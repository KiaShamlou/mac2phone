import XCTest
import ImageIO
@testable import mac2phone

final class IconMakerTests: XCTestCase {
    func testBrandIconPNGHasRequestedDimensions() throws {
        for size in [32, 180, 512] {
            let data = IconMaker.makePNG(size: size)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, size)
            XCTAssertEqual(image.height, size)
        }
    }

    func testInvalidSizesDoNotAllocateImages() {
        XCTAssertTrue(IconMaker.makePNG(size: 0).isEmpty)
        XCTAssertTrue(IconMaker.makePNG(size: -1).isEmpty)
        XCTAssertTrue(IconMaker.makePNG(size: Int.max).isEmpty)
    }
}
