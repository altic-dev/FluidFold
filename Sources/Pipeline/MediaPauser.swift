import Foundation
import MediaRemoteAdapter

/// Pauses whatever is playing when the fold starts and resumes it when the lid opens.
/// Uses the MediaRemoteAdapter bridge (a bundled dylib driven by /usr/bin/perl, the same approach as FluidVoice):
/// it can read the playback state, so we only pause what was playing and only resume what we paused.
@MainActor
final class MediaPauser {
    private struct Snapshot: Equatable, Sendable {
        let bundleIdentifier: String
        let processID: Int32
        let title: String?
        let isPlaying: Bool?
        func matches(_ o: Snapshot) -> Bool { bundleIdentifier == o.bundleIdentifier && processID == o.processID && title == o.title }
    }

    private var pausedTarget: Snapshot?
    private var generation = 0

    func pause() {
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let before = await Self.query(), before.isPlaying == true else { return }
            _ = await Self.send("pause")
            let stillWanted = await MainActor.run { () -> Bool in
                guard let self, self.generation == gen else { return false }
                self.pausedTarget = before
                dlog("media paused: \(before.bundleIdentifier) \(before.title ?? "")")
                return true
            }
            // The fold ended while the pause was in flight: undo it rather than leave media stuck.
            if !stillWanted { _ = await Self.send("play"); dlog("media pause undone (fold ended first)") }
        }
    }

    func resume() {
        generation += 1
        guard let target = pausedTarget else { return }
        pausedTarget = nil
        Task.detached(priority: .userInitiated) {
            // Only resume the same item, and only if it is still paused (the user may have pressed play or changed track).
            guard let now = await Self.query(), target.matches(now), now.isPlaying == false else { return }
            _ = await Self.send("play")
            dlog("media resumed: \(target.bundleIdentifier)")
        }
    }

    /// Quit path: the process is about to exit, so resume synchronously.
    func resumeBlocking() {
        generation += 1
        guard let target = pausedTarget else { return }
        pausedTarget = nil
        let sem = DispatchSemaphore(value: 0)
        Self.queue.async {
            if case let r = Self.run("get"), r.failure == nil, let now = Self.decode(r.output), target.matches(now), now.isPlaying == false {
                _ = Self.run("play")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
    }

    // MARK: - Bridge

    private static let queue = DispatchQueue(label: "com.altic.FluidFold.media", qos: .userInitiated)

    nonisolated private static func query() async -> Snapshot? {
        let result = await invoke("get")
        guard result.failure == nil else { return nil }
        return decode(result.output)
    }

    nonisolated private static func decode(_ output: Data) -> Snapshot? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let result = HelperResult(output: output, failure: nil)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NIL", trimmed != "null",
              let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let bundle = payload["bundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
        let pid = (payload["PID"] as? String).flatMap(Int32.init) ?? (payload["PID"] as? NSNumber)?.int32Value ?? 0
        guard pid > 0 else { return nil }
        let playing: Bool?
        if let v = payload["isPlaying"] as? Bool { playing = v }
        else if let rate = payload["playbackRate"] as? Double { playing = rate > 0 }
        else { playing = nil }
        return Snapshot(bundleIdentifier: bundle, processID: pid, title: payload["title"] as? String, isPlaying: playing)
    }

    nonisolated private static func send(_ command: String) async -> Bool {
        let result = await invoke(command)
        if let failure = result.failure { dlog("media \(command) failed: \(failure)") }
        return result.failure == nil
    }

    private struct HelperResult: Sendable { let output: Data; let failure: String? }

    nonisolated private static func invoke(_ command: String) async -> HelperResult {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: run(command)) } }
    }

    nonisolated private static func run(_ command: String) -> HelperResult {
        let framework = Bundle(for: MediaController.self)
        guard let library = framework.executablePath,
              let resourceURL = Bundle.main.url(forResource: "MediaRemoteAdapter_MediaRemoteAdapter", withExtension: "bundle"),
              let resources = Bundle(url: resourceURL),
              let script = resources.path(forResource: "run", ofType: "pl")
        else { return HelperResult(output: Data(), failure: "bridge_resources_missing") }

        // Run the shipped script unchanged. For commands, keep its run loop alive through one query before exiting
        // (as the upstream tool does) so the command is delivered before the process ends.
        let wrapper = """
        my $script = shift @ARGV;
        my $command = $ARGV[1];
        do $script;
        die $@ if $@;
        main::get() if $command eq 'pause' || $command eq 'play';
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", wrapper, script, library, command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { return HelperResult(output: Data(), failure: "launch_failed: \(error.localizedDescription)") }
        let killer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: killer)
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = killer.isCancelled == false && process.terminationReason == .uncaughtSignal
        killer.cancel()
        if timedOut { return HelperResult(output: output, failure: "helper_timeout") }
        if process.terminationStatus != 0 {
            let message = String(data: errors.prefix(300), encoding: .utf8) ?? ""
            return HelperResult(output: output, failure: "helper_exit_\(process.terminationStatus): \(message)")
        }
        return HelperResult(output: output, failure: nil)
    }
}
