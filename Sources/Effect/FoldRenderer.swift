import Foundation
import Metal
import MetalKit
import CoreVideo
import ImageIO

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
        shaderURL = Bundle.main.url(forResource: "FoldEffect", withExtension: "metal", subdirectory: "Shaders")!
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        reloadShader()
    }

    // MARK: Shader loading (bundle resource, or an on-disk override that hot-reloads on save)

    static let overridePathKey = "shaderOverridePath"

    private(set) var overrideError: String?

    var bundledShaderURL: URL {
        Bundle.main.url(forResource: "FoldEffect", withExtension: "metal", subdirectory: "Shaders")!
    }

    var overrideShaderURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.overridePathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The file actually in use (override if readable, else bundled).
    private(set) var shaderURL: URL

    @discardableResult
    func reloadShader() -> Bool {
        var source: String?
        overrideError = nil
        if let url = overrideShaderURL {
            do { source = try String(contentsOf: url, encoding: .utf8); shaderURL = url }
            catch { overrideError = "Override unreadable, using bundled shader. Pick the file with Choose… to grant access. (\(error.localizedDescription))" }
        }
        if source == nil {
            shaderURL = bundledShaderURL
            source = try? String(contentsOf: bundledShaderURL, encoding: .utf8)
        }
        do {
            let library = try device.makeLibrary(source: source ?? "", options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fold_vertex")
            desc.fragmentFunction = library.makeFunction(name: "fold_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            shaderError = nil
            dlog("shader loaded from \(shaderURL.path)")
        } catch {
            shaderError = "\(error)"
            dlog("shader compile failed: \(error)")
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

    var debugLog = false
    func draw(in view: MTKView) {
        if debugLog { dlog("draw size=\(view.drawableSize) drawable=\(view.currentDrawable != nil) pipeline=\(pipeline != nil) tex=\(mipTexture != nil) pending=\(pendingSource != nil) p=\(progress)") }
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
        if let dumpDir = debugDumpDir, progress > 0.45, progress < 0.6, !didDump {
            didDump = true
            dumpFrame(drawable.texture, commandBuffer: cmd, dir: dumpDir)
        }
        cmd.commit()
    }

    // MARK: Debug frame dump (set the `debugDumpDir` default; view must have framebufferOnly = false)

    var debugDumpDir: String? { UserDefaults.standard.string(forKey: "debugDumpDir") }
    private var didDump = false
    func resetDump() { didDump = false }

    private func dumpFrame(_ tex: MTLTexture, commandBuffer: MTLCommandBuffer, dir: String) {
        guard !tex.isFramebufferOnly else { dlog("dump skipped: framebufferOnly"); return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: tex.width, height: tex.height, mipmapped: false)
        d.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: d), let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, to: copy)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            let w = copy.width, h = copy.height, bpr = w * 4
            var bytes = [UInt8](repeating: 0, count: bpr * h)
            copy.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info.rawValue),
                  let img = ctx.makeImage() else { return }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("duofy_frame.png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                dlog("dumped frame to \(url.path)")
            }
        }
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
        framebufferOnly = renderer.debugDumpDir == nil
        layer?.backgroundColor = .black
    }
    required init(coder: NSCoder) { fatalError() }
}
