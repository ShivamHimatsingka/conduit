# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
"""Real-event UI test harness.

Launches the app bundle with CONDUIT_TEST_HOOKS=1 (it then publishes window/menu/control geometry to a JSON file), sends
genuine mouse and keyboard events with `build/realclick` (which refuses to click unless the topmost window at that point
belongs to the app), and checks what the window server really shows.
"""
import json, os, signal, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REALCLICK = os.path.join(ROOT, "build", "realclick")
STATE = "/tmp/conduit-state.json"
PROC = "ConduitUITest"            # executable name of the dev bundle (the real app is "Conduit" and is never touched)
DOMAIN = "com.conduit.app.uitest"   # its own preferences domain
failures = []
passes = 0


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


class App:
    def __init__(self, bundle, preset_dir=None, env=None, defaults=None):
        self.bundle = bundle
        self.preset_dir = preset_dir or tempfile.mkdtemp(prefix="conduit-ui-")
        self.proc = None
        self.extra_env = env or {}
        self.defaults = defaults or {}

    def launch(self, wait_popover=False):
        """Launch through LaunchServices (`open`), exactly like a double-click or a login item, in the background."""
        for p in sh("pgrep", "-x", PROC).stdout.split():
            os.kill(int(p), signal.SIGTERM)
        time.sleep(1.0)
        for k, v in self.defaults.items():
            sh("defaults", "write", DOMAIN, k, *(["-bool", str(v).lower()] if isinstance(v, bool) else ["-string", str(v)]))
        if os.path.exists(STATE):
            os.remove(STATE)
        envargs = []
        for k, v in dict(CONDUIT_TEST_HOOKS="1", CONDUIT_PRESET_DIR=self.preset_dir, CONDUIT_TEST_STATE=STATE, **self.extra_env).items():
            envargs += ["--env", f"{k}={v}"]
        subprocess.run(["open", "-g", *envargs, "-a", os.path.abspath(self.bundle)])
        time.sleep(2.5)
        pids = sh("pgrep", "-x", PROC).stdout.split()
        if not pids:
            raise RuntimeError("app did not start")
        self.proc = type("LaunchedProcess", (), {"pid": int(pids[0]), "poll": lambda s: None if sh("pgrep", "-x", PROC).stdout.split() else 0})()
        for _ in range(100):
            r = self.state().get("controls", {}).get("statusItem") if os.path.exists(STATE) else None
            if r and r[1] < 40 and r[0] > 200:      # in the menu-bar strip, not still at its initial offscreen position
                return self
            time.sleep(0.1)
        raise RuntimeError("app did not publish state")

    @property
    def pid(self):
        return self.proc.pid

    def alive(self):
        return self.proc.poll() is None

    def state(self):
        for _ in range(5):
            try:
                with open(STATE) as f:
                    return json.load(f)
            except Exception:
                time.sleep(0.05)
        return {}

    def wait(self, pred, timeout=4.0, step=0.1):
        end = time.time() + timeout
        while time.time() < end:
            s = self.state()
            if pred(s):
                return s
            time.sleep(step)
        return None

    def rect(self, name):
        r = self.state().get("controls", {}).get(name)
        if not r:
            raise KeyError(f"control {name} not on screen")
        return r

    def center(self, name):
        x, y, w, h = self.rect(name)
        return round(x + w / 2), round(y + h / 2)

    def click(self, name, *flags, dx=0, dy=0):
        # The safety interlock refuses while another window (or a transition) is on top; retry briefly.
        for attempt in range(8):
            x, y = self.center(name)
            r = sh(REALCLICK, "click", str(x + dx), str(y + dy), "--pid", str(self.pid), *flags)
            if r.returncode == 0:
                break
            if "refusing" not in r.stderr or attempt == 7:
                raise RuntimeError(r.stderr.strip())
            time.sleep(0.4)
        time.sleep(0.25)

    def click_status_item(self, real=False):
        """Open/close the popover the way the status item does. A crowded menu bar can hide the icon (macOS drops items that do not
        fit), so by default this presses the item through accessibility, which works either way; real=True posts a genuine click."""
        if real:
            x, y = self.center("statusItem")
            r = sh(REALCLICK, "click", str(x), str(y), "--pid", str(self.pid), "--statusitem")
            if r.returncode != 0:
                raise RuntimeError(r.stderr.strip())
        else:
            r = sh("osascript", "-e", 'tell application "System Events" to tell process "ConduitUITest" to click menu bar item 1 of menu bar 2')
            if r.returncode != 0:
                raise RuntimeError(r.stderr.strip())
        time.sleep(0.35)

    def key(self, code, *mods):
        r = sh(REALCLICK, "key", str(code), *mods, "--pid", str(self.pid))
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip())
        time.sleep(0.3)

    def choose_menu_item(self, title):
        """With a menu open, pick an item by title using real arrow-key + Return events (separators are skipped by the arrows)."""
        items = self.state()["menuItems"]
        selectable = [t for t in items if t != "-"]
        for _ in range(selectable.index(title) + 1):
            self.key(125)
        self.key(36)
        time.sleep(0.8)

    def cg_windows(self):
        return json.loads(sh(REALCLICK, "windows", str(self.pid)).stdout or "[]")

    def top_owner_at(self, x, y):
        out = sh(REALCLICK, "top", str(x), str(y)).stdout.strip().split("\t")
        return out[0] if out and out[0] != "none" else None

    def win(self, title=None, cls=None):
        for w in self.state().get("windows", []):
            if w["visible"] and (title is None or w["title"] == title) and (cls is None or cls in w["class"]):
                return w
        return None

    def focus(self):
        """Bring the app to the front the way a user would (for steps that need keyboard focus)."""
        sh("osascript", "-e", f'tell application "System Events" to set frontmost of process "{PROC}" to true')
        time.sleep(0.4)

    def type(self, text):
        r = sh(REALCLICK, "type", text, "--pid", str(self.pid))
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip())
        time.sleep(0.3)

    def default(self, key):
        r = sh("defaults", "read", DOMAIN, key)
        return r.stdout.strip() if r.returncode == 0 else None

    def saved(self):
        """The automatically saved routing (_last.json), as written by the app."""
        try:
            with open(os.path.join(self.preset_dir, "_last.json")) as f:
                return json.load(f)
        except Exception:
            return None

    def quit(self):
        if self.proc is not None and hasattr(self.proc, "terminate"):
            if self.alive():
                self.proc.terminate()
                try:
                    self.proc.wait(3)
                except Exception:
                    self.proc.kill()
        else:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def check(cond, what, detail=""):
    global passes
    if cond:
        passes += 1
        print(f"  ok    {what}")
    else:
        failures.append(what)
        print(f"  FAIL  {what}" + (f"   [{detail}]" if detail else ""))
    return cond


def finish(name):
    print(f"\n{name}: {passes} passed, {len(failures)} failed")
    if failures:
        for f in failures:
            print("   -", f)
    return 0 if not failures else 1
