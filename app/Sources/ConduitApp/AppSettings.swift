// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit

/// User preferences, stored in UserDefaults and applied live. Routing and mixer state are *not* here (see MixerModel / Presets).
@MainActor
enum AppSettings {
    static let changed = Notification.Name("ConduitSettingsChanged")
    private static var d: UserDefaults { .standard }

    // MARK: Appearance (dark by default)
    enum Appearance: String, CaseIterable {
        case dark, light, system
        var title: String { switch self { case .dark: return "Dark"; case .light: return "Light"; case .system: return "System" } }
        var nsAppearance: NSAppearance? { switch self { case .dark: return NSAppearance(named: .darkAqua); case .light: return NSAppearance(named: .aqua); case .system: return nil } }
    }
    static var appearance: Appearance {
        get { Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark }
        set { d.set(newValue.rawValue, forKey: "appearance"); apply(); post() }
    }

    // MARK: Windows and Dock
    static var floatOnTop: Bool { get { d.bool(forKey: "floatOnTop") } set { d.set(newValue, forKey: "floatOnTop"); post() } }
    /// Keep a Dock icon and the menu bar at all times (also the way out if macOS hides a crowded menu-bar icon).
    static var showInDock: Bool { get { d.bool(forKey: "showInDock") } set { d.set(newValue, forKey: "showInDock"); post() } }
    enum LaunchBehavior: String, CaseIterable {
        case restore, window, menuBar
        var title: String { switch self { case .restore: return "Reopen the window if it was open"; case .window: return "Always open the mixer window"; case .menuBar: return "Menu bar only" } }
    }
    static var launchBehavior: LaunchBehavior {
        get { LaunchBehavior(rawValue: d.string(forKey: "launchBehavior") ?? "") ?? .restore }
        set { d.set(newValue.rawValue, forKey: "launchBehavior"); post() }
    }
    /// ⌃⌥⌘M opens the mixer window from anywhere.
    static var globalShortcut: Bool {
        get { d.object(forKey: "globalShortcut") as? Bool ?? true }
        set { d.set(newValue, forKey: "globalShortcut"); post() }
    }

    // MARK: Audio and meters
    enum Latency: Int, CaseIterable {
        case lowest = 64, balanced = 128, safest = 256
        var title: String {
            switch self { case .lowest: return "Lowest latency (64 frames)"; case .balanced: return "Balanced (128 frames)"; case .safest: return "Safest (256 frames)" }
        }
    }
    static var latency: Latency {
        get { Latency(rawValue: d.integer(forKey: "captureBufferFrames")) ?? .lowest }
        set { d.set(newValue.rawValue, forKey: "captureBufferFrames"); post() }
    }
    static var bufferFrames: UInt32 { UInt32(latency.rawValue) }

    enum PeakHold: Double, CaseIterable {
        case off = 0, short = 1.3, long = 3, infinite = 1e9
        var title: String { switch self { case .off: return "Off"; case .short: return "1.3 seconds"; case .long: return "3 seconds"; case .infinite: return "Hold forever" } }
    }
    static var peakHold: PeakHold {
        get { PeakHold(rawValue: d.object(forKey: "peakHold") as? Double ?? PeakHold.short.rawValue) ?? .short }
        set { d.set(newValue.rawValue, forKey: "peakHold"); post() }
    }

    // MARK: Applying
    static func apply() {
        NSApp.appearance = appearance.nsAppearance
        LevelState.holdSeconds = Float(peakHold.rawValue)
    }
    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }
}
