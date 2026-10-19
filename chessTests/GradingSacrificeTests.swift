//
//  GradingSacrificeTests.swift
//  chessTests
//
//  One test per fault found in the review of the grades a decisive move can
//  get, each written to fail on the code as it was: a sacrifice that forced
//  mate judged by its own score, and so never brilliant; a mate that was the
//  only move there was never great, because a decided position asked nothing
//  of its alternatives; and a pawn that took on its last rank in the middle
//  of an exchange counted as a pawn rather than as the queen it became. The
//  rest hold the line on the other side: a game won anyway, and a mate among
//  several, single nothing out.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String) throws -> Game {
    var game = Game(fen: fen)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

/// Small budget, as in the other review suites. The mates below turn up at
/// two or three plies; what the budget buys is the deeper look at their
/// alternatives.
private let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5)

/// The first move of `game` as the review grades it, together with the search
/// that graded it. Only the position the move was played in is searched: its
/// grade does not depend on the one after it.
private func firstMove(of game: Game) throws -> (move: MoveAnalysis, search: PositionAnalysis) {
    let jobs = GameAnalyzer.positions(of: game)
    let search = try #require(GameAnalyzer.run(jobs[0], settings: quick))
    var results = [PositionAnalysis?](repeating: nil, count: jobs.count)
    results[0] = search
    let analysis = GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
    return (try #require(analysis.moves.first), search)
}

// MARK: - Sacrifices

@Suite("Fixes: sacrifices that win outright")
struct DecisiveSacrificeFixesTests {

    nonisolated struct Case: CustomTestStringConvertible {
        let name: String
        let fen: String
        let uci: String
        var testDescription: String { name }
    }

    /// First moves of bundled puzzles tagged as mating sacrifices, from the
    /// position the setup move leaves, and Philidor's legacy with Black a
    /// queen and a rook to the good, so that nothing but the mate will do.
    nonisolated static let mates: [Case] = [
        Case(name: "9jLwF, Qxh7+", fen: "3r2k1/1b3rBp/4pPp1/p7/1pqP1R1Q/P7/6PP/5RK1 w - - 0 31", uci: "h4h7"),
        Case(name: "0CYwL, Rxh7+", fen: "r2q1r1k/1ppb2pp/1n3b2/p6R/P7/1B1P3P/1PP2PP1/R1BQ2K1 w - - 5 21", uci: "h5h7"),
        Case(name: "BvoWt, Nf6+", fen: "r1b2rk1/ppp2pp1/7p/n7/4N1qn/2PQ4/P1B2PPP/R1B2RK1 w - - 8 17", uci: "e4f6"),
        Case(name: "smothered, Qg8+", fen: "r4r1k/6pp/7N/3Q4/1q6/8/5PPP/6K1 w - - 0 1", uci: "d5g8"),
    ]

    /// The sacrifice's own score is the score of the line it starts, so a
    /// sacrifice that forced mate measured as a position won already — 100 —
    /// and the gate meant for a player winning outright without it shut on
    /// every mating combination there is.
    @Test("A sacrifice that forces mate is brilliant", arguments: mates)
    func matingSacrificeIsBrilliant(testCase: Case) throws {
        let (move, search) = try firstMove(of: try played([testCase.uci], from: testCase.fen))
        try #require(move.isBestMove, "the engine preferred \(move.bestSAN)")
        try #require((SearchScore.mateInMoves(move.playedScore) ?? 0) > 0, "scored \(move.playedScore)")
        try #require(move.sacrifice >= GameAnalyzer.minimumSacrifice, "gives up only \(move.sacrifice)")
        #expect(search.alternativeWinsOutright == false)
        #expect(move.quality == .brilliant, "\(move.played.san) graded \(move.quality)")
    }

    /// The same smothered mate with Black's queen and rook gone: White is a
    /// queen and a knight against a rook, and wins outright whatever it plays.
    @Test("A sacrifice in a game won anyway is not brilliant")
    func sacrificeInAWonGameIsNotBrilliant() throws {
        let (move, search) = try firstMove(of: try played(["d5g8"], from: "5r1k/6pp/7N/3Q4/8/8/5PPP/6K1 w - - 0 1"))
        try #require(move.isBestMove, "the engine preferred \(move.bestSAN)")
        try #require(move.sacrifice >= GameAnalyzer.minimumSacrifice)
        #expect(search.alternativeWinsOutright == true)
        #expect(move.quality == .best, "Qg8+ graded \(move.quality)")
    }

    @Test("A decisive sacrifice is judged by what else there was")
    func theGateReadsTheAlternatives() {
        func grade(best: Int, close: Bool = true, alternativeWins: Bool?) -> MoveQuality {
            GameAnalyzer.classify(
                bestScore: best, playedScore: best, isBest: true, hasCloseAlternative: close,
                alternativeWinsOutright: alternativeWins, sacrifice: 400, legalMoveCount: 30,
                isRecapture: false, wasInCheck: false, isBook: false
            )
        }
        let mateInTwo = SearchScore.mate - 3
        #expect(grade(best: mateInTwo, alternativeWins: false) == .brilliant)
        #expect(grade(best: 1200, alternativeWins: false) == .brilliant)
        // Something else won outright too: a showier way to win.
        #expect(grade(best: mateInTwo, alternativeWins: true) == .best)
        // Not asked, or not answered in time: no brilliancy on a guess.
        #expect(grade(best: mateInTwo, alternativeWins: nil) == .best)
        #expect(grade(best: mateInTwo, close: false, alternativeWins: nil) == .great)
        // Below the line the question never arises.
        #expect(grade(best: 60, alternativeWins: nil) == .brilliant)
    }

    @Test("The line the search draws is the line the grading draws")
    func wonOutrightIsOneLine() {
        let score = WinChance.lowestScore(above: GameAnalyzer.wonOutright)
        #expect(WinChance.percent(centipawns: score) > GameAnalyzer.wonOutright)
        #expect(WinChance.percent(centipawns: score - 1) <= GameAnalyzer.wonOutright)
    }
}

// MARK: - Only-moves

@Suite("Fixes: only-moves in won positions")
struct DecisiveOnlyMoveFixesTests {

    /// Puzzle 3yG1w after 1.Rxa1: Qxf2+ Kh1 Qf1+ Rxf1 Rxf1 mates. White is a
    /// pawn up, and nothing else Black has comes near — but a position with a
    /// mate on the board asked its alternatives nothing, and the review
    /// called the mate merely best.
    @Test("The one mate there is is great")
    func theOnlyMateIsGreat() throws {
        let (move, search) = try firstMove(of: try played(["c2f2"], from: "5r1k/6p1/4Q2p/8/8/8/2q2PPP/R5K1 b - - 0 29"))
        try #require(move.isBestMove, "the engine preferred \(move.bestSAN)")
        try #require((SearchScore.mateInMoves(move.playedScore) ?? 0) > 0, "scored \(move.playedScore)")
        #expect(!search.hasCloseAlternative)
        #expect(move.quality == .great, "Qxf2+ graded \(move.quality)")
    }

    /// Queen and rook against a bare king on the back rank: Re8 and Qd8 both
    /// mate at once.
    @Test("A mate among several is not singled out", arguments: ["e1e8", "d1d8"])
    func oneMateOfSeveral(uci: String) throws {
        let (move, search) = try firstMove(of: try played([uci], from: "7k/6pp/8/8/8/8/5PPP/3QR1K1 w - - 0 1"))
        try #require(move.isBestMove)
        #expect(search.hasCloseAlternative)
        #expect(move.quality == .best, "\(move.played.san) graded \(move.quality)")
    }

    /// Mating a bare king takes a string of best moves, the mate included,
    /// and every one of them has others beside it that win just as surely.
    @Test("Winning an ending that is won already singles nothing out", arguments: [
        ("8/8/4k3/8/8/8/8/3QK3 w - - 0 1", "d1d4 e6f5 d4d6 f5e4 e1f2 e4f5 f2f3 f5g5 d6e6 g5h5 f3f4 h5h4 e6h6"),
        ("8/8/3k4/8/8/8/8/R3K2R w - - 0 1", "a1a6 d6c5 h1h5 c5b4 e1d2 b4c4 a6b6 c4d4 b6b4"),
    ])
    func wonEndingsHaveNoStandouts(fen: String, moves: String) throws {
        let game = try played(moves.split(separator: " ").map(String.init), from: fen)
        try #require(game.board.isInCheck && game.legalMoves.isEmpty, "the line does not end in mate")
        let jobs = GameAnalyzer.positions(of: game)
        let analysis = GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )
        for move in analysis.moves {
            #expect(!move.quality.isStandout && !move.quality.isMistake,
                    "\(move.played.san) graded \(move.quality), \(move.playedScore) against \(move.bestScore)")
        }
    }
}

// MARK: - Promotion in the exchange

@Suite("Fixes: promotion in the exchange")
struct PromotingExchangeFixesTests {

    private func exchange(_ uci: String, in fen: String) throws -> Int {
        let board = try #require(Board(fen: fen))
        let move = try #require(board.generateLegalMoves().first { $0.uci == uci }, "no legal \(uci)")
        return board.staticExchangeEvaluation(move)
    }

    private let rook = PieceKind.rook.centipawns
    private let queening = PieceKind.queen.centipawns - PieceKind.pawn.centipawns

    /// Rd1 next to a pawn on e2: exd1 takes the rook and queens, and there is
    /// nothing to take back with. The swap list counted the rook and left the
    /// pawn standing on d1 as a pawn.
    @Test("A pawn that takes on its last rank queens as it takes")
    func recaptureOntoTheLastRankQueens() throws {
        #expect(try exchange("a1d1", in: "7k/8/8/8/8/7K/4p3/R7 w - - 0 1") == -(rook + queening))
        // White's pawn the same way up the board.
        #expect(try exchange("a8d8", in: "r6k/4P3/8/8/8/8/8/7K b - - 0 1") == -(rook + queening))
    }

    /// With a knight to take back, the new queen goes straight away, so White
    /// is down the rook for the pawn. Counting the promotion and leaving the
    /// pawn on the square would have had the knight win 100 for the 900 it
    /// took, and called the exchange −1200.
    @Test("What the next capture wins is the queen, not the pawn")
    func theQueenIsWhatGetsTaken() throws {
        #expect(try exchange("a1d1", in: "7k/8/8/8/8/2N4K/4p3/R7 w - - 0 1")
                == -(rook - PieceKind.pawn.centipawns))
    }

    @Test("A piece standing where a pawn can take it and queen risks the queen as well")
    func materialAtRiskCountsTheQueen() throws {
        let board = try #require(Board(fen: "7k/8/8/8/8/7K/4p3/3R4 w - - 0 1"))
        let d1 = try #require(Square(algebraic: "d1"))
        #expect(board.materialAtRisk(on: d1) == rook + queening)
    }
}
