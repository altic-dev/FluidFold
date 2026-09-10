import Sparkle
import SwiftUI

/// Sparkle updater. Feed and public key come from Info.plist (SUFeedURL / SUPublicEDKey, set in project.yml).
@MainActor
final class Updater: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func check() { controller.updater.checkForUpdates() }
}
