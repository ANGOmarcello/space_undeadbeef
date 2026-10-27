//
//  NativeControlsPolicyTests.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

import Foundation

@main
enum NativeControlsPolicyTests {
    static func main() {
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
            }
        }
        func near(_ first: Double, _ second: Double) -> Bool { abs(first - second) < 0.000001 }
        func step(_ policy: inout GameInputPolicy, _ sample: GameControllerSample = GameControllerSample(),
                  menu: Bool = false, delta: Double = 1.0 / 60) -> GameInputFrame {
            policy.frame(delta: delta, pointerUnitsPerSecond: 480, sample: sample, inMenu: menu)
        }
        for rate in [30, 60, 120] {
            var policy = GameInputPolicy()
            for _ in 0..<100 { policy.setKey(.right, pressed: true) }
            var distance = 0.0
            for _ in 0..<rate { distance += Double(step(&policy, delta: 1.0 / Double(rate)).pointerDelta.x) }
            require(near(distance, 480), "Held-key movement uses elapsed time at \(rate) Hz, not repeat count")
            policy.setKey(.right, pressed: false)
            require(step(&policy).pointerDelta == .zero, "Key-up stops movement")
        }
        var keys = GameInputPolicy()
        keys.setKey(.left, pressed: true); keys.setKey(.right, pressed: true)
        require(step(&keys).pointerDelta == .zero, "Opposing arrows cancel")
        keys.setKey(.left, pressed: false); keys.setKey(.down, pressed: true)
        let diagonal = step(&keys).pointerDelta
        require(near(hypot(Double(diagonal.x), Double(diagonal.y)), 8), "Diagonal input does not move faster")
        keys.reset()
        require(step(&keys).pointerDelta == .zero, "Focus reset clears held movement")

        require(GameInputPolicy.stick(CGPoint(x: 0.1, y: -0.1)) == .zero, "Stick drift stays inside the dead zone")
        require(GameInputPolicy.stick(CGPoint(x: Double.nan, y: 1)) == .zero, "Invalid analog input cannot move the target")
        let clipped = GameInputPolicy.stick(CGPoint(x: 10, y: 10))
        require(near(hypot(Double(clipped.x), Double(clipped.y)), 1), "Malformed large stick values stay normalized")
        var pad = GameInputPolicy()
        let left = GameControllerSample(leftStick: CGPoint(x: 0, y: 1))
        let steering = step(&pad, left)
        require(near(steering.steeringDelta, -1.0 / 60), "Left stick moves the original ship target upward")
        require(steering.pointerDelta == .zero, "Ship steering does not also move the targeting marker")
        let menu = step(&pad, left, menu: true)
        require(menu.steeringDelta == 0 && menu.pointerDelta.y < 0, "Left stick can address menus without steering the ship")
        let aiming = step(&pad, GameControllerSample(rightStick: CGPoint(x: 1, y: 1)))
        require(aiming.pointerDelta.x > 0 && aiming.pointerDelta.y < 0 && aiming.steeringDelta == 0,
                "Right stick moves only the reticle with screen-correct Y direction")
        require(step(&pad, GameControllerSample(dpad: CGPoint(x: -1, y: 0))).pointerDelta.x < 0,
                "D-pad remains a pointer fallback")
        require(step(&pad, GameControllerSample(rightStick: CGPoint(x: 1, y: 0)), delta: .nan).pointerDelta == .zero,
                "Invalid elapsed time cannot move the pointer")
        let bounded = step(&pad, GameControllerSample(rightStick: CGPoint(x: 1, y: 0)), delta: 10)
        require(near(Double(bounded.pointerDelta.x), 32), "Unexpected long tick cannot teleport the pointer")

        var fire = GameInputPolicy()
        let held = GameControllerSample(fire: true)
        require(!step(&fire, held).firePressed, "A controller already held at activation must release before arming")
        _ = step(&fire)
        require(step(&fire, held).firePressed, "A fresh controller press begins a charge")
        require(!step(&fire, held).firePressed, "Holding a charge does not repeat press edges")
        fire.setKey(.fire, pressed: true)
        require(!step(&fire).fireReleased, "Keyboard ownership prevents early release when the controller lets go")
        fire.setKey(.fire, pressed: false)
        require(step(&fire).fireReleased, "Releasing the final input fires once")
        require(!step(&fire).fireReleased, "A release cannot fire twice")
        fire.setKey(.fire, pressed: true)
        require(step(&fire).firePressed, "A fresh keyboard press can charge immediately")
        fire.reset()
        require(!step(&fire, held).firePressed && !step(&fire, held).fireReleased,
                "Interruptions cancel held charge without firing or replaying it")
        _ = step(&fire)
        require(step(&fire, held).firePressed, "Releasing and pressing again rearms after an interruption")

        var pause = GameInputPolicy()
        let paused = GameControllerSample(pause: true)
        require(!step(&pause, paused).pausePressed, "Held Menu does not pause immediately after reconnect")
        _ = step(&pause)
        require(step(&pause, paused).pausePressed, "A fresh Menu edge requests pause")
        require(!step(&pause, paused).pausePressed, "Held Menu cannot repeatedly toggle pause")
        pause.reset()
        require(!step(&pause, paused).pausePressed, "Resume requires a new Menu press")

        let action = GameMenuAction(identifier: "original-start", label: "Game Start",
                                    logicalFrame: CGRect(x: 120, y: 20, width: 240, height: 40), selected: false)
        require(action.viewFrame(in: CGSize(width: 960, height: 640), logicalSize: CGSize(width: 480, height: 320)) ==
                CGRect(x: 240, y: 40, width: 480, height: 80), "Accessibility frame follows the unchanged original drawing")
        require(action.viewFrame(in: .zero, logicalSize: CGSize(width: 480, height: 320)) == nil,
                "Unconfigured viewport cannot create accessibility geometry")
        require(action.viewFrame(in: CGSize(width: 100, height: 100), logicalSize: CGSize(width: Double.infinity, height: 320)) == nil,
                "Nonfinite viewport geometry fails closed")
        let selected = GameMenuAction(identifier: action.identifier, label: action.label,
                                      logicalFrame: action.logicalFrame, selected: true)
        require(selected != action && selected.id == action.id, "A selection update preserves stable accessible identity")
        let invalid = GameMenuAction(identifier: "invalid", label: "Invalid", logicalFrame: .zero, selected: false)
        require(invalid.viewFrame(in: CGSize(width: 960, height: 640), logicalSize: CGSize(width: 480, height: 320)) == nil,
                "Empty original menu rectangles do not become virtual controls")
        require(action.viewFrame(in: CGSize(width: 960, height: 640),
                                 logicalSize: CGSize(width: Double.leastNonzeroMagnitude, height: 320)) == nil,
                "Overflowing accessibility transforms fail closed")
        print("PASS: \(checks) native input and menu geometry policy checks")
    }
}
