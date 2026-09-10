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
    private var wasClosing = false
    private var minAngleSeen: Double = 180

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        sensorAvailable = sensor.isAvailable
        sensor.onAngle = { [weak self] a in self?.angleChanged(a) }
        capturer.onFrame = { [weak self] pb in
            DispatchQueue.main.async {
                guard let self, self.isShowing else { return }
                self.renderer.setSource(pixelBuffer: pb)
                self.overlay.metalView.needsDisplay = true
            }
        }
        if let a = sensor.readAngle() { angle = a }
        sensor.start()
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
        let shouldShow = isEnabled && !isPaused && armed && a < startAngle
        if shouldShow {
            if !isShowing { showOverlay() }
            minAngleSeen = min(minAngleSeen, a)
            renderer.progress = progress(for: a)
            overlay.metalView.needsDisplay = true
        } else if isShowing {
            let opened = a >= startAngle && minAngleSeen < startAngle - 10
            hideOverlay(playSound: opened)
        }
    }

    private func showOverlay() {
        guard ScreenCapturer.hasPermission() else { ScreenCapturer.requestPermission(); return }
        isShowing = true
        minAngleSeen = angle
        renderer.clearSource()
        renderer.progress = progress(for: angle)
        overlay.show()
        Task { await capturer.start() }
    }

    private func hideOverlay(playSound: Bool) {
        guard isShowing else { return }
        isShowing = false
        capturer.stop()
        overlay.hide()
        renderer.clearSource()
        if playSound && soundEnabled { SoundPlayer.click() }
    }

    private func userDismissed() {
        armed = false
        hideOverlay(playSound: false)
    }
}

enum SoundPlayer {
    static func click() { NSSound(named: "Tink")?.play() }
}
