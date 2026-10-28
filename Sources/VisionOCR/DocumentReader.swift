import AppKit
import CoreGraphics
import Foundation
import LocalAIKit

/// Reads a whole document into markdown, reporting each page as it finishes.
public struct DocumentReader: Sendable {
    public var pageReader: VisionPageReader

    public init(pageReader: VisionPageReader = VisionPageReader()) {
        self.pageReader = pageReader
    }

    public struct Output: Sendable, Equatable {
        public var markdown: String
        public var pages: Int
    }

    @MainActor
    public func read(_ url: URL, kind: MediaKind, progress: (Int, Int) -> Void) async throws -> Output {
        switch kind {
        case .pdf:
            let pdf = try PDFPages(url: url)
            progress(0, pdf.count)
            var layouts: [PageLayout] = []
            for index in 0..<pdf.count {
                // Rendered inside the loop so each bitmap is released before the
                // next page is drawn.
                let image = try pdf.render(index)
                layouts += try await pageReader.read(image)
                progress(index + 1, pdf.count)
            }
            return Output(markdown: MarkdownRenderer.render(pages: layouts), pages: pdf.count)
        case .image:
            let frames = try ImageFrames.load(url)
            progress(0, frames.count)
            var layouts: [PageLayout] = []
            for (index, frame) in frames.enumerated() {
                layouts += try await pageReader.read(frame)
                progress(index + 1, frames.count)
            }
            return Output(markdown: MarkdownRenderer.render(pages: layouts), pages: frames.count)
        case .text:
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return Output(markdown: text, pages: 1)
        case .html:
            return Output(markdown: try Self.attributedText(url, type: .html), pages: 1)
        case .docx:
            return Output(markdown: try Self.attributedText(url, type: .officeOpenXML), pages: 1)
        }
    }

    /// HTML and Word documents have their text already; AppKit's importers get
    /// it out without OCR. They must run on the main thread.
    @MainActor
    static func attributedText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .html {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        do {
            let text = try NSAttributedString(url: url, options: options, documentAttributes: nil).string
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw DocumentReadError.unreadable("could not read the \(type == .html ? "HTML" : "Word") document")
        }
    }

    /// One recognition on an invoice drawn here, before the worker says it is
    /// ready. Vision's models are loaded by the first recognition in a process
    /// (25 to 40 seconds when no other process has them), so this keeps that
    /// out of the first real request.
    ///
    /// It does not cover everything: some pages still cost a further one-off
    /// 12 seconds in each worker. Which ones could not be pinned down; a
    /// near-identical copy of such a page in the warm-up did not prevent it.
    /// The default page limit leaves room for it.
    @MainActor
    public func warmUp() async throws -> String {
        let html = """
            <html><head><meta charset="utf-8"><style>td,th{border:1px solid #000}</style></head>
            <body style="font-family: Helvetica; font-size: 15px">
            <h1>Stadtwerke Musterstadt GmbH</h1>
            <p>Herrn Max Mustermann<br>Lindenstraße 12<br>10115 Berlin</p>
            <h2>Rechnung Nr. 2024-4711</h2>
            <p>Sehr geehrter Herr Mustermann, für den Abrechnungszeitraum 01.01.2024 bis 31.03.2024 stellen wir
            Ihnen folgende Leistungen in Rechnung. Bitte überweisen Sie den Betrag innerhalb von vierzehn Tagen.</p>
            <table border="1" cellpadding="6" style="border-collapse: collapse">
            <tr><th>Pos.</th><th>Beschreibung</th><th>Menge</th><th>Einzelpreis</th><th>Betrag</th></tr>
            <tr><td>1</td><td>Arbeitspreis Strom</td><td>812 kWh</td><td>0,3120 €</td><td>253,34 €</td></tr>
            <tr><td>2</td><td>Grundpreis</td><td>3 Monate</td><td>12,50 €</td><td>37,50 €</td></tr>
            <tr><td>3</td><td>Messstellenbetrieb</td><td>3 Monate</td><td>7,20 €</td><td>21,60 €</td></tr>
            <tr><td></td><td><b>Summe netto</b></td><td></td><td></td><td>312,44 €</td></tr>
            </table>
            <p>Hinweise:</p>
            <ul><li>Zahlbar ohne Abzug bis 15.04.2024.</li><li>IBAN: DE89 3704 0044 0532 0130 00</li>
            <li>Bei Fragen erreichen Sie uns unter 030 123456.</li></ul>
            <p>Mit freundlichen Grüßen<br>Ihre Stadtwerke</p>
            </body></html>
            """
        let page = try NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
        // A US letter page at 180 dpi.
        let size = NSSize(width: 680, height: 880)
        let scale: CGFloat = 2.5
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DocumentReadError.unreadable("could not allocate the warm-up image")
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        page.draw(in: NSRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80))
        NSGraphicsContext.restoreGraphicsState()

        guard let drawn = bitmap.cgImage else {
            throw DocumentReadError.unreadable("could not draw the warm-up image")
        }
        let image = try CanonicalBitmap.make(width: drawn.width, height: drawn.height) { context in
            context.draw(drawn, in: CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
        }
        return MarkdownRenderer.render(pages: try await pageReader.read(image))
    }
}
