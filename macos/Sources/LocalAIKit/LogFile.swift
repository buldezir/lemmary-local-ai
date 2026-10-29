import Foundation
import Synchronization

/// An append-only log file with one rotation: past `maxBytes` the file becomes
/// `<name>.1` and a new one starts. The old LaunchAgent setup grew an 89 MB
/// llama-server log in a month; this keeps it bounded without a log daemon.
public final class LogFile: Sendable {
    public let url: URL
    private let maxBytes: Int
    private let handle: Mutex<FileHandle?>

    public init(url: URL, maxBytes: Int = 10 << 20) {
        self.url = url
        self.maxBytes = maxBytes
        self.handle = Mutex(nil)
    }

    public func write(_ line: String) {
        let stamped = Self.timestamp() + " " + line + "\n"
        handle.withLock { handle in
            if handle == nil {
                Self.rotate(url, ifLargerThan: maxBytes)
                handle = Self.openForAppending(url)
            }
            guard let current = handle else { return }
            current.write(Data(stamped.utf8))
            if (try? current.offset()) ?? 0 > UInt64(maxBytes) {
                try? current.close()
                Self.rotate(url, ifLargerThan: 0)
                handle = Self.openForAppending(url)
            }
        }
    }

    /// Opens `url` for a child process's stdout and stderr, rotating first.
    public static func handleForChildProcess(_ url: URL, maxBytes: Int = 20 << 20) -> FileHandle? {
        rotate(url, ifLargerThan: maxBytes)
        return openForAppending(url)
    }

    public static func rotate(_ url: URL, ifLargerThan limit: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > limit else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// The end of a log, for showing why a process died.
    public static func tail(_ url: URL, bytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func openForAppending(_ url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func timestamp() -> String {
        Date.now.formatted(Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current)
            .year().month().day().time(includingFractionalSeconds: false))
    }
}
