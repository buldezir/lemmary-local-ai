import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.Key.allowRemote) private var allowRemote = true
    @AppStorage(Preferences.Key.embeddingsPort) private var embeddingsPort = 8080
    @AppStorage(Preferences.Key.ocrPort) private var ocrPort = 5001
    @AppStorage(Preferences.Key.contextTokens) private var contextTokens = 8192
    @AppStorage(Preferences.Key.parallelConversions) private var parallelConversions = 2
    @AppStorage(Preferences.Key.pageTimeout) private var pageTimeout = 60
    @AppStorage(Preferences.Key.modelPath) private var modelPath = ""
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
                caption("Lemmary usually runs on another machine and reaches this Mac over the LAN. Off, both services listen on 127.0.0.1 only. There is no authentication either way.")
                TextField("Embeddings port", value: $embeddingsPort, format: .number.grouping(.never))
                TextField("OCR port", value: $ocrPort, format: .number.grouping(.never))
            }

            Section("Embeddings") {
                LabeledContent("Model") {
                    HStack {
                        Text(app.modelStore.configuredLocation.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(app.modelStore.installedModel == nil ? .red : .primary)
                        Button("Choose…") { chooseModel() }
                    }
                }
                if !modelPath.isEmpty {
                    Button("Use the App's Own Download") { app.modelStore.useDefaultLocation() }
                }
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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Metrics.Text.caption)
            .foregroundStyle(.secondary)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose bge-m3 GGUF"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            app.modelStore.useExisting(url)
        }
    }
}
