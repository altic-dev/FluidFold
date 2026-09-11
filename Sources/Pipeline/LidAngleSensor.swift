import Foundation
import IOKit.hid
import QuartzCore

/// Reads the MacBook hinge angle from the built-in HID sensor (usage page 0x20, usage 0x8A).
/// Report 1 is whole degrees; report 7 has 0.01° resolution. Both changed around 10 Hz in calibration.
/// Raw polls and read boundaries are traced, including unchanged values. `fused`/`onAngle` preserve
/// the old selection rule for A/B measurement; LidTracker consumes the raw reports.
final class LidAngleSensor {
    struct Sample {
        let id: UInt64
        let time: Double
        let coarse: Double
        let fine: Double?
        let fused: Double
    }
    var onAngle: ((Double) -> Void)?
    var onSample: ((Sample) -> Void)?
    private(set) var isAvailable = false
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: DispatchSourceTimer?
    private var lastFused: Double = -1
    private var nextID: UInt64 = 0
    private let readLock = NSLock()

    init() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        device = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first
        isAvailable = device != nil && readCoarse() != nil
    }

    /// Whole degrees (report 1).
    func readCoarse() -> Double? {
        guard let device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len: CFIndex = buf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess, len >= 3 else { return nil }
        return Double(UInt16(buf[1]) | UInt16(buf[2]) << 8)
    }

    /// Hundredths of a degree (report 7), updated by the sensor at ~10 Hz.
    func readFine() -> Double? {
        guard let device else { return nil }
        var buf = [UInt8](repeating: 0, count: 16)
        var len: CFIndex = buf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 7, &buf, &len) == kIOReturnSuccess, len >= 3 else { return nil }
        let raw = UInt32(buf[1]) | UInt32(buf[2]) << 8 | (len > 3 ? UInt32(buf[3]) << 16 : 0)
        guard raw <= 36000 else { return nil }
        return Double(raw) / 100
    }

    func readAngle() -> Double? { readSample()?.fused }

    func readSample() -> Sample? {
        readLock.lock()
        defer { readLock.unlock() }
        let start = CACurrentMediaTime()
        guard let coarse = readCoarse() else {
            TrackingTrace.shared.record("sensor_failure", time: start)
            return nil
        }
        let coarseEnd = CACurrentMediaTime()
        let fine = readFine()
        let end = CACurrentMediaTime()
        nextID &+= 1
        // Legacy selection retained for A/B replay. Calibration found that fine can lead coarse;
        // the active tracker therefore prefers valid fine readings without this switching rule.
        let fused: Double
        if let fine, abs(fine - coarse) <= 1.0 { fused = fine } else { fused = coarse }
        TrackingTrace.shared.record("sensor", id: nextID, time: start,
                                    values: [coarse, fine ?? .nan, fused, coarseEnd, end])
        return Sample(id: nextID, time: end, coarse: coarse, fine: fine, fused: fused)
    }

    /// Polls slowly at rest and fast while the lid moves: fast polling gives accurate reading timestamps
    /// (the sensor's own cadence is ~100 ms; the poll interval is the timestamp error), slow polling keeps idle CPU low.
    func start(hz: Double = 60, movingHz: Double = 200) {
        stop()
        restHz = hz; boostHz = movingHz
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hinge.lid", qos: .userInteractive))
        t.setEventHandler { [weak self] in
            guard let self, let s = self.readSample() else { return }
            // Deadband: ignore the ±0.08° flicker of the fine report at rest.
            let changed = abs(s.fused - self.lastFused) >= 0.1
            if changed { self.lastFused = s.fused; self.lastChangeAt = s.time }
            if changed && !self.boosted { self.setRate(self.boostHz, on: t) }
            else if self.boosted && s.time - self.lastChangeAt > 1.5 { self.setRate(self.restHz, on: t) }
            DispatchQueue.main.async {
                TrackingTrace.shared.record("sensor_main", id: s.id, values: [s.time, changed ? 1 : 0])
                self.onSample?(s)
                if changed { self.onAngle?(s.fused) }
            }
        }
        timer = t
        setRate(hz, on: t)
        t.resume()
    }

    private var restHz = 60.0, boostHz = 200.0, boosted = false, lastChangeAt = 0.0
    private func setRate(_ hz: Double, on t: DispatchSourceTimer) {
        boosted = hz == boostHz
        t.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(hz > 100 ? 1 : 4))
    }

    func stop() { timer?.cancel(); timer = nil }
}
