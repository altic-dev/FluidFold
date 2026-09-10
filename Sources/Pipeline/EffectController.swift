import Foundation
import AppKit
import Combine

/// Glues sensor → capture → overlay → renderer. The only place that maps lid angle to effect progress.
@MainActor
final class EffectController: ObservableObject {
    @Published private(set) var angle: Double = 120
    @Published private(set) var isShowing = false
    @Published var isPaused = false { didSet { if isPaused { hideOverlay(playSound: false) } } }
    @Published var isEnabled = true { didSet { if !isEnabled { hideOverlay(playSound: false) } } }
    let sensorAvailable: Bool

    /// Effect begins below this angle and is complete at `endAngle`.
    var startAngle: Double = 95 { didSet { evaluate() } }
    var endAngle: Double = 25 { didSet { evaluate() } }
    var soundEnabled = true

    let renderer: FoldRenderer
    private let sensor = LidAngleSensor()
    private let capturer = ScreenCapturer()
    private lazy var overlay: OverlayWindow = {
        let w = OverlayWindow(renderer: renderer)
        w.onDismiss = { [weak self] in self?.userDismissed() }
        return w
    }()
    private var armed = true
    private var minAngleSeen: Double = 180
    /// Smoothed angle driving the render; the sensor is quantized to whole degrees at ~30 Hz.
    private var smoothedAngle: Double = 120
    private var angleVelocity: Double = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime = CACurrentMediaTime()
    var smoothing: Double = 40   // spring stiffness-ish; higher = snappier
    /// Start capturing this many degrees before the effect threshold so the first overlay frame is ready.
    var prewarmDegrees: Double = 10
    private var hasFrame = false
    private var pendingShow = false
    private var settlingToHide = false

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        renderer.debugLog = UserDefaults.standard.bool(forKey: "debugLog")
        sensorAvailable = sensor.isAvailable
        sensor.onAngle = { [weak self] a in self?.angleChanged(a) }
        capturer.onFrame = { [weak self] pb in
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderer.setSource(pixelBuffer: pb)
                self.hasFrame = true
                if self.pendingShow { self.pendingShow = false; self.presentOverlay() }
                // Rendering is paced by the display link; frames only update the source texture.
            }
        }
        if let a = sensor.readAngle() { angle = a }
        sensor.start()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hideOverlay(playSound: false)
                self?.capturer.stop(); self?.hasFrame = false
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let a = self.sensor.readAngle() { self.angle = a }
            self.evaluate()
        }
    }

    func progress(for angle: Double) -> Double {
        min(max((startAngle - angle) / max(startAngle - endAngle, 1), 0), 1)
    }

    private var simulationTimer: Timer?

    private func angleChanged(_ a: Double) {
        guard simulationTimer == nil else { return }
        angle = a
        evaluate()
    }

    /// Sweeps a fake lid angle closed and back open. Lets you see the real overlay without touching the lid.
    func simulateClose(duration: TimeInterval = 3) {
        simulationTimer?.invalidate()
        let start = Date()
        let top = startAngle + 5
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let x = Date().timeIntervalSince(start) / duration
            if x >= 1 {
                t.invalidate(); self.simulationTimer = nil
                self.angle = self.sensor.readAngle() ?? top
            } else {
                // 0 → 1 → 0 with a pause at the bottom
                let k = x < 0.4 ? x / 0.4 : (x < 0.6 ? 1 : 1 - (x - 0.6) / 0.4)
                self.angle = top - k * (top - self.endAngle)
            }
            self.evaluate()
        }
    }

    private func evaluate() {
        let a = angle
        // Re-arm after a pause once the lid is opened past the start angle.
        if a >= startAngle + 3 { armed = true }
        let active = isEnabled && !isPaused && armed
        // Pre-warm the capture stream just above the threshold so frames are flowing before we show.
        if active && !isShowing && !pendingShow {
            if a < startAngle + prewarmDegrees { Task { await capturer.start() } }
            else if a > startAngle + prewarmDegrees + 5 { capturer.stop(); hasFrame = false }
        }
        let shouldShow = active && a < startAngle
        if shouldShow {
            settlingToHide = false
            if !isShowing && !pendingShow { showOverlay() }
            minAngleSeen = min(minAngleSeen, a)
        } else if isShowing {
            // Let the spring return to tilt 0 first; at tilt 0 the overlay equals the live screen, so hiding is seamless.
            settlingToHide = true
        } else if pendingShow {
            pendingShow = false
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) { tick() }

    /// Critically damped spring toward the sensor angle, then render.
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrameTime, 1.0 / 20)
        lastFrameTime = now
        let k = smoothing
        let accel = k * k * (angle - smoothedAngle) - 2 * k * angleVelocity
        angleVelocity += accel * dt
        smoothedAngle += angleVelocity * dt
        if settlingToHide && (smoothedAngle >= startAngle - 0.3 || abs(angle - smoothedAngle) < 0.05 && angleVelocity.magnitude < 0.5) {
            let opened = minAngleSeen < startAngle - 10
            hideOverlay(playSound: opened)
            return
        }
        applyAngle(smoothedAngle)
    }

    private func applyAngle(_ a: Double) {
        renderer.progress = progress(for: a)
        renderer.tiltDegrees = max(startAngle - a, 0)
        overlay.metalView.requestRender()
    }

    private func showOverlay() {
        guard ScreenCapturer.hasPermission() else { ScreenCapturer.requestPermission(); return }
        Task { await capturer.start() }
        if hasFrame { presentOverlay() } else { pendingShow = true }
    }

    /// Called once a capture frame exists: the first overlay frame is the live desktop at tilt 0, so nothing pops.
    private func presentOverlay() {
        isShowing = true
        settlingToHide = false
        renderer.resetDump()
        minAngleSeen = angle
        smoothedAngle = startAngle
        angleVelocity = 0
        applyAngle(smoothedAngle)
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero ?? (overlay.screen?.backingScaleFactor ?? 2))
        overlay.show()
        lastFrameTime = CACurrentMediaTime()
        displayLink = overlay.metalView.displayLink(target: self, selector: #selector(displayTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func hideOverlay(playSound: Bool) {
        guard isShowing else { return }
        isShowing = false
        settlingToHide = false
        displayLink?.invalidate(); displayLink = nil
        overlay.hide()
        // Keep the stream warm; evaluate() stops it once the lid is well above the threshold.
        if playSound && soundEnabled { SoundPlayer.click() }
    }

    private func userDismissed() {
        armed = false
        hideOverlay(playSound: false)
        capturer.stop(); hasFrame = false
    }
}

enum SoundPlayer {
    static func click() { NSSound(named: "Tink")?.play() }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
