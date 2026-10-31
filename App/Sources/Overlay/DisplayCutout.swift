import AppKit
import IOKit

/// How the activity indicator is presented on a given screen.
enum IslandStyle: Equatable {
    /// Grows out of the camera-housing notch (MacBook Pro / Air with a notch).
    case notch(cutout: CGSize)
    /// Grows out of the Dynamic Island cutout (touchscreen MacBook Pro, 2026).
    case dynamicIsland(cutout: CGSize)
    /// A floating pill below the menu bar (displays without a cutout).
    case floating

    var cutout: CGSize? {
        switch self {
        case .notch(let s), .dynamicIsland(let s): s
        case .floating: nil
        }
    }
}

enum DisplayCutout {

    /// The size of the top-center camera cutout on `screen`, in points, if it has one.
    static func cutoutSize(of screen: NSScreen) -> CGSize? {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return nil }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 { return CGSize(width: width, height: top) }
        }
        // Safe-area inset without auxiliary areas: assume a typical notch width.
        return CGSize(width: 200, height: top)
    }

    static func style(for screen: NSScreen, preference: IslandStylePreference) -> IslandStyle {
        let cutout = cutoutSize(of: screen)
        switch preference {
        case .floating:
            return .floating
        case .notch:
            return .notch(cutout: cutout ?? CGSize(width: 200, height: menuBarHeight(screen)))
        case .dynamicIsland:
            return .dynamicIsland(cutout: cutout ?? CGSize(width: 180, height: menuBarHeight(screen)))
        case .automatic:
            guard let cutout else { return .floating }
            // The touchscreen MacBook Pro replaces the notch with a Dynamic Island. macOS exposes
            // both as a top safe-area cutout, so tell them apart by the built-in touch digitizer.
            return isBuiltIn(screen) && hasBuiltInTouchscreen ? .dynamicIsland(cutout: cutout) : .notch(cutout: cutout)
        }
    }

    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        max(24, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    /// True when the Mac has a built-in HID touchscreen (Digitizer page 0x0D, usage 0x04).
    /// Reads the IORegistry only, so it needs no Input Monitoring permission.
    static let hasBuiltInTouchscreen: Bool = {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return false }
        matching["PrimaryUsagePage"] = 0x0D
        matching["PrimaryUsage"] = 0x04
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let builtIn = IORegistryEntryCreateCFProperty(service, "Built-In" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool
            let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            // External USB/Bluetooth touch monitors don't count.
            if builtIn == true || (transport != "USB" && transport != "Bluetooth") { found = true }
        }
        return found
    }()

    /// The screen the user is looking at: the one containing the pointer.
    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
