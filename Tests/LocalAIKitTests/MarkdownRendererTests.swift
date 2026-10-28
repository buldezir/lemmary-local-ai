import Testing
@testable import LocalAIKit

private func box(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> LayoutBox {
    LayoutBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

private func text(_ s: String, _ b: LayoutBox) -> LayoutText {
    LayoutText(text: s, box: b)
}

@Test func titleBecomesAHeadingInPlace() {
    let page = PageLayout(
        title: text("Quarterly Report", box(0.06, 0.93, 0.37, 0.96)),
        paragraphs: [text("Quarterly Report", box(0.06, 0.93, 0.37, 0.96)), text("Body.", box(0.06, 0.8, 0.9, 0.85))]
    )
    #expect(MarkdownRenderer.render(page) == "## Quarterly Report\n\nBody.")
}

/// The layout Vision reported for a real two-column test page: paragraphs in
/// column order, then a full-width table below both columns. Sorting by height
/// would interleave the columns; the table must land after both.
@Test func tableGoesAfterBothColumnsAboveIt() {
    let table = LayoutTable(box: box(0.06, 0.50, 0.30, 0.60), cells: [
        LayoutCell(rows: 0...0, columns: 0...0, text: "Quarter"),
        LayoutCell(rows: 0...0, columns: 1...1, text: "Revenue"),
        LayoutCell(rows: 1...1, columns: 0...0, text: "Q1"),
        LayoutCell(rows: 1...1, columns: 1...1, text: "1.2 M"),
    ])
    let page = PageLayout(
        paragraphs: [
            text("Left one", box(0.06, 0.84, 0.45, 0.90)),
            text("Left two", box(0.06, 0.79, 0.43, 0.82)),
            text("Right one", box(0.53, 0.84, 0.92, 0.89)),
            text("Right two", box(0.53, 0.79, 0.92, 0.83)),
            text("Quarter Revenue", box(0.07, 0.58, 0.23, 0.59)),
            text("Q1 1.2 M", box(0.07, 0.55, 0.23, 0.56)),
            text("Closing remark", box(0.06, 0.42, 0.63, 0.44)),
        ],
        tables: [table]
    )
    #expect(MarkdownRenderer.render(page) == """
        Left one

        Left two

        Right one

        Right two

        | Quarter | Revenue |
        | --- | --- |
        | Q1 | 1.2 M |

        Closing remark
        """)
}

@Test func tableInTheLeftColumnStaysInTheLeftColumn() {
    let table = LayoutTable(box: box(0.06, 0.60, 0.45, 0.70), cells: [LayoutCell(rows: 0...0, columns: 0...0, text: "cell")])
    let page = PageLayout(
        paragraphs: [
            text("Left above", box(0.06, 0.80, 0.45, 0.90)),
            text("Left below", box(0.06, 0.40, 0.45, 0.50)),
            text("Right", box(0.55, 0.40, 0.92, 0.90)),
        ],
        tables: [table]
    )
    #expect(MarkdownRenderer.flow(page) == [.paragraph("Left above"), .table(table), .paragraph("Left below"), .paragraph("Right")])
}

@Test func blockAtTheTopOfItsColumnGoesBeforeWhatFollowsIt() {
    let list = LayoutList(box: box(0.06, 0.85, 0.45, 0.95), ordered: false, items: ["a"])
    let page = PageLayout(paragraphs: [text("Under the list", box(0.06, 0.70, 0.45, 0.80))], lists: [list])
    #expect(MarkdownRenderer.flow(page) == [.list(list), .paragraph("Under the list")])
}

@Test func listsRenderOrderedAndUnordered() {
    #expect(MarkdownRenderer.markdown(.list(LayoutList(box: box(0, 0, 1, 1), ordered: true, items: ["First", " Second\npoint "]))) == "1. First\n2. Second point")
    #expect(MarkdownRenderer.markdown(.list(LayoutList(box: box(0, 0, 1, 1), ordered: false, items: ["x", ""]))) == "- x")
}

@Test func spanningCellsAreWrittenOnceAndPipesEscaped() {
    let table = LayoutTable(box: box(0, 0, 1, 1), cells: [
        LayoutCell(rows: 0...0, columns: 0...1, text: "Wide header"),
        LayoutCell(rows: 1...1, columns: 0...0, text: "a|b"),
        LayoutCell(rows: 1...1, columns: 1...1, text: "line\nbreak"),
        LayoutCell(rows: 2...2, columns: 0...1, text: "  "),
    ])
    #expect(MarkdownRenderer.tableMarkdown(table) == """
        | Wide header |  |
        | --- | --- |
        | a\\|b | line break |
        """)
}

@Test func emptyPagesRenderNothing() {
    #expect(MarkdownRenderer.render(pages: [PageLayout(), PageLayout(paragraphs: [text("x", box(0, 0, 1, 1))])]) == "x")
}
