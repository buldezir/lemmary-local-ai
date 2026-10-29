import CryptoKit
import Foundation

/// What Indra OCR runs on, every file pinned by SHA-256: a relocatable CPython
/// (python-build-standalone), the five packages Indra imports, unpacked
/// straight into its site-packages, and the models from a tag of
/// datalab-to/indra-ocr. Downloaded into Application Support rather than
/// bundled: they would make the app, and every update Sparkle downloads, about
/// 100 MB larger. Nothing beyond these is needed: onnxruntime's declared
/// dependencies (flatbuffers, packaging, protobuf) are for its tools, and
/// huggingface_hub only downloads models, which the app does itself.
///
/// linux/indra.go pins the same versions for Linux; change both together, and
/// `id` with them, so an installed runtime is replaced instead of reused.
public enum IndraRuntime {
    public struct Artifact: Sendable, Equatable {
        public enum Kind: Sendable { case python, wheel, model }

        public var kind: Kind
        public var url: URL
        public var sha256: String
        public var size: Int64

        /// The name on disk: the URL's last component, decoded (`%2B` is `+`).
        public var fileName: String { url.lastPathComponent }
    }

    /// The runtime's directory name, and so its version.
    public static let id = "indra-1.1.2-cpython-3.12.15-20261013"
    /// The models' directory name, after their tag.
    public static let modelsID = "indra-ocr-v1.1.0"

    public static let python = Artifact(
        kind: .python,
        url: URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-aarch64-apple-darwin-install_only_stripped.tar.gz")!,
        sha256: "9866e11cf2ae9caa1e671383786f248859a52dd8bfb702fb4c0dc2c65f1d36de",
        size: 25_052_618
    )

    public static let wheels: [Artifact] = [
        wheel("3f/9a/ad0b5a2d72acc47bf321fc9c73c559b4c7743228c59f55949d2c050e4328/indra_ocr-1.1.2-py3-none-any.whl",
              "22c82720968dd91b11ae137865fa01edaed29d7c1c11dd5d9c4a084bc3654da2", 96_141),
        // Built on Accelerate, not OpenBLAS: half the size.
        wheel("31/2f/5ea3570fcb8ccd0882bea99436a513b2c85dad8f774a2057849130a8fb99/numpy-2.5.4-cp312-cp312-macosx_14_0_arm64.whl",
              "9cb18a327b49c5c337f972b03682f6a49855525faaf3c0d3e9c96cd0fd8880a8", 5_451_717),
        wheel("0e/f7/cecc0efeeea83bff2f7789ae1b80f27fa0f0210d6d9d66d1f0031a6b5e47/onnxruntime-1.31.1-cp312-cp312-macosx_14_0_arm64.whl",
              "96dd2564b10ea7153ad9c207e7cd8e5917cb3ba521e0e0a62ac03486fdc8d56c", 20_882_125),
        wheel("53/7c/8c8097891c509d98cd128493835c95631c80be6a8f37ed9d25716c2e16f1/opencv_python_headless-5.0.0.93-cp37-abi3-macosx_13_0_arm64.whl",
              "030ca5e0837a2963ab36ef896baa9767eb8d2b83353fb28af5a521e40dd8756f", 48_322_581),
        wheel("d1/ea/14673bc9d8b7beeaa1eb46e9951b22543edaf2a4676c586e3b1e032ff6ee/pypdfium2-5.14.0-py3-none-macosx_13_0_arm64.whl",
              "2de384df66ba55fcaab0775f30f28ec1090af3dfa60276a07821efc96d993118", 3_542_294),
    ]

    /// The tag v1.1.0, which indra-ocr 1.1.2 was built against, without the
    /// math models (math is off) and with the weights' licence, which has to
    /// travel with them.
    public static let models: [Artifact] = [
        model("det.onnx", "f2bd4cba23e9c328cf7ec824634e423e191a2c6aacbbf35c62bd79dd70f62f59", 389_948),
        model("rec.onnx", "475972a2710be4a3cbfeb2bc7f3624ffd563de07de42476fc7a290d4e1ece484", 5_042_161),
        model("rec_cjk.onnx", "4a035516a17e62cdf33a4fe2d88077654cb8841cff024685cdef4e351694ef50", 10_176_018),
        model("rec_rtl.onnx", "468796bd684486a8388c30c8b4ed2a26e3eeb1f8ff02831c24c2e12c79a2a834", 4_812_710),
        model("rec_world.onnx", "c8d1e59f21b04966f179d2d2d8e22b230d22110b3f89855bbbf2624a58c40043", 5_627_990),
        model("script.onnx", "b6ce4e926e19c243faaf37bd46880398bf2cb4ae56a29e1177a3b017c1280e36", 191_630),
        model("orient.onnx", "20eaf670f55a7cf9facfe1bdd6c7b8e40be75bbf4d48a3df43f66aa3bbd874fd", 371_802),
        model("order.onnx", "a42db2e8b536ad3d84045a4b7f9b0a72667cf8be4aa02d63f7b38004719fb180", 2_973_138),
        model("lm.npz", "6c0fb618a363a0acdd05d4f5b0edd9e8146d2d990541b87f6130bbfe17cea58d", 15_695_957),
        model("lm_cjk.npz", "6d64f13f4f90f4e529bd63340c6df76238d007feaef2abb903d8cd28d92bc2f3", 18_955_160),
        model("lm_world.npz", "34df5e74a2fcbb9cf5e7f360a559375ffa2e04d2d2943a42308c177bcb444d5d", 11_641_215),
        model("meta.json", "4ce4c94b46f5d644033c02e718322014ff4081270f385038c571912b56696339", 211_869),
        model("LICENSE", "50c88a018a7ee322e89f6b09401b237beb0cd331685879405b3db48993950a5f", 14_750),
    ]

    public static var all: [Artifact] { [python] + wheels + models }

    /// A file's address on PyPI, as its JSON API gives it.
    private static func wheel(_ path: String, _ sha256: String, _ size: Int64) -> Artifact {
        Artifact(kind: .wheel, url: URL(string: "https://files.pythonhosted.org/packages/\(path)")!, sha256: sha256, size: size)
    }

    private static func model(_ name: String, _ sha256: String, _ size: Int64) -> Artifact {
        Artifact(kind: .model,
                 url: URL(string: "https://huggingface.co/datalab-to/indra-ocr/resolve/bd02167fdf2005a19962cc15188f8496a2c87d3b/\(name)")!,
                 sha256: sha256, size: size)
    }

    /// Where the runtime and models live, and whether they are complete.
    public struct Layout: Sendable {
        /// The runtime's parent; older runtimes in it are removed on install.
        public var root: URL
        /// Where the models are kept, beside the app's other models.
        public var modelsRoot: URL

        public init(root: URL, modelsRoot: URL) {
            self.root = root
            self.modelsRoot = modelsRoot
        }

        public var runtime: URL { root.appending(path: IndraRuntime.id, directoryHint: .isDirectory) }
        public var python: URL { runtime.appending(path: "python/bin/python3") }
        public var sitePackages: URL { runtime.appending(path: "python/lib/python3.12/site-packages", directoryHint: .isDirectory) }
        public var models: URL { modelsRoot.appending(path: IndraRuntime.modelsID, directoryHint: .isDirectory) }
        var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
        /// Written last, so a runtime cut off half unpacked is unpacked again.
        var marker: URL { runtime.appending(path: ".installed") }

        /// What is still to be downloaded: the runtime as a whole, and each
        /// model file of the wrong size or missing.
        public var missing: [Artifact] {
            let files = FileManager.default
            let runtime = files.fileExists(atPath: marker.path) ? [] : [IndraRuntime.python] + IndraRuntime.wheels
            let models = IndraRuntime.models.filter {
                (try? files.attributesOfItem(atPath: models.appending(path: $0.fileName).path)[.size] as? Int64) != $0.size
            }
            return runtime + models
        }

        public var isInstalled: Bool { missing.isEmpty }

        /// The command line of one worker: Python isolated from the user's own
        /// (`-I` ignores PYTHONPATH and user site-packages), the worker script,
        /// the models, and its share of the cores.
        public func worker(script: URL, threads: Int) -> (executable: URL, arguments: [String]) {
            (python, ["-I", script.path, "serve", "--models", models.path, "--threads", String(max(1, threads))])
        }
    }

    public enum Progress: Sendable, Equatable {
        case downloading(received: Int64, total: Int64)
        case unpacking
    }

    public enum InstallError: Error, CustomStringConvertible {
        case download(String, String)
        case checksum(String)
        case unpack(String, String)

        public var description: String {
            switch self {
            case .download(let file, let why): "could not download \(file): \(why)"
            case .checksum(let file): "\(file) did not match its checksum; try again"
            case .unpack(let file, let why): "could not unpack \(file): \(why)"
            }
        }
    }

    /// Downloads what `layout` is missing, checks every file, and unpacks the
    /// runtime: Python's archive with tar, each wheel with ditto, since a
    /// wheel is a zip of what goes into site-packages.
    public static func install(_ layout: Layout, session: URLSession = .shared,
                               onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        let files = FileManager.default
        let needed = layout.missing
        guard !needed.isEmpty else { return }
        try files.createDirectory(at: layout.downloads, withIntermediateDirectories: true)
        try files.createDirectory(at: layout.models, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: layout.downloads) }

        let total = needed.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        var fetched: [Artifact: URL] = [:]
        for artifact in needed {
            onProgress(.downloading(received: done, total: total))
            let base = done
            let file = try await download(artifact, into: layout.downloads, session: session) { received in
                onProgress(.downloading(received: base + received, total: total))
            }
            done += artifact.size
            fetched[artifact] = file
        }

        onProgress(.unpacking)
        for artifact in needed where artifact.kind == .model {
            let destination = layout.models.appending(path: artifact.fileName)
            try? files.removeItem(at: destination)
            try files.moveItem(at: fetched[artifact]!, to: destination)
        }
        guard let archive = fetched[python] else { return }
        try? files.removeItem(at: layout.runtime)
        try files.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", layout.runtime.path], for: python.fileName)
        for wheel in wheels {
            try run("/usr/bin/ditto", ["-x", "-k", fetched[wheel]!.path, layout.sitePackages.path], for: wheel.fileName)
        }
        try Data(IndraRuntime.id.utf8).write(to: layout.marker)
        for old in (try? files.contentsOfDirectory(at: layout.root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("indra-") && old.lastPathComponent != IndraRuntime.id {
            try? files.removeItem(at: old)
        }
    }

    private static func download(_ artifact: Artifact, into directory: URL, session: URLSession,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let destination = directory.appending(path: artifact.fileName)
        let delegate = ProgressDelegate(progress)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: artifact.url, delegate: delegate)
        } catch {
            throw InstallError.download(artifact.fileName, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download(artifact.fileName, "HTTP \(http.statusCode)")
        }
        guard try sha256(of: temporary) == artifact.sha256 else { throw InstallError.checksum(artifact.fileName) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func run(_ tool: String, _ arguments: [String], for file: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.unpack(file, error.localizedDescription)
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.unpack(file, String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension IndraRuntime.Artifact: Hashable {}

/// Bytes received so far, for one download.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void

    init(_ progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
