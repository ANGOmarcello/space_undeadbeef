//
//  CrownInputTests.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation

@main
@MainActor
enum CrownInputTests {
    static func main() {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        func near(_ actual: Double?, _ expected: Double) -> Bool {
            actual.map { abs($0 - expected) < 0.000001 } ?? false
        }

        require(near(GameCrownInput.wrappedDelta(from: 0.95, to: -0.98), 0.07),
                "Continuous forward rotation crosses the finite seam without a backward jump")
        require(near(GameCrownInput.wrappedDelta(from: -0.95, to: 0.98), -0.07),
                "Continuous backward rotation crosses the finite seam without a forward jump")
        require(near(GameCrownInput.wrappedDelta(from: 0.1, to: 0.2), 0.1),
                "Ordinary relative rotation preserves its normalized distance")
        require(GameCrownInput.wrappedDelta(from: .infinity, to: 0).isNaN,
                "Invalid binding values safely cancel steering")

        var input = GameCrownInput()
        require(near(input.target(for: 0.1, shipNormalizedY: 0.2), 0.3),
                "A new gesture anchors the actual ship, not a fixed screen midpoint")
        require(near(input.target(for: 0.1, shipNormalizedY: 0.21), 0.4),
                "Fast Crown deltas accumulate while the original spring catches up")
        input.reset()
        require(near(input.target(for: -0.1, shipNormalizedY: 0.8), 0.7),
                "An idle or interrupted gesture discards its old destination")
        require(near(input.target(for: 10, shipNormalizedY: 0.8), 1), "Travel stops at the playable edge")
        require(near(input.target(for: -0.1, shipNormalizedY: 0.8), 0.9),
                "Reversing at an edge responds immediately without overscroll debt")
        require(input.target(for: 0, shipNormalizedY: 0.8) == nil, "No rotation creates no steering request")
        require(input.target(for: .nan, shipNormalizedY: 0.8) == nil && input.targetNormalizedY == nil,
                "Invalid input cannot retain a stale destination")

        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: CrownInputTests Resources/Original isolated-save-directory\n".utf8))
            exit(64)
        }
        let resources = CommandLine.arguments[1]
        let save = CommandLine.arguments[2]
        // The caller creates this empty task-owned directory and removes it on
        // exit. All preferences and the legacy save remain isolated from users.
        require(FileManager.default.fileExists(atPath: save), "The caller must supply an isolated save directory")
        require((try? FileManager.default.contentsOfDirectory(atPath: save).isEmpty) == true,
                "The isolated save directory must be empty")
        setenv("SDB_SAVE_DIRECTORY", save, 1)
        setenv("SDB_MUTE_AUDIO", "1", 1)
        setenv("SDB_CPU_RENDERER", "1", 1)
        let engine = SDBEngine(resourcePath: resources, offersHaptics: false)
        engine.watchLayout = true
        engine.configureViewport(CGSize(width: 208, height: 248), displayScale: 2,
                                 safeArea: CGRect(x: 0, y: 0, width: 208, height: 248))
        require(engine.failure == nil, "Initialize the actual original runtime")
        for _ in 0..<120 { engine.advanceSimulation(GameLayout.simulationStep) }
        let start = CGPoint(x: 160, y: engine.logicalSize.height / 2 - 120)
        engine.touchPhase(0, x: start.x, y: start.y)
        engine.advanceSimulation(GameLayout.simulationStep)
        engine.touchPhase(2, x: start.x, y: start.y)
        for _ in 0..<120 { engine.advanceSimulation(GameLayout.simulationStep) }
        require(engine.canPause && engine.gameMenuType == 0, "Enter gameplay through the original Game Start menu")

        let session = GameSession(engine: engine)
        session.setActive(true)
        var time = ProcessInfo.processInfo.systemUptime
        require(!engine.canSteerShip, "The original entrance precedes the playable ship state")
        session.steerWithCrown(delta: 0.4)
        // The original entrance animation reports gameplay before the ship
        // accepts steering. Complete it through normal fixed updates.
        for _ in 0..<180 { engine.advanceSimulation(GameLayout.simulationStep) }
        func step(_ count: Int) {
            var advanced = 0
            for _ in 0..<count {
                time += GameLayout.simulationStep
                advanced += session.drawDisplayFrame(at: time)
            }
            require(advanced == count, "The real Session advances the requested fixed-step batch")
            require(engine.failure == nil, "The original engine must remain healthy")
        }
        defer { session.setActive(false) }

        let entranceAnchor = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.01)
        step(60)
        require(abs(engine.shipNormalizedY - min(1, entranceAnchor + 0.01)) < 0.03,
                "Crown rotation during the entrance cannot queue a destination for later gameplay")
        session.endCrownSteering()

        let initial = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.35)
        step(8)
        require(engine.shipNormalizedY > initial + 0.01,
                "Crown input moves the actual ship through its original spring (\(initial) → \(engine.shipNormalizedY))")
        require(!session.isTouching && !engine.shipAiming, "Crown steering never synthesizes a held aiming touch")
        session.endCrownSteering()
        let newAnchor = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.02)
        step(60)
        require(abs(engine.shipNormalizedY - min(1, newAnchor + 0.02)) < 0.03,
                "A fresh Crown gesture follows the actual ship instead of jumping to the prior destination")

        session.steerWithCrown(delta: -0.4)
        session.configure(GameViewport(size: CGSize(width: 208, height: 248), scale: 2,
                                       safeArea: CGRect(x: 0, y: 0, width: 208, height: 248)))
        let resizedAnchor = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.01)
        step(30)
        require(abs(engine.shipNormalizedY - min(1, resizedAnchor + 0.01)) < 0.03,
                "Viewport reconfiguration clears the old Crown target before anchoring new input")

        let touch = CGPoint(x: engine.logicalSize.width / 2, y: engine.logicalSize.height / 2)
        session.drag(to: touch)
        step(1)
        require(session.isTouching && engine.shipAiming, "A real finger retains original targeting ownership")
        session.steerWithCrown(delta: -0.8)
        require(session.isTouching && engine.shipAiming, "Crown rotation cannot release or replace a held finger")
        session.cancelTouch()
        session.steerWithCrown(delta: -0.05)
        step(1)
        require(!session.isTouching && !engine.shipAiming, "Returning to the Crown clears canceled legacy aim without holding touch")

        session.pauseGame()
        require(!engine.canPause && !session.canPause, "The original pause transition updates host gameplay availability")
        let paused = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.8)
        // Let the original pause animation complete before selecting Continue.
        step(120)
        require(abs(engine.shipNormalizedY - paused) < 0.000001, "Crown rotation does not move the ship in a menu")
        let resume = CGPoint(x: engine.logicalSize.width / 2, y: engine.logicalSize.height / 2 - 30)
        session.drag(to: resume)
        step(1)
        session.endTouch()
        step(120)
        require(engine.canPause, "Continue through the original pause menu (menu=\(engine.gameMenuType), \(engine.diagnostics))")

        session.steerWithCrown(delta: 0.4)
        session.setActive(false)
        require(!session.isActive && !session.isTouching, "Backgrounding cancels active input ownership")
        session.steerWithCrown(delta: -0.8)
        session.setActive(true)
        time = ProcessInfo.processInfo.systemUptime
        let resumed = engine.shipNormalizedY
        session.steerWithCrown(delta: 0.01)
        step(60)
        require(abs(engine.shipNormalizedY - min(1, resumed + 0.01)) < 0.03,
                "Resuming starts from the current ship with no stale Crown destination")
        require(!engine.shipAiming && !session.isTouching, "Pause and resume leave no stuck touch or targeting charge")
        print("PASS: \(checks) Crown model and real Session-to-engine checks")
    }
}
