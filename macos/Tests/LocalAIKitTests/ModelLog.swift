import Foundation
import Synchronization
@testable import LocalAIKit

/// The model each conversion was asked for, in order.
final class ModelLog: Sendable {
    private let seen = Mutex<[OCRModel?]>([])

    func append(_ model: OCRModel?) {
        seen.withLock { $0.append(model) }
    }

    var models: [OCRModel?] { seen.withLock { $0 } }
}
