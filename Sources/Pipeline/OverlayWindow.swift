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
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        contentView = metalView
    }

    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } // Esc
    }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main
    }

    func show() {
        guard let screen = Self.builtInScreen() else { return }
        setFrame(screen.frame, display: true)
        makeKeyAndOrderFront(nil)
    }

    func hide() { orderOut(nil) }
}
