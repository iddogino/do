import CoreGraphics
import DoCore
import Foundation

/// A scripted "computer" for exercising the full agent loop with the real model, without
/// touching the host: the screen switches from `before` to `after` once a click lands inside
/// `hit`, and shell commands are acknowledged but never executed.
final class SimulatedEnvironment: AgentEnvironment, @unchecked Sendable {
    let before: ImageAttachment
    let after: ImageAttachment
    let hit: (x0: Double, y0: Double, x1: Double, y1: Double)
    private let lock = NSLock()
    private var _flipped = false

    init(before: CGImage, after: CGImage, hit: (Double, Double, Double, Double)) {
        self.before = ImageAttachment(image: before)
        self.after = ImageAttachment(image: after)
        self.hit = hit
    }

    var flipped: Bool { lock.withLock { _flipped } }

    func captureScreen() async throws -> CapturedScreen {
        // Stable attachment ids per state, so unchanged screens hit the vision cache.
        let shot = flipped ? after : before
        return CapturedScreen(
            attachment: shot,
            displayBounds: CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height),
            displayID: 0)
    }

    func perform(_ action: ComputerAction, on screen: CapturedScreen) async throws {
        switch action {
        case .click(let p, .left), .doubleClick(let p):
            if p.x >= hit.x0, p.x <= hit.x1, p.y >= hit.y0, p.y <= hit.y1 {
                lock.withLock { _flipped = true }
                print("  ✓ click inside target")
            } else {
                print("  ✗ click outside target")
            }
        default:
            break
        }
    }

    func runShell(_ command: String) async throws -> ShellResult {
        ShellResult(output: "", exitCode: 0)
    }

    func finish() async {}
}
