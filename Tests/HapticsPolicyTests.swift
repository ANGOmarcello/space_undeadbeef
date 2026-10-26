//
//  HapticsPolicyTests.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation

@main
@MainActor
enum HapticsPolicyTests {
    static func main() {
        var checks = 0
        func require(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        for (events, expected) in [(UInt(7), GameHapticEvent.damage),
                                   (UInt(3), .shot), (UInt(1), .shot),
                                   (UInt(2), .targetLock), (UInt(4), .damage),
                                   (UInt(0x82), .targetLock)] {
            var policy = GameHapticPolicy()
            require(policy.feedback(enabled: true, events: events, at: 0) == expected,
                    "Damage, laser release and lock must coalesce in that priority order")
        }

        var disabled = GameHapticPolicy()
        require(disabled.feedback(enabled: false, events: 7, at: 0) == nil,
                "OFF must discard feedback")
        require(disabled.feedback(enabled: true, events: 0, at: 0) == nil,
                "No event must produce no feedback")
        require(disabled.feedback(enabled: true, events: 0x80, at: 0) == nil,
                "Unknown bits must produce no feedback")
        require(disabled.feedback(enabled: true, events: 1, at: 0) == .shot,
                "OFF, empty and unknown calls must not consume the first valid event")

        var boundary = GameHapticPolicy()
        require(boundary.feedback(enabled: true, events: 1, at: 10) == .shot,
                "A fresh policy accepts an event")
        require(boundary.feedback(enabled: true, events: 4, at: 10.249999) == nil,
                "Damage must respect the same cooldown as a laser release")
        require(boundary.feedback(enabled: true, events: 2, at: 10.25) == .targetLock,
                "An event exactly at the quarter-second boundary must be accepted")
        require(boundary.feedback(enabled: true, events: 4, at: 10.25) == nil,
                "A duplicate timestamp must not emit a second impact")
        require(boundary.feedback(enabled: true, events: 0x80, at: 10.5) == nil,
                "An unknown event after cooldown must not consume the next event")
        require(boundary.feedback(enabled: true, events: 1, at: 10.5) == .shot,
                "The next valid event uses the unchanged cooldown")

        var discarded = GameHapticPolicy()
        require(discarded.feedback(enabled: true, events: 4, at: 100) == .damage,
                "Begin no-queue test with one impact")
        require(discarded.feedback(enabled: true, events: 1, at: 100.1) == nil,
                "Cooldown discards a laser event")
        require(discarded.feedback(enabled: true, events: 0, at: 100.25) == nil,
                "A discarded event must not replay when cooldown expires")
        require(discarded.feedback(enabled: true, events: 2, at: 100.25) == .targetLock,
                "A fresh lower-priority event must not inherit discarded laser bits")
        require(discarded.feedback(enabled: false, events: 4, at: 100.5) == nil,
                "OFF discards even a damage event after cooldown")
        require(discarded.feedback(enabled: true, events: 0, at: 100.5) == nil,
                "Enabling does not preview or replay an OFF event")

        var invalid = GameHapticPolicy()
        for timestamp in [Double.nan, .infinity, -.infinity] {
            require(invalid.feedback(enabled: true, events: 4, at: timestamp) == nil,
                    "Nonfinite timestamps must not emit feedback")
        }
        require(invalid.feedback(enabled: true, events: 1, at: 0) == .shot,
                "Invalid timestamps must not corrupt a fresh policy")
        require(invalid.feedback(enabled: true, events: 4, at: -1) == nil,
                "A backwards timestamp must not bypass the cooldown")
        require(invalid.feedback(enabled: true, events: 2, at: 0.25) == .targetLock,
                "A valid exact boundary works after a backwards timestamp")

        var uptime = GameHapticPolicy()
        let longUptime = 1_000_000.0
        require(uptime.feedback(enabled: true, events: 1, at: longUptime) == .shot,
                "Large monotonic uptime accepts a first event")
        require(uptime.feedback(enabled: true, events: 4, at: longUptime + 0.249) == nil,
                "Large uptime retains the cooldown")
        require(uptime.feedback(enabled: true, events: 4, at: longUptime + 0.25) == .damage,
                "Large uptime accepts the exact cooldown boundary")

        var toggled = GameHapticPolicy()
        require(toggled.feedback(enabled: true, events: 1, at: 0) == .shot,
                "Begin toggle test with one impact")
        for centisecond in 1..<25 {
            let timestamp = Double(centisecond) / 100
            require(toggled.feedback(enabled: false, events: 7, at: timestamp) == nil,
                    "OFF must discard each burst")
            require(toggled.feedback(enabled: true, events: 7, at: timestamp) == nil,
                    "Rapid OFF/ON toggles must not reset the global cooldown")
        }
        require(toggled.feedback(enabled: true, events: 7, at: 0.25) == .damage,
                "Cooldown survives toggles and ends on its original boundary")

        var sustained = GameHapticPolicy()
        var emitted = 0
        for frame in 0...600 {
            if sustained.feedback(enabled: true, events: 7, at: Double(frame) / 60) != nil {
                emitted += 1
            }
        }
        require(emitted == 41, "Ten seconds of 60 Hz event bursts must emit at most four impacts per second")
        require(!GameHaptics.offersHaptics, "The macOS policy test host must not offer hardware feedback")
        print("PASS: \(checks) haptic policy checks; priority, OFF, event discard, exact cooldown, invalid times, long uptime and rapid toggles; no hardware feedback")
    }
}
