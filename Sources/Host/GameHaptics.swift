//
//  GameHaptics.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum GameHapticEvent: UInt {
    /// Original lock-on laser release with at least one valid target.
    case shot = 1
    case targetLock = 2
    case damage = 4

    var intensity: Double {
        switch self {
        case .damage: 0.25
        case .shot: 0.15
        case .targetLock: 0.10
        }
    }
}

/// Coalesce one frame's events and rate-limit all event kinds together. Rejected
/// events are discarded, so a menu, cooldown or OFF never delays a later impact.
struct GameHapticPolicy {
    static let minimumInterval: TimeInterval = 0.25
    private var lastFeedbackTime: TimeInterval?

    mutating func feedback(enabled: Bool, events: UInt, at time: TimeInterval) -> GameHapticEvent? {
        guard enabled, time.isFinite else { return nil }
        let event: GameHapticEvent
        if events & GameHapticEvent.damage.rawValue != 0 { event = .damage }
        else if events & GameHapticEvent.shot.rawValue != 0 { event = .shot }
        else if events & GameHapticEvent.targetLock.rawValue != 0 { event = .targetLock }
        else { return nil }
        if let lastFeedbackTime, time - lastFeedbackTime < Self.minimumInterval { return nil }
        lastFeedbackTime = time
        return event
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
    private let generator: UIImpactFeedbackGenerator?
    private var policy = GameHapticPolicy()
    private var isEnabled = false

    init() {
        generator = Self.offersHaptics ? UIImpactFeedbackGenerator(style: .soft) : nil
    }

    func update(enabled: Bool, events: UInt) {
        guard enabled, let generator else {
            reset()
            return
        }
        if !isEnabled {
            isEnabled = true
            generator.prepare()
        }
        guard events != 0, let event = policy.feedback(enabled: true, events: events,
            at: ProcessInfo.processInfo.systemUptime) else { return }
        generator.impactOccurred(intensity: CGFloat(event.intensity))
        generator.prepare()
    }

    func reset() {
        isEnabled = false
        // Keep the last-impact timestamp: pause or preference toggles must not
        // bypass the global cooldown. There are no queued events to replay.
    }
    #else
    func update(enabled: Bool, events: UInt) {}
    func reset() {}
    #endif
}
