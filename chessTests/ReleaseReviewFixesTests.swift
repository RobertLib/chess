//
//  ReleaseReviewFixesTests.swift
//  chessTests
//
//  One test per fault found in the review before 1.0.1 went out, each
//  written to fail on the code as it was: a daily puzzle that came round
//  again as a fresh rated one, games at odds that walked the adaptive
//  opponent up, a mate the review called a move longer than it was, a clock
//  that ran on under the settings sheet, results and dates in a PGN file
//  read wrong, a delay written down as an increment, an import with no
//  limit, and a mistake named over the page that says none are left.
//

import Foundation
import Testing
@testable import chess

// MARK: - Puzzles

@Suite("Release review fixes: puzzles", .serialized)
@MainActor
struct PuzzleReleaseReviewFixesTests {

    @Test("A daily puzzle solved is seen, and one seen before counts for nothing again")
    func dailyPuzzleIsSeen() throws {
        withScratchStore("releaseDailySeen") {
            let store = PuzzleStore.shared
            let puzzles = Array(PuzzleLibrary.all.prefix(2))
            store.recordDailySolved(puzzles[0], day: 300, clean: true)
            #expect(store.progress.seen.contains(puzzles[0].id), "the rated puzzles would serve it again")
            #expect(store.progress.puzzlesSolved == 1)

            // Met first as a rated puzzle, it is not counted a second time
            // when it comes round as the daily — the streak still is.
            store.recordRated(puzzles[1], solved: true)
            #expect(store.progress.puzzlesSolved == 2)
            store.recordDailySolved(puzzles[1], day: 301, clean: true)
            #expect(store.progress.puzzlesSolved == 2, "the same puzzle counted twice")
            #expect(store.progress.dailyStreak == 2)
        }
    }

    /// Mate in one with Ra8; the game's move was Kf2.
    private func storeMistake() throws {
        let entry = MistakeEntry(
            id: UUID(), fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: nil, bestUCI: "a1a8",
            playedSAN: "Kf2", quality: .blunder, foundAt: Date()
        )
        MistakeStore.shared.reset()
        LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")
    }

    @Test("Next after the last mistake leaves no mistake named on the empty page")
    func emptyPageNamesNoMistake() throws {
        try withScratchStore("releaseMistakeCleared") {
            try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            let from = try #require(Square(algebraic: "a1"))
            model.select(from)
            model.attemptMove(from: from, to: try #require(Square(algebraic: "a8")))
            #expect(model.phase == .solved)
            model.loadNext()
            #expect(model.phase == .empty)
            #expect(model.currentMistake == nil, "the page still said which move was played")
        }
    }
}

// MARK: - Games

@Suite("Release review fixes: games", .serialized)
@MainActor
struct GameReleaseReviewFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func play(_ model: GameViewModel, _ uci: String) throws {
        let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        #expect(model.game.lastMove == move)
    }

    @Test("A game at odds does not move the adaptive opponent")
    func oddsLeaveTheLevelAlone() throws {
        var initial = 0.0
        var after = 0.0
        try withScratchStore("releaseAdaptiveOdds") {
            let settings = AppSettings()
            initial = settings.adaptiveLevel
            let model = GameViewModel(
                mode: .vsAI(difficulty: .adaptive, playerColor: .white), settings: settings,
                options: GameOptions(start: .handicap(.queen, giver: .black))
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            model.resign()
            after = settings.adaptiveLevel
        }
        #expect(after == initial, "a game the computer began a queen down moved the level")
    }

    @Test("The settings sheet holds a running clock")
    func settingsHoldTheClock() throws {
        try withScratchStore("releaseSettingsHold") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            #expect(model.isClockRunning)
            model.sheetDidAppear()
            #expect(model.isPaused, "the clock ran on under the sheet")
            time.now += 30
            model.sheetDidDisappear()
            #expect(model.clockRemaining(for: .black) == 60)
        }
    }

    @Test("The sheet closing on the way to the daily puzzle does not let the game go")
    func sheetClosedUnderThePuzzle() throws {
        try withScratchStore("releaseSheetUnderPuzzle") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            // The widget's tap: the puzzle covers the game, and the sheet
            // that was up is closed to make way for it.
            model.sheetDidAppear()
            model.coverDidAppear()
            model.sheetDidDisappear()
            try play(model, "e2e4")
            #expect(model.isPaused, "the clock started running under the puzzle")
        }
    }
}

// MARK: - Search

@Suite("Release review fixes: search")
struct SearchReleaseReviewFixesTests {

    /// Qg3+ mates in two: Kh1 Qxg2#, or Kg1 Qxg2#. Behind the slower mate
    /// Bxg2+ had found, delta pruning passed Qxg2# over for the pawn it takes.
    @Test("A mating capture is searched even once a slower mate has been found")
    func quickerMateBehindASlowerOne() throws {
        let board = try #require(Board(fen: "7k/6rp/p4Q2/2pP4/4P3/1PN1q2b/P5PK/5R2 b - - 5 37"))
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 12,
            nodeBudget: 250_000, timeLimit: 10
        ))
        #expect(analysis.bestMove.uci == "e3g3")
        #expect(SearchScore.mateInMoves(analysis.bestScore) == 2, "scored \(analysis.bestScore)")
    }
}

// MARK: - PGN

@Suite("Release review fixes: PGN")
struct PGNReleaseReviewFixesTests {

    @Test("A result written with an en dash is a result",
          arguments: ["1. e4 e5 ½–½", "1. e4 e5 1/2–1/2", "1. e4 e5 1—0"])
    func dashedResults(movetext: String) throws {
        let game = try #require(try PGN.parse("[Event \"Dashes\"]\n\n\(movetext)\n").first)
        #expect(game.unreadMove == nil, "the result was read as a move")
        #expect(game.game.history.count == 2)
        #expect(game.game.outcome.isGameOver)
    }

    @Test("A mate followed by a dashed result reads to the end")
    func dashedResultAfterMate() throws {
        let game = try #require(try PGN.parse("1. f3 e5 2. g4 Qh4# 0–1").first)
        #expect(game.unreadMove == nil)
        #expect(game.game.outcome.winner == .black)
    }

    @Test("Games pasted one after another, parted by dashed results, are all kept")
    func dashedResultsPartGames() throws {
        let games = try PGN.parse("1. e4 e5 1–0\n1. d4 d5 0–1\n")
        #expect(games.count == 2)
        #expect(games.last?.game.outcome.winner == .black)
    }

    @Test("A null move a word processor turned into a dash stops the game there, as \"--\" does",
          arguments: ["--", "–", "—"])
    func dashedNullMove(nullMove: String) throws {
        let game = try #require(try PGN.parse("1. e4 \(nullMove) 2. d4 *").first)
        #expect(game.game.history.count == 1, "the moves after it went to the wrong side")
        #expect(game.unreadMove == "--")
    }

    @Test("A Result tag written with an en dash is the result")
    func dashedResultTag() throws {
        let game = try #require(try PGN.parse("[Result \"0–1\"]\n\n1. e4 e5\n").first)
        #expect(game.game.outcome.winner == .black)
    }

    @Test("A date that does not exist, or has not come yet, is no date")
    func impossibleDates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 6, day: 1, hour: 9)))
        #expect(MyGamesView.date(from: "2024.13.45", now: now) == nil)
        #expect(MyGamesView.date(from: "2023.02.29", now: now) == nil)
        #expect(MyGamesView.date(from: "20240.01.01", now: now) == nil)
        #expect(MyGamesView.date(from: "2025.06.03", now: now) == nil)
        #expect(MyGamesView.date(from: "2024.02.29", now: now) != nil)
        #expect(MyGamesView.date(from: "2025.06.01", now: now) != nil, "today was taken for the future")
        #expect(MyGamesView.date(from: "2024.??.??", now: now) != nil)
    }

    @Test("A delay is not written down as an increment")
    func timeControlTag() {
        #expect(GameRecord.pgnTimeControl(.minutes(5, plus: 3)) == "300+3")
        #expect(GameRecord.pgnTimeControl(TimeControl(initial: 300, bonus: 3, bonusKind: .delay)) == "300")
        #expect(GameRecord.pgnTimeControl(TimeControl(initial: 300, bonus: 3, bonusKind: .bronstein)) == "300")
    }
}

// MARK: - Import

@Suite("Release review fixes: import")
struct ImportReleaseReviewFixesTests {

    private func scratchFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "releaseImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    @Test("A file past the size limit is turned away unread, and the others still go in")
    func tooLargeFile() throws {
        let large = try scratchFile("large.pgn")
        #expect(FileManager.default.createFile(atPath: large.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(MyGamesView.maxImportBytes + 1))
        try handle.close()
        let small = try scratchFile("small.pgn")
        try Data("[Event \"a\"]\n\n1. e4 e5 1-0\n".utf8).write(to: small)
        defer {
            try? FileManager.default.removeItem(at: large.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: small.deletingLastPathComponent())
        }

        let read = MyGamesView.readImports(from: [large, small])
        #expect(read.tooLargeFiles == 1)
        #expect(read.unreadableFiles == 0)
        #expect(read.records.count == 1)
    }

    @Test("The player is told a file was too large")
    @MainActor
    func tooLargeMessage() {
        let none = GameArchive.ImportSummary(added: 0, duplicates: 0, kept: 0)
        let alone = MyGamesView.importMessage(for: none, unreadableFiles: 0, of: 1, tooLargeFiles: 1)
        #expect(alone == String(localized: "\(1) files are too large to import."))
        let some = GameArchive.ImportSummary(added: 2, duplicates: 0, kept: 2)
        let beside = MyGamesView.importMessage(for: some, unreadableFiles: 0, of: 2, tooLargeFiles: 1)
        #expect(beside.hasSuffix(String(localized: "\(1) files are too large to import.")))
    }
}
