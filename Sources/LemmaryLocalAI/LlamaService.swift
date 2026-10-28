import Foundation
import LocalAIKit
import Observation

/// Runs one bundled `llama-server` and keeps it running: what the
/// `llama-embeddings` LaunchAgent with `KeepAlive` used to do. The app has one
/// for bge-m3 and one for the optional text model.
@MainActor
@Observable
final class LlamaService {
    struct Launch {
        var port: Int
        var arguments: [String]
    }

    private(set) var status: ServiceStatus = .stopped
    private(set) var memory: Int64?
    private(set) var port: Int = 0

    private let log: URL
    private let model: @MainActor () -> URL?
    private let launch: @MainActor (_ model: URL) -> Launch
    private var process: Process?
    private var pidFile: URL?
    private var startedAt: ContinuousClock.Instant?
    private var backoff = Backoff()
    private var stopping = false
    private var restartWhenStopped = false
    private var restartTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    /// `model` is the installed GGUF, nil while it still has to be downloaded;
    /// `launch` turns it into a port and a command line, read from the settings
    /// at every start.
    init(log: URL, model: @escaping @MainActor () -> URL?, launch: @escaping @MainActor (_ model: URL) -> Launch) {
        self.log = log
        self.model = model
        self.launch = launch
    }

    func start() {
        guard process == nil else { return }
        restartTask?.cancel()
        stopping = false

        guard let model = model() else {
            status = .needsSetup("Model not installed")
            return
        }
        guard let binary = Paths.helper("llama-server") else {
            status = .failed("llama-server is missing from the app bundle")
            return
        }
        let launch = launch(model)
        let pidFile = Paths.llamaPIDFile(port: launch.port)
        StaleProcess.reap(pidFile: pidFile)

        let output = LogFile.handleForChildProcess(log)
        let process = Process()
        process.executableURL = binary
        process.arguments = launch.arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
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
        try? output?.close()

        self.process = process
        self.pidFile = pidFile
        port = launch.port
        startedAt = .now
        StaleProcess.record(process.processIdentifier, in: pidFile)
        status = .starting("Loading model")
        watchHealth(port: launch.port, pid: process.processIdentifier)
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
        if let pidFile {
            try? FileManager.default.removeItem(at: pidFile)
        }
    }

    private func exited(status code: Int32) {
        process = nil
        healthTask?.cancel()
        memory = nil
        if let pidFile {
            try? FileManager.default.removeItem(at: pidFile)
        }

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
        let reason = Self.lastError(in: LogFile.tail(log)) ?? "llama-server exited with status \(code)"
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
    /// once it can serve.
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
