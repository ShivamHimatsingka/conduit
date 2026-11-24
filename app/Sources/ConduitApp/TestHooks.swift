// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Test-only state export, active only when the process is launched with CONDUIT_TEST_HOOKS=1 (never in normal use).
// It publishes, a few times a second, where the app's windows, menus and key controls are on screen and whether they
// are visible/key/occluded, so an external driver can send *real* mouse and keyboard events at them and check what the
// window server actually did (see tests/real_ui). There is no command channel: it only writes a JSON file.
import AppKit

@MainActor
final class TestHooks: NSObject, NSMenuDelegate {
    static let shared = TestHooks()
    static let enabled = ProcessInfo.processInfo.environment["CONDUIT_TEST_HOOKS"] == "1"
    static let stateURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONDUIT_TEST_STATE"] ?? "/tmp/conduit-state.json")

    private(set) var openMenus = 0
    private var menuItems: [String] = []
    var popoverShown: () -> Bool = { false }
    /// The model's routing, so tests can assert on what a click really changed (not only on what got written to disk).
    var routing: () -> [String: Any] = { [:] }
    private var controls: [String: () -> (NSView, NSRect)?] = [:]
    private var timer: Timer?
    private var last = ""
    private var becameActive = 0, resignedActive = 0, lastEvent = ""
    private var events: [String] = []
    private let t0 = Date()
    /// Timestamped breadcrumbs ("closePopover: global click", "app resigned active", ...) for finding out *why* something closed.
    func note(_ text: String) {
        guard Self.enabled else { return }
        events.append(String(format: "%.2f %@", Date().timeIntervalSince(t0), text)); if events.count > 40 { events.removeFirst() }
        dump()
    }

    /// Register a control by name; `provider` returns the view and a rect inside it (view coordinates).
    func register(_ name: String, _ provider: @escaping () -> (NSView, NSRect)?) {
        guard Self.enabled else { return }
        controls[name] = provider
    }
    func register(_ name: String, view: @escaping () -> NSView?) {
        register(name) { view().map { ($0, $0.bounds) } }
    }
    /// Track menu open/close (a menu that closes by itself right after opening is exactly the bug class we hunt).
    func watch(_ menu: NSMenu) { if Self.enabled { menu.delegate = self } }
    func menuWillOpen(_ menu: NSMenu) { openMenus += 1; menuItems = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }; note("menu opened: \(menuItems.count) items") }
    func menuDidClose(_ menu: NSMenu) { openMenus = max(0, openMenus - 1); dump() }

    func start() {
        guard Self.enabled, timer == nil else { return }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.becameActive += 1; self?.lastEvent = "becameActive"; self?.note("app became active (frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))") } }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.resignedActive += 1; self?.lastEvent = "resignedActive"; self?.note("app RESIGNED active (frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))") } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.dump() } }
        RunLoop.main.add(timer!, forMode: .common)   // keep reporting while a menu is tracking
    }

    /// Screen rect in Quartz coordinates (origin top-left of the primary display), as CGEvent expects.
    private func quartz(_ r: NSRect) -> [Double] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let v: [Double] = [Double(r.minX), Double(h - r.maxY), Double(r.width), Double(r.height)]
        return v.map { ($0 * 10).rounded() / 10 }
    }

    private func dump() {
        var windows: [[String: Any]] = []
        for w in NSApp.windows {
            windows.append(["class": String(describing: type(of: w)), "title": w.title, "level": w.level.rawValue, "visible": w.isVisible,
                            "key": w.isKeyWindow, "main": w.isMainWindow, "occluded": !w.occlusionState.contains(.visible), "frame": quartz(w.frame),
                            "number": w.windowNumber, "fullScreen": w.styleMask.contains(.fullScreen), "miniaturized": w.isMiniaturized])
        }
        var ctl: [String: [Double]] = [:]
        for (name, provider) in controls {
            guard let (view, rect) = provider(), let win = view.window, win.isVisible else { continue }
            ctl[name] = quartz(win.convertToScreen(view.convert(rect, to: nil)))
        }
        let state: [String: Any] = ["pid": getpid(), "active": NSApp.isActive, "policy": NSApp.activationPolicy().rawValue, "popoverShown": popoverShown(),
                                    "routing": routing(), "openMenus": openMenus, "menuItems": menuItems, "becameActive": becameActive, "resignedActive": resignedActive, "lastEvent": lastEvent, "events": events, "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "", "appearance": NSApp.effectiveAppearance.name.rawValue, "windows": windows, "controls": ctl]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8), json != last else { return }
        last = json
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}
