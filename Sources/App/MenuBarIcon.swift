import AppKit
import SwiftUI

/// Menu bar glyph: the app logo's two slabs (lid over base) meeting at a hinge in a "<". Template image, so it
/// matches the system's light/dark menu bar.
enum MenuBarIcon {
    static let active = image(paused: false)
    static let paused = image(paused: true)

    private static let size = NSSize(width: 18, height: 16)
    /// Inner corner of the "<", where the two slabs meet.
    private static let hinge = CGPoint(x: 6.6, y: 7.1)
    /// Half of the opening between the slabs, matching the logo.
    private static let half: CGFloat = 26 * .pi / 180
    private static let crease: CGFloat = 1.3

    /// Slab outlines in a local frame: x runs along the slab away from the hinge, y points away from the other slab.
    private static let lid = [CGPoint(x: -5.6, y: 0), CGPoint(x: 7.2, y: 0), CGPoint(x: 9.5, y: 4.2), CGPoint(x: -3.4, y: 4.2)]
    private static let base = [CGPoint(x: -4.4, y: 0), CGPoint(x: 8.3, y: 0), CGPoint(x: 6.8, y: 4.1), CGPoint(x: -2.5, y: 4.1)]

    private static func image(paused: Bool) -> NSImage {
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let toHinge = CGAffineTransform(translationX: hinge.x, y: hinge.y)
            let lidPath = roundedPolygon(lid, radius: 1.0, transform: CGAffineTransform(rotationAngle: half).concatenating(toHinge))
            let basePath = roundedPolygon(base, radius: 1.2,
                                          transform: CGAffineTransform(scaleX: 1, y: -1).rotated(by: half).concatenating(toHinge))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(basePath)
            ctx.fillPath()
            // Clear the lid plus a thin gap around it, so it reads as a separate slab lying over the base
            // (and the base never shows through the dimmed lid when paused).
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(crease)
            ctx.addPath(lidPath)
            ctx.drawPath(using: .fillStroke)
            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor.black.withAlphaComponent(paused ? 0.35 : 1).cgColor)
            ctx.addPath(lidPath)
            ctx.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat, transform: CGAffineTransform) -> CGPath {
        let pts = points.map { $0.applying(transform) }
        let path = CGMutablePath()
        let last = pts[pts.count - 1]
        path.move(to: CGPoint(x: (last.x + pts[0].x) / 2, y: (last.y + pts[0].y) / 2))
        for i in pts.indices {
            path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}
