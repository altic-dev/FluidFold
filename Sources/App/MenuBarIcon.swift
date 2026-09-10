import AppKit
import SwiftUI

/// Menu bar glyph: a MacBook in side profile. The lid line follows the real hinge angle, so the icon tilts as the
/// lid closes. Template image, so it matches the system's light/dark menu bar.
enum MenuBarIcon {
    static func image(angleDegrees: Double, paused: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let stroke: CGFloat = 1.8
            NSColor.black.setStroke()
            let base = NSBezierPath()
            base.lineWidth = stroke
            base.lineCapStyle = .round
            // Base: full width, sitting near the bottom.
            let y: CGFloat = 3.5
            base.move(to: NSPoint(x: 2, y: y))
            base.line(to: NSPoint(x: 18, y: y))
            base.stroke()
            // Lid: hinged at the right end of the base. 0 = flat on the base, 90 = upright; capped so it never clips.
            let angle = max(0, min(angleDegrees, 100)) * .pi / 180
            let hinge = NSPoint(x: 16, y: y)
            let len: CGFloat = 10.5
            let tip = NSPoint(x: hinge.x - len * CGFloat(cos(angle)), y: hinge.y + len * CGFloat(sin(angle)))
            let lid = NSBezierPath()
            lid.lineWidth = stroke
            lid.lineCapStyle = .round
            lid.move(to: hinge)
            lid.line(to: tip)
            if paused { NSColor.black.withAlphaComponent(0.35).setStroke() }
            lid.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
