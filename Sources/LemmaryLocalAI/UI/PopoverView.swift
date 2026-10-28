import AppKit
import LocalAIKit
import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    private let updater = AppUpdater.shared

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

            AddressRow(url: app.apiURL, status: app.api.status)

            ServiceRow(
                title: "Embeddings",
                engine: "bge-m3 on llama.cpp",
                status: app.embeddings.status,
                detail: modelDetail(ModelDescriptor.bgeM3.name, memoryDetail(app.embeddings))
            )
            if case .needsSetup = app.embeddings.status {
                ModelSetupView(store: app.modelStore, needs: "Embeddings need")
            }

            ServiceRow(
                title: "OCR",
                engine: "Apple Vision, docling-compatible",
                status: app.ocr.status,
                detail: modelDetail(OCRChatEndpoint.model, ocrDetail)
            )

            if app.textEnabled {
                ServiceRow(
                    title: "Text model",
                    engine: "\(app.textModel.descriptor.title) on llama.cpp",
                    status: app.text.status,
                    detail: modelDetail(app.textModel.descriptor.name, memoryDetail(app.text))
                )
                if case .needsSetup = app.text.status {
                    ModelSetupView(store: app.textModelStore, needs: "The text model needs")
                }
            }

            Divider()

            HStack {
                Button("Restart") { app.restartAll() }
                Button("Logs") { NSWorkspace.shared.open(Paths.logs) }
                if updater.isRelease {
                    Button(updater.menuTitle) { updater.checkForUpdates() }
                        .disabled(!updater.canCheck && updater.available == nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(Metrics.gutter)
        .frame(width: Metrics.popoverWidth)
        .onAppear { app.refreshAddress() }
    }

    private func memoryDetail(_ service: LlamaService) -> String? {
        service.memory.map { "\($0.formatted(.byteCount(style: .memory))) in memory" }
    }

    /// Lemmary's OpenAI provider asks for a model name for each job.
    private func modelDetail(_ name: String, _ more: String?) -> String {
        ["Model name \(name)", more].compactMap(\.self).joined(separator: " · ")
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

/// The one URL to give Lemmary: the base URL of an OpenAI provider that serves
/// all three. A docling provider takes it without `/v1`.
struct AddressRow: View {
    let url: String
    let status: ServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text("OpenAI base URL for Lemmary")
                .font(Metrics.Text.caption)
                .foregroundStyle(.secondary)
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
            if status != .ready {
                Text(status.label)
                    .font(Metrics.Text.caption)
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ServiceRow: View {
    let title: String
    let engine: String
    let status: ServiceStatus
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
    /// The start of the sentence that names the model, e.g. "Embeddings need".
    let needs: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            switch store.download {
            case .idle, .failed:
                Text("\(needs) \(store.descriptor.title) (\(store.descriptor.size.formatted(.byteCount(style: .file)))).")
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
        panel.title = "Choose the \(store.descriptor.title) GGUF"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.useExisting(url)
        }
    }
}
