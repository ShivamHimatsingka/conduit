#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
"""Real-event UI suite for the menu-bar app. Run: python3 tests/real_ui/suite.py [group ...]

Everything here uses genuine mouse/keyboard events and checks what the window server really shows (is the window on screen,
is it frontmost, what is on top at its centre), against a separate "ConduitUITest" copy of the app with its own preferences,
so it never touches your running Conduit or your settings. It moves the pointer and types, so leave the Mac alone while it runs.
"""
import json, os, shutil, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from harness import *

BUNDLE = os.path.join(ROOT, "build", "dev", "Conduit.app")
DARK, LIGHT = "NSAppearanceNameDarkAqua", "NSAppearanceNameAqua"


def fresh(**defaults):
    sh("defaults", "delete", DOMAIN)
    return App(BUNDLE, defaults=defaults).launch()


def real_windows(app):
    return [w for w in app.state().get("windows", []) if w["visible"] and "StatusBar" not in w["class"] and "Popover" not in w["class"]]


def popover_open(app):
    app.click_status_item()
    s = app.wait(lambda s: s["popoverShown"])
    time.sleep(0.6)
    return s


def open_menu(app, press=60):
    app.click("popover.menuButton", "--press", str(press))
    return app.wait(lambda s: s["openMenus"] == 1, 2)


def is_front_and_visible(app, title):
    """The window is on screen, key, not occluded, the app is frontmost, and the window server puts it on top at its centre."""
    w = app.win(title=title)
    if not w:
        return False, "window not found"
    x, y, ww, hh = w["frame"]
    top = app.top_owner_at(round(x + ww / 2), round(y + hh / 2))
    st = app.state()
    problems = []
    if not w["key"]: problems.append("not key")
    if w["occluded"]: problems.append("occluded")
    if st["frontmost"] != "ConduitUITest" and st["frontmost"] != "Conduit": problems.append(f"frontmost app is {st['frontmost']}")
    if top != str(app.pid): problems.append(f"topmost window at its centre belongs to pid {top}")
    return not problems, ", ".join(problems)


# ---------------------------------------------------------------------------------------------------------------------------------
def group_launch():
    print("\n[launch & appearance]")
    app = fresh()
    s = app.state()
    check(s["appearance"] == DARK, "default appearance is dark", s["appearance"])
    check(s["policy"] == 1, "launches as a menu-bar-only (accessory) app", f"policy={s['policy']}")
    check(not real_windows(app), "no window opens at first launch")
    popover_open(app)
    pop = [w for w in app.state()["windows"] if "Popover" in w["class"] and w["visible"]]
    check(bool(pop) and app.state()["popoverShown"], "status item opens the popover")
    app.click_status_item(); time.sleep(0.6)
    check(not app.state()["popoverShown"], "status item again closes it")
    popover_open(app); app.focus(); app.key(53)
    check(app.wait(lambda s: not s["popoverShown"], 2) is not None, "Esc closes the popover")
    app.quit()


def group_menu():
    print("\n[⋯ menu]")
    app = fresh()
    popover_open(app)
    for press in (10, 40, 90, 200, 400):
        s = open_menu(app, press)
        alive = True
        for _ in range(8):
            time.sleep(0.25)
            st = app.state()
            alive &= st["openMenus"] == 1 and st["popoverShown"]
        check(s is not None and alive, f"first click on ⋯ opens the menu and it STAYS open (press {press} ms)", str([e for e in app.state()["events"][-4:]]))
        app.key(53); time.sleep(0.4)
        if not app.state()["popoverShown"]: popover_open(app)
    items = open_menu(app)["menuItems"]
    for want in ("Open Mixer in a Window", "Reconnect to Driver", "Launch at Login", "Show Presets in Finder", "Settings…", "About Conduit", "Quit Conduit"):
        check(want in items, f"menu has “{want}”")
    app.key(53)
    app.quit()


def group_windows():
    print("\n[About, Settings and mixer windows are in front, never hidden behind the popover]")
    app = fresh()
    for title, item in (("About Conduit", "About Conduit"), ("Conduit Settings", "Settings…"), ("Conduit", "Open Mixer in a Window")):
        popover_open(app); open_menu(app); app.choose_menu_item(item)
        app.wait(lambda st: any(w["title"] == title and w["visible"] for w in st["windows"]), 4); time.sleep(0.5)
        ok, why = is_front_and_visible(app, title)
        check(ok, f"“{item}” opens a window that is key, visible and frontmost", why)
        st = app.state()
        check(not st["popoverShown"], f"the popover is closed when “{title}” opens")
        check(st["policy"] == 0, f"app becomes a regular app (menu bar + Dock) while “{title}” is open", f"policy={st['policy']}")
        app.focus(); app.key(13, "cmd"); time.sleep(0.8)          # ⌘W
        check(app.win(title=title) is None, f"⌘W closes “{title}”")
        check(app.wait(lambda s: s["policy"] == 1, 3) is not None, "and the app returns to menu-bar-only")
    app.quit()


def group_settings():
    print("\n[Settings]")
    app = fresh()
    popover_open(app); open_menu(app); app.choose_menu_item("Settings…"); time.sleep(0.9)
    check(app.state()["appearance"] == DARK, "starts dark")
    app.click("settings.appearance.light"); time.sleep(0.6)
    check(app.state()["appearance"] == LIGHT, "clicking Light switches the whole app to light, live")
    check(app.default("appearance") == "light", "and saves it")
    app.click("settings.appearance.dark"); time.sleep(0.6)
    check(app.state()["appearance"] == DARK, "clicking Dark switches back")
    app.click("settings.dock"); time.sleep(0.5)
    check(app.default("showInDock") == "1", "“Show in the Dock” is saved when ticked")
    app.click("settings.dock"); time.sleep(0.5)
    check(app.default("showInDock") == "0", "and unticked")
    app.click("settings.float"); time.sleep(0.4); check(app.default("floatOnTop") == "1", "“keep above other windows” saves")
    app.click("settings.float"); time.sleep(0.4)
    app.click("settings.shortcut"); time.sleep(0.4); check(app.default("globalShortcut") == "0", "global shortcut can be switched off")
    app.click("settings.shortcut"); time.sleep(0.4); check(app.default("globalShortcut") == "1", "and on")
    for name, key, downs, expect in (("latency", "captureBufferFrames", 1, "128"), ("peakHold", "peakHold", 1, "3"), ("launch", "launchBehavior", 1, "window")):
        app.click(f"settings.{name}"); time.sleep(0.5)
        for _ in range(downs): app.key(125)
        app.key(36); time.sleep(0.6)
        check(app.default(key) is not None and app.default(key).startswith(expect), f"popup “{name}” saves its choice", f"{key}={app.default(key)}")
    ok, why = is_front_and_visible(app, "Conduit Settings"); check(ok, "Settings is still frontmost after all that", why)
    app.quit()


def group_shortcuts():
    print("\n[keyboard]")
    app = fresh()
    app.focus(); app.key(46, "cmd", "ctrl", "opt"); time.sleep(1.0)      # ⌃⌥⌘M
    check(app.win(title="Conduit") is not None, "global shortcut ⌃⌥⌘M opens the mixer window from anywhere")
    ok, why = is_front_and_visible(app, "Conduit"); check(ok, "…and it is frontmost", why)
    app.key(43, "cmd"); time.sleep(0.9)                                                    # ⌘,
    check(app.win(title="Conduit Settings") is not None, "⌘, opens Settings")
    ok, why = is_front_and_visible(app, "Conduit Settings"); check(ok, "…in front", why)
    app.key(13, "cmd"); time.sleep(0.6)
    check(app.win(title="Conduit Settings") is None and app.win(title="Conduit") is not None, "⌘W closes only the front window")
    app.key(12, "cmd"); time.sleep(1.2)                                                    # ⌘Q
    check(not app.alive(), "⌘Q quits the app")
    app.quit()


def group_window_behaviour():
    print("\n[mixer window]")
    app = fresh(); app.focus()
    app.key(46, "cmd", "ctrl", "opt"); time.sleep(1.0)
    w = app.win(title="Conduit")
    check(w is not None and "NSWindow" in w["class"], "opens as a standard NSWindow (title bar, not a utility panel)")
    before = app.rect("window.cell.0.7")[0]
    sh("osascript", "-e", f'tell application "System Events" to tell process "{PROC}" to set size of window 1 to {{900, 520}}'); time.sleep(0.8)
    after = app.rect("window.cell.0.7")[0]
    check(after > before + 40, "widening the window stretches the grid columns", f"{before} -> {after}")
    app.key(3, "cmd", "ctrl"); time.sleep(2.0)                                              # ⌃⌘F
    check(any(x["fullScreen"] for x in app.state()["windows"]), "⌃⌘F enters full screen")
    app.key(3, "cmd", "ctrl"); time.sleep(2.0)
    check(not any(x["fullScreen"] for x in app.state()["windows"]), "and leaves it")
    app.key(13, "cmd"); time.sleep(0.8)
    check(app.default("mixerWindowOpen") == "0", "closing the window is remembered")
    app.quit()


def group_controls():
    print("\n[controls, with real mouse events]")
    app = fresh(); app.focus()
    app.key(46, "cmd", "ctrl", "opt"); time.sleep(1.2)
    rows = [k for k in app.state()["controls"] if k.startswith("window.row")]
    check(any(k.endswith(".toggle") for k in rows), "the source rows are on screen")
    app.click("window.row0.toggle"); time.sleep(1.0)
    s = app.saved(); src = next(iter(s["sources"]), None) if s else None
    check(bool(src) and s["sources"][src]["enabled"], "clicking a row's switch enables the source (saved to disk)", str(s))
    app.click("window.cell.0.2"); time.sleep(1.0)
    check(2 in app.saved()["sources"][src]["pairs"], "clicking a matrix cell routes it")
    app.click("window.cell.0.2"); time.sleep(1.0)
    check(2 not in app.saved()["sources"][src]["pairs"], "clicking it again unroutes it")
    x0, y0 = app.center("window.cell.0.3"); x1, _ = app.center("window.cell.0.6")
    r = sh(REALCLICK, "drag", str(x0), str(y0), str(x1), str(y0), "--pid", str(app.pid)); time.sleep(1.0)
    check(r.returncode == 0 and set(app.saved()["sources"][src]["pairs"]) >= {3, 4, 5, 6}, "dragging across cells paints a run of routes", str(app.saved()["sources"][src]["pairs"]))
    app.click("window.row0.mute"); time.sleep(1.0)
    check(app.saved()["sources"][src]["mute"] is True, "the row's mute button mutes")
    app.click("window.row0.mute"); time.sleep(0.8)
    check(app.saved()["sources"][src]["mute"] is False, "and unmutes")
    fx, fy = app.center("window.row0.gain"); r = sh(REALCLICK, "drag", str(fx), str(fy), str(fx - 14), str(fy), "--pid", str(app.pid)); time.sleep(1.0)
    check(app.saved()["sources"][src]["gainDB"] < -1, "dragging the source fader lowers its level", str(app.saved()["sources"][src]["gainDB"]))
    bx, by = app.center("window.bus1.fader"); r = sh(REALCLICK, "drag", str(bx), str(by), str(bx), str(by + 12), "--pid", str(app.pid)); time.sleep(1.0)
    check(app.saved()["buses"][1]["gainDB"] < -1, "dragging a bus fader lowers the bus", str(app.saved()["buses"][1]))
    app.click("window.bus2.mute"); time.sleep(1.0)
    check(app.saved()["buses"][2]["mute"] is True, "the bus mute button mutes the bus")
    app.quit()


def group_restore():
    print("\n[last settings come back]")
    app = fresh(); app.focus()
    app.key(46, "cmd", "ctrl", "opt"); time.sleep(1.2)
    app.click("window.row0.toggle"); app.click("window.cell.0.4"); time.sleep(1.0)
    saved = app.saved(); src = next(iter(saved["sources"]))
    app.key(12, "cmd"); time.sleep(1.5)                                                   # ⌘Q
    app2 = App(BUNDLE, preset_dir=app.preset_dir).launch(); time.sleep(1.0)
    check(app2.win(title="Conduit") is not None, "the window that was open is open again after relaunch")
    check(app2.saved()["sources"][src]["pairs"] == saved["sources"][src]["pairs"] and app2.saved()["sources"][src]["enabled"], "routing is restored")
    app2.focus(); app2.key(13, "cmd"); time.sleep(0.8); app2.quit()
    app3 = App(BUNDLE, preset_dir=app.preset_dir).launch(); time.sleep(1.0)
    check(app3.win(title="Conduit") is None, "a window you closed stays closed after relaunch")
    app3.quit()
    sh("defaults", "write", DOMAIN, "launchBehavior", "-string", "window")
    app4 = App(BUNDLE, preset_dir=app.preset_dir).launch(); time.sleep(1.0)
    check(app4.win(title="Conduit") is not None, "“Always open the mixer window” opens it at launch")
    app4.quit()
    sh("defaults", "write", DOMAIN, "showInDock", "-bool", "true"); sh("defaults", "write", DOMAIN, "launchBehavior", "-string", "menuBar")
    app5 = App(BUNDLE, preset_dir=app.preset_dir).launch(); time.sleep(1.0)
    check(app5.state()["policy"] == 0 and app5.win(title="Conduit") is None, "“Show in the Dock” keeps it a regular app with no window opened")
    app5.quit()


def group_presets():
    print("\n[presets and dialogs]")
    app = fresh(); app.focus()
    app.key(46, "cmd", "ctrl", "opt"); time.sleep(1.2)
    app.click("window.row0.toggle"); time.sleep(0.6)
    app.key(1, "cmd"); time.sleep(1.0)                                                     # ⌘S → Save dialog
    alert = [w for w in app.state()["windows"] if w["visible"] and ("Alert" in w["class"] or "Panel" in w["class"])]
    check(bool(alert), "⌘S shows the Save Preset dialog")
    if alert:
        x, y, w, h = alert[0]["frame"]; top = app.top_owner_at(round(x + w / 2), round(y + h / 2))
        check(top == str(app.pid), "and the dialog is on top", f"top owner {top}")
    app.type("UITest Preset"); app.key(36); time.sleep(1.0)
    check(os.path.exists(os.path.join(app.preset_dir, "UITest Preset.json")), "typing a name and pressing Return saves the preset file")
    app.quit()


GROUPS = {f.__name__[6:]: f for f in (group_launch, group_menu, group_windows, group_settings, group_shortcuts, group_window_behaviour,
                                      group_controls, group_restore, group_presets)}

if __name__ == "__main__":
    if sh(REALCLICK, "perm").stdout.strip() != "trusted":
        sys.exit("accessibility permission is required for real events")
    if not os.path.isdir(BUNDLE):
        sys.exit("run tests/real_ui/dev_bundle.sh first")
    chosen = sys.argv[1:] or list(GROUPS)
    try:
        for name in chosen:
            GROUPS[name]()
    finally:
        for p in sh("pgrep", "-x", PROC).stdout.split():
            os.kill(int(p), 15)
        sh("defaults", "delete", DOMAIN)
    sys.exit(finish("real-event UI suite"))
