import Foundation
import AppKit
import Combine

/// The sensor owns fold position. Capture only refreshes desktop pixels at that fixed position.
@MainActor
final class EffectController: ObservableObject {
    @Published private(set) var angle: Double = 120
    @Published private(set) var isShowing = false
    @Published private(set) var isLivePreview = false
    @Published var isPaused = false { didSet { evaluate() } }
    @Published var isEnabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enabled")
            if sensorAvailable { isEnabled ? sensor.start() : sensor.stop() }
            evaluate()
        }
    }
    let sensorAvailable: Bool

    /// Things the fold does besides drawing. Each is a setting; more can be added here.
    var muteAudioWhileFolded = false { didSet { if !muteAudioWhileFolded { muter.unmute() } } }
    private let muter = AudioMuter()
    private var foldedActionsDone = false

    var startAngle: Double = 95 { didSet { evaluate() } }
    var endAngle: Double = 25 { didSet { evaluate() } }
    var prewarmDegrees: Double = 10

    let renderer: FoldRenderer
    private let sensor = LidAngleSensor()
    private var tracker = LidTracker()
    private let capturer = ScreenCapturer()
    private lazy var overlay: OverlayWindow = {
        let window = OverlayWindow(renderer: renderer)
        window.onDismiss = { [weak self] in self?.userDismissed() }
        return window
    }()
    private var armed = true
    private var minAngleSeen: Double = 180
    private var hasFrame = false
    private var pendingShow = false
    private var previewReference: Double?

    /// Degrees of lid travel per timeline frame.
    var degreesPerFrame: Double = UserDefaults.standard.double(forKey: "degreesPerFrame").nonZero ?? 0.05
    private var timeline: FoldTimeline { FoldTimeline(startAngle: referenceAngle, endAngle: endAngle, degreesPerFrame: degreesPerFrame) }

    // Playhead: the sensor publishes ~10 readings/s. Between readings the playhead glides linearly to the
    // target frame over one sensor interval, stepping through every frame in between, and stops exactly on it.
    private(set) var playhead: Double = 0
    // Delay line. The playhead plays the sensor readings `delay` seconds behind real time, linearly between
    // readings, so its speed between two readings is exactly the lid's average speed over that interval. It can
    // never pass a reading, never reverses unless the lid does, and stops exactly where the lid stopped.
    private struct Reading { var t: Double; var frame: Double }
    private var track: [Reading] = []
    /// How far behind real time the playhead runs. Sensor cadence is 100 ms; polling adds up to 17 ms.
    var delay: Double = UserDefaults.standard.double(forKey: "playheadDelayMs").nonZero.map { $0 / 1000 } ?? 0.08
    /// If the next reading is late, keep moving at the last speed for at most this fraction of a cadence, then hold.
    var maxExtrapolation: Double = UserDefaults.standard.double(forKey: "maxExtrapolation").nonZero ?? 0.35
    private var lastRawReadingTime: Double = 0
    private var lastSnappedTime: Double = 0
    private var cadence: Double = 0.1
    private var segmentEndT: Double = -1, segmentEndTangent: Double = 0
    private var glideTo: Double = 0          // latest reading's frame (the point the playhead is heading to)
    private var holdingBeyond = false        // extrapolated past the last reading and waiting
    private var shownFrame = -1
    private var lastSampleTime: Double = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var hideWhenSettled = false
    private var lastSampleID: UInt64 = 0
    private var framesShownThisFold = 0
    private var foldStartTime: Double = 0
    private let hudEnabled = UserDefaults.standard.bool(forKey: "debugHUD")
    /// Always-on per-fold smoothness report: ~/Library/Logs/FluidFold/folds.log
    let recorder = FoldRecorder()
    private let mediaPauser = MediaPauser()
    var pauseMediaWhileFolded = false
    // Start-up timing, reported with each fold.
    private var captureRequestedAt: Double?
    private var firstCaptureFrameAt: Double?
    private var captureSize = CGSize.zero
    private var wantShowAt: Double?

    /// Cold start costs a whole fold (first screenshot ~110 ms, shader and drawable pool first use, window-server
    /// surface creation). Exercise all of it once at launch with the window invisible.
    private func warmUp() {
        guard ScreenCapturer.hasPermission(), !isShowing else { return }
        prepareOverlayIfNeeded()
        takeSnapshot(reason: "warm-up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isShowing, !self.pendingShow else { return }
            for frame in [0, 400, 1000] {
                let pose = self.timeline.pose(frame: frame)
                self.renderer.progress = pose.progress
                self.renderer.tiltDegrees = pose.tiltDegrees
                self.overlay.metalView.requestRender()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isShowing, !self.pendingShow, self.captureRequestedAt == nil else { return }
                if self.overlay.isPrepared && self.angle > self.referenceAngle + self.prewarmDegrees { self.overlay.hide() }
                self.hasFrame = false
                self.lastShotAt = 0
            }
        }
    }

    /// Snapshot mode (default): one-shot screenshots while the lid moves in the pre-warm zone; no stream.
    /// Stream mode (`expStream`): the old ScreenCaptureKit stream, kept for A/B benchmarks.
    private let useStream = UserDefaults.standard.bool(forKey: "expStream")
    private var lastShotAt: Double = 0
    private var shotInFlight = false
    private var lastAngleChangeAt: Double = 0

    private func takeSnapshot(reason: String) {
        guard !shotInFlight else { return }
        shotInFlight = true
        let requested = CACurrentMediaTime()
        if captureRequestedAt == nil { captureRequestedAt = requested; firstCaptureFrameAt = nil }
        // Rect screenshots (macOS 15.2+) don't spin up a capture session, so the window server keeps our window on
        // the direct-to-display path (~13 ms to glass) instead of compositing it (~40 ms, ragged) for ~0.8 s.
        let useRect = !UserDefaults.standard.bool(forKey: "expSessionShot")
        Task { [weak self] in
            if useRect, let img = await ScreenCapturer.snapshotImage() {
                await MainActor.run {
                    guard let self else { return }
                    self.shotInFlight = false
                    self.lastShotAt = CACurrentMediaTime()
                    self.ingest(cgImage: img, timestamp: requested, received: self.lastShotAt)
                }
                return
            }
            let pb = await ScreenCapturer.snapshotPixelBuffer()
            await MainActor.run {
                guard let self else { return }
                self.shotInFlight = false
                guard let pb else { return }
                self.lastShotAt = CACurrentMediaTime()
                self.ingest(pixelBuffer: pb, timestamp: requested, received: self.lastShotAt)
            }
        }
    }

    private func ingest(cgImage: CGImage, timestamp: Double, received: Double) {
        guard !isShowing else { return }
        if firstCaptureFrameAt == nil {
            firstCaptureFrameAt = received
            captureSize = CGSize(width: cgImage.width, height: cgImage.height)
        }
        renderer.setSource(cgImage: cgImage)
        afterIngest()
    }

    /// Adopts a captured frame as the (next) snapshot. Ignored while the fold is showing (frozen picture).
    private func ingest(pixelBuffer buffer: CVPixelBuffer, timestamp: Double, received: Double) {
        guard !isShowing else { return }
        if firstCaptureFrameAt == nil {
            firstCaptureFrameAt = received
            captureSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        renderer.setSource(pixelBuffer: buffer, timestamp: timestamp)
        afterIngest()
    }

    private func afterIngest() {
        hasFrame = true
        if pendingShow {
            pendingShow = false
            if wantsOverlay { presentOverlay() }
        } else if overlay.isPrepared {
            // Keep an invisible, up-to-date frame 0 in the window so showing it is instant.
            let pose = timeline.pose(frame: 0)
            renderer.progress = pose.progress
            renderer.tiltDegrees = pose.tiltDegrees
            overlay.metalView.requestRender()
        }
    }

    private func startCapture() {
        if !useStream {
            // Refresh the snapshot while the lid is moving toward the threshold, at most every 250 ms.
            let now = CACurrentMediaTime()
            if now - lastAngleChangeAt < 0.4 && now - lastShotAt > 0.25 { takeSnapshot(reason: "prewarm") }
            if !isShowing { prepareOverlayIfNeeded() }
            return
        }
        if captureRequestedAt == nil { captureRequestedAt = CACurrentMediaTime(); firstCaptureFrameAt = nil }
        Task { await capturer.start() }
        if !isShowing {
            overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                    ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
            overlay.prepare()
        }
    }

    private func prepareOverlayIfNeeded() {
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
        overlay.prepare()
    }

    private func stopCapture() {
        if useStream { capturer.stop() }
        captureRequestedAt = nil
        firstCaptureFrameAt = nil
        if !isShowing && overlay.isPrepared { overlay.hide() }
    }


    /// Debug: while fake readings are being injected, real sensor samples are ignored.
    private var injectingUntil: Double = 0

    private var referenceAngle: Double { previewReference ?? startAngle }
    private var active: Bool { isEnabled && !isPaused && armed }
    private var wantsOverlay: Bool { active && (isLivePreview || angle < referenceAngle) }

    var trackingStatus: String {
        if !sensorAvailable { return "Sensor unavailable" }
        if !isEnabled { return "Disabled" }
        if isPaused || !armed { return "Paused" }
        if pendingShow { return "Waiting for screen capture" }
        return isShowing ? "Following lid" : "Waiting for lid movement"
    }

    init(renderer: FoldRenderer) {
        self.renderer = renderer
        renderer.debugLog = UserDefaults.standard.bool(forKey: "debugLog")
        sensorAvailable = sensor.isAvailable
        renderer.onFrameTiming = { [weak self] timing in
            guard let self else { return }
            self.recorder.frame(timing)
            if timing.presented > 0 { self.notePresentLatency(timing.presented - timing.drawStart) }
        }
        sensor.onSample = { [weak self] sample in
            guard let self, CACurrentMediaTime() >= self.injectingUntil else { return }
            self.receive(sample)
        }
        if DevHooks.enabled {
            // Dev: `tools/sweep.sh` runs a fake lid sweep in-process at the real sensor cadence (10 Hz).
            DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.FluidFold.sweep"), object: nil, queue: .main) { [weak self] note in
                let seconds = (note.object as? String).flatMap(Double.init) ?? 1.5
                self?.runFakeSweep(secondsPerDirection: seconds)
            }
            DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.FluidFold.inject"), object: nil, queue: .main) { [weak self] note in
                guard let self, let value = (note.object as? String).flatMap(Double.init) else { return }
                self.injectingUntil = CACurrentMediaTime() + 1.5
                self.receive(LidAngleSensor.Sample(id: self.lastSampleID &+ 1, time: CACurrentMediaTime(), coarse: value.rounded(), fine: value, fused: value))
            }
        }
        capturer.onFrame = { [weak self] buffer, timestamp in
            let received = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                TrackingTrace.shared.record("capture_main", values: [received])
                self.ingest(pixelBuffer: buffer, timestamp: timestamp, received: received)
            }
        }
        if let sample = sensor.readSample() {
            angle = tracker.ingest(coarse: sample.coarse, fine: sample.fine)
            renderer.sensorSampleID = sample.id
        }
        if sensorAvailable && isEnabled { sensor.start() }
        evaluate()
        if sensorAvailable { warmUp() }
        overlay.onScreensChanged = { [weak self] in self?.screensChanged() }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                TrackingTrace.shared.record("sleep")
                self?.capturer.stop()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let sample = self.sensor.readSample() { self.receive(sample) }
                TrackingTrace.shared.record("wake", values: [self.angle])
                // The snapshot survives sleep, so reopening just rewinds the timeline.
                self.evaluate()
            }
        }
        capturer.onStopped = { [weak self] in
            guard let self, self.wantsOverlay, !self.isShowing else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.wantsOverlay, !self.isShowing else { return }
                Task { await self.capturer.start() }
            }
        }
    }

    private var fakeSweepTimer: Timer?

    /// Debug: 105° → 20°, hold 1 s, → 105°. Mimics the real hinge: the sensor value changes every 100 ms,
    /// and we only see the change on our next 60 Hz poll (so readings land 100 or 117 ms apart).
    private func runFakeSweep(secondsPerDirection: Double) {
        fakeSweepTimer?.invalidate()
        // Experiment: take the snapshot this long before the readings begin (models an early pre-warm shot).
        let lead = UserDefaults.standard.double(forKey: "expShotLeadMs") / 1000
        if lead > 0 {
            takeSnapshot(reason: "sweep lead")
            DispatchQueue.main.asyncAfter(deadline: .now() + lead) { [weak self] in self?.runFakeSweepNow(secondsPerDirection: secondsPerDirection) }
            return
        }
        runFakeSweepNow(secondsPerDirection: secondsPerDirection)
    }

    private func runFakeSweepNow(secondsPerDirection: Double) {
        let start = CACurrentMediaTime()
        let move = max(secondsPerDirection, 0.2)
        func angleAt(_ t: Double) -> Double {
            if t < move { return 105 - 85 * t / move }
            if t < move + 1 { return 20 }
            return min(20 + 85 * (t - move - 1) / move, 105)
        }
        var lastValue = -1.0
        fakeSweepTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - start
            if elapsed > 2 * move + 1.5 { t.invalidate(); return }
            let sensorTime = (elapsed / 0.1).rounded(.down) * 0.1     // sensor publishes every 100 ms
            let v = (angleAt(sensorTime) * 100).rounded() / 100
            self.injectingUntil = CACurrentMediaTime() + 1.5
            guard v != lastValue else { return }
            lastValue = v
            self.receive(LidAngleSensor.Sample(id: self.lastSampleID &+ 1, time: CACurrentMediaTime(), coarse: v.rounded(), fine: v, fused: v))
        }
        RunLoop.main.add(fakeSweepTimer!, forMode: .common)
    }

    private func receive(_ sample: LidAngleSensor.Sample) {
        let target = tracker.ingest(coarse: sample.coarse, fine: sample.fine)
        TrackingTrace.shared.record("tracking_target", id: sample.id,
                                    values: [target, tracker.usingFine ? 1 : 0, tracker.configuration.fineDeadband])
        if angle != target {
            renderer.sensorSampleID = sample.id
            lastSampleID = sample.id
            let now = CACurrentMediaTime()
            lastAngleChangeAt = now
            angle = target
            let targetFrame = timeline.playhead(for: target)
            recorder.reading(now: now, angle: target, target: targetFrame)
            appendReading(frame: targetFrame, at: now)
            lastSampleTime = now
            lastSampleTime = now
            evaluate()
        }
        // Logged on every poll, including stillness and times when no overlay is visible.
        TrackingTrace.shared.record("controller_state", id: sample.id,
                                    values: [angle, renderer.tiltDegrees ?? 0, renderer.progress,
                                             isShowing ? 1 : 0, pendingShow ? 1 : 0, isEnabled ? 1 : 0,
                                             isPaused ? 1 : 0, isLivePreview ? 1 : 0])
        TrackingTrace.shared.record("controller_mapping", id: sample.id,
                                    values: [referenceAngle, endAngle, armed ? 1 : 0])
    }

    func progress(for angle: Double) -> Double {
        LidPose(angle: angle, referenceAngle: referenceAngle, endAngle: endAngle).progress
    }

    /// A fixed reference plane, followed only by actual sensor input. No sweep or timer.
    func beginLivePreview() {
        guard sensorAvailable, isEnabled, !isPaused else { return }
        if let sample = sensor.readSample() { receive(sample) }
        previewReference = angle
        isLivePreview = true
        armed = true
        TrackingTrace.shared.record("live_preview_start", values: [angle])
        evaluate()
    }

    func endLivePreview() {
        previewReference = nil
        isLivePreview = false
        TrackingTrace.shared.record("live_preview_end", values: [angle])
        evaluate()
    }

    private func evaluate() {
        if angle >= startAngle + 3 { armed = true }
        if wantsOverlay {
            minAngleSeen = min(minAngleSeen, angle)
            hideWhenSettled = false
            if isShowing { ensureDisplayLink() }
            else if !pendingShow { showOverlay() }
        } else {
            pendingShow = false
            if isShowing && !hideWhenSettled {
                // Rewind to frame 0 first; frame 0 equals the live screen, so the hide is invisible.
                hideWhenSettled = true
                if let last = track.last, last.frame > 0 { track.append(Reading(t: max(last.t + 0.1, CACurrentMediaTime() - delay + 0.05), frame: 0)) }
                glideTo = 0
                ensureDisplayLink()
            }
        }
        if isShowing {
            // Frozen snapshot in use; no capture while the fold is on screen.
        } else if !active || angle > referenceAngle + prewarmDegrees + 5 && !isLivePreview {
            stopCapture()
            hasFrame = false
        } else if !pendingShow && angle < referenceAngle + prewarmDegrees {
            startCapture()
        }
    }

    /// Adds a reading to the delay line. Timestamps are snapped to the sensor's 100 ms cadence: we poll at 60 Hz,
    /// so the same 100 ms sensor tick is seen 100 or 117 ms after the previous one; using poll times would make
    /// alternate segments 17% faster or slower than the lid.
    private func appendReading(frame: Double, at now: Double) {
        // The sensor reports on its own clock (~103 ms period, not exactly 100). Snap timestamps to a running
        // estimate of that period so polling jitter never shows up as speed changes, and resync if we drift.
        var t = now
        let gap = now - lastRawReadingTime
        if lastSnappedTime > 0 && gap > 0.07 && gap < 0.15 {
            cadence = cadence * 0.85 + gap * 0.15
            t = lastSnappedTime + cadence
            if abs(t - now) > 0.025 { t = now }
        }
        lastRawReadingTime = now
        lastSnappedTime = t
        if let last = track.last, t <= last.t { t = last.t + 0.001 }
        // If we extrapolated past the last reading and held there, start the next segment from where we are.
        if holdingBeyond, !track.isEmpty { track[track.count - 1].frame = playhead; holdingBeyond = false }
        track.append(Reading(t: t, frame: frame))
        if track.count > 64 { track.removeFirst(track.count - 64) }
        glideTo = frame
        if isShowing { ensureDisplayLink() }
    }

    /// Playhead position at wall-clock `now`, and whether it has come to rest (nothing more to play).
    private func delayedPosition(at now: Double) -> (position: Double, atRest: Bool) {
        guard let last = track.last else { return (playhead, true) }
        let tau = now - delay
        if track.count == 1 || tau <= track[0].t { return (track.count == 1 && tau >= last.t ? last.frame : track[0].frame, tau >= last.t) }
        if tau >= last.t {
            // No newer reading yet: continue at the last segment's speed briefly, then hold.
            let prev = track[track.count - 2]
            let segDur = max(last.t - prev.t, 0.001)
            let v = (last.frame - prev.frame) / segDur
            let over = min(tau - last.t, segDur * maxExtrapolation)
            if over >= segDur * maxExtrapolation { holdingBeyond = over > 0 && v != 0 }
            let p = last.frame + v * over
            return (min(max(p, 0), Double(timeline.frameCount)), tau - last.t >= segDur * maxExtrapolation)
        }
        // Inside the recorded track: monotone cubic (Fritsch–Carlson) between the two readings around tau, so the
        // speed is continuous across readings instead of stepping every 100 ms, and it never overshoots a reading.
        var i = track.count - 2
        while i > 0 && track[i].t > tau { i -= 1 }
        let a = track[i], b = track[i + 1]
        let h = max(b.t - a.t, 0.001)
        let f = (tau - a.t) / h
        let slope = (b.frame - a.frame) / h
        func tangent(_ s0: Double?, _ s1: Double) -> Double {
            guard let s0, s0 * s1 > 0 else { return s0 == nil ? s1 : 0 }
            return 2 / (1 / s0 + 1 / s1)                       // harmonic mean keeps the curve monotone
        }
        let sBefore: Double? = i > 0 ? (a.frame - track[i - 1].frame) / max(a.t - track[i - 1].t, 0.001) : nil
        // The end tangent is fixed when the segment is first played, so a reading arriving mid-segment cannot move
        // the playhead (it would otherwise jump by up to a frame).
        let m1: Double
        if segmentEndT == b.t { m1 = segmentEndTangent } else {
            let sAfter: Double? = i + 2 < track.count ? (track[i + 2].frame - b.frame) / max(track[i + 2].t - b.t, 0.001) : nil
            m1 = tangent(sAfter, slope) * h
            segmentEndT = b.t; segmentEndTangent = m1
        }
        let m0 = tangent(sBefore, slope) * h
        let f2 = f * f, f3 = f2 * f
        let p = (2 * f3 - 3 * f2 + 1) * a.frame + (f3 - 2 * f2 + f) * m0 + (-2 * f3 + 3 * f2) * b.frame + (f3 - f2) * m1
        return (p, false)
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        recorder.note(String(format: "link start @%.0f→%.0f", playhead, glideTo))
        displayLink = overlay.metalView.displayLink(target: self, selector: #selector(displayTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        if displayLink != nil { recorder.note(String(format: "link stop @%.0f→%.0f", playhead, glideTo)) }
        displayLink?.invalidate()
        displayLink = nil
    }

    private var settleWork: DispatchWorkItem?

    // Adaptive pacing. While the window server composites our window (capture session winding down, other
    // overlays), frames take ~40 ms to reach the screen and only ~2 of every 3 are shown, which reads as jitter.
    // In that state we present on every other refresh: a steady 60 instead of a ragged 80.
    private var recentLatencies: [Double] = []
    private(set) var composited = false
    private var tickParity = 0
    /// Off by default: with rect screenshots the window stays on the direct path, and in real closes the latency
    /// alternates 8/16 ms, which made this toggle flap between 60 and 120 and add cadence breaks of its own.
    private let adaptiveEnabled = UserDefaults.standard.bool(forKey: "expAdaptive")

    private func notePresentLatency(_ latency: Double) {
        recentLatencies.append(latency)
        if recentLatencies.count > 4 { recentLatencies.removeFirst() }
        guard recentLatencies.count >= 3 else { return }
        let sorted = recentLatencies.sorted()
        let median = sorted[sorted.count / 2]
        let was = composited
        // Hysteresis: direct-to-display is ~13 ms, composited ~40 ms.
        composited = was ? median > 20.0 / 1000 : median > 26.0 / 1000
        if composited != was { recorder.note(composited ? "pacing 60 (composited)" : "pacing 120 (direct)") }
    }

    /// Once the lid has been still for a moment, do the work that would stutter a moving fold.
    private func scheduleSettled() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isShowing, self.displayLink == nil else { return }
            if self.useStream && self.captureRequestedAt != nil {
                self.capturer.stop()
                self.captureRequestedAt = nil
                self.recorder.note("settled: capture stopped")
            }
            self.overlay.takeFocus()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        recorder.period = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        let d = delayedPosition(at: now)
        playhead = d.position
        recorder.tick(now: now, playhead: playhead, frame: Int(playhead.rounded()), target: glideTo)
        tickParity ^= 1
        let skip = adaptiveEnabled && composited && tickParity == 1 && !d.atRest
        if !skip { show(frame: Int(playhead.rounded()), now: now) }
        if d.atRest {
            if hideWhenSettled && playhead < 0.5 {
                hideWhenSettled = false
                hideOverlay()
                return
            }
            if hideWhenSettled {
                // Lid is above the threshold but the track hasn't reached 0 yet (e.g. the last reading is old).
                track.append(Reading(t: (track.last?.t ?? now) + 0.1, frame: 0)); holdingBeyond = false
                return
            }
            stopDisplayLink()
            scheduleSettled()
        }
    }

    /// Draws a timeline frame. Frames are only drawn when the frame number changes.
    private func show(frame: Int, now: Double, force: Bool = false) {
        guard force || frame != shownFrame else { return }
        shownFrame = frame
        updateFoldedActions(frame: frame)
        framesShownThisFold += 1
        let pose = timeline.pose(frame: frame)
        renderer.progress = pose.progress
        renderer.tiltDegrees = pose.tiltDegrees
        renderer.frameTag = frame
        TrackingTrace.shared.record("timeline_frame", id: renderer.sensorSampleID,
                                    values: [Double(frame), Double(timeline.frameCount), playhead, glideTo, angle, pose.tiltDegrees])
        if hudEnabled {
            overlay.hudText = String(format: "frame %d / %d   target %.0f   sensor #%llu  %.2f°   tilt %.1f°   %.0f ms since reading   drawn this fold %d   gpu %.1f ms",
                                     frame, timeline.frameCount, glideTo.rounded(), lastSampleID, angle, pose.tiltDegrees,
                                     (now - lastSampleTime) * 1000, framesShownThisFold, renderer.gpuMs)
        }
        overlay.metalView.requestRender()
    }

    private func showOverlay() {
        guard ScreenCapturer.hasPermission() else { return }
        wantShowAt = CACurrentMediaTime()
        if useStream {
            startCapture()
            if hasFrame { presentOverlay() } else { pendingShow = true }
        } else {
            prepareOverlayIfNeeded()
            let maxAge = UserDefaults.standard.double(forKey: "snapshotMaxAgeMs").nonZero.map { $0 / 1000 } ?? 0.5
            if hasFrame && CACurrentMediaTime() - lastShotAt < maxAge {
                presentOverlay()
            } else {
                pendingShow = true
                takeSnapshot(reason: "threshold")
            }
        }
    }

    private func presentOverlay() {
        guard wantsOverlay else { return }
        TrackingTrace.shared.record("overlay_show", values: [angle])
        isShowing = true
        renderer.resetDump()
        minAngleSeen = angle
        framesShownThisFold = 0
        foldStartTime = CACurrentMediaTime()
        recorder.begin(now: foldStartTime, timelineFrames: timeline.frameCount, degreesPerFrame: degreesPerFrame, angle: angle)
        recentLatencies.removeAll()
        composited = CACurrentMediaTime() - lastShotAt < 1.0   // a fresh capture means the compositor path for ~0.8 s
        let ms = { (t: Double?) in t.map { String(format: "%.0f", ($0 - self.foldStartTime) * 1000) } ?? "?" }
        recorder.note("\(useStream ? "stream" : "snapshot") requested \(ms(captureRequestedAt))ms, first frame \(ms(firstCaptureFrameAt))ms, snapshot age \(ms(lastShotAt))ms, threshold crossed \(ms(wantShowAt))ms, \(Int(captureSize.width))x\(Int(captureSize.height))", now: foldStartTime)
        wantShowAt = nil
        // Always start at frame 0 (identical to the live screen) and glide in, even if the first reading
        // below the threshold is already several degrees in (fast close).
        let target = timeline.playhead(for: angle)
        playhead = 0
        holdingBeyond = false
        // The reading that crossed the threshold is already in the track. Seed a frame-0 reading one cadence
        // before it so the playhead starts flat (identical to the live screen) and moves at the lid's own speed.
        if let last = track.last {
            track = [Reading(t: last.t - 0.1, frame: 0), last]
        } else {
            track = [Reading(t: foldStartTime - 0.1, frame: 0), Reading(t: foldStartTime, frame: target)]
        }
        glideTo = target
        show(frame: Int(playhead.rounded()), now: foldStartTime, force: true)
        // Freeze: capture frames are ignored from now on. Stopping the stream (or taking keyboard focus) while
        // the lid moves stutters the fold, so both happen in `settled()`, once the lid is still.
        hasFrame = false
        if useStream { capturer.setFrameRate(1) }
        overlay.metalView.renderScale = CGFloat(UserDefaults.standard.double(forKey: "renderScale").nonZero
                                                ?? (OverlayWindow.builtInScreen()?.backingScaleFactor ?? 2))
        overlay.show()
        ensureDisplayLink()
    }

    /// Actions kick in once the fold is visibly under way (the frost eases in over the first ~18°, so 20° is where
    /// the screen clearly reads as folded) and are undone when the lid comes back past 16°, or when the fold hides.
    private func updateFoldedActions(frame: Int) {
        let engageAt = min(Int(20 / degreesPerFrame), timeline.frameCount / 2)
        let releaseAt = min(Int(16 / degreesPerFrame), engageAt)
        if frame >= engageAt && !foldedActionsDone {
            foldedActionsDone = true
            if muteAudioWhileFolded { muter.mute() }
            if pauseMediaWhileFolded { mediaPauser.pause() }
        } else if foldedActionsDone && frame < releaseAt {
            foldedActionsDone = false
            muter.unmute()
            mediaPauser.resume()
        }
    }

    /// Quit while folded: restore audio so a mute never outlives the app.
    func prepareForTermination() {
        muter.unmute()
        mediaPauser.resumeBlocking()
    }

    /// Displays changed (lid clamshell, external monitor plugged/unplugged). Drop any fold in progress; the
    /// overlay re-prepares itself for the built-in display on the next zone entry.
    private func screensChanged() {
        if isShowing { userDismissed() } else { overlay.reset() }
    }

    private func hideOverlay() {
        foldedActionsDone = false
        muter.unmute()
        mediaPauser.resume()
        TrackingTrace.shared.record("overlay_hide", values: [angle, renderer.tiltDegrees ?? 0])
        dlog(String(format: "fold done: %.2fs, %d frames drawn, timeline %d frames", CACurrentMediaTime() - foldStartTime, framesShownThisFold, timeline.frameCount))
        recorder.end(at: CACurrentMediaTime())
        settleWork?.cancel()
        isShowing = false
        shownFrame = -1
        playhead = 0
        track.removeAll()
        holdingBeyond = false
        hideWhenSettled = false
        stopDisplayLink()
        overlay.hide()
    }

    private func userDismissed() {
        previewReference = nil
        isLivePreview = false
        armed = false
        pendingShow = false
        if isShowing { hideOverlay() }
        capturer.stop()
        hasFrame = false
    }
}


private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
