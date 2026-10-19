//
//  AnalyzerPuzzleFixesTests.swift
//  chessTests
//
//  One test per fault found in the review of the analyzer and the puzzles,
//  each written to fail on the code as it was: the evaluation after a mating
//  move that read one move too long, and a mistake puzzle that could be
//  "fixed" by playing the very mistake again.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
    var game = Game(fen: fen)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

/// Small budget, as in the other review suites: a mate in two is found long
/// before it runs out.
private let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5)

/// Waits for `condition`, a twentieth of a second at a time, counted in
/// turns rather than against a clock: a simulator running every suite at
/// once can keep the main actor busy for seconds together.
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// `withScratchStore` for a test that has to wait on the engine. The store
/// stays swapped in across the wait, as in the model suites: a mistake puzzle
/// writes its result the moment the engine's answer lands, and that write
/// belongs in the scratch store, not the real one.
@MainActor
private func withScratchStoreAsync(_ name: String, _ body: () async throws -> Void) async rethrows {
    await ScratchStoreLock.acquire()
    defer { ScratchStoreLock.release() }
    let suiteName = "chessTests.\(name)"
    let scratch = UserDefaults(suiteName: suiteName)!
    scratch.removePersistentDomain(forName: suiteName)
    scratch.set(false, forKey: "soundsEnabled")
    scratch.set(false, forKey: "hapticsEnabled")
    let store = LocalStore.defaults
    LocalStore.defaults = scratch
    let files = LocalStore.files
    let sounds = SoundManager.shared.isEnabled
    let haptics = Haptics.isEnabled
    SoundManager.shared.isEnabled = false
    Haptics.isEnabled = false
    defer {
        SoundManager.shared.isEnabled = sounds
        Haptics.isEnabled = haptics
        LocalStore.defaults = store
        scratch.removePersistentDomain(forName: suiteName)
        files.discard()
        Achievements.shared.justUnlocked = []
    }
    try await body()
}

// MARK: - Mate distance

@Suite("Fixes: mate distance after a move")
@MainActor
struct MateDistanceFixesTests {

    /// Two rooks against a bare king. 1.Ra7 shuts the seventh rank, Kg8 is
    /// the one reply, and 2.Rb8 mates.
    private let ladder = "7k/8/8/8/8/8/R7/1R5K w - - 0 1"

    @Test("The position a mating move leaves reads one move nearer the mate")
    func mateAfterTheMoveIsOneNearer() throws {
        let game = try played(["a2a7", "h8g8", "b1b8"], from: ladder)
        let jobs = GameAnalyzer.positions(of: game)
        let results = jobs.map { GameAnalyzer.run($0, settings: quick) }
        let analysis = GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
        let curve = analysis.evalCurve
        try #require(curve.count == 4)

        // Before anything is played White mates in two.
        #expect(SearchScore.mateInMoves(curve[0]) == 2)
        // After 1.Ra7 it is mate in one, and the label said "M2".
        #expect(SearchScore.mateInMoves(curve[1]) == 1, "curve \(curve)")
        #expect(EvalFormat.text(centipawns: curve[1]) == "M1")
        // The search of that very position agrees. Black is on move there,
        // so its score is Black's and turned round for White.
        let afterRa7 = try #require(results[1])
        #expect(SearchScore.mateInMoves(-afterRa7.bestScore) == SearchScore.mateInMoves(curve[1]))
        // A move by the side being mated always read right, and still does.
        #expect(SearchScore.mateInMoves(curve[2]) == 1)
        // The mate on the board has no distance left.
        #expect(curve[3] == SearchScore.mate)

        // Only what is shown moved: the move is still scored from the
        // position it was played in, where it forces mate in two counting
        // itself, and is still the best there was.
        let ra7 = try #require(analysis.move(at: 0))
        #expect(SearchScore.mateInMoves(ra7.playedScore) == 2)
        #expect(ra7.isBestMove)
        #expect(ra7.pointsLost == 0)
        #expect(ra7.quality == .best)
    }

    @Test("Black's mate reads one move nearer too, from White's side of the board")
    func blacksMateIsOneNearer() throws {
        // The same ladder with the colours swapped: 1...Ra2 then 2...Rb1.
        let game = try played(["a7a2", "h1g1", "b8b1"], from: "1r5k/r7/8/8/8/8/8/7K b - - 0 1")
        let jobs = GameAnalyzer.positions(of: game)
        let analysis = GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )
        let curve = analysis.evalCurve
        try #require(curve.count == 4)

        #expect(SearchScore.mateInMoves(curve[0]) == -2)
        #expect(SearchScore.mateInMoves(curve[1]) == -1, "curve \(curve)")
        #expect(EvalFormat.text(centipawns: curve[1]) == "-M1")
        #expect(SearchScore.mateInMoves(curve[2]) == -1)
        #expect(curve[3] == -SearchScore.mate)
    }
}

// MARK: - Mistake puzzles

@Suite("Fixes: the move that was the mistake", .serialized)
@MainActor
struct OriginalMistakeFixesTests {

    @Test("A move is found from its SAN in the position, with or without check marks")
    func legalMoveFromSAN() throws {
        // 1.f3 e5 2.g4: Qh4 is mate, and both spellings name the same move.
        let fen = try played(["f2f3", "e7e5", "g2g4"]).board.fen
        let puzzle = Puzzle(
            id: "san", fen: fen, setup: nil, solution: ["d8h4"],
            rating: 0, themes: [], source: .mistake
        )
        let attempt = try #require(PuzzleAttempt(puzzle: puzzle))
        let mate = try #require(attempt.expectedMove)
        #expect(attempt.legalMove(named: "Qh4#") == mate)
        #expect(attempt.legalMove(named: "Qh4") == mate)
        #expect(attempt.legalMove(named: "Qh5") == nil)
    }

    /// White is a queen up, so every sensible first move keeps the game just
    /// as won, and the check that weighs a move the solution did not list
    /// accepts any of them. The review is the one that called d4 a mistake
    /// here, as a deeper search can: what matters is that playing it again
    /// is never taken for the answer.
    @Test("The move played in the game is never accepted as another answer")
    func originalMistakeIsWrong() async throws {
        try await withScratchStoreAsync("fixesOriginalMistake") {
            let entry = MistakeEntry(
                id: UUID(), fen: "rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                setupUCI: nil, bestUCI: "e2e4", playedSAN: "d4", quality: .mistake, foundAt: Date()
            )
            LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")

            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            try #require(model.phase == .playerToMove)

            @MainActor func move(_ from: String, to: String) throws {
                let origin = try #require(Square(algebraic: from))
                let target = try #require(Square(algebraic: to))
                model.select(origin)
                model.attemptMove(from: origin, to: target)
            }

            // The mistake itself is wrong at once, with no engine asked.
            try move("d2", to: "d4")
            try await waitFor { model.phase != .checking }
            try #require(model.phase == .wrong, "d4, the mistake, was taken for an answer")
            #expect(MistakeStore.shared.entries.first?.fixed == false)

            // Another move as good as the answer still goes to the engine
            // and is accepted. It no longer counts as a fix: a wrong move
            // came first, as it would for a library puzzle.
            try await waitFor { model.position.sideToMove == .white }
            try move("g1", to: "f3")
            try await waitFor { model.phase != .checking }
            #expect(model.phase == .solved, "Nf3 was not accepted as another answer")
            let stored = try #require(MistakeStore.shared.entries.first)
            #expect(stored.attempts == 1)
            #expect(!stored.fixed)
        }
    }
}
