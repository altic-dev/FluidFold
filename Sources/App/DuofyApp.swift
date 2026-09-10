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
            TrackingMenu(controller: state.controller)
            Divider()
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

struct TrackingMenu: View {
    @ObservedObject var controller: EffectController

    var body: some View {
        Text(controller.sensorAvailable ? String(format: "Lid angle: %.2f°", controller.angle) : "No hinge sensor on this Mac")
        Text(controller.trackingStatus)
        Divider()
        ControllerTogglesInner(controller: controller)
        Divider()
        Button(controller.isLivePreview ? "End live lid preview" : "Live lid preview") {
            if controller.isLivePreview { controller.endLivePreview() }
            else { controller.beginLivePreview() }
        }
        .keyboardShortcut("p")
        .disabled(!controller.sensorAvailable || !controller.isEnabled || controller.isPaused)
    }
}
