import Foundation
import LocalAIKit
import Observation

/// Where the embeddings model lives, and getting it there: either the app's own
/// verified download or a GGUF the user already has (the LaunchAgent setup kept
/// one in `~/ai/models`).
@MainActor
@Observable
final class ModelStore {
    enum Download: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
    }

    let descriptor = ModelDescriptor.bgeM3
    private(set) var download: Download = .idle
    /// Called once a model is in place, so the embeddings service can start.
    var onInstalled: (() -> Void)?

    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    var defaultLocation: URL { Paths.models.appending(path: descriptor.fileName) }

    var configuredLocation: URL {
        Preferences.modelPath.isEmpty ? defaultLocation : URL(fileURLWithPath: Preferences.modelPath)
    }

    var installedModel: URL? {
        FileManager.default.fileExists(atPath: configuredLocation.path) ? configuredLocation : nil
    }

    func useExisting(_ url: URL) {
        Preferences.modelPath = url.path
        download = .idle
        onInstalled?()
    }

    func useDefaultLocation() {
        Preferences.modelPath = ""
        onInstalled?()
    }

    func startDownload() {
        guard task == nil else { return }
        let delegate = DownloadDelegate(
            destination: Paths.models.appending(path: descriptor.fileName + ".partial"),
            progress: { [weak self] received, total in
                Task { @MainActor in self?.progressed(received: received, total: total) }
            },
            finished: { [weak self] result in
                Task { @MainActor in await self?.finished(result) }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: descriptor.url)
        self.session = session
        self.task = task
        download = .downloading(received: 0, total: descriptor.size)
        task.resume()
    }

    func cancelDownload() {
        task?.cancel()
        reset()
        download = .idle
    }

    private func progressed(received: Int64, total: Int64) {
        guard task != nil else { return }
        download = .downloading(received: received, total: total > 0 ? total : descriptor.size)
    }

    private func finished(_ result: Result<URL, Error>) async {
        reset()
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            download = .failed(error.localizedDescription)
        case .success(let partial):
            download = .verifying
            let expected = descriptor.sha256
            let digest = await Task.detached { try? ModelDescriptor.sha256(of: partial) }.value
            guard digest == expected else {
                try? FileManager.default.removeItem(at: partial)
                download = .failed("The download did not match its checksum; try again")
                return
            }
            do {
                try? FileManager.default.removeItem(at: defaultLocation)
                try FileManager.default.moveItem(at: partial, to: defaultLocation)
            } catch {
                download = .failed(error.localizedDescription)
                return
            }
            download = .idle
            useDefaultLocation()
        }
    }

    private func reset() {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }
}

/// URLSession's download delegate. The temporary file is gone once
/// `didFinishDownloadingTo` returns, so it is moved there, synchronously.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    let finished: @Sendable (Result<URL, Error>) -> Void

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void,
         finished: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.finished = finished
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finished(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finished(.success(destination))
        } catch {
            finished(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finished(.failure(error))
        }
    }
}
