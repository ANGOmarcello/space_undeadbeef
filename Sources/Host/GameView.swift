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
                                      action: { session.pauseGame() })
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            #endif
            .offset(x: -insets.leading, y: -insets.top)
            .onChange(of: viewport, initial: true) { _, value in session.configure(value) }
        }
        #if os(iOS)
        .background {
            GameHapticsSurface(session: session)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #endif
        #if os(watchOS)
        .overlay {
            WatchCornerControls(session: session)
                .ignoresSafeArea(.container)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if session.canPause {
                    Button(action: { session.pauseGame() }) {
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
            switch phase {
            case .active: session.setSceneActivity(.active)
            case .inactive: session.setSceneActivity(.inactive)
            case .background: session.setSceneActivity(.background)
            @unknown default: session.setSceneActivity(.background)
            }
            #if os(watchOS)
            isFocused = phase == .active && session.canPause
            #elseif os(tvOS)
            // The remote surface owns focus in both original menus and play.
            // Reapply it after returning from the system Home screen.
            isFocused = phase == .active
            #endif
        }
        .onDisappear { session.setSceneActive(false) }
        #if os(tvOS)
        .modifier(GameExitCommand(session: session))
        .defaultFocus($isFocused, true)
        #endif
        .alert("Progress could not be saved", isPresented: Binding(
            get: { session.persistenceError != nil },
            set: { if !$0 { session.dismissPersistenceError() } })) {
                Button("OK", role: .cancel) { session.dismissPersistenceError() }
            } message: {
                Text(session.persistenceError ?? "")
            }
        .onChange(of: isFocused) { _, focused in
            if !focused { session.inputController.resetHeldInputs() }
        }
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
            .accessibilityElement(children: .contain)
            .accessibilityHint("Move the target with the remote. Select taps; Play or Pause holds or releases a touch. With a controller, the left stick steers, the right stick aims, and A or the right trigger charges until released. Menu pauses.")
            // A Button otherwise derives its identifier from the virtual menu
            // children, changing its identity in AX snapshots between menus.
            .accessibilityIdentifier("game-canvas")
            .accessibilityLabel("SPACE UNDEADBEEF game")
            .accessibilityValue(Text(verbatim: uiTestAccessibilityValue))
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
            .onKeyPress(phases: [.down, .repeat, .up]) { press in handleKey(press) }
            .accessibilityHint("Touch or click and drag to play. Arrow keys aim; hold Space to charge and release to fire. Escape or P pauses. With a controller, the left stick steers, the right stick aims, and A or the right trigger charges until released.")
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
        .accessibilityElement(children: .contain)
        #if !os(tvOS)
        // TV publishes these on its actual remote Button, not this label's
        // nonfocusable container. Each platform has one stable canvas element.
        .accessibilityLabel("SPACE UNDEADBEEF game")
        .accessibilityIdentifier("game-canvas")
        .accessibilityValue(Text(verbatim: uiTestAccessibilityValue))
        #endif
        .accessibilityChildren {
            GameMenuAccessibility(session: session, size: size)
        }
    }

    private var uiTestAccessibilityValue: String {
        guard ProcessInfo.processInfo.environment["SDB_UI_TEST"] == "1" else { return "" }
        // Keep menuType last for the existing performance test's parser.
        #if os(iOS)
        let feedback = "; haptics \(session.hapticDeliveryStatus)"
        #else
        let feedback = ""
        #endif
        return "viewport \(Int(session.logicalSize.width)) × \(Int(session.logicalSize.height)); hostActive \(session.isActive); canPause \(session.canPause); focused \(isFocused); renderer \(session.usesMetalRenderer ? "Metal" : "CPU")\(feedback); menuType \(session.gameMenuType)"
    }

    #if !os(tvOS)
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                session.inputController.resetHeldInputs()
                session.drag(to: session.point(inView: value.location))
            }
            .onEnded { _ in session.endTouch() }
    }
    #endif

    #if !os(tvOS) && !os(watchOS)
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // A modifier pressed during a held game key must not swallow its up
        // edge and leave movement or charging stuck until focus changes.
        guard press.phase == .up || press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        if press.key == .escape || press.characters.lowercased() == "p" {
            guard press.phase == .down else { return .handled }
            return session.inputController.pause() ? .handled : .ignored
        }
        let key: GameInputKey
        switch press.key {
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .space: key = .fire
        default: return .ignored
        }
        if press.phase == .down { _ = session.requestUserResume() }
        // Holding is integrated by the fixed simulation tick. System repeat
        // events must not alter movement speed or restart a canceled charge.
        if press.phase != .repeat { session.inputController.setKey(key, pressed: press.phase != .up) }
        return .handled
    }
    #endif
}

#if os(tvOS)
/// Back/Menu pauses gameplay through the focused surface's root ancestor.
/// Menus retain normal system navigation because their handler is nil.
private struct GameExitCommand: ViewModifier {
    let session: GameSession

    func body(content: Content) -> some View {
        content.onExitCommand(perform: session.canPause ? {
            _ = session.inputController.pause()
        } : nil)
    }
}
#endif

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
