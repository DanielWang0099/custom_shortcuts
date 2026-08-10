import Foundation

enum AppConfiguration {
    static let bundleIdentifier = "com.susanawang.aishortcuts"
    static let keychainService = "com.susanawang.aishortcuts.openai"
    static let keychainAccount = "default"
    static let launchAgentLabel = "com.susanawang.aishortcuts"

    static var sourceKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub/japanese-practice")
            .appendingPathComponent("vocabulary-flashcard-practice/.env.local")
    }

    static var bootstrapKeyURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("bootstrap-key")
    }

    static let dataSharingSettingsURL = URL(
        string: "https://platform.openai.com/settings/organization/data-controls/sharing"
    )!
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!
}
