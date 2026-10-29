import Foundation
import LocalAIKit
import ServiceManagement
import os

/// The app's settings. The keys are shared with the Settings view, which binds
/// to them with `@AppStorage`; this type is how the services read them.
///
/// Any of them can be overridden for one run from the command line, which is
/// how a second copy is tested next to a running one:
/// `LemmaryLocalAI -Port 18080`.
@MainActor
enum Preferences {
    enum Key {
        static let port = "Port"
        /// The OCR port before everything moved to one; only read to carry a
        /// changed value over.
        static let legacyOCRPort = "OCRPort"
        static let allowRemote = "AllowRemote"
        static let modelPath = "ModelPath"
        static let contextTokens = "ContextTokens"
        static let parallelConversions = "ParallelConversions"
        /// The OCR model used last, which is the one loaded at launch.
        static let ocrModel = "OCRModel"
        static let pageTimeout = "PageTimeout"
        static let textModelEnabled = "TextModelEnabled"
        static let textModel = "TextModel"
        static let textContextTokens = "TextContextTokens"

        /// One per model, so switching between them keeps each one's file.
        static func textModelPath(_ model: TextModel) -> String {
            "TextModelPath-\(model.rawValue)"
        }
    }

    /// 5001 is the docling port Lemmary's guide uses, so a Lemmary already
    /// pointed at it keeps its OCR when everything moves there.
    static func registerDefaults() {
        carryOverOCRPort()
        UserDefaults.standard.register(defaults: [
            Key.port: 5001,
            Key.allowRemote: true,
            Key.modelPath: "",
            Key.contextTokens: 8192,
            // One worker: a second doubled the memory for the few times two
            // documents arrive together.
            Key.parallelConversions: 1,
            Key.ocrModel: OCRModel.appleVision.rawValue,
            Key.pageTimeout: 60,
            Key.textModelEnabled: false,
            Key.textModel: TextModel.gemma4E4B.rawValue,
            Key.textContextTokens: 16384,
        ])
    }

    /// A changed OCR port becomes the one port, since that is where Lemmary's
    /// docling provider already points. Only a saved value: one given on the
    /// command line is for that run.
    private static func carryOverOCRPort() {
        guard let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:)),
              domain[Key.port] == nil, let old = domain[Key.legacyOCRPort] as? Int else { return }
        UserDefaults.standard.set(old, forKey: Key.port)
    }

    /// Every service is on this one port; the llama-servers behind it are on
    /// loopback ports of their own.
    static var port: Int { validPort(Key.port) }

    /// On by default: Lemmary runs on another machine and reaches this one over
    /// the LAN. Off binds every service to 127.0.0.1.
    static var allowRemote: Bool { UserDefaults.standard.bool(forKey: Key.allowRemote) }
    static var listenHost: String { allowRemote ? "0.0.0.0" : "127.0.0.1" }

    static var contextTokens: Int { max(512, UserDefaults.standard.integer(forKey: Key.contextTokens)) }
    static var parallelConversions: Int { max(1, UserDefaults.standard.integer(forKey: Key.parallelConversions)) }
    static var pageTimeout: TimeInterval { TimeInterval(max(10, UserDefaults.standard.integer(forKey: Key.pageTimeout))) }
    /// Set by the OCR service each time it loads a model, not by Settings. A
    /// copy running from `.build` shares the installed app's settings, so it
    /// leaves the installed app's choice alone.
    static var ocrModel: OCRModel {
        get { UserDefaults.standard.string(forKey: Key.ocrModel).flatMap(OCRModel.init(rawValue:)) ?? .appleVision }
        set {
            guard !isRunningFromBuildDirectory else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.ocrModel)
        }
    }

    /// Off by default: it costs 6 to 19 GB of memory, and Lemmary can extract
    /// metadata with a hosted model instead.
    static var textModelEnabled: Bool { UserDefaults.standard.bool(forKey: Key.textModelEnabled) }
    static var textModel: TextModel {
        TextModel.resolve(UserDefaults.standard.string(forKey: Key.textModel), physicalMemory: physicalMemory)
    }
    /// Decides which text models Settings offers.
    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    static var textContextTokens: Int { max(4096, UserDefaults.standard.integer(forKey: Key.textContextTokens)) }

    private static func validPort(_ key: String) -> Int {
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
