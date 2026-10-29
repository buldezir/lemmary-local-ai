import Foundation

/// The OCR models the app serves. Both are always listed in `/v1/models`; one
/// at a time has its workers running (`OCRSwitch`).
public enum OCRModel: String, Sendable, Codable, CaseIterable {
    /// Apple Vision in `ocr-worker` processes. Also reads Word and HTML.
    case appleVision = "apple-vision-ocr"
    /// Indra OCR (datalab-to/indra) on ONNX Runtime, in Python workers. Reads a
    /// born-digital PDF's text layer where it passes Indra's checks.
    case indra = "indra-ocr"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleVision: "Apple Vision OCR"
        case .indra: "Indra OCR"
        }
    }

    /// What the app's own windows call the engine.
    public var engine: String {
        switch self {
        case .appleVision: "Apple Vision"
        case .indra: "Indra"
        }
    }

    public func reads(_ kind: MediaKind) -> Bool {
        switch self {
        case .appleVision: true
        case .indra: [.pdf, .image, .text].contains(kind)
        }
    }

    /// What reads one kind of document, said when another model is asked to.
    public var readsDescription: String {
        switch self {
        case .appleVision: "PDFs, images, Word and HTML"
        case .indra: "PDFs and images"
        }
    }

    /// The model a docling client names as its `ocr_engine`: Lemmary sends the
    /// OCR model bound to its provider. docling's own name for Apple Vision,
    /// `ocrmac`, counts too; any other engine is nil, which means the model in
    /// memory.
    public init?(engine: String) {
        switch engine.trimmingCharacters(in: .whitespaces).lowercased() {
        case Self.appleVision.rawValue, "apple-vision", "ocrmac": self = .appleVision
        case Self.indra.rawValue, "indra": self = .indra
        default: return nil
        }
    }
}
