//
//  RulesTests.swift
//  chessTests
//
//  How a game ends, and how moves are written down.
//

import Testing
@testable import chess

@Suite("Game rules")
struct RulesTests {

    private func play(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
        var game = Game(fen: fen)
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
        }
        return game
    }

    // MARK: Endings

    @Test("Fool's mate is checkmate for Black")
    func foolsMate() throws {
        let game = try play(["f2f3", "e7e5", "g2g4", "d8h4"])
        #expect(game.outcome == .checkmate(winner: .black))
        #expect(game.history.last?.san == "Qh4#")
        #expect(game.legalMoves.isEmpty)
    }

    @Test("A king with no move and no check is stalemate")
    func stalemate() {
        let game = Game(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        #expect(game.outcome == .stalemate)
        #expect(game.outcome.isDraw)
    }

    @Test("The same position three times is a draw")
    func threefoldRepetition() throws {
        let game = try play(["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"])
        #expect(game.outcome == .drawThreefoldRepetition)
    }

    @Test("The hundredth quiet half-move draws")
    func fiftyMoveRule() throws {
        let game = try play(["a1a2"], from: "8/8/4k3/8/8/8/8/R3K3 w - - 99 60")
        #expect(game.outcome == .drawFiftyMoveRule)
    }

    @Test("A pawn move resets the fifty-move count")
    func pawnMoveResetsTheClock() throws {
        let game = try play(["e2e3"], from: "8/8/4k3/8/8/8/4P3/4K3 w - - 99 60")
        #expect(game.outcome == .ongoing)
        #expect(game.board.halfmoveClock == 0)
    }

    @Test("Material too thin to mate is a draw", arguments: [
        ("8/8/4k3/8/8/8/8/4K3 w - - 0 1", true, "bare kings"),
        ("8/8/4k3/8/8/5B2/8/4K3 w - - 0 1", true, "king and bishop"),
        ("8/8/4k3/8/8/5N2/8/4K3 w - - 0 1", true, "king and knight"),
        ("8/8/2b1k3/8/8/5B2/8/4K3 w - - 0 1", true, "bishops on one colour"),
        ("8/8/4k3/8/8/3NN3/8/4K3 w - - 0 1", false, "two knights can mate, if helped"),
        ("8/8/5k2/8/8/3BB3/8/4K3 w - - 0 1", false, "bishops on both colours"),
        ("8/8/5k2/8/8/3BN3/8/4K3 w - - 0 1", false, "bishop and knight"),
        ("8/8/4k3/8/8/8/4P3/4K3 w - - 0 1", false, "a pawn can still promote"),
    ])
    func insufficientMaterial(fen: String, expected: Bool, note: String) throws {
        let board = try #require(Board(fen: fen))
        #expect(board.hasInsufficientMaterial == expected, "\(note)")
    }

    @Test("Resigning and agreeing a draw settle the game")
    func manualEndings() throws {
        var resigned = try play(["e2e4", "e7e5"])
        resigned.resign(.white)
        #expect(resigned.outcome == .resigned(winner: .black))
        #expect(resigned.legalMoves.isEmpty)

        var agreed = try play(["e2e4", "e7e5"])
        agreed.agreeToDraw()
        #expect(agreed.outcome == .drawAgreed)
        #expect(agreed.outcome.isDraw)
    }

    // MARK: Legality

    @Test("A king may not castle out of, through, or into check", arguments: [
        ("4k3/8/8/8/8/8/4r3/4K2R w K - 0 1", "out of check"),
        ("4k3/8/8/8/8/8/5r2/4K2R w K - 0 1", "through an attacked square"),
        ("4k3/8/8/8/8/8/6r1/4K2R w K - 0 1", "into check"),
    ])
    func castlingIsBlockedByCheck(fen: String, note: String) throws {
        let game = Game(fen: fen)
        #expect(!game.legalMoves.contains { $0.isCastleKingside }, "castled \(note)")
    }

    @Test("A pinned piece may not step off the pin")
    func pinnedPieceCannotMove() throws {
        // White knight on e2 is pinned to the king on e1 by the rook on e8.
        let game = Game(fen: "4r2k/8/8/8/8/8/4N3/4K3 w - - 0 1")
        let knightMoves = game.legalMoves.filter { $0.piece.kind == .knight }
        #expect(knightMoves.isEmpty, "the knight is pinned and cannot move")
    }

    // MARK: Notation

    @Test("Two pieces reaching one square are told apart by file")
    func disambiguationByFile() throws {
        let game = Game(fen: "4k3/8/8/3N1N2/8/8/8/4K3 w - - 0 1")
        let target = try #require(Square(algebraic: "e3"))
        let sans = game.legalMoves
            .filter { $0.piece.kind == .knight && $0.to == target }
            .map { game.board.san(for: $0) }
            .sorted()
        #expect(sans == ["Nde3", "Nfe3"])
    }

    @Test("Pieces on one file are told apart by rank")
    func disambiguationByRank() throws {
        let game = Game(fen: "4k3/8/8/3N4/8/3N4/8/4K3 w - - 0 1")
        let target = try #require(Square(algebraic: "b4"))
        let sans = game.legalMoves
            .filter { $0.piece.kind == .knight && $0.to == target }
            .map { game.board.san(for: $0) }
            .sorted()
        #expect(sans == ["N3b4", "N5b4"])
    }

    @Test("Three queens need the whole square")
    func disambiguationBySquare() throws {
        let game = Game(fen: "4k3/8/8/Q6Q/8/8/7Q/4K3 w - - 0 1")
        let target = try #require(Square(algebraic: "e5"))
        let sans = game.legalMoves
            .filter { $0.piece.kind == .queen && $0.to == target }
            .map { game.board.san(for: $0) }
            .sorted()
        // a5 is alone on its file, so the file alone identifies it; h2 shares
        // the h-file with h5 but is alone on rank 2; h5 shares both and needs
        // the whole square.
        #expect(sans == ["Q2e5+", "Qae5+", "Qh5e5+"])
    }

    @Test("Every move written can be read back as itself")
    func uciIdentifiesExactlyOneMove() throws {
        var game = Game()
        // A deterministic 60-ply walk through a real-looking game.
        for step in 0..<60 {
            let legal = game.legalMoves
            guard !legal.isEmpty else { break }
            let move = legal[(step * 7 + 3) % legal.count]
            let matching = legal.filter { $0.uci == move.uci }
            #expect(matching.count == 1, "\(move.uci) matched \(matching.count) moves")
            game.play(move)
        }
    }

    // MARK: Undo

    @Test("Undo puts the game back exactly where it was")
    func undoRestoresEverything() throws {
        var game = try play(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"])
        let fen = game.board.fen
        let hash = game.board.zobrist
        let historyCount = game.history.count

        game.play(try #require(game.legalMoves.first { $0.uci == "b5c6" }))
        game.undoLastMove()

        #expect(game.board.fen == fen)
        #expect(game.board.zobrist == hash)
        #expect(game.history.count == historyCount)
        #expect(game.outcome == .ongoing)
    }

    @Test("Undoing the mating move puts the game back in play")
    func undoClearsCheckmate() throws {
        var game = try play(["f2f3", "e7e5", "g2g4", "d8h4"])
        #expect(game.outcome.isGameOver)
        game.undoLastMove()
        #expect(game.outcome == .ongoing)
        #expect(!game.legalMoves.isEmpty)
    }

    // MARK: Saved games

    @Test("A saved game replays into the position it was saved from")
    func savedGamesRestore() throws {
        var game = Game()
        for step in 0..<40 {
            let legal = game.legalMoves
            guard !legal.isEmpty else { break }
            game.play(legal[(step * 5 + 1) % legal.count])
        }
        let saved = SavedGame(
            mode: .vsAI(difficulty: .medium, playerColor: .white),
            initialFEN: game.initialFEN,
            moveUCIs: game.history.map(\.move.uci),
            savedAt: .now
        )
        let restored = try #require(saved.restoreGame())
        #expect(restored.board.fen == game.board.fen)
        #expect(restored.history.map(\.san) == game.history.map(\.san))
    }

    @Test("A finished game remembers how it ended, even without a final move")
    func finishedGamesKeepTheirOutcome() throws {
        var game = try play(["e2e4", "e7e5"])
        game.resign(.white)
        let finished = FinishedGame(game: game, mode: .twoPlayer)
        let restored = try #require(finished.restoreGame())
        #expect(restored.outcome == .resigned(winner: .black))
    }
}
