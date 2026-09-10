import Foundation

/// Fixed A→B timeline. The lid angle is a playhead: closing plays forward, opening rewinds.
/// Frame k always means the same pose (tilt = k × step), so the same angle always shows the same frame.
struct FoldTimeline: Equatable {
    /// Angle where the fold starts (frame 0 = flat, identical to the live screen).
    let startAngle: Double
    /// Angle where the fold is complete (last frame). Closing further holds the last frame.
    let endAngle: Double
    /// Degrees of lid travel per frame. Resting jitter is removed upstream by the tracker deadband (0.2°).
    let degreesPerFrame: Double

    var frameCount: Int { max(Int(((startAngle - endAngle) / degreesPerFrame).rounded(.up)), 1) }

    /// Continuous playhead position (in frames) for a lid angle, clamped to the timeline.
    func playhead(for angle: Double) -> Double {
        min(max((startAngle - angle) / degreesPerFrame, 0), Double(frameCount))
    }

    func pose(frame: Int) -> LidPose {
        let clamped = min(max(frame, 0), frameCount)
        return LidPose(angle: startAngle - Double(clamped) * degreesPerFrame, referenceAngle: startAngle, endAngle: endAngle)
    }
}
