//
//  GameInputController.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

import CoreGraphics
import Foundation
#if !os(watchOS) && !SDB_NATIVE_POLICY_TEST
import GameController
#endif

enum GameInputKey: Hashable {
    case left, right, up, down, fire
}

struct GameControllerSample {
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero
    var dpad = CGPoint.zero
    var fire = false
    var pause = false
}

struct GameInputFrame {
    var pointerDelta = CGPoint.zero
    var steeringDelta = 0.0
    var firePressed = false
    var fireReleased = false
    var pausePressed = false
}

/// Event edges and time-based movement are independent of display refresh and
/// keyboard repeat. Controller axes use the standard positive-up convention.
struct GameInputPolicy {
    static let stickDeadZone = 0.18
    static let pointerWidthsPerSecond = 1.0
    static let shipRangesPerSecond = 1.0
    /// Bound malformed callers to four ordinary simulation steps.
    static let maximumTick = 4.0 / 60.0

    private var keys: Set<GameInputKey> = []
    private var wasFiring = false
    private var wasPausing = false
    private var waitsForControllerFireRelease = true
    private var waitsForControllerPauseRelease = true

    mutating func setKey(_ key: GameInputKey, pressed: Bool) {
        if pressed { keys.insert(key) } else { keys.remove(key) }
    }

    mutating func reset() {
        keys.removeAll(keepingCapacity: true)
        wasFiring = false
        wasPausing = false
        waitsForControllerFireRelease = true
        waitsForControllerPauseRelease = true
    }

    static func stick(_ point: CGPoint) -> CGPoint {
        let x = Double(point.x), y = Double(point.y)
        guard x.isFinite, y.isFinite else { return .zero }
        let magnitude = hypot(x, y)
        guard magnitude > stickDeadZone else { return .zero }
        let scale = (min(1, magnitude) - stickDeadZone) / (1 - stickDeadZone) / magnitude
        return CGPoint(x: x * scale, y: y * scale)
    }

    mutating func frame(delta: TimeInterval, pointerUnitsPerSecond: Double,
                        sample: GameControllerSample, inMenu: Bool) -> GameInputFrame {
        if !sample.fire { waitsForControllerFireRelease = false }
        if !sample.pause { waitsForControllerPauseRelease = false }
        let firing = keys.contains(.fire) || (sample.fire && !waitsForControllerFireRelease)
        let pausing = sample.pause && !waitsForControllerPauseRelease
        var result = GameInputFrame(firePressed: firing && !wasFiring,
                                    fireReleased: !firing && wasFiring,
                                    pausePressed: pausing && !wasPausing)
        wasFiring = firing
        wasPausing = pausing
        guard delta.isFinite, delta > 0, pointerUnitsPerSecond.isFinite,
              pointerUnitsPerSecond >= 0 else { return result }
        let dt = min(delta, Self.maximumTick)
        let left = Self.stick(sample.leftStick), right = Self.stick(sample.rightStick)
        let pad = Self.stick(sample.dpad)
        // In menus either stick can address the original buttons. During play,
        // left-stick vertical movement owns the original ship spring instead.
        let target = right != .zero ? right : inMenu ? left : .zero
        var x = Double(target.x + pad.x) + (keys.contains(.right) ? 1 : 0) - (keys.contains(.left) ? 1 : 0)
        var y = -Double(target.y + pad.y) + (keys.contains(.down) ? 1 : 0) - (keys.contains(.up) ? 1 : 0)
        let magnitude = hypot(x, y)
        if magnitude > 1 { x /= magnitude; y /= magnitude }
        let distance = pointerUnitsPerSecond * Self.pointerWidthsPerSecond * dt
        result.pointerDelta = CGPoint(x: x * distance, y: y * distance)
        if !inMenu { result.steeringDelta = -Double(left.y) * Self.shipRangesPerSecond * dt }
        return result
    }
}

#if !SDB_NATIVE_POLICY_TEST
@MainActor
final class GameInputController {
    private weak var session: GameSession?
    private var policy = GameInputPolicy()
    private var active = false
    private var ownsTouch = false
    private var ownsSteering = false
    private var steeringTarget: Double?
    #if !os(watchOS)
    // Isolated smoke/UI tests must not inspect or take over a real controller.
    private static let allowsHardwareControllers = {
        let environment = ProcessInfo.processInfo.environment
        return environment["SDB_SAVE_DIRECTORY"] == nil && environment["SDB_UI_TEST"] == nil
    }()
    private enum ResumeButton: Hashable, Sendable { case primary, trigger, menu }
    private var controller: GCController?
    private let observers = GameControllerObservers()
    private var controllerGeneration = 0
    private var resumeReady: Set<ResumeButton> = []
    #endif

    init(session: GameSession) {
        self.session = session
        #if !os(watchOS)
        if Self.allowsHardwareControllers {
            for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
                observers.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshController() }
                })
            }
            // Keep explicit resume buttons available even if a media-reset
            // gate prevents the simulation from becoming active at launch.
            refreshController()
        }
        #endif
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        resetHeldInputs()
        #if !os(watchOS)
        if active { refreshController() }
        else { installResumeHandlers() }
        #endif
    }

    func setKey(_ key: GameInputKey, pressed: Bool) {
        guard !pressed || (active && session?.persistenceError == nil) else { return }
        policy.setKey(key, pressed: pressed)
    }

    /// Used by interruption/focus handlers and before a direct touch. Releasing
    /// ownership cancels a charge; it must never fire a volley or end a finger.
    func resetHeldInputs() {
        policy.reset()
        if ownsTouch { session?.cancelTouch() }
        ownsTouch = false
        endSteering()
    }

    @discardableResult
    func pause() -> Bool {
        guard active, let session, session.canPause else { return false }
        resetHeldInputs()
        session.pauseGame()
        return true
    }

    /// Root calls this once per original fixed simulation step, before update.
    func tick(_ delta: TimeInterval) {
        tick(delta, sample: controllerSample())
    }

    /// An explicit sample shares the production input path without reading a
    /// controller, allowing isolated transport and lifecycle verification.
    func tick(_ delta: TimeInterval, sample: GameControllerSample) {
        guard active, let session, session.isActive, session.failure == nil else { return }
        guard session.persistenceError == nil else { resetHeldInputs(); return }
        let frame = policy.frame(delta: delta, pointerUnitsPerSecond: Double(GameLayout.width),
                                 sample: sample, inMenu: session.gameMenuType != 0)
        if frame.pausePressed, pause() { return }
        if frame.fireReleased, ownsTouch {
            session.endTouch()
            ownsTouch = false
        }
        // A finger keeps ownership until its own drag ends. Button edges are
        // consumed rather than queued for a surprise charge after finger lift.
        guard !session.isTouching || ownsTouch else { endSteering(); return }
        if frame.pointerDelta != .zero {
            session.movePointer(dx: frame.pointerDelta.x, dy: frame.pointerDelta.y)
        }
        if frame.firePressed, !session.isTouching {
            endSteering()
            session.beginPointerTouch()
            ownsTouch = true
        }
        guard !session.isTouching, session.canPause, let engine = session.engine,
              engine.canSteerShip, frame.steeringDelta != 0 else { endSteering(); return }
        let actual = engine.shipNormalizedY
        guard actual.isFinite else { endSteering(); return }
        let target = min(1, max(0, (steeringTarget ?? actual) + frame.steeringDelta))
        steeringTarget = target
        engine.steerShip(toNormalizedY: target)
        ownsSteering = true
    }

    private func endSteering() {
        if ownsSteering { session?.engine?.cancelShipSteering() }
        ownsSteering = false
        steeringTarget = nil
    }

    private func controllerSample() -> GameControllerSample {
        #if !os(watchOS)
        guard let pad = controller?.extendedGamepad else { return GameControllerSample() }
        return GameControllerSample(
            leftStick: CGPoint(x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value)),
            rightStick: CGPoint(x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value)),
            dpad: CGPoint(x: Double(pad.dpad.xAxis.value), y: Double(pad.dpad.yAxis.value)),
            fire: pad.buttonA.isPressed || pad.rightTrigger.isPressed, pause: pad.buttonMenu.isPressed)
        #else
        return GameControllerSample()
        #endif
    }

    #if !os(watchOS)
    private func refreshController() {
        guard Self.allowsHardwareControllers else { return }
        let connected = GCController.controllers()
        if let controller, connected.contains(where: { $0 === controller }) { return }
        // A disconnected idle controller must not pause somebody who has
        // already switched to a finger. Pause only an owned active gesture.
        let interrupted = controller != nil && (ownsTouch || ownsSteering)
        resetHeldInputs()
        detachResumeHandlers()
        controller = connected.first(where: { $0.extendedGamepad != nil })
        installResumeHandlers()
        if interrupted, active { _ = pause() }
    }

    private func detachResumeHandlers() {
        controllerGeneration &+= 1
        resumeReady.removeAll(keepingCapacity: true)
        for button in observers.buttons { button.pressedChangedHandler = nil }
        observers.buttons.removeAll(keepingCapacity: true)
    }

    private func installResumeHandlers() {
        detachResumeHandlers()
        guard Self.allowsHardwareControllers, let pad = controller?.extendedGamepad else { return }
        let generation = controllerGeneration
        let buttons: [(ResumeButton, GCControllerButtonInput)] = [
            (.primary, pad.buttonA), (.trigger, pad.rightTrigger), (.menu, pad.buttonMenu)
        ]
        for (name, button) in buttons {
            if !button.isPressed { resumeReady.insert(name) }
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor [weak self] in
                    self?.resumeButton(name, pressed: pressed, generation: generation)
                }
            }
            observers.buttons.append(button)
        }
    }

    private func resumeButton(_ button: ResumeButton, pressed: Bool, generation: Int) {
        guard generation == controllerGeneration, controller != nil else { return }
        if !pressed { resumeReady.insert(button); return }
        guard resumeReady.remove(button) != nil else { return }
        // Media recovery can suspend simulation, so tick cannot observe this
        // explicit user input. Axes never resume. The press only resumes; normal
        // policy still requires its release before another charge or pause.
        if !active { _ = session?.requestUserResume() }
    }
    #endif
}

#if !os(watchOS)
/// Tokens remove themselves without accessing actor state during deinit.
private final class GameControllerObservers {
    var tokens: [NSObjectProtocol] = []
    var buttons: [GCControllerButtonInput] = []
    deinit {
        for button in buttons { button.pressedChangedHandler = nil }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
#endif
#endif
