import AppKit
import SwiftUI

@main
struct LemmaryLocalAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(delegate.model)
        } label: {
            Image(systemName: delegate.model.hasProblem ? "exclamationmark.triangle" : "text.viewfinder")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than in the `App` struct: a scene's state is rebuilt
    /// more freely than a delegate is, and this object owns the child processes.
    let model: AppModel

    override init() {
        Preferences.registerDefaults()
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // A second copy would fight the first for its ports and restart
        // forever, so it hands over and leaves. A development build stays: it
        // is started beside the installed app on ports of its own.
        let mine = NSRunningApplication.current
        if !Preferences.isRunningFromBuildDirectory,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != mine.processIdentifier }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutDown()
    }
}
