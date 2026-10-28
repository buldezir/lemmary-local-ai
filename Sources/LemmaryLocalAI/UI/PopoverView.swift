import AppKit
import LocalAIKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.section) {
            HStack {
                Text("Lemmary Local AI")
                    .font(Metrics.Text.heading)
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            ServiceRow(
                title: "Embeddings",
                engine: "bge-m3 on llama.cpp",
                status: app.embeddings.status,
                url: app.embeddingsURL,
                detail: app.embeddings.memory.map { "\($0.formatted(.byteCount(style: .memory))) in memory" }
            )
            if case .needsSetup = app.embeddings.status {
                ModelSetupView(store: app.modelStore)
            }

            ServiceRow(
                title: "OCR",
                engine: "Apple Vision, docling-compatible",
                status: app.ocr.status,
                url: app.ocrURL,
                detail: ocrDetail
            )

            Divider()

            HStack {
                Button("Restart") { app.restartAll() }
                Button("Logs") { NSWorkspace.shared.open(Paths.logs) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(Metrics.gutter)
        .frame(width: Metrics.popoverWidth)
        .onAppear { app.refreshAddress() }
    }

    private var ocrDetail: String? {
        let ocr = app.ocr
        guard let last = ocr.lastConversion else { return nil }
        var counts = "\(ocr.converted) converted"
        if ocr.failed > 0 {
            counts += ", \(ocr.failed) failed"
        }
        let seconds = last.duration.formatted(.number.precision(.fractionLength(1)))
        if let failure = last.failure {
            return "\(counts) · last failed: \(failure)"
        }
        let pages = last.pages.map { $0 == 1 ? "1 page" : "\($0) pages" } ?? ""
        return "\(counts) · last \(pages) in \(seconds)s"
    }
}

struct ServiceRow: View {
    let title: String
    let engine: String
    let status: ServiceStatus
    let url: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: Metrics.tight * 1.5) {
                Circle()
                    .fill(status.color)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                Text(title)
                    .font(Metrics.Text.row)
                Text(engine)
                    .font(Metrics.Text.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(status.label)
                .font(Metrics.Text.caption)
                .foregroundStyle(status == .ready ? .secondary : status.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.tight) {
                Text(url)
                    .font(Metrics.Text.mono)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the URL to give Lemmary")
            }
            if let detail {
                Text(detail)
                    .font(Metrics.Text.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct ModelSetupView: View {
    let store: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            switch store.download {
            case .idle, .failed:
                Text("Embeddings need \(store.descriptor.name) (\(store.descriptor.size.formatted(.byteCount(style: .file)))).")
                    .font(Metrics.Text.caption)
                HStack {
                    Button("Download") { store.startDownload() }
                    Button("Use Existing File…") { chooseFile() }
                }
                .controlSize(.small)
                if case .failed(let why) = store.download {
                    Text(why)
                        .font(Metrics.Text.caption)
                        .foregroundStyle(.red)
                }
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                HStack {
                    Text("\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                        .font(Metrics.Text.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { store.cancelDownload() }
                        .controlSize(.small)
                }
            case .verifying:
                HStack(spacing: Metrics.tight) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying checksum…")
                        .font(Metrics.Text.caption)
                }
            }
        }
        .padding(.leading, Metrics.dot + Metrics.tight * 1.5)
    }

    private func chooseFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose bge-m3 GGUF"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.useExisting(url)
        }
    }
}
