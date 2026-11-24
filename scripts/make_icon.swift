// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Draws the Conduit app icon (a squircle with three mixer faders) at every size macOS needs.
//   swift scripts/make_icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o app/Resources/AppIcon.icns
import AppKit

func render(size px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.055, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)

    // soft shadow, then gradient body
    NSGraphicsContext.current?.cgContext.saveGState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.current?.cgContext.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.26, green: 0.52, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.43, green: 0.24, blue: 0.86, alpha: 1)])!
        .draw(in: body, angle: -60)
    // subtle top highlight
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // three faders: track + knob at different heights
    let trackW = s * 0.045, knobR = s * 0.082
    let xs: [CGFloat] = [0.31, 0.5, 0.69], ys: [CGFloat] = [0.60, 0.40, 0.54]
    for (x, y) in zip(xs, ys) {
        let cx = s * x, top = s * 0.76, bottom = s * 0.24
        NSColor.white.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - trackW / 2, y: bottom, width: trackW, height: top - bottom), xRadius: trackW / 2, yRadius: trackW / 2).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - trackW / 2, y: bottom, width: trackW, height: s * y - bottom), xRadius: trackW / 2, yRadius: trackW / 2).fill()
        let knob = NSRect(x: cx - knobR, y: s * y - knobR, width: knobR * 2, height: knobR * 2)
        NSGraphicsContext.current?.cgContext.saveGState()
        let ks = NSShadow(); ks.shadowColor = NSColor.black.withAlphaComponent(0.3); ks.shadowBlurRadius = s * 0.012; ks.shadowOffset = NSSize(width: 0, height: -s * 0.006); ks.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(size: px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
