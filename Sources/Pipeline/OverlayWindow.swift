import AppKit
import MetalKit

/// Borderless window above everything on the built-in display, hosting a FoldMetalView.
/// Click or Esc calls `onDismiss`.
final class OverlayWindow: NSWindow {
    var onDismiss: (() -> Void)?
    let metalView: FoldMetalView

    init(renderer: FoldRenderer) {
        metalView = FoldMetalView(renderer: renderer)
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)   // above dictation HUDs (Wispr Flow sits at 1000); anything over us forces compositing
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        observeScreens()
        if UserDefaults.standard.bool(forKey: "debugPlainView") {
            let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.red.cgColor
            contentView = v
        } else if UserDefaults.standard.bool(forKey: "debugHUD") {
            // Metal view plus a readout strip on top (debug only).
            let container = NSView()
            container.wantsLayer = true
            metalView.translatesAutoresizingMaskIntoConstraints = false
            hudLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(metalView)
            container.addSubview(hudLabel)
            NSLayoutConstraint.activate([
                metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                metalView.topAnchor.constraint(equalTo: container.topAnchor),
                metalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hudLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                hudLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            ])
            contentView = container
        } else {
            contentView = metalView
        }
    }

    /// Debug readout (frame, sensor sample, angles). Shown only with `defaults write com.altic.FluidFold debugHUD -bool true`.
    private let hudLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        l.textColor = .white
        l.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        l.drawsBackground = true
        l.isBezeled = false
        return l
    }()

    var hudText: String = "" {
        didSet { hudLabel.stringValue = hudText }
    }

    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } // Esc
    }

    /// The MacBook's own display. Nil in clamshell mode or on a desktop: the fold only ever targets the lid's screen.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    private(set) var isPrepared = false
    var onScreensChanged: (() -> Void)?
    private var screenObserver: Any?

    /// Forget the prepared frame so the next `prepare()` re-reads the built-in display.
    func reset() {
        orderOut(nil)
        isPrepared = false
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.onScreensChanged?()
        }
    }

    /// Orders the window in invisibly and click-through, so the window server has the full-screen surface
    /// ready before the fold starts. Showing it later is then only an alpha change.
    func prepare() {
        guard !isPrepared, let screen = Self.builtInScreen() else { return }
        var f = screen.frame; if UserDefaults.standard.bool(forKey: "debugHalf") { f.size.width /= 2 }
        setFrame(f, display: false)
        alphaValue = 0
        ignoresMouseEvents = true
        orderFrontRegardless()
        isPrepared = true
    }

    func show() {
        prepare()
        alphaValue = 1
        ignoresMouseEvents = false
        metalView.requestRender()
        // Keyboard focus (for Esc) is taken later via `takeFocus()`, once the lid is still: taking it now makes
        // the app underneath redraw as inactive, which measurably stutters the first frames.
    }

    func takeFocus() {
        guard alphaValue > 0, !isKeyWindow else { return }
        makeKey()
    }

    func hide() {
        metalView.renderer.cancelPendingRender()
        alphaValue = 0
        ignoresMouseEvents = true
        orderOut(nil)
        isPrepared = false
    }
}
