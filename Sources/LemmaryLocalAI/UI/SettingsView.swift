import AppKit
import LocalAIKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.Key.allowRemote) private var allowRemote = true
    @AppStorage(Preferences.Key.embeddingsPort) private var embeddingsPort = 8080
    @AppStorage(Preferences.Key.ocrPort) private var ocrPort = 5001
    @AppStorage(Preferences.Key.textModelPort) private var textModelPort = 8081
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
                caption("Lemmary usually runs on another machine and reaches this Mac over the LAN. Off, every service listens on 127.0.0.1 only. There is no authentication either way.")
                TextField("Embeddings port", value: $embeddingsPort, format: .number.grouping(.never))
                TextField("OCR port", value: $ocrPort, format: .number.grouping(.never))
                TextField("Text model port", value: $textModelPort, format: .number.grouping(.never))
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
                caption("For Lemmary's metadata extraction: title, date, tags and summary. In Lemmary, add an OpenAI provider with this service's URL, its model name and any API key, and use it for extraction only.")
                Picker("Model", selection: $textModel) {
                    Text("Gemma 4 E4B: 5.4 GB, 9 to 25 s a document").tag(TextModel.gemma4E4B.rawValue)
                    Text("Ornith 1.5 9B: 6.3 GB, 10 to 45 s a document").tag(TextModel.ornith9B.rawValue)
                }
                caption("Gemma is faster and fills in every field Lemmary asks for. Ornith writes better titles and summaries but sometimes leaves out suggested tags and reference numbers, and now and then mixes scripts in a name.")
                modelFile(app.textModelStores[TextModel(rawValue: textModel) ?? .gemma4E4B]!)
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
        .frame(width: Metrics.settingsWidth)
        .onAppear { launchAtLogin = Preferences.launchAtLogin }
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
