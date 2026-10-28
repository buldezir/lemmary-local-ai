import AppKit
import LocalAIKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.Key.allowRemote) private var allowRemote = true
    @AppStorage(Preferences.Key.port) private var port = 5001
    @AppStorage(Preferences.Key.contextTokens) private var contextTokens = 8192
    @AppStorage(Preferences.Key.parallelConversions) private var parallelConversions = 2
    @AppStorage(Preferences.Key.pageTimeout) private var pageTimeout = 60
    @AppStorage(Preferences.Key.textModelEnabled) private var textModelEnabled = false
    @AppStorage(Preferences.Key.textModel) private var textModel = TextModel.gemma4E4B.rawValue
    @AppStorage(Preferences.Key.textContextTokens) private var textContextTokens = 16384
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        Preferences.launchAtLogin = newValue
                        launchAtLogin = Preferences.launchAtLogin
                    }
                ))
                if Preferences.isRunningFromBuildDirectory {
                    caption("This build is running from .build, so it would register that copy. Install it first with Scripts/release.sh --install.")
                }
                caption("The services run while you are logged in. On a headless Mac, turn on automatic login and set it never to sleep.")
            }

            Section("Network") {
                Toggle("Accept connections from other computers", isOn: $allowRemote)
                caption("Lemmary usually runs on another machine and reaches this Mac over the LAN. Off, the port listens on 127.0.0.1 only. There is no authentication either way.")
                TextField("Port", value: $port, format: .number.grouping(.never))
                caption("Embeddings, OCR and the text model all answer on this one port, so Lemmary needs one OpenAI provider for all three.")
            }

            Section("Embeddings") {
                modelFile(app.modelStore)
                Picker("Longest input", selection: $contextTokens) {
                    Text("8192 tokens (bge-m3's maximum)").tag(8192)
                    Text("6144 tokens (less memory)").tag(6144)
                }
                caption("Lemmary caps an input at 8000 characters, up to about 5,700 tokens of dense text. A smaller window fails those inputs instead of embedding them.")
            }

            Section("OCR") {
                Picker("Documents at once", selection: $parallelConversions) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                }
                Picker("Give up on a page after", selection: $pageTimeout) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                caption("A page normally takes well under a second. One that makes no progress for this long has hit the Vision hang; it is stopped and tried once more.")
            }

            Section("Text model") {
                Toggle("Serve a text model", isOn: $textModelEnabled)
                caption("For Lemmary's metadata extraction: title, date, tags and summary. In Lemmary, choose this model's name on the same OpenAI provider, for extraction only.")
                Picker("Model", selection: Binding(
                    get: { selectedTextModel.rawValue },
                    set: { textModel = $0 }
                )) {
                    ForEach(offeredTextModels, id: \.self) { model in
                        Text(model.pickerLabel).tag(model.rawValue)
                    }
                }
                caption(selectedTextModel.note)
                caption(textModelsCaption)
                modelFile(app.textModelStores[selectedTextModel]!)
                Picker("Context", selection: $textContextTokens) {
                    Text("16,384 tokens").tag(16384)
                    Text("32,768 tokens (0.3 to 0.6 GB more)").tag(32768)
                }
                caption("A document Lemmary sends is at most about 7,000 tokens. The rest is for the prompt, which grows with the archive's tags, correspondents and document types.")
            }

            UpdatesSection()

            Section {
                HStack {
                    Text("Version \(AppInfo.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply and Restart Services") { app.restartAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Metrics.settingsMinSize.width, minHeight: Metrics.settingsMinSize.height)
        // A Settings window has a fixed size without this; the scene's
        // `windowResizability` does not change that.
        .windowResizeBehavior(.enabled)
        .onAppear { launchAtLogin = Preferences.launchAtLogin }
    }

    /// The larger models only on a Mac with the memory for them.
    private var offeredTextModels: [TextModel] {
        TextModel.offered(physicalMemory: Preferences.physicalMemory)
    }

    private var selectedTextModel: TextModel {
        TextModel.resolve(textModel, physicalMemory: Preferences.physicalMemory)
    }

    /// Says where the numbers come from, and which models are missing and why,
    /// so a shorter list does not look like a bug.
    private var textModelsCaption: String {
        var text = "Memory and times from a Mac mini M6, beside the embeddings and OCR; older chips take longer."
        let unoffered = TextModel.allCases.filter { !offeredTextModels.contains($0) }
        if !unoffered.isEmpty {
            let needs = unoffered.map { "\($0.descriptor.title) (\($0.minimumMemoryGB) GB)" }.joined(separator: ", ")
            text += " Needs more memory than this Mac's \(Preferences.physicalMemory >> 30) GB: \(needs)."
        }
        return text
    }

    @ViewBuilder
    private func modelFile(_ store: ModelStore) -> some View {
        LabeledContent("File") {
            HStack {
                Text(store.configuredLocation.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(store.installedModel == nil ? .red : .primary)
                Button("Choose…") { chooseModel(for: store) }
            }
        }
        if !store.customPath.isEmpty {
            Button("Use the App's Own Download") { store.useDefaultLocation() }
        }
        if store.installedModel == nil {
            caption("Not downloaded yet. Once the service is on, the menu bar panel offers to download it (\(store.descriptor.size.formatted(.byteCount(style: .file)))).")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Metrics.Text.caption)
            .foregroundStyle(.secondary)
    }

    private func chooseModel(for store: ModelStore) {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(store.descriptor.title) GGUF"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            store.useExisting(url)
        }
    }
}

/// What Settings says about each text model, from Lemmary's extraction prompt on
/// German and Russian documents on a Mac mini M6 (see `TextModel`).
private extension TextModel {
    var pickerLabel: String {
        switch self {
        case .gemma4E4B: "Gemma 4 E4B: 5.7 GB, 7 to 18 s a document"
        case .ornith9B: "Ornith 1.5 9B: 6.9 GB, 8 to 32 s a document"
        case .gemma4_12B: "Gemma 4 12B: 9.3 GB, 13 to 49 s a document"
        case .gemma4_26B: "Gemma 4 26B-A4B: 16.2 GB, 5 to 19 s a document"
        case .qwen36_35B: "Qwen3.6 35B-A3B: 18.7 GB, 6 to 22 s a document"
        }
    }

    var note: String {
        switch self {
        case .gemma4E4B:
            "Fills in every field Lemmary asks for, but now and then writes a Russian document's summary in German."
        case .ornith9B:
            "The most useful titles and summaries of the two small models, but it sometimes leaves out suggested tags and reference numbers, and now and then mixes scripts in a name."
        case .gemma4_12B:
            "Every summary in the document's own language, but slow: a long document can take over a minute while OCR and embeddings are busy, close to Lemmary's 90 s limit."
        case .gemma4_26B:
            "The fastest and most reliable of the five: every summary in the document's own language, and reference numbers without account or customer numbers. On a 24 GB Mac it leaves little memory for anything else."
        case .qwen36_35B:
            "The most detailed summaries and the best match to existing correspondents, but it often lists account and customer numbers among the references."
        }
    }
}

/// Whether the app looks for updates, and installs them by itself.
private struct UpdatesSection: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        if updater.isRelease {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle("Download and install automatically", isOn: $updater.downloadsAutomatically)
                    .disabled(!updater.checksAutomatically)
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.downloadsAutomatically && updater.checksAutomatically
                     ? "Once a day. A new version installs the next time the app quits, such as at a restart of the Mac."
                     : "Once a day. A new version waits in the menu bar panel until you install it; the services stop for a few seconds while it does.")
            }
        }
    }
}
