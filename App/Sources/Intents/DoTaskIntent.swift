import AppIntents

/// The Spotlight entry point: ⌘-Space, type "Do", then describe the task.
///
/// The intent runs inside the app process (launching it in the background if needed), hands the
/// task to `AppController`, and returns immediately; progress is shown by the island.
struct DoTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Do"
    static let description = IntentDescription(
        "Ask Do to complete a task on your Mac. Do sees your screen and uses the mouse, keyboard, and shell, entirely on-device.",
        categoryName: "Tasks")
    static let openAppWhenRun = false

    @Parameter(
        title: "Task",
        description: "What should Do do? For example: “Turn on Dark Mode”.",
        requestValueDialog: IntentDialog("What should Do do?"))
    var task: String

    static var parameterSummary: some ParameterSummary {
        Summary("Do \(\.$task)")
    }

    init() {}

    init(task: String) {
        self.task = task
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared.start(task: task)
        return .result()
    }
}

struct DoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DoTaskIntent(),
            phrases: [
                "\(.applicationName)",
                "Ask \(.applicationName)",
                "\(.applicationName) a task",
                "Have \(.applicationName) do something",
            ],
            shortTitle: "Do",
            systemImageName: "wand.and.sparkles")
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
