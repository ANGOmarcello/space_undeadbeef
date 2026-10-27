// Created by Angelo Cammalleri on 27.10.2026.
import Foundation

@main enum LifecyclePolicyTests {
    static func main() {
        var checks = 0
        func require(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        var policy = GameLifecyclePolicy()
        require(!policy.shouldRun, "No scheduling before the scene becomes active")
        policy.handle(.scene(.active))
        require(policy.shouldRun, "Active scene starts normally")
        policy.handle(.audioInterrupted)
        policy.handle(.scene(.background)); policy.handle(.scene(.active))
        require(!policy.shouldRun, "Foreground cannot override an ongoing call")
        policy.handle(.audioEnded(shouldResume: true))
        require(policy.shouldRun, "An ended interruption permits the paused host to run")
        policy.handle(.audioInterrupted)
        policy.handle(.audioEnded(shouldResume: false))
        require(!policy.shouldRun, "A denied automatic resume waits for user action")
        policy.handle(.userInteraction)
        require(policy.shouldRun, "An explicit action can resume an ended interruption")
        policy.handle(.mediaServicesLost)
        policy.handle(.userInteraction)
        require(!policy.shouldRun && policy.needsAudioRebuild, "Lost services cannot be resumed prematurely")
        policy.handle(.mediaServicesReset)
        require(!policy.shouldRun && policy.canAcceptUserResume, "A reset requires explicit user initiation")
        policy.handle(.userInteraction)
        require(!policy.shouldRun, "User initiation still needs graph reconstruction")
        policy.audioRebuilt()
        require(policy.shouldRun, "Successful graph reconstruction releases the final gate")
        policy.handle(.application(false)); policy.handle(.scene(.active))
        require(!policy.shouldRun, "App focus and scene activity are independent")
        policy.handle(.application(true))
        require(policy.shouldRun, "Returning focus restores a paused foreground host")
        policy.handle(.routeDisconnected)
        require(policy.shouldRun, "Route loss requests original pause without freezing menu interaction")
        policy.handle(.audioInterrupted); policy.handle(.mediaServicesReset)
        policy.handle(.scene(.background)); policy.handle(.userInteraction); policy.audioRebuilt()
        require(!policy.shouldRun, "A reset cannot bypass an inactive scene")
        policy.handle(.scene(.active))
        require(!policy.shouldRun, "A background user request cannot arm later automatic playback")
        policy.handle(.userInteraction)
        require(policy.shouldRun, "An active explicit request completes recovery")
        policy.handle(.scene(.background)); policy.handle(.scene(.background)); policy.handle(.scene(.active))
        require(policy.shouldRun, "Repeated suspension notifications are harmless")

        var transient = GameLifecyclePolicy(pausesInactiveScene: false)
        transient.handle(.scene(.active))
        require(!transient.requestsOriginalPause(for: .scene(.inactive)), "An iOS inactive banner does not request original Pause")
        transient.handle(.scene(.inactive))
        require(transient.shouldRun && transient.sceneAllowsScheduling && !transient.sceneAllowsInteraction && !transient.requiresUserResume,
                "A foreground iOS banner keeps scheduling without accepting held input or arming a manual-resume gate")
        transient.handle(.scene(.active))
        require(transient.shouldRun, "Returning from a transient banner automatically restores scheduling")
        require(transient.requestsOriginalPause(for: .scene(.background)), "Actual iOS backgrounding still requests original Pause")
        transient.handle(.scene(.inactive)); transient.handle(.scene(.background))
        require(!transient.shouldRun, "An inactive-to-background transition cannot play hidden time")
        transient.handle(.scene(.active))
        require(transient.shouldRun, "Foreground scheduling can animate the original background pause")

        let persistent = GameLifecyclePolicy(pausesInactiveScene: true)
        require(persistent.requestsOriginalPause(for: .scene(.inactive)), "Watch, TV and Mac retain their original inactive pause policy")
        var otherInactive = persistent
        otherInactive.handle(.scene(.inactive))
        require(!otherInactive.shouldRun && !otherInactive.sceneAllowsScheduling && !otherInactive.sceneAllowsInteraction,
                "Watch, TV and Mac still stop scheduling and input while inactive")
        require(persistent.requestsOriginalPause(for: .application(false)), "Application focus loss still requests original Pause")
        require(persistent.requestsOriginalPause(for: .audioInterrupted), "A genuine audio interruption still requests original Pause")
        require(persistent.requestsOriginalPause(for: .routeDisconnected), "A disconnected route still requests original Pause")
        require(persistent.requestsOriginalPause(for: .mediaServicesLost) && persistent.requestsOriginalPause(for: .mediaServicesReset),
                "Lost/reset services preserve the original Pause boundary")
        require(!persistent.requestsOriginalPause(for: .audioEnded(shouldResume: false)) &&
                !persistent.requestsOriginalPause(for: .scene(.active)) &&
                !persistent.requestsOriginalPause(for: .memoryPressure), "Hints and cache events never invent another Pause")

        var hints = GameLifecyclePolicy(pausesInactiveScene: false)
        hints.handle(.scene(.active))
        hints.handle(.audioEnded(shouldResume: false))
        require(hints.shouldRun && !hints.requiresUserResume, "An unmatched no-resume audio hint cannot freeze a running game")
        hints.handle(.audioEnded(shouldResume: true))
        require(hints.shouldRun, "An unmatched resume hint is harmless")
        require(GameAudioInterruptionPolicy.began(reason: 1) == nil,
                "A delayed appWasSuspended begin is informational rather than an ongoing call")
        require(GameAudioInterruptionPolicy.began(reason: nil, wasSuspended: true) == nil,
                "The legacy wasSuspended hint also does not acquire an interruption gate")
        require(GameAudioInterruptionPolicy.began(reason: nil) == .audioInterrupted,
                "A begin with missing optional metadata remains a genuine interruption")
        require(GameAudioInterruptionPolicy.began(reason: 0, wasSuspended: true) == .audioInterrupted,
                "An explicit current reason supersedes an obsolete contradictory legacy flag")
        require(GameAudioInterruptionPolicy.began(reason: 2) == .audioInterrupted &&
                GameAudioInterruptionPolicy.began(reason: 4) == .audioInterrupted &&
                GameAudioInterruptionPolicy.began(reason: 999) == .audioInterrupted,
                "Mic, route and future reasons retain conservative genuine-interruption behavior")
        if let real = GameAudioInterruptionPolicy.began(reason: 0) { hints.handle(real) }
        hints.handle(.scene(.inactive)); hints.handle(.scene(.active))
        require(!hints.shouldRun && hints.audioInterrupted, "A real call cannot be overridden by banner/foreground events")
        hints.handle(.audioEnded(shouldResume: false))
        require(!hints.shouldRun && hints.canAcceptUserResume, "A matched no-resume interruption requires explicit original-menu recovery")
        hints.handle(.audioEnded(shouldResume: true))
        require(!hints.shouldRun && hints.requiresUserResume, "A later unmatched hint cannot erase the explicit-resume gate")
        hints.handle(.userInteraction)
        require(hints.shouldRun, "A foreground explicit action completes genuine interruption recovery")

        var menu = GameLifecyclePolicy(pausesInactiveScene: false)
        menu.handle(.scene(.active)); menu.handle(.audioInterrupted)
        require(menu.canAnimatePausedMenu && !menu.shouldRun,
                "A genuine interruption can animate the original Pause menu while audio/gameplay stays gated")
        require(menu.canAttemptUserResume && !menu.canAcceptUserResume,
                "A foreground user may ask the OS to reactivate without blindly clearing an ongoing interruption")
        menu.handle(.userInteraction)
        require(!menu.shouldRun && menu.audioInterrupted, "An ordinary input cannot claim that audio activation succeeded")
        menu.handle(.audioActivationSucceeded)
        require(menu.shouldRun && !menu.audioInterrupted,
                "OS-approved explicit activation recovers a missing ended notification")
        menu.handle(.audioInterrupted); menu.handle(.scene(.inactive))
        require(menu.canAnimatePausedMenu && !menu.shouldRun && !menu.canAttemptUserResume,
                "An inactive iOS scene may animate a real pause but cannot reactivate audio or accept input")
        menu.handle(.scene(.active)); menu.handle(.audioActivationSucceeded)
        menu.handle(.audioInterrupted); menu.handle(.audioEnded(shouldResume: false))
        require(menu.canAnimatePausedMenu && !menu.shouldRun,
                "A no-auto-resume recommendation never freezes original Pause animation")
        menu.handle(.audioActivationSucceeded)
        require(menu.shouldRun, "Successful explicit activation also releases a matched no-resume gate")
        menu.handle(.mediaServicesLost)
        require(menu.canAnimatePausedMenu && !menu.canAttemptUserResume,
                "Lost audio services do not prevent silent original menu animation but cannot yet reactivate")
        menu.handle(.audioActivationSucceeded)
        require(menu.mediaServicesLost && !menu.shouldRun, "An activation result cannot bypass unavailable media services")
        menu.handle(.mediaServicesReset); menu.handle(.audioActivationSucceeded)
        require(!menu.shouldRun && menu.needsAudioRebuild,
                "Session activation and native graph reconstruction remain separate success requirements")
        menu.audioRebuilt()
        require(menu.shouldRun, "Confirmed activation and completed graph repair release scheduling")
        menu.handle(.audioInterrupted); menu.handle(.scene(.background))
        require(!menu.canAnimatePausedMenu && !menu.canAttemptUserResume,
                "Neither menu animation nor audio recovery can run in the background")
        menu.handle(.audioActivationSucceeded); menu.handle(.scene(.active))
        require(!menu.shouldRun && menu.audioInterrupted,
                "A background activation event cannot arm later hidden resume")
        menu.handle(.application(false))
        require(!menu.canAnimatePausedMenu && !menu.canAttemptUserResume,
                "Application focus loss closes both independent menu and activation gates")
        print("PASS: \(checks) lifecycle gating checks")
    }
}
