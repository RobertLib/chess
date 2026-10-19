//
//  Game.swift
//  chess
//
//  A full game: move history, SAN notation, outcome & draw detection.
//

import Foundation

/// One move as it was played, with display metadata.
nonisolated struct PlayedMove: Hashable, Codable, Sendable {
    var move: Move
    /// Standard algebraic notation, e.g. "Nxf3+", "O-O", "e8=Q#".
    var san: String
    /// Position hash after the move (for repetition display/debugging).
    var zobristAfter: UInt64
    /// Move number and color for display: "1. e4" / "1... e5".
    var moveNumber: Int
    var color: PieceColor
}

nonisolated struct Game: Hashable, Codable, Sendable {
    private(set) var board: Board
    private(set) var history: [PlayedMove]
    private(set) var outcome: GameOutcome
    /// Zobrist hashes of all positions since the last irreversible move,
    /// including the current one (for threefold repetition).
    private(set) var repetitionHashes: [UInt64]

    /// The FEN the game started from, as the board writes it — which for a
    /// Chess960 game means Shredder castling letters, so that the replay
    /// `undoLastMoves` and the saved games run from it is a 960 game too.
    let initialFEN: String

    /// Whether threefold repetition and the fifty-move rule end the game by
    /// themselves, as they do in every game played in the app (see
    /// `evaluateOutcome`). A game read from PGN has it off: its players may
    /// have played on past a repetition nobody claimed, and the moves after
    /// it are part of the game. Such a game ends by itself only on FIDE's
    /// automatic draws — the fifth repetition and seventy-five moves — and
    /// `claimDraw` settles the claimable ones its result says were claimed.
    let settlesClaimableDraws: Bool

    /// Reads standard and Chess960 FENs alike; `Board(fen:)` tells them apart.
    /// A FEN has no way to say King of the Hill or three-check, so `variant`
    /// does, and the position is read under its rules (see
    /// `Board(fen:variant:)`). A FEN that does not read, or names a position
    /// those rules cannot reach, starts the standard game instead.
    init(fen: String = Board.startFEN, variant: ChessVariant = .standard, settlesClaimableDraws: Bool = true) {
        let board = Board(fen: fen, variant: variant) ?? Board(fen: Board.startFEN, variant: variant)!
        self.board = board
        self.history = []
        self.outcome = .ongoing
        self.repetitionHashes = [board.zobrist]
        self.initialFEN = board.fen
        self.settlesClaimableDraws = settlesClaimableDraws
        self.outcome = Self.evaluateOutcome(
            board: board, repetitionHashes: repetitionHashes, settlesClaimableDraws: settlesClaimableDraws
        )
    }

    /// The same game back at its first position, under the same rules — what
    /// every replay of its moves has to start from, or a game read from PGN
    /// would stop at the first repetition its players did not claim.
    var atStart: Game {
        Game(fen: initialFEN, variant: variant, settlesClaimableDraws: settlesClaimableDraws)
    }

    // MARK: Queries

    var sideToMove: PieceColor { board.sideToMove }
    var isInCheck: Bool { board.isInCheck }

    /// Whether this is a Chess960 game. Read off the board, which keeps the
    /// flag for the whole game. A 960 game that starts with no castling rights
    /// at all writes its FEN as standard chess does and replays as standard
    /// chess — which plays identically, since castling is all that differs.
    var isChess960: Bool { board.isChess960 }

    /// The variant's rules, kept by the board for the whole game.
    var variant: ChessVariant { board.variant }

    var legalMoves: [Move] {
        outcome.isGameOver ? [] : board.generateLegalMoves()
    }

    func legalMoves(from square: Square) -> [Move] {
        outcome.isGameOver ? [] : board.legalMoves(from: square)
    }

    var lastMove: Move? { history.last?.move }

    // MARK: Making moves

    /// Plays a legal move, updating history and outcome. A move that is not
    /// legal in the current position is refused rather than played.
    ///
    /// Everything that reaches here today asks `legalMoves` first — the board,
    /// the AI task, the restore paths — so the check never fires in practice.
    /// It is here because this is the only door into the game state and a move
    /// that slipped through would not be rejected, it would quietly corrupt
    /// the position: `Board.make` trusts the flags the move carries, so a
    /// hand-built move with the wrong `captured` or `isDoublePawnPush` would
    /// leave pieces and en passant rights in a state no rule can explain.
    /// Debug builds trap so a mistake is found where it is made.
    mutating func play(_ move: Move) {
        guard !outcome.isGameOver else { return }
        let legalMoves = board.generateLegalMoves()
        guard legalMoves.contains(move) else {
            assertionFailure("illegal move \(move.uci) played in \(board.fen)")
            return
        }
        // The list is handed on rather than asked for again: naming a move
        // needs to know which other pieces could have gone to the same square,
        // which is the very list that was just generated to vet it.
        let san = board.san(for: move, legalMoves: legalMoves)
        let moveNumber = board.fullmoveNumber
        let color = board.sideToMove

        board.make(move)

        // Irreversible moves (pawn moves, captures) reset repetition tracking;
        // castling-right and en passant changes are captured by the hash itself.
        if move.piece.kind == .pawn || move.isCapture {
            repetitionHashes = [board.zobrist]
        } else {
            repetitionHashes.append(board.zobrist)
        }

        history.append(PlayedMove(
            move: move, san: san, zobristAfter: board.zobrist,
            moveNumber: moveNumber, color: color
        ))

        outcome = Self.evaluateOutcome(
            board: board, repetitionHashes: repetitionHashes, settlesClaimableDraws: settlesClaimableDraws
        )
    }

    /// Takes back the last move by replaying the game from the start.
    /// Also clears a finished outcome (including resignation/draw agreements).
    mutating func undoLastMove() {
        undoLastMoves(1)
    }

    /// Takes back the last `count` moves in one replay from the start.
    ///
    /// Against the computer a takeback is always two plies — the computer's
    /// reply and the move that drew it — and calling `undoLastMove` twice
    /// replayed the whole game twice for it. Measured at 160 plies: 2.9 ms for
    /// the pair against 1.8 ms for one, on a desktop core. Not a figure worth
    /// chasing on its own; it is asked for once instead of twice because there
    /// is no reason to ask twice.
    mutating func undoLastMoves(_ count: Int) {
        guard count > 0, !history.isEmpty else { return }
        let moves = history.prefix(max(0, history.count - count)).map(\.move)
        var replayed = atStart
        for move in moves { replayed.play(move) }
        self = replayed
    }

    mutating func resign(_ color: PieceColor) {
        guard !outcome.isGameOver else { return }
        outcome = .resigned(winner: color.opponent)
    }

    mutating func agreeToDraw() {
        guard !outcome.isGameOver else { return }
        outcome = .drawAgreed
    }

    /// Ends the game in the draw a player could claim now: the position on
    /// the board for the third time, or fifty moves without a capture or a
    /// pawn move. Returns false, leaving the game alone, when there is none.
    @discardableResult
    mutating func claimDraw() -> Bool {
        guard !outcome.isGameOver else { return false }
        if repetitionHashes.count(where: { $0 == board.zobrist }) >= 3 {
            outcome = .drawThreefoldRepetition
        } else if board.halfmoveClock >= 100 {
            outcome = .drawFiftyMoveRule
        } else {
            return false
        }
        return true
    }

    /// The side on move has run out of time. Only the side on move can: the
    /// other side's clock is not running. It loses — unless its opponent has
    /// nothing left to mate with, which makes the flag fall a draw.
    mutating func timeOut() {
        guard !outcome.isGameOver else { return }
        let flagged = sideToMove
        outcome = board.hasMatingMaterial(flagged.opponent)
            ? .timeForfeit(winner: flagged.opponent)
            : .drawTimeoutInsufficientMaterial
    }

    /// A flag that has already been ruled on: a game read from PGN whose
    /// result says the side on move lost on time, or one the archive replays
    /// after filing it as that loss. The verdict stands even where `timeOut`
    /// would have drawn it — the server that played the game judged the
    /// material by a rule of its own, and the archive should say what
    /// happened rather than what this app would have decided.
    mutating func recordTimeForfeit() {
        guard !outcome.isGameOver else { return }
        outcome = .timeForfeit(winner: sideToMove.opponent)
    }

    // MARK: Outcome

    /// How the game stands after a move.
    ///
    /// Threefold repetition and the fifty-move rule end the game here of their
    /// own accord. Under FIDE they are a player's to *claim* — only fivefold
    /// and seventy-five moves draw automatically — but claiming needs a button,
    /// a rule to explain and an answer for what the computer would do with it,
    /// so the app settles them itself, the way the "How to Play" guide promises
    /// it will. A deliberate simplification, not an oversight. A game read
    /// from PGN keeps FIDE's own rule instead (see `settlesClaimableDraws`).
    ///
    /// A variant's own win comes first: the king on the hill, the third check.
    /// The move that achieved it may also have mated, and either way it won.
    private static func evaluateOutcome(
        board: Board, repetitionHashes: [UInt64], settlesClaimableDraws: Bool
    ) -> GameOutcome {
        if let winner = board.variantWinner {
            return board.variant == .kingOfTheHill ? .kingOfTheHill(winner: winner) : .threeChecks(winner: winner)
        }
        let hasLegalMoves = !board.generateLegalMoves().isEmpty
        if !hasLegalMoves {
            if board.isInCheck {
                return .checkmate(winner: board.sideToMove.opponent)
            }
            return .stalemate
        }
        if board.hasInsufficientMaterial {
            return .drawInsufficientMaterial
        }
        if board.halfmoveClock >= (settlesClaimableDraws ? 100 : 150) {
            return .drawFiftyMoveRule
        }
        if repetitionHashes.count(where: { $0 == board.zobrist }) >= (settlesClaimableDraws ? 3 : 5) {
            return .drawThreefoldRepetition
        }
        return .ongoing
    }

    // MARK: Material

    /// Pieces captured by `color` over the whole game, in capture order.
    func capturedPieces(by color: PieceColor) -> [Piece] {
        history.compactMap { played in
            guard played.color == color, let captured = played.move.captured else { return nil }
            return captured
        }
    }

    /// Conventional material balance (positive: white is ahead), in pawns.
    var materialBalance: Int {
        var balance = 0
        for index in 0..<64 {
            guard let piece = board.piece(at: index) else { continue }
            let value: Int
            switch piece.kind {
            case .pawn: value = 1
            case .knight, .bishop: value = 3
            case .rook: value = 5
            case .queen: value = 9
            case .king: value = 0
            }
            balance += piece.color == .white ? value : -value
        }
        return balance
    }
}

// MARK: - Notation

nonisolated extension Board {

    /// Standard algebraic notation for a legal move in this position,
    /// e.g. "Nxf3+", "O-O", "e8=Q#".
    func san(for move: Move) -> String {
        san(for: move, legalMoves: generateLegalMoves())
    }

    /// The same, for a caller that has this position's legal moves already —
    /// disambiguation is the only thing they are needed for.
    func san(for move: Move, legalMoves: [Move]) -> String {
        var san: String

        if move.isCastleKingside {
            san = "O-O"
        } else if move.isCastleQueenside {
            san = "O-O-O"
        } else if move.piece.kind == .pawn {
            san = move.isCapture ? "\(Board.fileLetter(move.from.file))x" : ""
            san += move.to.algebraic
            if let promotion = move.promotion {
                san += "=\(promotion.letter)"
            }
        } else {
            san = move.piece.kind.letter
            san += disambiguation(for: move, among: legalMoves)
            if move.isCapture { san += "x" }
            san += move.to.algebraic
        }

        // Check / checkmate suffix.
        var next = self
        next.make(move)
        if next.isInCheck {
            san += next.generateLegalMoves().isEmpty ? "#" : "+"
        }
        return san
    }

    static func fileLetter(_ file: Int) -> String {
        String("abcdefgh"[String.Index(utf16Offset: file, in: "abcdefgh")])
    }

    /// SAN disambiguation when several identical pieces can reach the target.
    private func disambiguation(for move: Move, among legalMoves: [Move]) -> String {
        let rivals = legalMoves.filter {
            $0.to == move.to && $0.piece == move.piece && $0.from != move.from
        }
        guard !rivals.isEmpty else { return "" }
        let sameFile = rivals.contains { $0.from.file == move.from.file }
        let sameRank = rivals.contains { $0.from.rank == move.from.rank }
        if !sameFile { return Board.fileLetter(move.from.file) }
        if !sameRank { return String(move.from.rank + 1) }
        return move.from.algebraic
    }
}
