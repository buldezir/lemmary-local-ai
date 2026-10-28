import Foundation
import LocalAIKit
import VisionOCR

// ocr-worker serve: the long-lived worker the app pools (protocol in
// WorkerProtocol.swift). ocr-worker convert <file> <kind>: one document, result
// as JSON on stdout, for trying things by hand.

func send(_ message: WorkerMessage) {
    FileHandle.standardOutput.write(message.line())
}

func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

@MainActor
func read(_ reader: DocumentReader, _ url: URL, _ kind: MediaKind, progress: (Int, Int) -> Void) async -> WorkerResult {
    do {
        let output = try await reader.read(url, kind: kind, progress: progress)
        return .success(markdown: output.markdown, pages: output.pages)
    } catch let error as DocumentReadError {
        return .failure(error.description)
    } catch {
        return .failure("Vision could not read the document: \(error.localizedDescription)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let reader = DocumentReader()

switch arguments.first {
case "serve":
    var warmUpError: String?
    do {
        _ = try await reader.warmUp()
    } catch {
        warmUpError = "\(error)"
    }
    send(.ready(error: warmUpError))
    let decoder = JSONDecoder()
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        guard let request = try? decoder.decode(WorkerRequest.self, from: Data(line.utf8)) else {
            log("unreadable request: \(line.prefix(200))")
            continue
        }
        let result = await read(reader, URL(fileURLWithPath: request.path), request.kind) { page, total in
            send(.progress(id: request.id, page: page, total: total))
        }
        send(.result(id: request.id, result))
    }
case "convert" where arguments.count == 3:
    guard let kind = MediaKind(rawValue: arguments[2]) else {
        log("unknown kind \(arguments[2])")
        exit(64)
    }
    let result = await read(reader, URL(fileURLWithPath: arguments[1]), kind) { page, total in
        log("page \(page) of \(total)")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted]
    FileHandle.standardOutput.write((try? encoder.encode(result)) ?? Data())
default:
    log("usage: ocr-worker serve | ocr-worker convert <file> <\(MediaKind.allCases.map(\.rawValue).joined(separator: "|"))>")
    exit(64)
}
