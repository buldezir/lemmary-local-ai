import Foundation
import Network

/// A small HTTP/1.1 server on Network.framework: one request per connection,
/// bodies by `Content-Length`, the handler run off the network queue.
///
/// It exists so the OCR endpoint needs no dependency: the API it serves is two
/// GETs and one multipart POST, which a full web framework would dwarf.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public struct Configuration: Sendable {
        public var port: UInt16
        public var loopbackOnly: Bool
        public var maxBodyBytes: Int
        public var idleTimeout: TimeInterval

        public init(port: UInt16, loopbackOnly: Bool, maxBodyBytes: Int = 128 << 20, idleTimeout: TimeInterval = 60) {
            self.port = port
            self.loopbackOnly = loopbackOnly
            self.maxBodyBytes = maxBodyBytes
            self.idleTimeout = idleTimeout
        }
    }

    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    let configuration: Configuration
    let handler: Handler
    private let onStateChange: @Sendable (State) -> Void
    let queue = DispatchQueue(label: "LocalAIKit.HTTPServer")

    // Confined to `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var reportedFailure = false

    public init(configuration: Configuration, handler: @escaping Handler,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.configuration = configuration
        self.handler = handler
        self.onStateChange = onStateChange
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener: NWListener
        if configuration.loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: port)
        }
        listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync {
            self.listener = listener
            self.reportedFailure = false
        }
        onStateChange(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            onStateChange(.ready(port: listener?.port?.rawValue ?? configuration.port))
        case .failed(let error), .waiting(let error):
            // A port already in use arrives as `waiting`, and the listener would
            // sit there indefinitely; for a server that is a failure to report.
            reportedFailure = true
            onStateChange(.failed(Self.describe(error)))
            listener?.cancel()
        case .cancelled:
            if !reportedFailure {
                onStateChange(.stopped)
            }
        default:
            break
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(nw, server: self)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onFinish = { [weak self] in self?.connections[id] = nil }
        connection.start()
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "port already in use"
        }
        return error.localizedDescription
    }
}

/// One accepted socket. Everything here runs on the server's queue.
final class HTTPConnection: @unchecked Sendable {
    private let nw: NWConnection
    private let server: HTTPServer
    var onFinish: (() -> Void)?

    private var buffer = Data()
    private var head: (HTTPRequestHead, length: Int, contentLength: Int)?
    private var sentContinue = false
    private var finished = false
    private var idleTimer: DispatchWorkItem?

    init(_ nw: NWConnection, server: HTTPServer) {
        self.nw = nw
        self.server = server
    }

    func start() {
        nw.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: finish()
            default: break
            }
        }
        nw.start(queue: server.queue)
        armIdleTimer()
        receive()
    }

    func cancel() {
        nw.cancel()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
                armIdleTimer()
                if takeOver() { return }
            }
            if isComplete || error != nil {
                nw.cancel()
                return
            }
            receive()
        }
    }

    /// Advances the parse. True once the connection has stopped reading, either
    /// because the request went to the handler or because it was refused.
    private func takeOver() -> Bool {
        if head == nil {
            switch HTTPParser.parseHead(buffer) {
            case .needMore:
                return false
            case .invalid(let status, let message):
                respond(.detail(status, message))
                return true
            case .head(let parsed, let length, let contentLength):
                if contentLength > server.configuration.maxBodyBytes {
                    respond(.detail(.payloadTooLarge, "request body exceeds \(server.configuration.maxBodyBytes) bytes"))
                    return true
                }
                head = (parsed, length, contentLength)
            }
        }
        guard let (parsed, length, contentLength) = head else { return false }

        let needed = length + contentLength
        guard buffer.count >= needed else {
            // curl waits a second for this before sending a large body anyway;
            // answering it saves that second on every upload.
            if parsed.expectsContinue && !sentContinue {
                sentContinue = true
                nw.send(content: HTTPResponse.continueInterim, completion: .idempotent)
            }
            return false
        }

        let start = buffer.startIndex
        let request = HTTPRequest(head: parsed, body: buffer.subdata(in: (start + length)..<(start + needed)))
        buffer = Data()
        // The handler may run for minutes on a long document; idleness only
        // means something while the client still owes us bytes.
        idleTimer?.cancel()
        let handler = server.handler
        Task {
            let response = await handler(request)
            server.queue.async { self.respond(response) }
        }
        return true
    }

    private func respond(_ response: HTTPResponse) {
        guard !finished else { return }
        idleTimer?.cancel()
        nw.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [self] _ in nw.cancel() })
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.respond(.detail(.requestTimeout, "request not received in time"))
        }
        idleTimer = timer
        server.queue.asyncAfter(deadline: .now() + server.configuration.idleTimeout, execute: timer)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        idleTimer?.cancel()
        nw.stateUpdateHandler = nil
        onFinish?()
        onFinish = nil
    }
}
