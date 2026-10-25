// Created by Angelo Cammalleri on 25.10.2026.
import XCTest

final class HostUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        XCTAssertFalse(app.staticTexts["runtime-failure"].exists, "Original guest execution failed")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testOriginalGameInteraction() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SDB_MUTE_AUDIO"] = "1"
        app.launch()
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        capture(app, "01-title")
        #if os(tvOS)
        // Default virtual pointer is (240,160). Move it to the original Start row.
        for _ in 0..<4 { XCUIRemote.shared.press(.left) }
        for _ in 0..<6 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 2)
        capture(app, "02-gameplay-remote-select")
        XCUIRemote.shared.press(.playPause)
        for _ in 0..<5 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.playPause)
        capture(app, "03-remote-target-and-release")
        #else
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x / 480, dy: y / 320))
        }
        point(160, 120).tap()
        capture(app, "02-original-options")
        point(180, 150).tap()
        capture(app, "03-sound-on")
        point(300, 230).tap()
        Thread.sleep(forTimeInterval: 0.4)
        capture(app, "03b-ignore-silent-mode")
        point(180, 230).tap()
        Thread.sleep(forTimeInterval: 0.4)
        capture(app, "03c-respect-silent-mode")
        point(240, 280).tap()
        Thread.sleep(forTimeInterval: 1)
        point(160, 40).tap()
        Thread.sleep(forTimeInterval: 2)
        capture(app, "04-original-gameplay")
        point(100, 160).press(forDuration: 0.25, thenDragTo: point(350, 80))
        capture(app, "05-targeting-drag")
        XCUIDevice.shared.press(.home)
        app.activate()
        capture(app, "06-background-resume")
        #endif
        XCTAssertTrue(canvas.exists)
    }
}
