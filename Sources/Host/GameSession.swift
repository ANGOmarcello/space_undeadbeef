//
//  GameSession.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

import CoreGraphics
import Foundation
import Observation

enum GameLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 320
    static let size = CGSize(width: width, height: height)
    static let simulationStep = GameFrameClock.simulationStep
    static let pointerStep = width / 24
    static let pointerDiameter = height / 40
    static let pointerStroke = pointerDiameter / 4

    static func fittedSize(in available: CGSize) -> CGSize {
        let scale = max(0, min(available.width / width, available.height / height))
        return CGSize(width: width * scale, height: height * scale)
    }

    static func point(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(width, max(0, location.x / max(size.width, 1) * width)),
            y: min(height, max(0, location.y / max(size.height, 1) * height))
        )
    }
}

struct GameViewport: Equatable {
    let size: CGSize
    let scale: Double
    let safeArea: CGRect
}

@MainActor
@Observable
final class GameSession {
    private(set) var frame: CGImage?
    private(set) var logicalSize = GameLayout.size
    private(set) var rasterViewSize = GameLayout.size
    private(set) var usesMetalRenderer = false
    private(set) var isActive = false
    private(set) var canPause = false
    private(set) var gameMenuType = 0
    private(set) var failure: String?
    private(set) var pointer = CGPoint(x: GameLayout.width / 2, y: GameLayout.height / 2)
    private(set) var showsPointer = false
    private(set) var isTouching = false

    @ObservationIgnored private(set) var engine: SDBEngine?
    @ObservationIgnored private var viewport: GameViewport?
    @ObservationIgnored private var softwareTimer: Timer?
    @ObservationIgnored private var clock = GameFrameClock()
    @ObservationIgnored private var releasesTapAfterStep = false
    @ObservationIgnored private let haptics = GameHaptics()

    func setActive(_ active: Bool) {
        if !active {
            isActive = false
            cancelTouch()
            engine?.setSuspended(true)
            _ = engine?.consumeHapticEvents()
            haptics.reset()
            canPause = false
            softwareTimer?.invalidate()
            softwareTimer = nil
            clock.reset()
            return
        }
        guard !isActive, failure == nil else { return }
        if engine == nil {
            guard let path = Bundle.main.resourceURL?.appendingPathComponent("Original").path else {
                failure = "The original game resources could not be found."
                return
            }
            engine = SDBEngine(resourcePath: path, offersHaptics: GameHaptics.offersHaptics)
            failure = engine?.failure
            if let viewport { configure(viewport) }
            if let engine { refreshState(from: engine) }
        }
        guard failure == nil else { return }
        engine?.setSuspended(false)
        if let engine { refreshState(from: engine) }
        guard failure == nil else { return }
        clock.reset(at: ProcessInfo.processInfo.systemUptime)
        isActive = true
        // MetalKit drives supported views directly. Watch and other software
        // fallbacks still need a timer to publish their CPU-rendered CGImage.
        guard !usesMetalRenderer else { return }
        let timer = Timer(timeInterval: GameLayout.simulationStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.drawDisplayFrame(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        softwareTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called by MetalKit immediately before presentation, or by the software
    /// fallback timer. Catch-up advances original game logic, then renders once.
    @discardableResult
    func drawDisplayFrame(at time: TimeInterval) -> Int {
        guard isActive, failure == nil, let engine else { return 0 }
        let steps = clock.steps(at: time)
        guard steps > 0 else { return 0 }
        for _ in 0..<steps {
            engine.advanceSimulation(GameLayout.simulationStep)
            if releasesTapAfterStep {
                endTouch()
                releasesTapAfterStep = false
            }
        }
        engine.renderFrame()
        let events = engine.consumeHapticEvents()
        haptics.update(enabled: isActive && engine.hapticsEnabled && engine.gameMenuType == 0 && engine.failure == nil,
                       events: events)
        refreshState(from: engine)
        if failure != nil { setActive(false) }
        return steps
    }

    func configure(_ viewport: GameViewport) {
        self.viewport = viewport
        guard let engine else { return }
        cancelTouch()
        let old = logicalSize
        engine.configureViewport(viewport.size, displayScale: viewport.scale, safeArea: viewport.safeArea)
        logicalSize = engine.logicalSize
        rasterViewSize = engine.rasterViewSize
        pointer = CGPoint(x: pointer.x / old.width * logicalSize.width,
                          y: pointer.y / old.height * logicalSize.height)
        refreshState(from: engine)
    }

    private func refreshState(from engine: SDBEngine) {
        let metal = engine.usesMetalRenderer
        if usesMetalRenderer != metal { usesMetalRenderer = metal }
        if !metal { frame = engine.frame }
        else if frame != nil { frame = nil }
        let pause = engine.canPause
        if canPause != pause { canPause = pause }
        let menu = Int(engine.gameMenuType)
        if gameMenuType != menu { gameMenuType = menu }
        if failure != engine.failure { failure = engine.failure }
    }

    func pauseGame() {
        guard let engine, canPause else { return }
        cancelTouch()
        engine.pauseGame()
        _ = engine.consumeHapticEvents()
        haptics.reset()
        refreshState(from: engine)
        if failure != nil { setActive(false) }
    }

    func point(inView point: CGPoint) -> CGPoint {
        engine?.logicalPoint(forViewPoint: point) ?? .zero
    }

    func drag(to point: CGPoint) {
        pointer = point
        showsPointer = false
        engine?.touchPhase(isTouching ? 1 : 0, x: point.x, y: point.y)
        isTouching = true
    }

    func endTouch() {
        guard isTouching else { return }
        engine?.touchPhase(2, x: pointer.x, y: pointer.y)
        isTouching = false
    }

    func cancelTouch() {
        guard isTouching else { return }
        engine?.touchPhase(3, x: pointer.x, y: pointer.y)
        isTouching = false
        releasesTapAfterStep = false
    }

    func movePointer(dx: CGFloat, dy: CGFloat) {
        pointer = CGPoint(
            x: min(logicalSize.width, max(0, pointer.x + dx)),
            y: min(logicalSize.height, max(0, pointer.y + dy))
        )
        showsPointer = true
        if isTouching { engine?.touchPhase(1, x: pointer.x, y: pointer.y) }
    }

    func setPointerY(_ fraction: Double) {
        movePointer(dx: 0, dy: CGFloat(fraction) * logicalSize.height - pointer.y)
    }

    func beginPointerTouch() {
        guard !isTouching else { return }
        showsPointer = true
        isTouching = true
        engine?.touchPhase(0, x: pointer.x, y: pointer.y)
    }

    func tapPointer() {
        beginPointerTouch()
        releasesTapAfterStep = true
    }

    func togglePointerTouch() {
        if isTouching { endTouch() } else { beginPointerTouch() }
    }
}
