import SwiftUI

/// One pane for everyone. The Tuning tab (graphics development) appears only with
/// `defaults write com.altic.FluidFold developerMode -bool true`.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("developerMode") private var developerMode = false

    var body: some View {
        if developerMode {
            TabView {
                GeneralPane(controller: state.controller, permissions: state.permissions)
                    .tabItem { Label("General", systemImage: "gearshape") }
                TuningTab()
                    .tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
            }
        } else {
            GeneralPane(controller: state.controller, permissions: state.permissions)
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var controller: EffectController
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        Form {
            Section("Effect") {
                Picker("Style", selection: $state.style) {
                    ForEach(FoldStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .focusEffectDisabled()
                Slider(value: $state.params.blurSpread, in: 0...0.4) { Text("Blur") }
                Slider(value: $state.params.darkening, in: 0...0.04) { Text("Shadow") }
            }

            Section {
                Toggle("Enabled", isOn: $controller.isEnabled).toggleStyle(.switch)
                LabeledContent("Start folding at") {
                    HStack(spacing: 12) {
                        Slider(value: $state.startAngle, in: 60...115, step: 1)
                        Text("\(Int(state.startAngle))°")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                    .toggleStyle(.switch)
                Toggle("Check for updates automatically", isOn: Binding(get: { state.updater.automaticallyChecks }, set: { state.updater.automaticallyChecks = $0 }))
                    .toggleStyle(.switch)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Click the screen or press Esc to dismiss the fold until the lid is opened again.")
            }

            Section {
                Toggle("Mute audio", isOn: $state.muteAudioWhileFolded).toggleStyle(.switch)
            } header: {
                Text("While folded")
            } footer: {
                Text("Applies once the desktop is fully folded and is undone when you open the lid. A mute you set yourself is left alone.")
            }

            Section {
                PermissionRow(title: "Screen Recording",
                              subtitle: permissions.screenRecording
                                ? "FluidFold can snapshot your desktop."
                                : "Needed to fold your desktop.",
                              systemImage: "rectangle.dashed.badge.record",
                              isReady: permissions.screenRecording,
                              readyTitle: "Allowed",
                              actionTitle: permissions.actionTitle) { permissions.requestScreenRecording() }
                PermissionRow(title: "Lid sensor",
                              subtitle: controller.sensorAvailable
                                ? "Reading the hinge angle, no permission needed."
                                : "This Mac has no hinge-angle sensor.",
                              systemImage: "laptopcomputer",
                              isReady: controller.sensorAvailable,
                              readyTitle: String(format: "%.0f°", controller.angle),
                              neededTitle: "Unavailable")
            } header: {
                Text("Permissions")
            } footer: {
                Text("Your screen is processed on this Mac only. Nothing is recorded, saved, or sent.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.windowBackground)
        .safeAreaInset(edge: .top, spacing: 0) {
            FoldPreviewCard(controller: controller, permissions: permissions)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .background(.windowBackground)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("FluidFold \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                GlassButton(title: "Check for Updates") { state.updater.check() }
                GlassButton(title: "Quit FluidFold") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 460, height: 700)
    }
}

// MARK: - Signature detail: a MacBook that folds

private final class PreviewRendererState: ObservableObject {
    let renderer = FoldRenderer()
}

/// A small MacBook showing the fold on your own desktop. It loops gently on its own, and follows the real lid
/// as soon as the lid goes below the start angle.
struct FoldPreviewCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var controller: EffectController
    @ObservedObject var permissions: PermissionsModel
    @StateObject private var preview = PreviewRendererState()
    @State private var snapshot: CGImage?

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { context in
                device(progress: progress(at: context.date))
            }
            .frame(maxWidth: 300)

            Text(permissions.screenRecording ? "Close your lid to see it for real" : "Allow Screen Recording to see the preview")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: permissions.screenRecording) {
            if permissions.screenRecording { snapshot = await ScreenCapturer.snapshotImage() }
        }
    }

    private func progress(at date: Date) -> Double {
        // 5 s loop: fold most of the way, pause, unfold. Eased so it reads as a lid, not a metronome.
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5
        let wave = 0.5 - 0.5 * cos(t * 2 * .pi)
        return 0.75 * wave * wave * (3 - 2 * wave)
    }

    private func device(progress: Double) -> some View {
        VStack(spacing: 0) {
            // Screen and bezel
            ZStack {
                if snapshot != nil {
                    FoldPreviewView(renderer: preview.renderer, progress: progress, params: state.params, sourceImage: snapshot)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "rectangle.dashed").font(.title2).foregroundStyle(.tertiary))
                }
            }
            .aspectRatio(1512.0 / 982.0, contentMode: .fit)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            .padding(5)
            .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))

            // Base: a thin slab slightly wider than the lid, with the thumb notch.
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.66)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 8)
                Capsule().fill(Color(white: 0.58)).frame(width: 40, height: 3)
            }
            .padding(.horizontal, -14)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
    }
}

// MARK: - Developer: Tuning

struct TuningTab: View {
    @EnvironmentObject var state: AppState
    @State private var progress: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            MacBookPreviewAt(progress: progress).padding(.horizontal, 60).padding(.top, 12)
            TuningPanel(params: $state.params, progress: $progress, renderer: state.renderer)
        }
        .frame(width: 560, height: 640)
    }
}

/// Preview driven by an explicit progress (Tuning tab).
struct MacBookPreviewAt: View {
    @EnvironmentObject var state: AppState
    @StateObject private var preview = PreviewRendererState()
    @State private var snapshot: CGImage?
    let progress: Double

    var body: some View {
        FoldPreviewView(renderer: preview.renderer, progress: progress, params: state.params, sourceImage: snapshot)
            .aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task { if ScreenCapturer.hasPermission() { snapshot = await ScreenCapturer.snapshotImage() } }
    }
}
