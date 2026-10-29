//
//  GameMenuAccessibility.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

import CoreGraphics
import Foundation
#if !SDB_NATIVE_POLICY_TEST
import SwiftUI
#endif

/// A snapshot of one live original menu record. Identifiers are supplied and
/// validated by the engine; the host does not infer callbacks from coordinates.
struct GameMenuAction: Equatable, Identifiable {
    let identifier: String
    let label: String
    let logicalFrame: CGRect
    let selected: Bool
    var id: String { identifier }

    func viewFrame(in size: CGSize, logicalSize: CGSize) -> CGRect? {
        Self.viewFrame(logicalFrame, in: size, logicalSize: logicalSize)
    }

    static func viewFrame(_ logicalFrame: CGRect, in size: CGSize, logicalSize: CGSize) -> CGRect? {
        let values = [size.width, size.height, logicalSize.width, logicalSize.height,
                      logicalFrame.minX, logicalFrame.minY, logicalFrame.width, logicalFrame.height]
        guard values.allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              logicalSize.width > 0, logicalSize.height > 0,
              logicalFrame.width > 0, logicalFrame.height > 0 else { return nil }
        let xScale = size.width / logicalSize.width, yScale = size.height / logicalSize.height
        let frame = CGRect(x: logicalFrame.minX * xScale, y: logicalFrame.minY * yScale,
                           width: logicalFrame.width * xScale, height: logicalFrame.height * yScale)
        guard [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else { return nil }
        return frame
    }
}

#if !SDB_NATIVE_POLICY_TEST
/// Used only inside accessibilityChildren. These semantic controls do not draw,
/// intercept ordinary touches, or enter the native remote/keyboard focus tree.
@MainActor
struct GameMenuAccessibility: View {
    let session: GameSession
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if session.canRequestUserResume {
                // Suspended guest menus cannot finish their original animation.
                // This virtual control restarts scheduling only; the original
                // Pause/Resume or title choices remain in charge afterward.
                Button("Resume game") { _ = session.requestUserResume() }
                    .buttonStyle(.plain)
                    .frame(width: size.width, height: size.height)
                    .accessibilityIdentifier("resume-game-after-interruption")
            } else if session.isActive {
                ForEach(session.menuActions) { action in
                    if let frame = action.viewFrame(in: size, logicalSize: session.logicalSize) {
                        Button {
                            _ = session.activateMenuAction(action.identifier)
                        } label: {
                            Text(LocalizedStringKey(action.label))
                        }
                        .buttonStyle(.plain)
                        .frame(width: frame.width, height: frame.height)
                        // Preserve each virtual row's own accessibility frame.
                        .offset(x: frame.minX, y: frame.minY)
                        .accessibilityIdentifier(action.identifier)
                        .accessibilityAddTraits(action.selected ? .isSelected : [])
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Preserve a single Credits/Back row as a child rather than promoting
        // that button to the full virtual container's bounds.
        .accessibilityElement(children: .contain)
    }
}

/// The engine renders the original font; this native layer supplies only the
/// semantic web link and hit target, outside the game's drag gesture.
@MainActor
struct GameRestorationCredit: View {
    let session: GameSession
    let size: CGSize
    private static let destination = URL(string: "https://cammalleri.dev")!

    var body: some View {
        #if !os(tvOS)
        if let logicalFrame = session.restorationCreditFrame,
           let frame = GameMenuAction.viewFrame(logicalFrame, in: size, logicalSize: session.logicalSize) {
            Link(destination: Self.destination) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel("Modernization: cammalleri.dev")
            .accessibilityIdentifier("restoration-credit-link")
        }
        #endif
    }
}
#endif
