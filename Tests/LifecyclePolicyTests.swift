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
        policy.handle(.scene(true))
        require(policy.shouldRun, "Active scene starts normally")
        policy.handle(.audioInterrupted)
        policy.handle(.scene(false)); policy.handle(.scene(true))
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
        policy.handle(.application(false)); policy.handle(.scene(true))
        require(!policy.shouldRun, "App focus and scene activity are independent")
        policy.handle(.application(true))
        require(policy.shouldRun, "Returning focus restores a paused foreground host")
        policy.handle(.routeDisconnected)
        require(policy.shouldRun, "Route loss requests original pause without freezing menu interaction")
        policy.handle(.audioInterrupted); policy.handle(.mediaServicesReset)
        policy.handle(.scene(false)); policy.handle(.userInteraction); policy.audioRebuilt()
        require(!policy.shouldRun, "A reset cannot bypass an inactive scene")
        policy.handle(.scene(true))
        require(!policy.shouldRun, "A background user request cannot arm later automatic playback")
        policy.handle(.userInteraction)
        require(policy.shouldRun, "An active explicit request completes recovery")
        policy.handle(.scene(false)); policy.handle(.scene(false)); policy.handle(.scene(true))
        require(policy.shouldRun, "Repeated suspension notifications are harmless")
        print("PASS: \(checks) lifecycle gating checks")
    }
}
