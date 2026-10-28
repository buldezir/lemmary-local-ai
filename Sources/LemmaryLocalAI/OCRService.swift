import Foundation
import LocalAIKit
import Observation

/// Apple Vision in a pool of `ocr-worker` processes. The app's one port
/// (`APIService`) answers OCR with it, as docling-serve's convert endpoint and
/// as the `apple-vision-ocr` chat model.
@MainActor
@Observable
final class OCRService {
    private(set) var status: ServiceStatus = .stopped
    private(set) var converted = 0
    private(set) var failed = 0
    private(set) var lastConversion: ConversionEvent?

    /// What the endpoints convert with; nil while stopped.
    private(set) var converter: (any DocumentConverting)?
    private var pool: WorkerPool?
    private var readyWorkers = 0
    private let log = LogFile(url: Paths.ocrLog)

    func start() {
        guard pool == nil else { return }
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
        converter = PoolConverter(
            pool: pool,
            stallTimeout: Preferences.pageTimeout,
            hardTimeout: 30 * 60,
            onLog: { log.write($0) }
        )
        self.pool = pool
        readyWorkers = 0
        status = .starting("Loading Vision models")
        log.write("starting \(Preferences.parallelConversions) worker(s)")
        Task { await pool.start() }
    }

    func stop() {
        if let pool {
            Task { await pool.stop() }
        }
        pool = nil
        converter = nil
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

    /// Called by the endpoints for every document, from any thread.
    nonisolated func record(_ event: ConversionEvent) {
        log.write(Self.describe(event))
        Task { @MainActor in
            if event.failure == nil {
                converted += 1
            } else {
                failed += 1
            }
            lastConversion = event
        }
    }

    /// The first warm-up loads Vision's models, which takes up to 40 seconds.
    private func workersChanged(_ count: Int) {
        guard pool != nil else { return }
        if readyWorkers == 0 && count > 0 {
            log.write("ready")
        }
        readyWorkers = count
        status = count > 0 ? .ready : .starting("Loading Vision models")
    }

    nonisolated static func describe(_ event: ConversionEvent) -> String {
        let seconds = String(format: "%.2fs", event.duration)
        let pages = event.pages.map { "\($0)p" } ?? "-"
        let outcome = event.failure.map { "FAILED \($0)" } ?? "ok"
        return "\(event.filename) \(event.mimeType) \(event.bytes)B \(pages) \(seconds) \(outcome)"
    }
}
