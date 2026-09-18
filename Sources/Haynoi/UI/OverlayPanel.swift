import AppKit

/// HUD / toast panel that must never steal key status from the app the user
/// is dictating into. A regular `NSWindow.orderFront` during PTT made Ghostty
/// (and other terminals) lose the key window, so scroll died until release
/// (W37-738). `NSPanel` + `.nonactivatingPanel` + `canBecomeKey == false`
/// keeps the front app key; `ignoresMouseEvents` lets the wheel pass through.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func makeIndicator(size: NSSize, clickThrough: Bool) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = clickThrough
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = false
        return panel
    }

    /// Screen under the mouse (the one Son is looking at), else the key-window screen.
    static func activeScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Top-center of `visibleFrame` (already excludes the menu bar).
    static func topCenteredFrame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.maxY - size.height - CaptionLayout.menuGap
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Learn toast sits one row under the caption pill.
    static func toastFrame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.maxY - CaptionLayout.height - CaptionLayout.menuGap - size.height - 8
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func presentWithoutActivating() {
        orderFrontRegardless()
    }
}
