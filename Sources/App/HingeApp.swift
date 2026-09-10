import SwiftUI

@main
struct HingeApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openSettings) private var openSettings

    init() {
        if !ScreenCapturer.hasPermission() { ScreenCapturer.requestPermission() }
    }

    var body: some Scene {
        MenuBarExtra {
            TrackingMenu(controller: state.controller)
            Divider()
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }.keyboardShortcut(",")
            Button("Quit Hinge") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuBarLabel(controller: state.controller)
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

struct MenuBarLabel: View {
    @ObservedObject var controller: EffectController
    var body: some View {
        // Quantize to 5° so the glyph only redraws on real movement.
        let shown = controller.sensorAvailable ? (controller.angle / 5).rounded() * 5 : 100
        Image(nsImage: MenuBarIcon.image(angleDegrees: shown, paused: controller.isPaused || !controller.isEnabled))
    }
}
