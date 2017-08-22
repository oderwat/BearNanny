// Written by H.Raat / https://github.com/oderwat/ (c) 2017
// MIT LICENSE (aka do what you want with it but don't blame me)

import Foundation
import Cocoa
import SQLite

let homeDirURL = URL(fileURLWithPath: NSHomeDirectory())
// let homeDirURL = FileManager.default.homeDirectoryForCurrentUser

let db = try Connection("\(homeDirURL.absoluteString)/Library/Containers/net.shinyfrog.bear/Data/Documents/Application Data/database.sqlite",
        readonly: true)

//db.trace { print($0) }

var globalTask: Process?
var lastCheck: Double = 0.0
var verbose = true

func strHash(_ str: String) -> String {
    var result = UInt64(5381)
    let buf = [UInt8](str.utf8)
    for b in buf {
        result = 127 * (result & 0x00ffffffffffffff) + UInt64(b)
    }
    return String(result, radix: 36)
}

@discardableResult
func shell(_ command: String, _ args: [String] = []) -> (Int32, String) {

    globalTask = Process()
    let task = globalTask!
    task.launchPath = "/usr/bin/env"
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe // redirects stderr to stdout so we can parse that too
    task.standardInput = FileHandle.nullDevice

    signal(SIGINT) { signal in
        print("Interrupted! Cleaning up...")
        if globalTask != nil {
            globalTask!.terminate()
            globalTask!.waitUntilExit()
        }
        exit(EXIT_FAILURE)
    }

    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()
    globalTask = nil

    let output = String(data: data, encoding: String.Encoding.utf8)!
    print("Out: \(output)")
    return (task.terminationStatus, output)
}

func searchAndOpen(term: String) throws {
    for row in try db.prepare("""
        SELECT ZUNIQUEIDENTIFIER, ZTITLE FROM ZSFNOTE WHERE ZTEXT LIKE '% => ::%' AND ZTRASHED=0
        ORDER BY ZMODIFICATIONDATE DESC LIMIT 1
        """) {
        print("uid: \(row[0] as Optional), title: \(row[1] as Optional)")
        if let uid = row[0] {
            NSWorkspace.shared.open(URL(string: "bear://x-callback-url/open-note?id=\(uid)")!)
        }
    }
}

func updateCalcs() throws {
    let notes = Table("ZSFNOTE")
    let title = Expression<String>("ZTITLE")
    let uid = Expression<String>("ZUNIQUEIDENTIFIER")
    let text = Expression<String>("ZTEXT")
    let trashed = Expression<Int64>("ZTRASHED")
    let changed = Expression<Double>("ZMODIFICATIONDATE")

    let query = notes.select(uid, title, text, changed)
            .filter(text.like("%```swift\n%```\n```output%\n%```\n%"))
            .filter(changed > lastCheck)
            .filter(trashed == 0)

    for row in try db.prepare(query) {
        var modified = false
        let uid = row[uid]
        // removing the first line (which counts as title)
        let parts = row[text].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let text = String(parts[1])

        // it will still trigger twice because of the update to the note by url-scheme
        if row[changed] > lastCheck {
            lastCheck = row[changed]
        }

        var last_code = ""
        var blocks = text.components(separatedBy: "```")
        for idx in blocks.indices {
            let block = blocks[idx]
            if block.hasPrefix("swift\n") && block != "swift\n" {
                let range = block.index(block.startIndex, offsetBy: 6)..<block.index(block.endIndex, offsetBy: -1)
                last_code = String(block[range])
            } else if block.hasPrefix("output") && last_code != "" {
                // get hash from note
                let istHash = block.hasPrefix("output\n") ? "" : String(block[block.index(block.startIndex, offsetBy: 7)..<block.index(of: "\n")!])
                let sollHash = strHash(last_code)
                if verbose {
                    print("\(istHash) / \(sollHash)")
                }
                if (istHash == sollHash) {
                    // no change in sourcecode
                    if verbose {
                        print("no change to the source")
                    }
                    continue
                }
                let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("swift")
                let swiftFile = fileURL.path

                //let swiftFile = "/tmp/bearnanny_\(uid).swift"
                var output = ""
                do {
                    if verbose {
                        let date = Date(timeIntervalSinceReferenceDate: row[changed])
                        let dayTimePeriodFormatter = DateFormatter()
                        dayTimePeriodFormatter.dateFormat = "YYYY-MM-dd HH:mm:ss"
                        let dateString = dayTimePeriodFormatter.string(from: date)
                        //print(swiftFile)
                        print("Swift Code (\(dateString)):")
                        print(last_code)
                    }

                    // writing to disk
                    try last_code.write(to: URL(fileURLWithPath: swiftFile), atomically: false, encoding: .utf8)
                    // run it as code :)
                    (_, output) = shell("swift", ["swift", swiftFile])
                    try FileManager.default.removeItem(atPath: swiftFile)

                    if verbose {
                        print("Output:")
                        print(output)
                    }
                } catch {
                    print("error for \(swiftFile): \(error)")
                }
                // we only replace/update the result if the
                // output differs (ignoring that the hash needs an update)
                // this will make it not update when editing the swift file
                // for whitespace for example.
                if (blocks[idx] != "output \(istHash)\n\(output)") {
                    blocks[idx] = "output \(sollHash)\n\(output)"
                    modified = true
                } else if verbose {
                    print("ignoring source change for same output")
                }
            }
        }

        if modified {
            let build = blocks.joined(separator: "```")
            let url_text = build.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
                    .replacingOccurrences(of: "=", with: "%3d")
            if let url = URL(string: "bear://x-callback-url/add-text?id=\(uid)&mode=replace&text=\(url_text)") {
                NSWorkspace.shared.open(url)
            } else {
                print("error: can't build url")
            }
        }
    }
}

do {
    while true {
        try updateCalcs()
        sleep(1)
    }
} catch let error {
    print("Error: \(error)")
}
