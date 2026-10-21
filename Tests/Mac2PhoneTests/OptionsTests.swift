import XCTest
@testable import mac2phone

final class OptionsTests: XCTestCase {
    func testInvalidPortKeepsDefault() {
        XCTAssertEqual(Options.parse(["--port", "0"]).port, 8765)
        XCTAssertEqual(Options.parse(["--port", "999999"]).port, 8765)
        XCTAssertEqual(Options.parse(["--port", "9000"]).port, 9000)
    }
    func testNonFiniteQualityKeepsDefault() {
        XCTAssertEqual(Options.parse(["--quality", "nan"]).quality, 0.6)
        XCTAssertEqual(Options.parse(["--quality", "inf"]).quality, 0.6)
    }
    func testVideoSettingsClamp() {
        let options = Options.parse(["--fps", "1000", "--bitrate", "-1", "--width", "1"])
        XCTAssertEqual(options.fps, 60)
        XCTAssertEqual(options.bitrate, 1_000_000)
        XCTAssertEqual(options.width, 320)
    }
    func testViewOnlyAndCursorOptions() {
        let options = Options.parse(["--no-control", "--no-cursor", "--no-speak"])
        XCTAssertFalse(options.control)
        XCTAssertFalse(options.cursor)
        XCTAssertFalse(options.speak)
    }
}
