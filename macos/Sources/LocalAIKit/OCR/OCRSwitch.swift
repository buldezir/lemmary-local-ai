import Foundation
import Synchronization

/// The OCR models' worker pools, of which one runs at a time: the model used
/// last. Each worker holds its model in memory, 0.4 to 0.6 GB for either, and
/// Lemmary binds one OCR model, so the other's would only sit there.
///
/// A request for the other model waits for the requests in flight, then its
/// pool replaces the running one: Indra's workers start in under a second,
/// Vision's in up to 40 s when macOS has unloaded its models. While a request
/// waits for a switch, later ones for the model in memory queue behind it, so
/// neither model can keep the other out.
public actor OCRSwitch: DocumentConverting {
    public enum State: Sendable, Equatable {
        case idle
        /// The model's pool is starting, or has no worker ready yet.
        case loading(OCRModel)
        case ready(OCRModel, workers: Int)
        /// The model cannot start, e.g. its files are still downloading.
        case failed(OCRModel, String)
    }

    /// A model's workers as they would start now; throws `ConverterUnavailable`
    /// when they cannot.
    public typealias Engine = @Sendable () throws -> WorkerPool.Configuration

    private struct Loaded {
        let model: OCRModel
        let pool: WorkerPool
        let converter: PoolConverter
    }

    private let engines: [OCRModel: Engine]
    private let stallTimeout: TimeInterval
    private let hardTimeout: TimeInterval
    private let onLog: @Sendable (String) -> Void
    private let onState: @Sendable (State) -> Void
    private let onLoad: @Sendable (OCRModel) -> Void

    private var loaded: Loaded?
    private var switching = false
    private var inFlight = 0
    private var waiting: [(model: OCRModel, continuation: CheckedContinuation<PoolConverter, Error>)] = []
    /// What a request that names no model gets: docling clients other than
    /// Lemmary send none.
    private var lastRequested: OCRModel
    private var stopped = false
    /// The running pool, reachable without awaiting the actor, for quitting.
    private nonisolated let live = Mutex<WorkerPool?>(nil)

    /// `onLoad` is told each model whose pool has started, for remembering
    /// the last one across launches.
    public init(engines: [OCRModel: Engine], preferred: OCRModel, stallTimeout: TimeInterval, hardTimeout: TimeInterval,
                onLog: @escaping @Sendable (String) -> Void = { _ in },
                onState: @escaping @Sendable (State) -> Void = { _ in },
                onLoad: @escaping @Sendable (OCRModel) -> Void = { _ in }) {
        self.engines = engines
        self.stallTimeout = stallTimeout
        self.hardTimeout = hardTimeout
        self.onLog = onLog
        self.onState = onState
        self.onLoad = onLoad
        lastRequested = preferred
    }

    /// The model whose workers are running or starting, if any.
    public var loadedModel: OCRModel? { loaded?.model }

    public func convert(file: URL, kind: MediaKind, model: OCRModel?) async throws -> ConversionOutcome {
        let target = try route(model, kind)
        let converter = try await acquire(target)
        defer { release() }
        return try await converter.convert(file: file, kind: kind)
    }

    /// Starts `model` before any request asks for it: at launch, or once its
    /// files are in place. Does nothing while another model is loaded.
    public func preload(_ model: OCRModel) async {
        guard !stopped, loaded == nil, !switching else { return }
        lastRequested = model
        switching = true
        await load(model)
    }

    public func stop() async {
        stopped = true
        let pool = loaded?.pool
        loaded = nil
        live.withLock { $0 = nil }
        let waiters = waiting
        waiting.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: ConverterUnavailable())
        }
        await pool?.stop()
        onState(.idle)
    }

    /// Ends the running workers now, from any thread.
    public nonisolated func terminateNow() {
        live.withLock { $0 }?.terminateNow()
    }

    /// A named model must read the kind. With none named, the model used last
    /// does, or Apple Vision for what Indra cannot read (Word, HTML).
    private func route(_ model: OCRModel?, _ kind: MediaKind) throws -> OCRModel {
        if let model {
            guard model.reads(kind) else { throw UnreadableByModel(model: model, kind: kind) }
            return model
        }
        return lastRequested.reads(kind) ? lastRequested : .appleVision
    }

    private func acquire(_ model: OCRModel) async throws -> PoolConverter {
        guard !stopped else { throw ConverterUnavailable() }
        if let loaded, loaded.model == model, !switching, waiting.isEmpty {
            inFlight += 1
            lastRequested = model
            return loaded.converter
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append((model, continuation))
            advance()
        }
    }

    private func release() {
        inFlight -= 1
        advance()
    }

    /// Lets in the requests at the head of the queue, switching models first
    /// once nothing is in flight.
    private func advance() {
        guard !switching, inFlight == 0, let next = waiting.first?.model else { return }
        if loaded?.model == next {
            admit(next)
            return
        }
        switching = true
        Task { await load(next) }
    }

    /// Every queued request for the loaded model, in order. A model counts as
    /// used once it reads a request, so one that could not start is not the
    /// model requests naming none are sent to.
    private func admit(_ model: OCRModel) {
        guard let loaded, loaded.model == model else { return }
        let admitted = waiting.filter { $0.model == model }
        waiting.removeAll { $0.model == model }
        inFlight += admitted.count
        if !admitted.isEmpty {
            lastRequested = model
        }
        for waiter in admitted {
            waiter.continuation.resume(returning: loaded.converter)
        }
    }

    /// Replaces the running pool, if any, with `model`'s. Called with
    /// `switching` set and nothing in flight. A model that cannot start
    /// refuses its requests and leaves the running one in memory.
    private func load(_ model: OCRModel) async {
        let configuration: WorkerPool.Configuration
        do {
            guard let engine = engines[model] else { throw ConverterUnavailable("\(model.id) is not served") }
            configuration = try engine()
        } catch {
            switching = false
            let reason = error as? ConverterUnavailable ?? ConverterUnavailable("\(model.id) cannot start: \(error)")
            onLog(reason.description)
            if loaded == nil {
                onState(.failed(model, reason.description))
            }
            let refused = waiting.filter { $0.model == model }
            waiting.removeAll { $0.model == model }
            for waiter in refused {
                waiter.continuation.resume(throwing: reason)
            }
            advance()
            return
        }
        if let old = loaded {
            loaded = nil
            live.withLock { $0 = nil }
            await old.pool.stop()
            onLog("unloaded \(old.model.id)")
        }
        guard !stopped else {
            switching = false
            return
        }

        onState(.loading(model))
        let onState = self.onState
        let pool = WorkerPool(configuration: configuration, onLog: onLog, onReadyChange: { count in
            onState(count > 0 ? .ready(model, workers: count) : .loading(model))
        })
        loaded = Loaded(model: model, pool: pool,
                        converter: PoolConverter(pool: pool, stallTimeout: stallTimeout, hardTimeout: hardTimeout, onLog: onLog))
        live.withLock { $0 = pool }
        await pool.start()
        switching = false
        onLog("loaded \(model.id), \(configuration.size) worker(s)")
        onLoad(model)
        admit(model)
        advance()
    }
}

/// A model asked for a kind of document it does not read, e.g. Indra for Word.
public struct UnreadableByModel: Error, CustomStringConvertible {
    public var model: OCRModel
    public var kind: MediaKind

    public var description: String { "\(model.id) reads \(model.readsDescription), not \(kind.rawValue)" }
}
