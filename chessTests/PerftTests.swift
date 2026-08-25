//
//  PerftTests.swift
//  chessTests
//
//  Perft counts every leaf of the move tree to a given depth. If move
//  generation is wrong anywhere — a missed en passant, a rook that castles out
//  of check, a promotion counted once instead of four times — the totals stop
//  matching, so these numbers are the engine's foundation.
//
//  Reference counts: Chess Programming Wiki, "Perft Results".
//

import Testing
@testable import chess

@Suite("Perft")
struct PerftTests {

    /// Walks the tree the way the search does — pseudo-legal moves filtered by
    /// a king-safety test — so this exercises the code the engine really runs.
    nonisolated static func perft(_ board: inout Board, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        var total = 0
        for move in board.generatePseudoLegalMoves() {
            let mover = board.sideToMove
            let undo = board.make(move)
            if !board.isSquareAttacked(board.kingSquare(of: mover), by: mover.opponent) {
                total += perft(&board, depth - 1)
            }
            board.unmake(move, undo: undo)
        }
        return total
    }

    nonisolated struct Position {
        let name: String
        let fen: String
        /// Expected node counts for depth 1, 2, 3 …
        let counts: [Int]
    }

    nonisolated static let positions: [Position] = [
        Position(
            name: "Starting position",
            fen: Board.startFEN,
            counts: [20, 400, 8_902, 197_281]
        ),
        Position(
            name: "Kiwipete",
            fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            counts: [48, 2_039, 97_862]
        ),
        Position(
            name: "Position 3 — pawn endgame with en passant",
            fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            counts: [14, 191, 2_812, 43_238]
        ),
        Position(
            name: "Position 4 — promotions under check",
            fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
            counts: [6, 264, 9_467]
        ),
        Position(
            name: "Position 5",
            fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
            counts: [44, 1_486, 62_379]
        ),
        Position(
            name: "Position 6",
            fen: "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
            counts: [46, 2_079, 89_890]
        ),
    ]

    @Test("Node counts match the reference", arguments: positions)
    func perftMatchesReference(position: Position) throws {
        var board = try #require(Board(fen: position.fen), "FEN should parse")
        for (index, expected) in position.counts.enumerated() {
            let depth = index + 1
            #expect(
                Self.perft(&board, depth) == expected,
                "perft(\(depth)) for \(position.name)"
            )
        }
    }

    @Test("Searching and unsearching leaves the position untouched", arguments: positions)
    func treeWalkIsNonDestructive(position: Position) throws {
        var board = try #require(Board(fen: position.fen))
        let before = board
        _ = Self.perft(&board, 3)
        #expect(board == before, "\(position.name) came back changed")
    }
}

extension PerftTests.Position: CustomTestStringConvertible {
    var testDescription: String { name }
}
