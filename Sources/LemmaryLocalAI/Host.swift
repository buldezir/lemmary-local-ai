import Darwin
import Foundation

enum Paths {
    static let appSupport = URL.applicationSupportDirectory.appending(path: "LemmaryLocalAI", directoryHint: .isDirectory)
    static let models = appSupport.appending(path: "models", directoryHint: .isDirectory)
    /// One per port, because that is what a leftover server is in the way of,
    /// and so a development copy on other ports leaves the installed app's
    /// servers alone.
    static func llamaPIDFile(port: Int) -> URL {
        appSupport.appending(path: "llama-server-\(port).pid")
    }
    static let logs = URL.libraryDirectory.appending(path: "Logs/LemmaryLocalAI", directoryHint: .isDirectory)
    static let llamaLog = logs.appending(path: "llama-server.log")
    static let textModelLog = logs.appending(path: "text-model.log")
    static let ocrLog = logs.appending(path: "ocr.log")
    static let uploads = FileManager.default.temporaryDirectory.appending(path: "LemmaryLocalAI-uploads", directoryHint: .isDirectory)

    /// A helper binary shipped next to the app's own executable: `ocr-worker`
    /// and `llama-server` in `Contents/MacOS`, or in the build directory when
    /// run with `swift run`.
    static func helper(_ name: String) -> URL? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

enum HostInfo {
    /// The address to give Lemmary: the first IPv4 address on an interface that
    /// is up, preferring en0, which on a Mac mini is Ethernet.
    static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Link-local addresses are what an interface gets with no DHCP;
            // nothing on the LAN would use one.
            if address.hasPrefix("169.254.") { continue }
            found.append((String(cString: entry.ifa_name), address))
        }
        return (found.first { $0.name == "en0" } ?? found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }

    /// Resident memory. Not Activity Monitor's "Memory" (the physical
    /// footprint): for llama-server that leaves out the model, a 1.1 GB file
    /// that is memory-mapped and stays resident, and so reads about 100 MB.
    static func residentMemory(of pid: pid_t) -> Int64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? Int64(info.ri_resident_size) : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A llama-server left behind by a previous run that did not shut down cleanly
/// (a crash, a force quit) still holds the port, and the new one would fail to
/// bind and restart forever. The pid file says which process that would be;
/// it is only killed if it really is one of ours.
enum StaleProcess {
    static func reap(pidFile: URL) {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let path = HostInfo.executablePath(of: pid),
              path.hasSuffix("/llama-server"), path.contains("LemmaryLocalAI") else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            usleep(50_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    static func record(_ pid: pid_t, in pidFile: URL) {
        try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }
}
