import Foundation
import Metal
import MetalKit
import QuartzCore
import AppKit
import CoreVideo
import ImageIO

/// Self-contained Metal renderer for the fold effect.
/// Inputs: a source texture (`setSource`), `params`, `progress`. Output: draws into any MTKView.
/// Nothing here knows about lids, sensors, or screen capture.
final class FoldRenderer: NSObject {
    let device: MTLDevice
    var params: FoldParams = .silk
    var progress: Double = 0
    /// Physical degrees closed since the effect started. nil = derive from progress (preview).
    var tiltDegrees: Double?
    var sensorSampleID: UInt64 = 0
    /// Caller's label for the next frame (the timeline frame number). Carried into `FrameTiming`.
    var frameTag: Int = 0

    /// Per-frame timings, delivered on the main queue once the frame has been presented (or discarded).
    struct FrameTiming {
        let tag: Int
        let request: Double        // render(into:) called
        let drawStart: Double      // encode started (render queue)
        let acquired: Double       // nextDrawable returned
        var gpuStart: Double = 0
        var gpuEnd: Double = 0
        var presented: Double = 0  // 0 = never shown
    }
    var onFrameTiming: ((FrameTiming) -> Void)?
    private let timingLock = NSLock()
    private var partialTimings: [UInt64: (timing: FrameTiming, gpuDone: Bool, presentDone: Bool)] = [:]

    private func updateTiming(_ id: UInt64, _ change: (inout FrameTiming) -> Void, gpu: Bool = false, present: Bool = false) {
        timingLock.lock()
        guard var entry = partialTimings[id] else { timingLock.unlock(); return }
        change(&entry.timing)
        if gpu { entry.gpuDone = true }
        if present { entry.presentDone = true }
        let finished = entry.gpuDone && entry.presentDone
        if finished { partialTimings[id] = nil } else { partialTimings[id] = entry }
        timingLock.unlock()
        if finished, let cb = onFrameTiming {
            let t = entry.timing
            DispatchQueue.main.async { cb(t) }
        }
    }
    private var sourceTimestamp: Double = 0
    /// Points-per-pixel scale of the target (2 on Retina). Set by the view.
    var contentsScale: Double = 2
    private(set) var shaderError: String?

    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var mipTexture: MTLTexture?
    private var pendingSource: MTLTexture?
    private var pendingRetain: [Any] = []   // keeps CVPixelBuffer/CVMetalTexture alive until the GPU copy finishes
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()
    /// One encode/GPU submission at a time; a single pending request always uses the newest inputs.
    private let inflight = DispatchSemaphore(value: max(1, min(3, UserDefaults.standard.integer(forKey: "expInflight").nonZeroOr(3))))
    private let renderQueue = DispatchQueue(label: "hinge.render", qos: .userInteractive)
    private var pendingLayer: CAMetalLayer?
    private(set) var droppedFrames = 0
    private var fpsCount = 0
    private var fpsWindowStart = CACurrentMediaTime()
    /// Rolling frames-per-second of completed renders (for the Tuning panel / logs).
    private(set) var measuredFPS: Double = 0
    private(set) var gpuMs: Double = 0
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

    /// CGImage source (one-shot screenshots). Uploaded synchronously (~10 ms at 3024x1964).
    func setSource(cgImage: CGImage) {
        let loader = MTKTextureLoader(device: device)
        if let tex = try? loader.newTexture(cgImage: cgImage, options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]) {
            pendingSource = tex
            pendingRetain = []
        }
    }

    /// BGRA pixel buffer from ScreenCaptureKit / AVFoundation.
    func setSource(pixelBuffer: CVPixelBuffer, timestamp: Double = 0) {
        guard let cache = textureCache else { return }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        if let cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
            pendingSource = tex
            sourceTimestamp = timestamp
            pendingRetain = [pixelBuffer, cvTex]
        }
    }

    func clearSource() {
        pendingSource = nil
        pendingRetain = []
        sourceTimestamp = 0
        renderQueue.async { [weak self] in self?.mipTexture = nil }
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

    // MARK: Rendering

    private struct FrameInput {
        let frameID: UInt64
        let sampleID: UInt64
        let params: FoldParams
        let progress: Double
        let tiltDegrees: Double?
        let pipeline: MTLRenderPipelineState?
        let source: MTLTexture?
        let retain: [Any]
        let sourceTimestamp: Double
        let scale: Double
        let dumpDir: String?
        let tag: Int
        let request: Double
    }

    var debugLog = false
    func render(into layer: CAMetalLayer) {
        guard layer.drawableSize.width > 0 else { return }
        guard inflight.wait(timeout: .now()) == .success else {
            pendingLayer = layer
            droppedFrames += 1
            TrackingTrace.shared.record("render_dropped", values: [Double(sensorSampleID)])
            return
        }
        let frameID = TrackingTrace.shared.nextFrameID()
        let dumpDir = !didDump && progress > 0.45 && progress < 0.6 ? debugDumpDir : nil
        if dumpDir != nil { didDump = true }
        let input = FrameInput(frameID: frameID, sampleID: sensorSampleID, params: params,
                               progress: progress, tiltDegrees: tiltDegrees, pipeline: pipeline,
                               source: pendingSource, retain: pendingRetain, sourceTimestamp: sourceTimestamp,
                               scale: Double(layer.contentsScale), dumpDir: dumpDir,
                               tag: frameTag, request: CACurrentMediaTime())
        pendingSource = nil
        pendingRetain = []
        TrackingTrace.shared.record("render_request", id: frameID, values: [Double(sensorSampleID)])
        renderQueue.async { [self] in encode(into: layer, input: input) }
    }

    /// Main-thread inputs are immutable snapshots. Drawable acquisition never blocks sensor delivery.
    private func encode(into layer: CAMetalLayer, input: FrameInput) {
        let drawStart = CACurrentMediaTime()
        let frameID = input.frameID
        let sampleID = input.sampleID
        let params = input.params
        let progress = input.progress
        let tiltDegrees = input.tiltDegrees
        let pipeline = input.pipeline
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else {
            inflight.signal()
            TrackingTrace.shared.record("drawable_failure", id: frameID)
            DispatchQueue.main.async { [weak self] in self?.renderPendingFrame() }
            return
        }
        if onFrameTiming != nil {
            timingLock.lock()
            partialTimings[frameID] = (FrameTiming(tag: input.tag, request: input.request, drawStart: drawStart,
                                                   acquired: CACurrentMediaTime()), false, false)
            timingLock.unlock()
        }
        TrackingTrace.shared.record("draw", id: frameID, time: drawStart,
                                    values: [Double(sampleID), CACurrentMediaTime(), tiltDegrees ?? -1, progress,
                                             input.sourceTimestamp, Double(drawable.texture.width), Double(drawable.texture.height)])
        let permit = inflight
        // Slots are released when the GPU finishes. The caller renders at most once per display refresh, so we
        // never queue frames faster than the screen shows them. (Releasing on presentation instead can lose the
        // final frame: if the compositor discards a frame, the retry tied to its presentation never happens.)
        drawable.addPresentedHandler { [weak self] surface in
            let shown = surface.presentedTime
            self?.updateTiming(frameID, { $0.presented = shown }, present: true)
            TrackingTrace.shared.record("presented", id: frameID,
                                        values: [Double(sampleID), surface.presentedTime])
        }
        cmd.addCompletedHandler { [weak self] cb in
            permit.signal()
            DispatchQueue.main.async { [weak self] in self?.renderPendingFrame() }
            let gs = cb.gpuStartTime, ge = cb.gpuEndTime
            self?.updateTiming(frameID, { $0.gpuStart = gs; $0.gpuEnd = ge }, gpu: true)
            TrackingTrace.shared.record("gpu", id: frameID,
                                        values: [Double(sampleID), cb.gpuStartTime, cb.gpuEndTime, Double(cb.status.rawValue)])
        }
        cmd.addCompletedHandler { [weak self] cb in
            let duration = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            let completed = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fpsCount += 1
                self.gpuMs = duration
                if completed - self.fpsWindowStart >= 1 {
                    self.measuredFPS = Double(self.fpsCount) / (completed - self.fpsWindowStart)
                    self.fpsCount = 0; self.fpsWindowStart = completed
                    if self.debugLog { dlog("fps=\(Int(self.measuredFPS)) dropped=\(self.droppedFrames) gpu=\(String(format: "%.1f", self.gpuMs))ms") }
                }
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].storeAction = .store
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)

        if let src = input.source {
            let retain = input.retain
            cmd.addCompletedHandler { _ in _ = retain }
            let mip = ensureMipTexture(like: src)
            if let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: src.width, height: src.height, depth: 1),
                          to: mip, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                blit.generateMipmaps(for: mip)
                blit.endEncoding()
            }
        }

        pass.colorAttachments[0].loadAction = .clear
        let clearOnly = UserDefaults.standard.bool(forKey: "debugClearOnly")
        pass.colorAttachments[0].clearColor = clearOnly ? MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1) : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if !clearOnly, let pipeline, let tex = mipTexture {
                var u = params.uniforms(progress: progress, tiltDegrees: tiltDegrees, size: drawableSize,
                                        scale: input.scale, time: CACurrentMediaTime() - startTime)
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<FoldParams.Uniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<FoldParams.Uniforms>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }
        cmd.present(drawable)
        if let dumpDir = input.dumpDir {
            dumpFrame(drawable.texture, commandBuffer: cmd, dir: dumpDir)
        }
        TrackingTrace.shared.record("commit", id: frameID, values: [Double(sampleID)])
        cmd.commit()
    }

    func cancelPendingRender() { pendingLayer = nil }

    private func renderPendingFrame() {
        guard let layer = pendingLayer else { return }
        pendingLayer = nil
        render(into: layer)
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
            let url = URL(fileURLWithPath: dir).appendingPathComponent("hinge_frame.png")
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

/// Drop-in view backed by a CAMetalLayer. Call `requestRender()` whenever progress/params/source change.
final class FoldMetalView: NSView {
    let renderer: FoldRenderer

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        l.pixelFormat = .bgra8Unorm
        l.maximumDrawableCount = max(2, min(3, UserDefaults.standard.integer(forKey: "expDrawables").nonZeroOr(3)))
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        l.framebufferOnly = renderer.debugDumpDir == nil
        return l
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.requestRender() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// Render scale relative to points. 1 = non-Retina (4x cheaper than 2), fine for a blurred, tilted picture.
    var renderScale: CGFloat = 1 { didSet { updateDrawableSize() } }

    private func updateDrawableSize() {
        let scale = renderScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        requestRender()
    }

    /// Renders now. Callers paced by a display link should call this once per tick.
    func requestRender() {
        guard window?.isVisible == true else { return }
        renderer.render(into: metalLayer)
    }
}

private extension Int {
    func nonZeroOr(_ d: Int) -> Int { self == 0 ? d : self }
}
