//
//  GameSession.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

import CoreGraphics
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

enum GameLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 320
    static let size = CGSize(width: width, height: height)
    static let simulationStep = GameFrameClock.simulationStep
    static let pointerStep = width / 24
    static let pointerDiameter = height / 40
    static let pointerStroke = pointerDiameter / 4
    static let cornerControlSide: CGFloat = 24

    static func fittedSize(in available: CGSize) -> CGSize {
        let scale = max(0, min(available.width / width, available.height / height))
        return CGSize(width: width * scale, height: height * scale)
    }

    static func point(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(width, max(0, location.x / max(size.width, 1) * width)),
            y: min(height, max(0, location.y / max(size.height, 1) * height))
        )
    }
}

struct GameViewport: Equatable {
    let size: CGSize
    let scale: Double
    let safeArea: CGRect
}

@MainActor
@Observable
final class GameSession {
    private(set) var frame: CGImage?
    private(set) var logicalSize = GameLayout.size
    private(set) var rasterViewSize = GameLayout.size
    private(set) var usesMetalRenderer = false
    private(set) var isActive = false
    private(set) var canPause = false
    private(set) var canSteerShip = false
    private(set) var canRequestUserResume = false
    private(set) var gameMenuType = 0
    private(set) var failure: String?
    private(set) var menuActions: [GameMenuAction] = []
    private(set) var restorationCreditFrame: CGRect?
    private(set) var persistenceError: String?
    private(set) var pointer = CGPoint(x: GameLayout.width / 2, y: GameLayout.height / 2)
    private(set) var showsPointer = false
    private(set) var isTouching = false
    #if os(iOS)
    private(set) var hapticDeliveryStatus = "detached"
    #endif

    @ObservationIgnored private(set) var engine: SDBEngine?
    @ObservationIgnored private var viewport: GameViewport?
    @ObservationIgnored private var softwareTimer: Timer?
    @ObservationIgnored private var softwareMetrics = GameFrameMetrics(renderer: .software)
    @ObservationIgnored private var clock = GameFrameClock()
    @ObservationIgnored private var releasesTapAfterStep = false
    @ObservationIgnored private let haptics = GameHaptics()
    @ObservationIgnored private var crownInput = GameCrownInput()
    // The Crown Binding setter runs for each native scaled update. Observing
    // its value through SwiftUI State can coalesce turns before input sees them.
    @ObservationIgnored private var crownOffset = 0.0
    @ObservationIgnored lazy var inputController = GameInputController(session: self)
    @ObservationIgnored private var lifecycle = GameLifecyclePolicy()
    @ObservationIgnored private lazy var interruptionMonitor = GameInterruptionMonitor { [weak self] event in
        self?.handleLifecycle(event)
    }
    @ObservationIgnored private var checkpointSteps = 0
    @ObservationIgnored private var reportedSaveError: String?
    @ObservationIgnored private let progressSync = GameProgressSync()
    @ObservationIgnored private var progressControlsOpen = false
    #if os(iOS)
    @ObservationIgnored let folderProgress = GameFolderProgressSync()
    #endif
    @ObservationIgnored private let resumeAudio: @MainActor (SDBEngine) -> Bool

    init(engine: SDBEngine? = nil, lifecycle: GameLifecyclePolicy = GameLifecyclePolicy(),
         resumeAudio: @escaping @MainActor (SDBEngine) -> Bool = { $0.tryResumeAudio() }) {
        self.engine = engine
        self.lifecycle = lifecycle
        self.resumeAudio = resumeAudio
    }

    func setSceneActive(_ active: Bool) {
        setSceneActivity(active ? .active : .background)
    }

    func setSceneActivity(_ activity: GameSceneActivity) {
        interruptionMonitor.start()
        handleLifecycle(.scene(activity))
    }

    func handleLifecycle(_ event: GameLifecycleEvent) {
        defer { refreshUserResumeAvailability() }
        let mustPause = lifecycle.requestsOriginalPause(for: event)
        if mustPause {
            inputController.resetHeldInputs()
            if canPause { pauseGame(deliverFeedback: false) }
        }
        lifecycle.handle(event)
        if !lifecycle.sceneAllowsInteraction { inputController.resetHeldInputs(); cancelTouch() }
        if lifecycle.audioInterrupted || lifecycle.requiresUserResume || lifecycle.needsAudioRebuild || lifecycle.mediaServicesLost {
            engine?.setAudioSuspended(true)
        }
        if case .memoryPressure = event {
            // A bounded checkpoint protects progress before possible eviction.
            saveCheckpoint(completed: true)
            engine?.trimTransientResources()
            return
        }
        updateScheduling()
    }

    private func updateScheduling() {
        // The original pause routine stops gameplay. Its menu still needs
        // ordinary fixed updates and drawing while native audio is unavailable.
        if lifecycle.shouldRun, let engine, engine.audioSuspended, !resumeAudio(engine), canPause {
            pauseGame(deliverFeedback: false)
        }
        let animatesPause = gameMenuType == 3 && lifecycle.canAnimatePausedMenu
        setActive((lifecycle.shouldRun && engine?.audioSuspended != true) || animatesPause)
        // Initial engine creation can encounter an audio failure before any OS
        // interruption notification arrives. Keep that gate independent too.
        if engine?.audioSuspended == true && !animatesPause { setActive(false) }
        inputController.setActive(!progressControlsOpen && isActive && lifecycle.shouldRun &&
                                  lifecycle.sceneAllowsInteraction && engine?.audioSuspended != true)
    }

    private func prepareForUserInteraction() -> Bool {
        defer { refreshUserResumeAvailability() }
        guard !progressControlsOpen, persistenceError == nil, failure == nil, lifecycle.canAttemptUserResume else { return false }
        if isActive && lifecycle.shouldRun && engine?.audioSuspended != true { return true }
        if lifecycle.needsAudioRebuild {
            guard engine?.recoverAudioAfterMediaServicesReset() == true else { return false }
            lifecycle.audioRebuilt()
        }
        guard let engine, resumeAudio(engine) else { return false }
        lifecycle.handle(.audioActivationSucceeded)
        lifecycle.handle(.userInteraction)
        updateScheduling()
        return isActive && lifecycle.shouldRun && engine.audioSuspended == false && failure == nil
    }

    @discardableResult
    func requestUserResume() -> Bool { prepareForUserInteraction() }

    private func refreshUserResumeAvailability() {
        let available = failure == nil && persistenceError == nil && engine != nil && engine?.failure == nil &&
            lifecycle.canAttemptUserResume && (!lifecycle.shouldRun || engine?.audioSuspended == true)
        if canRequestUserResume != available { canRequestUserResume = available }
    }

    @discardableResult
    func activateMenuAction(_ identifier: String) -> Bool {
        guard prepareForUserInteraction(), let engine else { return false }
        inputController.resetHeldInputs()
        cancelTouch()
        let accepted = engine.activateMenuAction(identifier)
        deliverHaptics(from: engine)
        refreshState(from: engine)
        return accepted
    }

    func dismissPersistenceError() {
        inputController.resetHeldInputs()
        cancelTouch()
        persistenceError = nil
        refreshUserResumeAvailability()
    }

    #if os(iOS)
    func setProgressControlsOpen(_ open: Bool) {
        progressControlsOpen = open
        inputController.resetHeldInputs()
        cancelTouch()
        updateScheduling()
    }

    func checkFolderProgress() {
        if isActive, let engine { folderProgress.check(with: engine) }
    }
    #endif

    private func exchangeProgress(with engine: SDBEngine, foreground: Bool = false) {
        #if os(iOS)
        if GameProgressBuild.usesFolder {
            folderProgress.check(with: engine)
            return
        }
        #endif
        progressSync.exchange(with: engine, foreground: foreground)
    }

    private func saveCheckpoint(completed: Bool = false) {
        guard let engine, failure == nil else { return }
        if completed { _ = engine.saveProgress() }
        else { engine.checkpointProgress() }
        exchangeProgress(with: engine)
        updatePersistenceError(from: engine)
    }

    private func updatePersistenceError(from engine: SDBEngine) {
        let error = engine.lastSaveError
        if error == nil { reportedSaveError = nil; persistenceError = nil }
        else if error != reportedSaveError {
            reportedSaveError = error
            persistenceError = error
            inputController.resetHeldInputs()
            cancelTouch()
            // The native alert must not leave the original ship playing behind
            // a modal sheet. Record the error first to prevent recursive alerts.
            if isActive && canPause { pauseGame(deliverFeedback: false) }
        }
    }

    func setActive(_ active: Bool) {
        defer { refreshUserResumeAvailability() }
        if !active {
            isActive = false
            inputController.setActive(false)
            cancelTouch()
            engine?.setSuspended(true)
            if let engine { updatePersistenceError(from: engine) }
            _ = engine?.consumeHapticEvents()
            haptics.reset()
            #if os(iOS)
            refreshHapticDeliveryStatus()
            #endif
            canPause = false
            canSteerShip = false
            restorationCreditFrame = nil
            softwareTimer?.invalidate()
            softwareTimer = nil
            softwareMetrics = GameFrameMetrics(renderer: .software)
            clock.reset()
            return
        }
        guard !isActive, failure == nil else { return }
        if engine == nil {
            guard let path = Bundle.main.resourceURL?.appendingPathComponent("Original").path else {
                failure = "The original game resources could not be found."
                return
            }
            engine = SDBEngine(resourcePath: path, offersHaptics: GameHaptics.offersHaptics)
            failure = engine?.failure
            if let viewport { configure(viewport) }
            if let engine { refreshState(from: engine) }
        }
        guard failure == nil else { return }
        engine?.setSuspended(false)
        if let engine { refreshState(from: engine) }
        guard failure == nil else { return }
        // A software Timer has its own delivery phase. Anchor its epoch at the
        // first callback, rather than letting activation/setup time place every
        // later callback on the clock's early-delivery allowance boundary.
        // Metal retains its display-driven activation epoch. Subsequent clock
        // steps keep the same bounded catch-up and scheduling-time debt.
        clock.reset(at: usesMetalRenderer ? ProcessInfo.processInfo.systemUptime : nil)
        isActive = true
        inputController.setActive(!progressControlsOpen)
        if let engine { exchangeProgress(with: engine, foreground: true) }
        // MetalKit drives supported views directly. Watch and other software
        // fallbacks still need a timer to publish their CPU-rendered CGImage.
        guard !usesMetalRenderer else { return }
        softwareMetrics = GameFrameMetrics(renderer: .software)
        let timer = Timer(timeInterval: GameLayout.simulationStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let started = ProcessInfo.processInfo.systemUptime
                let previousFrame = self.frame
                let steps = self.drawDisplayFrame(at: started)
                if self.softwareMetrics.enabled {
                    self.softwareMetrics.record(started: started,
                        finished: ProcessInfo.processInfo.systemUptime,
                        simulationSteps: steps,
                        producedFrame: self.frame !== previousFrame && self.failure == nil && self.frame != nil,
                        menuType: self.gameMenuType)
                }
            }
        }
        softwareTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called by MetalKit immediately before presentation, or by the software
    /// fallback timer. Catch-up advances original game logic, then renders once.
    @discardableResult
    func drawDisplayFrame(at time: TimeInterval) -> Int {
        guard isActive, failure == nil, let engine else { return 0 }
        let steps = clock.steps(at: time)
        guard steps > 0 else { return 0 }
        for _ in 0..<steps {
            inputController.tick(GameLayout.simulationStep)
            engine.advanceSimulation(GameLayout.simulationStep)
            checkpointSteps += 1
            if checkpointSteps >= GameFrameClock.framesPerSecond * 30 {
                checkpointSteps = 0
                saveCheckpoint()
            }
            if releasesTapAfterStep {
                endTouch()
                releasesTapAfterStep = false
            }
        }
        engine.renderFrame()
        deliverHaptics(from: engine)
        refreshState(from: engine)
        // A newly failed native graph pauses gameplay once. While that menu
        // animates, retries belong to lifecycle events or explicit user input,
        // never to the 60 Hz presentation loop.
        if engine.audioSuspended && lifecycle.shouldRun && gameMenuType != 3 { updateScheduling() }
        if failure != nil { setActive(false) }
        return steps
    }

    func configure(_ viewport: GameViewport) {
        self.viewport = viewport
        guard let engine else { return }
        inputController.resetHeldInputs()
        cancelTouch()
        let old = logicalSize
        engine.configureViewport(viewport.size, displayScale: viewport.scale, safeArea: viewport.safeArea)
        logicalSize = engine.logicalSize
        rasterViewSize = engine.rasterViewSize
        pointer = CGPoint(x: pointer.x / old.width * logicalSize.width,
                          y: pointer.y / old.height * logicalSize.height)
        refreshState(from: engine)
    }

    private func refreshState(from engine: SDBEngine) {
        let metal = engine.usesMetalRenderer
        if usesMetalRenderer != metal { usesMetalRenderer = metal }
        if !metal {
            // A stable software menu retains its immutable image. Publishing
            // the same reference would still invalidate the SwiftUI leaf.
            let next = engine.frame
            if frame !== next { frame = next }
        }
        else if frame != nil { frame = nil }
        let pause = engine.canPause
        if canPause != pause { canPause = pause }
        let steering = engine.canSteerShip
        if canSteerShip != steering { canSteerShip = steering }
        let menu = Int(engine.gameMenuType)
        let menuChanged = gameMenuType != menu
        if menuChanged { gameMenuType = menu }
        if menu == 1, isActive {
            #if os(iOS)
            if GameProgressBuild.usesFolder, !isTouching, !progressControlsOpen {
                folderProgress.applyPending(to: engine)
                if menuChanged { folderProgress.check(with: engine) }
            }
            #endif
            if !GameProgressBuild.usesFolder, progressSync.needsExchange { progressSync.exchange(with: engine) }
        }
        let actions = engine.menuActions.map {
            GameMenuAction(identifier: $0.identifier, label: $0.label,
                           logicalFrame: $0.logicalFrame, selected: $0.selected)
        }
        if menuActions != actions { menuActions = actions }
        let credit = menu == 6 && !actions.isEmpty ? engine.restorationCreditFrame : nil
        if restorationCreditFrame != credit { restorationCreditFrame = credit }
        updatePersistenceError(from: engine)
        if failure != engine.failure { failure = engine.failure }
        refreshUserResumeAvailability()
        if !engine.canSteerShip || menu != 0 || failure != nil { endCrownSteering() }
    }

    private func deliverHaptics(from engine: SDBEngine) {
        // The engine filters gameplay events while in menus, but preserves
        // accepted selections and the Haptics ON preview in every active menu.
        let events = engine.consumeHapticEvents()
        haptics.update(enabled: isActive && lifecycle.sceneAllowsInteraction && lifecycle.shouldRun &&
            engine.hapticsEnabled && engine.failure == nil, events: events)
        #if os(iOS)
        refreshHapticDeliveryStatus()
        #endif
    }

    #if os(iOS)
    func attachHaptics(to view: UIView, owner: AnyObject) {
        haptics.attach(to: view, owner: owner)
        refreshHapticDeliveryStatus()
    }
    func detachHaptics(owner: AnyObject) {
        haptics.detach(owner: owner)
        refreshHapticDeliveryStatus()
    }
    private func refreshHapticDeliveryStatus() {
        let next = haptics.deliveryStatus
        if hapticDeliveryStatus != next { hapticDeliveryStatus = next }
    }
    #endif

    func pauseGame(deliverFeedback: Bool = true) {
        guard let engine, canPause else { return }
        inputController.resetHeldInputs()
        cancelTouch()
        engine.pauseGame()
        if deliverFeedback { deliverHaptics(from: engine) }
        else { _ = engine.consumeHapticEvents() }
        refreshState(from: engine)
        if failure != nil { setActive(false) }
    }

    func point(inView point: CGPoint) -> CGPoint {
        engine?.logicalPoint(forViewPoint: point) ?? .zero
    }

    func drag(to point: CGPoint) {
        guard prepareForUserInteraction() else { return }
        endCrownSteering()
        pointer = point
        showsPointer = false
        engine?.touchPhase(isTouching ? 1 : 0, x: point.x, y: point.y)
        isTouching = true
    }

    func endTouch() {
        guard isTouching else { return }
        engine?.touchPhase(2, x: pointer.x, y: pointer.y)
        isTouching = false
    }

    func cancelTouch() {
        endCrownSteering()
        releasesTapAfterStep = false
        guard isTouching else { return }
        engine?.cancelHeldInput()
        isTouching = false
    }

    func movePointer(dx: CGFloat, dy: CGFloat) {
        guard persistenceError == nil, lifecycle.sceneAllowsInteraction else { return }
        pointer = CGPoint(
            x: min(logicalSize.width, max(0, pointer.x + dx)),
            y: min(logicalSize.height, max(0, pointer.y + dy))
        )
        showsPointer = true
        if isTouching { engine?.touchPhase(1, x: pointer.x, y: pointer.y) }
    }

    func setPointerY(_ fraction: Double) {
        movePointer(dx: 0, dy: CGFloat(fraction) * logicalSize.height - pointer.y)
    }

    /// Move through the original ship spring without holding a targeting touch.
    /// A held finger keeps ownership; turning the Crown cannot cancel its aim.
    var crownPosition: Double {
        get { crownOffset }
        set {
            guard newValue.isFinite else { endCrownSteering(); return }
            let previous = crownOffset
            // Keep the transport baseline current even when menus, entrance,
            // inactive state or a held finger reject this particular input.
            crownOffset = newValue
            steerWithCrown(delta: GameCrownInput.wrappedDelta(from: previous, to: newValue))
        }
    }

    func crownBecameIdle() { crownInput.becameIdle() }

    func steerWithCrown(delta: Double) {
        guard persistenceError == nil, lifecycle.shouldRun, lifecycle.sceneAllowsInteraction else { return }
        guard isActive, !isTouching, failure == nil, let engine,
              engine.canSteerShip, engine.gameMenuType == 0 else {
            endCrownSteering()
            return
        }
        let ship = engine.shipNormalizedY
        guard delta.isFinite, ship.isFinite else {
            endCrownSteering()
            return
        }
        guard let target = crownInput.target(for: delta, shipNormalizedY: ship) else { return }
        engine.steerShip(toNormalizedY: target)
    }

    func endCrownSteering() {
        guard crownInput.targetNormalizedY != nil else { return }
        crownInput.reset()
        engine?.cancelShipSteering()
    }

    func beginPointerTouch() {
        guard prepareForUserInteraction() else { return }
        guard !isTouching else { return }
        endCrownSteering()
        showsPointer = true
        isTouching = true
        engine?.touchPhase(0, x: pointer.x, y: pointer.y)
    }

    func tapPointer() {
        guard persistenceError == nil else { return }
        beginPointerTouch()
        if isTouching { releasesTapAfterStep = true }
    }

    func togglePointerTouch() {
        guard persistenceError == nil else { return }
        if isTouching { endTouch() } else { beginPointerTouch() }
    }
}
