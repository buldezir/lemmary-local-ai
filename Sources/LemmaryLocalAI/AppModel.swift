import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let modelStore = ModelStore()
    let embeddings: EmbeddingsService
    let ocr = OCRService()
    private(set) var lanAddress: String?

    /// Without this an `LSUIElement` app with no visible window is a candidate
    /// for App Nap, and a napping process answers HTTP late or not at all. It
    /// does not keep the Mac awake.
    private var activity: NSObjectProtocol?

    init() {
        embeddings = EmbeddingsService(modelStore: modelStore)
        modelStore.onInstalled = { [weak self] in self?.embeddings.restart() }
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Serving embeddings and OCR"
        )
        refreshAddress()
        ocr.start()
        embeddings.start()
    }

    func shutDown() {
        embeddings.stopAndWait()
        ocr.stopNow()
    }

    func restartAll() {
        refreshAddress()
        ocr.restart()
        embeddings.restart()
    }

    func refreshAddress() {
        lanAddress = HostInfo.lanIPv4()
    }

    var hasProblem: Bool {
        embeddings.status.isProblem || ocr.status.isProblem
    }

    /// The host Lemmary should be given: this Mac's LAN address, or loopback
    /// when the services are not reachable from other machines.
    var advertisedHost: String {
        Preferences.allowRemote ? (lanAddress ?? "127.0.0.1") : "127.0.0.1"
    }

    var embeddingsURL: String { "http://\(advertisedHost):\(Preferences.embeddingsPort)/v1" }
    var ocrURL: String { "http://\(advertisedHost):\(Preferences.ocrPort)" }
}
