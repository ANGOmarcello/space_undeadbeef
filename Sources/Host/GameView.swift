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
                    .overlay {
                        GameRestorationCredit(session: session, size: size)
                    }
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
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: session.setSceneActivity(.active)
            case .inactive: session.setSceneActivity(.inactive)
            case .background: session.setSceneActivity(.background)
            @unknown default: session.setSceneActivity(.background)
            }
            #if os(watchOS)
            isFocused = phase == .active && session.canSteerShip
            #endif
        }
        .onDisappear { session.setSceneActive(false) }
        #if os(tvOS)
        .modifier(GameExitCommand(session: session))
        #endif
        .alert("Progress could not be saved", isPresented: Binding(
            get: { session.persistenceError != nil },
            set: { if !$0 { session.dismissPersistenceError() } })) {
                Button("OK", role: .cancel) { session.dismissPersistenceError() }
            } message: {
                Text(session.persistenceError ?? "")
            }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                session.inputController.resetHeldInputs()
                #if os(watchOS)
                session.endCrownSteering()
                #endif
            }
        }
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .modifier(GameStatusBarVisibility())
        #endif
    }

    @ViewBuilder
    private func interactiveScreen(size: CGSize) -> some View {
        #if os(tvOS)
        ZStack {
            screen(size: size).accessibilityHidden(true)
            GameTVInputSurface(session: session, size: size)
        }
        #elseif os(watchOS)
        @Bindable var crownSession = session
        screen(size: size)
            .gesture(dragGesture(size: size))
            .focusable(session.canSteerShip)
            .focused($isFocused)
            .focusEffectDisabled()
            .digitalCrownRotation($crownSession.crownPosition,
                                  from: GameCrownInput.rotationRange.lowerBound,
                                  through: GameCrownInput.rotationRange.upperBound,
                                  sensitivity: .medium, isContinuous: true,
                                  isHapticFeedbackEnabled: false,
                                  onChange: { _ in }, onIdle: session.crownBecameIdle)
            .digitalCrownAccessory(.hidden)
            .onChange(of: session.canSteerShip, initial: true) { _, canSteer in
                isFocused = canSteer && scenePhase == .active
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
            #if !os(watchOS) && !os(tvOS)
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
        #if !os(tvOS)
        .accessibilityChildren {
            GameMenuAccessibility(session: session, size: size)
        }
        #endif
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

// TV keeps the original renderer and delegates focus/touch routing to UIKit.
// Created by Angelo Cammalleri on 29.10.2026.
#if os(tvOS)
import UIKit

private struct GameTVInputSurface: UIViewRepresentable {
    let session: GameSession
    let size: CGSize
    func makeUIView(context: Context) -> TVGameInputView { TVGameInputView(session: session) }
    func updateUIView(_ view: TVGameInputView, context: Context) { view.update(size: size) }
    static func dismantleUIView(_ view: TVGameInputView, coordinator: ()) { view.cancelInput() }
}

@MainActor
private final class TVGameInputView: UIView {
    private weak var session: GameSession?
    private var buttons: [String: TVMenuButton] = [:]
    private var actionIDs: [String] = []
    private var clickOwnsTouch = false
    private var gameplay = false
    private lazy var remoteTouch = TVRemoteTouchRecognizer { [weak self] phase, location in
        guard let self, self.gameplay, let session = self.session else { return }
        switch phase {
        case .began:
            session.inputController.resetHeldInputs()
            session.drag(to: session.point(inView: location))
        case .changed: session.drag(to: session.point(inView: location))
        case .ended: session.endTouch()
        default: session.cancelTouch()
        }
    }

    init(session: GameSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityIdentifier = "game-canvas"
        accessibilityLabel = "SPACE UNDEADBEEF game"
        remoteTouch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue),
                                        NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(remoteTouch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var canBecomeFocused: Bool { gameplay }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if gameplay { return [self] }
        return buttons.values.filter { !$0.isHidden }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }.prefix(1).map { $0 }
    }
    override var accessibilityValue: String? {
        get {
            guard ProcessInfo.processInfo.environment["SDB_UI_TEST"] == "1", let session else { return nil }
            let focused = isFocused || buttons.values.contains(where: \.isFocused)
            return "hostActive \(session.isActive); canPause \(session.canPause); focused \(focused); pointerVisible \(session.showsPointer); touching \(session.isTouching); aiming \(session.engine?.shipAiming ?? false); menuType \(session.gameMenuType)"
        }
        set {}
    }
    func update(size: CGSize) {
        guard let session else { return }
        let previousGameplay = gameplay
        gameplay = session.isActive && session.gameMenuType == 0 && session.persistenceError == nil
        remoteTouch.isEnabled = gameplay
        isAccessibilityElement = gameplay
        let actions = session.isActive && session.persistenceError == nil ? session.menuActions : []
        let ids = actions.map(\.identifier)
        for id in actionIDs where !ids.contains(id) { buttons.removeValue(forKey: id)?.removeFromSuperview() }
        for action in actions {
            let button: TVMenuButton
            if let existing = buttons[action.identifier] { button = existing }
            else {
                button = TVMenuButton(type: .custom)
                button.accessibilityIdentifier = action.identifier
                let id = action.identifier
                button.addAction(UIAction { [weak self] _ in
                    _ = self?.session?.activateMenuAction(id)
                }, for: .primaryActionTriggered)
                buttons[id] = button
                addSubview(button)
            }
            button.accessibilityLabel = action.label
            button.isSelected = action.selected
            if let frame = action.viewFrame(in: size, logicalSize: session.logicalSize) {
                button.frame = frame
                button.focusLineWidth = frame.height / 12
                button.isHidden = false
            } else { button.isHidden = true }
        }
        let changed = ids != actionIDs || gameplay != previousGameplay
        actionIDs = ids
        if changed { setNeedsFocusUpdate(); updateFocusIfNeeded() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInput() }
        else { setNeedsFocusUpdate(); updateFocusIfNeeded() }
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.previouslyFocusedView === self && context.nextFocusedView !== self { cancelInput() }
    }
    func cancelInput() {
        clickOwnsTouch = false
        session?.inputController.resetHeldInputs()
        session?.cancelTouch()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard gameplay, let session else { super.pressesBegan(presses, with: event); return }
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .select:
                if !session.isTouching { session.drag(to: session.pointer); clickOwnsTouch = session.isTouching }
            case .playPause:
                if session.isTouching { session.endTouch() }
                else { session.drag(to: session.pointer) }
            case .upArrow, .downArrow, .leftArrow, .rightArrow:
                let step = GameLayout.pointerStep
                let dx = press.type == .leftArrow ? -step : press.type == .rightArrow ? step : 0
                let dy = press.type == .upArrow ? -step : press.type == .downArrow ? step : 0
                if session.isTouching {
                    let point = CGPoint(x: min(session.logicalSize.width, max(0, session.pointer.x + dx)),
                                        y: min(session.logicalSize.height, max(0, session.pointer.y + dy)))
                    session.drag(to: point)
                } else if dy != 0 {
                    session.steerWithCrown(delta: Double(dy / session.logicalSize.height))
                }
            default: unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }), clickOwnsTouch {
            session?.endTouch(); clickOwnsTouch = false
        }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        cancelInput()
        super.pressesCancelled(presses, with: event)
    }
}

@MainActor
private final class TVMenuButton: UIButton {
    var focusLineWidth: CGFloat = 1 { didSet { updateDecoration() } }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateDecoration()
    }
    private func updateDecoration() {
        // The original Options selection/credit color; original glyphs stay drawn by the game.
        let color = UIColor(red: 1, green: 192.0 / 255, blue: 128.0 / 255, alpha: 1)
        layer.borderColor = color.cgColor
        layer.borderWidth = isFocused ? focusLineWidth : 0
        backgroundColor = isFocused ? color.withAlphaComponent(0.16) : .clear
    }
}

/// Only gameplay owns this recognizer. Menus retain the native focus engine.
@MainActor
private final class TVRemoteTouchRecognizer: UIGestureRecognizer {
    private var tracked: UITouch?
    private let forward: (UIGestureRecognizer.State, CGPoint) -> Void
    init(forward: @escaping (UIGestureRecognizer.State, CGPoint) -> Void) {
        self.forward = forward
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        state = .began
        forward(.began, touch.location(in: view))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = .changed
        forward(.changed, tracked.location(in: view))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        forward(.ended, tracked.location(in: view))
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        forward(.cancelled, .zero)
        state = .cancelled
    }
    override func reset() {
        if tracked != nil && state != .ended { forward(.cancelled, .zero) }
        tracked = nil
        super.reset()
    }
}
#endif
