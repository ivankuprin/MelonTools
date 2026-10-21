import Foundation
import Combine
import AppKit

/// XCTest launches the real app as its test host. Unit tests must not touch
/// the live vault, gateway, Codex config, scheduler or network.
enum AppRuntime {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

/// Global app state: appearance and codex home.
@MainActor
final class AppState: ObservableObject {
    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
        }
    }
    @Published var codexHome: String {
        didSet { UserDefaults.standard.set(codexHome, forKey: "codexHome") }
    }

    init() {
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .system
        codexHome = UserDefaults.standard.string(forKey: "codexHome")
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "~/.codex"
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

    var codexHomeURL: URL { URL(fileURLWithPath: codexHome) }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
