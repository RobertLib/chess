//
//  SearchReviewFixesTests.swift
//  chessTests
//
//  One test per fault found in the review of the search and what the review
//  makes of it, each written to fail on the code as it was: a played move
//  scored only as deep as the mate the engine had found, a pinned pawn that
//  turned a winning fork into a brilliant sacrifice, a stalemate and a variant
//  win one ply past the horizon that quiescence could not see, and an
//  opening book that played the Englund Gambit and knew an opening only in
//  the order it was written down. One more holds the first fix to the hazard
//  it brings with it: a deeper search of the played move cut off part way.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN, variant: ChessVariant = .standard) throws -> Game {
    var game = Game(fen: fen, variant: variant)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

private func legalMove(_ uci: String, in board: Board) throws -> Move {
    try #require(board.generateLegalMoves().first { $0.uci == uci }, "no legal \(uci)")
}

/// Small budget, as in the other review suites: the mates below are a few
/// plies long and found long before it runs out.
private let quick = GameAnalyzer.Settings(maxDepth: 8, nodesPerPosition: 200_000, timeLimitPerPosition: 10)

private func review(_ game: Game, settings: GameAnalyzer.Settings = quick) -> GameAnalysis {
    let jobs = GameAnalyzer.positions(of: game)
    return GameAnalyzer.assemble(
        game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: settings) }
    )
}

// MARK: - The played move after a mate is found

@Suite("Fixes: the played move beside a forced mate")
struct FocusBesideMateFixesTests {

    /// Ra8 mates at once; Rb1 mates a move later, since the king has only g8
    /// and Rb8 follows. The search stopped at the depth the mate in one turned
    /// up at — one ply — and scored Rb1 there, as a rook up: graded a miss,
    /// accuracy 66, the curve jumping from +6.35 straight to mate.
    private let rookMate = "7k/8/6K1/8/8/8/8/R7 w - - 0 1"

    @Test("A slower forced mate is graded as a mate, not as a miss")
    func aSlowerMateIsStillAMate() throws {
        let analysis = review(try played(["a1b1"], from: rookMate))
        let rb1 = try #require(analysis.moves.first)
        #expect(SearchScore.mateInMoves(rb1.playedScore) == 2, "Rb1 scored \(rb1.playedScore)")
        #expect(!rb1.quality.isMistake, "Rb1 graded \(rb1.quality)")
        #expect(rb1.accuracy > 95, "accuracy \(rb1.accuracy)")
        #expect(rb1.centipawnLoss < 10)
        #expect(analysis.evalCurve.allSatisfy(SearchScore.isMate), "curve \(analysis.evalCurve)")
    }

    /// Every move the review's own search of the next position shows to be a
    /// forced mate has to be scored as one where it was played. Before, every
    /// one of them but the fastest came out a miss and cost the player a
    /// thousand centipawns each in the average.
    @Test("Every mating move is scored as a mate", arguments: [
        "4k3/8/8/8/8/8/1R6/R5K1 w - - 0 1",
        "k7/8/2K5/8/8/8/8/7Q w - - 0 1",
    ])
    func everyMatingMoveIsAMate(fen: String) throws {
        let board = try #require(Board(fen: fen))
        var mates = 0
        for move in board.generateLegalMoves() {
            let game = try played([move.uci], from: fen)
            let jobs = GameAnalyzer.positions(of: game)
            let results = jobs.map { GameAnalyzer.run($0, settings: quick) }
            // The mated side's own view of the position the move left: mated
            // in three at most, so a mate in four from the move itself —
            // seven plies, inside what `quick` can see from there.
            guard let after = results[1], let mated = SearchScore.mateInMoves(after.bestScore),
                  (-3)...(-1) ~= mated
            else { continue }
            mates += 1

            let analysis = GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
            let graded = try #require(analysis.moves.first)
            #expect((SearchScore.mateInMoves(graded.playedScore) ?? 0) > 0,
                    "\(graded.played.san) mates in \(1 - mated) but scored \(graded.playedScore)")
            #expect(!graded.quality.isMistake, "\(graded.played.san) graded \(graded.quality)")
            #expect(graded.centipawnLoss < 10, "\(graded.played.san) lost \(graded.centipawnLoss) cp")
        }
        #expect(mates >= 3, "only \(mates) mating moves to hold the review to")
    }

    /// Ra7 leaves the back rank to ...Re1#, where Qd8 would have mated first.
    /// Scored at the one ply the mate in one was found at, Ra7 kept a rook
    /// and a queen: a miss, +7.58.
    @Test("A move that walks into mate beside a mate on offer is a blunder")
    func walkingIntoMateBesideAMate() throws {
        let analysis = review(try played(["a1a7"], from: "6k1/5ppp/8/8/4p2Q/4r3/5PPP/R5K1 w - - 0 1"))
        let ra7 = try #require(analysis.moves.first)
        #expect(SearchScore.mateInMoves(ra7.playedScore) == -1, "Ra7 scored \(ra7.playedScore)")
        #expect(ra7.quality == .blunder, "Ra7 graded \(ra7.quality)")
        #expect(ra7.evalWhite < -SearchScore.mateThreshold, "shown as \(ra7.evalWhite)")
    }

    /// The mistake puzzle's check of a move other than the answer, as
    /// `PuzzleSessionModel.checkAlternative` makes it.
    private func acceptsAlternative(_ uci: String, in fen: String) throws -> Bool {
        let board = try #require(Board(fen: fen))
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 12,
            nodeBudget: 250_000, timeLimit: 4, focusMove: try legalMove(uci, in: board)
        ))
        let focus = try #require(analysis.focusScore)
        return WinChance.percent(centipawns: analysis.bestScore) - WinChance.percent(centipawns: focus) <= 3
    }

    @Test("A mistake puzzle takes a slower mate and refuses a move that allows one")
    func puzzleAlternatives() throws {
        #expect(try acceptsAlternative("a1b1", in: rookMate), "a forced mate in two was refused")
        // Ra3 lets ...Re1 mate, where either queen mates at once.
        #expect(try !acceptsAlternative("a1a3", in: "6k1/5ppp/8/8/Q3p2Q/4r3/5PPP/R5K1 w - - 0 1"),
                "a move that allows mate in one was accepted")
    }

    /// The played move goes on being deepened alone after the mate is found,
    /// and the budget can run out in the middle of one of those searches.
    /// What that search returned is no score, and taking it would grade the
    /// move on nothing; the last depth that finished has to stand. g3 here
    /// keeps a rook where Rd8 mates — it never becomes a mate either way, so
    /// every budget below ends part way through a search of it.
    @Test("A search of the played move the budget breaks off does not replace the last one that finished",
          arguments: [500, 2_000, 8_000, 30_000, 120_000])
    func anInterruptedDeepeningKeepsTheLastScore(budget: Int) throws {
        let board = try #require(Board(fen: "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1"))
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 30,
            nodeBudget: budget, timeLimit: 30, focusMove: try legalMove("g2g3", in: board)
        ))
        try #require(SearchScore.mateInMoves(analysis.bestScore) == 1)
        let g3 = try #require(analysis.focusScore)
        #expect(!SearchScore.isMate(g3))
        #expect(g3 > 300, "g3, a rook up, scored \(g3) on a budget of \(budget)")
        #expect(!analysis.isCutShort)
    }
}

// MARK: - Pinned defenders

@Suite("Fixes: an exchange with a pinned defender")
struct PinnedExchangeFixesTests {

    /// Nd5 forks the queen on c7 and the rook on f6. The e6 pawn attacks d5
    /// but is pinned to its king by Re1, so nothing can take the knight —
    /// the exchange counted exd5 anyway, called the fork a 320-centipawn
    /// sacrifice, and the review graded it brilliant and unlocked the
    /// achievement for it.
    private let fork = "4k3/2q5/4pr2/8/1N6/8/PP3PPP/4R1K1 w - - 0 1"

    @Test("A pawn pinned to its king does not take part in the exchange")
    func pinnedPawnCannotRecapture() throws {
        let board = try #require(Board(fen: fork))
        let nd5 = try legalMove("b4d5", in: board)
        #expect(board.staticExchangeEvaluation(nd5) == 0)
        #expect(GameAnalyzer.sacrifice(of: nd5, in: board) == 0)

        // The control: without the rook on e1 the pawn is free, and the
        // knight really is given up.
        let unpinned = try #require(Board(fen: "4k3/2q5/4pr2/8/1N6/8/PP3PPP/6K1 w - - 0 1"))
        #expect(unpinned.staticExchangeEvaluation(try legalMove("b4d5", in: unpinned))
                == -PieceKind.knight.centipawns)
    }

    @Test("A fork the pinned pawn cannot answer is not a brilliancy")
    func forkIsNotBrilliant() throws {
        let analysis = review(try played(["b4d5"], from: fork))
        let nd5 = try #require(analysis.moves.first)
        try #require(nd5.isBestMove, "the engine preferred \(nd5.bestSAN)")
        #expect(nd5.quality != .brilliant, "Nd5 graded brilliant for \(nd5.sacrifice) given up")
    }

    /// The same rule from the other side: a capture that leaves the
    /// capturer's king in check is not on offer either, so a side in check
    /// takes back only with a piece that also ends it. Bxd5 steps off the
    /// e-file and discovers check from the rook, and the queen that attacks
    /// d5 may not take.
    @Test("A side in check takes back only if that ends the check")
    func checkComesFirst() throws {
        let board = try #require(Board(fen: "3qk3/8/8/3p4/4B3/8/8/4R1K1 w - - 0 1"))
        let bxd5 = try legalMove("e4d5", in: board)
        #expect(board.staticExchangeEvaluation(bxd5) == PieceKind.pawn.centipawns)
    }
}

// MARK: - Stalemate at the horizon

@Suite("Fixes: stalemate at the horizon")
struct HorizonStalemateFixesTests {

    /// One ply deep, so the reply to the move is quiescence's to judge — and
    /// quiescence, out of check with no capture to make, stood pat: a
    /// stalemate scored as the material the stalemating side had left.
    private func scoreAtOnePly(_ uci: String, in fen: String) throws -> Int {
        let board = try #require(Board(fen: fen))
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 1,
            nodeBudget: 100_000, timeLimit: 10, focusMove: try legalMove(uci, in: board)
        ))
        return try #require(analysis.focusScore)
    }

    @Test("Stalemating a bare king is a draw, not a queen up")
    func bareKing() throws {
        // Qc7 takes every square from the king on a8; Qe8 would have mated.
        #expect(try scoreAtOnePly("d7c7", in: "k7/3Q4/1K6/8/8/8/8/8 w - - 0 1") == 0)
    }

    @Test("Stalemating a king whose pawns are blocked is a draw, not a pawn up")
    func kingAndBlockedPawn() throws {
        // Kf7 covers g7 and g8, and the h-pawn is blocked by its own number.
        #expect(try scoreAtOnePly("f6f7", in: "7k/7p/5K1P/8/8/8/P7/8 w - - 0 1") == 0)
    }
}

// MARK: - Variant wins at the horizon

@Suite("Fixes: variant wins at the horizon")
struct HorizonVariantWinFixesTests {

    /// White's rook can take the queen on b2, and then the black king steps
    /// from f6 onto e5. A king step captures nothing, so quiescence never
    /// looked at it, and one ply deep the queen was simply won.
    private let hill = "8/8/5k2/8/8/8/Rq6/7K w - - 0 1"

    @Test("A king step onto the hill past the horizon is seen")
    func kingOfTheHill() throws {
        let board = try played([], from: hill, variant: .kingOfTheHill).board
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 1,
            nodeBudget: 100_000, timeLimit: 10, focusMove: try legalMove("a2b2", in: board)
        ))
        #expect(SearchScore.mateInMoves(try #require(analysis.focusScore)) == -1,
                "Rxb2 scored \(analysis.focusScore ?? 0)")

        let shallow = AIStrength(maxDepth: 1, time: 10, temperature: 0, window: 0)
        let result = try #require(ChessAISearcher(board: board, gameHashes: [board.zobrist])
            .search(strength: shallow, randomSeed: 1))
        #expect(result.move.uci != "a2b2", "took the queen and let the king onto the hill")
    }

    /// Black has given two checks. After Rxb2 the rook's Rd1 is the third,
    /// and it captures nothing either.
    @Test("A quiet third check past the horizon is seen")
    func threeCheck() throws {
        let board = try played([], from: "3rk3/8/8/8/8/8/Rq6/7K w - - 3+1 0 1", variant: .threeCheck).board
        try #require(board.checksGiven.black == 2)
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 1,
            nodeBudget: 100_000, timeLimit: 10, focusMove: try legalMove("a2b2", in: board)
        ))
        #expect(SearchScore.mateInMoves(try #require(analysis.focusScore)) == -1,
                "Rxb2 scored \(analysis.focusScore ?? 0)")
    }
}

// MARK: - Opening book

@Suite("Fixes: opening book soundness and transpositions")
struct BookTranspositionFixesTests {

    private func bookName(of moves: String) -> String? {
        let moves = moves.split(separator: " ").map(String.init)
        return OpeningBook.lines.first { $0.moves == moves }.map { String(localized: $0.name) }
    }

    /// Every first move, or reply, the book picks from `sans` over many seeds.
    private func picks(after sans: [String]) throws -> Set<String> {
        var game = Game()
        for san in sans {
            game.play(try #require(game.legalMoves.first { game.board.san(for: $0) == san }, "no \(san)"))
        }
        var seen = Set<String>()
        for seed in 0..<3000 {
            if let move = OpeningBook.move(
                after: sans, in: game.board,
                randomSeed: UInt64(seed) &* 6_364_136_223_846_793_005 &+ 1
            ) {
                seen.insert(game.board.san(for: move))
            }
        }
        return seen
    }

    /// Weighted by line count, 1...e5 was one answer to 1.d4 in twenty-three
    /// and 1.g4 one first move in ninety: the top levels played the Englund
    /// Gambit and Grob's Attack out of the book.
    @Test("The computer plays only sound lines out of the book")
    func onlySoundLinesArePlayed() throws {
        let first = try picks(after: [])
        #expect(first.isDisjoint(with: ["g4", "b4"]), "opened \(first.sorted())")
        #expect(first.isSuperset(of: ["e4", "d4"]))
        let againstD4 = try picks(after: ["d4"])
        #expect(againstD4.isDisjoint(with: ["e5", "b5"]), "answered 1.d4 with \(againstD4.sorted())")
        #expect(againstD4.isSuperset(of: ["d5", "Nf6"]))
        let againstE4 = try picks(after: ["e4"])
        #expect(againstE4.isDisjoint(with: ["Nc6", "b6"]), "answered 1.e4 with \(againstE4.sorted())")
    }

    @Test("A dubious line is still named when a player chooses it")
    func dubiousLinesAreStillNamed() {
        let englund = OpeningBook.match(sans: ["d4", "e5"])
        #expect(englund.name == bookName(of: "d4 e5"))
        #expect(englund.bookPlies == 2)
        #expect(OpeningBook.match(sans: ["g4"]).name == bookName(of: "g4"))
    }

    /// 1.Nf3 d5 2.d4 Nf6 3.Bf4 is the London System by another road. Matched
    /// as a sequence it was the Réti, out of the book on the third move.
    @Test("An opening reached in another order is still that opening")
    func transpositionsAreNamed() {
        let london = OpeningBook.match(sans: ["Nf3", "d5", "d4", "Nf6", "Bf4"])
        #expect(london.name == bookName(of: "d4 d5 Nf3 Nf6 Bf4"))
        #expect(london.bookPlies == 5)

        // The Queen's Indian by way of 2.Nf3, a position the book does not
        // hold: named all the same, and judged from where it left theory.
        let queensIndian = OpeningBook.match(sans: ["d4", "Nf6", "Nf3", "e6", "c4", "b6"])
        #expect(queensIndian.name == bookName(of: "d4 Nf6 c4 e6 Nf3 b6"))
        #expect(queensIndian.bookPlies == 2)
    }

    @Test("The book carries on after a transposition")
    func bookFollowsATransposition() throws {
        let game = try played(["g1f3", "d7d5", "d2d4"])
        let reply = try #require(
            OpeningBook.move(after: game.history.map(\.san), in: game.board, randomSeed: 3),
            "the book had nothing to say about the position after 1.d4 d5 2.Nf3"
        )
        #expect(game.board.san(for: reply) == "Nf6")
    }

    @Test("The review names a transposed opening and leaves its moves unjudged")
    func reviewNamesATransposition() throws {
        let game = try played(["g1f3", "d7d5", "d2d4", "g8f6", "c1f4", "e7e6"])
        let jobs = GameAnalyzer.positions(of: game)
        // Every move the engine's own choice, so a move that is not graded
        // book is graded best and the two can be told apart.
        let results: [PositionAnalysis?] = jobs.map { job in
            guard let move = job.playedMove else { return nil }
            return PositionAnalysis(
                bestMove: move, bestScore: 20, focusScore: nil, hasCloseAlternative: true,
                legalMoveCount: job.board.generateLegalMoves().count, depth: 10, nodes: 1000
            )
        }
        let analysis = GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
        #expect(analysis.openingName == bookName(of: "d4 d5 Nf3 Nf6 Bf4"))
        #expect(analysis.moves.map(\.quality) == Array(repeating: .book, count: 5) + [.best])
    }
}
