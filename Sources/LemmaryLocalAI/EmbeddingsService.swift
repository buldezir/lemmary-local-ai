import Foundation
import LocalAIKit
import Observation

/// Runs the bundled `llama-server` with bge-m3 and keeps it running: what the
/// `llama-embeddings` LaunchAgent with `KeepAlive` used to do.
@MainActor
@Observable
final class EmbeddingsService {
    private(set) var status: ServiceStatus = .stopped
    private(set) var memory: Int64?
    private(set) var port: Int = 0

    private let modelStore: ModelStore
    private var process: Process?
    private var startedAt: ContinuousClock.Instant?
    private var backoff = Backoff()
    private var stopping = false
    private var restartWhenStopped = false
    private var restartTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func start() {
        guard process == nil else { return }
        restartTask?.cancel()
        stopping = false

        guard let model = modelStore.installedModel else {
            status = .needsSetup("Model not installed")
            return
        }
        guard let binary = Paths.helper("llama-server") else {
            status = .failed("llama-server is missing from the app bundle")
            return
        }
        StaleProcess.reap(pidFile: Paths.llamaPIDFile)

        let config = LlamaServerConfig(
            modelPath: model.path,
            host: Preferences.allowRemote ? "0.0.0.0" : "127.0.0.1",
            port: Preferences.embeddingsPort,
            contextTokens: Preferences.contextTokens
        )
        let log = LogFile.handleForChildProcess(Paths.llamaLog)
        let process = Process()
        process.executableURL = binary
        process.arguments = config.arguments
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(status: status) }
        }
        do {
            try process.run()
        } catch {
            status = .failed("Could not start llama-server: \(error.localizedDescription)")
            scheduleRestart()
            return
        }
        try? log?.close()

        self.process = process
        port = config.port
        startedAt = .now
        StaleProcess.record(process.processIdentifier, in: Paths.llamaPIDFile)
        status = .starting("Loading model")
        watchHealth(port: config.port, pid: process.processIdentifier)
    }

    func stop() {
        stopping = true
        restartTask?.cancel()
        healthTask?.cancel()
        process?.terminate()
        if process == nil {
            status = .stopped
        }
    }

    func restart() {
        if process == nil {
            start()
        } else {
            restartWhenStopped = true
            stop()
        }
    }

    /// For quitting: the termination handler cannot run while the main thread
    /// waits here, so the process is reaped directly.
    func stopAndWait() {
        guard let process else { return }
        stopping = true
        restartTask?.cancel()
        healthTask?.cancel()
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: Paths.llamaPIDFile)
    }

    private func exited(status code: Int32) {
        process = nil
        healthTask?.cancel()
        memory = nil
        try? FileManager.default.removeItem(at: Paths.llamaPIDFile)

        if restartWhenStopped {
            restartWhenStopped = false
            start()
            return
        }
        if stopping {
            status = .stopped
            return
        }
        if let startedAt, ContinuousClock.now - startedAt > .seconds(60) {
            backoff.reset()
        }
        let reason = Self.lastError(in: LogFile.tail(Paths.llamaLog)) ?? "llama-server exited with status \(code)"
        scheduleRestart(reason: reason)
    }

    private func scheduleRestart(reason: String? = nil) {
        let delay = backoff.next()
        status = .failed("\(reason ?? status.label) — retrying in \(Int(delay))s")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// llama-server answers `/health` with 503 while it loads the model and 200
    /// once it can embed.
    private func watchHealth(port: Int, pid: pid_t) {
        healthTask?.cancel()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        healthTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                let code = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                guard let self, !Task.isCancelled else { return }
                memory = HostInfo.residentMemory(of: pid)
                switch code {
                case 200:
                    failures = 0
                    status = .ready
                case 503:
                    status = .starting("Loading model")
                default:
                    failures += 1
                    if status == .ready && failures >= 3 {
                        status = .failed("Not answering on port \(port)")
                    }
                }
                try? await Task.sleep(for: status == .ready ? .seconds(10) : .seconds(1))
            }
        }
    }

    /// The most recent error line llama-server wrote, e.g. why it could not
    /// bind its port. Its log lines carry the level as a single letter after
    /// the timestamp.
    static func lastError(in log: String) -> String? {
        let lines = log.split(separator: "\n").map(String.init)
        guard let line = lines.last(where: { $0.contains(" E ") || $0.localizedCaseInsensitiveContains("error") }) else {
            return nil
        }
        let message = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(2).joined(separator: " ")
        return String((message.isEmpty ? line : message).prefix(160))
    }
}
