//
//  GameCrownInput.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

/// Crown values are relative. Keep the requested destination while the original
/// spring catches up, then anchor the next gesture to the ship's actual position.
struct GameCrownInput {
    /// One full playable ship range in either direction. SwiftUI wraps this
    /// finite control range; an infinite range produces invalid Crown geometry.
    static let rotationRange = -1.0...1.0
    private(set) var targetNormalizedY: Double?
    private var startsNewGesture = true

    static func wrappedDelta(from previous: Double, to current: Double) -> Double {
        guard previous.isFinite, current.isFinite else { return .nan }
        let span = rotationRange.upperBound - rotationRange.lowerBound
        var delta = (current - previous).truncatingRemainder(dividingBy: span)
        if delta > span / 2 { delta -= span }
        else if delta < -span / 2 { delta += span }
        return delta
    }

    mutating func target(for delta: Double, shipNormalizedY: Double) -> Double? {
        guard delta.isFinite, shipNormalizedY.isFinite else {
            reset()
            return nil
        }
        guard delta != 0 else { return nil }
        let ship = min(1, max(0, shipNormalizedY))
        let pending = targetNormalizedY ?? ship
        // An opposite input must not first consume distance to a destination
        // the original spring has not reached yet. Preserve that spring's
        // inertia, but put the new destination on the requested side.
        let reversesPendingTravel = (pending - ship) * delta < 0
        let anchor = startsNewGesture || reversesPendingTravel ? ship : pending
        let target = min(1, max(0, anchor + delta))
        targetNormalizedY = target
        startsNewGesture = false
        return target
    }

    /// Idle ends accumulation, not the accepted spring destination. In
    /// particular, a short tick may become idle before the next fixed step.
    mutating func becameIdle() { startsNewGesture = true }

    mutating func reset() {
        targetNormalizedY = nil
        startsNewGesture = true
    }
}
