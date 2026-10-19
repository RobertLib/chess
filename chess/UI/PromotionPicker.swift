//
//  PromotionPicker.swift
//  chess
//
//  The four pieces a pawn may become, offered over a dimmed board. Shared
//  by every board that takes moves.
//

import SwiftUI

struct PromotionPickerOverlay: View {
    let color: PieceColor
    let theme: BoardTheme
    /// True when the side promoting sits across the table, with its pieces
    /// drawn upside down: the card turns to face that player the way their
    /// pieces do. Only the card turns — the dimming under it runs into the
    /// safe areas, which are not the same at the top and the bottom, and
    /// turned with it would leave a strip of the board undimmed.
    var facesFarSide = false
    let onPick: (PieceKind) -> Void
    let onCancel: () -> Void

    /// The picker lays four pieces out in a row, and at the design's size that
    /// row is wider than the narrowest phone the app runs on: 4 x (62 + 2 x 8)
    /// tile, three 10 pt gaps and the card's own 22 pt inset come to 386 pt
    /// against the 375 pt of an iPhone SE or a mini, which pushed the card's
    /// rounded corners and its border off both edges of the screen. So the
    /// tile is measured against the width actually on offer and only shrinks
    /// where it has to — on every wider phone it is the 62 pt it always was.
    private enum PromotionMetrics {
        static let tile: CGFloat = 62
        static let tilePadding: CGFloat = 8
        static let spacing: CGFloat = 10
        static let cardPadding: CGFloat = 22
        /// Margin the card keeps to the edges of the screen. It is what the
        /// design already had on the phone it was drawn against, so on every
        /// screen wide enough the arithmetic below returns the full 62 pt and
        /// nothing about the picker changes.
        static let screenInset: CGFloat = 8

        /// Side of one piece for a picker `width` points wide.
        static func tileSide(forWidth width: CGFloat) -> CGFloat {
            let chrome = 2 * screenInset + 2 * cardPadding + 3 * spacing + 8 * tilePadding
            return max(36, min(tile, (width - chrome) / 4))
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            GeometryReader { proxy in
                promotionCard(tile: PromotionMetrics.tileSide(forWidth: proxy.size.width))
                    .rotationEffect(facesFarSide ? .degrees(180) : .zero)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func promotionCard(tile: CGFloat) -> some View {
        VStack(spacing: 14) {
            Text("Pawn Promotion")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: PromotionMetrics.spacing) {
                ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                    Button {
                        onPick(kind)
                    } label: {
                        PieceView(piece: Piece(color, kind))
                            .frame(width: tile, height: tile)
                            .accessibilityHidden(true)
                            .padding(PromotionMetrics.tilePadding)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Piece(color, kind).spokenName)
                }
            }
        }
        .padding(PromotionMetrics.cardPadding)
        // VoiceOver treats the card as the only thing on screen while it is
        // up: without this, focus could wander to Undo or Resign underneath
        // and act on a game that is waiting for an answer here. The escape
        // gesture stands in for the tap on the dimmed board.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onCancel() }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.backgroundBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        )
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
