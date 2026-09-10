import Foundation
import SwiftUI
import ServiceManagement

/// User settings, persisted to UserDefaults, applied to the EffectController.
@MainActor
final class AppState: ObservableObject {
    let renderer = FoldRenderer()
    let controller: EffectController

    @AppStorage("style") var styleRaw: String = FoldStyle.silk.rawValue { didSet { applyParams() } }
    @AppStorage("customParams") private var customParamsJSON: String = ""
    @AppStorage("startAngle") var startAngle: Double = 95 { didSet { controller.startAngle = startAngle } }
    @AppStorage("endAngle") var endAngle: Double = 25 { didSet { controller.endAngle = endAngle } }
    @AppStorage("soundEnabled") var soundEnabled: Bool = true { didSet { controller.soundEnabled = soundEnabled } }
    @AppStorage("followSensor") var followSensor: Bool = true
    @AppStorage("manualAngle") var manualAngle: Double = 60

    /// The params actually rendered. Starts from the style preset; Tuning edits persist as custom.
    @Published var params: FoldParams = .silk { didSet { persistParams() } }

    var style: FoldStyle {
        get { FoldStyle(rawValue: styleRaw) ?? .silk }
        set { styleRaw = newValue.rawValue }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { dlog("launch at login failed: \(error)") }
            objectWillChange.send()
        }
    }

    init() {
        controller = EffectController(renderer: renderer)
        if let data = customParamsJSON.data(using: .utf8), let p = try? JSONDecoder().decode(FoldParams.self, from: data) {
            params = p
        } else {
            params = style.preset
        }
        controller.startAngle = startAngle
        controller.endAngle = endAngle
        controller.soundEnabled = soundEnabled
        renderer.params = params
        // Dev hook: `scripts/preview.sh` posts this to run the on-screen sweep without touching the lid.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.Duofy.preview"), object: nil, queue: .main) { [weak self] _ in
            self?.controller.simulateClose()
        }
    }

    private func applyParams() {
        params = style.preset
    }

    private func persistParams() {
        renderer.params = params
        if let data = try? JSONEncoder().encode(params) { customParamsJSON = String(data: data, encoding: .utf8) ?? "" }
    }

    var previewAngle: Double { followSensor ? controller.angle : manualAngle }
}
