#if DEBUG
import AppKit
import DoCore
import SwiftUI

/// Debug-only visual QA: `Do.app/Contents/MacOS/Do --snapshots <dir>` renders the island and
/// cursor in each state to PNGs (no screen-recording permission needed), then exits.
@MainActor
enum Snapshots {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let notch = IslandStyle.notch(cutout: CGSize(width: 190, height: 32))
        let island = IslandStyle.dynamicIsland(cutout: CGSize(width: 150, height: 32))
        let task = "Switch the system appearance to Dark mode"

        func islandModel(_ style: IslandStyle, _ configure: (IslandModel) -> Void) -> IslandModel {
            let m = IslandModel()
            m.style = style
            m.reset(task: task)
            m.phase = .working
            m.step = 3
            m.status = "Click the Dark appearance tile in System Settings."
            m.thinking = "The Appearance pane is open and Light is currently selected. The Dark tile is to the right of Light, so clicking it will switch the system appearance."
            m.history = ["Open System Settings.", "Open the Appearance pane.", "Click the Dark appearance tile in System Settings."]
            configure(m)
            return m
        }

        let cases: [(String, IslandModel, CGFloat)] = [
            ("island-notch-compact", islandModel(notch) { _ in }, 0),
            ("island-notch-preparing", islandModel(notch) { $0.phase = .preparing(message: "Downloading model… 42%", progress: 0.42) }, 0),
            ("island-notch-escape", islandModel(notch) { $0.escapeArmed = true }, 0),
            ("island-notch-expanded", islandModel(notch) { $0.expanded = true }, 0),
            ("island-notch-approval", islandModel(notch) {
                $0.approval = ApprovalRequest(command: "rm -rf ~/Desktop/old-screenshots && sudo purge", reasons: ["recursively or forcibly deletes files", "runs with administrator privileges"])
            }, 0),
            ("island-notch-done", islandModel(notch) { $0.phase = .finished(.completed(message: "Dark Mode is on.")) }, 0),
            ("island-dynamic-compact", islandModel(island) { _ in }, 0),
            ("island-floating-compact", islandModel(.floating) { _ in }, 30),
            ("island-floating-expanded", islandModel(.floating) { $0.expanded = true }, 30),
        ]
        for (name, model, inset) in cases {
            let view = IslandView(model: model, topInset: inset) { _ in }
                .frame(width: 640, height: model.expanded || model.approval != nil ? 300 : 120)
                .background(
                    LinearGradient(colors: [Color(white: 0.85), Color(red: 0.6, green: 0.65, blue: 0.85)], startPoint: .top, endPoint: .bottom))
            write(view, to: dir.appending(path: "\(name).png"))
        }

        func cursorModel(_ configure: (CursorModel) -> Void) -> CursorModel {
            let m = CursorModel()
            m.visible = true
            m.position = CGPoint(x: 120, y: 90)
            configure(m)
            return m
        }
        let cursors: [(String, CursorModel)] = [
            ("cursor-thinking", cursorModel { $0.mode = .thinking; $0.badge = .thinking }),
            ("cursor-click", cursorModel { $0.badge = .text(icon: "cursorarrow.click", text: "Click"); $0.ripples = [.init(point: CGPoint(x: 120, y: 90), tint: Theme.brand[1], delay: 0)] }),
            ("cursor-scroll", cursorModel { $0.mode = .scrolling(dx: 0, dy: -400); $0.badge = .text(icon: "scroll", text: "Scrolling down") }),
            ("cursor-drag", cursorModel { $0.mode = .dragging; $0.dragStart = CGPoint(x: 30, y: 40); $0.badge = .text(icon: "hand.draw", text: "Dragging") }),
            ("cursor-keys", cursorModel { $0.badge = .keys(["cmd", "shift", "t"]) }),
            ("cursor-typing", cursorModel { $0.badge = .typing("Quarterly report.xlsx") }),
            ("cursor-shell", cursorModel { $0.badge = .text(icon: "terminal", text: "defaults write -g AppleInterfaceStyle Dark") }),
        ]
        for (name, model) in cursors {
            let view = CursorOverlayView(model: model)
                .frame(width: 420, height: 180)
                .background(Color(white: 0.93))
            write(view, to: dir.appending(path: "\(name).png"))
        }
        print("snapshots written to \(dir.path)")
        exit(0)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
