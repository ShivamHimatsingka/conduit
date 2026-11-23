// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit

@MainActor
enum Snapshot {
    static func render(to path: String, dark: Bool) -> Bool {
        let model = MixerModel(demo: true)
        model.start()
        let vc = MixerViewController(model: model, host: nil)
        let size = NSSize(width: Layout.width(pairs: model.pairCount), height: 470)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = vc
        window.setContentSize(size)
        window.backgroundColor = .windowBackgroundColor
        let view = vc.view
        window.appearance?.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }  // popover/window supply this in the real app
        view.layoutSubtreeIfNeeded()

        // Run the real metering path for ~1.2 s of simulated frames so bars, holds and the FFT have content.
        for _ in 0..<72 { model.poll(dt: 1.0 / 60); vc.updateMeters() }
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)); print("wrote \(path) \(Int(size.width))x\(Int(size.height))"); return true }
        catch { print("snapshot failed: \(error)"); return false }
    }
}
