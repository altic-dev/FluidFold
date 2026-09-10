import SwiftUI
import MetalKit

/// SwiftUI wrapper around FoldMetalView. Redraws whenever progress/params/source change.
struct FoldPreviewView: NSViewRepresentable {
    let renderer: FoldRenderer
    var progress: Double
    var params: FoldParams
    var sourceImage: CGImage?

    func makeNSView(context: Context) -> FoldMetalView {
        let v = FoldMetalView(renderer: renderer)
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .foldShaderReloaded, object: nil, queue: .main) { [weak v] _ in
            v?.requestRender()
        }
        return v
    }

    func updateNSView(_ view: FoldMetalView, context: Context) {
        if let img = sourceImage, context.coordinator.lastImage !== img {
            context.coordinator.lastImage = img
            let loader = MTKTextureLoader(device: renderer.device)
            if let tex = try? loader.newTexture(cgImage: img, options: [.SRGB: false]) {
                renderer.setSource(texture: tex)
            }
        }
        renderer.params = params
        renderer.progress = progress
        view.requestRender()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var lastImage: CGImage?
        var observer: Any?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
