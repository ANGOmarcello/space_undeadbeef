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
    static let simulationStep = 1.0 / 60.0
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

@MainActor
@Observable
final class GameSession {
    private(set) var frame: CGImage?
    private(set) var failure: String?
    private(set) var pointer = CGPoint(x: GameLayout.width / 2, y: GameLayout.height / 2)
    private(set) var showsPointer = false
    private(set) var isTouching = false

    @ObservationIgnored private var engine: SDBEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTime = 0.0
    @ObservationIgnored private var accumulatedTime = 0.0
    @ObservationIgnored private var releasesTapAfterStep = false

    func setActive(_ active: Bool) {
        if !active {
            cancelTouch()
            engine?.setSuspended(true)
            timer?.invalidate()
            timer = nil
            lastTime = 0
            accumulatedTime = 0
            return
        }
        guard timer == nil, failure == nil else { return }
        if engine == nil {
            guard let path = Bundle.main.resourceURL?.appendingPathComponent("Original").path else {
                failure = "The original game resources could not be found."
                return
            }
            engine = SDBEngine(resourcePath: path)
            failure = engine?.failure
            frame = engine?.frame
        }
        guard failure == nil else { return }
        engine?.setSuspended(false)
        lastTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: GameLayout.simulationStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard let engine else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Keep the original 60 Hz simulation independent of host redraw cadence.
        // A suspended scene resumes without simulating its time in the background.
        accumulatedTime += min(now - lastTime, GameLayout.simulationStep * 4)
        lastTime = now
        while accumulatedTime >= GameLayout.simulationStep {
            engine.update(GameLayout.simulationStep)
            accumulatedTime -= GameLayout.simulationStep
            if releasesTapAfterStep {
                endTouch()
                releasesTapAfterStep = false
            }
        }
        frame = engine.frame
        failure = engine.failure
        if failure != nil { setActive(false) }
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
            x: min(GameLayout.width, max(0, pointer.x + dx)),
            y: min(GameLayout.height, max(0, pointer.y + dy))
        )
        showsPointer = true
        if isTouching { engine?.touchPhase(1, x: pointer.x, y: pointer.y) }
    }

    func setPointerY(_ fraction: Double) {
        movePointer(dx: 0, dy: CGFloat(fraction) * GameLayout.height - pointer.y)
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
