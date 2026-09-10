import Foundation
import IOKit.hid

/// Reads the MacBook hinge angle from the built-in HID sensor (usage page 0x20, usage 0x8A).
/// Two reports are fused: report 1 is whole degrees and fresh; report 7 is 0.01° but updates at ~10 Hz.
/// Polls on a background queue; `onAngle` is called on the main queue when the fused value changes.
final class LidAngleSensor {
    struct Sample { let coarse: Double; let fine: Double?; let fused: Double }
    var onAngle: ((Double) -> Void)?
    var onSample: ((Sample) -> Void)?
    private(set) var isAvailable = false
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: DispatchSourceTimer?
    private var lastFused: Double = -1
    private var lastFine: Double?

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
        guard let coarse = readCoarse() else { return nil }
        let fine = readFine()
        // The fine value lags while moving; trust it only when it agrees with the fresh whole-degree reading.
        let fused: Double
        if let fine, abs(fine - coarse) <= 1.0 { fused = fine } else { fused = coarse }
        return Sample(coarse: coarse, fine: fine, fused: fused)
    }

    func start(hz: Double = 60) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "duofy.lid", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / hz)
        t.setEventHandler { [weak self] in
            guard let self, let s = self.readSample() else { return }
            // Deadband: ignore the ±0.08° flicker of the fine report at rest.
            guard abs(s.fused - self.lastFused) >= 0.1 else { return }
            self.lastFused = s.fused
            DispatchQueue.main.async { self.onSample?(s); self.onAngle?(s.fused) }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}
