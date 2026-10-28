import Foundation
import LocalAIKit
import ServiceManagement
import os

/// The app's settings. The keys are shared with the Settings view, which binds
/// to them with `@AppStorage`; this type is how the services read them.
///
/// Any of them can be overridden for one run from the command line, which is
/// how a second copy is tested next to a running one:
/// `LemmaryLocalAI -EmbeddingsPort 18080 -OCRPort 15001`.
@MainActor
enum Preferences {
    enum Key {
        static let embeddingsPort = "EmbeddingsPort"
        static let ocrPort = "OCRPort"
        static let allowRemote = "AllowRemote"
        static let modelPath = "ModelPath"
        static let contextTokens = "ContextTokens"
        static let parallelConversions = "ParallelConversions"
        static let pageTimeout = "PageTimeout"
        static let textModelEnabled = "TextModelEnabled"
        static let textModel = "TextModel"
        static let textModelPort = "TextModelPort"
        static let textContextTokens = "TextContextTokens"

        /// One per model, so switching between them keeps each one's file.
        static func textModelPath(_ model: TextModel) -> String {
            "TextModelPath-\(model.rawValue)"
        }
    }

    /// The ports are the ones Lemmary's guide uses, so moving from the
    /// LaunchAgent setup to the app changes nothing on Lemmary's side.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.embeddingsPort: 8080,
            Key.ocrPort: 5001,
            Key.allowRemote: true,
            Key.modelPath: "",
            Key.contextTokens: 8192,
            Key.parallelConversions: 2,
            Key.pageTimeout: 60,
            Key.textModelEnabled: false,
            Key.textModel: TextModel.gemma4E4B.rawValue,
            Key.textModelPort: 8081,
            Key.textContextTokens: 16384,
        ])
    }

    static var embeddingsPort: Int { port(Key.embeddingsPort) }
    static var ocrPort: Int { port(Key.ocrPort) }
    static var textModelPort: Int { port(Key.textModelPort) }

    /// On by default: Lemmary runs on another machine and reaches this one over
    /// the LAN. Off binds every service to 127.0.0.1.
    static var allowRemote: Bool { UserDefaults.standard.bool(forKey: Key.allowRemote) }
    static var listenHost: String { allowRemote ? "0.0.0.0" : "127.0.0.1" }

    static var contextTokens: Int { max(512, UserDefaults.standard.integer(forKey: Key.contextTokens)) }
    static var parallelConversions: Int { max(1, UserDefaults.standard.integer(forKey: Key.parallelConversions)) }
    static var pageTimeout: TimeInterval { TimeInterval(max(10, UserDefaults.standard.integer(forKey: Key.pageTimeout))) }

    /// Off by default: it costs 5 to 6 GB of memory, and Lemmary can extract
    /// metadata with a hosted model instead.
    static var textModelEnabled: Bool { UserDefaults.standard.bool(forKey: Key.textModelEnabled) }
    static var textModel: TextModel {
        TextModel(rawValue: UserDefaults.standard.string(forKey: Key.textModel) ?? "") ?? .gemma4E4B
    }
    static var textContextTokens: Int { max(4096, UserDefaults.standard.integer(forKey: Key.textContextTokens)) }

    private static func port(_ key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return (1...65535).contains(value) ? value : 0
    }

    // MARK: - launch at login

    /// Reflects the real registration rather than a stored bool: the user can
    /// remove a login item in System Settings.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.app.error("launch at login \(newValue): \(String(describing: error))")
            }
        }
    }

    /// `SMAppService` registers the bundle that is running, so a debug build out
    /// of `.build` would pin itself as the login item.
    static var isRunningFromBuildDirectory: Bool {
        Bundle.main.bundleURL.pathComponents.contains(".build")
    }
}

extension Logger {
    static let app = Logger(subsystem: "eu.buldezir.lemmary-local-ai", category: "app")
}
