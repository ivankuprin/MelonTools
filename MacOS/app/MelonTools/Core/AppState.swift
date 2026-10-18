import Foundation
import Combine
import AppKit

/// Global app state: appearance, fleet home path, codex home.
@MainActor
final class AppState: ObservableObject {
    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
        }
    }
    @Published var fleetHome: String {
        didSet {
            UserDefaults.standard.set(fleetHome, forKey: "fleetHome")
            AppStateLocator.shared.homePath = NSString(string: fleetHome).expandingTildeInPath
        }
    }
    @Published var codexHome: String {
        didSet { UserDefaults.standard.set(codexHome, forKey: "codexHome") }
    }

    init() {
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .system
        fleetHome = UserDefaults.standard.string(forKey: "fleetHome")
            ?? ProcessInfo.processInfo.environment["fleet_HOME"]
            ?? "~/.fleet"
        codexHome = UserDefaults.standard.string(forKey: "codexHome")
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "~/.codex"
        AppStateLocator.shared.homePath = NSString(string: fleetHome).expandingTildeInPath
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return L("System")
            case .light: return L("Light")
            case .dark: return L("Dark")
            }
        }
    }

    var fleetHomeURL: URL { URL(fileURLWithPath: fleetHome) }
    var codexHomeURL: URL { URL(fileURLWithPath: codexHome) }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
