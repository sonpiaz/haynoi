import AppKit
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
        let panel = OverlayPanel.makeIndicator(size: OverlayPanel.orbSize, clickThrough: true)
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testOrbSitsTopCenterNotOverTheDock() {
        // 1728-wide display: Dock ~70pt, menu bar excluded from visibleFrame.
        let visible = NSRect(x: 0, y: 70, width: 1728, height: 1000)
        let size = OverlayPanel.orbSize
        let frame = OverlayPanel.topCenteredFrame(size: size, visibleFrame: visible)
        XCTAssertEqual(frame.maxY, visible.maxY - OverlayPanel.menuGap, accuracy: 0.1)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.1)
        XCTAssertGreaterThan(frame.minY, visible.midY)
        XCTAssertLessThan(frame.maxY, visible.maxY)
    }
}
