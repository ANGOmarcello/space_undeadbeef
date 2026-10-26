//
//  GameView.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

import SwiftUI

struct GameView: View {
    @State private var session = GameSession()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    #if os(watchOS)
    @State private var crownPosition = 0.0
    #endif
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                              height: geometry.size.height + insets.top + insets.bottom)
            let viewport = GameViewport(size: size, scale: displayScale,
                safeArea: CGRect(x: insets.leading, y: insets.top,
                                 width: geometry.size.width, height: geometry.size.height))
            ZStack {
                Color.black
                interactiveScreen(size: size)
                    .frame(width: size.width, height: size.height)
                if let failure = session.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .accessibilityIdentifier("runtime-failure")
                }
            }
            .frame(width: size.width, height: size.height)
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                if session.canPause {
                    CornerPauseButton(viewScale: size.width / session.logicalSize.width,
                                      action: session.pauseGame)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            #endif
            .offset(x: -insets.leading, y: -insets.top)
            .onChange(of: viewport, initial: true) { _, value in session.configure(value) }
        }
        #if os(watchOS)
        .overlay {
            WatchCornerControls(session: session)
                .ignoresSafeArea(.container)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if session.canPause {
                    Button(action: session.pauseGame) {
                        WatchPauseToolbarLabel()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pause game")
                    .accessibilityIdentifier("pause-game")
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.setActive(phase == .active)
            #if os(watchOS)
            isFocused = phase == .active && session.canPause
            #endif
        }
        .onDisappear { session.setActive(false) }
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .modifier(GameStatusBarVisibility())
        #endif
    }

    @ViewBuilder
    private func interactiveScreen(size: CGSize) -> some View {
        #if os(tvOS)
        Button { session.tapPointer() } label: { screen(size: size) }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onMoveCommand { direction in
                switch direction {
                case .left: session.movePointer(dx: -GameLayout.pointerStep, dy: 0)
                case .right: session.movePointer(dx: GameLayout.pointerStep, dy: 0)
                case .up: session.movePointer(dx: 0, dy: -GameLayout.pointerStep)
                case .down: session.movePointer(dx: 0, dy: GameLayout.pointerStep)
                @unknown default: break
                }
            }
            .onPlayPauseCommand { session.togglePointerTouch() }
            .accessibilityHint("Move the pointer with the remote. Select to tap. Play or Pause holds or releases a touch for dragging.")
        #elseif os(watchOS)
        screen(size: size)
            .gesture(dragGesture(size: size))
            .focusable(session.canPause)
            .focused($isFocused)
            .focusEffectDisabled()
            .digitalCrownRotation($crownPosition,
                                  from: GameCrownInput.rotationRange.lowerBound,
                                  through: GameCrownInput.rotationRange.upperBound,
                                  sensitivity: .medium, isContinuous: true,
                                  isHapticFeedbackEnabled: false,
                                  onChange: { _ in }, onIdle: session.endCrownSteering)
            .digitalCrownAccessory(.hidden)
            .onChange(of: crownPosition) { old, new in
                session.steerWithCrown(delta: GameCrownInput.wrappedDelta(from: old, to: new))
            }
            .onChange(of: session.canPause, initial: true) { _, canPause in
                isFocused = canPause && scenePhase == .active
            }
            .accessibilityHint("Turn the Digital Crown to steer up or down. Touch and drag to aim and fire.")
        #else
        screen(size: size)
            .gesture(dragGesture(size: size))
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onKeyPress(phases: [.down, .repeat, .up]) { press in
                if press.key == .space {
                    if press.phase == .up { session.endTouch() }
                    else { session.beginPointerTouch() }
                    return .handled
                }
                guard press.phase != .up else { return .ignored }
                switch press.key {
                case .leftArrow: session.movePointer(dx: -GameLayout.pointerStep, dy: 0)
                case .rightArrow: session.movePointer(dx: GameLayout.pointerStep, dy: 0)
                case .upArrow: session.movePointer(dx: 0, dy: -GameLayout.pointerStep)
                case .downArrow: session.movePointer(dx: 0, dy: GameLayout.pointerStep)
                default: return .ignored
                }
                return .handled
            }
            .accessibilityHint("Touch or click and drag to play. With a keyboard, use the arrow keys to move the pointer and hold Space to touch.")
        #endif
    }

    private func screen(size: CGSize) -> some View {
        ZStack {
            #if !os(watchOS)
            if session.usesMetalRenderer {
                MetalGameSurface(session: session)
                    .allowsHitTesting(false)
            }
            #endif
            SoftwareGameSurface(session: session, size: size)
            #if !os(watchOS)
            if session.showsPointer {
                Circle()
                    .stroke(.white, lineWidth: GameLayout.pointerStroke)
                    .frame(width: GameLayout.pointerDiameter * size.width / session.logicalSize.width,
                           height: GameLayout.pointerDiameter * size.height / session.logicalSize.height)
                    .position(x: session.pointer.x / session.logicalSize.width * size.width,
                              y: session.pointer.y / session.logicalSize.height * size.height)
                    .allowsHitTesting(false)
            }
            #endif
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SPACE UNDEADBEEF game")
        .accessibilityIdentifier("game-canvas")
        .accessibilityValue(ProcessInfo.processInfo.environment["SDB_UI_TEST"] == "1"
            ? "viewport \(Int(session.logicalSize.width)) × \(Int(session.logicalSize.height)); menuType \(session.gameMenuType)"
            : "")
    }

    #if !os(tvOS)
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in session.drag(to: session.point(inView: value.location)) }
            .onEnded { _ in session.endTouch() }
    }
    #endif
}

/// Only this leaf observes the changing software frame. Publishing a Watch
/// image must not also rebuild the enclosing gestures, Crown or toolbar.
private struct SoftwareGameSurface: View {
    let session: GameSession
    let size: CGSize

    var body: some View {
        if let frame = session.frame {
            Image(decorative: frame, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .frame(width: session.rasterViewSize.width, height: session.rasterViewSize.height)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .accessibilityIdentifier("original-game-frame")
        }
    }
}

#if os(iOS)
/// Keep the original full-screen corner control clear of system status content.
private struct GameStatusBarVisibility: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarVisibility(.hidden, for: .statusBar)
        } else {
            content.statusBarHidden()
        }
    }
}
#endif

#if os(watchOS)
/// Paint the original fold at the physical edge. The native leading toolbar
/// button owns input in this system-managed corner alongside the Watch clock.
private struct WatchCornerControls: View {
    let session: GameSession

    var body: some View {
        GeometryReader { geometry in
            if session.canPause {
                WatchPauseDecoration(viewScale: geometry.size.width / session.logicalSize.width)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
}
#endif
