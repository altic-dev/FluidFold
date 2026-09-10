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

    // Interpolation: the sensor publishes ~10 values/s; frames are drawn at display rate between them.
    // The displayed angle moves linearly from where it is to the newest reading over one sensor interval,
    // so it lands exactly on the reading and stops there. No overshoot, no settling tail.
    private(set) var displayedAngle: Double = 120
    private var interpFrom: Double = 120
    private var interpTo: Double = 120
    private var interpStart: Double = 0
    private var interpDuration: Double = 0.1
    private var lastSampleTime: Double = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var hideWhenSettled = false
    private var lastSampleID: UInt64 = 0
    private var lastFPSCheck = CACurrentMediaTime()
    private var tickCount = 0
    private var displayFPS = 0.0
    private let hudEnabled = UserDefaults.standard.bool(forKey: "debugHUD")
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
        sensor.onSample = { [weak self] sample in self?.receive(sample) }
        capturer.onFrame = { [weak self] buffer, timestamp in
            let received = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                TrackingTrace.shared.record("capture_main", values: [received])
                self.renderer.setSource(pixelBuffer: buffer, timestamp: timestamp)
                self.hasFrame = true
                if self.pendingShow {
                    self.pendingShow = false
                    if self.wantsOverlay { self.presentOverlay() }
                } else if self.isShowing {
                    // A new desktop frame never changes tilt or progress.
                    self.overlay.metalView.requestRender()
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
                if self.isShowing { Task { await self.capturer.start() } }
                self.evaluate()
            }
        }
        capturer.onStopped = { [weak self] in
            guard let self, self.wantsOverlay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.wantsOverlay else { return }
                Task { await self.capturer.start() }
            }
        }
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
            // Aim the displayed angle at the new reading over roughly one sensor interval.
            startInterpolation(to: target, duration: min(max(now - lastSampleTime, 0.04), 0.15), now: now)
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
                // Glide back to tilt 0 first; at tilt 0 the overlay equals the live screen, so the hide is invisible.
                hideWhenSettled = true
                startInterpolation(to: referenceAngle, duration: 0.12, now: CACurrentMediaTime())
                ensureDisplayLink()
            }
        }
        if !active || angle > referenceAngle + prewarmDegrees + 5 && !isLivePreview {
            capturer.stop()
            hasFrame = false
        } else if !isShowing && !pendingShow && angle < referenceAngle + prewarmDegrees {
            Task { await capturer.start() }
        }
    }

    private func startInterpolation(to target: Double, duration: Double, now: Double) {
        interpFrom = displayedAngle
        interpTo = target
        interpStart = now
        interpDuration = duration
        if isShowing { ensureDisplayLink() }
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
        let t = interpDuration > 0 ? min(max((now - interpStart) / interpDuration, 0), 1) : 1
        displayedAngle = interpFrom + (interpTo - interpFrom) * t
        applyPose(displayedAngle, now: now)
        if t >= 1 {
            if hideWhenSettled {
                hideWhenSettled = false
                let opened = active && minAngleSeen < startAngle - 10
                hideOverlay(playSound: opened)
            }
            stopDisplayLink()   // static lid: capture frames alone drive redraws
        }
    }

    /// Renders the fold for a displayed angle. The pose is a pure function of that angle.
    private func applyPose(_ shown: Double, now: Double) {
        let pose = LidPose(angle: shown, referenceAngle: referenceAngle, endAngle: endAngle)
        renderer.progress = pose.progress
        renderer.tiltDegrees = pose.tiltDegrees
        TrackingTrace.shared.record("effect_update", id: renderer.sensorSampleID,
                                    values: [shown, pose.tiltDegrees, pose.progress, referenceAngle, endAngle, angle])
        if hudEnabled { updateHUD(now: now, pose: pose) }
        overlay.metalView.requestRender()
    }

    private func updateHUD(now: Double, pose: LidPose) {
        tickCount += 1
        if now - lastFPSCheck >= 0.5 {
            displayFPS = Double(tickCount) / (now - lastFPSCheck)
            tickCount = 0; lastFPSCheck = now
        }
        overlay.hudText = String(format: "frame %llu   sensor #%llu   sensor %.2f°   shown %.2f°   behind %+.2f°   tilt %.2f°   p %.3f   %.0f ms since sample   %.0f fps   gpu %.1f ms",
                                 TrackingTrace.shared.currentFrameID, lastSampleID, angle, displayedAngle, displayedAngle - angle,
                                 pose.tiltDegrees, pose.progress, (now - lastSampleTime) * 1000, displayFPS, renderer.gpuMs)
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
        // Crossing the threshold from above: first frame at tilt 0 (identical to the live screen), then glide in.
        // Re-appearing further in (after wake or live preview): start at the real angle.
        displayedAngle = angle > referenceAngle - 3 ? referenceAngle : angle
        startInterpolation(to: angle, duration: 0.1, now: CACurrentMediaTime())
        applyPose(displayedAngle, now: CACurrentMediaTime())
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
        overlay.show()
        ensureDisplayLink()
    }

    private func hideOverlay(playSound: Bool) {
        TrackingTrace.shared.record("overlay_hide", values: [angle, renderer.tiltDegrees ?? 0])
        isShowing = false
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
