import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Streams the built-in display (excluding this app's own windows) as BGRA pixel buffers.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    var onStopped: (() -> Void)?
    private var stream: SCStream?
    private var starting = false
    private let queue = DispatchQueue(label: "duofy.capture", qos: .userInteractive)

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    private static func filter() async throws -> (SCContentFilter, SCDisplay) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = builtInDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Duofy", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display"])
        }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), display)
    }

    /// One-shot screenshot, used for the settings preview.
    static func snapshot() async -> CGImage? {
        guard let (filter, display) = try? await filter() else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = CGDisplayPixelsWide(display.displayID); cfg.height = CGDisplayPixelsHigh(display.displayID)
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    func start(fps: Int = 60) async {
        guard stream == nil, !starting else { return }
        starting = true
        TrackingTrace.shared.record("capture_start")
        defer { starting = false }
        guard let (filter, display) = try? await Self.filter() else { return }
        let cfg = SCStreamConfiguration()
        // Full pixel resolution so the tilt-0 frame is indistinguishable from the live screen.
        cfg.width = CGDisplayPixelsWide(display.displayID); cfg.height = CGDisplayPixelsHigh(display.displayID)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            TrackingTrace.shared.record("capture_ready")
        } catch {
            dlog("capture start failed: \(error)")
        }
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        TrackingTrace.shared.record("capture_frame", values: [CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds])
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        dlog("stream stopped: \(error)")
        self.stream = nil
        DispatchQueue.main.async { self.onStopped?() }
    }
}
