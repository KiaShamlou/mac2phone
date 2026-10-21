import XCTest
import CoreGraphics
@testable import TouchCore
@testable import mac2phone

final class TouchTests: XCTestCase {
    func testTouchModeSuppressesCursorWithoutLosingPreference() {
        XCTAssertFalse(ControlStyle.ipad.showsCursor(preference: true, controlling: true))
        XCTAssertTrue(ControlStyle.ipad.showsCursor(preference: true, controlling: false))
        XCTAssertTrue(ControlStyle.trackpad.showsCursor(preference: true, controlling: true))
        XCTAssertFalse(ControlStyle.direct.showsCursor(preference: false, controlling: true))
    }

    func testLetterboxDoesNotMapToDesktopEdge() {
        let geometry = TouchGeometry(videoSize: CGSize(width: 1920, height: 1080), scale: 0.5,
                                     origin: CGPoint(x: 0, y: 100))
        XCTAssertFalse(geometry.contains(CGPoint(x: 400, y: 30)))
        XCTAssertTrue(geometry.contains(CGPoint(x: 480, y: 370)))
        XCTAssertEqual(geometry.normalised(CGPoint(x: 480, y: 370)), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(geometry.delta(CGPoint(x: 96, y: 54)), CGPoint(x: 0.1, y: 0.1))
    }

    func testInvalidGeometryProducesNoCoordinates() {
        let geometry = TouchGeometry(videoSize: .zero, scale: 0, origin: .zero)
        XCTAssertFalse(geometry.contains(.zero))
        XCTAssertEqual(geometry.normalised(CGPoint(x: 1, y: 2)), .zero)
        XCTAssertEqual(geometry.delta(CGPoint(x: 1, y: 2)), .zero)
    }

    func testCoordinatesClampOutsideVideoDuringDrag() {
        let geometry = TouchGeometry(videoSize: CGSize(width: 100, height: 200), scale: 1, origin: .zero)
        XCTAssertEqual(geometry.normalised(CGPoint(x: -20, y: 300)), CGPoint(x: 0, y: 1))
        XCTAssertEqual(geometry.normalised(CGPoint(x: CGFloat.nan, y: 0)), .zero)
    }

    func testMomentumIndependentOfTouchSampleRate() {
        var slow = TouchVelocity(), fast = TouchVelocity()
        slow.reset(at: 0); fast.reset(at: 0)
        slow.record(delta: CGPoint(x: 0.01, y: 0.02), at: 1.0 / 60)
        fast.record(delta: CGPoint(x: 0.005, y: 0.01), at: 1.0 / 120)
        XCTAssertEqual(slow.ending(at: 0.02).x, fast.ending(at: 0.02).x, accuracy: 0.00001)
        XCTAssertEqual(slow.ending(at: 0.02).y, fast.ending(at: 0.02).y, accuracy: 0.00001)
    }

    func testPauseBeforeLiftSuppressesFlick() {
        var velocity = TouchVelocity()
        velocity.reset(at: 0)
        velocity.record(delta: CGPoint(x: 0, y: 0.04), at: 0.02)
        XCTAssertNotEqual(velocity.ending(at: 0.03), .zero)
        XCTAssertEqual(velocity.ending(at: 0.2), .zero)
    }

    func testRemoteGestureEndsExactlyOnce() {
        var gesture = RemoteGesture(kind: .routed)
        let end = gesture.finish()
        XCTAssertEqual(end?["t"] as? String, "dend")
        XCTAssertEqual(end?["vx"] as? Double, 0)
        XCTAssertNil(gesture.finish())
        XCTAssertEqual(gesture.kind, .none)
    }

    func testMouseReleaseMatchesPressedButton() {
        var gesture = RemoteGesture(kind: .button(1))
        XCTAssertEqual(gesture.finish()?["b"] as? Int, 1)
        XCTAssertNil(gesture.finish())
    }

    func testScrollEndingCarriesVelocity() {
        var gesture = RemoteGesture(kind: .scroll)
        let result = gesture.finish(velocity: CGPoint(x: 2, y: -3))
        XCTAssertEqual(result?["t"] as? String, "se")
        XCTAssertEqual(result?["vy"] as? Double, -3)
    }

    func testCancelStopsMomentumAndEndsScrollOnce() {
        let input = InputController()
        var events: [InputController.Event] = []
        input.eventObserver = { events.append($0) }
        input.scrollBegin()
        input.scroll(dx: 0, dy: 12)
        input.scrollEnd(velocityX: 0, velocityY: 30)
        input.cancelScroll()
        let count = events.count
        input.cancelScroll()
        XCTAssertEqual(events.count, count)
        XCTAssertEqual(events.last?.momentumPhase, 3)
        let done = expectation(description: "cancelled momentum stays stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(events.count, count)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    func testNewScrollTerminatesPriorMomentum() {
        let input = InputController()
        var phases: [(Int64, Int64)] = []
        input.eventObserver = { phases.append(($0.scrollPhase,
                                          $0.momentumPhase)) }
        input.scrollBegin()
        input.scrollEnd(velocityX: 0, velocityY: 20)
        input.scrollBegin()
        XCTAssertEqual(phases.suffix(2).map { $0.1 }, [3, 0])
        XCTAssertEqual(phases.last?.0, 1)
        input.releaseAll()
    }

    func testDisableReleasesHeldButtons() {
        let input = InputController()
        var types: [CGEventType] = []
        input.eventObserver = { types.append($0.type) }
        input.down(button: 0)
        input.down(button: 0)
        input.enabled = false
        XCTAssertEqual(types, [.leftMouseDown, .leftMouseUp])
    }

    func testNonFiniteInputDoesNotPostEvents() {
        let input = InputController()
        var count = 0
        input.eventObserver = { _ in count += 1 }
        input.scroll(dx: .nan, dy: .infinity)
        input.zoom(delta: .nan)
        input.move(nx: .nan, ny: 0)
        input.moveRelative(dx: .infinity, dy: 0, dragging: false)
        XCTAssertEqual(count, 0)
    }
}
