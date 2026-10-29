import Foundation

/// One uploaded document through the converter: staged to a file, converted,
/// reported, removed. docling's endpoint and the OCR chat model share it, and
/// each answers the result in its own API's shape.
struct UploadConversion: Sendable {
    enum Result: Sendable, Equatable {
        case converted(markdown: String, pages: Int, duration: TimeInterval)
        /// The document itself could not be read, e.g. a password-protected PDF.
        case documentFailed(String, duration: TimeInterval)
        case unsupported(mimeType: String)
        case serverError(HTTPStatus, String)
    }

    var converter: any DocumentConverting
    var uploadDirectory: URL
    var onConversion: @Sendable (ConversionEvent) -> Void

    func run(data: Data, declaredType: String?, filename: String?, model: OCRModel?) async -> Result {
        let media = MediaType.resolve(declared: declaredType, filename: filename, data: data)
        guard let kind = media.kind, model?.reads(kind) ?? true else {
            return .unsupported(mimeType: media.mimeType)
        }

        let input = uploadDirectory.appending(path: "\(UUID().uuidString).\(MediaType.fileExtension(forMIME: media.mimeType))")
        do {
            try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
            try data.write(to: input)
        } catch {
            return .serverError(.internalServerError, "could not stage the upload: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: input) }

        let started = ContinuousClock.now
        func report(pages: Int?, failure: String?) -> TimeInterval {
            let duration = (ContinuousClock.now - started).seconds
            onConversion(ConversionEvent(filename: filename ?? "document", mimeType: media.mimeType, bytes: data.count,
                                         pages: pages, duration: duration, failure: failure))
            return duration
        }

        do {
            switch try await converter.convert(file: input, kind: kind, model: model) {
            case .converted(let markdown, let pages):
                return .converted(markdown: markdown, pages: pages, duration: report(pages: pages, failure: nil))
            case .failed(let reason):
                return .documentFailed(reason, duration: report(pages: nil, failure: reason))
            }
        } catch let failure as WorkerFailure {
            _ = report(pages: nil, failure: failure.description)
            switch failure {
            case .stalled, .timedOut:
                return .serverError(.gatewayTimeout, failure.description)
            case .launch, .crashed:
                return .serverError(.internalServerError, failure.description)
            }
        } catch let unavailable as ConverterUnavailable {
            return .serverError(.serviceUnavailable, unavailable.description)
        } catch is UnreadableByModel {
            return .unsupported(mimeType: media.mimeType)
        } catch {
            _ = report(pages: nil, failure: "\(error)")
            return .serverError(.internalServerError, "\(error)")
        }
    }
}

/// A converter looked up at every request, for an endpoint that outlives the
/// worker pool behind it: the pool is rebuilt when its settings change.
public struct DeferredConverter: DocumentConverting {
    public var current: @Sendable () async -> (any DocumentConverting)?

    public init(_ current: @escaping @Sendable () async -> (any DocumentConverting)?) {
        self.current = current
    }

    public func convert(file: URL, kind: MediaKind, model: OCRModel?) async throws -> ConversionOutcome {
        guard let converter = await current() else { throw ConverterUnavailable() }
        return try await converter.convert(file: file, kind: kind, model: model)
    }
}

/// OCR is stopped or restarting, or a model cannot start yet.
public struct ConverterUnavailable: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String = "OCR is not running") {
        self.description = description
    }
}
