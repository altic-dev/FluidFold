import SwiftUI

/// First-run window, shown when Screen Recording hasn't been allowed yet. Replaces the bare system prompt.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var permissions: PermissionsModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .padding(.top, 22)

            Text("Let FluidFold see your screen")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 18)

            Text("When you close the lid, FluidFold folds a snapshot of your desktop.\nIt stays on this Mac. Nothing is recorded or uploaded.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 8)

            PermissionRow(title: "Screen Recording",
                          subtitle: permissions.screenRecording
                            ? "All set. Close your lid to try it."
                            : "If macOS offers to quit and reopen FluidFold, accept.",
                          systemImage: "rectangle.dashed.badge.record",
                          isReady: permissions.screenRecording,
                          actionTitle: permissions.actionTitle,
                          style: .card) { permissions.requestScreenRecording() }
                .padding(.top, 26)

            if !permissions.screenRecording {
                Text("Already allowed it? FluidFold updates as soon as macOS confirms.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }

            Spacer(minLength: 20)

            HStack {
                Spacer()
                if permissions.screenRecording {
                    PillButton(title: "Done") { dismissWindow(id: "onboarding") }
                } else {
                    Button("Later") { dismissWindow(id: "onboarding") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
        .frame(width: 480, height: 380)
        .animation(.easeOut(duration: 0.2), value: permissions.screenRecording)
    }
}
