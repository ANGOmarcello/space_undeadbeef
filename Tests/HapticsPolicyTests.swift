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

        for (events, expected) in [(UInt(63), GameHapticEvent.menuSelection),
                                   (UInt(55), .damage), (UInt(51), .shot),
                                   (UInt(50), .primaryShot), (UInt(18), .explosion),
                                   (UInt(2), .targetLock), (UInt(0x88), .menuSelection)] {
            var policy = WatchGameHapticPolicy()
            require(policy.feedback(enabled: true, events: events, at: 0) == expected,
                    "Watch coalesced events preserve menu, damage, volley, primary, explosion and target priority")
        }

        for (event, interval) in [(GameHapticEvent.menuSelection, 0.25), (.shot, 0.75),
                                  (.primaryShot, 1.0), (.damage, 0.75), (.explosion, 1.5), (.targetLock, 2.0)] {
            var boundary = WatchGameHapticPolicy()
            require(boundary.feedback(enabled: true, events: event.rawValue, at: 10) == event,
                    "Watch accepts an initial event of every kind")
            require(boundary.feedback(enabled: true, events: event.rawValue, at: 10 + interval - 0.000001) == nil,
                    "Watch rejects every kind immediately before its cooldown")
            require(boundary.feedback(enabled: true, events: event.rawValue, at: 10 + interval) == event,
                    "Watch accepts every kind at its exact cooldown boundary")
            require(boundary.feedback(enabled: true, events: event.rawValue, at: 10 + interval) == nil,
                    "Watch cannot repeat feedback at a duplicate timestamp")
        }

        // Each gameplay kind must honor quiet time even when it has never fired
        // before. An independent per-kind timer cannot bypass this shared bound.
        for previous in [GameHapticEvent.menuSelection, .shot, .primaryShot, .explosion, .targetLock] {
            for next in [GameHapticEvent.shot, .primaryShot, .explosion, .targetLock, .damage] {
                var policy = WatchGameHapticPolicy()
                require(policy.feedback(enabled: true, events: previous.rawValue, at: 0) == previous,
                        "Watch starts a cross-event quiet-time test")
                require(policy.feedback(enabled: true, events: next.rawValue, at: 0.499999) == nil,
                        "Watch gameplay cannot interrupt any feedback within half a second")
                let ownInterval = previous == .shot ? 0.75 : previous == next ? (next == .primaryShot ? 1.0 :
                    next == .explosion ? 1.5 : 2.0) : 0.5
                require(policy.feedback(enabled: true, events: next.rawValue, at: 0.5) ==
                        (ownInterval > 0.5 ? nil : next),
                        "Watch exact shared boundary still respects per-kind and volley quiet time")
                if previous == .shot {
                    require(policy.feedback(enabled: true, events: next.rawValue, at: 0.75) == next,
                            "Watch fresh gameplay returns exactly after volley quiet time")
                }
            }
        }

        for previous in [GameHapticEvent.menuSelection, .primaryShot, .explosion, .targetLock] {
            var policy = WatchGameHapticPolicy()
            require(policy.feedback(enabled: true, events: previous.rawValue, at: 0) == previous,
                    "Watch begins a menu interruption test")
            require(policy.feedback(enabled: true, events: 8, at: 0.249999) == nil,
                    "Watch menu cannot interrupt any fresh pattern")
            require(policy.feedback(enabled: true, events: 8, at: 0.25) == .menuSelection,
                    "Watch menu responds at the quarter-second boundary after any pattern")
            require(policy.feedback(enabled: true, events: 4, at: 0.749999) == nil,
                    "Watch accepted menu resets gameplay quiet time")
            require(policy.feedback(enabled: true, events: 4, at: 0.75) == .damage,
                    "Watch gameplay returns half a second after a menu")
        }

        for previous in [GameHapticEvent.damage, .shot] {
            for next in [GameHapticEvent.menuSelection, .damage, .shot, .primaryShot, .explosion, .targetLock] {
                var policy = WatchGameHapticPolicy()
                require(policy.feedback(enabled: true, events: previous.rawValue, at: 0) == previous,
                        "Watch begins a protected health-loss or volley pattern")
                for timestamp in [0.249999, 0.25, 0.5, 0.749999] {
                    require(policy.feedback(enabled: true, events: next.rawValue, at: timestamp) == nil,
                            "Watch health loss and volleys reserve three quarters of a second before any next pattern")
                }
                require(policy.feedback(enabled: true, events: next.rawValue, at: 0.75) == next,
                        "Watch accepts a fresh event exactly after protected quiet time")
            }
        }

        var watchPreemption = WatchGameHapticPolicy()
        require(watchPreemption.feedback(enabled: true, events: 32, at: 0) == .primaryShot,
                "Watch begins with primary feedback")
        require(watchPreemption.feedback(enabled: true, events: 1, at: 0.01) == nil,
                "Watch targeted volley cannot immediately preempt a primary pattern")
        require(watchPreemption.feedback(enabled: true, events: 4, at: 0.1) == nil,
                "Watch damage cannot interrupt a just-started pattern")
        require(watchPreemption.feedback(enabled: true, events: 1, at: 0.5) == .shot,
                "Watch targeted volley becomes available after quiet time")
        require(watchPreemption.feedback(enabled: true, events: 32, at: 0.75) == nil,
                "Watch alternating weapons cannot bypass shared quiet time")

        var watchDisabled = WatchGameHapticPolicy()
        require(watchDisabled.feedback(enabled: false, events: 63, at: 0) == nil,
                "Watch OFF discards all event types")
        require(watchDisabled.feedback(enabled: true, events: 0, at: 0) == nil,
                "Watch empty masks produce no feedback")
        require(watchDisabled.feedback(enabled: true, events: 0x80, at: 0) == nil,
                "Watch unknown bits produce no feedback")
        require(watchDisabled.feedback(enabled: true, events: 8, at: 0) == .menuSelection,
                "Watch ON preview accepts a fresh menu event")
        for centisecond in 1..<25 {
            let timestamp = Double(centisecond) / 100
            require(watchDisabled.feedback(enabled: false, events: 8, at: timestamp) == nil,
                    "Watch OFF always discards events")
            require(watchDisabled.feedback(enabled: true, events: 8, at: timestamp) == nil,
                    "Watch OFF/ON cannot reset an emitted pattern's cooldown")
        }
        require(watchDisabled.feedback(enabled: false, events: 8, at: 100) == nil,
                "Watch disabled calls do not move its active timeline")
        require(watchDisabled.feedback(enabled: true, events: 8, at: 0.25) == .menuSelection,
                "Watch OFF/ON preserves the original exact boundary")

        var watchDiscarded = WatchGameHapticPolicy()
        require(watchDiscarded.feedback(enabled: true, events: 1, at: 0) == .shot,
                "Watch begins a no-queue test")
        require(watchDiscarded.feedback(enabled: true, events: 4, at: 0.1) == nil,
                "Watch drops blocked damage instead of deferring it")
        require(watchDiscarded.feedback(enabled: false, events: 8, at: 0.2) == nil,
                "Watch drops an OFF menu event")
        require(watchDiscarded.feedback(enabled: true, events: 0, at: 1) == nil,
                "Watch discarded events never replay on a later empty frame")
        require(watchDiscarded.feedback(enabled: true, events: 2, at: 1) == .targetLock,
                "Watch a fresh event does not inherit previously discarded higher-priority bits")

        var watchInvalid = WatchGameHapticPolicy()
        for timestamp in [Double.nan, .infinity, -.infinity] {
            require(watchInvalid.feedback(enabled: true, events: 63, at: timestamp) == nil,
                    "Watch rejects nonfinite timestamps")
        }
        require(watchInvalid.feedback(enabled: true, events: 32, at: 0) == .primaryShot,
                "Watch invalid timestamps do not corrupt a fresh policy")
        require(watchInvalid.feedback(enabled: true, events: 8, at: -1) == nil,
                "Watch backwards time cannot switch channels to bypass limits")
        require(watchInvalid.feedback(enabled: true, events: 32, at: 0.5) == nil,
                "Watch a valid suppressed event advances its monotonic observation")
        require(watchInvalid.feedback(enabled: true, events: 8, at: 0.25) == nil,
                "Watch rejects time behind a suppressed event too")
        require(watchInvalid.feedback(enabled: true, events: 32, at: 1) == .primaryShot,
                "Watch valid time still works after backwards rejection")

        var watchUptime = WatchGameHapticPolicy()
        require(watchUptime.feedback(enabled: true, events: 1, at: longUptime) == .shot,
                "Watch accepts large system uptime")
        require(watchUptime.feedback(enabled: true, events: 1, at: longUptime + 0.749999) == nil,
                "Watch large uptime preserves event cooldowns")
        require(watchUptime.feedback(enabled: true, events: 1, at: longUptime + 0.75) == .shot,
                "Watch large uptime accepts the exact boundary")

        for (event, interval) in [(GameHapticEvent.menuSelection, 0.25), (.shot, 0.75),
                                  (.primaryShot, 1.0), (.damage, 0.75), (.explosion, 1.5), (.targetLock, 2.0)] {
            var sustained = WatchGameHapticPolicy()
            var emitted = 0
            for frame in 0...600 {
                if sustained.feedback(enabled: true, events: event.rawValue, at: Double(frame) / 60) != nil {
                    emitted += 1
                }
            }
            require(emitted > 1 && emitted <= Int(10 / interval) + 1,
                    "Watch sustained 60 Hz event bursts respect each kind's bound")
        }

        for includeMenus in [false, true] {
            var mixed = WatchGameHapticPolicy()
            let events: [GameHapticEvent] = includeMenus ? [.menuSelection, .shot, .primaryShot, .explosion, .targetLock, .damage] :
                [.shot, .primaryShot, .explosion, .targetLock, .damage]
            var previous: (event: GameHapticEvent, time: TimeInterval)?
            var emitted = 0
            for frame in 0...3600 {
                let time = Double(frame) / 60
                let mask = events[frame % events.count].rawValue
                guard let event = mixed.feedback(enabled: true, events: mask, at: time) else { continue }
                emitted += 1
                if let previous {
                    let interval = previous.event == .damage || previous.event == .shot ? 0.75 :
                        event == .menuSelection ? 0.25 : 0.5
                    require(time - previous.time >= interval,
                            "Watch mixed 60 Hz bursts respect global and damage quiet times")
                }
                previous = (event, time)
            }
            require(emitted > 30 && emitted <= (includeMenus ? 241 : 121),
                    "Watch mixed events remain bounded over a full minute without starving all feedback")
        }

        print("PASS: \(checks) haptic policy checks (\(phoneChecks) unchanged iPhone, \(checks - phoneChecks) Watch); priority, quiet intervals, exact boundaries, sustained mixed bursts, OFF, no queue and monotonic time; no hardware feedback")
    }
}
