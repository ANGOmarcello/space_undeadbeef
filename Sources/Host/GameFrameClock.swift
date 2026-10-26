//
//  GameFrameClock.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 26.10.2026.
//

import Foundation

/// Fixed game time is independent of the display's refresh rate. Missed frames
/// catch up within a small bound; resuming a scene starts a new timing epoch.
struct GameFrameClock {
    static let framesPerSecond = 60
    static let simulationStep = 1.0 / Double(framesPerSecond)
    static let maximumCatchUpSteps = 4
    /// MetalKit callbacks arrive close to, rather than exactly on, a refresh
    /// boundary. Borrow at most one millisecond, preserving the debt below.
    static let schedulingLeeway = 0.001

    private var lastTime: TimeInterval?
    private var accumulatedTime = 0.0

    mutating func reset(at time: TimeInterval? = nil) {
        lastTime = time.flatMap { $0.isFinite ? $0 : nil }
        accumulatedTime = 0
    }

    mutating func steps(at time: TimeInterval) -> Int {
        guard time.isFinite else { return 0 }
        guard let previous = lastTime else {
            lastTime = time
            return 0
        }
        lastTime = time
        let elapsed = time - previous
        guard elapsed >= 0 else {
            accumulatedTime = 0
            return 0
        }
        accumulatedTime += min(elapsed, Self.simulationStep * Double(Self.maximumCatchUpSteps))
        // A slightly early callback should not repeat a pose and require two
        // steps on the next refresh. Negative carry repays any borrowed time;
        // clamping it to zero would make a fast/jittered display speed up play.
        // The additional tolerance covers timestamp rounding at a large uptime.
        let roundingTolerance = Self.simulationStep * 0.000001
        let count = max(0, min(Self.maximumCatchUpSteps,
                        Int((accumulatedTime + Self.schedulingLeeway + roundingTolerance) / Self.simulationStep)))
        accumulatedTime -= Double(count) * Self.simulationStep
        return count
    }
}

/// Opt-in, constant-space host diagnostics. Metal outputs count successful
/// drawable submissions; software outputs count published images. Neither rate
/// measures display scanout. Callback work includes rendering and native
/// submission/publication, but not later SwiftUI composition or GPU completion.
struct GameFrameMetrics {
    enum Renderer: String {
        case metal, software

        var outputLabel: String { self == .metal ? "submissions" : "images" }
    }

    private static let loggingEnabled = ProcessInfo.processInfo.environment["SDB_PERFORMANCE_LOG"] == "1"
    private static let reportInterval = 2.0
    private static let lateInterval = GameFrameClock.simulationStep * 1.5

    let enabled = Self.loggingEnabled
    private let renderer: Renderer
    private var menuType: Int?
    private var began: TimeInterval?
    private var previous: TimeInterval?
    private var callbacks = 0
    private var simulations = 0
    private var outputs = 0
    private var zeroStepCallbacks = 0
    private var catchUpCallbacks = 0
    private var lateCallbacks = 0
    private var longestGap = 0.0
    private var totalWork = 0.0
    private var longestWork = 0.0

    init(renderer: Renderer) { self.renderer = renderer }

    mutating func record(started: TimeInterval, finished: TimeInterval,
                         simulationSteps: Int, producedFrame: Bool, menuType: Int) {
        guard enabled, started.isFinite, finished.isFinite else { return }
        if self.menuType != menuType {
            // A report contains one original menu phase only. Transition work
            // does not get averaged into the next gameplay/title window.
            self = GameFrameMetrics(renderer: renderer)
            self.menuType = menuType
        }
        guard let began, let previous else {
            self.began = started
            self.previous = started
            return
        }
        let gap = started - previous
        guard gap >= 0 else {
            self = GameFrameMetrics(renderer: renderer)
            return
        }
        self.previous = started
        longestGap = max(longestGap, gap)
        if gap > Self.lateInterval { lateCallbacks += 1 }
        callbacks += 1
        simulations += simulationSteps
        outputs += producedFrame ? 1 : 0
        zeroStepCallbacks += simulationSteps == 0 ? 1 : 0
        catchUpCallbacks += simulationSteps > 1 ? 1 : 0
        let work = max(0, finished - started)
        totalWork += work
        longestWork = max(longestWork, work)
        let elapsed = started - began
        guard elapsed >= Self.reportInterval else { return }
        NSLog("SDB_PERFORMANCE host renderer=%@ menuType=%ld callbacks=%.1fHz simulations=%.1fHz %@=%.1fHz late=%ld zeroSteps=%ld catchUp=%ld maxGap=%.2fms workMean=%.2fms workMax=%.2fms",
              renderer.rawValue, menuType, Double(callbacks) / elapsed, Double(simulations) / elapsed,
              renderer.outputLabel, Double(outputs) / elapsed, lateCallbacks,
              zeroStepCallbacks, catchUpCallbacks, longestGap * 1000,
              totalWork / Double(callbacks) * 1000, longestWork * 1000)
        self = GameFrameMetrics(renderer: renderer)
        self.menuType = menuType
        self.began = started
        self.previous = started
    }
}
