import CoreGraphics
import ImageIO
import LocalAIKit
import Vision

/// One image in, one `PageLayout` per document Vision finds in it out (a photo
/// of two receipts side by side is two).
public struct VisionPageReader: Sendable {
    public init() {}

    public func read(_ image: CGImage) async throws -> [PageLayout] {
        var request = RecognizeDocumentsRequest()
        // Language correction stays off. On macOS 27.0 and 27.0.1 an accurate
        // recognition with correction on intermittently never returns (it hung
        // after 404 calls in testing); with it off, thousands of calls ran
        // clean, and German and Russian letters read the same.
        //
        // minimumTextHeightFraction stays at Vision's 1/32 although that drops
        // some short isolated tokens (a table's "Q1", an invoice's position
        // numbers): every lower value tried also stopped lists being detected.
        request.textRecognitionOptions.useLanguageCorrection = false
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: image)
        return observations.map { PageLayout($0.document) }
    }
}

extension PageLayout {
    init(_ document: DocumentObservation.Container) {
        self.init(
            title: document.title.map { LayoutText(text: $0.transcript, box: LayoutBox($0.boundingRegion)) },
            paragraphs: document.paragraphs.map { LayoutText(text: $0.transcript, box: LayoutBox($0.boundingRegion)) },
            tables: document.tables.map(LayoutTable.init),
            lists: document.lists.map(LayoutList.init)
        )
    }
}

extension LayoutTable {
    init(_ table: DocumentObservation.Container.Table) {
        var seen = Set<[Int]>()
        var cells: [LayoutCell] = []
        // A cell spanning several rows is listed under each of them.
        for cell in table.rows.joined() {
            let key = [cell.rowRange.lowerBound, cell.rowRange.upperBound, cell.columnRange.lowerBound, cell.columnRange.upperBound]
            guard seen.insert(key).inserted else { continue }
            cells.append(LayoutCell(rows: cell.rowRange, columns: cell.columnRange, text: cell.content.text.transcript))
        }
        self.init(box: LayoutBox(table.boundingRegion), cells: cells)
    }
}

extension LayoutList {
    init(_ list: DocumentObservation.Container.List) {
        let ordered: Bool = switch list.items.first?.markerType {
        case .decimal, .decorativeDecimal, .compositeDecimal, .lowercaseLatin, .uppercaseLatin: true
        default: false
        }
        self.init(box: LayoutBox(list.boundingRegion), ordered: ordered, items: list.items.map(\.itemString))
    }
}

extension LayoutBox {
    init(_ region: NormalizedRegion) {
        let rect = region.normalizedPath.boundingBox
        self.init(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
    }
}
