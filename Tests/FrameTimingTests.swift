//
//  FrameTimingTests.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation

@main
enum FrameTimingTests {
    static func main() {
        for refreshRate in [30, 60, 120] {
            var clock = GameFrameClock()
            clock.reset(at: 0)
            var steps = 0
            for callback in 1...(refreshRate * 2) {
                let count = clock.steps(at: Double(callback) / Double(refreshRate))
                precondition(count <= GameFrameClock.maximumCatchUpSteps)
                steps += count
            }
            precondition(steps == 120, "\(refreshRate) Hz display changed the 60 Hz game rate")
        }

        let uptime = 1_000_000.0
        var refreshJitter = GameFrameClock()
        refreshJitter.reset(at: uptime)
        let callbackOffsets = [-0.0004, 0.0004, -0.0002, 0.0001, 0, 0.0003]
        for callback in 1...6_000 {
            let timestamp = uptime + Double(callback) * GameFrameClock.simulationStep +
                callbackOffsets[(callback - 1) % callbackOffsets.count]
            precondition(refreshJitter.steps(at: timestamp) == 1,
                         "Submillisecond 60 Hz callback jitter repeated or skipped a game pose")
        }

        var borrowed = GameFrameClock()
        borrowed.reset(at: 0)
        let earlyRefresh = GameFrameClock.simulationStep - 0.0005
        precondition(borrowed.steps(at: earlyRefresh) == 1)
        precondition(borrowed.steps(at: earlyRefresh) == 0,
                     "A duplicate early callback must not consume the same time twice")
        precondition(borrowed.steps(at: 2 * GameFrameClock.simulationStep - 0.0012) == 0,
                     "Borrowed time must remain debt instead of accumulating speed")
        precondition(borrowed.steps(at: 2 * GameFrameClock.simulationStep - 0.0009) == 1)

        var fasterDisplay = GameFrameClock()
        fasterDisplay.reset(at: 0)
        var fasterSteps = 0
        for callback in 1...60_000 {
            let timestamp = Double(callback) * (GameFrameClock.simulationStep - 0.0005)
            fasterSteps += fasterDisplay.steps(at: timestamp)
            precondition(Double(fasterSteps) * GameFrameClock.simulationStep <=
                         timestamp + GameFrameClock.schedulingLeeway + 0.0000001,
                         "Scheduling allowance advanced game time beyond its fixed bound")
        }
        precondition(fasterSteps == 58_200,
                     "Faster callbacks converted scheduling allowance into faster gameplay")

        var jittered = GameFrameClock()
        jittered.reset(at: 0)
        let intervals = [0.004, 0.008, 0.021, 0.033, 0.012, 0.019]
        var time = 0.0
        var steps = 0
        for callback in 0..<600 {
            time += intervals[callback % intervals.count]
            steps += jittered.steps(at: time)
        }
        precondition(steps == Int((time + 0.00000001) / GameFrameClock.simulationStep),
                     "Callback jitter lost or invented game steps")

        var stalled = GameFrameClock()
        stalled.reset(at: 0)
        precondition(stalled.steps(at: 1) == 4, "A long stall must bound catch-up work")
        precondition(stalled.steps(at: 1 + GameFrameClock.simulationStep) == 1,
                     "Discarded stall time must not create a catch-up spiral")

        var remainder = GameFrameClock()
        let halfStep = GameFrameClock.simulationStep / 2
        remainder.reset(at: 0)
        precondition(remainder.steps(at: halfStep) == 0)
        precondition(remainder.steps(at: 1 + halfStep) == 4)
        precondition(remainder.steps(at: 1 + 2 * halfStep) == 1,
                     "A bounded stall must preserve the existing fractional step")

        var resumed = GameFrameClock()
        resumed.reset(at: 0)
        _ = resumed.steps(at: halfStep)
        resumed.reset()
        precondition(resumed.steps(at: 300) == 0, "Resume must not simulate inactive time")
        precondition(resumed.steps(at: 300 + GameFrameClock.simulationStep) == 1)
        resumed.reset(at: 600)
        precondition(resumed.steps(at: 600 + GameFrameClock.simulationStep) == 1)
        precondition(resumed.steps(at: 600 + GameFrameClock.simulationStep) == 0,
                     "Duplicate display callbacks must not advance game time")

        var invalid = GameFrameClock()
        invalid.reset(at: 2)
        precondition(invalid.steps(at: .nan) == 0)
        precondition(invalid.steps(at: .infinity) == 0)
        precondition(invalid.steps(at: 1) == 0, "A backwards timestamp must start a new epoch")
        precondition(invalid.steps(at: 1 + GameFrameClock.simulationStep) == 1)

        var longRunning = GameFrameClock()
        longRunning.reset(at: uptime)
        var longRunSteps = 0
        for callback in 1...72_000 {
            longRunSteps += longRunning.steps(at: uptime + Double(callback) / 120)
        }
        precondition(longRunSteps == 36_000,
                     "Large timestamps or high refresh rates drifted over ten minutes")
        print("PASS: 30/60/120 Hz, 60 Hz submillisecond cadence, bounded lead with debt, faster display rate, jitter, bounded catch-up, suspend/resume and ten-minute uptime")
    }
}
