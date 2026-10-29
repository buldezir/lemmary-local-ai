import CoreGraphics
import Foundation
import ImageIO
import LocalAIKit
import Testing
import UniformTypeIdentifiers
import Vision
@testable import VisionOCR

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

/// What Vision returned for `Fixtures/twocol.png` on macOS 27.0.1, encoded with
/// DocumentObservation's own Codable conformance. It pins the adapter and the
/// renderer to a real observation without running Vision.
@Test func realObservationRendersInReadingOrder() throws {
    let observation = try JSONDecoder().decode(DocumentObservation.self, from: Data(contentsOf: fixture("twocol-observation.json")))
    let markdown = MarkdownRenderer.render(PageLayout(observation.document))

    #expect(markdown.hasPrefix("## Quarterly Report\n\nAlpha column."))
    let left = try #require(markdown.range(of: "Second left paragraph"))
    let right = try #require(markdown.range(of: "Beta column"))
    let closing = try #require(markdown.range(of: "Closing remark"))
    #expect(left.lowerBound < right.lowerBound)
    #expect(right.lowerBound < closing.lowerBound)
    #expect(markdown.hasSuffix("1. First numbered point\n2. Second numbered point"))
}

private func blankPDF(pages: Int, size: CGSize, password: String? = nil) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: size)
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password
    }
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

@Test func pdfPagesRenderAt300DPI() throws {
    let pdf = try PDFPages(url: try blankPDF(pages: 2, size: CGSize(width: 612, height: 792)))
    #expect(pdf.count == 2)
    let page = try pdf.render(1)
    #expect(page.width == 2550)
    #expect(page.height == 3300)
}

@Test func posterPagesAreCappedInsteadOfAllocatingGigabytes() throws {
    let page = try PDFPages(url: try blankPDF(pages: 1, size: CGSize(width: 3000, height: 2000))).render(0)
    #expect(max(page.width, page.height) == Int(PDFPages.maxPixels))
}

@Test func aPasswordProtectedPDFIsLocked() throws {
    #expect(throws: DocumentReadError.locked) {
        try PDFPages(url: try blankPDF(pages: 1, size: CGSize(width: 100, height: 100), password: "secret"))
    }
}

@Test func garbageIsUnreadableNotACrash() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "garbage-\(UUID().uuidString)")
    try Data("not a document".utf8).write(to: url)
    #expect(throws: DocumentReadError.self) { try PDFPages(url: url) }
    #expect(throws: DocumentReadError.self) { try ImageFrames.load(url) }
}

/// A phone photo taken in portrait is stored landscape with an EXIF rotation;
/// it must reach Vision upright.
@Test func exifOrientationIsApplied() throws {
    let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let stored = try #require(context.makeImage())
    let url = FileManager.default.temporaryDirectory.appending(path: "rotated-\(UUID().uuidString).jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let frames = try ImageFrames.load(url)
    #expect(frames.count == 1)
    #expect(frames[0].width == 200)
    #expect(frames[0].height == 400)
}

/// A screenshot with a transparent background must not reach Vision as text
/// on black.
@Test func transparencyBecomesWhite() throws {
    let context = try #require(CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let transparent = try #require(context.makeImage())
    let url = FileManager.default.temporaryDirectory.appending(path: "transparent-\(UUID().uuidString).png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, transparent, nil)
    #expect(CGImageDestinationFinalize(destination))

    let frame = try #require(try ImageFrames.load(url).first)
    #expect(frame.alphaInfo == .noneSkipLast)
    let pixels = try #require(frame.dataProvider?.data as Data?)
    #expect(pixels.prefix(3) == Data([255, 255, 255]))
}

/// GitHub's macOS runners are virtual machines, where Vision's document reader
/// fails at once with `.unknownError`; the same Xcode and macOS pass on the Mac
/// mini.
private let isVirtualMachine: Bool = {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
}()

/// The real thing, once: Vision on the two-column fixture. Slow the first time
/// a new test binary runs it (Vision loads its models), fast after.
@Test(.timeLimit(.minutes(3)), .enabled(if: !isVirtualMachine, "Vision's document reader fails in a virtual machine"))
@MainActor
func visionReadsTheFixture() async throws {
    let output = try await DocumentReader().read(try fixture("twocol.png"), kind: .image) { _, _ in }
    #expect(output.pages == 1)
    #expect(output.markdown.contains("Quarterly Report"))
    #expect(output.markdown.contains("Closing remark below the table"))
}
