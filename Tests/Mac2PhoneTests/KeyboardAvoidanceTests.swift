import XCTest
import CoreGraphics
@testable import TouchCore

final class KeyboardAvoidanceTests: XCTestCase {
    private let phone = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let keyboard = CGRect(x: 0, y: 504, width: 390, height: 340)
    private var original: TouchGeometry {
        TouchGeometry(videoSize: CGSize(width: 1920, height: 1080), scale: 390.0 / 1920,
                      origin: CGPoint(x: 0, y: (844 - 390.0 * 1080 / 1920) / 2))
    }
    private var available: CGRect {
        KeyboardAvoidance.viewport(in: phone, keyboard: keyboard, controlsHeight: 74, topInset: 81)
    }

    func testScreenshotLayoutMovesPictureUpWithoutShrinking() {
        let adjusted = KeyboardAvoidance.adjusted(original, to: available)
        XCTAssertEqual(available.maxY, 418)
        XCTAssertEqual(adjusted.scale, original.scale)
        XCTAssertEqual(adjusted.origin.y, 198.625, accuracy: 0.001)
        XCTAssertLessThan(adjusted.origin.y, original.origin.y)
        XCTAssertEqual(adjusted.origin.y + 1080 * adjusted.scale, available.maxY, accuracy: 0.001)
    }

    func testTouchCoordinatesFollowShiftedPicture() {
        let adjusted = KeyboardAvoidance.adjusted(original, to: available)
        let centre = CGPoint(x: adjusted.origin.x + 1920 * adjusted.scale / 2,
                             y: adjusted.origin.y + 1080 * adjusted.scale / 2)
        XCTAssertEqual(adjusted.normalised(centre).x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(adjusted.normalised(centre).y, 0.5, accuracy: 0.0001)
        XCTAssertFalse(adjusted.contains(CGPoint(x: 195, y: 470)))
    }

    func testDismissalRestoresFullViewportAndSavedTransform() {
        let originalOrigin = original.origin
        _ = KeyboardAvoidance.adjusted(original, to: available)
        XCTAssertEqual(original.origin, originalOrigin)
        XCTAssertEqual(KeyboardAvoidance.viewport(in: phone,
            keyboard: CGRect(x: 0, y: 844, width: 390, height: 0), controlsHeight: 74), phone)
    }

    func testFloatingKeyboardDoesNotShrinkEntireScreen() {
        let floating = CGRect(x: 140, y: 450, width: 220, height: 200)
        XCTAssertEqual(KeyboardAvoidance.viewport(in: phone, keyboard: floating, controlsHeight: 74), phone)
    }

    func testOffscreenKeyboardAndHardwareKeyboardKeepViewport() {
        XCTAssertEqual(KeyboardAvoidance.viewport(in: phone,
            keyboard: CGRect(x: 0, y: 844, width: 390, height: 340), controlsHeight: 74), phone)
        XCTAssertEqual(KeyboardAvoidance.viewport(in: phone, keyboard: .zero, controlsHeight: 74), phone)
    }

    func testPortraitDesktopScalesOnlyEnoughToFitAboveKeyboard() {
        let portrait = TouchGeometry(videoSize: CGSize(width: 1080, height: 1920), scale: 390.0 / 1080,
                                     origin: CGPoint(x: 0, y: 75))
        let adjusted = KeyboardAvoidance.adjusted(portrait, to: available)
        XCTAssertLessThan(adjusted.scale, portrait.scale)
        XCTAssertGreaterThanOrEqual(adjusted.origin.y, available.minY)
        XCTAssertLessThanOrEqual(adjusted.origin.y + 1920 * adjusted.scale, available.maxY + 0.001)
    }

    func testExpandedControlsReserveTheirMeasuredHeight() {
        let expanded = KeyboardAvoidance.viewport(in: phone, keyboard: keyboard, controlsHeight: 184, topInset: 81)
        XCTAssertEqual(expanded.maxY, 308)
        XCTAssertLessThan(expanded.height, available.height)
    }

    func testLandscapeAndSplitViewUseLocalBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let available = KeyboardAvoidance.viewport(in: bounds,
            keyboard: CGRect(x: 0, y: 210, width: 844, height: 180), controlsHeight: 74, topInset: 34)
        let adjusted = KeyboardAvoidance.adjusted(original, to: available)
        XCTAssertEqual(available.maxY, 124)
        XCTAssertLessThanOrEqual(adjusted.origin.y + 1080 * adjusted.scale, 124.001)
    }

    func testKeyboardFrameUpdatesDoNotAccumulateOffset() {
        let once = KeyboardAvoidance.adjusted(original, to: available)
        let twice = KeyboardAvoidance.adjusted(original, to: available)
        XCTAssertEqual(once.origin, twice.origin)
        XCTAssertEqual(once.scale, twice.scale)
    }

    func testInvalidGeometryAndExtremeInsetsRemainFinite() {
        let invalid = TouchGeometry(videoSize: .zero, scale: 0, origin: .zero)
        XCTAssertEqual(KeyboardAvoidance.adjusted(invalid, to: available).scale, 0)
        XCTAssertEqual(KeyboardAvoidance.viewport(in: phone, keyboard: keyboard,
            controlsHeight: .nan), phone)
        let tiny = KeyboardAvoidance.viewport(in: phone, keyboard: keyboard,
            controlsHeight: 1000, topInset: 1000)
        XCTAssertGreaterThan(tiny.height, 0)
        XCTAssertTrue(KeyboardAvoidance.adjusted(original, to: tiny).valid)
    }
}
