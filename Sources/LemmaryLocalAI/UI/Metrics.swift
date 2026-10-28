import SwiftUI

/// The one place a size is written down.
enum Metrics {
    static let popoverWidth: CGFloat = 360
    static let settingsWidth: CGFloat = 480

    static let gutter: CGFloat = 12
    static let section: CGFloat = 12
    static let tight: CGFloat = 4
    static let rowSpacing: CGFloat = 2

    /// The status dot beside a service's name.
    static let dot: CGFloat = 8

    enum Text {
        static let heading = Font.system(size: 13, weight: .semibold)
        static let row = Font.system(size: 12, weight: .medium)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}
