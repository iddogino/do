import CoreGraphics
import DoCore
import Foundation
import ImageIO
import MageVL

// Developer tool for the Mage-VL port.
//
//   mage-cli parity --model <dir> --ref <dir>
//       Compare against a reference exported by scripts/parity/export_reference.py.
//
//   mage-cli run --model <dir> --image <png> --task "<instruction>" [--greedy] [--max-pixels N]
//       Run one agent turn (first step) on a screenshot and print the parsed action.
//
//   mage-cli shell "<command>"
//       Exercise the bash channel exactly as the agent would.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var defaultModelDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Do/Models/pratikgx/Mage-VL-Cowork-MLX-4bit")
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read image \(path)") }
    return image
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
let modelDirectory = argument("--model").map { URL(fileURLWithPath: $0) } ?? defaultModelDirectory

switch command {
case "parity":
    guard let ref = argument("--ref") else { fail("--ref <dir> is required") }
    let report = try await MageVLDiagnostics.parity(
        modelDirectory: modelDirectory, referenceDirectory: URL(fileURLWithPath: ref))
    print(report)
    exit(report.passed ? 0 : 1)

case "vision-bisect":
    guard let ref = argument("--ref") else { fail("--ref <dir> is required") }
    print(try await MageVLDiagnostics.visionBisect(modelDirectory: modelDirectory, referenceDirectory: URL(fileURLWithPath: ref)))

case "run":
    guard let imagePath = argument("--image"), let task = argument("--task") else {
        fail("--image <png> and --task <text> are required")
    }
    var options = MageVLRuntime.Options()
    if flag("--greedy") { options.temperature = 0 }
    if let px = argument("--max-pixels").flatMap(Int.init) { options.maxImagePixels = px }
    if let n = argument("--max-tokens").flatMap(Int.init) { options.maxTokens = n }

    let loadStart = Date()
    let runtime = try await MageVLRuntime.load(directory: modelDirectory, options: options)
    print("loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")

    var configuration = AgentSession.Configuration()
    if flag("--no-mac-note") { configuration.environmentNote = nil }
    let instruction = configuration.environmentNote.map { "\(task)\n\n(\($0))" } ?? task
    let history = AgentHistory(instruction: instruction)
    let screenshot = ImageAttachment(image: loadImage(imagePath))
    let messages = history.messages(current: .screenshot(screenshot))

    let repeats = argument("--repeat").flatMap(Int.init) ?? 1
    for i in 1 ... repeats {
        print("---- turn \(i) ----")
        let output = try await runtime.generate(messages: messages) { delta in
            FileHandle.standardOutput.write(delta.data(using: .utf8)!)
        }
        print("\n----")
        print(
            "prompt \(output.promptTokens) tokens (reused \(output.reusedPromptTokens)), prefill \(String(format: "%.2f", output.prefillSeconds))s; generated \(output.generatedTokens) tokens in \(String(format: "%.2f", output.decodeSeconds))s (\(String(format: "%.1f", output.decodeTokensPerSecond)) tok/s)"
        )
        let turn = ResponseParser.parse(output.text)
        print("action: \(turn.actionSentence)")
        print("invocation: \(String(describing: turn.invocation))")
        if !turn.issues.isEmpty { print("issues: \(turn.issues)") }
    }

case "simulate":
    // Full AgentSession with the real model against a scripted screen: the screen flips to
    // `--after` once the model clicks inside `--hit x0,y0,x1,y1` (normalized coordinates).
    // Shell commands are not executed.
    guard let before = argument("--image"), let after = argument("--after"), let task = argument("--task"),
        let hit = argument("--hit")?.split(separator: ",").compactMap({ Double($0) }), hit.count == 4
    else { fail("--image, --after, --task and --hit x0,y0,x1,y1 are required") }
    var options = MageVLRuntime.Options()
    if flag("--greedy") { options.temperature = 0 }
    let runtime = try await MageVLRuntime.load(directory: modelDirectory, options: options)
    let environment = SimulatedEnvironment(
        before: loadImage(before), after: loadImage(after), hit: (hit[0], hit[1], hit[2], hit[3]))
    var configuration = AgentSession.Configuration()
    configuration.maxSteps = argument("--max-steps").flatMap(Int.init) ?? 8
    configuration.settleDelay = .zero
    let started = Date()
    let session = AgentSession(task: task, model: runtime, environment: environment, configuration: configuration) { event in
        switch event {
        case .stepStarted(let step): print("\n=== step \(step) ===")
        case .actionSummary(_, let s): print("Action: \(s)")
        case .performing(_, let a): print("  → \(a)")
        case .runningCommand(_, let c): print("  $ \(c)")
        case .generationStats(_, let s):
            print(String(format: "  [prompt %d tok, reused %d, prefill %.1fs, %d tok @ %.1f tok/s]", s.promptTokens, s.reusedPromptTokens, s.prefillSeconds, s.generatedTokens, s.decodeTokensPerSecond))
        case .parseIssues(_, let issues): print("  ! \(issues)")
        default: break
        }
    }
    let outcome = await session.run()
    print("\noutcome: \(outcome)  screen flipped: \(environment.flipped)  total \(Int(Date().timeIntervalSince(started)))s")

case "shell":
    guard let cmd = CommandLine.arguments.dropFirst(2).first else { fail("usage: mage-cli shell <command>") }
    let runner = ShellRunner(workingDirectory: ShellRunner.defaultWorkspace, timeout: .seconds(20))
    let result = try await runner.run(cmd)
    print(result.output, terminator: "")
    print("[exit \(result.exitCode)\(result.timedOut ? ", timed out" : "")]")

default:
    print("usage: mage-cli parity|run|shell …  (see source header)")
}
