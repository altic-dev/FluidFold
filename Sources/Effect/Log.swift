import Foundation
import os

/// Logs to unified logging and, when the `debugLog` default is set, to ~/Library/Logs/Duofy.log.
func dlog(_ message: @autoclosure () -> String) {
    let m = message()
    Logger(subsystem: "com.altic.Duofy", category: "app").log("\(m, privacy: .public)")
    guard UserDefaults.standard.bool(forKey: "debugLog") else { return }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Duofy.log")
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}
