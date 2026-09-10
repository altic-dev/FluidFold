import Foundation
import os

private let logQueue = DispatchQueue(label: "dusk.log", qos: .utility)

/// Low-frequency diagnostics only. High-frequency measurements use the buffered TrackingTrace.
func dlog(_ message: @autoclosure () -> String) {
    let m = message()
    Logger(subsystem: "com.altic.Dusk", category: "app").log("\(m, privacy: .public)")
    guard UserDefaults.standard.bool(forKey: "debugLog") else { return }
    let time = Date()
    logQueue.async {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dusk.log")
        let line = "\(time) \(m)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
