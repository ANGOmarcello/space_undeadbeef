//
//  MetalGameSurface.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#if !os(watchOS)
import MetalKit
import SwiftUI

/// MetalKit drives presentation at the display cadence. Each callback lets the
/// session advance due fixed game steps and render once, without a SwiftUI update.
@MainActor
struct MetalGameSurface: View {
    let session: GameSession

    var body: some View {
        if let engine = session.engine {
            PlatformMetalSurface(session: session, engine: engine, isActive: session.isActive)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private final class MetalSurfaceCoordinator: NSObject, MTKViewDelegate {
    private var session: GameSession
    private var engine: SDBEngine
    private var metrics = MetalFrameMetrics()

    init(session: GameSession, engine: SDBEngine) {
        self.session = session
        self.engine = engine
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: engine.metalDevice)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = GameFrameClock.framesPerSecond
        view.autoResizeDrawable = false
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = 1
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        #if os(macOS)
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        view.layer?.isOpaque = true
        #else
        view.backgroundColor = .black
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        #endif
        view.delegate = self
        return view
    }

    func update(_ view: MTKView, session: GameSession, engine: SDBEngine, isActive: Bool) {
        self.session = session
        self.engine = engine
        if view.device !== engine.metalDevice {
            view.device = engine.metalDevice
        }

        updateDrawableSize(view)
        let shouldPause = !isActive
        if view.isPaused != shouldPause {
            metrics = MetalFrameMetrics()
            view.isPaused = shouldPause
        }
    }

    private func updateDrawableSize(_ view: MTKView) {
        let size = engine.rasterSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        if view.drawableSize != size { view.drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Raster dimensions come from the engine. Resizing this native view must
        // not feed back into simulation or replace the engine's viewport policy.
    }

    func draw(in view: MTKView) {
        guard session.isActive, engine.usesMetalRenderer, view.window != nil else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let steps = session.drawDisplayFrame(at: started)
        guard session.isActive, session.failure == nil else {
            view.isPaused = true
            return
        }
        // Viewport changes are applied by the session independently of SwiftUI's
        // representable updates. Follow the engine before obtaining a drawable.
        updateDrawableSize(view)
        var submitted = false
        if view.drawableSize == engine.rasterSize, let drawable = view.currentDrawable {
            submitted = engine.present(to: drawable)
        }
        if metrics.enabled {
            metrics.record(started: started, finished: ProcessInfo.processInfo.systemUptime,
                           simulationSteps: steps, submitted: submitted)
        }
    }
}

/// Opt-in aggregate diagnostics. Successful submissions are not measurements of
/// physical display scanout; callback work includes obtaining the drawable.
private struct MetalFrameMetrics {
    let enabled = ProcessInfo.processInfo.environment["SDB_PERFORMANCE_LOG"] == "1"
    private static let reportInterval = 2.0
    private static let lateInterval = GameFrameClock.simulationStep * 1.5
    private var began: TimeInterval?
    private var previous: TimeInterval?
    private var callbacks = 0
    private var simulations = 0
    private var submissions = 0
    private var lateCallbacks = 0
    private var longestGap = 0.0
    private var totalWork = 0.0
    private var longestWork = 0.0

    mutating func record(started: TimeInterval, finished: TimeInterval,
                         simulationSteps: Int, submitted: Bool) {
        guard enabled else { return }
        if began == nil {
            began = started
            previous = started
            return
        }
        if let previous {
            let gap = started - previous
            longestGap = max(longestGap, gap)
            if gap > Self.lateInterval { lateCallbacks += 1 }
        }
        previous = started
        callbacks += 1
        simulations += simulationSteps
        submissions += submitted ? 1 : 0
        let work = max(0, finished - started)
        totalWork += work
        longestWork = max(longestWork, work)
        guard let began, started - began >= Self.reportInterval else { return }
        let elapsed = started - began
        NSLog("SDB_PERFORMANCE host callbacks=%.1fHz simulations=%.1fHz submissions=%.1fHz late=%ld maxGap=%.2fms workMean=%.2fms workMax=%.2fms",
              Double(callbacks) / elapsed, Double(simulations) / elapsed,
              Double(submissions) / elapsed, lateCallbacks, longestGap * 1000,
              totalWork / Double(callbacks) * 1000, longestWork * 1000)
        self.began = started
        callbacks = 0
        simulations = 0
        submissions = 0
        lateCallbacks = 0
        longestGap = 0
        totalWork = 0
        longestWork = 0
    }
}

#if os(macOS)
@MainActor
private struct PlatformMetalSurface: NSViewRepresentable {
    let session: GameSession
    let engine: SDBEngine
    let isActive: Bool

    func makeCoordinator() -> MetalSurfaceCoordinator {
        MetalSurfaceCoordinator(session: session, engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, session: session, engine: engine, isActive: isActive)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: MetalSurfaceCoordinator) {
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#else
@MainActor
private struct PlatformMetalSurface: UIViewRepresentable {
    let session: GameSession
    let engine: SDBEngine
    let isActive: Bool

    func makeCoordinator() -> MetalSurfaceCoordinator {
        MetalSurfaceCoordinator(session: session, engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, session: session, engine: engine, isActive: isActive)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: MetalSurfaceCoordinator) {
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#endif
#endif
