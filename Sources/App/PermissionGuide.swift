import AppKit
import SwiftUI

/// FluidVoice's "drag the app into the list" guide, ported for Screen Recording.
/// Opens the pane, parks our window beside System Settings, floats a panel with a draggable app icon under the
/// Settings window, keeps System Settings in front, and closes itself once access is granted or Settings goes away.
@MainActor
final class ScreenRecordingGuide {
    private var requestID: UUID?
    private var panel: NSPanel?
    private var monitor: Task<Void, Never>?
    private let isGranted: () -> Bool
    private let onFinished: () -> Void

    init(isGranted: @escaping () -> Bool, onFinished: @escaping () -> Void) {
        self.isGranted = isGranted
        self.onFinished = onFinished
    }

    func begin() {
        let id = UUID()
        requestID = id
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        positionAppWindowBesideSettings(requestID: id)
        showPanel(requestID: id)
        activateSettingsSoon(requestID: id)
    }

    func cancel() {
        finish()
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        requestID = nil
        monitor?.cancel(); monitor = nil
        panel?.close(); panel = nil
        onFinished()
    }

    private var appWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && ($0.title.contains("FluidFold")) } ?? NSApp.keyWindow
    }

    // MARK: Layout around System Settings

    private func settingsWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat, w > 200, h > 200 else { continue }
            for screen in NSScreen.screens {
                let f = NSRect(x: x, y: screen.frame.maxY - y - h, width: w, height: h)
                if screen.frame.intersects(f) { return f }
            }
            return NSRect(x: x, y: (NSScreen.main?.frame.maxY ?? 0) - y - h, width: w, height: h)
        }
        return nil
    }

    private func positionAppWindowBesideSettings(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in
            guard self.requestID == requestID, let window = appWindow else { return }
            let settings = settingsWindowFrame()
            guard let screen = settings.flatMap({ f in NSScreen.screens.first { $0.frame.intersects(f) } }) ?? window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = window.frame.size
            let gap: CGFloat = 20
            var x = visible.maxX - size.width - 24
            var y = visible.midY - size.height / 2
            if let s = settings {
                if s.maxX + gap + size.width <= visible.maxX { x = s.maxX + gap }
                else if s.minX - gap - size.width >= visible.minX { x = s.minX - gap - size.width }
                y = min(visible.maxY - size.height - 16, max(visible.minY + 16, s.maxY - size.height))
            }
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: true)
            window.orderBack(nil)
        }
    }

    private func showPanel(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [self] in
            guard self.requestID == requestID else { return }
            if isGranted() { finish(); return }
            let settings = settingsWindowFrame()
            guard let screen = settings.flatMap({ f in NSScreen.screens.first { $0.frame.intersects(f) } }) ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let width = min(max((settings?.width ?? visible.width * 0.48) * 0.86, 520), 760)
            let height: CGFloat = 132
            let x: CGFloat, y: CGFloat
            if let s = settings {
                x = min(visible.maxX - width - 16, max(visible.minX + 16, s.midX - width / 2))
                y = max(visible.minY + 16, s.minY - height - 14)
            } else {
                x = visible.midX - width / 2
                y = visible.minY + 120
            }
            let frame = NSRect(x: x, y: y, width: width, height: height)
            let p = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: FloatingGuideView(
                appURL: Bundle.main.bundleURL,
                appName: "FluidFold",
                onReturnToApp: { [weak self] in self?.cancel() },
                onClose: { [weak self] in self?.cancel() }))
            p.setFrame(frame, display: true, animate: panel != nil)
            p.orderFrontRegardless()
            panel = p
            startMonitor()
            activateSettingsSoon(requestID: requestID)
        }
    }

    private func activateSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                guard self.requestID == requestID else { return }
                let apps = NSWorkspace.shared.runningApplications
                (apps.first { $0.bundleIdentifier == "com.apple.SystemSettings" }
                 ?? apps.first { $0.bundleIdentifier == "com.apple.systempreferences" }
                 ?? apps.first { $0.localizedName == "System Settings" })?.activate(options: [])
            }
        }
    }

    /// Close the guide when access is granted, or when System Settings has been gone for ~3 s.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var missing = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self else { return }
                if self.isGranted() { self.finish(); return }
                missing = self.settingsWindowFrame() == nil ? missing + 1 : 0
                if missing >= 3 { self.cancel(); return }
            }
        }
    }
}

/// The floating panel: bouncing arrow, instruction, and a draggable token carrying the app bundle URL.
struct FloatingGuideView: View {
    let appURL: URL
    let appName: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrowRaised = false
    @State private var tokenHovered = false

    private var appIcon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FluidBrand.blue)
                    .offset(y: reduceMotion ? 0 : (arrowRaised ? -8 : 4))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: arrowRaised)
                Text("Drag \(appName) into the list above, then switch it on")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).focusable(false).help("Close guide")
            }
            HStack(spacing: 12) {
                Button(action: onReturnToApp) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).focusable(false).help("Return to \(appName)")
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(appName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(tokenHovered ? 0.095 : 0.055))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(tokenHovered ? 0.16 : 0.08), lineWidth: 1)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { h in
                if reduceMotion { tokenHovered = h } else { withAnimation(.easeOut(duration: 0.14)) { tokenHovered = h } }
            }
            .onDrag { NSItemProvider(object: appURL as NSURL) }
            .accessibilityLabel("Drag \(appName) to the Screen Recording list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1)))
        .onAppear { if !reduceMotion { arrowRaised = true } }
    }
}
