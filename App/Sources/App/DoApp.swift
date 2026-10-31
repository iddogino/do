import AppIntents
import AppKit
import DoCore
import SwiftUI

@main
struct DoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(controller: AppController.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindow = MainWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Snapshots.runIfRequested()
        #endif
        let controller = AppController.shared
        DoAppShortcuts.updateAppShortcutParameters()
        controller.openMainWindow = { [weak self] in self?.mainWindow.show() }
        controller.hideMainWindow = { [weak self] in self?.mainWindow.hide() }
        Task { @MainActor in
            await controller.model.refresh()
            // If Spotlight launched us to run a task, let that proceed undisturbed.
            try? await Task.sleep(for: .milliseconds(600))
            guard !controller.isRunning else { return }
            // First launch (or anything missing): show onboarding.
            if !controller.permissionsGranted || !controller.model.isDownloaded {
                self.mainWindow.show()
            }
        }
    }

    /// Launching Do again (Finder, Launchpad, Spotlight app result) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `doapp://run?task=Turn%20on%20Dark%20Mode`, `doapp://stop`
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "doapp" else { continue }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host() {
            case "run":
                if let task = items.first(where: { $0.name == "task" })?.value {
                    AppController.shared.start(task: task)
                }
            case "stop":
                AppController.shared.stop()
            default:
                mainWindow.show()
            }
        }
    }
}

/// The onboarding / status window, owned by AppKit so any trigger can open it.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindowView(controller: AppController.shared))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Do"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        AppController.shared.refreshPermissions()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppController.shared.refreshPermissions()
    }
}
