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
            angle = target
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
            if isShowing { applySensorPose() }
            else if !pendingShow { showOverlay() }
        } else {
            pendingShow = false
            if isShowing {
                let opened = active && minAngleSeen < startAngle - 10
                hideOverlay(playSound: opened)
            }
        }
        if !active || angle > referenceAngle + prewarmDegrees + 5 && !isLivePreview {
            capturer.stop()
            hasFrame = false
        } else if !isShowing && !pendingShow && angle < referenceAngle + prewarmDegrees {
            Task { await capturer.start() }
        }
    }

    /// No integration, velocity, easing, prediction, or elapsed-time input can advance the fold.
    private func applySensorPose() {
        let pose = LidPose(angle: angle, referenceAngle: referenceAngle, endAngle: endAngle)
        renderer.progress = pose.progress
        renderer.tiltDegrees = pose.tiltDegrees
        TrackingTrace.shared.record("effect_update", id: renderer.sensorSampleID,
                                    values: [angle, pose.tiltDegrees, pose.progress, referenceAngle, endAngle])
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
        applySensorPose()
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
        overlay.show()
    }

    private func hideOverlay(playSound: Bool) {
        TrackingTrace.shared.record("overlay_hide", values: [angle, renderer.tiltDegrees ?? 0])
        isShowing = false
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
