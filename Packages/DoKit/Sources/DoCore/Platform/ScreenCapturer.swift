import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenCaptureError: Error, LocalizedError {
    case noDisplay
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to capture."
        case .permissionDenied: "Do needs Screen Recording permission to see the screen."
        }
    }
}

/// Captures the display the agent works on, at point resolution (1 pixel per point), with the
/// pointer and Do's own windows (island, cursor overlay) excluded so the model never sees them.
public final class ScreenCapturer: Sendable {
    public init() {}

    /// The display under the pointer, falling back to the main display.
    public static func activeDisplayID() -> CGDirectDisplayID {
        let pointer = InputSynthesizer.pointerLocation
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        if CGGetDisplaysWithPoint(pointer, 8, &ids, &count) == .success, count > 0 {
            return ids[0]
        }
        return CGMainDisplayID()
    }

    public func capture(displayID: CGDirectDisplayID? = nil) async throws -> CapturedScreen {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.permissionDenied
        }
        let wanted = displayID ?? Self.activeDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first
        else { throw ScreenCaptureError.noDisplay }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .nominal

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedScreen(
            attachment: ImageAttachment(image: image),
            displayBounds: CGDisplayBounds(display.displayID),
            displayID: display.displayID)
    }
}
