import AppKit
import CoreGraphics
import SwiftUI

enum FluidBrand {
    static let blue = Color(red: 0.10, green: 0.46, blue: 1.0)
}

/// Screen Recording status, refreshed when the app becomes active and polled while the user is in System Settings
/// (same pattern as FluidVoice's onboarding).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @AppStorage("askedScreenRecording") private var asked = false
    private var pollTask: Task<Void, Never>?
    private var activeObserver: Any?
    private lazy var guide = ScreenRecordingGuide(isGranted: { CGPreflightScreenCaptureAccess() },
                                                  onFinished: { [weak self] in self?.refresh() })

    init() {
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let now = CGPreflightScreenCaptureAccess()
        let wasMissing = !screenRecording
        if now != screenRecording { screenRecording = now }
        if now {
            stopPolling()
            // ScreenCaptureKit only honors a new grant in a fresh process (same as FluidVoice): relaunch once.
            if wasMissing && !UserDefaults.standard.bool(forKey: "relaunchedAfterGrant") {
                UserDefaults.standard.set(true, forKey: "relaunchedAfterGrant")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.relaunch() }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "relaunchedAfterGrant")
        }
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// First time: the system prompt (it also adds FluidFold to the list). After that: System Settings.
    var actionTitle: String { "Show Guide" }

    /// Always the guided flow: the system prompt alone leaves the toggle off on macOS 15+, so users need the pane anyway.
    func requestScreenRecording() {
        dlog("requestScreenRecording")
        asked = true
        guide.begin()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<60 {                       // up to 2 minutes
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refresh() }
                if await MainActor.run(body: { self?.screenRecording ?? true }) { return }
            }
        }
    }

    private func stopPolling() { pollTask?.cancel(); pollTask = nil }
}

/// Permission row, after FluidVoice's onboarding row: status badge, title with a status pill, one-line
/// explanation, and a pill button while action is needed. `card` draws its own rounded background (onboarding);
/// `plain` relies on the surrounding grouped Form.
struct PermissionRow: View {
    enum Style { case card, plain }

    let title: String
    let subtitle: String
    let systemImage: String
    let isReady: Bool
    var readyTitle = "Ready"
    var neededTitle = "Needed"
    var actionTitle: String? = nil
    var style: Style = .plain
    var action: () -> Void = {}

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { isReady ? .green : FluidBrand.blue }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(isReady ? 0.16 : 0.12))
                Image(systemName: isReady ? "checkmark" : systemImage)
                    .font(.system(size: isReady ? 13 : 13, weight: .bold))
                    .foregroundStyle(tint.opacity(0.95))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(isReady ? readyTitle : neededTitle)
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.12)))
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isReady, let actionTitle {
                PillButton(title: actionTitle,
                           systemImage: actionTitle == "Allow" ? "hand.tap.fill" : "arrow.up.right",
                           action: action)
            }
        }
        .padding(.vertical, style == .card ? 14 : 4)
        .padding(.horizontal, style == .card ? 16 : 0)
        .background {
            if style == .card {
                shape.fill(Color.primary.opacity(isReady ? 0.035 : 0.05))
                    .overlay(shape.stroke(tint.opacity(isReady ? 0.20 : 0.28), lineWidth: 1))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isReady)
    }
}

/// Filled brand-blue capsule with FluidVoice's hover treatment (lift, glow, outer ring).
/// A real ButtonStyle so hits are handled by SwiftUI, including inside Form rows.
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        }
        .buttonStyle(PillButtonStyle())
    }
}

struct PillButtonStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let lifted = hovered && !configuration.isPressed
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                shape.fill(FluidBrand.blue.opacity(configuration.isPressed ? 0.8 : 1))
                    .overlay(shape.fill(Color.white.opacity(lifted ? 0.10 : 0)))
                    .overlay(shape.stroke(Color.white.opacity(lifted ? 0.30 : 0), lineWidth: 1))
                    .overlay(shape.stroke(FluidBrand.blue.opacity(lifted ? 0.5 : 0), lineWidth: 1.4).padding(-2))
                    .shadow(color: FluidBrand.blue.opacity(lifted ? 0.5 : 0.22), radius: lifted ? 12 : 6, y: lifted ? 4 : 2)
            )
            .contentShape(shape)
            .onHover { h in
                if reduceMotion { hovered = h } else { withAnimation(.easeOut(duration: 0.14)) { hovered = h } }
            }
    }
}

enum Permissions {
    static func openScreenRecordingSettings() {
        dlog("opening Screen Recording settings")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url, configuration: .init()) { _, error in
            if let error {
                dlog("settings URL failed: \(error); falling back to open(1)")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url.absoluteString]; try? p.run()
            }
        }
    }
}
