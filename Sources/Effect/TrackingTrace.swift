import Foundation
import QuartzCore

/// Numeric, monotonic timestamps only: no captured desktop content. Bounded sessions and buffering
/// keep diagnostic disk I/O and string formatting off the sensor, main, and GPU callback threads.
final class TrackingTrace {
    static let shared = TrackingTrace()
    private struct Event {
        let name: String
        let time: Double
        let id: UInt64
        let values: [Double]
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "duofy.trace", qos: .utility)
    private var events: [Event] = []
    private var deadline: Double = 0
    private var dropped = 0
    private var sequence: UInt64 = 0
    private var file: FileHandle?
    private var timer: DispatchSourceTimer?

    private init() {}

    /// Starts a fresh bounded trace. All file operations are serialized on the writer queue.
    func start(seconds: Double = 90) {
        queue.async { [self] in
            flush()
            try? file?.close()
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DuofyTracking")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "tracking-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).csv"
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("event,time,id,a,b,c,d,e,f,g,h\n".utf8))
            file = try? FileHandle(forWritingTo: url)
            try? file?.seekToEnd()
            lock.lock()
            events.removeAll(keepingCapacity: true)
            dropped = 0
            deadline = CACurrentMediaTime() + min(max(seconds, 1), 180)
            lock.unlock()
            record("session", values: [Date().timeIntervalSince1970, seconds])
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.flush()
                self.lock.lock()
                let expired = CACurrentMediaTime() >= self.deadline
                self.lock.unlock()
                if expired {
                    self.timer?.cancel(); self.timer = nil
                    try? self.file?.close(); self.file = nil
                }
            }
            timer = t
            t.resume()
            dlog("tracking trace: \(url.path)")
        }
    }

    func record(_ name: String, id: UInt64 = 0, time: Double = CACurrentMediaTime(), values: [Double] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard time < deadline else { return }
        guard events.count < 8192 else { dropped += 1; return }
        events.append(Event(name: name, time: time, id: id, values: values))
    }

    var currentFrameID: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return sequence
    }

    func nextFrameID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    private func flush() {
        lock.lock()
        let batch = events
        events.removeAll(keepingCapacity: true)
        let lost = dropped
        dropped = 0
        lock.unlock()
        guard let file else { return }
        var text = batch.map { event in
            let fields = [event.name, String(format: "%.9f", event.time), String(event.id)]
                + (0..<8).map { $0 < event.values.count ? String(format: "%.9f", event.values[$0]) : "" }
            return fields.joined(separator: ",") + "\n"
        }.joined()
        if lost > 0 { text += "trace_dropped,\(CACurrentMediaTime()),0,\(lost),,,,,,,\n" }
        try? file.write(contentsOf: Data(text.utf8))
    }
}
