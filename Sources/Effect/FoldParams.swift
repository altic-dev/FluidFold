import Foundation
import simd

/// Every tunable of the fold effect. Edit defaults here or from the Tuning panel.
/// Changing this struct: also update `FoldUniforms` in FoldEffect.metal and `uniforms(...)`.
struct FoldParams: Codable, Equatable {
    // Physical model
    var eyeDistanceMM: Double = 550      // viewer to screen, head-on
    var pointsPerMM: Double = 4.4        // 14" MacBook Pro: 1512 pt / ~344 mm
    var blurSpread: Double = 0.10        // blur px per px of glass-to-plane gap
    var darkening: Double = 0.006        // light lost per px of blur radius
    var minLight: Double = 0.25          // brightness floor
    var rampDegrees: Double = 18         // blur/darkening ease-in over the first degrees of tilt
    var maxTiltDegrees: Double = 70      // tilt at progress 1 (preview / manual mode)
    var hinge: Double = 0                // 0 = bottom edge (laptop), 1 = top
    var maxTaps: Double = 32             // blur kernel cap
    var cornerRadius: Double = 12        // glass corner radius in points, matching the display's rounded corners
    // Cosmetics
    var frost: Double = 0
    var sheen: Double = 0.25
    var vignette: Double = 0.2
    var easing: Double = 1.0             // progress exponent for preview sweeps

    static let silk = FoldParams()
    static let shade = FoldParams(blurSpread: 0.05, darkening: 0.02, minLight: 0.1, sheen: 0.05, vignette: 0.4)
    static let frost = FoldParams(blurSpread: 0.2, darkening: 0.003, minLight: 0.4, frost: 0.35, sheen: 0, vignette: 0.1)

    /// Must match the Metal struct layout (16 floats, 64 bytes).
    struct Uniforms {
        var tilt: Float
        var eyeDistance: Float
        var blurSpread: Float
        var darkening: Float
        var frost: Float
        var sheen: Float
        var vignette: Float
        var hinge: Float
        var size: SIMD2<Float>
        var progress: Float
        var time: Float
        var maxTaps: Float
        var rampTilt: Float
        var minLight: Float
        var cornerRadius: Float
    }

    /// - progress: 0..1 normalized closing progress (cosmetic terms, and tilt when `tiltDegrees` is nil).
    /// - tiltDegrees: physical degrees the lid has closed since the effect started.
    func uniforms(progress rawProgress: Double, tiltDegrees: Double?, size: CGSize, scale: Double, time: Double) -> Uniforms {
        let p = pow(min(max(rawProgress, 0), 1), easing)
        let tilt = tiltDegrees ?? (p * maxTiltDegrees)
        let pxPerMM = pointsPerMM * scale
        return Uniforms(
            tilt: Float(max(tilt, 0) * .pi / 180),
            eyeDistance: Float(eyeDistanceMM * pxPerMM),
            blurSpread: Float(blurSpread),
            darkening: Float(darkening / scale),
            frost: Float(frost),
            sheen: Float(sheen),
            vignette: Float(vignette),
            hinge: Float(hinge),
            size: SIMD2(Float(size.width), Float(size.height)),
            progress: Float(p),
            time: Float(time),
            maxTaps: Float(maxTaps),
            rampTilt: Float(rampDegrees * .pi / 180),
            minLight: Float(minLight),
            cornerRadius: Float(cornerRadius * scale)
        )
    }
}

enum FoldStyle: String, CaseIterable, Codable, Identifiable {
    case silk = "Silk", shade = "Shade", frost = "Frost"
    var id: String { rawValue }
    var preset: FoldParams {
        switch self {
        case .silk: .silk
        case .shade: .shade
        case .frost: .frost
        }
    }
}
