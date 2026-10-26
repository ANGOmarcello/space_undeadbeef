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
    private var metrics = GameFrameMetrics(renderer: .metal)

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
        #if os(iOS)
        session.attachHaptics(to: view)
        #endif
        return view
    }

    func update(_ view: MTKView, session: GameSession, engine: SDBEngine, isActive: Bool) {
        #if os(iOS)
        if self.session !== session { self.session.detachHaptics(from: view) }
        #endif
        self.session = session
        self.engine = engine
        #if os(iOS)
        session.attachHaptics(to: view)
        #endif
        if view.device !== engine.metalDevice {
            view.device = engine.metalDevice
        }

        updateDrawableSize(view)
        let shouldPause = !isActive
        if view.isPaused != shouldPause {
            metrics = GameFrameMetrics(renderer: .metal)
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

    #if os(iOS)
    func detachHaptics(from view: MTKView) {
        session.detachHaptics(from: view)
    }
    #endif

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
                           simulationSteps: steps, producedFrame: submitted,
                           menuType: session.gameMenuType)
        }
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
        #if os(iOS)
        coordinator.detachHaptics(from: view)
        #endif
        view.delegate = nil
        view.releaseDrawables()
    }
}
#endif
#endif
