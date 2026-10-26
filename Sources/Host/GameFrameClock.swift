//
//  GameFrameClock.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation

/// Fixed game time is independent of the display's refresh rate. Missed frames
/// catch up within a small bound; resuming a scene starts a new timing epoch.
struct GameFrameClock {
    static let framesPerSecond = 60
    static let simulationStep = 1.0 / Double(framesPerSecond)
    static let maximumCatchUpSteps = 4
    /// MetalKit callbacks arrive close to, rather than exactly on, a refresh
    /// boundary. Borrow at most one millisecond, preserving the debt below.
    static let schedulingLeeway = 0.001

    private var lastTime: TimeInterval?
    private var accumulatedTime = 0.0

    mutating func reset(at time: TimeInterval? = nil) {
        lastTime = time.flatMap { $0.isFinite ? $0 : nil }
        accumulatedTime = 0
    }

    mutating func steps(at time: TimeInterval) -> Int {
        guard time.isFinite else { return 0 }
        guard let previous = lastTime else {
            lastTime = time
            return 0
        }
        lastTime = time
        let elapsed = time - previous
        guard elapsed >= 0 else {
            accumulatedTime = 0
            return 0
        }
        accumulatedTime += min(elapsed, Self.simulationStep * Double(Self.maximumCatchUpSteps))
        // A slightly early callback should not repeat a pose and require two
        // steps on the next refresh. Negative carry repays any borrowed time;
        // clamping it to zero would make a fast/jittered display speed up play.
        // The additional tolerance covers timestamp rounding at a large uptime.
        let roundingTolerance = Self.simulationStep * 0.000001
        let count = max(0, min(Self.maximumCatchUpSteps,
                        Int((accumulatedTime + Self.schedulingLeeway + roundingTolerance) / Self.simulationStep)))
        accumulatedTime -= Double(count) * Self.simulationStep
        return count
    }
}
