import AppKit
import DoCore
import SwiftUI

struct SettingsView: View {
    let controller: AppController

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section("Safety") {
                Picker("Ask before running shell commands", selection: $settings.approvalMode) {
                    Text("Only risky ones").tag(CommandApprovalMode.risky)
                    Text("Always").tag(CommandApprovalMode.always)
                    Text("Never").tag(CommandApprovalMode.never)
                }
                Text("Risky commands delete files, use sudo, install software, change system settings, or send data off your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Stop after \(settings.maxSteps) steps", value: $settings.maxSteps, in: 5 ... 100, step: 5)
            }

            Section("Performance") {
                Picker("Screenshot detail", selection: $settings.screenshotDetail) {
                    ForEach(ScreenshotDetail.allCases) { Text($0.title).tag($0) }
                }
                Text("Standard matches the model's training resolution. Faster cuts thinking time on base-model Macs at some cost in click precision.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Deterministic responses", isOn: $settings.deterministic)
                Picker("Free model memory after", selection: $settings.unloadAfterMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
            }

            Section("Behavior") {
                Toggle("Adapt Linux shortcuts (Ctrl → ⌘) outside terminals", isOn: $settings.translateShortcuts)
                Picker("Activity indicator", selection: $settings.islandStyle) {
                    ForEach(IslandStylePreference.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Updates") {
                if controller.updater.isAvailable {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { controller.updater.automaticallyChecks },
                            set: { controller.updater.automaticallyChecks = $0 }))
                    Button("Check for Updates Now") { controller.updater.checkForUpdates() }
                } else {
                    Text("Updates are disabled in development builds.").foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                LabeledContent("Model", value: controller.model.store.manifest.repository)
                LabeledContent("Revision", value: String(controller.model.store.manifest.revision.prefix(10)))
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.model.store.directory])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 560)
    }
}
