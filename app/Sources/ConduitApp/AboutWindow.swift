// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit

/// A plain About window. (The standard About panel opens at normal window level, which put it *behind* the menu-bar popover.)
@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "About Conduit"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true; icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let name = NSTextField(labelWithString: "Conduit"); name.font = .systemFont(ofSize: 22, weight: .semibold)
        let ver = NSTextField(labelWithString: "Version \(version) (alpha)"); ver.font = .systemFont(ofSize: 12); ver.textColor = .secondaryLabelColor
        let blurb = NSTextField(wrappingLabelWithString: "A free, open-source virtual audio router and mixer for macOS.")
        blurb.font = .systemFont(ofSize: 12); blurb.alignment = .center; blurb.preferredMaxLayoutWidth = 280
        let link = NSTextField(labelWithAttributedString: NSAttributedString(string: "github.com/ShivamHimatsingka/conduit", attributes: [
            .link: URL(string: "https://github.com/ShivamHimatsingka/conduit")!, .font: NSFont.systemFont(ofSize: 12)]))
        link.allowsEditingTextAttributes = true; link.isSelectable = true
        let copyright = NSTextField(labelWithString: "© 2026 Shivam Himatsingka · MIT License"); copyright.font = .systemFont(ofSize: 11); copyright.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, name, ver, blurb, link, copyright])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.setCustomSpacing(14, after: icon); stack.setCustomSpacing(14, after: ver)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 24, right: 30)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
