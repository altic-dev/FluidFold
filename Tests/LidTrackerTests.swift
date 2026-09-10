import Foundation

@main
struct LidTrackerTests {
    static func main() {
        var tracker = LidTracker()
        _ = tracker.ingest(coarse: 104, fine: 104.49)
        for i in 1...10800 {
            let fine = 104.49 + 0.08 * sin(Double(i))
            _ = tracker.ingest(coarse: i % 2 == 0 ? 104 : 105, fine: fine)
            precondition(tracker.target == 104.49, "Stationary jitter escaped the lock")
        }

        // Closing, holding, and reversing use each measurement immediately. There is no clock
        // to run the effect forward while the physical input is unchanged.
        var live = LidTracker()
        let reference = live.ingest(coarse: 110, fine: 110)
        let first = LidPose(angle: live.target, referenceAngle: reference, endAngle: 25)
        precondition(first.tiltDegrees == 0 && first.progress == 0, "Preview starts autoplaying")
        _ = live.ingest(coarse: 85, fine: 85)
        let closed = LidPose(angle: live.target, referenceAngle: reference, endAngle: 25)
        precondition(closed.tiltDegrees == 25, "Effect waits for an animation instead of using the lid position")
        for i in 0..<36000 {
            _ = live.ingest(coarse: 85, fine: 85 + 0.08 * sin(Double(i)))
            precondition(LidPose(angle: live.target, referenceAngle: reference, endAngle: 25) == closed,
                         "Fold progresses during a hold")
        }
        _ = live.ingest(coarse: 100, fine: 100)
        precondition(LidPose(angle: live.target, referenceAngle: reference, endAngle: 25).tiltDegrees == 10,
                     "Opening does not reverse immediately")
        _ = live.ingest(coarse: 115, fine: 115)
        precondition(LidPose(angle: live.target, referenceAngle: reference, endAngle: 25).tiltDegrees == 0)

        _ = tracker.ingest(coarse: 100, fine: 99.11)
        _ = tracker.ingest(coarse: 99, fine: 102.97)
        precondition(tracker.target == 102.97, "Fine reading discarded")
        var slow = LidTracker()
        _ = slow.ingest(coarse: 90, fine: 90)
        for i in 1...50 { _ = slow.ingest(coarse: 90, fine: 90 - Double(i) * 0.01) }
        precondition(slow.target < 89.7, "Slow movement was mistaken for noise")
        var fallback = LidTracker()
        _ = fallback.ingest(coarse: 90, fine: nil)
        _ = fallback.ingest(coarse: 91, fine: nil)
        precondition(fallback.target == 90, "Coarse quantization causes jitter")
        _ = fallback.ingest(coarse: 93, fine: nil)
        precondition(fallback.target == 93)
        _ = fallback.ingest(coarse: .nan, fine: nil)
        precondition(fallback.target == 93)

        if CommandLine.arguments.count > 1 {
            let csv = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            var recorded = LidTracker()
            var outputs: [Double] = []
            for row in csv.split(separator: "\n").dropFirst() {
                let cols = row.split(separator: ",").map { Double($0)! }
                outputs.append(recorded.ingest(coarse: cols[2], fine: cols[3]))
            }
            let drift = outputs.max()! - outputs.min()!
            precondition(drift == 0, "Recorded stationary input drifted by \(drift)")
            print("PASS: \(outputs.count) recorded samples, accepted angle drift = \(drift) degrees")
        }
        print("PASS: immediate close/hold/reverse, stationary noise, fine readings, slow motion, coarse fallback, invalid input")
    }
}
