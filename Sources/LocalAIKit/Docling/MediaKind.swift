import Foundation

/// What the worker knows how to read. Anything else is refused before a worker
/// is started.
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case pdf
    case image
    /// Plain text and CSV: returned as they are.
    case text
    case html
    case docx
}

public struct ResolvedMedia: Sendable, Equatable {
    public var mimeType: String
    public var kind: MediaKind?
}

/// Decides what an upload is, in the order docling-serve does: the part's
/// declared type first, then the filename, then the bytes themselves.
///
/// Lemmary declares the type on purpose (its upload names are generated), so the
/// declaration wins whenever it names something specific; `octet-stream` or no
/// type at all falls through to the extension and then to magic bytes.
public enum MediaType {
    public static func resolve(declared: String?, filename: String?, data: Data) -> ResolvedMedia {
        if let declared = normalize(declared), declared != "application/octet-stream" {
            return ResolvedMedia(mimeType: declared, kind: kind(forMIME: declared))
        }
        if let ext = filename.flatMap({ URL(fileURLWithPath: $0).pathExtension.lowercased() }),
           let mime = byExtension[ext] {
            return ResolvedMedia(mimeType: mime, kind: kind(forMIME: mime))
        }
        if let mime = sniff(data) {
            return ResolvedMedia(mimeType: mime, kind: kind(forMIME: mime))
        }
        return ResolvedMedia(mimeType: normalize(declared) ?? "application/octet-stream", kind: nil)
    }

    public static func kind(forMIME mime: String) -> MediaKind? {
        switch mime {
        case "application/pdf":
            .pdf
        case "image/jpeg", "image/jpg", "image/png", "image/webp", "image/tiff", "image/gif",
             "image/bmp", "image/x-ms-bmp", "image/heic", "image/heif":
            .image
        case "text/plain", "text/csv", "text/markdown":
            .text
        case "text/html", "application/xhtml+xml":
            .html
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            .docx
        default:
            nil
        }
    }

    /// The suffix the worker's input file gets, so ImageIO and NSAttributedString
    /// see a name that agrees with the bytes.
    public static func fileExtension(forMIME mime: String) -> String {
        byExtension.first { $0.value == mime }?.key ?? "bin"
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = HeaderValue.parse(raw).value.lowercased()
        return value.isEmpty ? nil : value
    }

    private static let byExtension: [String: String] = [
        "pdf": "application/pdf",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "heic": "image/heic",
        "heif": "image/heif",
        "txt": "text/plain",
        "csv": "text/csv",
        "md": "text/markdown",
        "html": "text/html",
        "htm": "text/html",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ]

    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        func has(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + prefix.count && Array(b[offset..<(offset + prefix.count)]) == prefix
        }
        if has(Array("%PDF".utf8)) { return "application/pdf" }
        if has([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if has([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if has(Array("RIFF".utf8)) && has(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if has(Array("GIF8".utf8)) { return "image/gif" }
        if has(Array("BM".utf8)) { return "image/bmp" }
        if has(Array("ftyp".utf8), at: 4) {
            let brand = String(decoding: b.count >= 12 ? Array(b[8..<12]) : [], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        return nil
    }
}
