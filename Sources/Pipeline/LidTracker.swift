import Foundation

/// Anchored noise rejection. Accepted measurements are used directly, without timed motion.
/// The anchor never follows sub-threshold noise, so a stationary lid cannot random-walk.
/// No forward extrapolation: stale sensor values must not move a stationary screen.
struct LidTracker {
    struct Configuration {
        var fineDeadband = 0.20
        var coarseDeadband = 1.05
    }

    var configuration = Configuration()
    private(set) var target: Double = 120
    private(set) var initialized = false
    private(set) var usingFine = false

    mutating func ingest(coarse: Double, fine: Double?) -> Double {
        let validFine = fine.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil }
        let measurement = validFine ?? coarse
        guard measurement.isFinite, (0...360).contains(measurement) else { return target }
        let fineAvailable = validFine != nil
        if !initialized {
            target = measurement
            initialized = true
        } else {
            // At a source transition, cover coarse quantization too. Returning to fine readings
            // does not release the resting lock until the measurement leaves that uncertainty.
            let threshold = fineAvailable && usingFine ? configuration.fineDeadband : configuration.coarseDeadband
            if abs(measurement - target) > threshold { target = measurement }
        }
        usingFine = fineAvailable
        return target
    }

}

/// Pure angle-to-pose mapping shared by live rendering and tests. Time is deliberately not an input.
struct LidPose: Equatable {
    let tiltDegrees: Double
    let progress: Double

    init(angle: Double, referenceAngle: Double, endAngle: Double) {
        tiltDegrees = max(referenceAngle - angle, 0)
        progress = min(max((referenceAngle - angle) / max(referenceAngle - endAngle, 1), 0), 1)
    }
}
