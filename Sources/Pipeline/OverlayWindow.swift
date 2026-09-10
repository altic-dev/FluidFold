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
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        if UserDefaults.standard.bool(forKey: "debugPlainView") {
            let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.red.cgColor
            contentView = v
        } else {
            contentView = metalView
        }
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
        var f = screen.frame; if UserDefaults.standard.bool(forKey: "debugHalf") { f.size.width /= 2 }
        setFrame(f, display: true)
        makeKeyAndOrderFront(nil)
        dlog("overlay show frame=\(frame) view=\(metalView.frame) err=\(metalView.renderer.shaderError ?? "none")")
        metalView.requestRender()
    }

    func hide() { orderOut(nil) }
}
