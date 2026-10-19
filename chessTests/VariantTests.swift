//
//  VariantTests.swift
//  chessTests
//
//  King of the Hill and three-check: what wins them, what no longer draws,
//  that the check count is part of the position, and that the engine plays
//  for the variant's own win.
//

import Foundation
import Testing
@testable import chess

@Suite("Variants")
struct VariantTests {

    private func play(_ game: inout Game, _ ucis: [String]) throws {
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci) in \(game.board.fen)"))
        }
    }

    // MARK: King of the Hill

    @Test("A king on a centre square wins King of the Hill")
    func hill() throws {
        var game = Game(fen: "k7/8/8/8/8/4K3/8/8 w - - 0 1", variant: .kingOfTheHill)
        #expect(game.outcome == .ongoing, "two bare kings are no draw on the hill")
        try play(&game, ["e3e4"])
        #expect(game.outcome == .kingOfTheHill(winner: .white))
        #expect(game.outcome.winner == .white)
    }

    @Test("Standard chess still calls the same position a draw")
    func standardStillDraws() {
        #expect(Game(fen: "k7/8/8/8/8/4K3/8/8 w - - 0 1").outcome == .drawInsufficientMaterial)
    }

    @Test("The engine walks onto the hill when it can")
    func engineTakesTheHill() throws {
        var board = try #require(Board(fen: "k7/8/8/8/8/4K3/8/7r w - - 0 1"))
        board.variant = .kingOfTheHill
        board.zobrist = board.computeZobrist()
        let result = try #require(ChessAISearcher(board: board, gameHashes: [board.zobrist])
            .search(strength: AIDifficulty.hard.strength, randomSeed: 1))
        #expect(Board.isHill(result.move.to.index), "played \(result.move.uci) instead of stepping onto the hill")
        #expect(SearchScore.isMate(result.score))
    }

    // MARK: Three-check

    @Test("The third check wins three-check")
    func threeChecks() throws {
        // The white queen shuttles between checks; the black king steps aside.
        var game = Game(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1", variant: .threeCheck)
        try play(&game, ["d1d7"])
        #expect(game.board.checksGiven.white == 1)
        try play(&game, ["e8f8", "d7d8"])
        #expect(game.board.checksGiven.white == 2)
        #expect(game.outcome == .ongoing)
        try play(&game, ["f8g7", "d8e7"])
        #expect(game.outcome == .threeChecks(winner: .white))
    }

    @Test("The check count is part of the position's hash, and undo restores it")
    func hashing() throws {
        var board = try #require(Board(fen: "r3k2r/pppq1ppp/2npbn2/2b1p3/2B1P3/2NPBN2/PPPQ1PPP/R3K2R w KQkq - 0 1"))
        board.variant = .threeCheck
        board.zobrist = board.computeZobrist()
        var rng = Zobrist.SplitMix64(seed: 99)
        for _ in 0..<400 {
            let legal = board.generateLegalMoves()
            guard !legal.isEmpty, board.variantWinner == nil else { break }
            let move = legal[Int(rng.next() % UInt64(legal.count))]
            let before = board
            let undo = board.make(move)
            #expect(board.zobrist == board.computeZobrist(), "incremental hash drifted after \(move.uci)")
            var restored = board
            restored.unmake(move, undo: undo)
            #expect(restored == before, "unmake did not restore \(move.uci)")
            if board.halfmoveClock > 60 { break }
        }
        // Two positions that differ only in the count are different positions.
        var one = try #require(Board(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"))
        one.variant = .threeCheck
        var two = one
        two.checksGiven.white = 1
        #expect(one.computeZobrist() != two.computeZobrist())
    }

    @Test("Two checks given, the engine finds the third")
    func engineGivesTheThirdCheck() throws {
        // The e-file is open, so Qe2+ is there to be found — and nothing
        // else on the board is worth half as much as the game.
        var board = try #require(Board(fen: "4k3/pppp1ppp/8/8/8/8/PPPP1PPP/R2QK2R w KQ - 0 1"))
        board.variant = .threeCheck
        board.checksGiven.white = 2
        board.zobrist = board.computeZobrist()
        let result = try #require(ChessAISearcher(board: board, gameHashes: [board.zobrist])
            .search(strength: AIDifficulty.hard.strength, randomSeed: 3))
        var after = board
        after.make(result.move)
        #expect(after.variantWinner == .white, "played \(result.move.uci), which is not a check")
    }

    @Test("Bare kings are still a draw in three-check, a knight is not")
    func threeCheckMaterial() {
        #expect(Game(fen: "k7/8/8/8/8/8/8/7K w - - 0 1", variant: .threeCheck).outcome == .drawInsufficientMaterial)
        #expect(Game(fen: "k7/8/8/8/8/8/8/6NK w - - 0 1", variant: .threeCheck).outcome == .ongoing)
    }

    @Test("Undo replays under the game's own rules")
    func undoKeepsTheVariant() throws {
        var game = Game(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1", variant: .threeCheck)
        try play(&game, ["d1d7", "e8f8", "d7d8"])
        game.undoLastMove()
        #expect(game.variant == .threeCheck)
        #expect(game.board.checksGiven.white == 1)
    }

    @Test("Variant games travel through PGN under their own name")
    func pgn() throws {
        var game = Game(fen: Board.startFEN, variant: .kingOfTheHill)
        try play(&game, ["e2e4", "e7e5"])
        let text = PGN.export(game: game)
        #expect(text.contains("[Variant \"King of the Hill\"]"))
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.variant == .kingOfTheHill)
        #expect(PGN.variant(named: "Three-check") == .threeCheck)
    }
}

@Suite("Variant games", .serialized)
@MainActor
struct VariantGameTests {

    @Test("A saved three-check game comes back with its checks counted")
    func savedGame() throws {
        try withScratchStore("variantSaved") {
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(start: .custom(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"), variant: .threeCheck)
            )
            let check = try #require(model.game.legalMoves.first { $0.uci == "d1d7" })
            model.handleTap(on: check.from)
            model.handleTap(on: check.to)
            #expect(model.game.board.checksGiven.white == 1)
            model.teardown()
            let saved = try #require(SavedGame.load())
            let restored = try #require(saved.restoreGame())
            #expect(restored.variant == .threeCheck)
            #expect(restored.board.checksGiven.white == 1)
        }
    }

    @Test("The hill is marked on the board")
    func hillIsDrawn() throws {
        withScratchStore("variantHill") {
            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings(),
                                      options: GameOptions(variant: .kingOfTheHill))
            defer { model.teardown() }
            #expect(Set(model.decorations.zone.map(\.index)) == Set(Board.hillSquares))
        }
    }
}
