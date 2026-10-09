// Prints the window number of the largest on-screen window of one process (layer 0), for `screencapture -l`.
// Usage: winid <pid>. Exits 1 when the process has no such window. Built by scripts/qa/shot.sh.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: winid <pid>\n".utf8))
    exit(2)
}

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
else {
    exit(1)
}

var best: (number: Int, area: CGFloat)?
for window in windows {
    guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
    else {
        continue
    }
    guard let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    else {
        continue
    }
    let area = bounds.width * bounds.height
    if best == nil || area > best!.area {
        best = (number, area)
    }
}

guard let found = best else {
    exit(1)
}
print(found.number)
