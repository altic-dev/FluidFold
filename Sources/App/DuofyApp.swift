import SwiftUI

@main
struct DuofyApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openSettings) private var openSettings

    init() {
        if !ScreenCapturer.hasPermission() { ScreenCapturer.requestPermission() }
    }

    var body: some Scene {
        MenuBarExtra("Duofy", systemImage: "laptopcomputer") {
            Text(state.controller.sensorAvailable
                 ? "Lid angle: \(Int(state.controller.angle))°"
                 : "No hinge sensor on this Mac")
            Divider()
            ControllerTogglesInner(controller: state.controller)
            Divider()
            Button("Preview on screen") { state.controller.simulateClose() }.keyboardShortcut("p")
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }.keyboardShortcut(",")
            Button("Quit Duofy") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

struct ControllerTogglesInner: View {
    @ObservedObject var controller: EffectController
    var body: some View {
        Toggle("Enabled", isOn: $controller.isEnabled)
        Toggle("Paused", isOn: $controller.isPaused)
    }
}
