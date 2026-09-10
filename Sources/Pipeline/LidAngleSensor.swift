import Foundation
import IOKit.hid

/// Reads the MacBook hinge angle (degrees) from the built-in HID sensor (usage page 0x20, usage 0x8A).
/// Polls on a background queue; `onAngle` is called on the main queue only when the value changes.
final class LidAngleSensor {
    var onAngle: ((Double) -> Void)?
    private(set) var isAvailable = false
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: DispatchSourceTimer?
    private var lastAngle: Double = -1

    init() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        device = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first
        isAvailable = device != nil && readAngle() != nil
    }

    func readAngle() -> Double? {
        guard let device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len: CFIndex = buf.count
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard r == kIOReturnSuccess, len >= 3 else { return nil }
        return Double(UInt16(buf[1]) | UInt16(buf[2]) << 8)
    }

    func start(hz: Double = 30) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "duofy.lid", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / hz)
        t.setEventHandler { [weak self] in
            guard let self, let a = self.readAngle(), a != self.lastAngle else { return }
            self.lastAngle = a
            DispatchQueue.main.async { self.onAngle?(a) }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}
