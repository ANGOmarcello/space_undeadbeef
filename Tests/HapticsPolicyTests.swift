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

        for (events, expected) in [(UInt(63), GameHapticEvent.menuSelection),
                                   (UInt(55), .damage), (UInt(51), .shot),
                                   (UInt(50), .primaryShot), (UInt(18), .explosion),
                                   (UInt(2), .targetLock), (UInt(0x88), .menuSelection)] {
            var policy = GameHapticPolicy()
            require(policy.feedback(enabled: true, events: events, at: 0) == expected,
                    "Coalesced events must preserve menu, damage, volley, primary and explosion priority")
        }

        var disabled = GameHapticPolicy()
        require(disabled.feedback(enabled: false, events: 63, at: 0) == nil, "OFF discards every event kind")
        require(disabled.feedback(enabled: true, events: 0, at: 0) == nil, "Empty masks produce no feedback")
        require(disabled.feedback(enabled: true, events: 0x80, at: 0) == nil, "Unknown bits produce no feedback")
        require(disabled.feedback(enabled: true, events: 8, at: 0) == .menuSelection,
                "A fresh Haptics ON preview can use an accepted menu event")

        var boundary = GameHapticPolicy()
        require(boundary.feedback(enabled: true, events: 1, at: 10) == .shot, "Accept an initial volley")
        require(boundary.feedback(enabled: true, events: 1, at: 10.249999) == nil, "Bound repeat volleys")
        require(boundary.feedback(enabled: true, events: 1, at: 10.25) == .shot, "Accept the exact quarter-second boundary")
        require(boundary.feedback(enabled: true, events: 1, at: 10.25) == nil, "Duplicate timestamps cannot repeat a volley")
        require(boundary.feedback(enabled: true, events: 0x80, at: 10.5) == nil, "Unknown bits do not consume cooldown")
        require(boundary.feedback(enabled: true, events: 1, at: 10.5) == .shot, "The next real volley retains its boundary")

        var targets = GameHapticPolicy()
        require(targets.feedback(enabled: true, events: 2, at: 0) == .targetLock, "Accept a target tick")
        require(targets.feedback(enabled: true, events: 1, at: 0.01) == .shot,
                "A target tick must not consume the weapon budget")
        require(targets.feedback(enabled: true, events: 2, at: 0.99) == nil, "Target ticks stay at most once a second")
        require(targets.feedback(enabled: true, events: 2, at: 1) == .targetLock, "Target cooldown ends exactly")
        require(targets.feedback(enabled: true, events: 32, at: 1.01) == .primaryShot,
                "A target tick must not suppress a primary shot either")

        var explosions = GameHapticPolicy()
        require(explosions.feedback(enabled: true, events: 16, at: 0) == .explosion, "Accept a real explosion")
        require(explosions.feedback(enabled: true, events: 32, at: 0.125) == .primaryShot,
                "Explosion feedback must not starve the next weapon")
        require(explosions.feedback(enabled: true, events: 16, at: 0.25) == nil,
                "Explosions leave a quiet interval after weapon feedback")
        require(explosions.feedback(enabled: true, events: 1, at: 0.25) == .shot,
                "A volley may preempt a recent weaker primary pulse")
        require(explosions.feedback(enabled: true, events: 16, at: 0.5) == .explosion,
                "Explosion feedback can return after a quiet quarter second")
        require(explosions.feedback(enabled: true, events: 1, at: 0.51) == .shot,
                "Explosions do not delay a ready targeted volley")

        var primary = GameHapticPolicy()
        require(primary.feedback(enabled: true, events: 32, at: 0) == .primaryShot, "Accept an initial primary pulse")
        require(primary.feedback(enabled: true, events: 32, at: 0.499999) == nil, "Primary auto-fire stays at most two hertz")
        require(primary.feedback(enabled: true, events: 32, at: 0.5) == .primaryShot, "Primary cooldown ends exactly")
        require(primary.feedback(enabled: true, events: 1, at: 0.625) == .shot, "A targeted release can preempt primary")
        require(primary.feedback(enabled: true, events: 1, at: 0.75) == nil, "Preemption cannot remove the volley's own limit")
        require(primary.feedback(enabled: true, events: 1, at: 0.875) == .shot, "Volley limit survives preemption")
        require(primary.feedback(enabled: true, events: 32, at: 1) == nil, "Primary leaves quiet time after a stronger volley")

        var damage = GameHapticPolicy()
        require(damage.feedback(enabled: true, events: 1, at: 0) == .shot, "Begin with weaker feedback")
        require(damage.feedback(enabled: true, events: 4, at: 0.01) == .damage, "Damage can replace recent weaker feedback")
        require(damage.feedback(enabled: true, events: 4, at: 0.1) == nil, "Repeated damage still has a cooldown")
        var damageBoundary = GameHapticPolicy()
        require(damageBoundary.feedback(enabled: true, events: 4, at: 0) == .damage, "Start damage boundary test")
        require(damageBoundary.feedback(enabled: true, events: 4, at: 0.35) == .damage, "Damage accepts its exact boundary")

        var menus = GameHapticPolicy()
        require(menus.feedback(enabled: true, events: 1, at: 0) == .shot, "Begin independent menu test")
        require(menus.feedback(enabled: true, events: 8, at: 0.01) == .menuSelection,
                "A weapon must not suppress an accepted menu selection")
        require(menus.feedback(enabled: true, events: 8, at: 0.1) == nil, "Menu taps are debounced")
        var menuBoundary = GameHapticPolicy()
        require(menuBoundary.feedback(enabled: true, events: 8, at: 0) == .menuSelection, "Start menu boundary test")
        require(menuBoundary.feedback(enabled: true, events: 8, at: 0.12) == .menuSelection, "Menu accepts its exact boundary")
        require(menuBoundary.feedback(enabled: false, events: 8, at: 0.24) == nil, "OFF immediately suppresses menu feedback")
        require(menuBoundary.feedback(enabled: true, events: 0, at: 0.24) == nil, "Enabling never replays an OFF event")

        var discarded = GameHapticPolicy()
        require(discarded.feedback(enabled: true, events: 1, at: 100) == .shot, "Begin no-queue test")
        require(discarded.feedback(enabled: true, events: 1, at: 100.1) == nil, "Cooldown discards an event")
        require(discarded.feedback(enabled: true, events: 0, at: 100.25) == nil, "Discarded events never replay later")
        require(discarded.feedback(enabled: true, events: 2, at: 100.25) == .targetLock,
                "A fresh lower-priority event does not inherit discarded bits")

        var invalid = GameHapticPolicy()
        for timestamp in [Double.nan, .infinity, -.infinity] {
            require(invalid.feedback(enabled: true, events: 63, at: timestamp) == nil, "Reject nonfinite timestamps")
        }
        require(invalid.feedback(enabled: true, events: 1, at: 0) == .shot, "Invalid timestamps do not corrupt a fresh policy")
        require(invalid.feedback(enabled: true, events: 8, at: -1) == nil, "Backwards time cannot switch channels to bypass limits")
        require(invalid.feedback(enabled: true, events: 1, at: 0.25) == .shot, "Valid time still works after rejection")

        var uptime = GameHapticPolicy()
        let longUptime = 1_000_000.0
        require(uptime.feedback(enabled: true, events: 1, at: longUptime) == .shot, "Large uptime accepts an event")
        require(uptime.feedback(enabled: true, events: 1, at: longUptime + 0.249) == nil, "Large uptime retains cooldown")
        require(uptime.feedback(enabled: true, events: 1, at: longUptime + 0.25) == .shot, "Large uptime accepts the exact boundary")

        var toggled = GameHapticPolicy()
        require(toggled.feedback(enabled: true, events: 1, at: 0) == .shot, "Begin preference toggle test")
        for centisecond in 1..<25 {
            let timestamp = Double(centisecond) / 100
            require(toggled.feedback(enabled: false, events: 1, at: timestamp) == nil, "OFF always discards feedback")
            require(toggled.feedback(enabled: true, events: 1, at: timestamp) == nil, "OFF/ON cannot reset cooldown")
        }
        require(toggled.feedback(enabled: true, events: 1, at: 0.25) == .shot, "Toggle preserves the original boundary")

        for (event, interval) in [(GameHapticEvent.shot, 0.25), (.primaryShot, 0.5),
                                  (.explosion, 0.25), (.targetLock, 1.0), (.damage, 0.35), (.menuSelection, 0.12)] {
            var sustained = GameHapticPolicy()
            var emitted = 0
            for frame in 0...600 {
                if sustained.feedback(enabled: true, events: event.rawValue, at: Double(frame) / 60) != nil {
                    emitted += 1
                }
            }
            require(emitted > 1 && emitted <= Int(10 / interval) + 1,
                    "Continuous event bursts must preserve each kind's bound")
        }
        require(!GameHaptics.offersHaptics, "The macOS policy host offers no hardware feedback")
        let phoneChecks = checks

        // Regression for the reported Watch gaps: a volley must not impose a
        // 750 ms blackout, and fresh explosions may return after 250 ms rather
        // than the former Watch-only 1.5 seconds. Keep the actual event result
        // explicit; equality alone would let both hosts silently lose feedback.
        let watchTrace: [(time: TimeInterval, events: UInt, expected: GameHapticEvent?)] = [
            (0, 8, .menuSelection),
            (0.125, 16, .explosion),
            (0.375, 16, .explosion),
            (0.5, 32, .primaryShot),
            (0.625, 1, .shot),
            (0.75, 16, nil),
            (0.875, 16, .explosion),
            (1, 1, .shot),
            (1.015625, 4, .damage),
            (1.265625, 16, .explosion),
            (1.390625, 4, .damage),
            (1.640625, 16, .explosion),
            (1.890625, 16, .explosion),
            (2.140625, 16, .explosion)
        ]
        var watch = WatchGameHapticPolicy()
        var phone = GameHapticPolicy()
        for step in watchTrace {
            let actual = watch.feedback(enabled: true, events: step.events, at: step.time)
            require(actual == step.expected, "Watch must deliver the intended impact/explosion cadence")
            require(actual == phone.feedback(enabled: true, events: step.events, at: step.time),
                    "Watch and iPhone choose the same event at the same time")
        }
        require(watch.feedback(enabled: false, events: 63, at: 3) == nil,
                "Watch OFF still discards every event")
        require(watch.feedback(enabled: true, events: 0, at: 4) == nil,
                "Watch ON cannot replay explosions discarded while OFF")

        print("PASS: \(checks) haptic policy checks (\(phoneChecks) unchanged iPhone, \(checks - phoneChecks) Watch); shared event cadence, priority, exact boundaries, OFF, no queue and monotonic time; no hardware feedback")
    }
}
