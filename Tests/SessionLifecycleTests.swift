//
//  SessionLifecycleTests.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//
// Exercises the actual Session and original game. Lifecycle events are injected
// into this process only; no notifications, devices, settings or cloud are used.

import CoreGraphics
import Foundation
import AVFAudio

@MainActor
private final class SessionAudioAvailability {
    var available = true
    var attempts = 0
    func resume(_ engine: SDBEngine) -> Bool {
        attempts += 1
        return available && engine.tryResumeAudio()
    }
}

@main
@MainActor
enum SessionLifecycleTests {
    static func main() {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        require(CommandLine.arguments.count == 3, "Supply original resources and an empty task-owned temporary save directory")
        let resources = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let temporaryRoots = [URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath(),
                              URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()]
        require(temporaryRoots.contains { directory.path.hasPrefix($0.path + "/") }, "State must remain inside system temporary storage")
        require((try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true,
                "The caller must create an empty isolated directory")
        setenv("SDB_SAVE_DIRECTORY", directory.path, 1)
        setenv("SDB_UI_TEST", "1", 1) // Suppresses real controller observers/enumeration and cloud.
        setenv("SDB_MUTE_AUDIO", "1", 1)
        setenv("SDB_CPU_RENDERER", "1", 1)

        let engine = SDBEngine(resourcePath: resources, offersHaptics: true)
        let audioAvailability = SessionAudioAvailability()
        let session = GameSession(engine: engine, lifecycle: GameLifecyclePolicy(pausesInactiveScene: false)) { engine in
            audioAvailability.resume(engine)
        }
        let viewport = GameViewport(size: CGSize(width: 240, height: 160), scale: 1,
                                    safeArea: CGRect(x: 0, y: 0, width: 240, height: 160))
        session.configure(viewport)
        session.setSceneActive(true)
        defer { session.setSceneActive(false) }
        var time = 0.0
        require(session.isActive && engine.failure == nil, "Activate the actual isolated software Session")
        require(!session.canRequestUserResume, "Ordinary active gameplay has no redundant recovery action")
        require(session.drawDisplayFrame(at: time) == 0, "First software callback establishes its epoch")

        func healthy(_ context: String) {
            require(session.failure == nil && engine.failure == nil,
                    "\(context): actual runtime stays healthy (\(engine.failure ?? "none"))")
        }
        func advance(_ frames: Int) {
            for _ in 0..<frames {
                time += GameLayout.simulationStep
                require(session.drawDisplayFrame(at: time) == 1, "Active Session preserves each original fixed update")
            }
            healthy("fixed updates")
        }
        func action(_ label: String) -> GameMenuAction {
            for _ in 0..<180 {
                if let action = session.menuActions.first(where: { $0.label == label }) { return action }
                advance(1)
            }
            require(false, "Original menu never exposed \(label); menu=\(session.gameMenuType)")
            fatalError("unreachable")
        }
        func activate(_ label: String) {
            let item = action(label)
            require(session.activateMenuAction(item.identifier), "Original semantic \(label) decision is accepted")
            advance(120) // Original decided/menu animation, not an assigned state.
        }
        func primeResume() {
            time += 30 // No inactive time may be simulated by the resumed host.
            require(session.drawDisplayFrame(at: time) == 0, "Resumed software Session starts a fresh epoch")
        }
        func resumeOriginalGame() {
            require(session.gameMenuType == 3 && !session.canPause, "Scheduling never dismisses the original pause menu")
            activate("Resume")
            require(session.gameMenuType == 0 && session.canPause, "Original Resume restores gameplay")
        }
        func beginCharge() {
            require(engine.canSteerShip && session.canPause, "A playable original ship is available for the charge")
            session.inputController.setKey(.fire, pressed: true)
            advance(1)
            require(session.isTouching && engine.shipAiming, "The native keyboard edge starts original marker aiming")
        }
        func audioEvents() -> UInt64? {
            engine.diagnostics.split(separator: " ").first(where: { $0.hasPrefix("audio=") })
                .flatMap { UInt64($0.dropFirst("audio=".count)) }
        }
        func audioGraph() -> AVAudioEngine? {
            (engine.value(forKey: "audioMixer") as? NSObject)?.value(forKey: "engine") as? AVAudioEngine
        }
        func pausedSources() -> NSSet? {
            (engine.value(forKey: "pausedSources") as? NSSet)?.copy() as? NSSet
        }
        func voices() -> [NSNumber: NSObject]? { engine.value(forKey: "players") as? [NSNumber: NSObject] }
        func isPlaying(_ voice: NSObject) -> Bool {
            (voice.value(forKey: "isPlaying") as? NSNumber)?.boolValue == true
        }
        func isLooping(_ voice: NSObject) -> Bool {
            ((voice.value(forKey: "numberOfLoops") as? NSNumber)?.intValue ?? 0) < 0
        }

        advance(120)
        require(session.gameMenuType == 1 && session.menuActions.count == 4, "The original title exposes four semantic choices")
        let staleStart = action("Game Start").identifier
        activate("Game Start")
        require(session.gameMenuType == 0 && session.menuActions.isEmpty, "Semantic Start enters actual original gameplay")
        for _ in 0..<600 {
            if engine.canSteerShip { break }
            advance(1)
        }
        require(engine.canSteerShip, "Normal entrance reaches the playable ship without state edits")
        let earned = engine.progressPortableSnapshot
        require((earned?["checkpoint"] as? NSNumber)?.intValue ?? 0 > 0,
                "Ordinary original updates earn a real checkpoint")

        // Read private Objective-C objects only to observe retained voice intent.
        // Public suspension/recovery APIs supply this fixture; no KVC writes or
        // guest patches manufacture a playing voice or saved-source membership.
        engine.setSuspended(true)
        let pausedBeforeReset = pausedSources()
        let voicesBeforeReset = voices()
        let graphBeforeReset = audioGraph()
        require(pausedBeforeReset != nil && pausedBeforeReset!.count > 0,
                "An ordinary game has active audio voices whose resume intent can be tested")
        require(graphBeforeReset != nil && !graphBeforeReset!.isRunning,
                "Public suspension actually stops native audio callbacks")
        require(engine.recoverAudioAfterMediaServicesReset(), "The public engine reset rebuild succeeds in isolation")
        let loopingSources = pausedBeforeReset!.allObjects.compactMap { $0 as? NSNumber }.filter {
            voicesBeforeReset?[$0].map(isLooping) == true
        }
        require(pausedSources()?.isEqual(NSSet(array: loopingSources)) == true,
                "Native graph reconstruction retains music intent and discards interrupted one-shots")
        let rebuiltGraph = audioGraph()
        require(rebuiltGraph != nil && rebuiltGraph !== graphBeforeReset && !rebuiltGraph!.isRunning,
                "Recovery replaces the native graph without starting it")
        let retainedVoices = voices()
        require(voicesBeforeReset != nil && retainedVoices != nil,
                "Original voice objects remain observable across graph reconstruction")
        var loopingVoices: [NSObject] = []
        for source in loopingSources {
            guard let before = voicesBeforeReset?[source],
                  let after = retainedVoices?[source] else {
                require(false, "Paused source must retain its original logical voice"); continue
            }
            require(before === after && !isPlaying(after),
                    "A rebuilt graph preserves each logical voice while keeping it paused")
            if isLooping(after) { loopingVoices.append(after) }
        }
        require(!loopingVoices.isEmpty, "The retained intent includes original looping background music")
        engine.setSuspended(false)
        require(engine.audioSuspended && audioGraph()?.isRunning == false,
                "Resuming guest scheduling alone cannot reopen audio after media reset")
        require(engine.tryResumeAudio(), "Explicit OS-approved activation releases the native audio gate")
        require(engine.failure == nil && audioGraph()?.isRunning == true,
                "Explicit activation prepares the rebuilt native graph")
        // One-shots may naturally finish in the first resumed render quantum;
        // looping music gives a stable oracle for restored transport intent.
        for voice in loopingVoices {
            require(isPlaying(voice), "Explicit activation restores the paused original background music")
        }
        require(pausedSources()?.count == 0, "Explicit activation consumes the retained resume intent")

        beginCharge()
        let beforeCancel = audioEvents()
        require(beforeCancel != nil, "Original audio-event counter is observable")
        session.inputController.resetHeldInputs()
        require(!session.isTouching && !engine.shipAiming, "Reset cancels both native charge ownership and original marker aiming")
        require(audioEvents() == beforeCancel, "Canceling a charge does not request a release-volley sound")

        beginCharge()
        let beforeBanner = engine.progressPortableSnapshot
        let attemptsBeforeBanner = audioAvailability.attempts
        session.setSceneActivity(.inactive)
        require(session.isActive && session.gameMenuType == 0 && !session.isTouching && !engine.shipAiming,
                "A transient iOS banner cancels held input without stopping gameplay or entering Pause")
        let pointerBeforeBanner = session.pointer
        session.drag(to: .zero)
        session.movePointer(dx: GameLayout.pointerStep, dy: GameLayout.pointerStep)
        require(!session.isTouching && session.pointer == pointerBeforeBanner,
                "A foreground inactive banner does not accept input intended for the system")
        advance(30)
        require(session.gameMenuType == 0 && !engine.audioSuspended && audioAvailability.attempts == attemptsBeforeBanner,
                "Banner time uses ordinary game updates without stopping or reactivating audio")
        session.setSceneActivity(.active)
        advance(1)
        require(session.canPause && session.gameMenuType == 0 && !session.canRequestUserResume,
                "Dismissing a banner leaves the ongoing game playable with no Resume ceremony")
        require(beforeBanner != nil, "The banner fixture started from real original progress")

        engine.setAudioSuspended(true)
        audioAvailability.available = false
        session.handleLifecycle(.wake)
        require(session.isActive && session.gameMenuType == 3 && engine.audioSuspended,
                "A native audio failure without an OS notification enters the original animated Pause menu")
        let failedAttempts = audioAvailability.attempts
        advance(120)
        require(audioAvailability.attempts == failedAttempts,
                "Animating a paused menu never retries unavailable audio from the 60 Hz frame loop")
        require(!session.activateMenuAction(action("Resume").identifier) && session.gameMenuType == 3,
                "A failed native audio retry cannot dispatch original Resume")
        audioAvailability.available = true
        resumeOriginalGame()

        beginCharge()
        session.setSceneActive(false)
        require(!session.isActive && !session.isTouching && !engine.shipAiming, "Scene suspension cancels charge and aiming")
        require(!session.canRequestUserResume, "An inactive scene exposes no semantic recovery action")
        require(session.gameMenuType == 3 && !session.canPause, "Scene suspension enters the original pause flow")
        let suspendedState = engine.diagnostics
        require(session.drawDisplayFrame(at: time + 10) == 0 && engine.diagnostics == suspendedState,
                "An inactive host cannot simulate or render hidden game time")
        require(!session.activateMenuAction(staleStart), "An inactive stale semantic action cannot dispatch")
        audioAvailability.available = false
        session.handleLifecycle(.audioInterrupted)
        session.setSceneActive(true)
        require(session.isActive && engine.audioSuspended && !session.requestUserResume(),
                "Foreground may animate Pause, but cannot override OS refusal to reactivate audio")
        require(session.canRequestUserResume, "A foreground pause offers an explicit OS-checked recovery attempt")
        audioAvailability.available = true
        session.handleLifecycle(.audioEnded(shouldResume: true))
        require(session.isActive && !engine.audioSuspended, "An eligible ended interruption releases native audio")
        require(!session.canRequestUserResume, "Automatically eligible scheduling needs no explicit recovery action")
        primeResume()
        resumeOriginalGame()
        require(!session.isTouching && !engine.shipAiming, "Original Resume cannot resurrect a canceled charge")

        beginCharge()
        audioAvailability.available = false
        session.handleLifecycle(.audioInterrupted)
        advance(120)
        let pausedProgress = engine.progressPortableSnapshot
        advance(120)
        require(session.isActive && engine.audioSuspended && audioGraph()?.isRunning == false &&
                session.menuActions.contains(where: { $0.label == "Resume" }),
                "The original Pause menu completes normal animation while the interrupted audio graph stays stopped")
        require(NSDictionary(dictionary: pausedProgress ?? [:]).isEqual(to: engine.progressPortableSnapshot ?? [:]),
                "Paused menu animation cannot advance original progress behind the audio gate")
        let busyResume = action("Resume")
        require(!session.activateMenuAction(busyResume.identifier) && session.gameMenuType == 3,
                "A busy OS rejects explicit recovery without dismissing the original Pause menu")
        audioAvailability.available = true
        // No interruption-ended event: actual OS-approved user activation is
        // sufficient to recover a stale begin, through the original touch row.
        session.drag(to: CGPoint(x: busyResume.logicalFrame.midX, y: busyResume.logicalFrame.midY))
        advance(1)
        session.endTouch()
        advance(120)
        require(session.gameMenuType == 0 && session.canPause && !engine.audioSuspended,
                "One ordinary Resume tap recovers a missing end notification without a hidden first tap")

        beginCharge()
        session.handleLifecycle(.audioInterrupted)
        session.handleLifecycle(.audioEnded(shouldResume: false))
        require(session.isActive && engine.audioSuspended && !session.isTouching && !engine.shipAiming,
                "A no-resume recommendation keeps audio stopped while the original Pause UI remains live")
        require(session.canRequestUserResume, "An ended no-resume interruption offers semantic user recovery")
        session.setSceneActive(false)
        require(!session.canRequestUserResume, "Backgrounding hides explicit recovery until the scene is eligible")
        session.setSceneActive(true)
        require(session.isActive && engine.audioSuspended, "Foreground animates the original menu without bypassing explicit audio resume")
        require(session.canRequestUserResume, "Returning an eligible scene restores its semantic recovery action")
        session.handleLifecycle(.application(false))
        require(!session.canRequestUserResume && !session.requestUserResume(), "Application focus independently gates semantic recovery")
        session.handleLifecycle(.application(true))
        require(session.canRequestUserResume && session.isActive && engine.audioSuspended,
                "Restoring focus offers animated recovery without restarting audio automatically")
        require(session.requestUserResume() && session.isActive, "A fresh user request can resume an ended interruption")
        require(!session.canRequestUserResume, "Successful explicit recovery removes its semantic action")
        primeResume()
        resumeOriginalGame()

        session.handleLifecycle(.application(false))
        session.setSceneActive(true)
        require(!session.isActive && !session.requestUserResume(), "A scene cannot override loss of application focus")
        session.handleLifecycle(.application(true))
        require(session.isActive, "Returning application focus releases the independent gate")
        primeResume()
        resumeOriginalGame()

        beginCharge()
        session.handleLifecycle(.routeDisconnected)
        require(session.isActive && session.gameMenuType == 3 && !session.isTouching && !engine.shipAiming,
                "Route loss pauses the original game while keeping pause-menu interaction available")
        resumeOriginalGame()

        session.handleLifecycle(.mediaServicesLost)
        require(session.isActive && engine.audioSuspended && !session.requestUserResume(),
                "Lost media services reject premature audio resume while keeping the original menu responsive")
        require(!session.canRequestUserResume, "Lost media services expose no unusable recovery action")
        session.handleLifecycle(.mediaServicesReset)
        session.handleLifecycle(.wake)
        session.setSceneActive(true)
        require(session.isActive && audioGraph()?.isRunning == false && engine.audioSuspended,
                "Media reset, wake and foreground animate Pause without restarting native audio automatically")
        require(session.canRequestUserResume, "Completed media reset offers semantic recovery despite the suspended guest menu")
        require(session.requestUserResume() && session.isActive, "Explicit user recovery rebuilds the real audio graph and resumes scheduling")
        require(!session.canRequestUserResume, "Audio graph recovery clears its semantic recovery action")
        advance(1)
        resumeOriginalGame()

        // Preserve a paused original record and currently visible software image
        // while trimming host caches and checkpointing under memory pressure.
        session.pauseGame(deliverFeedback: false)
        advance(120)
        let visible = session.frame
        require(visible != nil, "The actual Session published its software frame")
        session.handleLifecycle(.memoryPressure)
        require(session.frame === visible && session.isActive && session.gameMenuType == 3,
                "Memory pressure preserves the visible frame and pause state")
        require(session.persistenceError == nil && engine.lastSaveError == nil, "Memory-pressure checkpoint has no persistence error")
        let saveFile = directory.appendingPathComponent("savedata.dat")
        let saved = try? Data(contentsOf: saveFile)
        require(saved?.count == 256 && saved?.prefix(4) == Data([0x50, 0x53, 0x48, 0x30]),
                "Lifecycle checkpoint retains the original 256-byte PSH0 record")
        let checkpoint = (engine.progressPortableSnapshot?["checkpoint"] as? NSNumber)?.intValue
        require(checkpoint != nil && checkpoint! > 0, "Lifecycle checkpoint retains naturally earned progress")
        healthy("memory trim")
        session.setSceneActive(false)

        let freshEngine = SDBEngine(resourcePath: resources, offersHaptics: true)
        let fresh = GameSession(engine: freshEngine)
        fresh.configure(viewport)
        fresh.setSceneActive(true)
        defer { fresh.setSceneActive(false) }
        var freshTime = 0.0
        require(fresh.drawDisplayFrame(at: freshTime) == 0, "Fresh engine establishes a separate software epoch")
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            require(fresh.drawDisplayFrame(at: freshTime) == 1, "Fresh Session advances the untouched original title")
        }
        require(freshEngine.failure == nil && fresh.gameMenuType == 1, "A fresh engine loads the original saved title normally")
        require((freshEngine.progressPortableSnapshot?["checkpoint"] as? NSNumber)?.intValue == checkpoint,
                "Fresh original load preserves the saved checkpoint")
        fresh.handleLifecycle(.audioInterrupted)
        require(!fresh.isActive && fresh.canRequestUserResume,
                "An interrupted title offers an explicit OS-checked retry even if an end notification is missing")
        fresh.handleLifecycle(.audioEnded(shouldResume: false))
        require(!fresh.isActive && fresh.canRequestUserResume && fresh.gameMenuType == 1,
                "A suspended original title offers semantic recovery after a no-resume interruption")
        require(fresh.requestUserResume() && !fresh.canRequestUserResume,
                "Semantic title recovery restarts scheduling and removes the recovery action")
        freshTime += 30
        require(fresh.drawDisplayFrame(at: freshTime) == 0, "Recovered title also gets a fresh software epoch")
        require(fresh.gameMenuType == 1 && fresh.menuActions.contains(where: { $0.label == "Continue" }),
                "Original title choices reappear after semantic recovery")
        let continueAction = fresh.menuActions.first(where: { $0.label == "Continue" })
        require(continueAction != nil && fresh.activateMenuAction(continueAction!.identifier),
                "Fresh Session accepts the actual original Continue semantic action")
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            require(fresh.drawDisplayFrame(at: freshTime) == 1, "Continue runs normal fixed updates")
        }
        require(freshEngine.failure == nil && fresh.gameMenuType == 0 && fresh.canPause,
                "Original Continue enters healthy gameplay through the saved checkpoint")
        fresh.pauseGame()
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            _ = fresh.drawDisplayFrame(at: freshTime)
        }
        guard let preparedResume = fresh.menuActions.first(where: { $0.label == "Resume" }) else {
            require(false, "Prepare the controller pointer on the actual original Resume row"); return
        }
        fresh.movePointer(dx: preparedResume.logicalFrame.midX - fresh.pointer.x,
                          dy: preparedResume.logicalFrame.midY - fresh.pointer.y)
        require(fresh.activateMenuAction(preparedResume.identifier), "Prepare a genuine resumed game before storage failure")
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            _ = fresh.drawDisplayFrame(at: freshTime)
        }
        require(fresh.canPause && fresh.gameMenuType == 0, "The prepared controller target retains ordinary gameplay")
        let priorPacked = freshEngine.progressPortableSnapshot?["saveData"] as? Data
        for _ in 0..<1200 {
            if (freshEngine.progressPortableSnapshot?["saveData"] as? Data) != priorPacked { break }
            freshTime += GameLayout.simulationStep
            _ = fresh.drawDisplayFrame(at: freshTime)
        }
        require(fresh.canPause && (freshEngine.progressPortableSnapshot?["saveData"] as? Data) != priorPacked,
                "Ordinary gameplay changes original packed progress before the storage-failure fixture")
        let backup = directory.appendingPathExtension("before-storage-error")
        do {
            try FileManager.default.moveItem(at: directory, to: backup)
            try Data([0]).write(to: directory)
        } catch {
            require(false, "Cannot prepare task-owned storage failure: \(error)")
        }
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.moveItem(at: backup, to: directory)
        }
        fresh.handleLifecycle(.memoryPressure)
        require(fresh.failure == nil && fresh.persistenceError != nil && fresh.isActive && fresh.gameMenuType == 3,
                "A real save failure remains nonfatal and pauses gameplay before its native alert")
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            require(fresh.drawDisplayFrame(at: freshTime) == 1,
                    "The original pause animation keeps its normal fixed updates behind the storage alert")
        }
        guard let modalResume = fresh.menuActions.first(where: { $0.label == "Resume" }) else {
            require(false, "The original settled pause menu must expose Resume behind the modal"); return
        }
        require(modalResume.logicalFrame.contains(fresh.pointer), "The controller is already aimed at the actual original Resume row")
        let modalPointer = fresh.pointer
        fresh.movePointer(dx: GameLayout.pointerStep, dy: GameLayout.pointerStep)
        fresh.setPointerY(0)
        fresh.steerWithCrown(delta: 0.2)
        require(fresh.pointer == modalPointer && !fresh.isTouching && !freshEngine.shipAiming,
                "Direct remote targeting and Crown input remain inert during the storage modal")
        require(!fresh.activateMenuAction(modalResume.identifier) && !fresh.requestUserResume(),
                "Semantic Resume and recovery cannot bypass the pending storage alert")
        fresh.beginPointerTouch()
        fresh.tapPointer()
        require(!fresh.isTouching, "A native pointer cannot begin a hidden touch while the alert is pending")
        fresh.inputController.setKey(.fire, pressed: true)
        for sample in [GameControllerSample(), GameControllerSample(fire: true), GameControllerSample()] {
            fresh.inputController.tick(GameLayout.simulationStep, sample: sample)
            freshTime += GameLayout.simulationStep
            _ = fresh.drawDisplayFrame(at: freshTime)
        }
        require(!fresh.isTouching && !freshEngine.shipAiming && fresh.gameMenuType == 3 && fresh.persistenceError != nil,
                "Fresh keyboard/controller presses and releases over Resume cannot play behind the storage alert")
        fresh.inputController.tick(GameLayout.simulationStep, sample: GameControllerSample(fire: true))
        fresh.handleLifecycle(.mediaServicesReset)
        require(fresh.isActive && !fresh.canRequestUserResume && fresh.persistenceError != nil && freshEngine.audioSuspended,
                "A media-reset gate cannot expose semantic recovery through the pending storage alert")
        fresh.dismissPersistenceError()
        require(fresh.persistenceError == nil, "The storage error can be acknowledged without leaving the game")
        require(fresh.canRequestUserResume,
                "Acknowledgement immediately republishes recovery when stopped scheduling has no timer")
        require(fresh.requestUserResume() && fresh.isActive,
                "Acknowledged explicit recovery rebuilds audio without reopening the unchanged save error")
        fresh.inputController.tick(GameLayout.simulationStep, sample: GameControllerSample(fire: true))
        require(!fresh.isTouching && fresh.gameMenuType == 3,
                "A controller button held across acknowledgement is not queued as a hidden Resume")
        // Check the injected held edge before an ordinary host tick samples
        // the intentionally absent hardware controller as released.
        freshTime += GameLayout.simulationStep
        require(fresh.drawDisplayFrame(at: freshTime) == 1,
                "Modal/media recovery preserves the ordinary paused-menu clock without a hidden catch-up")
        fresh.drag(to: modalPointer)
        freshTime += GameLayout.simulationStep
        _ = fresh.drawDisplayFrame(at: freshTime)
        require(fresh.isTouching, "A modal-blocked tap cannot queue a release that ends a fresh post-acknowledgement touch")
        fresh.cancelTouch()
        fresh.inputController.resetHeldInputs()
        fresh.inputController.tick(GameLayout.simulationStep, sample: GameControllerSample())
        fresh.inputController.tick(GameLayout.simulationStep, sample: GameControllerSample(fire: true))
        require(fresh.isTouching, "A fresh post-acknowledgement controller press reaches the original Resume row")
        fresh.inputController.tick(GameLayout.simulationStep, sample: GameControllerSample())
        require(!fresh.isTouching, "The post-acknowledgement controller release follows the original touch-ended path")
        for _ in 0..<120 {
            freshTime += GameLayout.simulationStep
            require(fresh.drawDisplayFrame(at: freshTime) == 1, "Original Resume continues normal fixed updates after acknowledgement")
        }
        require(fresh.gameMenuType == 0 && fresh.canPause && fresh.persistenceError == nil && fresh.failure == nil,
                "Fresh acknowledged Resume restores gameplay without recursively reopening the unchanged error")
        print("PASS: \(checks) actual Session/engine lifecycle, input, semantic menu and checkpoint checks")
    }
}
