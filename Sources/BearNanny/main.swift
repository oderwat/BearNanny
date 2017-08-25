// Written by H.Raat / https://github.com/oderwat/ (c) 2017
// MIT LICENSE (aka do what you want with it but don't blame me)

import Foundation
import Cocoa
import SQLite

let homeDirURL = URL(fileURLWithPath: NSHomeDirectory())
// let homeDirURL = FileManager.default.homeDirectoryForCurrentUser

let bearDB = try Connection("\(homeDirURL.absoluteString)/Library/Containers/net.shinyfrog.bear/Data/Documents/Application Data/database.sqlite",
        readonly: true)

//bearDB.trace { print($0) }

var globalTask: Process?
var lastCheck: Double = 0.0
var verbose = 1

@discardableResult
func shell(_ command: String, _ args: [String] = []) -> (Int32, String) {

    globalTask = Process()
    guard let task = globalTask else {
        return (-1, "")
    }
    defer {
        globalTask = nil
    }
    task.launchPath = command
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe // redirects stderr to stdout so we can parse that too
    task.standardInput = FileHandle.nullDevice

    signal(SIGINT) { signal in
        print("Interrupted! Cleaning up...")
        if let gt = globalTask {
            print("terminating running task...", terminator: "")
            gt.terminate()
            gt.waitUntilExit()
            print("ok")
        }
        exit(EXIT_FAILURE)
    }

    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()

    let output = String(data: data, encoding: String.Encoding.utf8)!
    return (task.terminationStatus, output)
}

func searchAndOpen(term: String) throws {
    for row in try bearDB.prepare("""
        SELECT ZUNIQUEIDENTIFIER, ZTITLE FROM ZSFNOTE WHERE ZTEXT LIKE '% => ::%' AND ZTRASHED=0
        ORDER BY ZMODIFICATIONDATE DESC LIMIT 1
        """) {
        print("uid: \(row[0] as Optional), title: \(row[1] as Optional)")
        if let uid = row[0] {
            NSWorkspace.shared.open(URL(string: "bear://x-callback-url/open-note?id=\(uid)")!)
        }
    }
}


func nanny() throws {
    let notes = Table("ZSFNOTE")
    let title = Expression<String>("ZTITLE")
    let uid = Expression<String>("ZUNIQUEIDENTIFIER")
    let text = Expression<String>("ZTEXT")
    let trashed = Expression<Int64>("ZTRASHED")
    let changed = Expression<Double>("ZMODIFICATIONDATE")

    let query = notes.select(uid, title, text, changed)
            .filter(text.like("%```swift\n%```\n```output%\n%```\n%") || text.like("%```meta\n%```\n```%\n%```\n%"))
            .filter(changed > lastCheck)
            .filter(trashed == 0)

    for row in try bearDB.prepare(query) {
        var modified = false
        let uid = row[uid]
        // removing the first line (which counts as title)
        let parts = row[text].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let text = String(parts[1])

        // it will still trigger twice because of the update to the note by url-scheme
        if row[changed] > lastCheck {
            lastCheck = row[changed]
        }

        var blocks = text.components(separatedBy: "```")

        var lastCode = ""
        var lastType = ""
        var lastMeta = [String: String]()
        var savedAs: String? = nil

        func reInit() {
            // if there are empty blocks or other spacing we don't process them
            lastType = ""
            lastCode = ""
            lastMeta = [String: String]()
            savedAs = nil
        }

        for idx in blocks.indices {
            let block = blocks[idx]

            if block.hasPrefix("output") {
                if lastType != "swift" && lastType != "php" && lastMeta["run"] == nil {
                    print("output without implicit or explicit way to run it")
                    reInit()
                    continue
                }

                // get hash from note
                let istHash = block.hasPrefix("output\n") ? "" : String(block[block.index(block.startIndex, offsetBy: 7)..<block.index(of: "\n")!])
                let sollHash = lastCode.stableHash()
                if verbose > 0 {
                    print("\(istHash) / \(sollHash)")
                }
                if (istHash == sollHash) {
                    // no change in sourcecode
                    if verbose > 0 {
                        print("no change to the source")
                    }
                    reInit()
                    continue
                }

                var output = ""
                do {
                    var codeFile: String

                    if savedAs != nil {
                        codeFile = savedAs!
                    } else {
                        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent(UUID().uuidString)
                                .appendingPathExtension("swift")
                        codeFile = fileURL.path
                        // writing to disk
                        try lastCode.write(to: URL(fileURLWithPath: codeFile), atomically: false, encoding: .utf8)
                    }

                    //let codeFile = "/tmp/bearnanny_\(uid).swift"
                    if verbose > 2 {
                        let date = Date(timeIntervalSinceReferenceDate: row[changed])
                        let dayTimePeriodFormatter = DateFormatter()
                        dayTimePeriodFormatter.dateFormat = "YYYY-MM-dd HH:mm:ss"
                        let dateString = dayTimePeriodFormatter.string(from: date)
                        print(codeFile)
                        print("\(lastType) (\(dateString)):")
                        print(lastCode)
                    }

                    // run it as code :)
                    if lastMeta["run"] != nil {
                        print("run \(lastMeta["run"]!) on \(codeFile)")
                        (_, output) = shell("/usr/bin/env", [lastMeta["run"]!, codeFile])
                    } else if lastType == "swift" {
                        print("run Swift on \(codeFile)")
                        (_, output) = shell("/usr/bin/env", ["swift", codeFile])
                    } else if lastType == "php" {
                        print("run PHP on \(codeFile)")
                        (_, output) = shell("/usr/bin/env", ["php", codeFile])
                    }
                    try FileManager.default.removeItem(atPath: codeFile)

                    if output[output.index(output.endIndex, offsetBy: -1)] != "\n" {
                        output += "\n"
                    }

                    if verbose > 2 {
                        print("Output:")
                        print(output)
                    }
                } catch {
                    print("error for: \(error)")
                }
                // we only replace/update the result if the
                // output differs (ignoring that the hash needs an update)
                // this will make it not update when editing the swift file
                // for whitespace for example.
                if  blocks[idx] != "output \(istHash)\n\(output)" || true {
                    blocks[idx] = "output \(sollHash)\n\(output)"
                    modified = true
                } else if verbose > 0 {
                    print("ignoring source change for same output")
                }

                reInit()
            } else if block.hasPrefix("meta\n") {
                // for every new meta block we reset everything
                reInit()

                let range = block.index(block.startIndex, offsetBy: 5)..<block.index(block.endIndex, offsetBy: -1)
                for line in String(block[range]).split(separator: "\n") {
                    let keyval = line.split(separator: ":", maxSplits: 1)
                    let key = keyval[0].trim()
                    let val = keyval[1].trim()
                    if key == "saveas" {
                        lastMeta[key] = NSString(string: val).expandingTildeInPath
                    } else {
                        lastMeta[key] = val
                    }
                }
                if verbose > 0 {
                    for (key, val) in lastMeta {
                        print("'\(key)': '\(val)'")
                    }
                }
            } else if block != "\n" { // we ignore "in between blocks with just whitespace
                let end = block.index(of: "\n")
                if end != nil {
                    lastType = String(block[block.startIndex..<end!])
                    lastCode = String(block[(block.index(end!, offsetBy: 1))..<block.endIndex])

                    // test for output block
                    if blocks.count > idx+2 {
                        let haveOutput = blocks[idx+2]
                        print("have output: \(haveOutput)")
                    }

                    if lastType == "php" {
                        // PHP gets php tags so the code inside Bear looks cleaner
                        // if one needs "raw" php there is always "run:php" possible too
                        lastCode = "<?php\n\(lastCode)"
                    }
                    if verbose > 1 {
                        print("LastType: \(lastType)")
                        print("LastCode: \(lastCode)")
                    }
                    if let saveas = lastMeta["saveas"] {
                        print("saving to \(saveas)")
                        try lastCode.write(to: URL(fileURLWithPath: saveas), atomically: false, encoding: .utf8)
                        if let perms = lastMeta["chmod"] {
                            try chmod(saveas, Int(perms, radix: 8)!)
                        }
                        // we saved it so lets remove this
                        lastMeta.removeValue(forKey: "saveas")
                        // remember that we (already) saved the code so we don't need to write
                        // it again to "run" it if that is needed
                        savedAs = saveas
                    } else {
                        savedAs = nil
                    }
                } else {
                    // if there are empty blocks or other spacing we don't process them
                    reInit()
                }
            }
        }

        if modified {
            // Updating the note in Bear with the new content
            let build = blocks.joined(separator: "```")
            let urlText = build.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
                    .replacingOccurrences(of: "=", with: "%3d")
            if let url = URL(string: "bear://x-callback-url/add-text?id=\(uid)&mode=replace&text=\(urlText)") {
                NSWorkspace.shared.open(url)
            } else {
                print("error: can't build url")
            }
        }
    }
}

do {
    while true {
        try nanny()
        sleep(1)
    }
} catch let error {
    print("Error: \(error)")
}
