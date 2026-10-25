//
//  MetalGameSurface.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#if !os(watchOS)
import MetalKit
import SwiftUI

/// Presents frames already rendered by the engine. GameSession owns timing and
/// simulation; this view never advances guest code or creates a display timer.
@MainActor
struct MetalGameSurface: View {
    let engine: SDBEngine
    let revision: UInt64

    var body: some View {
        PlatformMetalSurface(engine: engine, revision: revision)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
private final class MetalSurfaceCoordinator: NSObject, MTKViewDelegate {
    private var engine: SDBEngine
    private var lastRevision: UInt64?

    init(engine: SDBEngine) {
        self.engine = engine
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: engine.metalDevice)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
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

    func update(_ view: MTKView, engine: SDBEngine, revision: UInt64) {
        let engineChanged = self.engine !== engine
        self.engine = engine
        if view.device !== engine.metalDevice {
            view.device = engine.metalDevice
        }

        let size = engine.rasterSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let sizeChanged = view.drawableSize != size
        if sizeChanged { view.drawableSize = size }
        guard engineChanged || sizeChanged || lastRevision != revision else { return }
        lastRevision = revision
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Raster dimensions come from the engine. Resizing this native view must
        // not feed back into simulation or replace the engine's viewport policy.
    }

    func draw(in view: MTKView) {
        guard engine.usesMetalRenderer,
              view.drawableSize == engine.rasterSize,
              let drawable = view.currentDrawable else { return }
        _ = engine.present(to: drawable)
    }
}

#if os(macOS)
@MainActor
private struct PlatformMetalSurface: NSViewRepresentable {
    let engine: SDBEngine
    let revision: UInt64

    func makeCoordinator() -> MetalSurfaceCoordinator {
        MetalSurfaceCoordinator(engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, engine: engine, revision: revision)
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
    let engine: SDBEngine
    let revision: UInt64

    func makeCoordinator() -> MetalSurfaceCoordinator {
        MetalSurfaceCoordinator(engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, engine: engine, revision: revision)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: MetalSurfaceCoordinator) {
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
}
#endif
#endif
