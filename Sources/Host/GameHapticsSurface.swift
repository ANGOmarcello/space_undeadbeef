//
//  GameHapticsSurface.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

#if os(iOS)
import SwiftUI
import UIKit

/// A renderer-independent window attachment. The transparent sentinel never
/// handles input; feedback interactions belong to its real, visible UIWindow.
@MainActor
struct GameHapticsSurface: UIViewRepresentable {
    let session: GameSession

    func makeUIView(context: Context) -> GameHapticsAttachmentView {
        let view = GameHapticsAttachmentView(frame: .zero)
        view.bind(to: session)
        return view
    }

    func updateUIView(_ view: GameHapticsAttachmentView, context: Context) {
        view.bind(to: session)
    }

    static func dismantleUIView(_ view: GameHapticsAttachmentView, coordinator: ()) {
        view.unbind()
    }
}

@MainActor
final class GameHapticsAttachmentView: UIView {
    private weak var session: GameSession?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isOpaque = false
        backgroundColor = .clear
    }

    func bind(to session: GameSession) {
        if self.session !== session {
            self.session?.detachHaptics(owner: self)
            self.session = session
        }
        updateAttachment()
    }

    func unbind() {
        session?.detachHaptics(owner: self)
        session = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAttachment()
    }

    private func updateAttachment() {
        guard let session else { return }
        guard let window else {
            session.detachHaptics(owner: self)
            return
        }
        session.attachHaptics(to: window, owner: self)
    }
}
#endif
