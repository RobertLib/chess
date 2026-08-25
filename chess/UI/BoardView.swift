//
//  BoardView.swift
//  chess
//
//  The interactive chessboard: frame with coordinates, highlights, animated
//  pieces, tap-to-move and drag & drop.
//

import SwiftUI

struct BoardView: View {
    let model: GameViewModel
    let theme: BoardTheme
    let showCoordinates: Bool
    let showLegalMoves: Bool

    @State private var dragState: DragState?

    private struct DragState {
        var from: Square
        var location: CGPoint
        var isBeyondTapThreshold = false
        /// True when touching down is what selected this square. Lifting the
        /// finger again then has to leave the selection alone: handing the same
        /// square back to `handleTap` would read as a second tap and toggle it
        /// straight off, which is what used to make tap-to-move impossible.
        var selectedOnTouchDown = false
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            // The same mapping and the same backdrop the review and the lesson
            // diagrams draw: the live board used to carry its own copy of the
            // frame, the coordinates, the checkered canvas and the square
            // arithmetic, which is four things to keep in step by hand.
            let geometry = BoardGeometry(size: size, orientation: model.orientation)

            ZStack(alignment: .topLeading) {
                BoardBackdrop(geometry: geometry, theme: theme, showCoordinates: showCoordinates)

                highlightLayer(geometry)
                    .accessibilityHidden(true)

                piecesLayer(geometry)
                    .accessibilityHidden(true)

                accessibilityLayer(geometry)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(boardGesture(geometry))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Chessboard", comment: "VoiceOver name for the board"))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Highlights

    @ViewBuilder
    private func highlightLayer(_ geometry: BoardGeometry) -> some View {
        let squareSize = geometry.squareSize

        // Last move.
        if let last = model.lastMove {
            ForEach([last.from, last.to], id: \.index) { square in
                RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                    .fill(theme.accent.opacity(0.34))
                    .frame(width: squareSize, height: squareSize)
                    .position(geometry.center(of: square))
                    .allowsHitTesting(false)
            }
        }

        // Check glow under the king.
        if let checked = model.checkedKingSquare {
            CheckGlow()
                .frame(width: squareSize * 1.5, height: squareSize * 1.5)
                .position(geometry.center(of: checked))
                .allowsHitTesting(false)
        }

        // Selection.
        if let selected = model.selectedSquare {
            RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                .fill(theme.accent.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: max(1.5, squareSize * 0.045))
                )
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: selected))
                .allowsHitTesting(false)
        }

        // Legal targets.
        if showLegalMoves {
            ForEach(model.legalTargetSquares, id: \.to.index) { move in
                Group {
                    if move.isCapture {
                        Circle()
                            .strokeBorder(theme.accent.opacity(0.85), lineWidth: max(2, squareSize * 0.07))
                            .frame(width: squareSize * 0.92, height: squareSize * 0.92)
                    } else {
                        Circle()
                            .fill(theme.accent.opacity(0.55))
                            .frame(width: squareSize * 0.30, height: squareSize * 0.30)
                    }
                }
                .position(geometry.center(of: move.to))
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
            }
        }

        // Hint.
        if let hint = model.hintMove {
            ForEach([hint.from, hint.to], id: \.index) { square in
                RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                    .strokeBorder(Color.cyan, lineWidth: max(2.5, squareSize * 0.07))
                    .shadow(color: .cyan.opacity(0.8), radius: 6)
                    .frame(width: squareSize, height: squareSize)
                    .position(geometry.center(of: square))
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
            }
        }
    }

    // MARK: Pieces

    /// Where a lifted piece is drawn: above the finger, so it stays visible.
    private func liftedPoint(_ drag: DragState, _ geometry: BoardGeometry) -> CGPoint {
        CGPoint(x: drag.location.x, y: drag.location.y - geometry.squareSize * 0.9)
    }

    @ViewBuilder
    private func piecesLayer(_ geometry: BoardGeometry) -> some View {
        let squareSize = geometry.squareSize

        // Dying (captured) pieces fade out underneath.
        ForEach(model.dyingPieces) { dying in
            DyingPieceView(piece: dying.piece)
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: dying.square))
                .allowsHitTesting(false)
        }

        // Faded stand-in marking the square a piece was picked up from.
        if let drag = dragState, drag.isBeyondTapThreshold,
           let lifted = model.pieces.first(where: { $0.square == drag.from }) {
            PieceView(piece: lifted.piece, shadow: false)
                .frame(width: squareSize, height: squareSize)
                .opacity(0.22)
                .position(geometry.center(of: drag.from))
                .allowsHitTesting(false)
        }

        // A dragged piece is this same view, moved under the finger, so that on
        // release SwiftUI animates it from where it was dropped rather than
        // from the square it came from.
        ForEach(model.pieces) { boardPiece in
            let drag = dragState
            let isDragged = drag?.from == boardPiece.square && drag?.isBeyondTapThreshold == true
            let isMoved = model.lastMove?.to == boardPiece.square
            let point = (isDragged ? drag.map { liftedPoint($0, geometry) } : nil)
                ?? geometry.center(of: boardPiece.square)
            PieceView(piece: boardPiece.piece)
                .frame(width: squareSize, height: squareSize)
                .scaleEffect(isDragged ? 1.5 : 1)
                .shadow(color: .black.opacity(isDragged ? 0.35 : 0),
                        radius: squareSize * 0.18, y: squareSize * 0.12)
                .position(point)
                .zIndex(isDragged ? 10 : (isMoved ? 2 : 1))
                .allowsHitTesting(false)
        }
    }

    // MARK: Accessibility

    /// VoiceOver's view of the board. Everything drawn above is decoration as
    /// far as accessibility is concerned, so the squares get their own layer of
    /// 64 labelled elements. They carry no gesture of their own, which leaves
    /// the drag recognizer on the container in charge of touch — VoiceOver
    /// reaches them through the accessibility action instead.
    private func accessibilityLayer(_ geometry: BoardGeometry) -> some View {
        ForEach(Square.all, id: \.index) { square in
            let piece = model.game.board.piece(at: square)
            let target = model.legalTargets.first { $0.to == square }
            Color.clear
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: square))
                .accessibilityElement()
                .accessibilityLabel(BoardSpeech.label(square: square, piece: piece))
                .accessibilityValue(accessibilityValue(for: square))
                .accessibilityHint(
                    BoardSpeech.hint(
                        square: square,
                        piece: piece,
                        isSelected: model.selectedSquare == square,
                        isLegalTarget: target != nil,
                        isCaptureTarget: target?.isCapture == true,
                        canSelect: piece.map { model.isInteractive(color: $0.color) } ?? false
                    ) ?? ""
                )
                .accessibilityAddTraits(model.selectedSquare == square ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.handleTap(on: square) }
        }
    }

    /// Extra context a sighted player reads off the highlights.
    private func accessibilityValue(for square: Square) -> String {
        var parts: [String] = []
        if model.checkedKingSquare == square {
            parts.append(String(localized: "in check", comment: "VoiceOver value on the checked king's square"))
        }
        if let last = model.lastMove, last.from == square || last.to == square {
            parts.append(String(localized: "last move", comment: "VoiceOver value on the squares of the move just played"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Gesture

    private func boardGesture(_ geometry: BoardGeometry) -> some Gesture {
        let squareSize = geometry.squareSize
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.pendingPromotion == nil else { return }

                if dragState == nil {
                    // Gesture start: select own piece under the finger.
                    guard let start = geometry.square(at: value.startLocation) else { return }
                    if let piece = model.game.board.piece(at: start), model.isInteractive(color: piece.color) {
                        let alreadySelected = model.selectedSquare == start
                        if !alreadySelected {
                            model.select(start)
                        }
                        dragState = DragState(
                            from: start,
                            location: value.location,
                            selectedOnTouchDown: !alreadySelected
                        )
                        model.isDragging = true
                    }
                }

                guard dragState != nil else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if dragState?.isBeyondTapThreshold == false, distance > squareSize * 0.25 {
                    // Pick the piece up off its square.
                    withAnimation(.easeOut(duration: 0.12)) {
                        dragState?.location = value.location
                        dragState?.isBeyondTapThreshold = true
                    }
                } else {
                    dragState?.location = value.location
                }
            }
            .onEnded { value in
                // Whatever the gesture turns out to have been, the finger is
                // up: an auto-flip held back for it may now go ahead.
                defer { model.isDragging = false }
                guard model.pendingPromotion == nil else {
                    dragState = nil
                    return
                }

                let distance = hypot(value.translation.width, value.translation.height)
                let tapped = geometry.square(at: value.location)

                let drag = dragState
                let travelled = distance > squareSize * 0.25

                if let drag, drag.isBeyondTapThreshold || travelled {
                    // Drop. Clearing the drag in the same transaction as the
                    // move means the piece flies from the finger to its
                    // destination — or back to its square if the drop is
                    // illegal — instead of jumping.
                    withAnimation(Motion.meaningful(.spring(duration: 0.35, bounce: 0.18))) {
                        if let target = tapped, target != drag.from {
                            _ = model.attemptMove(from: drag.from, to: target)
                        }
                        // Not a legal target: the selection stays put.
                        dragState = nil
                    }
                    return
                }

                // Nothing was picked up, because the gesture began on an empty
                // square or on a piece that is not the player's to move. Then
                // this counts as a tap only if it stayed on one square: a
                // finger that crossed from one square to another is a swipe
                // over the board, and handing the square it happened to lift
                // over to `handleTap` would move whatever piece is selected.
                //
                // The test is the square, not the distance — a tap with a
                // shaky finger travels a few points and still means the square
                // it landed on.
                if drag == nil {
                    let started = geometry.square(at: value.startLocation)
                    dragState = nil
                    if let tapped, started == tapped {
                        model.handleTap(on: tapped)
                    }
                    return
                }

                let justSelected = drag?.selectedOnTouchDown == true && tapped == drag?.from
                dragState = nil
                // Touching down already did the selecting; anything else is a
                // real tap and goes through the model.
                if let tapped, !justSelected {
                    model.handleTap(on: tapped)
                }
            }
    }
}

// MARK: - Supporting views

/// Fades and shrinks immediately after appearing.
private struct DyingPieceView: View {
    let piece: Piece
    @State private var gone = false

    var body: some View {
        PieceView(piece: piece)
            .scaleEffect(gone ? 0.4 : 1)
            .opacity(gone ? 0 : 1)
            .onAppear {
                withAnimation(Motion.meaningful(
                    .easeOut(duration: 0.32).delay(0.05),
                    reduced: .easeOut(duration: 0.2)
                )) {
                    gone = true
                }
            }
    }
}

/// Glow marking a checked king — it pulses, unless the reader has asked for
/// less motion, in which case it simply sits there and still marks the square.
private struct CheckGlow: View {
    @State private var pulsing = false

    var body: some View {
        // Asked here rather than in `onAppear` so that turning Reduce Motion on
        // or off reaches a glow that is already on screen.
        let mayPulse = Motion.allowsRepeatingDecoration
        return RadialGradient(
            colors: [Color.red.opacity(0.75), Color.red.opacity(0)],
            center: .center, startRadius: 0, endRadius: 40
        )
        .scaleEffect(pulsing ? 1.12 : 1)
        .opacity(pulsing ? 1.0 : 0.9)
        .animation(
            Motion.decorative(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)),
            value: pulsing
        )
        .onAppear { pulsing = mayPulse }
        .onChange(of: mayPulse) { _, new in pulsing = new }
    }
}
