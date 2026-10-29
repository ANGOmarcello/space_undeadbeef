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
        app.launchEnvironment["SDB_SAVE_DIRECTORY"] = "~/tmp/space-undeadbeef-ui-\(UUID().uuidString)"
        app.launch()
        #if os(tvOS)
        defer { if app.state != .notRunning { app.terminate() } }
        #endif
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        #if os(tvOS)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "game-canvas").count, 1,
                       "The TV canvas must have one stable semantic container")
        #endif
        func waitForMenu(_ type: Int) {
            let predicate = NSPredicate(format: "value CONTAINS %@", "menuType \(type)")
            expectation(for: predicate, evaluatedWith: canvas)
            waitForExpectations(timeout: 10)
        }
        waitForMenu(1)
        capture(app, "01-title")
        #if os(tvOS)
        let initialTitle = canvas.value as? String ?? ""
        XCTAssertTrue(initialTitle.contains("canPause false"), initialTitle)
        XCUIRemote.shared.press(.menu)
        let exited = NSPredicate(format: "state == %d OR state == %d OR state == %d",
            XCUIApplication.State.runningBackground.rawValue,
            XCUIApplication.State.runningBackgroundSuspended.rawValue,
            XCUIApplication.State.notRunning.rawValue)
        expectation(for: exited, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.activate()
        waitForMenu(1)
        // Default virtual pointer is (240,160). Move it to the original Start row.
        for _ in 0..<4 { XCUIRemote.shared.press(.left) }
        for _ in 0..<5 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.select)
        waitForMenu(0)
        Thread.sleep(forTimeInterval: 5)
        capture(app, "02-gameplay-remote-select")
        let beforeBack = canvas.value as? String ?? ""
        XCTAssertTrue(beforeBack.contains("hostActive true"), beforeBack)
        XCTAssertTrue(beforeBack.contains("canPause true"), beforeBack)
        XCTAssertTrue(beforeBack.contains("focused true"), "Remote surface lost focus: \(beforeBack)")
        XCUIRemote.shared.press(.menu)
        XCTAssertEqual(app.state, .runningForeground, "Back should pause the active game within its host")
        waitForMenu(3)
        capture(app, "02b-remote-back-pause")
        // The pointer remains at Start. Move to the original Resume row.
        for _ in 0..<4 { XCUIRemote.shared.press(.right) }
        for _ in 0..<4 { XCUIRemote.shared.press(.down) }
        XCUIRemote.shared.press(.select)
        waitForMenu(0)
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

    @MainActor
    func testRestorationCreditLink() throws {
        #if os(iOS)
        let app = XCUIApplication()
        let save = "~/tmp/space-restoration-credit-\(UUID().uuidString)"
        app.launchEnvironment = ["SDB_UI_TEST": "1", "SDB_MUTE_AUDIO": "1", "SDB_SAVE_DIRECTORY": save]
        app.launch()
        defer { app.terminate() }
        let credits = app.buttons.matching(NSPredicate(format: "label == %@", "Credits")).firstMatch
        XCTAssertTrue(credits.waitForExistence(timeout: 15))
        credits.press(forDuration: 0.2)
        let link = app.descendants(matching: .any).matching(identifier: "restoration-credit-link").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertEqual(link.label, "Modernization: cammalleri.dev")
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertFalse(link.frame.intersects(back.frame), "Link must preserve the original EXIT hit area")
        capture(app, "restoration-credit-before-opening")
        link.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Native credit link should open the system browser")
        let address = safari.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "cammalleri.dev", "cammalleri.dev")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15), "The browser should receive the approved website address")
        capture(safari, "restoration-credit-website")
        app.activate()
        XCTAssertTrue(link.waitForExistence(timeout: 15), "Returning from the website retains Credits")
        back.press(forDuration: 0.2)
        XCTAssertTrue(credits.waitForExistence(timeout: 10), "Original EXIT still returns to the title")
        #endif
    }

    /// Read the semantic children without changing system VoiceOver settings.
    /// Ordinary taps still follow the original game menu hit-test path.
    @MainActor
    func testAccessibleOriginalMenus() throws {
        #if os(iOS)
        let app = XCUIApplication()
        let save = "~/tmp/space-accessible-menus-\(UUID().uuidString)"
        app.launchEnvironment = ["SDB_UI_TEST": "1", "SDB_MUTE_AUDIO": "1", "SDB_SAVE_DIRECTORY": save]
        print("SDB_UI_TEST isolatedSave=\(save)")
        app.launch()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        func button(_ label: String) -> XCUIElement {
            let result = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10), "Missing semantic menu action: \(label)")
            return result
        }
        func waitForMenu(_ type: Int) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", "menuType \(type)"), evaluatedWith: canvas)
            waitForExpectations(timeout: 10)
        }
        waitForMenu(1)
        XCTAssertTrue(button("Game Start").frame.intersects(canvas.frame))
        button("Options").tap()
        waitForMenu(5)
        button("Sound Off").tap()
        XCTAssertTrue(button("Sound Off").isSelected)
        button("Sound On").tap()
        XCTAssertTrue(button("Sound On").isSelected)
        button("Save and Exit").tap()
        waitForMenu(1)
        button("Credits").tap()
        waitForMenu(6)
        capture(app, "accessible-original-credits")
        let back = button("Back")
        XCTAssertLessThan(back.frame.width, canvas.frame.width)
        XCTAssertLessThan(back.frame.height, canvas.frame.height)
        XCTAssertGreaterThan(back.frame.midY, canvas.frame.midY)
        back.tap()
        waitForMenu(1)
        capture(app, "accessible-original-title")
        button("Game Start").tap()
        waitForMenu(0)
        let pause = app.buttons["pause-game"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        waitForMenu(3)
        XCTAssertTrue(button("Resume").exists)
        capture(app, "accessible-original-pause")
        button("Resume").tap()
        waitForMenu(0)
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForMenu(3)
        button("Resume").tap()
        waitForMenu(0)
        XCTAssertFalse(app.staticTexts["runtime-failure"].exists)
        #else
        throw XCTSkip("Semantic menu activation is checked in the iOS hosts and isolated engine tests.")
        #endif
    }

    @MainActor
    func testHapticHostWithMetal() throws { try verifyHapticHost(forceSoftware: false) }

    @MainActor
    func testHapticHostWithSoftware() throws { try verifyHapticHost(forceSoftware: true) }

    /// Simulator proof of real UIKit/window attachment and native dispatch
    /// readiness. Physical pulse strength remains a separate user check.
    @MainActor
    private func verifyHapticHost(forceSoftware: Bool) throws {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPad has no supported native phone haptic output.")
        }
        let app = XCUIApplication()
        let save = "~/tmp/space-haptic-host-\(UUID().uuidString)"
        app.launchEnvironment = ["SDB_UI_TEST": "1", "SDB_MUTE_AUDIO": "1",
            "SDB_HAPTICS_LOG": "1", "SDB_SAVE_DIRECTORY": save]
        if forceSoftware { app.launchEnvironment["SDB_CPU_RENDERER"] = "1" }
        app.launch()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        func waitForValue(_ value: String) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", value), evaluatedWith: canvas)
            waitForExpectations(timeout: 10)
        }
        func button(_ label: String) -> XCUIElement {
            let result = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10), "Missing original menu action: \(label)")
            return result
        }
        waitForValue("haptics ready")
        waitForValue(forceSoftware ? "renderer CPU" : "renderer Metal")
        button("Options").tap()
        waitForValue("menuType 5")
        button("Haptics Off").tap()
        waitForValue("haptics disabled")
        button("Haptics On").tap()
        waitForValue("haptics ready")
        XCTAssertTrue(button("Haptics On").isSelected)
        capture(app, forceSoftware ? "software-haptic-host-ready" : "metal-haptic-host-ready")
        XCUIDevice.shared.press(.home)
        app.activate()
        waitForValue("haptics ready")
        waitForValue("menuType 5")
        button("Save and Exit").tap()
        waitForValue("menuType 1")
        button("Game Start").tap()
        waitForValue("menuType 0")
        let pause = app.buttons["pause-game"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        waitForValue("menuType 3")
        button("Resume").tap()
        waitForValue("menuType 0")
        waitForValue("haptics ready")
        XCTAssertFalse(app.staticTexts["runtime-failure"].exists)
        #else
        throw XCTSkip("Native UIKit haptic attachment is specific to iPhone.")
        #endif
    }

    @MainActor
    func testSaveFailureRemainsPlayable() throws {
        #if os(iOS)
        let app = XCUIApplication()
        // A character device cannot contain child files. This produces a real
        // storage error without changing any file or ordinary user settings.
        app.launchEnvironment = ["SDB_UI_TEST": "1", "SDB_MUTE_AUDIO": "1", "SDB_SAVE_DIRECTORY": "/dev/null"]
        app.launch()
        defer { app.terminate() }
        let alert = app.alerts["Progress could not be saved"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        capture(app, "native-save-error")
        alert.buttons["OK"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["runtime-failure"].exists)
        XCTAssertFalse(alert.exists)
        #else
        throw XCTSkip("The native alert is checked in the iOS host; storage failure handling is shared and tested separately.")
        #endif
    }

    /// Actual host callbacks during an ordinary game, with original death/title
    /// transitions and real Start inputs. Logs measure host work, not scanout.
    @MainActor
    func testPerformanceGameplay() throws {
        let app = XCUIApplication()
        let save = "~/tmp/space-performance-\(UUID().uuidString)"
        app.launchEnvironment["SDB_UI_TEST"] = "1"
        app.launchEnvironment["SDB_MUTE_AUDIO"] = "1"
        app.launchEnvironment["SDB_PERFORMANCE_LOG"] = "1"
        app.launchEnvironment["SDB_SAVE_DIRECTORY"] = save
        print("SDB_UI_TEST isolatedSave=\(save)")
        app.launch()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any).matching(identifier: "game-canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        func waitForMenu(_ type: Int) {
            let predicate = NSPredicate(format: "value CONTAINS %@", "menuType \(type)")
            expectation(for: predicate, evaluatedWith: canvas)
            waitForExpectations(timeout: 10)
        }
        func menuType() -> Int? {
            (canvas.value as? String)?.components(separatedBy: "menuType ").last.flatMap(Int.init)
        }
        #if !os(tvOS)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let size = canvas.frame.size
            let width = max(480, 320 * size.width / size.height)
            let height = max(320, 480 * size.height / size.width)
            return canvas.coordinate(withNormalizedOffset: CGVector(
                dx: (x + (width - 480) / 2) / width,
                dy: (y + (height - 320) / 2) / height))
        }
        #endif
        waitForMenu(1)
        capture(app, "performance-01-title")
        #if os(tvOS)
        // Relative to the original center, matching the existing remote flow.
        for _ in 0..<4 { XCUIRemote.shared.press(.left) }
        for _ in 0..<5 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.select)
        #else
        point(160, 40).tap()
        #endif
        waitForMenu(0)
        capture(app, "performance-02-gameplay-start")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var gameplaySweeps = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            XCTAssertFalse(app.staticTexts["runtime-failure"].exists, "Original guest execution failed")
            XCTAssertTrue(canvas.exists)
            if menuType() == 1 {
                // Preserve original death behavior; start another ordinary game.
                #if os(tvOS)
                XCUIRemote.shared.press(.select)
                #else
                point(160, 40).tap()
                #endif
                waitForMenu(0)
            }
            if menuType() == 0 {
                #if os(tvOS)
                XCUIRemote.shared.press(.playPause)
                Thread.sleep(forTimeInterval: 0.6)
                for _ in 0..<3 { XCUIRemote.shared.press(.right) }
                for _ in 0..<3 { XCUIRemote.shared.press(.down) }
                XCUIRemote.shared.press(.playPause)
                // Return to Start's pointer position for a possible title return.
                for _ in 0..<3 { XCUIRemote.shared.press(.left) }
                for _ in 0..<3 { XCUIRemote.shared.press(.up) }
                #else
                point(100, 160).press(forDuration: 0.6, thenDragTo: point(350, 80))
                point(350, 80).press(forDuration: 0.4, thenDragTo: point(100, 240))
                #endif
                gameplaySweeps += 1
            }
            Thread.sleep(forTimeInterval: 0.35)
        }
        XCTAssertGreaterThan(gameplaySweeps, 0, "The original game never accepted the performance workload")
        capture(app, "performance-03-final")
    }
}
