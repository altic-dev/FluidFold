import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            AppearanceTab().tabItem { Label("Appearance", systemImage: "sparkles") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            TuningTab().tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 620)
    }
}

/// Live MacBook mock with the fold rendered inside its screen.
struct MacBookPreview: View {
    @EnvironmentObject var state: AppState
    @State private var snapshot: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12))
                FoldPreviewView(renderer: state.renderer,
                                progress: state.controller.progress(for: state.previewAngle),
                                params: state.params,
                                sourceImage: snapshot)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
            .aspectRatio(1.6, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                .frame(height: 12)
                .padding(.horizontal, -14)
        }
        .task {
            if ScreenCapturer.hasPermission() { snapshot = await ScreenCapturer.snapshot() }
        }
        .overlay(alignment: .topTrailing) {
            if snapshot == nil {
                Text("Grant Screen Recording to see a live preview").font(.caption).padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(16)
            }
        }
    }
}

struct AppearanceTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            MacBookPreview().padding(.horizontal, 24).padding(.top, 16)
            Form {
                Picker("Style", selection: $state.style) {
                    ForEach(FoldStyle.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Follow lid sensor", isOn: $state.followSensor)
                HStack {
                    Text("Lid angle")
                    Slider(value: $state.manualAngle, in: 0...130).disabled(state.followSensor)
                    Text("\(Int(state.previewAngle))°").monospacedDigit().frame(width: 40)
                }
                HStack { Text("Perspective"); Slider(value: $state.params.perspective, in: 0...1) }
                HStack { Text("Blur"); Slider(value: $state.params.blur, in: 0...1) }
                HStack { Text("Shadow"); Slider(value: $state.params.shadow, in: 0...1) }
            }
            .formStyle(.grouped)
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Trigger") {
                HStack { Text("Start below"); Slider(value: $state.startAngle, in: 40...120); Text("\(Int(state.startAngle))°").frame(width: 40) }
                HStack { Text("Fully folded at"); Slider(value: $state.endAngle, in: 0...60); Text("\(Int(state.endAngle))°").frame(width: 40) }
                Text("Click the screen or press Esc to pause until the lid is reopened.").font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Soft click when the lid opens", isOn: $state.soundEnabled)
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                ControllerTogglesInner(controller: state.controller)
            }
            Section("Permissions") {
                HStack {
                    Text(ScreenCapturer.hasPermission() ? "Screen Recording: granted" : "Screen Recording: not granted")
                    Spacer()
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                Text("Frames are processed locally. Nothing is recorded, saved, or uploaded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sensor") {
                Text(state.controller.sensorAvailable ? "Hinge sensor: \(Int(state.controller.angle))°" : "Hinge sensor not found")
            }
        }
        .formStyle(.grouped)
    }
}

struct TuningTab: View {
    @EnvironmentObject var state: AppState
    @State private var progress: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            MacBookPreviewAt(progress: progress).padding(.horizontal, 60).padding(.top, 12)
            TuningPanel(params: $state.params, progress: $progress, renderer: state.renderer)
        }
    }
}

/// Preview driven by an explicit progress (Tuning tab).
struct MacBookPreviewAt: View {
    @EnvironmentObject var state: AppState
    @State private var snapshot: CGImage?
    let progress: Double

    var body: some View {
        FoldPreviewView(renderer: state.renderer, progress: progress, params: state.params, sourceImage: snapshot)
            .aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task { if ScreenCapturer.hasPermission() { snapshot = await ScreenCapturer.snapshot() } }
    }
}
