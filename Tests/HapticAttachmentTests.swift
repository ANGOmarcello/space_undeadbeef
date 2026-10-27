// Created by Angelo Cammalleri on 27.10.2026.
import Foundation

@main enum HapticAttachmentTests {
    static func main() {
        var checks = 0
        func require(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        let oldHost = NSObject(), replacementHost = NSObject()
        let firstWindow = NSObject(), secondWindow = NSObject()
        var attachment = GameHapticAttachmentPolicy()
        require(!attachment.shouldRebuild(interactionsAttached: false), "No native host means no generator creation")
        attachment.bind(owner: oldHost, target: firstWindow)
        require(attachment.shouldRebuild(interactionsAttached: false), "A host joining a window requires native interactions")
        require(attachment.generation == 0, "Binding alone does not claim generators were created")
        attachment.didRebuild()
        require(attachment.generation == 1 && !attachment.shouldRebuild(interactionsAttached: true),
                "Successful native construction is retained across ordinary frame updates")
        attachment.bind(owner: oldHost, target: firstWindow)
        require(!attachment.shouldRebuild(interactionsAttached: true), "Repeated layout updates do not recreate generators")
        attachment.bind(owner: replacementHost, target: firstWindow)
        require(!attachment.shouldRebuild(interactionsAttached: true), "A replacement host can retain the same window's interactions")
        require(!attachment.unbind(owner: oldHost), "Dismantling an old renderer/host cannot detach its replacement")
        require(attachment.owner == ObjectIdentifier(replacementHost) && attachment.target == ObjectIdentifier(firstWindow),
                "The replacement keeps ownership after a stale detach")
        attachment.invalidate()
        require(attachment.shouldRebuild(interactionsAttached: true), "A scene/audio reset rebuilds even apparently attached generators")
        attachment.didRebuild()
        require(attachment.generation == 2 && !attachment.shouldRebuild(interactionsAttached: true),
                "Reset recovery constructs one fresh native generation")
        require(attachment.shouldRebuild(interactionsAttached: false), "Lost UIKit interaction attachment is detected without a view identity change")
        attachment.didRebuild()
        require(attachment.generation == 3, "A repaired native attachment is observable")
        attachment.bind(owner: oldHost, target: secondWindow)
        require(attachment.shouldRebuild(interactionsAttached: true), "Moving windows replaces the native target even if old interactions survive")
        require(!attachment.unbind(owner: replacementHost), "Old-window dismantling cannot detach the new window")
        attachment.didRebuild()
        require(attachment.target == ObjectIdentifier(secondWindow) && attachment.generation == 4,
                "Only the current window is retained as feedback target")
        require(attachment.unbind(owner: oldHost), "The current host can release its attachment")
        require(attachment.owner == nil && attachment.target == nil && !attachment.shouldRebuild(interactionsAttached: false),
                "Removing the host stops future native construction")
        attachment.didRebuild()
        require(attachment.generation == 4, "A detached host cannot claim native recovery")
        attachment.bind(owner: replacementHost, target: firstWindow)
        attachment.didRebuild()
        require(attachment.generation == 5, "Reattaching after removal builds a fresh generation")
        attachment.clear()
        require(!attachment.unbind(owner: replacementHost) && !attachment.shouldRebuild(interactionsAttached: true),
                "An orphaned owner can be cleared without accepting stale callbacks")
        print("PASS: \(checks) haptic attachment ownership/recovery checks; no hardware, windows, settings or apps accessed")
    }
}
