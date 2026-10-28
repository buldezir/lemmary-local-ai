import Foundation
import LocalAIKit
import Observation

/// Serves docling-serve's convert endpoint, answering it with Apple Vision run
/// in a pool of `ocr-worker` processes. Lemmary's `docling` OCR SDK talks to it
/// unchanged.
@MainActor
@Observable
final class OCRService {
    private(set) var status: ServiceStatus = .stopped
    private(set) var port: Int = 0
    private(set) var converted = 0
    private(set) var failed = 0
    private(set) var lastConversion: ConversionEvent?

    private var server: HTTPServer?
    private var pool: WorkerPool?
    private var listening = false
    private var readyWorkers = 0
    private var backoff = Backoff()
    private var retryTask: Task<Void, Never>?
    private let log = LogFile(url: Paths.ocrLog)

    func start() {
        guard server == nil else { return }
        retryTask?.cancel()
        guard let worker = Paths.helper("ocr-worker") else {
            status = .failed("ocr-worker is missing from the app bundle")
            return
        }

        let log = self.log
        let pool = WorkerPool(
            configuration: .init(executable: worker, size: Preferences.parallelConversions),
            onLog: { log.write("worker: \($0)") },
            onReadyChange: { [weak self] count in
                Task { @MainActor in self?.workersChanged(count) }
            }
        )
        let converter = PoolConverter(
            pool: pool,
            stallTimeout: Preferences.pageTimeout,
            hardTimeout: 30 * 60,
            onLog: { log.write($0) }
        )
        let endpoint = DoclingEndpoint(
            converter: converter,
            isReady: { await pool.readyCount > 0 },
            uploadDirectory: Paths.uploads,
            version: AppInfo.version,
            onConversion: { [weak self] event in
                log.write(Self.describe(event))
                Task { @MainActor in self?.record(event) }
            }
        )
        let port = Preferences.ocrPort
        let server = HTTPServer(
            configuration: .init(port: UInt16(port), loopbackOnly: !Preferences.allowRemote),
            handler: { await endpoint.handle($0) },
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
        self.pool = pool
        self.port = port
        listening = false
        readyWorkers = 0
        status = .starting("Opening port \(port)")
        log.write("listening on \(Preferences.allowRemote ? "0.0.0.0" : "127.0.0.1"):\(port), \(Preferences.parallelConversions) worker(s)")
        Task { await pool.start() }
    }

    func stop() {
        retryTask?.cancel()
        server?.stop()
        server = nil
        if let pool {
            Task { await pool.stop() }
        }
        pool = nil
        status = .stopped
    }

    func restart() {
        stop()
        start()
    }

    /// For quitting, when there is no later to schedule a task in.
    func stopNow() {
        pool?.terminateNow()
        stop()
    }

    private func serverChanged(_ state: HTTPServer.State) {
        switch state {
        case .starting, .stopped:
            break
        case .ready:
            backoff.reset()
            listening = true
            updateStatus()
        case .failed(let why):
            stop()
            fail("Port \(port): \(why)")
        }
    }

    private func workersChanged(_ count: Int) {
        guard server != nil else { return }
        if readyWorkers == 0 && count > 0 {
            log.write("ready")
        }
        readyWorkers = count
        updateStatus()
    }

    /// The first warm-up loads Vision's models, which takes up to 40 seconds.
    private func updateStatus() {
        guard server != nil else { return }
        if !listening {
            status = .starting("Opening port \(port)")
        } else if readyWorkers == 0 {
            status = .starting("Loading Vision models")
        } else {
            status = .ready
        }
    }

    private func fail(_ message: String) {
        let delay = backoff.next()
        status = .failed("\(message) — retrying in \(Int(delay))s")
        log.write(message)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func record(_ event: ConversionEvent) {
        if event.failure == nil {
            converted += 1
        } else {
            failed += 1
        }
        lastConversion = event
    }

    nonisolated static func describe(_ event: ConversionEvent) -> String {
        let seconds = String(format: "%.2fs", event.duration)
        let pages = event.pages.map { "\($0)p" } ?? "-"
        let outcome = event.failure.map { "FAILED \($0)" } ?? "ok"
        return "\(event.filename) \(event.mimeType) \(event.bytes)B \(pages) \(seconds) \(outcome)"
    }
}
