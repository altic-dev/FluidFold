import Foundation
import AppKit

/// Records every fold end to end and writes a smoothness report, so stutter can be diagnosed from numbers.
///
/// Output (always on, bounded):
///   ~/Library/Logs/Duofy/folds.log          one report block per fold, newest last
///   ~/Library/Logs/Duofy/folds/fold-N.csv   one row per on-screen frame (last 30 folds kept)
///
/// A fold is split into three phases: start (first 300 ms), middle, end (last 300 ms).
/// Smooth means: while the playhead is moving, every display refresh shows a new frame.
/// Each missed refresh is attributed to the stage that was slow for the frame that finally appeared.
@MainActor
final class FoldRecorder {
    struct Reading { let t: Double; let angle: Double; let target: Double }
    struct Tick { let t: Double; let playhead: Double; let frame: Int; let target: Double }

    private(set) var active = false
    private var foldNumber = UserDefaults.standard.integer(forKey: "foldReportCounter")
    private var start: Double = 0
    private var frameCount = 0
    private var refresh: Double = 1.0 / 120
    /// Current display refresh period as reported by the display link (ProMotion varies it).
    var period: Double = 1.0 / 120 { didSet { periods.append((CACurrentMediaTime(), period)) } }
    private var periods: [(t: Double, p: Double)] = []
    private var readings: [Reading] = []
    private var ticks: [Tick] = []
    private var frames: [FoldRenderer.FrameTiming] = []
    private var startAngle: Double = 0
    private var degPerFrame: Double = 0.05
    private var notes: [String] = []
    private let cap = 20_000

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Duofy")

    func begin(now: Double, timelineFrames: Int, degreesPerFrame: Double, angle: Double) {
        if active { finish(at: now) }
        active = true
        start = now
        frameCount = timelineFrames
        degPerFrame = degreesPerFrame
        startAngle = angle
        let fps = Double(OverlayWindow.builtInScreen()?.maximumFramesPerSecond ?? 120)
        refresh = 1.0 / max(fps, 30)
        readings.removeAll(keepingCapacity: true)
        periods.removeAll(keepingCapacity: true)
        ticks.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        notes.removeAll()
    }

    func note(_ text: String, now: Double = CACurrentMediaTime()) {
        guard active else { return }
        notes.append(String(format: "+%.0fms %@", (now - start) * 1000, text))
    }

    func reading(now: Double, angle: Double, target: Double) {
        guard active, readings.count < cap else { return }
        readings.append(Reading(t: now, angle: angle, target: target))
    }

    func tick(now: Double, playhead: Double, frame: Int, target: Double) {
        guard active, ticks.count < cap else { return }
        ticks.append(Tick(t: now, playhead: playhead, frame: frame, target: target))
    }

    func frame(_ f: FoldRenderer.FrameTiming) {
        guard active, frames.count < cap, f.request >= start else { return }
        frames.append(f)
    }

    /// Ends the fold after in-flight frames have been presented.
    func end(at now: Double) {
        guard active else { return }
        let n = foldNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active, self.foldNumber == n else { return }
            self.finish(at: now)
        }
    }

    // MARK: Analysis

    private struct PhaseStats {
        var shown = 0, missed = 0, holds = 0, irregular = 0, moving = 0
        var maxGap = 0.0
        var causes: [String: Int] = [:]
        var summary: String {
            let c = causes.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            return String(format: "%3d frames  irregular %2d/%-3d missed %2d  holds %2d  max gap %5.1f ms%@", shown, irregular, moving, missed, holds, maxGap * 1000,
                          c.isEmpty ? "" : "  ← \(c)")
        }
    }

    private func finish(at end: Double) {
        active = false
        foldNumber += 1
        UserDefaults.standard.set(foldNumber, forKey: "foldReportCounter")
        let shown = frames.filter { $0.presented > 0 }.sorted { $0.presented < $1.presented }
        let duration = end - start
        // Refresh period in effect at time t (nearest display-link report), falling back to the panel maximum.
        func periodAt(_ t: Double) -> Double {
            var best = refresh, bestDt = Double.infinity
            for p in periods where abs(p.t - t) < bestDt { best = p.p; bestDt = abs(p.t - t) }
            return min(max(best, refresh), 1.0 / 24)
        }
        let r = refresh

        // Frame changes the playhead asked for (demand). A gap between two on-screen frames only counts as
        // stutter if a newer frame was demanded in between; an idle lid (no demand) is not stutter.
        var demandTimes: [Double] = []
        for i in ticks.indices.dropFirst() where ticks[i].frame != ticks[i - 1].frame { demandTimes.append(ticks[i].t) }
        func demands(_ prev: FoldRenderer.FrameTiming, _ f: FoldRenderer.FrameTiming) -> Int {
            demandTimes.filter { $0 > prev.request + 0.001 && $0 < f.request - 0.001 }.count
        }
        func moving(_ prev: FoldRenderer.FrameTiming, _ f: FoldRenderer.FrameTiming) -> Bool { demands(prev, f) > 0 }
        func cause(_ f: FoldRenderer.FrameTiming, prevShown: Double) -> String {
            if f.acquired - f.drawStart > r { return "drawable wait (window server)" }
            if f.gpuStart - f.acquired > r { return "GPU queue (system busy)" }
            if f.gpuEnd - f.gpuStart > r { return "GPU too slow" }
            if f.drawStart - f.request > r { return "render queue" }
            // Did the main thread tick on time? A gap in ticks means the main thread was blocked.
            let t = ticks.filter { $0.t > prevShown - 2 * r && $0.t < f.request }
            for i in t.indices.dropFirst() where t[i].t - t[i - 1].t > 1.5 * r { return "main thread late" }
            if f.request - prevShown > 1.5 * r { return "no frame requested (playhead idle)" }
            return "compositor"
        }

        var phases = [PhaseStats(), PhaseStats(), PhaseStats()]
        func phase(_ t: Double) -> Int { t - start < 0.3 ? 0 : (end - t < 0.3 ? 2 : 1) }
        var advances: [Double] = []
        var prevGap = 0.0
        var rows = ["t_ms,frame,request_ms,drawable_wait_ms,gpu_queue_ms,gpu_ms,draw_to_screen_ms,gap_ms,missed,cause"]
        for (i, f) in shown.enumerated() {
            let p = phase(f.presented)
            phases[p].shown += 1
            var gap = 0.0, missed = 0, why = ""
            if i > 0 {
                let prev = shown[i - 1]
                gap = f.presented - prev.presented
                let rp = periodAt(f.presented)
                if moving(prev, f) {
                    // Irregular = the cadence changed (e.g. 8 ms then 17 ms). A steady 60 or 120 is not irregular.
                    phases[p].moving += 1
                    if prevGap > 0 && abs(gap - prevGap) > 0.5 * rp { phases[p].irregular += 1 }
                    prevGap = gap
                } else { prevGap = 0 }
                if moving(prev, f) || (p == 0 && gap > 1.5 * rp) {
                    if demands(prev, f) >= Int((gap / rp).rounded()) - 1 || p == 0 { phases[p].maxGap = max(phases[p].maxGap, gap) }
                    if gap > 1.5 * rp {
                        // Can't miss more refreshes than new frames were asked for (an idle lid asks for none).
                        missed = min(Int((gap / rp).rounded()) - 1, max(demands(prev, f), p == 0 ? Int.max : 0))
                        phases[p].missed += missed
                        why = cause(f, prevShown: prev.presented)
                        phases[p].causes[why, default: 0] += missed
                    }
                    if f.tag == prev.tag { phases[p].holds += 1 }
                    if p == 1 { advances.append(Double(abs(f.tag - prev.tag)) / max(gap / rp, 1)) }
                }
            }
            rows.append(String(format: "%.1f,%d,%.1f,%.2f,%.2f,%.2f,%.1f,%.1f,%d,%@",
                               (f.presented - start) * 1000, f.tag, (f.request - start) * 1000,
                               (f.acquired - f.drawStart) * 1000, (f.gpuStart - f.acquired) * 1000,
                               (f.gpuEnd - f.gpuStart) * 1000, (f.presented - f.drawStart) * 1000, gap * 1000, missed, why))
        }
        let moved = advances.filter { $0 > 0 }
        let mean = moved.isEmpty ? 0 : moved.reduce(0, +) / Double(moved.count)
        let wobble = moved.count < 2 || mean == 0 ? 0 :
            (moved.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(moved.count)).squareRoot() / mean
        let lagFrames = ticks.map { abs($0.target - $0.playhead) }
        let maxWait = frames.map { $0.acquired - $0.drawStart }.max() ?? 0
        let maxQueue = frames.map { $0.gpuStart - $0.acquired }.max() ?? 0
        let maxGPU = frames.map { $0.gpuEnd - $0.gpuStart }.max() ?? 0
        let lat = shown.map { $0.presented - $0.request }.sorted()
        let p50lat = lat.isEmpty ? 0 : lat[lat.count / 2]
        let neverShown = frames.count - shown.count
        let angles = readings.map(\.angle)

        let totalIrregular = phases.map(\.irregular).reduce(0, +)
        let totalMoving = max(phases.map(\.moving).reduce(0, +), 1)
        let totalHolds = phases.map(\.holds).reduce(0, +)
        let worstGap = phases.map(\.maxGap).max() ?? 0
        let names = ["start", "middle", "end"]
        let detail = phases.indices.filter { phases[$0].irregular + phases[$0].holds > 0 }.map { i -> String in
            let top = phases[i].causes.max { $0.value < $1.value }?.key ?? "cadence"
            return "\(names[i]): \(phases[i].irregular) irregular of \(phases[i].moving), \(phases[i].holds) holds (\(top))"
        }.joined(separator: "; ")
        var verdict: String
        if totalIrregular <= 2 && totalHolds == 0 && worstGap <= 2.5 * refresh {
            verdict = "SMOOTH" + (totalIrregular > 0 ? " (\(totalIrregular) cadence blip)" : "")
        } else if Double(totalIrregular) / Double(totalMoving) <= 0.05 && totalHolds == 0 && worstGap <= 4 * refresh {
            verdict = "MINOR — " + detail
        } else {
            verdict = "STUTTER — " + detail
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var report = String(format: "fold #%d  %@  %.2f s  lid %.1f° → %.1f° → %.1f°  readings %d  on screen %d (%.0f fps)  never shown %d\n",
                            foldNumber, df.string(from: Date()), duration, startAngle, angles.min() ?? startAngle,
                            angles.last ?? startAngle, readings.count, shown.count,
                            duration > 0 ? Double(shown.count) / duration : 0, neverShown)
        report += "  start  (0–300 ms)    \(phases[0].summary)\n"
        report += "  middle               \(phases[1].summary)\n"
        report += "  end    (last 300 ms) \(phases[2].summary)\n"
        report += String(format: "  speed wobble %.0f%%   playhead lag avg %.2f° max %.2f°   request→screen p50 %.1f ms\n",
                         wobble * 100, (lagFrames.isEmpty ? 0 : lagFrames.reduce(0, +) / Double(lagFrames.count)) * degPerFrame,
                         (lagFrames.max() ?? 0) * degPerFrame, p50lat * 1000)
        report += String(format: "  worst: drawable wait %.1f ms   GPU queue %.1f ms   GPU %.1f ms\n", maxWait * 1000, maxQueue * 1000, maxGPU * 1000)
        if !notes.isEmpty { report += "  events: " + notes.joined(separator: "  ") + "\n" }
        let ps = periods.map(\.p)
        if let lo = ps.min(), let hi = ps.max() {
            report += String(format: "  display refresh during fold: %.0f–%.0f Hz\n", 1 / hi, 1 / lo)
        }
        report += "  VERDICT: \(verdict)\n\n"

        let tickRows = ["t_ms,playhead,frame,target"] + ticks.map { String(format: "%.1f,%.1f,%d,%.1f", ($0.t - start) * 1000, $0.playhead, $0.frame, $0.target) }
            + readings.map { String(format: "%.1f,READING,%.2f,%.1f", ($0.t - start) * 1000, $0.angle, $0.target) }
        write(report: report, csv: rows.joined(separator: "\n"), ticksCSV: tickRows.joined(separator: "\n"), number: foldNumber)
        dlog(report.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func write(report: String, csv: String, ticksCSV: String, number: Int) {
        let dir = Self.directory
        let folds = dir.appendingPathComponent("folds")
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folds, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("folds.log")
            if let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile(); h.write(Data(report.utf8)); try? h.close()
            } else {
                try? report.write(to: log, atomically: true, encoding: .utf8)
            }
            try? csv.write(to: folds.appendingPathComponent("fold-\(number).csv"), atomically: true, encoding: .utf8)
            try? ticksCSV.write(to: folds.appendingPathComponent("fold-\(number)-ticks.csv"), atomically: true, encoding: .utf8)
            // Keep the newest 30 per-fold CSVs.
            if let files = try? fm.contentsOfDirectory(at: folds, includingPropertiesForKeys: [.contentModificationDateKey]),
               files.count > 60 {
                let sorted = files.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                    ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                sorted.prefix(files.count - 60).forEach { try? fm.removeItem(at: $0) }
            }
        }
    }
}
