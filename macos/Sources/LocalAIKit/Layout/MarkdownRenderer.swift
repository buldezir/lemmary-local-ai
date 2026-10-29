import Foundation

/// Turns page layouts into the markdown docling-serve would return in
/// `md_content`: a `##` heading for the title, paragraphs, pipe tables and lists.
public enum MarkdownRenderer {
    public static func render(pages: [PageLayout]) -> String {
        pages.map { render($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func render(_ page: PageLayout) -> String {
        flow(page).compactMap(markdown).joined(separator: "\n\n")
    }

    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case table(LayoutTable)
        case list(LayoutList)
    }

    /// Paragraphs keep Vision's reading order, which is the only part of the
    /// page that knows about columns. Tables and lists have no place in that
    /// order of their own, so each is slotted in after the text above it;
    /// sorting everything by height instead would interleave the lines of a
    /// two-column page.
    static func flow(_ page: PageLayout) -> [Block] {
        let regions: [(box: LayoutBox, block: Block)] =
            page.tables.map { ($0.box, .table($0)) } + page.lists.map { ($0.box, .list($0)) }
        let slack = 0.005

        var placed: [(box: LayoutBox, block: Block)] = []
        var titleEmitted = false
        for paragraph in page.paragraphs {
            let (x, y) = (paragraph.box.midX, paragraph.box.midY)
            if regions.contains(where: { $0.box.contains(x: x, y: y, slack: slack) }) {
                continue
            }
            if let title = page.title, !titleEmitted, title.box.contains(x: x, y: y, slack: slack) {
                placed.append((paragraph.box, .heading(title.text)))
                titleEmitted = true
                continue
            }
            placed.append((paragraph.box, .paragraph(paragraph.text)))
        }
        if let title = page.title, !titleEmitted {
            placed.insert((title.box, .heading(title.text)), at: 0)
        }

        for region in regions.sorted(by: { $0.box.maxY > $1.box.maxY }) {
            placed.insert(region, at: insertionIndex(for: region.box, in: placed.map(\.box)))
        }
        return placed.map(\.block)
    }

    /// "Above" depends on whether the block sits inside a column. If text runs
    /// down beside it, it belongs to its own column and follows the last text
    /// above it in that column. If nothing is beside it, it has a band of the
    /// page to itself and follows everything above it, whichever column.
    static func insertionIndex(for box: LayoutBox, in flow: [LayoutBox]) -> Int {
        let hasNeighbour = flow.contains {
            !$0.overlapsHorizontally(box) && min($0.maxY, box.maxY) > max($0.minY, box.minY)
        }
        let sameColumn: (LayoutBox) -> Bool = { hasNeighbour ? $0.overlapsHorizontally(box) : true }
        if let above = flow.lastIndex(where: { sameColumn($0) && $0.midY > box.maxY }) {
            return above + 1
        }
        if let below = flow.firstIndex(where: { sameColumn($0) && $0.midY < box.minY }) {
            return below
        }
        return flow.count
    }

    static func markdown(_ block: Block) -> String? {
        switch block {
        case .heading(let text):
            let line = singleLine(text)
            return line.isEmpty ? nil : "## " + line
        case .paragraph(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .table(let table):
            return tableMarkdown(table)
        case .list(let list):
            let items = list.items.map(singleLine).filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return items.enumerated()
                .map { list.ordered ? "\($0.offset + 1). \($0.element)" : "- \($0.element)" }
                .joined(separator: "\n")
        }
    }

    static func tableMarkdown(_ table: LayoutTable) -> String? {
        guard let lastRow = table.cells.map(\.rows.upperBound).max(),
              let lastColumn = table.cells.map(\.columns.upperBound).max() else { return nil }
        var grid = Array(repeating: Array(repeating: "", count: lastColumn + 1), count: lastRow + 1)
        // A spanning cell is written once, at its top-left; the rest of its
        // span stays empty, which is as close as a pipe table gets to a merge.
        for cell in table.cells where grid[cell.rows.lowerBound][cell.columns.lowerBound].isEmpty {
            grid[cell.rows.lowerBound][cell.columns.lowerBound] =
                singleLine(cell.text).replacingOccurrences(of: "|", with: "\\|")
        }
        let rows = grid.filter { $0.contains { !$0.isEmpty } }
        guard !rows.isEmpty else { return nil }
        var lines = rows.map { "| " + $0.joined(separator: " | ") + " |" }
        lines.insert("|" + String(repeating: " --- |", count: lastColumn + 1), at: 1)
        return lines.joined(separator: "\n")
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
