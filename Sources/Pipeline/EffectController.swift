import Foundation
import AppKit
import Combine

/// The sensor owns fold position. Capture only refreshes desktop pixels at that fixed position.
@MainActor
final class EffectController: ObservableObject {
    @Published private(set) var angle: Double = 120
    @Published private(set) var isShowing = false
    @Published private(set) var isLivePreview = false
    @Published var isPaused = false { didSet { evaluate() } }
    @Published var isEnabled = true { didSet { evaluate() } }
    let sensorAvailable: Bool

    var startAngle: Double = 95 { didSet { evaluate() } }
    var endAngle: Double = 25 { didSet { evaluate() } }
    var soundEnabled = true
    var prewarmDegrees: Double = 10

    let renderer: FoldRenderer
    private let sensor = LidAngleSensor()
    private var tracker = LidTracker()
    private let capturer = ScreenCapturer()
    private lazy var overlay: OverlayWindow = {
        let window = OverlayWindow(renderer: renderer)
        window.onDismiss = { [weak self] in self?.userDismissed() }
        return window
    }()
    private var armed = true
    private var minAngleSeen: Double = 180
    private var hasFrame = false
    private var pendingShow = false
    private var previewReference: Double?

    /// Degrees of lid travel per timeline frame.
    var degreesPerFrame: Double = UserDefaults.standard.double(forKey: "degreesPerFrame").nonZero ?? 0.05
    private var timeline: FoldTimeline { FoldTimeline(startAngle: referenceAngle, endAngle: endAngle, degreesPerFrame: degreesPerFrame) }

    // Playhead: the sensor publishes ~10 readings/s. Between readings the playhead glides linearly to the
    // target frame over one sensor interval, stepping through every frame in between, and stops exactly on it.
    private(set) var playhead: Double = 0
    private var glideFrom: Double = 0
    private var glideTo: Double = 0
    private var glideStart: Double = 0
    private var glideDuration: Double = 0.1
    private var glideFromVelocity: Double = 0     // frames/s at glide start (continuity with the previous glide)
    private var glideToVelocity: Double = 0       // estimated lid speed at the target, frames/s
    private var playheadVelocity: Double = 0
    private var lastTarget: Double = 0
    private var readingInterval: Double = 0.1     // smoothed sensor cadence
    private var shownFrame = -1
    private var lastSampleTime: Double = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var hideWhenSettled = false
    private var lastSampleID: UInt64 = 0
    private var framesShownThisFold = 0
    private var foldStartTime: Double = 0
    private let hudEnabled = UserDefaults.standard.bool(forKey: "debugHUD")
    /// Debug: while fake readings are being injected, real sensor samples are ignored.
    private var injectingUntil: Double = 0

    private var referenceAngle: Double { previewReference ?? startAngle }
    private var active: Bool { isEnabled && !isPaused && armed }
    private var wantsOverlay: Bool { active && (isLivePreview || angle < referenceAngle) }

    var trackingStatus: String {
        if !sensorAvailable { return "Sensor unavailable" }
        if !isEnabled { return "Disabled" }
        if isPaused || !armed { return "Paused" }
        if pendingShow { return "Waiting for screen capture" }
        return isShowing ? "Following lid" : "Waiting for lid movement"
    }

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        renderer.debugLog = UserDefaults.standard.bool(forKey: "debugLog")
        sensorAvailable = sensor.isAvailable
        sensor.onSample = { [weak self] sample in
            guard let self, CACurrentMediaTime() >= self.injectingUntil else { return }
            self.receive(sample)
        }
        // Debug: `scripts/sweep.sh` runs a fake lid sweep in-process at the real sensor cadence (10 Hz).
        DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.Duofy.sweep"), object: nil, queue: .main) { [weak self] note in
            let seconds = (note.object as? String).flatMap(Double.init) ?? 1.5
            self?.runFakeSweep(secondsPerDirection: seconds)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.Duofy.inject"), object: nil, queue: .main) { [weak self] note in
            guard let self, let value = (note.object as? String).flatMap(Double.init) else { return }
            self.injectingUntil = CACurrentMediaTime() + 1.5
            self.receive(LidAngleSensor.Sample(id: self.lastSampleID &+ 1, time: CACurrentMediaTime(), coarse: value.rounded(), fine: value, fused: value))
        }
        capturer.onFrame = { [weak self] buffer, timestamp in
            let received = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                TrackingTrace.shared.record("capture_main", values: [received])
                // Frozen snapshot: once the fold is showing, the picture never changes. Every frame of the
                // timeline is computed from the same snapshot, so forward and rewind show identical frames.
                guard !self.isShowing else { return }
                self.renderer.setSource(pixelBuffer: buffer, timestamp: timestamp)
                self.hasFrame = true
                if self.pendingShow {
                    self.pendingShow = false
                    if self.wantsOverlay { self.presentOverlay() }
                }
            }
        }
        if let sample = sensor.readSample() {
            angle = tracker.ingest(coarse: sample.coarse, fine: sample.fine)
            renderer.sensorSampleID = sample.id
        }
        sensor.start()
        evaluate()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                TrackingTrace.shared.record("sleep")
                self?.capturer.stop()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let sample = self.sensor.readSample() { self.receive(sample) }
                TrackingTrace.shared.record("wake", values: [self.angle])
                // The snapshot survives sleep, so reopening just rewinds the timeline.
                self.evaluate()
            }
        }
        capturer.onStopped = { [weak self] in
            guard let self, self.wantsOverlay, !self.isShowing else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.wantsOverlay, !self.isShowing else { return }
                Task { await self.capturer.start() }
            }
        }
    }

    private var fakeSweepTimer: Timer?

    /// Debug: 105° → 20°, hold 1 s, → 105°, one reading every 100 ms like the hinge sensor.
    private func runFakeSweep(secondsPerDirection: Double) {
        fakeSweepTimer?.invalidate()
        let steps = max(Int(secondsPerDirection * 10), 1)
        var readings: [Double] = (0...steps).map { 105 - 85 * Double($0) / Double(steps) }
        readings += Array(repeating: 20, count: 10)
        readings += (0...steps).map { 20 + 85 * Double($0) / Double(steps) }
        var i = 0
        fakeSweepTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, i < readings.count else { t.invalidate(); return }
            self.injectingUntil = CACurrentMediaTime() + 1.5
            let v = readings[i]; i += 1
            self.receive(LidAngleSensor.Sample(id: self.lastSampleID &+ 1, time: CACurrentMediaTime(), coarse: v.rounded(), fine: v, fused: v))
        }
        RunLoop.main.add(fakeSweepTimer!, forMode: .common)
    }

    private func receive(_ sample: LidAngleSensor.Sample) {
        let target = tracker.ingest(coarse: sample.coarse, fine: sample.fine)
        TrackingTrace.shared.record("tracking_target", id: sample.id,
                                    values: [target, tracker.usingFine ? 1 : 0, tracker.configuration.fineDeadband])
        if angle != target {
            renderer.sensorSampleID = sample.id
            lastSampleID = sample.id
            let now = CACurrentMediaTime()
            angle = target
            // Glide the playhead to the new reading's frame over about one sensor interval (+10% so it rarely
            // arrives before the next reading and has to stop).
            let interval = min(max(now - lastSampleTime, 0.05), 0.2)
            readingInterval = readingInterval * 0.7 + interval * 0.3
            let targetFrame = timeline.playhead(for: target)
            // Lid speed at the target: 0 when the reading repeats (lid stopped), so the glide eases into a stop.
            let lidVelocity = (targetFrame - lastTarget) / readingInterval
            lastTarget = targetFrame
            glide(to: targetFrame, endVelocity: lidVelocity, duration: readingInterval * 1.1, now: now)
            lastSampleTime = now
            evaluate()
        }
        // Logged on every poll, including stillness and times when no overlay is visible.
        TrackingTrace.shared.record("controller_state", id: sample.id,
                                    values: [angle, renderer.tiltDegrees ?? 0, renderer.progress,
                                             isShowing ? 1 : 0, pendingShow ? 1 : 0, isEnabled ? 1 : 0,
                                             isPaused ? 1 : 0, isLivePreview ? 1 : 0])
        TrackingTrace.shared.record("controller_mapping", id: sample.id,
                                    values: [referenceAngle, endAngle, armed ? 1 : 0])
    }

    func progress(for angle: Double) -> Double {
        LidPose(angle: angle, referenceAngle: referenceAngle, endAngle: endAngle).progress
    }

    /// A fixed reference plane, followed only by actual sensor input. No sweep or timer.
    func beginLivePreview() {
        guard sensorAvailable, isEnabled, !isPaused else { return }
        if let sample = sensor.readSample() { receive(sample) }
        previewReference = angle
        isLivePreview = true
        armed = true
        TrackingTrace.shared.record("live_preview_start", values: [angle])
        evaluate()
    }

    func endLivePreview() {
        previewReference = nil
        isLivePreview = false
        TrackingTrace.shared.record("live_preview_end", values: [angle])
        evaluate()
    }

    private func evaluate() {
        if angle >= startAngle + 3 { armed = true }
        if wantsOverlay {
            minAngleSeen = min(minAngleSeen, angle)
            hideWhenSettled = false
            if isShowing { ensureDisplayLink() }
            else if !pendingShow { showOverlay() }
        } else {
            pendingShow = false
            if isShowing && !hideWhenSettled {
                // Rewind to frame 0 first; frame 0 equals the live screen, so the hide is invisible.
                hideWhenSettled = true
                glide(to: 0, endVelocity: 0, duration: 0.15, now: CACurrentMediaTime())
                ensureDisplayLink()
            }
        }
        if isShowing {
            // Frozen snapshot in use; no capture while the fold is on screen.
        } else if !active || angle > referenceAngle + prewarmDegrees + 5 && !isLivePreview {
            capturer.stop()
            hasFrame = false
        } else if !pendingShow && angle < referenceAngle + prewarmDegrees {
            Task { await capturer.start() }
        }
    }

    /// Cubic (Hermite) glide: position and speed are continuous across readings, it passes exactly through
    /// each reading, and it is clamped between start and target so it never overshoots.
    private func glide(to target: Double, endVelocity: Double, duration: Double, now: Double) {
        // Start from where the current glide is *now*, not where it was at the last vsync.
        if displayLink != nil {
            let g = glidePosition(at: now)
            playhead = g.position
            playheadVelocity = g.velocity
        }
        glideFrom = playhead
        glideFromVelocity = playheadVelocity
        glideTo = target
        // Only carry speed in the direction of travel; a reversal or a stop starts/ends at rest.
        let dir = target - playhead
        glideToVelocity = dir * endVelocity > 0 ? endVelocity : 0
        if dir * glideFromVelocity < 0 { glideFromVelocity = 0 }
        glideStart = now
        glideDuration = duration
        if isShowing { ensureDisplayLink() }
    }

    private func glidePosition(at now: Double) -> (position: Double, velocity: Double, done: Bool) {
        let T = max(glideDuration, 1e-3)
        let s = min(max((now - glideStart) / T, 0), 1)
        let s2 = s * s, s3 = s2 * s
        let p0 = glideFrom, p1 = glideTo, m0 = glideFromVelocity * T, m1 = glideToVelocity * T
        var p = (2 * s3 - 3 * s2 + 1) * p0 + (s3 - 2 * s2 + s) * m0 + (-2 * s3 + 3 * s2) * p1 + (s3 - s2) * m1
        let v = ((6 * s2 - 6 * s) * p0 + (3 * s2 - 4 * s + 1) * m0 + (-6 * s2 + 6 * s) * p1 + (3 * s2 - 2 * s) * m1) / T
        p = min(max(p, min(p0, p1)), max(p0, p1))
        return (p, s >= 1 ? 0 : v, s >= 1)
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        displayLink = overlay.metalView.displayLink(target: self, selector: #selector(displayTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let g = glidePosition(at: now)
        playhead = g.position
        playheadVelocity = g.velocity
        show(frame: Int(playhead.rounded()), now: now)
        if g.done {
            if hideWhenSettled {
                hideWhenSettled = false
                let opened = active && minAngleSeen < startAngle - 10
                hideOverlay(playSound: opened)
                return
            }
            stopDisplayLink()   // lid is still: nothing to draw until the next reading
        }
    }

    /// Draws a timeline frame. Frames are only drawn when the frame number changes.
    private func show(frame: Int, now: Double, force: Bool = false) {
        guard force || frame != shownFrame else { return }
        shownFrame = frame
        framesShownThisFold += 1
        let pose = timeline.pose(frame: frame)
        renderer.progress = pose.progress
        renderer.tiltDegrees = pose.tiltDegrees
        TrackingTrace.shared.record("timeline_frame", id: renderer.sensorSampleID,
                                    values: [Double(frame), Double(timeline.frameCount), playhead, glideTo, angle, pose.tiltDegrees])
        if hudEnabled {
            overlay.hudText = String(format: "frame %d / %d   target %.0f   sensor #%llu  %.2f°   tilt %.1f°   %.0f ms since reading   drawn this fold %d   gpu %.1f ms",
                                     frame, timeline.frameCount, glideTo.rounded(), lastSampleID, angle, pose.tiltDegrees,
                                     (now - lastSampleTime) * 1000, framesShownThisFold, renderer.gpuMs)
        }
        overlay.metalView.requestRender()
    }

    private func showOverlay() {
        guard ScreenCapturer.hasPermission() else { ScreenCapturer.requestPermission(); return }
        Task { await capturer.start() }
        if hasFrame { presentOverlay() } else { pendingShow = true }
    }

    private func presentOverlay() {
        guard wantsOverlay else { return }
        TrackingTrace.shared.record("overlay_show", values: [angle])
        isShowing = true
        renderer.resetDump()
        minAngleSeen = angle
        framesShownThisFold = 0
        foldStartTime = CACurrentMediaTime()
        // Crossing the threshold from above: frame 0 first (identical to the live screen), then glide in.
        let target = timeline.playhead(for: angle)
        playhead = target < 15 ? 0 : target
        playheadVelocity = 0
        lastTarget = playhead
        glide(to: target, endVelocity: 0, duration: 0.1, now: foldStartTime)
        show(frame: Int(playhead.rounded()), now: foldStartTime, force: true)
        // Freeze: the pending capture frame becomes the snapshot; stop capturing while the fold is up.
        capturer.stop()
        hasFrame = false
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
        overlay.show()
        ensureDisplayLink()
    }

    private func hideOverlay(playSound: Bool) {
        TrackingTrace.shared.record("overlay_hide", values: [angle, renderer.tiltDegrees ?? 0])
        dlog(String(format: "fold done: %.2fs, %d frames drawn, timeline %d frames", CACurrentMediaTime() - foldStartTime, framesShownThisFold, timeline.frameCount))
        isShowing = false
        shownFrame = -1
        playhead = 0
        playheadVelocity = 0
        lastTarget = 0
        hideWhenSettled = false
        stopDisplayLink()
        overlay.hide()
        if playSound && soundEnabled { SoundPlayer.click() }
    }

    private func userDismissed() {
        previewReference = nil
        isLivePreview = false
        armed = false
        pendingShow = false
        if isShowing { hideOverlay(playSound: false) }
        capturer.stop()
        hasFrame = false
    }
}

enum SoundPlayer {
    static func click() { NSSound(named: "Tink")?.play() }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
