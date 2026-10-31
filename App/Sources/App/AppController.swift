import AppKit
import DoCore
import MageVL
import Observation
import SwiftUI
import os

/// The app's coordinator. Every trigger (Spotlight intent, URL scheme, the "Try it" field)
/// funnels into `start(task:)`.
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    let settings = AppSettings()
    let model = ModelController()
    let island = IslandController()
    let cursor = CursorOverlayController()
    @ObservationIgnored let escape = EscapeMonitor()
    @ObservationIgnored let updater = UpdaterController()

    private(set) var isRunning = false
    private(set) var hasAccessibility = Permissions.hasAccessibility
    private(set) var hasScreenRecording = Permissions.hasScreenRecording
    private(set) var lastOutcome: AgentOutcome?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var hideMainWindow: () -> Void = {}
    private static let log = Logger(subsystem: "com.do.app", category: "App")

    private init() {
        island.model.onStop = { [weak self] in self?.stop() }
        island.model.onApprovalDecision = { [weak self] allow in self?.resolveApproval(allow) }
        escape.onArm = { [weak self] in self?.island.model.escapeArmed = true }
        escape.onDisarm = { [weak self] in self?.island.model.escapeArmed = false }
        escape.onStop = { [weak self] in self?.stop() }
    }

    var permissionsGranted: Bool { hasAccessibility && hasScreenRecording }

    func refreshPermissions() {
        hasAccessibility = Permissions.hasAccessibility
        hasScreenRecording = Permissions.hasScreenRecording
    }

    // MARK: Running tasks

    func start(task rawTask: String) {
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        refreshPermissions()
        guard permissionsGranted else {
            Self.log.notice("missing permissions; showing onboarding")
            openMainWindow()
            return
        }
        if isRunning {
            // A new request replaces the current one.
            runTask?.cancel()
        }
        let previous = runTask
        runTask = Task { [weak self] in
            await previous?.value
            await self?.run(task)
        }
    }

    func stop() {
        guard isRunning else { return }
        island.model.stopping = true
        resolveApproval(false)
        runTask?.cancel()
    }

    private func run(_ task: String) async {
        isRunning = true
        defer { isRunning = false }
        // Do's own window must not cover what the agent needs to see and click.
        hideMainWindow()
        let screen = DisplayCutout.activeScreen
        island.present(task: task, on: screen, preference: settings.islandStyle)

        // 1. Model (download on first use, then load).
        let runtime: MageVLRuntime
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                self?.updatePreparingStatus()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        do {
            escape.start()
            runtime = try await model.prepare(options: settings.runtimeOptions)
            progress.cancel()
        } catch {
            progress.cancel()
            escape.stop()
            finish(Task.isCancelled ? .stopped : .failed(error.localizedDescription))
            return
        }
        guard !Task.isCancelled else {
            escape.stop()
            finish(.stopped)
            return
        }

        // 2. Agent loop.
        island.model.phase = .working
        cursor.show(on: screen)
        let environment = MacEnvironment(visualizer: cursor, configuration: settings.environmentConfiguration)
        let mode = settings.approvalMode
        let (events, sink) = AsyncStream<AgentEvent>.makeStream()
        let session = AgentSession(
            task: task, model: runtime, environment: environment, configuration: settings.sessionConfiguration,
            approveCommand: { [weak self] command in
                guard CommandSafety.requiresApproval(command, mode: mode) else { return true }
                return await self?.requestApproval(command) ?? false
            },
            onEvent: { sink.yield($0) })

        let consumer = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        let outcome = await session.run()
        sink.finish()
        await consumer.value

        escape.stop()
        cursor.hide()
        finish(outcome)
    }

    private func finish(_ outcome: AgentOutcome) {
        lastOutcome = outcome
        island.finish(outcome)
        model.scheduleUnload(afterMinutes: settings.unloadAfterMinutes)
        if case .failed(let message) = outcome { Self.log.error("run failed: \(message)") }
    }

    private func updatePreparingStatus() {
        let message: String
        var progress: Double?
        switch model.state {
        case .downloading(let done, let total):
            progress = total > 0 ? Double(done) / Double(total) : nil
            message = "Downloading model… \(Int((progress ?? 0) * 100))%"
        case .verifying: message = "Verifying model…"
        case .loading, .downloaded, .ready: message = "Loading model…"
        default: message = "Getting ready…"
        }
        if island.model.phase != .working { island.model.phase = .preparing(message: message, progress: progress) }
    }

    private func handle(_ event: AgentEvent) {
        let m = island.model
        switch event {
        case .started:
            break
        case .stepStarted(let step):
            m.step = step
            m.agentActing = false
            m.thinking = ""
            m.status = step == 1 ? "Looking at the screen…" : "Thinking…"
            cursor.showThinking()
        case .modelText:
            break
        case .thinking(_, let text):
            m.thinking = text
        case .actionSummary(_, let sentence):
            m.status = sentence
            m.pushHistory(sentence)
        case .performing:
            m.agentActing = true
        case .runningCommand(_, let command):
            m.agentActing = false
            if m.status.isEmpty { m.status = "Running \(command)" }
        case .commandFinished:
            break
        case .commandRefused:
            m.status = "Skipped a command you declined"
        case .generationStats(let step, let stats):
            Self.log.info(
                "step \(step): prompt \(stats.promptTokens) (reused \(stats.reusedPromptTokens)) in \(stats.prefillSeconds, format: .fixed(precision: 1))s, \(stats.generatedTokens) tokens at \(stats.decodeTokensPerSecond, format: .fixed(precision: 1)) tok/s"
            )
        case .parseIssues:
            break
        case .finished:
            m.agentActing = false
        }
    }

    // MARK: Command approval

    private func requestApproval(_ command: String) async -> Bool {
        let assessment = CommandSafety.assess(command)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuation?.resume(returning: false)
                approvalContinuation = continuation
                island.model.approval = ApprovalRequest(command: command, reasons: assessment.reasons)
                island.model.agentActing = false
                NSSound(named: "Tink")?.play()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(false) }
        }
    }

    private func resolveApproval(_ allow: Bool) {
        island.model.approval = nil
        approvalContinuation?.resume(returning: allow)
        approvalContinuation = nil
    }
}
