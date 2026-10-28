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
    /// The one port everything is reached on.
    private(set) var api: APIService!
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
                host: "127.0.0.1",
                port: HostInfo.freeLoopbackPort() ?? 0,
                contextTokens: Preferences.contextTokens
            )
            return .init(port: config.port, pidFile: Paths.llamaPIDFile(role: "embeddings", appPort: Preferences.port),
                         arguments: config.arguments, contextTokens: config.contextTokens)
        }

        let textStores = Dictionary(uniqueKeysWithValues: TextModel.allCases.map {
            ($0, ModelStore(descriptor: $0.descriptor, pathKey: Preferences.Key.textModelPath($0)))
        })
        textModelStores = textStores
        text = LlamaService(log: Paths.textModelLog, model: { textStores[Preferences.textModel]?.installedModel }) { model in
            let config = TextServerConfig(
                modelPath: model.path,
                alias: Preferences.textModel.descriptor.name,
                host: "127.0.0.1",
                port: HostInfo.freeLoopbackPort() ?? 0,
                contextTokens: Preferences.textContextTokens
            )
            return .init(port: config.port, pidFile: Paths.llamaPIDFile(role: "text", appPort: Preferences.port),
                         arguments: config.arguments, contextTokens: config.contextTokens)
        }
        api = APIService(ocr: ocr) { [weak self] in
            await MainActor.run { self?.upstreams ?? .init(embeddingsPort: nil, text: nil) }
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

    /// Where requests go now, as applied: a text model turned on in Settings
    /// but not yet applied is not served.
    private var upstreams: APIRouter.Upstreams {
        let descriptor = textModel.descriptor
        return .init(
            embeddingsPort: embeddings.listeningPort,
            embeddingsContext: embeddings.contextTokens ?? Preferences.contextTokens,
            text: textEnabled ? .init(model: descriptor.name, title: descriptor.title, port: text.listeningPort,
                                      contextTokens: text.contextTokens ?? Preferences.textContextTokens) : nil
        )
    }

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
        api.start()
    }

    func shutDown() {
        api.stop()
        embeddings.stopAndWait()
        text.stopAndWait()
        ocr.stopNow()
    }

    func restartAll() {
        refreshAddress()
        textEnabled = Preferences.textModelEnabled
        textModel = Preferences.textModel
        api.restart()
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
        api.status.isProblem || embeddings.status.isProblem || ocr.status.isProblem || (textEnabled && text.status.isProblem)
    }

    /// The host Lemmary should be given: this Mac's LAN address, or loopback
    /// when the services are not reachable from other machines.
    var advertisedHost: String {
        Preferences.allowRemote ? (lanAddress ?? "127.0.0.1") : "127.0.0.1"
    }

    /// The base URL of the one `openai` provider Lemmary needs. A `docling`
    /// provider takes the same without `/v1`.
    var apiURL: String { "http://\(advertisedHost):\(Preferences.port)/v1" }
}
