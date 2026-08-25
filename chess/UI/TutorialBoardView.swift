//
//  TutorialBoardView.swift
//  chess
//
//  The little board inside a lesson. It draws a position from a FEN and, when
//  the lesson names a piece, offers that piece's legal moves as dots — asked
//  from the same engine that runs a real game, and really playable.
//

import SwiftUI

struct TutorialBoardView: View {
    let diagram: TutorialDiagram
    let theme: BoardTheme

    /// A piece on the demo board. The id stays with the piece as it moves, so
    /// SwiftUI animates the move instead of swapping one piece for another.
    private struct Placed: Identifiable {
        let id: Int
        var piece: Piece
        var square: Square
    }

    /// What the board currently shows. `board` is nil for diagrams that only
    /// illustrate something and have no kings on them; those offer no moves.
    private struct Position {
        var board: Board?
        var placed: [Placed]
        var hasMoved = false

        init(diagram: TutorialDiagram) {
            board = Board(fen: diagram.fen)
            placed = Position.placement(fen: diagram.fen)
        }

        /// Reads just the piece placement of a FEN, which — unlike a full
        /// `Board` — works for positions without kings.
        ///
        /// Malformed input draws nothing at all, the same way `Board(fen:)`
        /// refuses it: a blank diagram is a typo somebody notices, whereas a
        /// rank quietly shifted by one is a lesson that teaches the wrong
        /// position.
        private static func placement(fen: String) -> [Placed] {
            guard let field = fen.split(separator: " ").first else { return [] }
            let ranks = field.split(separator: "/")
            guard ranks.count == 8 else { return [] }

            var result: [Placed] = []
            for (row, rankField) in ranks.enumerated() {
                let rank = 7 - row
                var file = 0
                for character in rankField {
                    if let skip = character.wholeNumberValue, (1...8).contains(skip) {
                        file += skip
                    } else if let piece = Piece(fenCharacter: character) {
                        guard file < 8 else { return [] }
                        let square = Square(file: file, rank: rank)
                        result.append(Placed(id: square.index, piece: piece, square: square))
                        file += 1
                    } else {
                        return []
                    }
                }
                guard file == 8 else { return [] }
            }
            return result
        }
    }

    @State private var position: Position

    init(diagram: TutorialDiagram, theme: BoardTheme) {
        self.diagram = diagram
        self.theme = theme
        _position = SwiftUI.State(initialValue: Position(diagram: diagram))
    }

    var body: some View {
        VStack(spacing: 8) {
            board
            captionRow
        }
    }

    private var board: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(size: side, orientation: diagram.orientation)

            ZStack(alignment: .topLeading) {
                BoardBackdrop(geometry: geometry, theme: theme, showCoordinates: true)
                highlights(geometry).accessibilityHidden(true)
                pieces(geometry)
                arrows(geometry).accessibilityHidden(true)
                targetDots(geometry)
                accessibilityLayer(geometry)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let square = geometry.square(at: location) {
                    play(to: square)
                }
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Lesson diagram", comment: "VoiceOver name for a board inside a lesson"))
            .accessibilityValue(BoardSpeech.lessonValue(focus: focusPiece, at: diagram.focusSquare))
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: diagram) { _, new in
            position = Position(diagram: new)
        }
        .onAppear {
#if DEBUG
            // Development helper: plays an offered move, as a tap would.
            if let argument = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--tutorial-tap=") }),
               let square = Square(algebraic: String(argument.dropFirst("--tutorial-tap=".count))) {
                play(to: square)
            }
#endif
        }
    }

    // MARK: Moves on offer

    /// The squares the focused piece may go to, one entry per square even when
    /// a promotion offers four moves to the same one.
    private var targets: [(square: Square, isCapture: Bool)] {
        guard !position.hasMoved, let focus = diagram.focusSquare, let board = position.board
        else { return [] }

        var seen = Set<Int>()
        var result: [(square: Square, isCapture: Bool)] = []
        for move in board.legalMoves(from: focus) where seen.insert(move.to.index).inserted {
            result.append((move.to, move.isCapture))
        }
        return result
    }

    /// The piece the lesson is pointing at, while it still stands there.
    private var focusPiece: Piece? {
        guard !position.hasMoved, let focus = diagram.focusSquare else { return nil }
        return position.placed.first { $0.square == focus }?.piece
    }

    // MARK: Accessibility

    /// VoiceOver's view of a lesson diagram. The live board exposes all sixty-
    /// four squares because a player may move to any of them; a diagram is read
    /// far more often than it is played, so only the squares that carry
    /// something — a piece, or a move on offer — become elements. That keeps a
    /// lesson page to a dozen swipes rather than sixty-four.
    private func accessibilityLayer(_ geometry: BoardGeometry) -> some View {
        let offered = Dictionary(targets.map { ($0.square.index, $0.isCapture) }) { first, _ in first }
        let occupied = Set(position.placed.map(\.square.index))
        let focusIndex = position.hasMoved ? nil : diagram.focusSquare?.index

        return ForEach(occupied.union(offered.keys).sorted(), id: \.self) { index in
            let square = Square(index)
            let piece = position.placed.first { $0.square == square }?.piece
            Color.clear
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: square))
                .accessibilityElement()
                .accessibilityLabel(BoardSpeech.label(square: square, piece: piece))
                .accessibilityHint(
                    BoardSpeech.lessonHint(
                        isFocus: index == focusIndex,
                        isLegalTarget: offered[index] != nil,
                        isCaptureTarget: offered[index] == true
                    ) ?? ""
                )
                .accessibilityAddTraits(offered[index] != nil ? .isButton : [])
                .accessibilityAction { play(to: square) }
        }
    }

    /// Plays the offered move that lands on `square`, if there is one.
    private func play(to square: Square) {
        guard !position.hasMoved, let focus = diagram.focusSquare, var board = position.board
        else { return }

        let candidates = board.legalMoves(from: focus).filter { $0.to == square }
        // A pawn reaching the last rank offers four moves to the same square;
        // the lesson says it becomes a queen.
        guard let move = candidates.first(where: { $0.promotion == .queen }) ?? candidates.first
        else { return }

        var placed = position.placed

        if move.isEnPassant {
            let capturedIndex = move.piece.color == .white ? move.to.index - 8 : move.to.index + 8
            placed.removeAll { $0.square.index == capturedIndex }
        } else if move.isCapture {
            placed.removeAll { $0.square == move.to }
        }

        if let index = placed.firstIndex(where: { $0.square == move.from }) {
            placed[index].square = move.to
            if let promotion = move.promotion {
                placed[index].piece = Piece(move.piece.color, promotion)
            }
        }

        if move.isCastle {
            let base = move.piece.color == .white ? 0 : 56
            let rookFrom = base + (move.isCastleKingside ? 7 : 0)
            let rookTo = base + (move.isCastleKingside ? 5 : 3)
            if let index = placed.firstIndex(where: { $0.square.index == rookFrom }) {
                placed[index].square = Square(rookTo)
            }
        }

        let san = board.san(for: move)
        board.make(move)
        let isCheck = board.isInCheck

        withAnimation(Motion.meaningful(.spring(duration: 0.35, bounce: 0.15))) {
            position.placed = placed
            position.board = board
            position.hasMoved = true
        }

        // The diagram just changed under a reader who cannot see it.
        AccessibilityNotification.Announcement(BoardSpeech.lessonAnnouncement(san: san)).post()

        SoundManager.shared.play(for: move, isCheck: isCheck)
        if isCheck {
            Haptics.check()
        } else if move.isCapture {
            Haptics.capture()
        } else {
            Haptics.pieceMoved()
        }
    }

    @ViewBuilder
    private var captionRow: some View {
        if diagram.caption != nil || position.hasMoved {
            ZStack {
                if let caption = diagram.caption {
                    Text(caption)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, position.hasMoved ? 76 : 0)
                }

                if position.hasMoved {
                    HStack {
                        Spacer()
                        resetButton
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var resetButton: some View {
        Button {
            withAnimation(Motion.meaningful(.spring(duration: 0.35))) {
                position = Position(diagram: diagram)
            }
            Haptics.pieceSelected()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset", comment: "Puts a lesson diagram back the way it started")
            }
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .hudCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Put the pieces back")
    }

    // MARK: Layers

    @ViewBuilder
    private func highlights(_ geometry: BoardGeometry) -> some View {
        if !position.hasMoved {
            ForEach(diagram.highlightSquares, id: \.index) { square in
                RoundedRectangle(cornerRadius: geometry.squareSize * 0.12, style: .continuous)
                    .fill(theme.accent.opacity(0.34))
                    .frame(width: geometry.squareSize, height: geometry.squareSize)
                    .position(geometry.center(of: square))
            }
        }

        if let focus = diagram.focusSquare, !position.hasMoved {
            RoundedRectangle(cornerRadius: geometry.squareSize * 0.12, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: max(1.5, geometry.squareSize * 0.05))
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: focus))
        }

        if let board = position.board, board.isInCheck {
            RadialGradient(
                colors: [Color.red.opacity(0.7), Color.red.opacity(0)],
                center: .center, startRadius: 0, endRadius: geometry.squareSize * 0.75
            )
            .frame(width: geometry.squareSize * 1.5, height: geometry.squareSize * 1.5)
            .position(geometry.center(of: Square(board.kingSquare(of: board.sideToMove))))
        }
    }

    private func targetDots(_ geometry: BoardGeometry) -> some View {
        ForEach(targets, id: \.square.index) { target in
            Group {
                if target.isCapture {
                    Circle()
                        .strokeBorder(theme.accent.opacity(0.85), lineWidth: max(2, geometry.squareSize * 0.07))
                        .frame(width: geometry.squareSize * 0.92, height: geometry.squareSize * 0.92)
                } else {
                    Circle()
                        .fill(theme.accent.opacity(0.55))
                        .frame(width: geometry.squareSize * 0.30, height: geometry.squareSize * 0.30)
                }
            }
            .position(geometry.center(of: target.square))
            .transition(.scale.combined(with: .opacity))
        }
        .accessibilityHidden(true)
    }

    private func pieces(_ geometry: BoardGeometry) -> some View {
        ForEach(position.placed) { placed in
            PieceView(piece: placed.piece)
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: placed.square))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func arrows(_ geometry: BoardGeometry) -> some View {
        if !position.hasMoved {
            ForEach(Array(diagram.arrows.enumerated()), id: \.offset) { _, arrow in
                if let squares = arrow.squares {
                    MoveArrow(
                        from: geometry.center(of: squares.from),
                        to: geometry.center(of: squares.to),
                        squareSize: geometry.squareSize
                    )
                    .fill(color(for: arrow.kind).opacity(0.9))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .frame(width: geometry.size, height: geometry.size)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func color(for kind: TutorialArrow.Kind) -> Color {
        switch kind {
        case .move: return MoveQuality.best.tint
        case .attack: return MoveQuality.blunder.tint
        }
    }
}

#Preview("Diagram") {
    VStack(spacing: 20) {
        TutorialBoardView(
            diagram: TutorialDiagram(
                fen: "r3k2r/pppqbppp/2np1n2/4p3/4P3/2NP1N2/PPPQBPPP/R3K2R w KQkq - 0 1",
                focus: "e1",
                arrows: [.move("h1", "f1"), .move("a1", "d1")]
            ),
            theme: .classic
        )
        .frame(maxWidth: 340)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(BoardTheme.classic.backgroundBottom)
}
