import AppKit
import SwiftUI
import XCTest
@testable import Haynoi

final class PTTScrollIsolationTests: XCTestCase {

    func testPTTMonitorDoesNotIncludeScrollWheel() {
        XCTAssertFalse(HotkeyManager.pttEventMask.contains(.scrollWheel))
        XCTAssertFalse(HotkeyManager.pttEventMask.contains(.leftMouseDown))
        XCTAssertTrue(HotkeyManager.pttEventMask.contains(.flagsChanged))
        XCTAssertTrue(HotkeyManager.pttEventMask.contains(.keyDown))
    }

    func testIndicatorPanelCannotBecomeKeyOrEatClicks() {
        let panel = OverlayPanel.makeIndicator(size: NSSize(width: 200, height: 44), clickThrough: true)
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.acceptsFirstResponder)
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testHostingViewDoesNotTakeFirstResponderOrHits() {
        let hosting = ClickThroughHostingView(rootView: Color.clear)
        XCTAssertFalse(hosting.acceptsFirstResponder)
        XCTAssertFalse(hosting.becomeFirstResponder())
        XCTAssertNil(hosting.hitTest(NSPoint(x: 1, y: 1)))
    }

    func testCaptionSitsTopCenterUnderMenuBar() {
        // 1728-wide display: Dock ~70pt, menu bar excluded from visibleFrame.
        let visible = NSRect(x: 0, y: 70, width: 1728, height: 1000)
        let size = CaptionLayout.pillSize(screenWidth: visible.width)
        let frame = OverlayPanel.topCenteredFrame(size: size, visibleFrame: visible)
        XCTAssertEqual(frame.maxY, visible.maxY - CaptionLayout.menuGap, accuracy: 0.1)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.1)
        XCTAssertGreaterThan(frame.minY, visible.midY)
        XCTAssertLessThan(frame.maxY, visible.maxY)
        // Must not sit on the Dock (visible.minY).
        XCTAssertGreaterThan(frame.minY - visible.minY, 400)
        XCTAssertEqual(frame.width, CaptionLayout.fixedWidth(screenWidth: 1728), accuracy: 0.5)
    }
}
