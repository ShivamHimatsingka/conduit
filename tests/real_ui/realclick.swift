// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Real mouse/keyboard events for UI tests, with a safety interlock: a click is only posted if the window that is
// topmost at that point belongs to the app under test (--pid), so a test can never click into somebody else's app.
//
//   realclick perm
//   realclick top X Y
//   realclick windows PID
//   realclick click X Y --pid PID [--right] [--double] [--statusitem] [--press MS] [--travel FROMX,FROMY]
//   realclick move X Y
//   realclick key CODE [cmd] [shift] [opt] [ctrl] --pid PID      (refuses unless that app is frontmost)
//   realclick type TEXT --pid PID                                  (same interlock)
//   realclick drag X1 Y1 X2 Y2 --pid PID
import CoreGraphics
import Foundation
import ApplicationServices
import AppKit

func topWindow(at p: CGPoint) -> [String: Any]? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []   // front to back
    for w in list {
        guard let b = w[kCGWindowBounds as String] as? [String: Double], let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 2_000_000_000,   // skip the pointer's own window
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.contains(p) { return w }
    }
    return nil
}

func fail(_ m: String, _ code: Int32 = 1) -> Never { FileHandle.standardError.write(Data("realclick: \(m)\n".utf8)); exit(code) }
let a = Array(CommandLine.arguments.dropFirst())
/// Keystrokes go to whatever app is frontmost, so never send one unless it is the app under test.
func requireFrontmost() {
    guard let pidText = a.firstIndex(of: "--pid").flatMap({ $0 + 1 < a.count ? a[$0 + 1] : nil }), let pid = Int32(pidText) else { fail("--pid is required for keyboard events (safety interlock)", 4) }
    let front = NSWorkspace.shared.frontmostApplication
    guard front?.processIdentifier == pid else { fail("refusing to send keys: frontmost app is \(front?.localizedName ?? "unknown"), not pid \(pid)", 4) }
}
guard let cmd = a.first else { fail("usage: perm | top | windows | click | move | key") }
func num(_ i: Int) -> Double { i < a.count ? Double(a[i]) ?? .nan : .nan }
func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }

switch cmd {
case "perm":
    print(AXIsProcessTrusted() ? "trusted" : "not-trusted")
case "top":
    let p = CGPoint(x: num(1), y: num(2))
    if let w = topWindow(at: p) { print("\(w[kCGWindowOwnerPID as String] ?? 0)\t\(w[kCGWindowOwnerName as String] ?? "")\t\(w[kCGWindowLayer as String] ?? 0)\t\(w[kCGWindowName as String] ?? "")") } else { print("none") }
case "windows":
    let pid = Int(a[1]) ?? 0
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [[String: Any]] = []
    for (order, w) in list.enumerated() where (w[kCGWindowOwnerPID as String] as? Int) == pid {
        out.append(["order": order, "layer": w[kCGWindowLayer as String] ?? 0, "name": w[kCGWindowName as String] ?? "", "bounds": w[kCGWindowBounds as String] ?? [:], "number": w[kCGWindowNumber as String] ?? 0])
    }
    print(String(decoding: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
case "move":
    CGWarpMouseCursorPosition(CGPoint(x: num(1), y: num(2)))
case "click":
    let p = CGPoint(x: num(1), y: num(2))
    guard p.x.isFinite, p.y.isFinite else { fail("bad coordinates") }
    if let pid = opt("--pid").flatMap(Int.init) {
        let statusItem = a.contains("--statusitem") && p.y < 40   // the menu-bar strip: the status item's own window may belong to the system
        if !statusItem {
            guard let w = topWindow(at: p), (w[kCGWindowOwnerPID as String] as? Int) == pid else {
                let who = topWindow(at: p).map { "\($0[kCGWindowOwnerName as String] ?? "?")" } ?? "nothing"
                fail("refusing to click: topmost window at (\(p.x), \(p.y)) is \(who), not pid \(pid)", 3)
            }
        }
    } else { fail("--pid is required (safety interlock)") }
    let button: CGMouseButton = a.contains("--right") ? .right : .left
    let down: CGEventType = a.contains("--right") ? .rightMouseDown : .leftMouseDown, up: CGEventType = a.contains("--right") ? .rightMouseUp : .leftMouseUp
    let pressMs = opt("--press").flatMap(UInt32.init) ?? 60
    if let from = opt("--travel")?.split(separator: ",").compactMap({ Double($0) }), from.count == 2 {
        // Like a hand: a path of many small pointer moves ending on the target, instead of teleporting.
        for i in 1...24 {
            let t = Double(i) / 24, q = CGPoint(x: from[0] + (p.x - from[0]) * t, y: from[1] + (p.y - from[1]) * t)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: button)?.post(tap: .cghidEventTap)
            usleep(14_000)
        }
        usleep(60_000)
    } else {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
    for click in 1...(a.contains("--double") ? 2 : 1) {
        let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
        d?.setIntegerValueField(.mouseEventClickState, value: Int64(click)); d?.post(tap: .cghidEventTap)
        usleep(pressMs * 1000)
        let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
        u?.setIntegerValueField(.mouseEventClickState, value: Int64(click)); u?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
case "key":
    requireFrontmost()
    guard let code = UInt16(a[1]) else { fail("bad key code") }
    var flags: CGEventFlags = []
    if a.contains("cmd") { flags.insert(.maskCommand) }; if a.contains("shift") { flags.insert(.maskShift) }
    if a.contains("opt") { flags.insert(.maskAlternate) }; if a.contains("ctrl") { flags.insert(.maskControl) }
    for isDown in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown); e?.flags = flags; e?.post(tap: .cghidEventTap); usleep(40_000)
    }
case "drag":
    let from = CGPoint(x: num(1), y: num(2)), to = CGPoint(x: num(3), y: num(4))
    guard let pid = opt("--pid").flatMap(Int.init), let w = topWindow(at: from), (w[kCGWindowOwnerPID as String] as? Int) == pid else { fail("refusing to drag: start point is not over the app under test", 3) }
    CGWarpMouseCursorPosition(from)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(100_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(80_000)
    for i in 1...20 {
        let t = Double(i) / 20, q = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(20_000)
    }
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
case "type":
    requireFrontmost()
    for ch in a[1].utf16 {
        var u = ch
        for isDown in [true, false] {
            let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 0, keyDown: isDown); e?.flags = []; e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u); e?.post(tap: .cghidEventTap); usleep(30_000)
        }
    }
default: fail("unknown command \(cmd)")
}
