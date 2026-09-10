import Foundation
import Metal
import MetalKit
import CoreVideo

/// Self-contained Metal renderer for the fold effect.
/// Inputs: a source texture (`setSource`), `params`, `progress`. Output: draws into any MTKView.
/// Nothing here knows about lids, sensors, or screen capture.
final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    var params: FoldParams = .silk
    var progress: Double = 0
    private(set) var shaderError: String?

    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var mipTexture: MTLTexture?
    private var pendingSource: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()
    private var shaderWatcher: DispatchSourceFileSystemObject?
    private var shaderFD: Int32 = -1

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        reloadShader()
    }

    // MARK: Shader loading (bundle resource, or an on-disk override that hot-reloads on save)

    static let overridePathKey = "shaderOverridePath"

    var shaderURL: URL {
        if let path = UserDefaults.standard.string(forKey: Self.overridePathKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.url(forResource: "FoldEffect", withExtension: "metal", subdirectory: "Shaders")!
    }

    @discardableResult
    func reloadShader() -> Bool {
        do {
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fold_vertex")
            desc.fragmentFunction = library.makeFunction(name: "fold_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            shaderError = nil
            NSLog("Duofy: shader loaded from \(shaderURL.path)")
        } catch {
            shaderError = "\(error)"
            NSLog("Duofy: shader compile failed: \(error)")
        }
        watchShaderFile()
        return shaderError == nil
    }

    private func watchShaderFile() {
        shaderWatcher?.cancel()
        shaderWatcher = nil
        guard shaderURL.isFileURL, !shaderURL.path.hasPrefix(Bundle.main.bundlePath) else { return }
        let fd = open(shaderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            // Editors save via rename; re-open on the next tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.reloadShader()
                NotificationCenter.default.post(name: .foldShaderReloaded, object: nil)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        shaderWatcher = src
    }

    // MARK: Sources

    /// Any texture (e.g. from MTKTextureLoader). Mipmaps are generated here.
    func setSource(texture: MTLTexture) {
        pendingSource = texture
    }

    /// BGRA pixel buffer from ScreenCaptureKit / AVFoundation.
    func setSource(pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        if let cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
            pendingSource = tex
        }
    }

    func clearSource() {
        pendingSource = nil
        mipTexture = nil
    }

    private func ensureMipTexture(like src: MTLTexture) -> MTLTexture {
        if let t = mipTexture, t.width == src.width, t.height == src.height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: src.width, height: src.height, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        mipTexture = t
        return t
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        if let src = pendingSource {
            pendingSource = nil
            let mip = ensureMipTexture(like: src)
            if let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: src.width, height: src.height, depth: 1),
                          to: mip, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                blit.generateMipmaps(for: mip)
                blit.endEncoding()
            }
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if let pipeline, let tex = mipTexture {
                var u = params.uniforms(progress: progress,
                                        aspect: Double(view.drawableSize.width / max(view.drawableSize.height, 1)),
                                        time: CACurrentMediaTime() - startTime)
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<FoldParams.Uniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<FoldParams.Uniforms>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }
}

extension Notification.Name {
    static let foldShaderReloaded = Notification.Name("FoldShaderReloaded")
}

/// Drop-in view: give it a renderer, call `setNeedsDisplay()` when progress/params/source change.
final class FoldMetalView: MTKView {
    let renderer: FoldRenderer
    init(renderer: FoldRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        delegate = renderer
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        layer?.backgroundColor = .black
    }
    required init(coder: NSCoder) { fatalError() }
}
