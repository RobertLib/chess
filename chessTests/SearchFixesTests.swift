//
//  SearchFixesTests.swift
//  chessTests
//
//  One test per fault found in the search and the review that reads it, each
//  written to fail on the code as it was: a repetition counted one too early,
//  a walk into mate graded as a good move, and an opening book that quoted
//  theory at positions it was never written for.
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

/// White a queen up, both kings with a square beside them to step to and back.
private let queenUp = "6k1/5pp1/7p/8/8/8/5PPP/3Q2K1 w - - 0 1"

/// A depth cap rather than a clock, so the searches below finish the same way
/// on every machine.
private let fixedDepth = AIStrength(maxDepth: 6, time: 10, temperature: 0, window: 0)

// MARK: - Repetition

@Suite("Fixes: repetition")
struct RepetitionFixesTests {

    private func search(_ game: Game) throws -> AISearchResult {
        try #require(
            ChessAISearcher(board: game.board, gameHashes: game.repetitionHashes)
                .search(strength: fixedDepth, randomSeed: 1)
        )
    }

    /// Both kings step aside and back, once. A position the game had seen a
    /// single time before used to count as its own repetition, so the review
    /// scored White's step back as throwing a queen's worth of advantage away
    /// — graded Miss, the curve dropping to 0.00 — and Black's shuffles as the
    /// only moves that saved the game.
    @Test("A position seen once before is not yet a draw")
    func aSecondOccurrenceIsNotADraw() throws {
        let game = try played(["g1h1", "g8h7", "h1g1", "h7g8", "g1h1", "g8h7"], from: queenUp)
        let jobs = GameAnalyzer.positions(of: game)
        let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5)
        let analysis = GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )

        #expect(analysis.evalCurve.allSatisfy { $0 > 500 }, "curve \(analysis.evalCurve)")
        for move in analysis.moves {
            #expect(!move.quality.isMistake && !move.quality.isStandout,
                    "\(move.played.san) graded \(move.quality), \(move.playedScore) against \(move.bestScore)")
        }
    }

    /// The same mistake from the losing side: stepping back to where the
    /// king came from looked like a draw, so the search preferred it to
    /// every move that merely lost.
    @Test("Going back once does not save the side that is lost")
    func aSecondOccurrenceDoesNotSaveTheLoser() throws {
        let game = try played(["g1h1", "g8h7", "h1g1"], from: queenUp)
        let result = try search(game)
        #expect(result.score < -500, "\(result.move.uci) scored \(result.score)")

        let kg8 = try #require(game.legalMoves.first { $0.uci == "h7g8" })
        let analysis = try #require(analyzePosition(
            board: game.board, gameHashes: game.repetitionHashes, maxDepth: 6,
            nodeBudget: 40_000, timeLimit: 5, focusMove: kg8
        ))
        #expect(try #require(analysis.focusScore) < -500, "Kg8 scored \(analysis.focusScore ?? 0)")
    }

    /// The third occurrence is a real draw, and the search must still know
    /// it: Kg8 brings the starting position round for the third time.
    @Test("A side that is lost still takes the threefold repetition")
    func theLoserTakesTheThirdOccurrence() throws {
        let game = try played(
            ["g1h1", "g8h7", "h1g1", "h7g8", "g1h1", "g8h7", "h1g1"], from: queenUp
        )
        let result = try search(game)
        #expect(result.move.uci == "h7g8", "played \(result.move.uci) for \(result.score)")
        #expect(result.score == 0)

        var after = game
        after.play(result.move)
        #expect(after.outcome == .drawThreefoldRepetition)
    }

    /// The same cycle started with Black to move, so that it is White's Kg1
    /// that would bring a position round for the third time.
    @Test("A side that is winning steers clear of the threefold repetition")
    func theWinnerAvoidsTheThirdOccurrence() throws {
        let fen = queenUp.replacingOccurrences(of: " w ", with: " b ")
        let game = try played(
            ["g8h7", "g1h1", "h7g8", "h1g1", "g8h7", "g1h1", "h7g8"], from: fen
        )
        var drawn = game
        drawn.play(try #require(game.legalMoves.first { $0.uci == "h1g1" }))
        try #require(drawn.outcome == .drawThreefoldRepetition)

        let result = try search(game)
        #expect(result.move.uci != "h1g1")
        #expect(result.score > 500, "\(result.move.uci) scored \(result.score)")
    }
}

// MARK: - Grading mates

@Suite("Fixes: grading mates")
struct MateGradingFixesTests {

    private func grade(best: Int, played: Int) -> MoveQuality {
        GameAnalyzer.classify(
            bestScore: best, playedScore: played, isBest: false, hasCloseAlternative: true,
            sacrifice: 0, legalMoveCount: 30, isRecapture: false, wasInCheck: false, isBook: false
        )
    }

    /// Mated in one, from the mover's point of view.
    private let mated = -(SearchScore.mate - 2)

    /// Below -7 win expectancy hardly moves, so walking into mate from -9
    /// measured as a loss of three points and was graded Good.
    @Test("Walking into a forced mate is graded by how lost the position was", arguments: [
        (-1500, MoveQuality.inaccuracy),
        (-916, MoveQuality.mistake),
        (-400, MoveQuality.blunder),
        (50, MoveQuality.blunder),
    ])
    func walkingIntoMate(before: Int, expected: MoveQuality) {
        #expect(grade(best: before, played: mated) == expected)
    }

    /// A long mate thrown away used to be excused entirely whenever the
    /// position stayed above +6, however much of the win went with it.
    @Test("Letting a long forced mate go is graded by what is left", arguments: [
        (1500, MoveQuality.inaccuracy),
        (850, MoveQuality.mistake),
        (650, MoveQuality.miss),
        (300, MoveQuality.miss),
        (-200, MoveQuality.blunder),
    ])
    func lettingALongMateGo(after: Int, expected: MoveQuality) {
        let mateInEight = SearchScore.mate - 15
        #expect(grade(best: mateInEight, played: after) == expected)
    }

    @Test("A short mate let go is still a miss, and a move that keeps the verdict is not marked down")
    func mateRulesLeaveTheRestAlone() {
        // Mate in two, played into a position that is merely winning.
        #expect(grade(best: SearchScore.mate - 3, played: 1500) == .miss)
        // A slower mate is still a mate.
        #expect(!grade(best: SearchScore.mate - 3, played: SearchScore.mate - 15).isMistake)
        // Already being mated, and mated a little sooner.
        #expect(!grade(best: -(SearchScore.mate - 15), played: mated).isMistake)
    }

    /// The reviewer's own example: a queen down, Kh8 allows Qd8 mate where a
    /// pawn move would have given the king room.
    @Test("The review marks a walk into mate")
    func theReviewMarksAWalkIntoMate() throws {
        let game = try played(["g8h8"], from: "6k1/5ppp/8/8/8/8/5PPP/3Q2K1 b - - 0 1")
        let jobs = GameAnalyzer.positions(of: game)
        let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5)
        let analysis = GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )
        let kh8 = try #require(analysis.moves.first)
        try #require(SearchScore.mateInMoves(kh8.playedScore) == -1)
        #expect(kh8.quality.isMistake, "graded \(kh8.quality) from \(kh8.bestScore)")
    }
}

// MARK: - Opening book

@Suite("Fixes: opening book")
struct BookFixesTests {

    /// Back-rank mate in one, with three of the book's first moves legal.
    private let mateInOne = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"

    @Test("The book answers only for the position its moves lead to")
    func bookChecksThePosition() throws {
        let puzzle = try #require(Board(fen: mateInOne))
        #expect(OpeningBook.move(after: [], in: puzzle, randomSeed: 1) == nil)
        // A history whose next move, Nf3, is legal here too — but this board
        // is not where 1.e4 e5 leads.
        #expect(OpeningBook.move(after: ["e4", "e5"], in: .initial, randomSeed: 1) == nil)

        #expect(OpeningBook.move(after: [], in: .initial, randomSeed: 1) != nil)
        let afterE4 = try played(["e2e4"], from: Board.startFEN)
        #expect(OpeningBook.move(after: ["e4"], in: afterE4.board, randomSeed: 1) != nil)
    }

    /// `bookSANs` defaults to empty, which read as "nothing played yet"
    /// whatever the board: Hard answered mates in two and three with 1.g4.
    @Test("The top level mates instead of quoting theory")
    func bookStaysOutOfOtherPositions() throws {
        let board = try #require(Board(fen: mateInOne))
        let result = try #require(GameAIEngine().bestMove(
            board: board, gameHashes: [board.zobrist], difficulty: .hard, randomSeed: 1
        ))
        #expect(!result.isBookMove)
        #expect(result.move.uci == "a1a8", "played \(result.move.uci)")
    }
}
