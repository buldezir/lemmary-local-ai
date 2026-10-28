import SwiftUI

enum ServiceStatus: Equatable {
    case stopped
    case starting(String)
    case ready
    /// Waiting on the user, e.g. for the model to be downloaded.
    case needsSetup(String)
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting(let what): what
        case .ready: "Ready"
        case .needsSetup(let what): what
        case .failed(let why): why
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .starting, .needsSetup: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var isProblem: Bool {
        switch self {
        case .failed, .needsSetup: true
        default: false
        }
    }
}
