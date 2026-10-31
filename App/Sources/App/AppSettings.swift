import DoCore
import Foundation
import MageVL
import Observation

enum ScreenshotDetail: String, CaseIterable, Identifiable {
    /// Matches the model's training resolution (1920×1080 worth of pixels).
    case standard
    /// Fewer visual tokens: noticeably faster on base-model Macs, slightly less precise clicks.
    case fast
    /// Native point resolution up to the checkpoint's 4 MP ceiling.
    case full

    var id: String { rawValue }

    var maxPixels: Int? {
        switch self {
        case .standard: 1920 * 1080
        case .fast: 1280 * 800
        case .full: nil
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Faster"
        case .full: "Maximum"
        }
    }
}

enum IslandStylePreference: String, CaseIterable, Identifiable {
    case automatic, notch, dynamicIsland, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .notch: "Notch"
        case .dynamicIsland: "Dynamic Island"
        case .floating: "Floating pill"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var approvalMode: CommandApprovalMode {
        didSet { defaults.set(approvalMode.rawValue, forKey: "approvalMode") }
    }
    var screenshotDetail: ScreenshotDetail {
        didSet { defaults.set(screenshotDetail.rawValue, forKey: "screenshotDetail") }
    }
    var deterministic: Bool {
        didSet { defaults.set(deterministic, forKey: "deterministic") }
    }
    var islandStyle: IslandStylePreference {
        didSet { defaults.set(islandStyle.rawValue, forKey: "islandStyle") }
    }
    var translateShortcuts: Bool {
        didSet { defaults.set(translateShortcuts, forKey: "translateShortcuts") }
    }
    var maxSteps: Int {
        didSet { defaults.set(maxSteps, forKey: "maxSteps") }
    }
    /// Unload the model after this many idle minutes (0 = keep loaded).
    var unloadAfterMinutes: Int {
        didSet { defaults.set(unloadAfterMinutes, forKey: "unloadAfterMinutes") }
    }

    init() {
        approvalMode = defaults.string(forKey: "approvalMode").flatMap(CommandApprovalMode.init) ?? .risky
        screenshotDetail = defaults.string(forKey: "screenshotDetail").flatMap(ScreenshotDetail.init) ?? .standard
        deterministic = defaults.object(forKey: "deterministic") as? Bool ?? false
        islandStyle = defaults.string(forKey: "islandStyle").flatMap(IslandStylePreference.init) ?? .automatic
        translateShortcuts = defaults.object(forKey: "translateShortcuts") as? Bool ?? true
        maxSteps = defaults.object(forKey: "maxSteps") as? Int ?? 50
        unloadAfterMinutes = defaults.object(forKey: "unloadAfterMinutes") as? Int ?? 15
    }

    var runtimeOptions: MageVLRuntime.Options {
        var options = MageVLRuntime.Options()
        options.maxImagePixels = screenshotDetail.maxPixels
        if deterministic { options.temperature = 0 }
        return options
    }

    var sessionConfiguration: AgentSession.Configuration {
        var configuration = AgentSession.Configuration()
        configuration.maxSteps = max(5, min(maxSteps, 100))
        configuration.history.maxSteps = configuration.maxSteps
        return configuration
    }

    var environmentConfiguration: MacEnvironment.Configuration {
        var configuration = MacEnvironment.Configuration()
        configuration.translateLinuxShortcuts = translateShortcuts
        return configuration
    }
}
