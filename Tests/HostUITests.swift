// Created by Angelo Cammalleri on 25.10.2026.
import XCTest
#if os(iOS)
import UIKit
#endif

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
        app.launchEnvironment["SDB_UI_TEST"] = "1"
        app.launchEnvironment["SDB_SAVE_DIRECTORY"] = NSTemporaryDirectory().appending("space-undeadbeef-ui-tests")
        app.launch()
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        func waitForMenu(_ type: Int) {
            let predicate = NSPredicate(format: "value CONTAINS %@", "menuType \(type)")
            expectation(for: predicate, evaluatedWith: canvas)
            waitForExpectations(timeout: 10)
        }
        waitForMenu(1)
        capture(app, "01-title")
        #if os(tvOS)
        // Default virtual pointer is (240,160). Move it to the original Start row.
        for _ in 0..<4 { XCUIRemote.shared.press(.left) }
        for _ in 0..<5 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.select)
        waitForMenu(0)
        Thread.sleep(forTimeInterval: 5)
        capture(app, "02-gameplay-remote-select")
        XCUIRemote.shared.press(.playPause)
        for _ in 0..<5 { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.playPause)
        capture(app, "03-remote-target-and-release")
        #else
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let size = canvas.frame.size
            let width = max(480, 320 * size.width / size.height)
            let height = max(320, 480 * size.height / size.width)
            return canvas.coordinate(withNormalizedOffset: CGVector(
                dx: (x + (width - 480) / 2) / width,
                dy: (y + (height - 320) / 2) / height))
        }
        point(160, 120).tap()
        capture(app, "02-original-options")
        #if os(iOS)
        let compactOptions = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let compactOptions = false
        #endif
        point(180, compactOptions ? 130 : 150).tap()
        capture(app, "03-sound-on")
        point(300, compactOptions ? 190 : 230).tap()
        Thread.sleep(forTimeInterval: 0.4)
        capture(app, "03b-ignore-silent-mode")
        point(180, compactOptions ? 190 : 230).tap()
        Thread.sleep(forTimeInterval: 0.4)
        capture(app, "03c-respect-silent-mode")
        if compactOptions {
            point(180, 250).tap()
            capture(app, "03d-haptics-on")
            point(300, 250).tap()
            capture(app, "03e-haptics-off")
        }
        point(240, 280).tap()
        Thread.sleep(forTimeInterval: 1)
        point(160, 40).tap()
        waitForMenu(0)
        Thread.sleep(forTimeInterval: 5)
        capture(app, "04-original-gameplay")
        let pause = app.buttons["pause-game"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertEqual(pause.frame.maxX, canvas.frame.maxX, accuracy: 1)
        XCTAssertEqual(pause.frame.minY, canvas.frame.minY, accuracy: 1)
        pause.tap()
        waitForMenu(3)
        capture(app, "04b-native-corner-pause")
        point(240, 130).tap()
        waitForMenu(0)
        capture(app, "04c-resume")
        point(100, 160).press(forDuration: 0.25, thenDragTo: point(350, 80))
        capture(app, "05-targeting-drag")
        XCUIDevice.shared.press(.home)
        app.activate()
        capture(app, "06-background-resume")
        #endif
        XCTAssertTrue(canvas.exists)
        app.terminate()
    }
}
