import SwiftUI
import AppKit

/// Developer tuning UI: one slider per FoldParams field, shader hot-reload, preset JSON copy/paste.
/// Independent of the app pipeline; bind it to any `FoldParams`.
struct TuningPanel: View {
    @Binding var params: FoldParams
    @Binding var progress: Double
    let renderer: FoldRenderer
    @State private var shaderPath: String = UserDefaults.standard.string(forKey: FoldRenderer.overridePathKey) ?? ""
    @State private var status: String = ""

    var body: some View {
        Form {
            Section("Progress") {
                slider("Progress", $progress, 0...1)
            }
            Section("Geometry") {
                slider("Max tilt °", $params.maxTiltDegrees, 0...90)
                slider("Perspective", $params.perspective, 0...1)
                slider("Shrink", $params.shrink, 0...0.5)
                slider("Drop", $params.drop, 0...0.5)
                slider("Easing", $params.easing, 0.3...3)
            }
            Section("Look") {
                slider("Blur", $params.blur, 0...1)
                slider("Max blur LOD", $params.maxBlurLod, 0...8)
                slider("Shadow", $params.shadow, 0...1)
                slider("Vignette", $params.vignette, 0...1)
                slider("Sheen", $params.sheen, 0...1)
                slider("Frost", $params.frost, 0...1)
            }
            Section("Presets") {
                HStack {
                    ForEach(FoldStyle.allCases) { style in
                        Button(style.rawValue) { params = style.preset }
                    }
                    Spacer()
                    Button("Copy JSON") { copyJSON() }
                    Button("Paste JSON") { pasteJSON() }
                }
            }
            Section("Shader (hot reload)") {
                HStack {
                    TextField("Path to FoldEffect.metal (empty = bundled)", text: $shaderPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseShader() }
                    Button("Apply") { applyShaderPath() }
                }
                Text(renderer.shaderError ?? "Shader OK. Edit the file and save; it reloads automatically.")
                    .font(.caption.monospaced())
                    .foregroundStyle(renderer.shaderError == nil ? .secondary : .red)
                    .textSelection(.enabled)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func copyJSON() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(params), let s = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            status = "Copied preset JSON"
        }
    }

    private func pasteJSON() {
        if let s = NSPasteboard.general.string(forType: .string), let data = s.data(using: .utf8),
           let p = try? JSONDecoder().decode(FoldParams.self, from: data) {
            params = p; status = "Pasted preset"
        } else { status = "Clipboard is not a FoldParams JSON" }
    }

    private func chooseShader() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "metal") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { shaderPath = url.path; applyShaderPath() }
    }

    private func applyShaderPath() {
        UserDefaults.standard.set(shaderPath.isEmpty ? nil : shaderPath, forKey: FoldRenderer.overridePathKey)
        status = renderer.reloadShader() ? "Shader reloaded" : "Shader failed: see error"
        NotificationCenter.default.post(name: .foldShaderReloaded, object: nil)
    }
}
