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
#elseif os(watchOS)
import WatchKit
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

/// Match iPhone event coverage, timing and priority. Watch uses short system
/// clicks for frequent effects, without extra platform-specific quiet windows.
/// WatchKit may interrupt overlapping patterns; requests are never queued here.
typealias WatchGameHapticPolicy = GameHapticPolicy

/// The most recent native host owns attachment. A dismantled older host must
/// not remove a replacement host's generators, even in the same window.
struct GameHapticAttachmentPolicy {
    private(set) var owner: ObjectIdentifier?
    private(set) var target: ObjectIdentifier?
    private(set) var needsRebuild = true
    private(set) var generation = 0

    mutating func bind(owner: AnyObject, target: AnyObject) {
        let nextTarget = ObjectIdentifier(target)
        if self.target != nextTarget { needsRebuild = true }
        self.owner = ObjectIdentifier(owner)
        self.target = nextTarget
    }

    mutating func unbind(owner: AnyObject) -> Bool {
        guard self.owner == ObjectIdentifier(owner) else { return false }
        clear()
        return true
    }

    mutating func clear() {
        owner = nil
        target = nil
        needsRebuild = true
    }

    mutating func invalidate() { needsRebuild = true }

    func shouldRebuild(interactionsAttached: Bool) -> Bool {
        owner != nil && target != nil && (needsRebuild || !interactionsAttached)
    }

    mutating func didRebuild() {
        guard owner != nil, target != nil else { return }
        needsRebuild = false
        generation += 1
    }
}

@MainActor
final class GameHaptics {
    static var offersHaptics: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #elseif os(watchOS)
        true
        #else
        false
        #endif
    }

    #if os(iOS)
    private weak var window: UIWindow?
    private weak var owner: AnyObject?
    private var attachment = GameHapticAttachmentPolicy()
    private var selection: UISelectionFeedbackGenerator?
    private var lightImpact: UIImpactFeedbackGenerator?
    private var mediumImpact: UIImpactFeedbackGenerator?
    private var policy = GameHapticPolicy()
    private var isEnabled = false
    private let logsEnabled = ProcessInfo.processInfo.environment["SDB_HAPTICS_LOG"] == "1"
    private var lastStatus: String?
    private var lastRateLimitLog: TimeInterval?
    private(set) var deliveryStatus = "detached"
    var attachmentGeneration: Int { attachment.generation }

    init() {
        if logsEnabled {
            NSLog("SDB_HAPTICS hardware phone=%d supportsHaptics=%d",
                  Self.offersHaptics, CHHapticEngine.capabilitiesForHardware().supportsHaptics)
        }
    }

    func attach(to view: UIView) {
        attach(to: view, owner: view)
    }

    func attach(to view: UIView, owner: AnyObject) {
        guard Self.offersHaptics else { return }
        // UIKit's view-associated generators are UIInteractions. Bind them to
        // the actual app window, independently of rendering/hit-test surfaces.
        guard let window = (view as? UIWindow) ?? view.window else { return }
        let changesWindow = self.window !== window
        attachment.bind(owner: owner, target: window)
        self.owner = owner
        self.window = window
        if changesWindow {
            removeGenerators()
            isEnabled = false
            deliveryStatus = "attached"
        }
        // SwiftUI can rebind this sentinel after every observed state change.
        // Rebuild only in an eligible update, so OFF/inactive invalidation does
        // not become an attach/disabled feedback loop or recreate idle hardware.
    }

    func detach(from view: UIView) {
        detach(owner: view)
    }

    func detach(owner: AnyObject) {
        guard attachment.unbind(owner: owner) else { return }
        releaseAttachment()
    }

    private func removeGenerators() {
        if let selection { selection.view?.removeInteraction(selection) }
        if let lightImpact { lightImpact.view?.removeInteraction(lightImpact) }
        if let mediumImpact { mediumImpact.view?.removeInteraction(mediumImpact) }
        selection = nil
        lightImpact = nil
        mediumImpact = nil
    }

    private func releaseAttachment() {
        removeGenerators()
        owner = nil
        window = nil
        attachment.clear()
        isEnabled = false
        deliveryStatus = "detached"
        lastStatus = nil
        if logsEnabled { NSLog("SDB_HAPTICS detach") }
    }

    private func interactionsAttached(to window: UIWindow) -> Bool {
        selection?.view === window && lightImpact?.view === window && mediumImpact?.view === window
    }

    private func rebuildGenerators(in window: UIWindow) {
        removeGenerators()
        selection = UISelectionFeedbackGenerator(view: window)
        lightImpact = UIImpactFeedbackGenerator(style: .light, view: window)
        mediumImpact = UIImpactFeedbackGenerator(style: .medium, view: window)
        attachment.didRebuild()
        isEnabled = false
        deliveryStatus = "attached"
        lastStatus = nil
        if logsEnabled { NSLog("SDB_HAPTICS attach target=window generation=%ld", attachment.generation) }
    }

    func update(enabled: Bool, events: UInt) {
        if owner == nil, window != nil { releaseAttachment() }
        let attached = owner != nil && window != nil
        let inWindow = window.map { !$0.isHidden && $0.windowScene != nil } ?? false
        let active = window?.windowScene?.activationState == .foregroundActive
        let status = !Self.offersHaptics ? "unsupported" : !enabled ? "disabled" :
            !attached ? "detached" : !inWindow ? "offscreen" : !active ? "inactive" : "ready"
        deliveryStatus = status
        if logsEnabled, status != lastStatus {
            NSLog("SDB_HAPTICS state=%@ enabled=%d attached=%d inWindow=%d events=%lu",
                  status, enabled, attached, inWindow, events)
        }
        lastStatus = status
        guard status == "ready", let window else {
            reset()
            deliveryStatus = status
            return
        }
        if attachment.shouldRebuild(interactionsAttached: interactionsAttached(to: window)) {
            rebuildGenerators(in: window)
            deliveryStatus = status
        }
        guard let selection, let lightImpact, let mediumImpact else { return }
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
        let location = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        switch event {
        case .menuSelection:
            selection.selectionChanged(at: location)
            selection.prepare()
            nativeCall = "selectionChanged"
        case .targetLock, .primaryShot:
            lightImpact.impactOccurred(intensity: CGFloat(event.intensity), at: location)
            lightImpact.prepare()
            nativeCall = "lightImpact"
        case .shot, .damage, .explosion:
            mediumImpact.impactOccurred(intensity: CGFloat(event.intensity), at: location)
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
        deliveryStatus = "inactive"
        // UIKit can discard native feedback state during a scene/audio reset.
        // Recreate the view-associated interactions at the next eligible update.
        attachment.invalidate()
        // Retain cooldown timestamps across OFF/pause/view changes, with no
        // queued feedback to replay when the game becomes active again.
    }
    #elseif os(watchOS)
    private var policy = WatchGameHapticPolicy()
    private let logsEnabled = ProcessInfo.processInfo.environment["SDB_HAPTICS_LOG"] == "1"
    private var lastStatus: String?
    private var lastRateLimitLog: TimeInterval?

    func update(enabled: Bool, events: UInt) {
        let active = WKApplication.shared().applicationState == .active
        let status = !enabled ? "disabled" : !active ? "inactive" : "ready"
        if logsEnabled, status != lastStatus {
            NSLog("SDB_HAPTICS state=%@ platform=watch enabled=%d active=%d events=%lu",
                  status, enabled, active, events)
        }
        lastStatus = status
        guard enabled, active, events & 63 != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let event = policy.feedback(enabled: true, events: events, at: now) else {
            if logsEnabled, lastRateLimitLog.map({ now - $0 >= 1 }) ?? true {
                NSLog("SDB_HAPTICS rateLimited platform=watch events=%lu", events)
                lastRateLimitLog = now
            }
            return
        }
        let pattern: WKHapticType
        let nativeCall: String
        switch event {
        case .damage:
            pattern = .directionDown
            nativeCall = "play.directionDown"
        case .menuSelection, .shot, .primaryShot, .targetLock, .explosion:
            pattern = .click
            nativeCall = "play.click"
        }
        WKInterfaceDevice.current().play(pattern)
        if logsEnabled {
            NSLog("SDB_HAPTICS request event=%@ nativeCall=%@ platform=watch events=%lu",
                  event.name, nativeCall, events)
        }
    }

    func reset() {
        // No pending feedback. Preserve quiet intervals across OFF/pause and
        // inactive transitions so reactivation cannot produce a burst.
    }
    #else
    func update(enabled: Bool, events: UInt) {}
    func reset() {}
    #endif
}
