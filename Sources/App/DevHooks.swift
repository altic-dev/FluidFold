import Foundation

/// Machine-wide notification hooks used by the dev scripts. Off unless `defaults write com.altic.FluidFold developerMode -bool true`.
enum DevHooks {
    static let enabled = UserDefaults.standard.bool(forKey: "developerMode")
}
