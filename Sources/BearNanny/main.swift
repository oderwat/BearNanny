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
var runTrigger = "<<<"
var formatTrigger = ">>>"
var formatOnRun = false
var formatConfigSwift: String?
var verbose = 1

@discardableResult
func shell(_ command: String, _ args: [String] = [], stdin: String? = nil) -> (Int32, String, String) {

    globalTask = Process()
    guard let task = globalTask else {
        return (-1, "", "")
    }
    defer {
        globalTask = nil
    }
    task.launchPath = command
    task.arguments = args

    let pipeOutput = Pipe()
    let pipeError = Pipe()
    task.standardOutput = pipeOutput
    task.standardError = pipeError // redirects stderr to stdout so we can parse that too
    if let stdinFile = stdin {
        task.standardInput = FileHandle(forReadingAtPath: stdinFile)
    } else {
        task.standardInput = FileHandle.nullDevice
    }

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

    let dataOutput = pipeOutput.fileHandleForReading.readDataToEndOfFile()
    let dataError = pipeError.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()

    let output = String(data: dataOutput, encoding: String.Encoding.utf8)!
    let error = String(data: dataError, encoding: String.Encoding.utf8)!
    return (task.terminationStatus, output, error)
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

func placeCursor(_ line: Int, _ column: Int) {

    let script = """
    tell application \"System Events\"
        keystroke return
        key down {command}
        key code 126
        key up {command}
        repeat with i from 1 to \(line)
            key code 125
        end repeat
        repeat with i from 1 to \(column)
            key code 124
        end repeat
    end tell
    """

    do {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
        try script.write(to: URL(fileURLWithPath: fileURL.path), atomically: false, encoding: .utf8)
        shell("/usr/bin/env", ["osascript", fileURL.path])
    } catch {
        return
    }
}


func nanny() throws {
    let notes = Table("ZSFNOTE")
    let title = Expression<String>("ZTITLE")
    let uid = Expression<String>("ZUNIQUEIDENTIFIER")
    let text = Expression<String>("ZTEXT")
    let trashed = Expression<Int64>("ZTRASHED")
    let changed = Expression<Double>("ZMODIFICATIONDATE")

    var newestChange = 0.0

    // read the BearNanny Config (if available) from the dedicated note :)
    let configQuery = notes.select(text, changed)
            .filter(text.like("%```BearNanny%"))
            .filter(changed > lastCheck)
            .filter(trashed == 0)
    for row in try bearDB.prepare(configQuery) {
        if row[changed] > newestChange {
            newestChange = row[changed]
        }
        let text = row[text]
        for line in text.split(separator: "\n") {
            let keyval = line.split(separator: ":", maxSplits: 1)
            if keyval.count == 2 {
                let key = keyval[0].trim()
                let val = keyval[1].trim()
                switch key {
                case "RunTrigger":
                    runTrigger = val
                    if verbose > 0 {
                        print("run trigger set to: '\(runTrigger)'")
                    }
                case "FormatTrigger":
                    formatTrigger = val
                    if verbose > 0 {
                        print("format trigger set to: '\(formatTrigger)'")
                    }
                case "FormatOnRun":
                    formatOnRun = val == "true"
                    if verbose > 0 {
                        print("format on run set to: '\(formatOnRun ? "true" : "false")'")
                    }
                case "FormatSwift":
                    formatConfigSwift = val
                    if verbose > 0 {
                        print("FormatSwift options set to: '\(formatConfigSwift!)'")
                    }
                default:
                    print("Unknown key \(key) in BearConfig block")
                }
            }
        }
    }

    let query = notes.select(uid, title, text, changed)
            .filter(text.like("%```%\(runTrigger)%\n%```%") ||
                    text.like("%```%\(formatTrigger)%\n%```%") ||
                    text.like("%```meta\n%```\n```%\n%```%"))
            .filter(changed > lastCheck)
            .filter(trashed == 0)

    for row in try bearDB.prepare(query) {
        var modified = false
        let noteUid = row[uid]
        // removing the first line (which counts as title)
        let parts = row[text].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let text = String(parts[1])

        // it will still trigger twice because of the update to the note by url-scheme
        if row[changed] > newestChange {
            newestChange = row[changed]
        }

        let noteModified = Date(timeIntervalSinceReferenceDate: row[changed])

        var blocks = text.components(separatedBy: "```")

        var lastMeta = [String: String]()
        var skipToIdx = 0

        var blockStartLine = 1 // first line was stripped as "header" of the note
        var lastLineCount = 0

        var triggerLine = -1
        var triggerColumn = -1

        var removeBlocks = [Int]()

        for idx in blocks.indices {
            let block = blocks[idx]
            // Counting lines like this makes it easier to handle the continues in the loop
            blockStartLine += lastLineCount
            lastLineCount = block.countInstances(of: "\n")

            if idx < skipToIdx {
                // fast skipping
                continue
            }

            if block.hasPrefix("meta\n") {
                // start a new meta collection
                lastMeta = [String: String]()

                // for every new meta block we reset everything
                if block.count < 6 {
                    continue
                }

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
            } else if block != "\n" && !block.hasPrefix("BearNanny\n") { // we ignore "in between blocks with just whitespace
                let end = block.index(of: "\n")
                if end != nil {
                    let codeType = String(block[block.startIndex..<end!])

                    if codeType == "" && lastMeta.count == 0 {
                        if verbose > 1 {
                            print("Skipping unrelated block")
                        }
                        continue;
                    }

                    var codeText = String(block[(block.index(end!, offsetBy: 1))..<block.endIndex])
                    var codeFile = ""
                    var codeExtension = ""

                    let haveRunTrigger = codeText.contains(runTrigger)
                    let haveFormatTrigger = codeText.contains(formatTrigger)

                    var triggers: [String] = []
                    if haveRunTrigger {
                        triggers.append(runTrigger)
                    }

                    if haveFormatTrigger {
                        // both triggers can be the same characters
                        if !triggers.contains(formatTrigger) {
                            triggers.append(formatTrigger)
                        }
                    }

                    // check for triggers
                    if triggers.count > 0 {
                        // trigger entfernen (damit er nicht stört)
                        if verbose > 0 {
                            print("got trigger!")
                        }

                        for trigger in triggers {
                            codeText = codeText.replacingOccurrences(of: trigger, with: "")
                            blocks[idx] = blocks[idx].replacingOccurrences(of: trigger, with: "")

                        }
                        modified = true

                        // we need to find the exact line where the (first) trigger is
                        // and from that what the exact column is
                        let trigger = triggers[0]
                        let lines = block.components(separatedBy: "\n")
                        for lineIdx in lines.indices {
                            let line = lines[lineIdx]
                            if let range = line.range(of: trigger) {
                                let startPos = line.distance(from: line.startIndex, to: range.lowerBound)
                                //let endPos = mystring.distance(from: mystring.startIndex, to: range.upperBound)
                                triggerLine = blockStartLine + lineIdx
                                triggerColumn = startPos
                                break
                            }
                        }
                    }

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

                    if haveRunTrigger || haveFormatTrigger {
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

                        let knownCode = ["swift", "php", "python"]
                        // Handle code running
                        if knownCode.contains(codeType) || lastMeta["run"] != nil {
                            do {

                                // run it as code :)
                                let cmd = lastMeta["run"] ?? codeType

                                if codeFile == "" {
                                    switch cmd {
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

                                if haveFormatTrigger || (haveRunTrigger && formatOnRun) {
                                    if codeType == "swift" {
                                        // formatting (swift) source code :)
                                        if let swiftFormat = formatConfigSwift {
                                            print("swiftformat: \(swiftFormat)")
                                            let (rc, codeFormatted, error) = shell("/usr/bin/env",
                                                    swiftFormat.components(separatedBy: " "), stdin: codeFile)
                                            if codeFormatted != codeText {
                                                if rc != 0 || error.count > 0 {
                                                    print("Skipping format because of possible error")
                                                    print(codeFormatted)
                                                    print(error)
                                                } else {
                                                    // Update to the formatted version of the code
                                                    try codeFormatted.write(to: URL(fileURLWithPath: codeFile), atomically: false, encoding: .utf8)
                                                    blocks[idx] = String("swift\n\(codeFormatted)".dropLast())
                                                    modified = true
                                                }
                                            }
                                        }
                                    }
                                }

                                if haveRunTrigger {
                                    if verbose > 0 {
                                        print("run \(cmd) on \(codeFile)")
                                    }
                                    var (_, output, error) = shell("/usr/bin/env", [cmd, codeFile])

                                    var boffset = 0
                                    // is the next block an 'errors' block
                                    if blocks.count > idx + 3 && blocks[idx + 2].hasPrefix("errors") {
                                        // we remove two error blocks
                                        skipToIdx = idx + 2
                                        removeBlocks.append(idx + 2)
                                        removeBlocks.append(idx + 3)
                                        boffset = 2
                                        modified = true
                                    }

                                    // have an output block?
                                    if blocks.count > idx + 3 + boffset && blocks[idx + 2 + boffset].hasPrefix("output") {
                                        let oi = idx + 2 + boffset // output block index
                                        skipToIdx = idx + 4

                                        if output != "" {
                                            if output[output.index(output.endIndex, offsetBy: -1)] != "\n" {
                                                output += "\n"
                                            }
                                        }

                                        if error != "" {
                                            if error[error.index(error.endIndex, offsetBy: -1)] != "\n" {
                                                error += "\n"
                                            }
                                        }

                                        if verbose > 2 {
                                            print("Output:")
                                            print(output)
                                        }

                                        if verbose > 0 && error != "" {
                                            print("Error:")
                                            print(error)
                                        }

                                        if error != "" {
                                            // updating the output and prepend an error block
                                            blocks[oi] = "errors\n\(error)```\n```output\n\(output)"
                                        } else {
                                            // updating the output
                                            blocks[oi] = "output\n\(output)"
                                        }
                                        modified = true
                                    }

                                }
                                try FileManager.default.removeItem(atPath: codeFile)

                            } catch {
                                print("error for: \(error)")
                            }
                        }
                    }

                    lastMeta = [String: String]()
                }
            }
        }

        if modified {
            // Updating the note in Bear with the new content
            var offset = 0
            for remIdx in removeBlocks {
                blocks.remove(at: remIdx - offset)
                offset += 1
            }
            let build = blocks.joined(separator: "```")
            var allowedQueryParamAndKey =  CharacterSet.urlQueryAllowed
            allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
            let urlText = build.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey)!
            if let url = URL(string: "bear://x-callback-url/add-text?id=\(noteUid)&mode=replace&text=\(urlText)") {
                NSWorkspace.shared.open(url)
                if triggerLine >= 0 {
                    if verbose > 1 {
                        print("trigger at line: \(triggerLine) column: \(triggerColumn)")
                    }
                    placeCursor(triggerLine, triggerColumn)
                }
            } else {
                print("error: can't build url")
            }
        }
    }

    if newestChange > lastCheck {
        lastCheck = newestChange
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
