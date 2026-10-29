import Foundation

/// A rectangle in normalized page coordinates with Vision's convention: origin
/// at the bottom-left, so a larger `maxY` is nearer the top of the page.
public struct LayoutBox: Sendable, Equatable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public func contains(x: Double, y: Double, slack: Double = 0) -> Bool {
        x >= minX - slack && x <= maxX + slack && y >= minY - slack && y <= maxY + slack
    }

    public func overlapsHorizontally(_ other: LayoutBox) -> Bool {
        min(maxX, other.maxX) > max(minX, other.minX)
    }
}

public struct LayoutText: Sendable, Equatable, Codable {
    public var text: String
    public var box: LayoutBox

    public init(text: String, box: LayoutBox) {
        self.text = text
        self.box = box
    }
}

public struct LayoutCell: Sendable, Equatable, Codable {
    public var rows: ClosedRange<Int>
    public var columns: ClosedRange<Int>
    public var text: String

    public init(rows: ClosedRange<Int>, columns: ClosedRange<Int>, text: String) {
        self.rows = rows
        self.columns = columns
        self.text = text
    }
}

public struct LayoutTable: Sendable, Equatable, Codable {
    public var box: LayoutBox
    public var cells: [LayoutCell]

    public init(box: LayoutBox, cells: [LayoutCell]) {
        self.box = box
        self.cells = cells
    }
}

public struct LayoutList: Sendable, Equatable, Codable {
    public var box: LayoutBox
    public var ordered: Bool
    public var items: [String]

    public init(box: LayoutBox, ordered: Bool, items: [String]) {
        self.box = box
        self.ordered = ordered
        self.items = items
    }
}

/// One page as Vision's document reader sees it, reduced to what markdown can
/// say. Kept free of Vision types so the renderer can be tested with pages
/// written by hand.
///
/// `paragraphs` is in Vision's reading order, which already follows columns,
/// and it includes the text of table cells and list items: those are claimed by
/// their table or list when rendering.
public struct PageLayout: Sendable, Equatable, Codable {
    public var title: LayoutText?
    public var paragraphs: [LayoutText]
    public var tables: [LayoutTable]
    public var lists: [LayoutList]

    public init(title: LayoutText? = nil, paragraphs: [LayoutText] = [], tables: [LayoutTable] = [], lists: [LayoutList] = []) {
        self.title = title
        self.paragraphs = paragraphs
        self.tables = tables
        self.lists = lists
    }
}
