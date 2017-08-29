// Written by H.Raat / https://github.com/oderwat/ (c) 2017
// MIT LICENSE (aka do what you want with it but don't blame me)

import Foundation
import Cocoa
import SQLite

let homeDirURL = URL(fileURLWithPath: NSHomeDirectory())
// let homeDirURL = FileManager.default.homeDirectoryForCurrentUser

let bearDB = try Connection("\(homeDirURL.absoluteString)/Library/Containers/net.shinyfrog.bear/Data/Documents/Application Data/database.sqlite",
        readonly: true)

bearDB.busyTimeout = 5

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
            .filter(text.like("%```%\n%```\n```output%\n%```\n%") || text.like("%```meta\n%```\n```%\n%```\n%"))
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

        let noteModified = Date(timeIntervalSinceReferenceDate: row[changed])

        var blocks = text.components(separatedBy: "```")
        var lastMeta = [String: String]()
        var skipToIdx = 0

        for idx in blocks.indices {
            if idx < skipToIdx {
                // fast skipping
                continue
            }
            let block = blocks[idx]

            if block.hasPrefix("meta\n") {
                // start a new meta collection
                lastMeta = [String: String]()

                // for every new meta block we reset everything
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
                if verbose > 1 {
                    for (key, val) in lastMeta {
                        print("'\(key)': '\(val)'")
                    }
                }
            } else if block != "\n" { // we ignore "in between blocks with just whitespace
                let end = block.index(of: "\n")
                if end != nil {
                    let codeType = String(block[block.startIndex..<end!])

                    if codeType == "" && lastMeta.count == 0 {
                        if verbose > 1 {
                            print("Skipping unrelated block")
                            continue;
                        }
                    }

                    var codeText = String(block[(block.index(end!, offsetBy: 1))..<block.endIndex])
                    var codeFile = ""
                    var codeExtension = ""

                    if codeType == "php" {
                        // PHP gets php tags so the code inside Bear looks cleaner
                        // if one needs "raw" php there is always "run:php" possible too
                        codeText = "<?php\n\(codeText)"
                    }
                    if verbose > 2 {
                        print("codeType: \(codeType)")
                    }
                    if verbose > 2 {
                        print("codeText: \(codeText)")
                    }

                    // we call it maybe a bit to often right now
                    var sollHash: String?


                    if let saveas = lastMeta["saveas"] {
                        var needSave = true
                        // check if the file needs to be saved by checking the timestamps (for now)
                        if let fileModified = fileModified(saveas) {
                            if verbose > 2 {
                                print("\(fileModified) vs \(noteModified)")
                            }
                            if fileModified > noteModified {
                                needSave = false
                            }
                        }

                        if needSave {
                            sollHash = codeText.stableHash()

                            if verbose > 0 {
                                print("saving to \(saveas)")
                            }
                            try codeText.write(to: URL(fileURLWithPath: saveas), atomically: false, encoding: .utf8)
                            if let perms = lastMeta["chmod"] {
                                try chmod(saveas, Int(perms, radix: 8)!)
                            }
                        }

                        // we handled (saved) it so lets remove this
                        lastMeta.removeValue(forKey: "saveas")
                        // remember that we (already) saved the code so we don't need to write
                        // it again to "run" it if that is needed
                        codeFile = saveas
                    }

                    let knownCode = ["swift", "php", "python"]
                    // Handle code running
                    if knownCode.contains(codeType) || lastMeta["run"] != nil {
                        // test for output block
                        if blocks.count > idx + 2 && blocks[idx + 2].hasPrefix("output") {
                            let oi = idx + 2 // output block index
                            let ob = blocks[oi] // output block contents

                            skipToIdx = oi + 1

                            // get hash from output block
                            let istHash = ob.hasPrefix("output\n") ?
                                    "" :
                                    String(ob[ob.index(ob.startIndex, offsetBy: 7)..<ob.index(of: "\n")!])

                            if sollHash == nil {
                                sollHash = codeText.stableHash()
                            }

                            if verbose > 2 {
                                print("\(istHash) / \(sollHash!)")
                            }

                            if (istHash == sollHash!) {
                                // no change in sourcecode
                                if verbose > 1 {
                                    print("no change to the source")
                                }
                                continue
                            }

                            var output = ""
                            do {

                                // run it as code :)
                                let cmd = lastMeta["run"] ?? codeType

                                if codeFile == "" {
                                    switch(cmd) {
                                    case "php":
                                        codeExtension = "php"
                                    case "swift":
                                        codeExtension = "swift"
                                    case "python":
                                        codeExtension = "py"
                                    default:
                                        codeExtension = lastMeta["ext"] ?? "txt"
                                    }
                                    let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                                            .appendingPathComponent(UUID().uuidString)
                                            .appendingPathExtension(codeExtension)
                                    codeFile = fileURL.path
                                    // writing to disk
                                    try codeText.write(to: URL(fileURLWithPath: codeFile), atomically: false, encoding: .utf8)
                                }

                                if verbose > 2 {
                                    let date = Date(timeIntervalSinceReferenceDate: row[changed])
                                    let dayTimePeriodFormatter = DateFormatter()
                                    dayTimePeriodFormatter.dateFormat = "YYYY-MM-dd HH:mm:ss"
                                    let dateString = dayTimePeriodFormatter.string(from: date)
                                    print(codeFile)
                                    print("\(codeType) (\(dateString)):")
                                    print(codeText)
                                }

                                if verbose > 0 {
                                    print("run \(cmd) on \(codeFile)")
                                }
                                (_, output) = shell("/usr/bin/env", [cmd, codeFile])

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
                            // updating the output (always, so the hash gets updated)
                            blocks[oi] = "output \(sollHash!)\n\(output)"
                            modified = true
                        } else {
                            if verbose > 2 {
                                print("skipping code run because no output is defined")
                            }
                        }
                    }
                    lastMeta = [String: String]()
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
