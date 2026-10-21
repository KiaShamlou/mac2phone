import XCTest
@testable import mac2phone

final class DesktopStatusTests: XCTestCase {
    private func status(enabled: Bool = true, screen: Bool = true, accessibility: Bool = true, native: Int = 0, web: Int = 0) -> AppController.Status {
        var viewers = Server.Viewers()
        viewers.native = native
        viewers.web = web
        return AppController.Status(headline: "Status", detail: nil, addresses: [], enabled: enabled,
            matchesDisplay: true, displayMode: nil, lidAwake: false, lidHelperInstalled: false,
            powerState: "off", onBattery: false, screenRecording: screen, accessibility: accessibility,
            microphone: false, audioDeviceInstalled: false, viewers: viewers)
    }
    func testWaitingIsNotShownAsConnected() {
        let model = DesktopStatusPresentation(status: status())
        XCTAssertEqual(model.badge, "READY TO CONNECT")
        XCTAssertEqual(model.title, "Ready when you are.")
    }
    func testPauseTakesPrecedenceOverViewers() {
        let model = DesktopStatusPresentation(status: status(enabled: false, native: 1))
        XCTAssertEqual(model.badge, "PAUSED")
        XCTAssertTrue(model.connectionDetail.contains("Resume"))
    }
    func testBrowserAndNativeViewersBothCountAsConnected() {
        XCTAssertEqual(DesktopStatusPresentation(status: status(native: 1)).badge, "CONNECTED")
        XCTAssertEqual(DesktopStatusPresentation(status: status(web: 1)).badge, "CONNECTED")
    }
    func testOptionalAudioDoesNotBlockReadiness() {
        XCTAssertEqual(DesktopStatusPresentation(status: status()).requiredPermissions, 2)
        XCTAssertEqual(DesktopStatusPresentation(status: status(screen: false)).requiredPermissions, 1)
        XCTAssertEqual(DesktopStatusPresentation(status: status(screen: false, accessibility: false)).requiredPermissions, 0)
    }

    func testMissingScreenPermissionShowsSetupInsteadOfReady() {
        let model = DesktopStatusPresentation(status: status(screen: false))
        XCTAssertEqual(model.badge, "SETUP NEEDED")
        XCTAssertEqual(model.stateLabel, "Let’s finish setup")
        XCTAssertTrue(model.connectionDetail.contains("Screen Recording"))
    }

    func testViewOnlyReadinessExplainsMissingControlPermission() {
        let model = DesktopStatusPresentation(status: status(accessibility: false))
        XCTAssertEqual(model.stateLabel, "Ready to connect")
        XCTAssertTrue(model.connectionDetail.contains("Accessibility"))
    }

    func testPausedStateNeverAsksToConnect() {
        let model = DesktopStatusPresentation(status: status(enabled: false, screen: false))
        XCTAssertEqual(model.stateLabel, "Sharing paused")
        XCTAssertEqual(model.badge, "PAUSED")
    }

    func testConnectedLabelUsesActualViewers() {
        XCTAssertEqual(DesktopStatusPresentation(status: status(native: 2)).stateLabel, "Your Mac is connected")
        XCTAssertEqual(DesktopStatusPresentation(status: status(web: 1)).stateLabel, "Your Mac is connected")
    }
}
