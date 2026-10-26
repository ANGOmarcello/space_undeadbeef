//
//  GameHaptics.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation
#if os(iOS)
import UIKit
import CoreHaptics
#endif

enum GameHapticEvent: UInt {
    case shot = 1
    case targetLock = 2
    case damage = 4
    case menuSelection = 8
    case explosion = 16
    case primaryShot = 32

    var intensity: Double {
        switch self {
        case .damage: 1.0
        case .shot: 0.85
        case .primaryShot: 0.70
        case .explosion: 0.65
        case .targetLock: 0.35
        case .menuSelection: 1.0
        }
    }

    var name: String {
        switch self {
        case .shot: "weaponRelease"
        case .primaryShot: "primaryShot"
        case .targetLock: "targetLock"
        case .damage: "damage"
        case .menuSelection: "menuSelection"
        case .explosion: "explosion"
        }
    }
}

/// One event per update, without a deferred queue. Low-priority target/explosion
/// feedback never consumes the weapon budget; stronger events can replace it.
struct GameHapticPolicy {
    static let minimumInterval: TimeInterval = 0.25
    static let primaryInterval: TimeInterval = 0.50
    static let damageInterval: TimeInterval = 0.35
    static let targetInterval: TimeInterval = 1.0
    static let menuInterval: TimeInterval = 0.12

    private var lastObservedTime: TimeInterval?
    private var lastWeaponTime: TimeInterval?
    private var lastWeaponEvent: GameHapticEvent?
    private var lastVolleyTime: TimeInterval?
    private var lastDamageTime: TimeInterval?
    private var lastTargetTime: TimeInterval?
    private var lastExplosionTime: TimeInterval?
    private var lastGameplayTime: TimeInterval?
    private var lastMenuTime: TimeInterval?

    mutating func feedback(enabled: Bool, events: UInt, at time: TimeInterval) -> GameHapticEvent? {
        guard enabled, time.isFinite, events & 63 != 0 else { return nil }
        if let lastObservedTime, time < lastObservedTime { return nil }
        lastObservedTime = time

        if events & GameHapticEvent.menuSelection.rawValue != 0,
           ready(lastMenuTime, interval: Self.menuInterval, at: time) {
            lastMenuTime = time
            return .menuSelection
        }
        if events & GameHapticEvent.damage.rawValue != 0,
           ready(lastDamageTime, interval: Self.damageInterval, at: time) {
            lastDamageTime = time
            lastWeaponTime = time
            lastWeaponEvent = .damage
            lastGameplayTime = time
            return .damage
        }
        // A targeted volley may replace a recent weaker primary pulse. Its own
        // quarter-second budget still bounds repeated rocket/laser releases.
        if events & GameHapticEvent.shot.rawValue != 0,
           ready(lastVolleyTime, interval: Self.minimumInterval, at: time),
           ready(lastWeaponTime, interval: Self.minimumInterval, at: time) || lastWeaponEvent == .primaryShot {
            lastVolleyTime = time
            lastWeaponTime = time
            lastWeaponEvent = .shot
            lastGameplayTime = time
            return .shot
        }
        if events & GameHapticEvent.primaryShot.rawValue != 0,
           ready(lastWeaponTime, interval: Self.primaryInterval, at: time) {
            lastWeaponTime = time
            lastWeaponEvent = .primaryShot
            lastGameplayTime = time
            return .primaryShot
        }
        if events & GameHapticEvent.explosion.rawValue != 0,
           ready(lastExplosionTime, interval: Self.minimumInterval, at: time),
           ready(lastGameplayTime, interval: Self.minimumInterval, at: time) {
            lastExplosionTime = time
            lastGameplayTime = time
            return .explosion
        }
        if events & GameHapticEvent.targetLock.rawValue != 0,
           ready(lastTargetTime, interval: Self.targetInterval, at: time),
           ready(lastGameplayTime, interval: Self.minimumInterval, at: time) {
            lastTargetTime = time
            lastGameplayTime = time
            return .targetLock
        }
        return nil
    }

    private func ready(_ previous: TimeInterval?, interval: TimeInterval, at time: TimeInterval) -> Bool {
        guard let previous else { return true }
        return time - previous >= interval
    }
}

@MainActor
final class GameHaptics {
    static var offersHaptics: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    #if os(iOS)
    private weak var view: UIView?
    private var selection: UISelectionFeedbackGenerator?
    private var lightImpact: UIImpactFeedbackGenerator?
    private var mediumImpact: UIImpactFeedbackGenerator?
    private var policy = GameHapticPolicy()
    private var isEnabled = false
    private let logsEnabled = ProcessInfo.processInfo.environment["SDB_HAPTICS_LOG"] == "1"
    private var lastStatus: String?
    private var lastRateLimitLog: TimeInterval?

    init() {
        if logsEnabled {
            NSLog("SDB_HAPTICS hardware phone=%d supportsHaptics=%d",
                  Self.offersHaptics, CHHapticEngine.capabilitiesForHardware().supportsHaptics)
        }
    }

    func attach(to view: UIView) {
        guard Self.offersHaptics else { return }
        guard self.view !== view else { return }
        if let previous = self.view { detach(from: previous) }
        self.view = view
        // These initializers attach each generator as an interaction on the
        // actual visible game view. Retain them until that view is dismantled.
        selection = UISelectionFeedbackGenerator(view: view)
        lightImpact = UIImpactFeedbackGenerator(style: .light, view: view)
        mediumImpact = UIImpactFeedbackGenerator(style: .medium, view: view)
        isEnabled = false
        lastStatus = nil
        if logsEnabled { NSLog("SDB_HAPTICS attach inWindow=%d", view.window != nil) }
    }

    func detach(from view: UIView) {
        guard self.view === view else { return }
        if let selection { view.removeInteraction(selection) }
        if let lightImpact { view.removeInteraction(lightImpact) }
        if let mediumImpact { view.removeInteraction(mediumImpact) }
        selection = nil
        lightImpact = nil
        mediumImpact = nil
        self.view = nil
        reset()
        lastStatus = nil
        if logsEnabled { NSLog("SDB_HAPTICS detach") }
    }

    func update(enabled: Bool, events: UInt) {
        let attached = view != nil
        let inWindow = view?.window != nil
        let status = !Self.offersHaptics ? "unsupported" : !enabled ? "disabled" :
            !attached ? "detached" : !inWindow ? "offscreen" : "ready"
        if logsEnabled, status != lastStatus {
            NSLog("SDB_HAPTICS state=%@ enabled=%d attached=%d inWindow=%d events=%lu",
                  status, enabled, attached, inWindow, events)
        }
        lastStatus = status
        guard status == "ready", let selection, let lightImpact, let mediumImpact else {
            reset()
            return
        }
        if !isEnabled {
            isEnabled = true
            selection.prepare()
            lightImpact.prepare()
            mediumImpact.prepare()
        }
        guard events & 63 != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let event = policy.feedback(enabled: true, events: events, at: now) else {
            if logsEnabled {
                let logDue = lastRateLimitLog.map { now - $0 >= 1 } ?? true
                if logDue {
                    NSLog("SDB_HAPTICS rateLimited events=%lu enabled=%d attached=%d inWindow=%d",
                          events, enabled, attached, inWindow)
                    lastRateLimitLog = now
                }
            }
            return
        }
        let nativeCall: String
        switch event {
        case .menuSelection:
            selection.selectionChanged()
            selection.prepare()
            nativeCall = "selectionChanged"
        case .targetLock, .primaryShot:
            lightImpact.impactOccurred(intensity: CGFloat(event.intensity))
            lightImpact.prepare()
            nativeCall = "lightImpact"
        case .shot, .damage, .explosion:
            mediumImpact.impactOccurred(intensity: CGFloat(event.intensity))
            mediumImpact.prepare()
            nativeCall = "mediumImpact"
        }
        if logsEnabled {
            NSLog("SDB_HAPTICS request event=%@ nativeCall=%@ intensity=%.2f events=%lu enabled=%d attached=%d inWindow=%d",
                  event.name, nativeCall, event.intensity, events, enabled, attached, inWindow)
        }
    }

    func reset() {
        isEnabled = false
        // Retain cooldown timestamps across OFF/pause/view changes, with no
        // queued feedback to replay when the game becomes active again.
    }
    #else
    func update(enabled: Bool, events: UInt) {}
    func reset() {}
    #endif
}
