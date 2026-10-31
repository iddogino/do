import AppKit
import DoCore
import SwiftUI

/// Onboarding and status: model download, permissions, how to trigger Do, and a "Try it" box.
struct MainWindowView: View {
    let controller: AppController
    @State private var tryTask = ""

    private var model: ModelController { controller.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(spacing: 12) {
                modelCard
                permissionsCard
                usageCard
            }
            tryIt
            footer
        }
        .padding(28)
        .frame(width: 520)
        .task {
            await model.refresh()
            while !Task.isCancelled {
                controller.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Do").font(.system(size: 26, weight: .bold))
                Text("Tell your Mac what to do. It runs entirely on-device.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Model

    private var modelCard: some View {
        Card(icon: "cpu", title: "On-device model", done: model.isDownloaded) {
            switch model.state {
            case .unknown:
                Text("Checking…").foregroundStyle(.secondary)
            case .notDownloaded:
                HStack {
                    Text("Mage-VL-Cowork (4-bit) · \(model.downloadSizeDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") { model.download() }
                        .buttonStyle(.borderedProminent)
                }
            case .downloading(let done, let total):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                    )
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            case .verifying:
                HStack { ProgressView().controlSize(.small); Text("Verifying…").foregroundStyle(.secondary) }
            case .downloaded:
                Text("Downloaded · loads automatically when you start a task").foregroundStyle(.secondary)
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            case .ready:
                Text("Loaded and ready").foregroundStyle(.secondary)
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Retry") { model.download() }
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        Card(icon: "lock.shield", title: "Permissions", done: controller.permissionsGranted) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "To move the pointer, click, and type.",
                    granted: controller.hasAccessibility
                ) {
                    Permissions.requestAccessibility()
                    NSWorkspace.shared.open(Permissions.accessibilitySettingsURL)
                }
                PermissionRow(
                    title: "Screen Recording",
                    detail: "To see the screen. macOS may ask you to reopen Do afterwards.",
                    granted: controller.hasScreenRecording
                ) {
                    if !Permissions.requestScreenRecording() {
                        NSWorkspace.shared.open(Permissions.screenRecordingSettingsURL)
                    }
                }
                if !controller.hasScreenRecording {
                    Button("Already granted? Reopen Do") { Relauncher.relaunch() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: Usage

    private var usageCard: some View {
        Card(icon: "magnifyingglass", title: "Start a task from Spotlight", done: nil) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    KeyCap("⌘"); KeyCap("Space")
                    Text("then type").foregroundStyle(.secondary)
                    Text("Do").bold()
                    Text("and describe the task.").foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Press").foregroundStyle(.secondary)
                    KeyCap("esc"); KeyCap("esc")
                    Text("to stop Do at any time.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        HStack {
            TextField("Try it: “Switch to Dark Mode”", text: $tryTask)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            Button(controller.isRunning ? "Stop" : "Run") {
                controller.isRunning ? controller.stop() : run()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!controller.isRunning && (tryTask.trimmingCharacters(in: .whitespaces).isEmpty || !controller.permissionsGranted))
        }
    }

    private func run() {
        let task = tryTask
        // Get out of the way so Do can see and use the screen.
        NSApp.keyWindow?.orderOut(nil)
        NSApp.hide(nil)
        controller.start(task: task)
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
            Spacer()
            Text("Version \(Bundle.main.shortVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct Card<Content: View>: View {
    let icon: String
    let title: String
    let done: Bool?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let done {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(done ? .green : .secondary)
                    }
                }
                content
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
            } else {
                Button("Grant…", action: request)
            }
        }
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.background).shadow(radius: 0.5, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
    }
}

enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
