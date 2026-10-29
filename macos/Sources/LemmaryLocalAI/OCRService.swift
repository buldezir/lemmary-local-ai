import Foundation
import LocalAIKit
import Observation

/// OCR by two models, Apple Vision in `ocr-worker` processes and Indra in
/// Python ones, with one of them in memory at a time: the one used last
/// (`OCRSwitch`). The app's one port (`APIService`) answers with it, as
/// docling-serve's convert endpoint and as the `apple-vision-ocr` and
/// `indra-ocr` chat models. Indra's runtime and models are downloaded at the
/// first start.
@MainActor
@Observable
final class OCRService {
    enum IndraDownload: Equatable {
        case checking
        case installed
        case downloading(received: Int64, total: Int64)
        case unpacking
        case failed(String)
    }

    private(set) var status: ServiceStatus = .stopped
    /// The model whose workers are running or starting.
    private(set) var loaded: OCRModel?
    private(set) var indraDownload: IndraDownload = .checking
    private(set) var converted = 0
    private(set) var failed = 0
    private(set) var lastConversion: ConversionEvent?

    /// What the endpoints convert with; nil while stopped.
    private(set) var converter: OCRSwitch?
    private var installing = false
    private let log = LogFile(url: Paths.ocrLog)

    func start() {
        guard converter == nil else { return }
        let log = self.log
        let workers = Preferences.parallelConversions
        // Indra's share of the cores: four threads read a page in 0.17 s on an
        // M6, and more gained little.
        let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / workers))
        let layout = Paths.indraLayout
        let script = Bundle.main.url(forResource: "indra_worker", withExtension: "py")
        let engines: [OCRModel: OCRSwitch.Engine] = [
            .appleVision: {
                guard let worker = Paths.helper("ocr-worker") else {
                    throw ConverterUnavailable("ocr-worker is missing from the app bundle")
                }
                return .init(executable: worker, size: workers)
            },
            .indra: {
                guard let script else { throw ConverterUnavailable("indra_worker.py is missing from the app bundle") }
                guard layout.isInstalled else {
                    throw ConverterUnavailable("indra-ocr is still downloading its runtime and models; try again in a minute")
                }
                let command = layout.worker(script: script, threads: threads)
                return .init(executable: command.executable, arguments: command.arguments, size: workers, startupTimeout: 120)
            },
        ]
        let preferred = Preferences.ocrModel
        let converter = OCRSwitch(
            engines: engines,
            preferred: preferred,
            stallTimeout: Preferences.pageTimeout,
            hardTimeout: 30 * 60,
            onLog: { log.write($0) },
            onState: { [weak self] state in
                Task { @MainActor in self?.switched(state) }
            },
            onLoad: { model in
                Task { @MainActor in Preferences.ocrModel = model }
            }
        )
        self.converter = converter
        status = .starting("Starting \(preferred.engine)")
        log.write("starting \(preferred.id), \(workers) worker(s)")
        Task { await converter.preload(preferred) }
        installIndra()
    }

    func stop() {
        if let converter {
            Task { await converter.stop() }
        }
        converter = nil
        loaded = nil
        status = .stopped
    }

    func restart() {
        stop()
        start()
    }

    /// For quitting, when there is no later to schedule a task in.
    func stopNow() {
        converter?.terminateNow()
        stop()
    }

    /// Downloads and unpacks Indra once; a restart while it runs leaves it
    /// running. Then loads it, if it was the model asked for last.
    func installIndra() {
        let layout = Paths.indraLayout
        guard !installing else { return }
        guard !layout.isInstalled else {
            indraDownload = .installed
            return
        }
        installing = true
        indraDownload = .downloading(received: 0, total: layout.missing.reduce(0) { $0 + $1.size })
        log.write("downloading indra-ocr")
        Task {
            do {
                try await IndraRuntime.install(layout) { progress in
                    Task { @MainActor in self.progressed(progress) }
                }
                indraDownload = .installed
                log.write("indra-ocr installed")
                if Preferences.ocrModel == .indra {
                    await converter?.preload(.indra)
                }
            } catch {
                indraDownload = .failed("\(error)")
                log.write("indra-ocr: \(error)")
                if loaded == nil, Preferences.ocrModel == .indra {
                    status = .failed("Indra could not be downloaded: \(error)")
                }
            }
            installing = false
        }
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

    /// A download reports every few kilobytes; a megabyte is enough to redraw.
    private func progressed(_ progress: IndraRuntime.Progress) {
        guard installing else { return }
        switch progress {
        case .downloading(let received, let total):
            if case .downloading(let shown, _) = indraDownload, received - shown < 1 << 20, received < total { return }
            indraDownload = .downloading(received: received, total: total)
        case .unpacking:
            indraDownload = .unpacking
        }
    }

    private func switched(_ state: OCRSwitch.State) {
        guard converter != nil else { return }
        switch state {
        case .idle:
            loaded = nil
        case .loading(let model):
            loaded = model
            // The first warm-up loads Vision's models, which takes up to 40
            // seconds; Indra's take under one.
            status = .starting(model == .appleVision ? "Loading Vision models" : "Loading Indra")
        case .ready(let model, _):
            if status != .ready || loaded != model {
                log.write("\(model.id) ready")
            }
            loaded = model
            status = .ready
        case .failed(let model, let why):
            // Only reported while nothing is loaded: Indra chosen last, and
            // its download still running or failed.
            if model == .indra, installing {
                status = .starting("Waiting for Indra's download")
            } else {
                status = .failed(why)
            }
        }
    }

    nonisolated static func describe(_ event: ConversionEvent) -> String {
        let seconds = String(format: "%.2fs", event.duration)
        let pages = event.pages.map { "\($0)p" } ?? "-"
        let outcome = event.failure.map { "FAILED \($0)" } ?? "ok"
        return "\(event.filename) \(event.mimeType) \(event.bytes)B \(pages) \(seconds) \(outcome)"
    }
}
