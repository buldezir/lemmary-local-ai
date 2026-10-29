import Foundation
import LocalAIKit
import Observation

/// The app's one port: everything Lemmary asks for, through one `openai`
/// provider or the `docling` and `local` provider types. Embeddings and the text
/// model are forwarded to their llama-servers on loopback; OCR is answered here.
@MainActor
@Observable
final class APIService {
    private(set) var status: ServiceStatus = .stopped
    private(set) var port: Int = 0

    private let upstreams: @Sendable () async -> APIRouter.Upstreams
    private let ocr: OCRService
    private var server: HTTPServer?
    private var backoff = Backoff()
    private var retryTask: Task<Void, Never>?

    /// `upstreams` says, at every request, where the llama-servers are now.
    init(ocr: OCRService, upstreams: @escaping @Sendable () async -> APIRouter.Upstreams) {
        self.ocr = ocr
        self.upstreams = upstreams
    }

    func start() {
        guard server == nil else { return }
        retryTask?.cancel()

        let ocr = self.ocr
        let converter = DeferredConverter { await MainActor.run { ocr.converter } }
        let record: @Sendable (ConversionEvent) -> Void = { ocr.record($0) }
        let router = APIRouter(
            docling: DoclingEndpoint(
                converter: converter,
                isReady: { await MainActor.run { ocr.status == .ready } },
                uploadDirectory: Paths.uploads,
                version: AppInfo.version,
                onConversion: record
            ),
            ocr: OCRChatEndpoint(converter: converter, uploadDirectory: Paths.uploads, onConversion: record),
            embeddingsModel: ModelDescriptor.bgeM3.name,
            upstreams: upstreams
        )
        let port = Preferences.port
        let server = HTTPServer(
            configuration: .init(port: UInt16(port), loopbackOnly: !Preferences.allowRemote),
            handler: { await router.handle($0) },
            onStateChange: { [weak self] state in
                Task { @MainActor in self?.serverChanged(state) }
            }
        )
        do {
            try server.start()
        } catch {
            fail("Could not open port \(port): \(error.localizedDescription)")
            return
        }
        self.server = server
        self.port = port
        status = .starting("Opening port \(port)")
    }

    func stop() {
        retryTask?.cancel()
        server?.stop()
        server = nil
        status = .stopped
    }

    func restart() {
        stop()
        start()
    }

    private func serverChanged(_ state: HTTPServer.State) {
        switch state {
        case .starting, .stopped:
            break
        case .ready:
            backoff.reset()
            status = .ready
        case .failed(let why):
            stop()
            fail("Port \(port): \(why)")
        }
    }

    private func fail(_ message: String) {
        let delay = backoff.next()
        status = .failed("\(message) — retrying in \(Int(delay))s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
}
