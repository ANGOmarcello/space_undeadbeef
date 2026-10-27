//
//  GameLifecycle.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

import Foundation
#if os(macOS)
import AppKit
#else
import AVFAudio
#endif

enum GameSceneActivity: Equatable, Sendable {
    case active, inactive, background
}

enum GameLifecycleEvent: Equatable, Sendable {
    case scene(GameSceneActivity)
    case application(Bool)
    case audioInterrupted
    case audioEnded(shouldResume: Bool)
    case audioActivationSucceeded
    case routeDisconnected
    case mediaServicesLost
    case mediaServicesReset
    case userInteraction
    case memoryPressure
    case wake
}

/// A suspension begin describes deactivation that already happened while the
/// process could not run. It is not an ongoing competing-session interruption.
enum GameAudioInterruptionPolicy {
    // AVAudioSessionInterruptionReasonAppWasSuspended's documented wire value.
    // Apple stopped sending it in iOS16; retain decoding for delayed/legacy data.
    private static let delayedSuspensionReason: UInt = 1

    static func began(reason: UInt?, wasSuspended: Bool = false) -> GameLifecycleEvent? {
        if let reason {
            // The current reason supersedes the obsolete wasSuspended key.
            return reason == delayedSuspensionReason ? nil : .audioInterrupted
        }
        return wasSuspended ? nil : .audioInterrupted
    }
}

/// Independent gates keep a foreground notification from resuming an ongoing
/// interruption. Resuming scheduling never dismisses the original pause menu.
struct GameLifecyclePolicy {
    #if os(iOS)
    private static let defaultPausesInactiveScene = false
    #else
    private static let defaultPausesInactiveScene = true
    #endif
    private let pausesInactiveScene: Bool
    private(set) var sceneActivity: GameSceneActivity = .background
    private(set) var applicationActive = true
    private(set) var audioInterrupted = false
    private(set) var mediaServicesLost = false
    private(set) var needsAudioRebuild = false
    private(set) var requiresUserResume = false

    init(pausesInactiveScene: Bool = Self.defaultPausesInactiveScene) {
        self.pausesInactiveScene = pausesInactiveScene
    }

    var sceneActive: Bool { sceneActivity == .active }
    var sceneAllowsScheduling: Bool { sceneActive || (sceneActivity == .inactive && !pausesInactiveScene) }
    var sceneAllowsInteraction: Bool { sceneActive }
    var canAnimatePausedMenu: Bool { sceneAllowsScheduling && applicationActive }
    var canAttemptUserResume: Bool { sceneAllowsInteraction && applicationActive && !mediaServicesLost }
    var canAcceptUserResume: Bool { canAttemptUserResume && !audioInterrupted }
    var shouldRun: Bool {
        canAnimatePausedMenu && !audioInterrupted && !mediaServicesLost && !requiresUserResume && !needsAudioRebuild
    }

    func requestsOriginalPause(for event: GameLifecycleEvent) -> Bool {
        switch event {
        case .scene(.background), .application(false), .audioInterrupted,
             .routeDisconnected, .mediaServicesLost, .mediaServicesReset: true
        case .scene(.inactive): pausesInactiveScene
        default: false
        }
    }

    mutating func handle(_ event: GameLifecycleEvent) {
        switch event {
        case .scene(let activity): sceneActivity = activity
        case .application(let active): applicationActive = active
        case .audioInterrupted: audioInterrupted = true
        case .audioEnded(let shouldResume):
            // Recommendations without a tracked interruption must not stop a
            // running game or cancel an independent explicit-resume gate.
            guard audioInterrupted else { return }
            audioInterrupted = false
            requiresUserResume = requiresUserResume || !shouldResume
        case .audioActivationSucceeded:
            // A user-requested activation approved by the OS can recover a
            // stale begin whose matching end was never delivered. Graph repair
            // remains independent; a failed activation must not send this event.
            guard canAttemptUserResume else { return }
            audioInterrupted = false
            requiresUserResume = false
        case .routeDisconnected:
            // The original Pause/Continue menu is the explicit resume action.
            break
        case .mediaServicesLost:
            mediaServicesLost = true
            needsAudioRebuild = true
            requiresUserResume = true
        case .mediaServicesReset:
            mediaServicesLost = false
            audioInterrupted = false
            needsAudioRebuild = true
            requiresUserResume = true
        case .userInteraction:
            if canAcceptUserResume { requiresUserResume = false }
        case .memoryPressure, .wake: break
        }
    }

    mutating func audioRebuilt() { needsAudioRebuild = false }
}

private final class GameNotificationTokens: @unchecked Sendable {
    var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    var memoryPressure: (any DispatchSourceMemoryPressure)?
    deinit {
        memoryPressure?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
    }
}

/// Observes only this app's lifecycle. Tests may drive the policy directly;
/// no system settings or global media-service reset is used for verification.
@MainActor
final class GameInterruptionMonitor {
    private let observations = GameNotificationTokens()
    private let receive: @MainActor (GameLifecycleEvent) -> Void
    private var started = false

    init(receive: @escaping @MainActor (GameLifecycleEvent) -> Void) { self.receive = receive }

    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app" else { return }
        started = true
        // Watch and Mac have no UIApplication memory-warning notification.
        // Dispatch supplies the same bounded cache/checkpoint path everywhere.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.receive(.memoryPressure) }
        }
        observations.memoryPressure = pressure
        pressure.activate()
        #if os(macOS)
        observe(NSApplication.didResignActiveNotification) { _ in .application(false) }
        observe(NSApplication.didBecomeActiveNotification) { _ in .application(true) }
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { _ in .application(false) }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { _ in .wake }
        #else
        observe(AVAudioSession.interruptionNotification) { note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                #if os(iOS) || os(watchOS)
                let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
                return GameAudioInterruptionPolicy.began(reason: reason)
                #else
                return .audioInterrupted
                #endif
            }
            guard type == AVAudioSession.InterruptionType.ended.rawValue else { return nil }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            return .audioEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        }
        observe(AVAudioSession.routeChangeNotification) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            return reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ? .routeDisconnected : nil
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in .mediaServicesLost }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesReset }
        #endif
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         event: @escaping @Sendable (Notification) -> GameLifecycleEvent?) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard let value = event(note) else { return }
            // These notifications are delivered on the requested main queue.
            MainActor.assumeIsolated {
                #if os(macOS)
                if case .wake = value { self?.receive(.application(NSApplication.shared.isActive)) }
                else { self?.receive(value) }
                #else
                self?.receive(value)
                #endif
            }
        }
        observations.tokens.append((center, token))
    }
}
