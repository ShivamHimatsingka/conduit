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
if arguments.contains("--livetest") { exit(LiveTest.run() ? 0 : 1) }
if arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
