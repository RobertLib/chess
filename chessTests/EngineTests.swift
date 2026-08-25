//
//  EngineTests.swift
//  chessTests
//
//  The search, the static exchange evaluation and the review that reads them.
//

import Foundation
import Testing
@testable import chess

@Suite("Static exchange")
struct StaticExchangeTests {

    nonisolated struct Case {
        let name: String
        let fen: String
        let uci: String
        let expected: Int
    }

    nonisolated static let cases: [Case] = [
        Case(name: "an undefended pawn is free",
             fen: "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", uci: "e4d5", expected: 100),
        Case(name: "pawn takes pawn, knight takes back",
             fen: "4k3/8/1n6/3p4/4P3/8/8/4K3 w - - 0 1", uci: "e4d5", expected: 0),
        Case(name: "a queen must not take a defended pawn",
             fen: "4k3/8/1n6/3p4/8/8/8/3QK3 w - - 0 1", uci: "d1d5", expected: -800),
        Case(name: "nor may a rook",
             fen: "4k3/8/1n6/3p4/8/8/8/3RK3 w - - 0 1", uci: "d1d5", expected: -400),
        Case(name: "a hanging rook is worth taking",
             fen: "4k3/8/8/3r4/8/8/8/3RK3 w - - 0 1", uci: "d1d5", expected: 500),
        Case(name: "a defended rook is an even trade",
             fen: "4k3/3r4/8/3r4/8/8/8/3RK3 w - - 0 1", uci: "d1d5", expected: 0),
        Case(name: "doubled rooks see through each other",
             fen: "4k3/3r4/8/3r4/8/8/3R4/3RK3 w - - 0 1", uci: "d2d5", expected: 500),
        Case(name: "a pawn defends as well as anything",
             fen: "4k3/8/2p5/3p4/4P3/8/8/4K3 w - - 0 1", uci: "e4d5", expected: 0),
        Case(name: "Bxf7+ gives up a bishop for a pawn",
             fen: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1",
             uci: "c4f7", expected: -230),
    ]

    @Test("Swap-list values are exact", arguments: cases)
    func exchangeValues(testCase: Case) throws {
        let board = try #require(Board(fen: testCase.fen))
        let move = try #require(board.generateLegalMoves().first { $0.uci == testCase.uci })
        #expect(board.staticExchangeEvaluation(move) == testCase.expected)
    }
}

extension StaticExchangeTests.Case: CustomTestStringConvertible {
    var testDescription: String { name }
}

// MARK: - Search

@Suite("Search")
struct SearchTests {

    nonisolated struct MateCase {
        let name: String
        let fen: String
        let uci: String
    }

    nonisolated static let mates: [MateCase] = [
        MateCase(name: "back-rank rook", fen: "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", uci: "a1a8"),
        MateCase(name: "queen to the eighth", fen: "7k/6pp/8/8/8/8/5Q2/6K1 w - - 0 1", uci: "f2f8"),
        MateCase(name: "rook mate with the king cutting off", fen: "k7/8/1K6/8/8/8/8/7R w - - 0 1", uci: "h1h8"),
        MateCase(name: "Black mates on the back rank", fen: "3rkr2/8/8/8/8/8/6PP/6K1 b - - 0 1", uci: "d8d1"),
    ]

    @Test("Mate in one is found", arguments: mates)
    func findsMateInOne(testCase: MateCase) throws {
        let board = try #require(Board(fen: testCase.fen))
        let result = try #require(
            findBestAIMove(board: board, gameHashes: [board.zobrist],
                           difficulty: .hard, randomSeed: 1)
        )
        #expect(result.move.uci.hasPrefix(testCase.uci))
        #expect(SearchScore.isMate(result.score))
    }

    @Test("The same seed always plays the same move")
    func searchIsDeterministic() throws {
        let board = Board.initial
        let first = findBestAIMove(board: board, gameHashes: [board.zobrist],
                                   difficulty: .easy, randomSeed: 99)
        let second = findBestAIMove(board: board, gameHashes: [board.zobrist],
                                    difficulty: .easy, randomSeed: 99)
        #expect(first?.move == second?.move)
    }

    @Test("Easier levels vary their openings")
    func lowDifficultyVaries() {
        let board = Board.initial
        var seen = Set<String>()
        for seed in 1...12 {
            if let result = findBestAIMove(board: board, gameHashes: [board.zobrist],
                                           difficulty: .beginner, randomSeed: UInt64(seed)) {
                seen.insert(result.move.uci)
            }
        }
        #expect(seen.count >= 3, "beginner played only \(seen.count) distinct first moves")
    }

    @Test("A search told to stop before it starts returns at once")
    func cancellationBeforeSearching() {
        let board = Board.initial
        let cancellation = SearchCancellation()
        cancellation.cancel()

        let start = Date()
        let result = findBestAIMove(
            board: board, gameHashes: [board.zobrist],
            difficulty: .expert, randomSeed: 5, cancellation: cancellation
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.0, "expert's budget is 2.6s; this took \(elapsed)s")
        #expect(result == nil, "an abandoned search should not hand back a move")
    }

    @Test("A search told to stop mid-flight drops what it was doing")
    func cancellationDuringSearch() throws {
        let board = Board.initial
        let cancellation = SearchCancellation()
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AISearchResult?
        nonisolated(unsafe) var elapsed: TimeInterval = 0

        // Plain threads rather than tasks: this suite runs CPU-bound searches
        // in parallel, and a cooperative-pool canceller can be starved for
        // longer than the search it is meant to interrupt.
        let worker = Thread {
            let start = Date()
            result = findBestAIMove(
                board: board, gameHashes: [board.zobrist],
                difficulty: .expert, randomSeed: 5, cancellation: cancellation
            )
            elapsed = Date().timeIntervalSince(start)
            finished.signal()
        }
        // The test body is driven from the main queue, which is user-interactive.
        // Waiting there on a default-QoS thread is a priority inversion, so the
        // search runs at the same class as the thread blocked on it.
        worker.qualityOfService = .userInteractive
        worker.start()
        Thread.sleep(forTimeInterval: 0.2)
        cancellation.cancel()

        // Read only once the worker has signalled: until then it may still be
        // writing both variables.
        try #require(finished.wait(timeout: .now() + 10) == .success, "the search never came back")
        #expect(elapsed < 2.0, "expert's budget is 2.6s; cancelling took \(elapsed)s")
        #expect(result == nil)
    }

    @Test("A mate delivered on the hundredth halfmove is still a mate")
    func mateOutranksTheFiftyMoveClock() throws {
        // Ra8 mates — and it is the hundredth quiet halfmove. A search that
        // consulted the clock before looking for a reply scored the mate as a
        // dead draw and shuffled instead, while `Game` rightly called it mate.
        let board = try #require(Board(fen: "7k/8/6K1/8/8/8/8/R7 w - - 99 60"))
        let result = try #require(
            findBestAIMove(board: board, gameHashes: [board.zobrist], difficulty: .expert, randomSeed: 3)
        )
        #expect(result.move.uci == "a1a8", "played \(result.move.uci)")
        #expect(SearchScore.isMate(result.score), "scored \(result.score), not a mate")
    }

    /// Without the opening book behind them these two levels replay one game:
    /// their `temperature` is 0, so the root shuffle only breaks *exact* score
    /// ties, and from the starting position at depth 10 and up there are none.
    /// Measured before the book was wired in, both played 1.e4 on eight seeds
    /// out of eight.
    /// `nonisolated` because the app's MainActor default isolation reaches the
    /// test target too, and `@Test` arguments are read outside the actor.
    nonisolated static let bookLevels: [AIDifficulty] = [.hard, .expert]

    @Test("The levels that do not randomise still vary their opening",
          arguments: bookLevels)
    func topLevelsVaryTheirOpening(difficulty: AIDifficulty) {
        #expect(difficulty.playsFromBook)
        let game = Game()
        var seen = Set<String>()
        for seed in 1...12 {
            let engine = GameAIEngine()
            if let result = engine.bestMove(
                board: game.board, gameHashes: game.repetitionHashes,
                difficulty: difficulty, bookSANs: [],
                randomSeed: UInt64(seed) &* 6_364_136_223_846_793_005 &+ 1
            ) {
                seen.insert(result.move.uci)
            }
        }
        #expect(seen.count >= 3, "\(difficulty.rawValue) played only \(seen.count) distinct first moves")
    }

    /// The other half of the same fix: the book is not merely a source of
    /// variety, it is theory. Before it was wired in, the top levels left the
    /// book on the second ply — so a review of every Grandmaster game credited
    /// two book moves and named whatever one-move line the reply happened to
    /// be. Playing while theory lasts never searches, so this is cheap.
    /// Held to a mean over ten games rather than a floor on one, because how
    /// far theory runs is the luck of which line came up: the pick is weighted
    /// towards the openings the book has most to say about, but 1.c4 is three
    /// lines two plies deep and landing there legitimately ends the book on
    /// the second move. Measured over 5000 games the depth spreads 1 to 10
    /// with a mean of 5.0 and a mode of 6; over 200 windows of ten the worst
    /// mean was 2.90, the worst maximum 6, and no window ever had all ten
    /// games leave the book on the same ply — so these three hold with room,
    /// and all three fail flat at the two plies the levels used to manage.
    @Test("The games the top level opens stay in the book", arguments: bookLevels)
    func topLevelsPlayTheory(difficulty: AIDifficulty) throws {
        var depths: [Int] = []

        for run in 0..<10 {
            let engine = GameAIEngine()
            var game = Game()
            var plies = 0

            while !OpeningBook.continuations(after: game.history.map(\.san)).isEmpty {
                let result = try #require(engine.bestMove(
                    board: game.board, gameHashes: game.repetitionHashes,
                    difficulty: difficulty, bookSANs: game.history.map(\.san),
                    randomSeed: UInt64(run) &* 2_862_933_555_777_941_757 &+ UInt64(plies)
                ))
                #expect(result.isBookMove, "searched ply \(plies) instead of quoting theory")
                #expect(result.nodes == 0, "a book move searched \(result.nodes) nodes")
                #expect(game.legalMoves.contains(result.move), "illegal \(result.move.uci) at ply \(plies)")
                game.play(result.move)
                plies += 1
            }

            #expect(plies >= 1, "the book had nothing to say about the starting position")
            let match = OpeningBook.match(sans: game.history.map(\.san))
            #expect(match.bookPlies == plies)
            #expect(match.name != nil, "played \(plies) book plies and the review named nothing")
            depths.append(plies)
        }

        let mean = Double(depths.reduce(0, +)) / Double(depths.count)
        #expect(mean > 2.5, "mean book depth \(mean) over \(depths)")
        #expect((depths.max() ?? 0) >= 5, "the deepest of \(depths) never reached real theory")
        #expect(Set(depths).count > 1, "all ten games left the book on the same ply")
    }

    /// A hint is advice about the position in front of the player, so it goes
    /// through `findBestAIMove`, which never touches the book — quoting theory
    /// is not the same thing as saying what the engine would play.
    @Test("A hint is searched, never quoted out of the book")
    func hintsAreSearched() throws {
        let board = Board.initial
        let result = try #require(
            findBestAIMove(board: board, gameHashes: [board.zobrist],
                           difficulty: .hard, randomSeed: 4)
        )
        #expect(!result.isBookMove)
        #expect(result.depth >= 1, "the hint came back unsearched")
        #expect(result.nodes > 0)
    }

    /// Handing the lower levels theory as well would have Beginner opening
    /// like a grandmaster; their softmax already varies the opening.
    @Test("Only the levels with nothing else to vary them play from the book")
    func onlyTemperatureFreeLevelsUseTheBook() {
        for difficulty in AIDifficulty.allCases {
            let randomises = difficulty.parameters.temperature > 0
            #expect(
                difficulty.playsFromBook == !randomises,
                "\(difficulty.rawValue): playsFromBook \(difficulty.playsFromBook) with temperature \(difficulty.parameters.temperature)"
            )
        }
    }

    @Test("The per-game engine keeps playing legal moves as its table fills")
    func persistentEngineStaysLegal() throws {
        let engine = GameAIEngine()
        var game = Game()
        for ply in 0..<24 {
            guard let result = engine.bestMove(
                board: game.board, gameHashes: game.repetitionHashes,
                difficulty: .medium, randomSeed: UInt64(ply) &* 6_364_136_223_846_793_005
            ) else { break }
            #expect(game.legalMoves.contains(result.move), "illegal move \(result.move.uci) at ply \(ply)")
            game.play(result.move)
        }
        #expect(game.history.count == 24)
    }

    @Test("A position with one legal move needs no thought")
    func singleReplyIsInstant() throws {
        // The rook checks along the h-file; g7 is blocked by Black's own pawn
        // and h7 stays on the file, so Kg8 is the only move there is.
        let board = try #require(Board(fen: "7k/6p1/8/8/8/8/8/4K2R b - - 0 1"))
        let legal = board.generateLegalMoves()
        try #require(legal.count == 1)
        let result = try #require(
            findBestAIMove(board: board, gameHashes: [board.zobrist],
                           difficulty: .expert, randomSeed: 1)
        )
        #expect(result.move == legal[0])
        // The point is the shortcut, not the answer — any correct search would
        // find the one move. No search at all is what "instant" means.
        #expect(result.depth == 0 && result.nodes == 1, "searched \(result.nodes) nodes to depth \(result.depth)")
    }

    /// Pawn races, which are where the quiescence search used to run away with
    /// the whole time budget: promotions are generated in captures-only mode,
    /// each pawn offered four of them, and nothing on these boards is a
    /// capture — so the tree grew on promotions alone and depth 1 never
    /// finished. `search` then fell through to `rootMoves[0]`, and those are
    /// shuffled, so the computer played a random legal move. Measured then:
    /// five pawns a side spent 1.45 M nodes and came back with a promotion to
    /// a **bishop**.
    ///
    /// `depth` is the assertion because it is exactly what separates the two
    /// outcomes: the fallback reports 0 and every searched answer reports 1 or
    /// more. Which move is best here is a matter of engine judgement and not
    /// this test's business.
    nonisolated static let pawnRaces: [String] = [
        "8/PPPPP3/8/8/k6K/8/ppppp3/8 w - - 0 1",
        "8/PPPPPP2/8/8/k6K/8/pppppp2/8 w - - 0 1",
        "8/PPPPPPPP/8/8/k6K/8/pppppppp/8 w - - 0 1",
    ]

    @Test("A pawn race is still searched, not guessed at", arguments: pawnRaces)
    func aPawnRaceStillGetsASearchedMove(fen: String) throws {
        let board = try #require(Board(fen: fen))
        let result = try #require(
            findBestAIMove(board: board, gameHashes: [board.zobrist],
                           difficulty: .expert, randomSeed: 11)
        )
        #expect(result.depth >= 1,
                "depth 0 means nothing was searched and \(result.move.uci) is a shuffled guess")
        #expect(board.generateLegalMoves().contains(result.move), "illegal move \(result.move.uci)")
    }

    /// The cap on quiescence is only half the fix; the other half is that a
    /// pawn taking the last rank in captures-only mode takes the queen and
    /// nothing else. In check the four are all still there, because an evasion
    /// is an evasion whatever it promotes to — and running out of them is how
    /// quiescence finds mate.
    @Test("Quiescence offers one promotion, the full move list four")
    func quiescencePromotesOnlyToAQueen() throws {
        let board = try #require(Board(fen: "5k2/3P4/8/8/8/8/8/4K3 w - - 0 1"))

        let quiet = board.generatePseudoLegalMoves(capturesOnly: true)
            .filter { $0.promotion != nil }
        #expect(quiet.map(\.promotion) == [.queen], "quiescence offered \(quiet.map(\.uci))")

        let full = board.generatePseudoLegalMoves().filter { $0.promotion != nil }
        #expect(Set(full.compactMap(\.promotion)) == [.queen, .rook, .bishop, .knight],
                "the full list offered \(full.map(\.uci))")
    }
}

extension SearchTests.MateCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

// MARK: - Review

@Suite("Game review")
struct GameAnalyzerTests {

    /// A short Evans Gambit, enough to exercise the book, a sacrifice and a
    /// handful of ordinary moves.
    private func sampleGame() throws -> Game {
        var game = Game()
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5",
                    "b2b4", "c5b4", "c2c3", "b4a5", "d2d4", "e5d4"] {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }))
        }
        return game
    }

    /// Small budget: these tests care about shape and repeatability, not depth.
    private let quick = GameAnalyzer.Settings(
        maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5
    )

    private func analyse(_ game: Game) -> GameAnalysis {
        let jobs = GameAnalyzer.positions(of: game)
        let results = jobs.map { GameAnalyzer.run($0, settings: quick) }
        return GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
    }

    @Test("Every move is graded and the curve lines up with the game")
    func reportHasTheRightShape() throws {
        let game = try sampleGame()
        let analysis = analyse(game)
        #expect(analysis.moves.count == game.history.count)
        #expect(analysis.evalCurve.count == game.history.count + 1)
        #expect(analysis.moves.map(\.ply) == Array(0..<game.history.count))
        #expect((0...100).contains(try #require(analysis.white.accuracy)))
        #expect((0...100).contains(try #require(analysis.black.accuracy)))
    }

    @Test("A player who never moved is given no accuracy at all")
    func aSideThatNeverMovedHasNoReport() throws {
        // Resigning before your first turn is legal, and against the computer
        // it is always the human who resigns — so playing Black and giving up
        // before moving leaves Black with nothing to grade. An accuracy of 100
        // there had the review calling a game flawless that was never played.
        var game = Game()
        game.play(try #require(game.legalMoves.first { $0.uci == "e2e4" }))
        let analysis = analyse(game)

        #expect(analysis.black.accuracy == nil)
        #expect(analysis.black.verdict == nil)
        #expect(analysis.black.averageCentipawnLoss == nil)
        #expect(analysis.black.counts.isEmpty)
        // White did move, so White is graded as usual.
        #expect(analysis.white.accuracy != nil)
        #expect(analysis.white.verdict != nil)
    }

    @Test("A node budget makes the review repeatable")
    func analysisIsReproducible() throws {
        let game = try sampleGame()
        let first = analyse(game)
        let second = analyse(game)
        #expect(first.moves.map(\.quality) == second.moves.map(\.quality))
        #expect(first.moves.map(\.playedScore) == second.moves.map(\.playedScore))
        #expect(first.white.accuracy == second.white.accuracy)
        #expect(first.black.accuracy == second.black.accuracy)
        #expect(first.evalCurve == second.evalCurve)
    }

    @Test("Opening theory is named, not marked wrong")
    func openingsAreRecognised() throws {
        // The guard the naming sits behind: a game begun the normal way must
        // serialize back to the very string it is compared against.
        #expect(Game().initialFEN == Board.startFEN)

        let analysis = analyse(try sampleGame())
        #expect(analysis.openingName?.contains("Evans") == true,
                "expected the Evans Gambit, got \(analysis.openingName ?? "nothing")")
        #expect(analysis.moves.prefix(4).allSatisfy { $0.quality == .book })
    }

    /// The book is a list of move sequences, so a game set up from a FEN whose
    /// first moves happen to read like theory would otherwise be credited with
    /// an opening it never played — and have those moves left unjudged on the
    /// strength of it. Both knights are off their home squares here, so this
    /// is not the starting position, but 1.e4 e5 is legal and writes the same
    /// SAN the book's "Open Game" does.
    @Test("A game that did not start from the standard position has no opening")
    func aGameFromAFENIsNotNamed() throws {
        var game = Game(fen: "r1bqkb1r/pppppppp/8/8/8/8/PPPPPPPP/R1BQKB1R w KQkq - 0 1")
        try #require(game.initialFEN != Board.startFEN)
        for uci in ["e2e4", "e7e5"] {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }))
        }
        // The book itself does recognise the sequence — the guard is what
        // keeps it from being applied here.
        #expect(OpeningBook.match(sans: game.history.map(\.san)).name != nil)

        let analysis = analyse(game)
        #expect(analysis.openingName == nil, "named \(analysis.openingName ?? "")")
        #expect(analysis.moves.allSatisfy { $0.quality != .book },
                "graded a move as theory in a game that has no opening")
    }

    // MARK: Grading thresholds

    /// Centipawn score that lands on a given win expectancy, so the cases below
    /// can be written in the terms the thresholds are actually expressed in.
    private func score(winPercent: Double) -> Int {
        let p = min(0.999, max(0.001, winPercent / 100))
        return Int((log(p / (1 - p)) / 0.00368208).rounded())
    }

    @Test("A move that loses nothing is not marked down")
    func bestMoveIsBest() {
        let quality = GameAnalyzer.classify(
            bestScore: 30, playedScore: 30, isBest: true, hasCloseAlternative: true,
            sacrifice: 0, legalMoveCount: 30, isRecapture: false,
            wasInCheck: false, isBook: false
        )
        #expect(quality == .best)
    }

    @Test("A sound sacrifice reads as brilliant")
    func soundSacrificeIsBrilliant() {
        let quality = GameAnalyzer.classify(
            bestScore: 60, playedScore: 60, isBest: true, hasCloseAlternative: true,
            sacrifice: 300, legalMoveCount: 30, isRecapture: false,
            wasInCheck: false, isBook: false
        )
        #expect(quality == .brilliant)
    }

    @Test("Only-moves are great, but forced recaptures and check evasions are not")
    func onlyMoveIsGreat() {
        func grade(isRecapture: Bool, wasInCheck: Bool) -> MoveQuality {
            GameAnalyzer.classify(
                bestScore: 20, playedScore: 20, isBest: true, hasCloseAlternative: false,
                sacrifice: 0, legalMoveCount: 30, isRecapture: isRecapture,
                wasInCheck: wasInCheck, isBook: false
            )
        }
        #expect(grade(isRecapture: false, wasInCheck: false) == .great)
        #expect(grade(isRecapture: true, wasInCheck: false) == .best)
        #expect(grade(isRecapture: false, wasInCheck: true) == .best)
    }

    @Test("Losing ground is graded by how much", arguments: [
        (1.0, MoveQuality.excellent),
        (7.0, MoveQuality.inaccuracy),
        (15.0, MoveQuality.mistake),
        (40.0, MoveQuality.blunder),
    ])
    func lossThresholds(pointsLost: Double, expected: MoveQuality) {
        // Start from a balanced position so the "already winning" shortcut and
        // the missed-mate rule stay out of the way.
        let quality = GameAnalyzer.classify(
            bestScore: score(winPercent: 50),
            playedScore: score(winPercent: 50 - pointsLost),
            isBest: false, hasCloseAlternative: true, sacrifice: 0,
            legalMoveCount: 30, isRecapture: false, wasInCheck: false, isBook: false
        )
        #expect(quality == expected, "losing \(pointsLost) points graded \(quality)")
    }

    @Test("Walking past a short forced mate is a missed chance")
    func missedMateIsFlagged() {
        let quality = GameAnalyzer.classify(
            bestScore: SearchScore.mate - 4, playedScore: score(winPercent: 96),
            isBest: false, hasCloseAlternative: true, sacrifice: 0,
            legalMoveCount: 30, isRecapture: false, wasInCheck: false, isBook: false
        )
        #expect(quality == .miss)
    }

    @Test("Taking the slow road home in a won game is not a blunder")
    func wonPositionsAreForgiving() {
        let quality = GameAnalyzer.classify(
            bestScore: score(winPercent: 99), playedScore: score(winPercent: 95),
            isBest: false, hasCloseAlternative: true, sacrifice: 0,
            legalMoveCount: 30, isRecapture: false, wasInCheck: false, isBook: false
        )
        #expect(!quality.isMistake, "graded \(quality)")
    }

    @Test("Win expectancy and accuracy stay inside their scales", arguments: [
        -3000, -900, -100, 0, 100, 900, 3000,
    ])
    func curvesAreBounded(centipawns: Int) {
        let win = WinChance.percent(centipawns: centipawns)
        #expect((0...100).contains(win))
        #expect((0...100).contains(WinChance.accuracy(pointsLost: 100 - win)))
    }

    @Test("A flawless game scores near 100, a terrible one does not")
    func accuracyEndsOfTheScale() {
        #expect(WinChance.accuracy(pointsLost: 0) > 99)
        #expect(WinChance.accuracy(pointsLost: 50) < 20)
    }
}
