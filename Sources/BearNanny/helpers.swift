//
// Created by Hans Raaf on 25.08.17.
//

import Foundation


extension Substring {
    func trim() -> String {
        var trimmed = String(self)
        for replace in [" ", "\n", "\""] {
            trimmed = trimmed.replacingOccurrences(of: replace, with: "", options: NSString.CompareOptions.literal, range: nil)
        }
        return trimmed
    }
}

extension String {
    func stableHash() -> String {
        var result = UInt64(5381)
        let buf = [UInt8](self.utf8)
        for b in buf {
            result = 127 * (result & 0x00ffffffffffffff) + UInt64(b)
        }
        return String(result, radix: 36)
    }
}

func chmod(_ path: String, _ perms: Int) throws {
    let fm = FileManager.default

    var attributes = [FileAttributeKey: Any]()
    attributes[.posixPermissions] = perms
    try fm.setAttributes(attributes, ofItemAtPath: path)
}

func fileModified(_ path: String) -> Date? {
    do {
        let attr = try FileManager.default.attributesOfItem(atPath: path)
        return attr[FileAttributeKey.modificationDate] as? Date
    } catch {
        return nil
    }
}
