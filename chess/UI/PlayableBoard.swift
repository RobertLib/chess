//
//  PlayableBoard.swift
//  chess
//
//  What a board that takes moves needs from whatever drives it. The game, the
//  puzzles, the analysis board and the opening trainer all draw the same
//  board and take touch the same way; this is the contract between that one
//  view and the four models behind it.
//

import SwiftUI

// MARK: - Contract

@MainActor
protocol PlayableBoard: AnyObject, Observable {
    /// Colour drawn at the bottom of the board.
    var orientation: PieceColor { get }
    /// The animated pieces.
    var layout: PieceLayout { get }
    /// The position the pieces stand in — what touch is checked against.
    var position: Board { get }
    var lastMove: Move? { get }
    var checkedKingSquare: Square? { get }
    var selectedSquare: Square? { get }
    /// Every legal move of the selected piece (promotions four times over).
    var legalTargets: [Move] { get }
    /// The same, one entry per destination square, for drawing the markers.
    var legalTargetSquares: [Move] { get }
    var hintMove: Move? { get }
    /// True while the promotion picker is waiting for an answer.
    var hasPendingPromotion: Bool { get }
    /// Reported by the board while a finger is dragging a piece.
    var isDragging: Bool { get set }
    /// Arrows, marked squares and the like, drawn over the board.
    var decorations: BoardDecorations { get }

    /// Whether the player may pick up pieces of `color` right now.
    func isInteractive(color: PieceColor) -> Bool
    func handleTap(on square: Square)
    func select(_ square: Square)
    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool
}

extension PlayableBoard {
    /// Destination squares of `legalTargets`, one per square: a pawn reaching
    /// the last rank offers four moves to one square, and the board draws one
    /// marker for it, not four.
    static func uniqueTargets(_ moves: [Move]) -> [Move] {
        var seen = Set<Int>()
        return moves.filter { seen.insert($0.to.index).inserted }
    }

    /// The moves a tap or drop from `from` to `to` can mean.
    ///
    /// In Chess960 a castle is written as the king taking its own rook, so
    /// that is where the board offers it — the only square that names the
    /// move even when the king does not move at all. Players also reach for
    /// the square the king lands on, g1 or c1, the way they castle in ordinary
    /// chess, so that is accepted too whenever no other move goes there.
    static func moves(from: Square, to: Square, among moves: [Move], on board: Board) -> [Move] {
        let direct = moves.filter { $0.from == from && $0.to == to }
        guard direct.isEmpty, board.isChess960 else { return direct }
        return moves.filter {
            $0.isCastle && $0.from == from && board.castlingSquares(for: $0)?.kingTo == to
        }
    }
}

// MARK: - Where a move is drawn

extension Board {
    /// The two squares a move is shown on — highlighted, or joined by an
    /// arrow. Its `from` and `to`, except for a Chess960 castle, where `to`
    /// is the rook's square: there it is the king's start and where it lands.
    /// Any position of the same game answers alike (see `castlingSquares`).
    func displaySquares(of move: Move) -> (from: Square, to: Square) {
        guard isChess960, let castle = castlingSquares(for: move) else { return (move.from, move.to) }
        return (castle.kingFrom, castle.kingTo)
    }

    /// The same as a list, without a repeat: a Chess960 king can castle
    /// without moving, and a `ForEach` keyed by square must not see one twice.
    func highlightSquares(of move: Move) -> [Square] {
        let squares = displaySquares(of: move)
        return squares.from == squares.to ? [squares.from] : [squares.from, squares.to]
    }
}

// MARK: - Decorations

/// What a model can ask the board to draw beyond the position itself.
struct BoardDecorations {
    var arrows: [BoardArrow] = []
    var marks: [SquareMark] = []
    /// A move the player has queued while waiting for the computer.
    var premove: Move?
    /// Pieces of this colour are drawn upside down — the far side of a board
    /// two players share across a table.
    var upsideDownColor: PieceColor?
    /// Squares the rules single out — King of the Hill's centre.
    var zone: [Square] = []

    static let none = BoardDecorations()
}

struct BoardArrow: Hashable {
    enum Kind: Hashable {
        /// The engine's suggestion.
        case best
        /// A threat, or the move that went wrong.
        case danger
        /// A neutral pointer.
        case info
    }

    var from: Square
    var to: Square
    var kind: Kind

    var color: Color {
        switch kind {
        case .best: return MoveQuality.best.tint
        case .danger: return MoveQuality.blunder.tint
        case .info: return Color(red: 0.42, green: 0.72, blue: 0.98)
        }
    }
}

struct SquareMark: Hashable {
    enum Kind: Hashable {
        /// The square the right move landed on.
        case correct
        /// The square a wrong move landed on.
        case wrong
        /// A gentle pointer, such as the piece a hint names.
        case hint
    }

    var square: Square
    var kind: Kind

    var color: Color {
        switch kind {
        case .correct: return MoveQuality.best.tint
        case .wrong: return MoveQuality.blunder.tint
        case .hint: return .cyan
        }
    }
}

// MARK: - Piece layout

/// The pieces as the board draws them, each with an identity that stays with
/// it from square to square — so that SwiftUI animates a move as a piece
/// sliding rather than as one piece vanishing and another appearing.
///
/// Every board that plays moves keeps one of these in step with its position.
/// Moves are mirrored into it one at a time (that is what makes the slide),
/// and anything that jumps — an undo, a new puzzle, a step back several moves
/// — rebuilds it from the position instead.
@Observable
@MainActor
final class PieceLayout {

    struct BoardPiece: Identifiable {
        let id: UUID
        var piece: Piece
        var square: Square
    }

    /// A captured piece, kept around while it fades out.
    struct DyingPiece: Identifiable {
        let id: UUID
        let piece: Piece
        let square: Square
    }

    private(set) var pieces: [BoardPiece] = []
    private(set) var dyingPieces: [DyingPiece] = []

    /// The fade-outs still in flight, one per ghost so that two captures in
    /// quick succession do not cut each other short.
    private var dyingPieceTasks: [UUID: Task<Void, Never>] = [:]

    init(board: Board) {
        rebuild(from: board)
    }

    /// Redraws the whole board from a position, without animation.
    func rebuild(from board: Board) {
        pieces = Square.all.compactMap { square in
            board.piece(at: square).map { BoardPiece(id: UUID(), piece: $0, square: square) }
        }
        // The ghosts go with the position they belonged to, and so do the
        // fade-outs that were going to clear them.
        cancelFades()
    }

    /// Moves the drawn pieces to a new position, sliding each one that can be
    /// matched to where it now stands rather than redrawing the board.
    ///
    /// Used where the position jumps by more than one move — a wrong puzzle
    /// move taken back, an analysis board stepping through a game. A piece
    /// that is already right stays put; every other square takes the nearest
    /// unmatched piece of the same kind and colour; whatever is left over
    /// fades out or appears. That reads as moves played forwards or backwards,
    /// which a full rebuild — every piece swapped for a new one — does not.
    func sync(to board: Board, animation: Animation?) {
        var remaining = pieces
        var placed: [BoardPiece] = []
        var targets: [(square: Square, piece: Piece)] = []

        for square in Square.all {
            guard let piece = board.piece(at: square) else { continue }
            if let index = remaining.firstIndex(where: { $0.square == square && $0.piece == piece }) {
                placed.append(remaining.remove(at: index))
            } else {
                targets.append((square, piece))
            }
        }
        for target in targets {
            let candidates = remaining.indices.filter { remaining[$0].piece == target.piece }
            let nearest = candidates.min { a, b in
                Self.distance(remaining[a].square, target.square) < Self.distance(remaining[b].square, target.square)
            }
            if let nearest {
                var moved = remaining.remove(at: nearest)
                moved.square = target.square
                placed.append(moved)
            } else {
                placed.append(BoardPiece(id: UUID(), piece: target.piece, square: target.square))
            }
        }
        cancelFades()
        withAnimation(animation) {
            pieces = placed
        }
    }

    private static func distance(_ a: Square, _ b: Square) -> Int {
        max(abs(a.file - b.file), abs(a.rank - b.rank))
    }

    /// Mirrors one move, which must not have been made on `board` yet: the
    /// position before the move is what says where a castling rook stands.
    func apply(_ move: Move, before board: Board, animation: Animation?) {
        let mover = move.piece.color
        var dyingID: UUID?
        let castling = move.isCastle ? board.castlingSquares(for: move) : nil

        withAnimation(animation) {
            // Remove the captured piece.
            if move.captured != nil {
                let captureSquare: Square
                if move.isEnPassant {
                    captureSquare = Square(mover == .white ? move.to.index - 8 : move.to.index + 8)
                } else {
                    captureSquare = move.to
                }
                if let index = pieces.firstIndex(where: { $0.square == captureSquare }) {
                    let dying = pieces.remove(at: index)
                    dyingID = dying.id
                    dyingPieces.append(DyingPiece(id: dying.id, piece: dying.piece, square: dying.square))
                }
            }

            if let castling {
                // King and rook are looked up before either moves: in Chess960
                // one can land on the square the other is leaving.
                let king = pieces.firstIndex { $0.square == castling.kingFrom }
                let rook = pieces.firstIndex { $0.square == castling.rookFrom }
                if let king { pieces[king].square = castling.kingTo }
                if let rook { pieces[rook].square = castling.rookTo }
            } else if let index = pieces.firstIndex(where: { $0.square == move.from }) {
                pieces[index].square = move.to
                if let promotion = move.promotion {
                    pieces[index].piece = Piece(mover, promotion)
                }
            }
        }

        // Let the fade-out play, then drop this piece — and only this one.
        if let dyingID {
            dyingPieceTasks[dyingID] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.dyingPieceTasks[dyingID] = nil
                withAnimation(.easeOut(duration: 0.1)) {
                    self.dyingPieces.removeAll { $0.id == dyingID }
                }
            }
        }
    }

    func cancelFades() {
        for task in dyingPieceTasks.values { task.cancel() }
        dyingPieceTasks = [:]
        dyingPieces = []
    }
}
