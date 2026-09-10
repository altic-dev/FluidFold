import SwiftUI

@main
struct FluidFoldApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: state.controller, permissions: state.permissions, updater: state.updater)
        } label: {
            MenuBarLabel(controller: state.controller, permissions: state.permissions)
        }
        Settings {
            SettingsView().environmentObject(state)
        }
        Window("Welcome to FluidFold", id: "onboarding") {
            OnboardingView(permissions: state.permissions).environmentObject(state)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The whole menu: one toggle, Settings, Quit. A status line appears only when something needs attention.
struct MenuContent: View {
    @ObservedObject var controller: EffectController
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var updater: Updater
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !controller.sensorAvailable {
            Text("This Mac has no lid sensor")
            Divider()
        } else if !permissions.screenRecording {
            Button("Allow Screen Recording…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "onboarding")
            }
            Divider()
        }
        Toggle("Enabled", isOn: $controller.isEnabled)
            .disabled(!controller.sensorAvailable)
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
        Button("Quit FluidFold") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: EffectController
    @ObservedObject var permissions: PermissionsModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: controller.isEnabled ? MenuBarIcon.active : MenuBarIcon.paused)
            // Dev hook (scripts, screenshots): open Settings without clicking the menu.
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.altic.FluidFold.settings"))) { _ in
                guard DevHooks.enabled else { return }
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.altic.FluidFold.onboarding"))) { _ in
                guard DevHooks.enabled else { return }
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "onboarding")
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.altic.FluidFold.guide"))) { _ in
                guard DevHooks.enabled else { return }
                permissions.requestScreenRecording()
            }
            .task {
                // First run (or permission revoked): show the welcome window instead of a bare system prompt.
                if controller.sensorAvailable && !permissions.screenRecording {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                }
            }
    }
}
