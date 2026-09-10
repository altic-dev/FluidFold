import Foundation
import simd

/// Every tunable of the fold effect. Edit defaults here or from the Tuning panel.
/// Changing this struct: also update `FoldUniforms` in FoldEffect.metal and `uniforms(progress:aspect:time:)`.
struct FoldParams: Codable, Equatable {
    var maxTiltDegrees: Double = 68      // tilt of the panel at progress 1
    var perspective: Double = 0.45       // 0 = flat, 1 = extreme
    var blur: Double = 0.6               // 0..1 scale of max mip level
    var shadow: Double = 0.6             // 0..1
    var frost: Double = 0                // 0..1
    var sheen: Double = 0.4              // 0..1
    var vignette: Double = 0.3           // 0..1
    var shrink: Double = 0.06            // 0..1, panel shrink at progress 1
    var drop: Double = 0.08              // 0..1, panel drop at progress 1
    var easing: Double = 1.4             // progress exponent (1 = linear)
    var maxBlurLod: Double = 5           // mip levels at blur 1

    static let silk = FoldParams()
    static let shade = FoldParams(maxTiltDegrees: 60, perspective: 0.35, blur: 0.3, shadow: 0.9, frost: 0, sheen: 0.1, vignette: 0.5)
    static let frost = FoldParams(maxTiltDegrees: 55, perspective: 0.4, blur: 1.0, shadow: 0.3, frost: 0.35, sheen: 0, vignette: 0.15)

    /// Must match the Metal struct layout (12 floats, 48 bytes).
    struct Uniforms {
        var progress: Float
        var tilt: Float
        var camDist: Float
        var blurLod: Float
        var shade: Float
        var frost: Float
        var sheen: Float
        var vignette: Float
        var scale: Float
        var yOffset: Float
        var aspect: Float
        var time: Float
    }

    func uniforms(progress rawProgress: Double, aspect: Double, time: Double) -> Uniforms {
        let p = pow(min(max(rawProgress, 0), 1), easing)
        let camDist = 1.2 + (1 - perspective) * 8.0
        return Uniforms(
            progress: Float(p),
            tilt: Float(p * maxTiltDegrees * .pi / 180),
            camDist: Float(camDist),
            blurLod: Float(p * blur * maxBlurLod),
            shade: Float(shadow),
            frost: Float(frost),
            sheen: Float(sheen),
            vignette: Float(vignette),
            scale: Float(1 - p * shrink),
            yOffset: Float(-p * drop),
            aspect: Float(aspect),
            time: Float(time)
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
