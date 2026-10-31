import ApplicationServices
import CoreGraphics
import Foundation

/// The two TCC permissions Do needs.
public enum Permissions {
    /// Accessibility: required to post synthetic input and to intercept Escape.
    public static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links to Privacy & Security ▸ Accessibility.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Screen Recording: required to capture screenshots.
    public static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static var allGranted: Bool { hasAccessibility && hasScreenRecording }

    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
