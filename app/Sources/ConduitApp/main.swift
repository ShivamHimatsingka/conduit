// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit

let arguments = CommandLine.arguments
let application = NSApplication.shared

if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    // Offscreen render of the mixer with demo data (docs, CI, UI development). Never touches Core Audio.
    let dark = arguments.contains("--dark")
    exit(Snapshot.render(to: arguments[i + 1], dark: dark) ? 0 : 1)
}

if let i = arguments.firstIndex(of: "--uitest") {
    exit(UITest.run(outDir: i + 1 < arguments.count ? arguments[i + 1] : "/tmp") ? 0 : 1)
}
if arguments.contains("--restoretest") { exit(LiveTest.runRestoreTest() ? 0 : 1) }
if arguments.contains("--staletest") { exit(LiveTest.runStaleTest() ? 0 : 1) }
if arguments.contains("--livetest") { exit(LiveTest.run() ? 0 : 1) }
if arguments.contains("--timing") { SelfTest.timing(); exit(0) }
if arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }

if arguments.contains("--driver-status") { print(DriverInstaller.status()); exit(0) }
if arguments.contains("--install-driver") || arguments.contains("--uninstall-driver") {
    // Scriptable/testable entry to the same code path the app uses (shows the macOS administrator prompt).
    let removing = arguments.contains("--uninstall-driver")
    Task { @MainActor in
        do {
            if removing { try await DriverInstaller.uninstall() } else { try await DriverInstaller.install() }
            print(removing ? "driver removed" : "driver installed"); exit(0)
        } catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
}

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
