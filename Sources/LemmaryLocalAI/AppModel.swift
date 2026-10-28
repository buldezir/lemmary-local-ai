import AppKit
import Foundation
import LocalAIKit
import Observation

@MainActor
@Observable
final class AppModel {
    let modelStore = ModelStore(descriptor: .bgeM3, pathKey: Preferences.Key.modelPath)
    let textModelStores: [TextModel: ModelStore]
    let embeddings: LlamaService
    let text: LlamaService
    let ocr = OCRService()
    private(set) var lanAddress: String?
    /// The text model settings as last applied, not as the Settings window has
    /// them now: those take effect with "Apply and Restart Services".
    private(set) var textEnabled = Preferences.textModelEnabled
    private(set) var textModel = Preferences.textModel

    /// Without this an `LSUIElement` app with no visible window is a candidate
    /// for App Nap, and a napping process answers HTTP late or not at all. It
    /// does not keep the Mac awake.
    private var activity: NSObjectProtocol?

    init() {
        let embeddingsStore = modelStore
        embeddings = LlamaService(log: Paths.llamaLog, model: { embeddingsStore.installedModel }) { model in
            let config = EmbeddingsServerConfig(
                modelPath: model.path,
                host: Preferences.listenHost,
                port: Preferences.embeddingsPort,
                contextTokens: Preferences.contextTokens
            )
            return .init(port: config.port, arguments: config.arguments)
        }

        let textStores = Dictionary(uniqueKeysWithValues: TextModel.allCases.map {
            ($0, ModelStore(descriptor: $0.descriptor, pathKey: Preferences.Key.textModelPath($0)))
        })
        textModelStores = textStores
        text = LlamaService(log: Paths.textModelLog, model: { textStores[Preferences.textModel]?.installedModel }) { model in
            let config = TextServerConfig(
                modelPath: model.path,
                alias: Preferences.textModel.descriptor.name,
                host: Preferences.listenHost,
                port: Preferences.textModelPort,
                contextTokens: Preferences.textContextTokens
            )
            return .init(port: config.port, arguments: config.arguments)
        }

        modelStore.onInstalled = { [weak self] in self?.embeddings.restart() }
        for (model, store) in textStores {
            store.onInstalled = { [weak self] in
                guard let self, textEnabled, textModel == model else { return }
                text.restart()
            }
        }
    }

    var textModelStore: ModelStore { textModelStores[textModel]! }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Serving embeddings, OCR and the text model"
        )
        refreshAddress()
        ocr.start()
        embeddings.start()
        if textEnabled {
            text.start()
        }
    }

    func shutDown() {
        embeddings.stopAndWait()
        text.stopAndWait()
        ocr.stopNow()
    }

    func restartAll() {
        refreshAddress()
        textEnabled = Preferences.textModelEnabled
        textModel = Preferences.textModel
        ocr.restart()
        embeddings.restart()
        if textEnabled {
            text.restart()
        } else {
            text.stop()
        }
    }

    func refreshAddress() {
        lanAddress = HostInfo.lanIPv4()
    }

    var hasProblem: Bool {
        embeddings.status.isProblem || ocr.status.isProblem || (textEnabled && text.status.isProblem)
    }

    /// The host Lemmary should be given: this Mac's LAN address, or loopback
    /// when the services are not reachable from other machines.
    var advertisedHost: String {
        Preferences.allowRemote ? (lanAddress ?? "127.0.0.1") : "127.0.0.1"
    }

    var embeddingsURL: String { "http://\(advertisedHost):\(Preferences.embeddingsPort)/v1" }
    var ocrURL: String { "http://\(advertisedHost):\(Preferences.ocrPort)" }
    var textURL: String { "http://\(advertisedHost):\(Preferences.textModelPort)/v1" }
}
