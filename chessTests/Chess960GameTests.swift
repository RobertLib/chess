//
//  Chess960GameTests.swift
//  chessTests
//
//  Chess960 as the board plays it: castling by tapping the rook or the
//  king's square, the drawn pieces keeping up when king and rook swap places,
//  and whole games from shuffled starts staying in step with the position.
//

import Foundation
import Testing
@testable import chess

@Suite("Chess960 on the board", .serialized)
@MainActor
struct Chess960BoardPlayTests {

    private func expectDrawnCorrectly(_ model: GameViewModel, _ context: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        var drawn = [UInt8](repeating: 0, count: 64)
        for piece in model.pieces {
            #expect(drawn[piece.square.index] == 0, "\(context): two pieces on \(piece.square)",
                    sourceLocation: sourceLocation)
            drawn[piece.square.index] = piece.piece.packed
        }
        #expect(drawn == model.game.board.squares, "\(context): the drawn board is not the position",
                sourceLocation: sourceLocation)
    }

    private func model(_ fen: String) -> GameViewModel {
        GameViewModel(mode: .twoPlayer, settings: AppSettings(), options: GameOptions(start: .custom(fen: fen)))
    }

    /// Rooks on b1 and g1, king on e1: castling kingside lands the king on the
    /// rook's own square, and castling queenside sends the rook past the king.
    private let crossing = "1r2k1r1/pppppppp/8/8/8/8/PPPPPPPP/1R2K1R1 w GBgb - 0 1"

    @Test("Tapping the rook castles, and the king lands where the rook stood")
    func castleOntoTheRook() throws {
        try withScratchStore("chess960Rook") {
            let model = model(crossing)
            defer { model.teardown() }
            #expect(model.game.board.isChess960)
            model.handleTap(on: Square(algebraic: "e1")!)
            model.handleTap(on: Square(algebraic: "g1")!)
            let last = try #require(model.game.lastMove)
            #expect(last.isCastleKingside)
            #expect(model.game.board.piece(at: Square(algebraic: "g1")!) == Piece(.white, .king))
            #expect(model.game.board.piece(at: Square(algebraic: "f1")!) == Piece(.white, .rook))
            expectDrawnCorrectly(model, "after O-O")
        }
    }

    @Test("Tapping the king's destination castles too")
    func castleByDestination() throws {
        try withScratchStore("chess960Destination") {
            let model = model(crossing)
            defer { model.teardown() }
            model.handleTap(on: Square(algebraic: "e1")!)
            model.handleTap(on: Square(algebraic: "c1")!)
            let last = try #require(model.game.lastMove)
            #expect(last.isCastleQueenside, "c1 holds nothing the king could reach but the castle")
            #expect(model.game.board.piece(at: Square(algebraic: "c1")!) == Piece(.white, .king))
            #expect(model.game.board.piece(at: Square(algebraic: "d1")!) == Piece(.white, .rook))
            expectDrawnCorrectly(model, "after O-O-O")
        }
    }

    @Test("Whole games from shuffled starts keep the drawn board in step",
          arguments: [0, 1, 105, 333, 518, 700, 959])
    func shuffledGames(_ number: Int) throws {
        try withScratchStore("chess960Games\(number)") {
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(start: .chess960(number: number))
            )
            defer { model.teardown() }
            #expect(model.game.board.isChess960)
            var rng = Zobrist.SplitMix64(seed: UInt64(number) &+ 17)
            var castles = 0
            for ply in 0..<120 {
                let legal = model.game.legalMoves
                guard !legal.isEmpty else { break }
                // A castle whenever one is on offer, so every start gets to
                // exercise it; otherwise any move at all.
                let move = legal.first(where: \.isCastle) ?? legal[Int(rng.next() % UInt64(legal.count))]
                if move.isCastle { castles += 1 }
                model.handleTap(on: move.from)
                model.handleTap(on: move.to)
                if model.pendingPromotion != nil { model.completePromotion(with: move.promotion ?? .queen) }
                #expect(model.game.lastMove == move, "ply \(ply): the board would not play \(move.uci)")
                expectDrawnCorrectly(model, "position \(number), ply \(ply)")
                if model.game.outcome.isGameOver { break }
            }
            // The saved game comes back as the same Chess960 game.
            if !model.game.outcome.isGameOver, let saved = SavedGame.load() {
                let restored = try #require(saved.restoreGame())
                #expect(restored.board == model.game.board)
            }
            _ = castles
        }
    }
}
