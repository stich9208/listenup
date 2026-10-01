import AppKit
import XCTest
@testable import ListenUpApp

final class RecordingIndicatorGestureTests: XCTestCase {
    func testClickIsRecognizedOnReleaseWithSmallPointerJitter() {
        var gesture = RecordingIndicatorPointerGesture()
        gesture.begin(at: NSPoint(x: 100, y: 100), windowOrigin: NSPoint(x: 70, y: 70))
        XCTAssertNil(gesture.drag(to: NSPoint(x: 101, y: 102)))
        XCTAssertTrue(gesture.finish(at: NSPoint(x: 101, y: 102)))
        XCTAssertFalse(gesture.finish(at: NSPoint(x: 101, y: 102)), "a release can activate at most once")
    }

    func testDragMovesWidgetWithoutBecomingClick() {
        var gesture = RecordingIndicatorPointerGesture()
        gesture.begin(at: NSPoint(x: 100, y: 100), windowOrigin: NSPoint(x: 70, y: 70))
        XCTAssertEqual(gesture.drag(to: NSPoint(x: 130, y: 90)), NSPoint(x: 100, y: 60))
        XCTAssertEqual(gesture.drag(to: NSPoint(x: 150, y: 80)), NSPoint(x: 120, y: 50))
        XCTAssertFalse(gesture.finish(at: NSPoint(x: 150, y: 80)))
    }

    func testDraggingBackToStartingPointDoesNotOpenApp() {
        var gesture = RecordingIndicatorPointerGesture()
        gesture.begin(at: .zero, windowOrigin: NSPoint(x: 10, y: 10))
        XCTAssertNotNil(gesture.drag(to: NSPoint(x: 20, y: 20)))
        XCTAssertEqual(gesture.drag(to: .zero), NSPoint(x: 10, y: 10))
        XCTAssertFalse(gesture.finish(at: .zero))
        gesture.begin(at: .zero, windowOrigin: .zero)
        XCTAssertTrue(gesture.finish(at: .zero), "the next independent click should still work")
    }

    func testDisplacedReleaseAndUnmatchedEventsNeverOpenApp() {
        var gesture = RecordingIndicatorPointerGesture()
        XCTAssertNil(gesture.drag(to: NSPoint(x: 10, y: 10)))
        XCTAssertFalse(gesture.finish(at: .zero))
        gesture.begin(at: .zero, windowOrigin: .zero)
        XCTAssertFalse(gesture.finish(at: NSPoint(x: 10, y: 10)))
    }
}
