//
//  BoardView.swift
//  chess
//
//  The interactive chessboard: frame with coordinates, highlights, animated
//  pieces, tap-to-move and drag & drop.
//

import SwiftUI

struct BoardView<Model: PlayableBoard>: View {
    let model: Model
    let theme: BoardTheme
    let showCoordinates: Bool
    let showLegalMoves: Bool

    @State private var dragState: DragState?
    /// True while a finger is down. A gesture the system cancels — Control
    /// Center pulled down, a call coming in — never reaches `onEnded`, and
    /// this resetting is the only sign of it.
    @GestureState private var isTouching = false

    private struct DragState {
        var from: Square
        /// The drawn piece the finger is on, by identity. The square cannot
        /// say it: a premove is lined up while the computer is thinking, and
        /// its reply may capture on that very square with the finger still
        /// down — the square then holds the computer's piece, which used to
        /// be drawn lifted under the player's finger.
        var pieceID: UUID?
        var location: CGPoint
        var isBeyondTapThreshold = false
        /// True when touching down is what selected this square. Lifting the
        /// finger again then has to leave the selection alone: handing the same
        /// square back to `handleTap` would read as a second tap and toggle it
        /// straight off, which is what used to make tap-to-move impossible.
        var selectedOnTouchDown = false
        /// True when the piece under the finger is itself a target of the
        /// selection — the own rook a Chess960 king castles onto. Selecting it
        /// on touch-down would make castling by tap impossible, so it is only
        /// selected if the finger goes on to pick it up.
        var selectsOnPickUp = false
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

                arrowLayer(geometry)
                    .accessibilityHidden(true)

                // A view of its own, so that it is only rebuilt when what it
                // reads changes. Inline, it was part of this body, which runs
                // again for every frame of a drag — 64 elements with a label,
                // a value and a hint each, every one a string lookup, rebuilt
                // sixty times a second while a finger moved a piece.
                BoardAccessibilityLayer(model: model, geometry: geometry)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(boardGesture(geometry))
            .onChange(of: isTouching) { _, touching in
                // An ended gesture has cleared the drag by now; one still
                // here was cancelled, and the lifted piece goes back home.
                guard !touching, dragState != nil else { return }
                withAnimation(Motion.meaningful(.spring(duration: 0.35, bounce: 0.18))) { dragState = nil }
                model.isDragging = false
            }
            // Turning the device or resizing a Split View can swap the screen
            // to its other layout mid-drag, and the board there is a new view:
            // this one's gesture never ends at all. Left believing a finger is
            // still down, the model held the two-player auto-flip back until
            // some later drag happened to end.
            .onDisappear {
                if dragState != nil { model.isDragging = false }
            }
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
        // Built afresh on every read, so read once.
        let decorations = model.decorations

        // A variant's special squares, under everything else.
        ForEach(decorations.zone, id: \.index) { square in
            RoundedRectangle(cornerRadius: squareSize * 0.08, style: .continuous)
                .strokeBorder(Design.gold.opacity(0.75), lineWidth: max(1.5, squareSize * 0.05))
                .background(Design.gold.opacity(0.14))
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: square))
                .allowsHitTesting(false)
        }

        // Last move.
        if let last = model.lastMove {
            ForEach(model.position.highlightSquares(of: last), id: \.index) { square in
                RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                    .fill(theme.accent.opacity(0.34))
                    .frame(width: squareSize, height: squareSize)
                    .position(geometry.center(of: square))
                    .allowsHitTesting(false)
            }
        }

        // Check glow under the king.
        if let checked = model.checkedKingSquare {
            CheckGlow(radius: squareSize * 0.75)
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

        // Where a lifted piece is dropped: the square under the finger, which
        // is not the one the piece is drawn over. It is drawn lifted above the
        // finger so that the finger does not hide it, and with nothing marked
        // here it looked as if it would land a square higher than it did.
        // The selection's shape and colour, lighter, so the two read as from
        // and to; and shown on any square, legal or not, so that with the
        // legal moves hidden it gives none of them away.
        if let target = dropTarget(geometry) {
            RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.9), lineWidth: max(1.5, squareSize * 0.045))
                )
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: target))
                .allowsHitTesting(false)
        }

        // Legal targets.
        if showLegalMoves {
            ForEach(model.legalTargetSquares, id: \.to.index) { move in
                Group {
                    // A ring for anything standing on the square: a capture,
                    // or the own rook a Chess960 king castles onto.
                    if move.isCapture || model.position.piece(at: move.to) != nil {
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

        // Marked squares — a puzzle's right or wrong answer, a hint's piece.
        ForEach(decorations.marks, id: \.self) { mark in
            RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                .fill(mark.color.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                        .strokeBorder(mark.color, lineWidth: max(2, squareSize * 0.06))
                )
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: mark.square))
                .allowsHitTesting(false)
                .transition(.opacity)
        }

        // A queued premove: the two squares, in a colour of their own so it
        // does not read as the last move or the selection.
        if let premove = decorations.premove {
            ForEach(model.position.highlightSquares(of: premove), id: \.index) { square in
                RoundedRectangle(cornerRadius: squareSize * 0.12, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.38))
                    .frame(width: squareSize, height: squareSize)
                    .position(geometry.center(of: square))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }

        // Hint.
        if let hint = model.hintMove {
            ForEach(model.position.highlightSquares(of: hint), id: \.index) { square in
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

    /// The square a lifted piece would be dropped on if the finger came up
    /// now — the one under the finger, as the drop in `boardGesture` reads
    /// it — or nil while nothing is lifted, or over the square it came from,
    /// where letting go only puts it back.
    private func dropTarget(_ geometry: BoardGeometry) -> Square? {
        guard let drag = dragState, drag.isBeyondTapThreshold,
              let square = geometry.square(at: drag.location), square != drag.from
        else { return nil }
        return square
    }

    // MARK: Pieces

    /// Where a lifted piece is drawn: above the finger, so it stays visible.
    ///
    /// "Above" is the lifting player's above. Across a table the far player's
    /// hand comes in over the top edge of the screen, and a piece lifted
    /// towards that edge went under their own palm — so for the side drawn
    /// upside down it goes the other way, towards the top of *their* view.
    private func liftedPoint(_ drag: DragState, _ geometry: BoardGeometry, up: CGFloat) -> CGPoint {
        CGPoint(x: drag.location.x, y: drag.location.y - geometry.squareSize * 0.9 * up)
    }

    /// Which way is up for whoever owns `piece`, in screen terms: -1 for the
    /// side drawn upside down, 1 for everyone else.
    private func upDirection(for piece: Piece, upsideDown: PieceColor?) -> CGFloat {
        upsideDown == piece.color ? -1 : 1
    }

    @ViewBuilder
    private func piecesLayer(_ geometry: BoardGeometry) -> some View {
        let squareSize = geometry.squareSize
        // Asked once for the layer, not twice for every piece: the game's
        // decorations are built afresh on each read, and this layer is drawn
        // for every frame of a drag.
        let upsideDown = model.decorations.upsideDownColor
        let movedTo = model.lastMove.map { model.position.displaySquares(of: $0).to }

        // Dying (captured) pieces fade out underneath.
        ForEach(model.layout.dyingPieces) { dying in
            DyingPieceView(piece: dying.piece)
                .rotationEffect(rotation(for: dying.piece, upsideDown: upsideDown))
                .frame(width: squareSize, height: squareSize)
                .position(geometry.center(of: dying.square))
                .allowsHitTesting(false)
        }

        // Faded stand-in marking the square a piece was picked up from.
        if let drag = dragState, drag.isBeyondTapThreshold,
           let lifted = model.layout.pieces.first(where: { $0.id == drag.pieceID }) {
            PieceView(piece: lifted.piece, shadow: false)
                .rotationEffect(rotation(for: lifted.piece, upsideDown: upsideDown))
                .frame(width: squareSize, height: squareSize)
                .opacity(0.22)
                .position(geometry.center(of: drag.from))
                .allowsHitTesting(false)
        }

        // A dragged piece is this same view, moved under the finger, so that on
        // release SwiftUI animates it from where it was dropped rather than
        // from the square it came from.
        ForEach(model.layout.pieces) { boardPiece in
            let drag = dragState
            let isDragged = drag?.pieceID == boardPiece.id && drag?.isBeyondTapThreshold == true
            let isMoved = movedTo == boardPiece.square
            let up = upDirection(for: boardPiece.piece, upsideDown: upsideDown)
            let point = (isDragged ? drag.map { liftedPoint($0, geometry, up: up) } : nil)
                ?? geometry.center(of: boardPiece.square)
            PieceView(piece: boardPiece.piece)
                .rotationEffect(rotation(for: boardPiece.piece, upsideDown: upsideDown))
                .frame(width: squareSize, height: squareSize)
                .scaleEffect(isDragged ? 1.5 : 1)
                // The shadow turns with it, below the piece as its owner sees
                // it, so the far player's piece is not lit from underneath.
                .shadow(color: .black.opacity(isDragged ? 0.35 : 0),
                        radius: squareSize * 0.18, y: squareSize * 0.12 * up)
                .position(point)
                .zIndex(isDragged ? 10 : (isMoved ? 2 : 1))
                .allowsHitTesting(false)
        }
    }

    /// Half a turn for the far player's pieces when two players share a board
    /// across a table, so each side reads its own army the right way up.
    private func rotation(for piece: Piece, upsideDown: PieceColor?) -> Angle {
        upsideDown == piece.color ? .degrees(180) : .zero
    }

    // MARK: Arrows

    @ViewBuilder
    private func arrowLayer(_ geometry: BoardGeometry) -> some View {
        ForEach(model.decorations.arrows, id: \.self) { arrow in
            MoveArrow(
                from: geometry.center(of: arrow.from),
                to: geometry.center(of: arrow.to),
                squareSize: geometry.squareSize
            )
            .fill(arrow.color.opacity(0.85))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .frame(width: geometry.size, height: geometry.size)
            .allowsHitTesting(false)
            .transition(.opacity)
            // Over the pieces at rest (1, or 2 for the one just moved), as
            // the review's board draws its arrow — at 0 the head of an arrow
            // onto a capture was hidden under the piece it takes — and under
            // one being dragged (10), which is in the player's hand.
            .zIndex(5)
        }
    }

    // MARK: Gesture

    private func boardGesture(_ geometry: BoardGeometry) -> some Gesture {
        let squareSize = geometry.squareSize
        return DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard !model.hasPendingPromotion else { return }

                if dragState == nil {
                    // Gesture start: select own piece under the finger.
                    guard let start = geometry.square(at: value.startLocation) else { return }
                    if let piece = model.position.piece(at: start), model.isInteractive(color: piece.color) {
                        let alreadySelected = model.selectedSquare == start
                        let isTarget = !alreadySelected && model.selectedSquare.map {
                            !Model.moves(from: $0, to: start, among: model.legalTargets, on: model.position).isEmpty
                        } == true
                        if !alreadySelected && !isTarget {
                            model.select(start)
                        }
                        dragState = DragState(
                            from: start,
                            pieceID: model.layout.pieces.first { $0.square == start }?.id,
                            location: value.location,
                            selectedOnTouchDown: !alreadySelected && !isTarget,
                            selectsOnPickUp: isTarget
                        )
                        model.isDragging = true
                    }
                }

                guard dragState != nil else { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if dragState?.isBeyondTapThreshold == false, distance > squareSize * 0.25 {
                    // A castling rook that is dragged rather than tapped is
                    // being moved itself.
                    if dragState?.selectsOnPickUp == true, let from = dragState?.from {
                        model.select(from)
                        dragState?.selectsOnPickUp = false
                    }
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
                guard !model.hasPendingPromotion else {
                    dragState = nil
                    return
                }

                let distance = hypot(value.translation.width, value.translation.height)
                let tapped = geometry.square(at: value.location)

                let drag = dragState
                let travelled = distance > squareSize * 0.25

                // The piece under the finger was taken while it was held — the
                // computer's reply captured it under a premove. There is
                // nothing left to drop or to tap, and whatever stands on its
                // square now is not the player's to move.
                if let drag, let id = drag.pieceID, !model.layout.pieces.contains(where: { $0.id == id }) {
                    dragState = nil
                    return
                }

                if let drag, drag.isBeyondTapThreshold || travelled {
                    // A flick too quick for `onChanged` to see it cross the
                    // threshold has not selected the rook it carries yet.
                    if drag.selectsOnPickUp { model.select(drag.from) }
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
                guard let touched = drag else {
                    let started = geometry.square(at: value.startLocation)
                    dragState = nil
                    if let tapped, started == tapped {
                        model.handleTap(on: tapped)
                    }
                    return
                }

                // A tap that began on a piece is held to its square the same
                // way: it means that piece, wherever the finger came up. The
                // threshold is a quarter of a square — some eleven points on a
                // small phone — so a finger that landed near the edge can lift
                // over the neighbour without ever picking the piece up, and
                // that square handed to `handleTap` played a move nobody made:
                // the pawn just touched, pushed one square forward.
                dragState = nil
                // Touching down already did the selecting; anything else is a
                // real tap and goes through the model — which is also what
                // castles when the tap was on the rook a selected king offers.
                if !touched.selectedOnTouchDown {
                    model.handleTap(on: touched.from)
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

/// VoiceOver's view of the board. Everything the board draws is decoration as
/// far as accessibility is concerned, so the squares get their own layer of
/// 64 labelled elements. They carry no gesture of their own, which leaves the
/// drag recognizer on the board in charge of touch — VoiceOver reaches them
/// through the accessibility action instead.
private struct BoardAccessibilityLayer<Model: PlayableBoard>: View {
    let model: Model
    let geometry: BoardGeometry

    var body: some View {
        // What every square asks, asked once for the board.
        let position = model.position
        let selected = model.selectedSquare
        let targets = model.legalTargets
        let checked = model.checkedKingSquare
        let lastMoveSquares = model.lastMove.map { position.highlightSquares(of: $0) } ?? []
        ForEach(Square.all, id: \.index) { square in
            let piece = position.piece(at: square)
            let target = targets.first { $0.to == square }
            Color.clear
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: square))
                .accessibilityElement()
                .accessibilityLabel(BoardSpeech.label(square: square, piece: piece))
                .accessibilityValue(value(isChecked: checked == square, isLastMove: lastMoveSquares.contains(square)))
                .accessibilityHint(
                    BoardSpeech.hint(
                        square: square,
                        piece: piece,
                        isSelected: selected == square,
                        isLegalTarget: target != nil,
                        isCaptureTarget: target?.isCapture == true,
                        canSelect: piece.map { model.isInteractive(color: $0.color) } ?? false
                    ) ?? ""
                )
                .accessibilityAddTraits(selected == square ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.handleTap(on: square) }
        }
    }

    /// Extra context a sighted player reads off the highlights.
    private func value(isChecked: Bool, isLastMove: Bool) -> String {
        var parts: [String] = []
        if isChecked {
            parts.append(String(localized: "in check", comment: "VoiceOver value on the checked king's square"))
        }
        if isLastMove {
            parts.append(String(localized: "last move", comment: "VoiceOver value on the squares of the move just played"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Glow marking a checked king — it pulses, unless the reader has asked for
/// less motion, in which case it simply sits there and still marks the square.
private struct CheckGlow: View {
    /// Where the glow fades out — three quarters of a square, as on the review
    /// and lesson boards. A fixed 40 points was most of a square on a phone
    /// and hid under the king on an iPad, where a square is nearly three
    /// times that.
    let radius: CGFloat
    @State private var pulsing = false

    var body: some View {
        // Asked here rather than in `onAppear` so that turning Reduce Motion on
        // or off reaches a glow that is already on screen.
        let mayPulse = Motion.allowsRepeatingDecoration
        return RadialGradient(
            colors: [Color.red.opacity(0.75), Color.red.opacity(0)],
            center: .center, startRadius: 0, endRadius: radius
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
