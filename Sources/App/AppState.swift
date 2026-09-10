import Foundation
import SwiftUI
import AppKit
import ServiceManagement

/// User settings, persisted to UserDefaults, applied to the EffectController.
@MainActor
final class AppState: ObservableObject {
    let renderer = FoldRenderer()
    let controller: EffectController
    let permissions = PermissionsModel()

    @AppStorage("style") var styleRaw: String = FoldStyle.silk.rawValue { didSet { applyParams() } }
    @AppStorage("customParams") private var customParamsJSON: String = ""
    @AppStorage("startAngle") var startAngle: Double = 95 { didSet { controller.startAngle = startAngle } }
    @AppStorage("endAngle") var endAngle: Double = 25 { didSet { controller.endAngle = endAngle } }

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
        if UserDefaults.standard.bool(forKey: "trackingTrace") { TrackingTrace.shared.start() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.FluidFold.trace"), object: nil, queue: .main) { _ in
            TrackingTrace.shared.start()
        }
        if let data = customParamsJSON.data(using: .utf8), let p = try? JSONDecoder().decode(FoldParams.self, from: data) {
            params = p
        } else {
            params = style.preset
        }
        controller.startAngle = startAngle
        controller.endAngle = endAngle
        renderer.params = params
        // Dev hook: starts the sensor-driven live preview.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.altic.FluidFold.preview"), object: nil, queue: .main) { [weak self] _ in
            self?.controller.beginLivePreview()
        }
    }

    private func applyParams() {
        params = style.preset
    }

    private func persistParams() {
        renderer.params = params
        if let data = try? JSONEncoder().encode(params) { customParamsJSON = String(data: data, encoding: .utf8) ?? "" }
    }
}
