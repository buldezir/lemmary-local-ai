import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DocumentReadError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case locked

    public var description: String {
        switch self {
        case .unreadable(let why): why
        case .locked: "the PDF is password-protected"
        }
    }
}

/// Every page reaches Vision as the same kind of bitmap: 8-bit sRGB, no alpha,
/// on white. A PNG with a transparent background would otherwise reach Vision
/// as text on black, and what ImageIO decodes into (grayscale, P3, 16-bit,
/// premultiplied or not) stops being a variable.
enum CanonicalBitmap {
    static func make(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DocumentReadError.unreadable("could not allocate a \(width)×\(height) page")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        draw(context)
        guard let image = context.makeImage() else {
            throw DocumentReadError.unreadable("could not draw a \(width)×\(height) page")
        }
        return image
    }
}

/// The pages of a PDF as images, rendered one at a time on demand so a long
/// document never holds more than one bitmap.
public struct PDFPages {
    public static let dpi: CGFloat = 300
    /// A poster-sized page at 300 dpi would be a bitmap of hundreds of
    /// megabytes; past this the page is rendered smaller instead.
    public static let maxPixels: CGFloat = 5000

    private let document: CGPDFDocument

    public init(url: URL) throws {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw DocumentReadError.unreadable("not a readable PDF")
        }
        // Many PDFs are "encrypted" with an empty user password only to set
        // permissions; those open with "".
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw DocumentReadError.locked
        }
        self.document = document
    }

    public var count: Int { document.numberOfPages }

    /// `index` is zero-based.
    public func render(_ index: Int) throws -> CGImage {
        guard let page = document.page(at: index + 1) else {
            throw DocumentReadError.unreadable("page \(index + 1) is missing")
        }
        let box = page.getBoxRect(.cropBox)
        let quarterTurn = (page.rotationAngle / 90) % 2 != 0
        let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else {
            throw DocumentReadError.unreadable("page \(index + 1) has no size")
        }
        let scale = min(Self.dpi / 72, Self.maxPixels / max(size.width, size.height))
        return try CanonicalBitmap.make(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded())) { context in
            context.scaleBy(x: scale, y: scale)
            // The drawing transform applies the page's /Rotate. It never scales
            // up, which is why the context is scaled first and the target is the
            // page's own size.
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
    }
}

/// The images in an image file, upright.
public enum ImageFrames {
    /// Vision copes with large images, but a 48-megapixel phone photo gains
    /// nothing over this and costs time and memory.
    public static let maxPixels = 6000

    public static func load(_ url: URL) throws -> [CGImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DocumentReadError.unreadable("not a readable image")
        }
        // Only TIFF means "pages" by having several images. In a GIF they are
        // animation frames and in HEIC usually a burst or a thumbnail.
        let isTIFF = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)?.conforms(to: .tiff) ?? false
        let count = isTIFF ? CGImageSourceGetCount(source) : min(1, CGImageSourceGetCount(source))
        guard count > 0 else {
            throw DocumentReadError.unreadable("the image has no frames")
        }
        return try (0..<count).map { index in
            let largest = pixelSize(source, index)
            // The thumbnail path applies EXIF orientation, so a phone photo
            // taken sideways arrives upright.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(1, largest)),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw DocumentReadError.unreadable("could not decode image \(index + 1)")
            }
            // Transparent areas become white, as they would on paper.
            return try CanonicalBitmap.make(width: image.width, height: image.height) { context in
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
    }

    private static func pixelSize(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }
}
