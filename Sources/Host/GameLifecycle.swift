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

enum GameLifecycleEvent: Sendable {
    case scene(Bool)
    case application(Bool)
    case audioInterrupted
    case audioEnded(shouldResume: Bool)
    case routeDisconnected
    case mediaServicesLost
    case mediaServicesReset
    case userInteraction
    case memoryPressure
    case wake
}

/// Independent gates keep a foreground notification from resuming an ongoing
/// interruption. Resuming scheduling never dismisses the original pause menu.
struct GameLifecyclePolicy {
    private(set) var sceneActive = false
    private(set) var applicationActive = true
    private(set) var audioInterrupted = false
    private(set) var mediaServicesLost = false
    private(set) var needsAudioRebuild = false
    private(set) var requiresUserResume = false

    var canAcceptUserResume: Bool { sceneActive && applicationActive && !audioInterrupted && !mediaServicesLost }
    var shouldRun: Bool { canAcceptUserResume && !requiresUserResume && !needsAudioRebuild }

    mutating func handle(_ event: GameLifecycleEvent) {
        switch event {
        case .scene(let active): sceneActive = active
        case .application(let active): applicationActive = active
        case .audioInterrupted: audioInterrupted = true
        case .audioEnded(let shouldResume):
            audioInterrupted = false
            requiresUserResume = !shouldResume
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
            if type == AVAudioSession.InterruptionType.began.rawValue { return .audioInterrupted }
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
