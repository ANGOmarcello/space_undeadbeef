//
//  CornerPauseButton.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#if os(iOS) || os(watchOS)
import SwiftUI

/// The original p.png paper fold, redrawn as paths at the display's density.
/// The Watch mirrors the fold into its safe top-left corner, keeping P upright.
struct CornerPauseButton: View {
    enum Corner { case topLeading, topTrailing }

    let viewScale: CGFloat
    var corner: Corner = .topTrailing
    let action: () -> Void

    private enum Metrics {
        static let originalSide: CGFloat = 24
        static let originalFoldMargin = originalSide / 2
        static let minimumTouchSide: CGFloat = 44
    }

    var body: some View {
        let side = max(Metrics.minimumTouchSide, Metrics.originalSide * viewScale)
            + Metrics.originalFoldMargin * viewScale
        Button(action: action) {
            CornerPauseArtwork(corner: corner)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pause game")
        .accessibilityIdentifier("pause-game")
    }
}

private struct CornerPauseArtwork: View {
    let corner: CornerPauseButton.Corner

    var body: some View {
        Canvas { context, size in
            // Coordinates trace p.png after its original clockwise rotation.
            context.scaleBy(x: size.width / 24, y: size.height / 24)

            var fold = Path()
            fold.move(to: .zero)
            fold.addLine(to: CGPoint(x: 24, y: 24))
            fold.addLine(to: CGPoint(x: 12, y: 24))
            fold.closeSubpath()
            let cornerTransform = corner == .topLeading
                ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0)
                : .identity
            fold = fold.applying(cornerTransform)
            context.fill(fold, with: .color(Color(red: 109 / 255, green: 109 / 255, blue: 109 / 255)))

            var paper = Path()
            paper.move(to: .zero)
            paper.addLine(to: CGPoint(x: 24, y: 0))
            paper.addLine(to: CGPoint(x: 24, y: 24))
            paper.closeSubpath()
            paper = paper.applying(cornerTransform)
            context.fill(paper, with: .color(Color(red: 13 / 255, green: 38 / 255, blue: 0)))

            var crease = Path()
            crease.move(to: .zero)
            crease.addLine(to: CGPoint(x: 24, y: 24))
            crease = crease.applying(cornerTransform)
            context.stroke(crease, with: .color(Color(red: 56 / 255, green: 70 / 255, blue: 49 / 255)),
                           lineWidth: 0.75)

            // Preserve the original rounded P outline and counter. The inset
            // keeps it within the paper and clear of a rounded display corner;
            // the fold itself still reaches both physical screen edges.
            var letter = Path()
            letter.move(to: CGPoint(x: 15, y: 14))
            letter.addLine(to: CGPoint(x: 17, y: 14))
            letter.addLine(to: CGPoint(x: 17, y: 9))
            letter.addLine(to: CGPoint(x: 19, y: 9))
            letter.addCurve(to: CGPoint(x: 23, y: 5),
                            control1: CGPoint(x: 22, y: 9), control2: CGPoint(x: 23, y: 7))
            letter.addCurve(to: CGPoint(x: 19, y: 1),
                            control1: CGPoint(x: 23, y: 2), control2: CGPoint(x: 22, y: 1))
            letter.addCurve(to: CGPoint(x: 15, y: 4),
                            control1: CGPoint(x: 16, y: 1), control2: CGPoint(x: 15, y: 2))
            letter.closeSubpath()
            letter.move(to: CGPoint(x: 17, y: 3))
            letter.addLine(to: CGPoint(x: 19, y: 3))
            letter.addCurve(to: CGPoint(x: 21, y: 5),
                            control1: CGPoint(x: 20.5, y: 3), control2: CGPoint(x: 21, y: 3.5))
            letter.addCurve(to: CGPoint(x: 19, y: 7),
                            control1: CGPoint(x: 21, y: 6.5), control2: CGPoint(x: 20.5, y: 7))
            letter.addLine(to: CGPoint(x: 17, y: 7))
            letter.closeSubpath()
            letter = letter.applying(CGAffineTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 6.5, ty: 7))
            if corner == .topLeading {
                let bounds = letter.boundingRect
                letter = letter.applying(CGAffineTransform(
                    translationX: 24 - bounds.minX - bounds.maxX, y: 0))
            }
            context.fill(letter, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 194 / 255, blue: 29 / 255),
                                  Color(red: 254 / 255, green: 146 / 255, blue: 53 / 255)]),
                startPoint: CGPoint(x: 0, y: 7.5), endPoint: CGPoint(x: 0, y: 14)),
                style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}
#endif
