//
//  CheckupFixesTests.swift
//  chessTests
//
//  One test per fault found in a check-up of the whole app, each written to
//  fail on the code as it was: a delay clock whose face froze before its flag
//  fell, and a flag on the first turn that brought the start instructions
//  back; a PGN comment left open that swallowed every game after it, an
//  import that held a million empty games or pushed older ones out without a
//  word, and an export that left games out; games and puzzle progress lost
//  behind a file that did not read; a hill walk reviewed as a mate, a review
//  read to VoiceOver in notation; and a stalemate past the horizon that the
//  search did not see behind a narrow window.
//

import Foundation
import SwiftUI
import Testing
@testable import chess

private func played(_ ucis: [String], variant: ChessVariant = .standard) throws -> Game {
    var game = Game(fen: Board.startFEN, variant: variant)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

private func record(
    _ ucis: [String], at seconds: TimeInterval, source: GameRecord.Source = .played, round: Int? = nil
) throws -> GameRecord {
    GameRecord(
        game: try played(ucis), mode: .twoPlayer, options: .standard, moveTimes: [], finalClock: nil,
        source: source, tags: round.map { ["Round": "\($0)"] },
        finishedAt: Date(timeIntervalSinceReferenceDate: seconds)
    )
}

private func setPermissions(_ permissions: Int, of url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

// MARK: - The chess clock

@Suite("Check-up fixes: the chess clock")
struct ClockCheckupFixesTests {

    /// A clock the test moves by hand.
    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func offsets(_ schedule: ClockFaceSchedule, count: Int) -> [Double] {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        return schedule.entries(from: start, mode: .normal).prefix(count).map {
            ($0.timeIntervalSince(start) * 1000).rounded() / 1000
        }
    }

    @Test("Under a delay the face stands still for the delay, then counts down to the flag")
    func faceCountsDownAfterTheDelay() {
        // 4 s in the bank and a 5 s delay: the flag falls 9 s into the turn.
        let schedule = ClockFaceSchedule(remaining: 4, tenthsBelow: 20, heldFor: 5)
        #expect(offsets(schedule, count: 3) == [0, 5.1, 5.2])
        let all = offsets(schedule, count: 1000)
        #expect(all.last == 9, "the face stopped being redrawn at \(all.last ?? 0) s, before the flag")
    }

    @Test("The delay still to come stands between the bank and the flag")
    func delayLeft() {
        var clock = ChessClock(control: TimeControl(initial: 300, bonus: 5, bonusKind: .delay))
        #expect(clock.delayLeft(at: 0) == 0, "nobody is on turn")
        clock.start(.white, at: 10)
        #expect(clock.delayLeft(at: 12) == 3)
        #expect(clock.timeUntilFlag(at: 12) == 303)
        #expect(clock.delayLeft(at: 20) == 0)

        var increment = ChessClock(control: .minutes(5, plus: 3))
        increment.start(.white, at: 10)
        #expect(increment.delayLeft(at: 11) == 0)
    }

    @Test("A flag that falls on the first turn does not bring the start instructions back")
    func flagOnTheFirstTurn() {
        withScratchStore("checkupFirstFlag") {
            let time = FakeTime()
            let model = ChessClockModel(control: TimeControl(initial: 5, bonus: 0), timeSource: { time.now })
            defer { model.teardown() }
            model.tap(.black)
            time.now += 6
            model.tap(.white)
            #expect(model.flagged == .white)
            #expect(model.hasStarted, "a clock whose flag fell reads as one never started")
        }
    }
}

// MARK: - Reading PGN

@Suite("Check-up fixes: reading PGN")
struct PGNCheckupFixesTests {

    @Test("A comment left open does not swallow the games after it")
    func runawayComment() throws {
        let text = """
        [Event "A"]

        1. e4 {oops e5 2. Nf3 1-0

        [Event "B"]

        1. d4 d5 1/2-1/2

        [Event "C"]

        1. c4 e5 0-1
        """
        let games = try PGN.contents(of: text).games
        #expect(games.map { $0.tags["Event"] } == ["A", "B", "C"])
        #expect(games.first?.game.history.count == 1)
        #expect(games.first?.unreadMove != nil, "the game with the open comment is not said to end early")
        #expect(games.dropFirst().map(\.game.history.count) == [2, 2])
    }

    @Test("A comment over several lines keeps its blank lines, its commands and its brackets")
    func longCommentStays() throws {
        let text = "1. e4 {A long note.\n\n[%clk 0:01:00] and more.\n\n[a remark in brackets]} e5 2. Nf3 *"
        let games = try PGN.contents(of: text).games
        #expect(games.count == 1)
        #expect(games.first?.game.history.map(\.move.uci) == ["e2e4", "e7e5", "g1f3"])
    }

    @Test("A Windows line break is not a blank line")
    func windowsLineBreak() throws {
        let games = try PGN.contents(of: "1. e4 {note\r\n[Event \"in a comment\"]} e5 *").games
        #expect(games.count == 1)
        #expect(games.first?.game.history.count == 2)
    }

    @Test("An import passes over games without moves as it reads, and stops at its limit")
    func importLimits() throws {
        let tagsOnly = String(repeating: "[a \"b\"]\n", count: 2000)
        #expect(throws: PGN.ParseError.noGames) { try PGN.contents(of: tagsOnly, played: true) }
        #expect(try PGN.contents(of: tagsOnly).games.count == 2000, "the paste sheet reads them as it did")

        let many = (1...50).map { "[Round \"\($0)\"]\n\n1. e4 *\n" }.joined(separator: "\n")
        let capped = try PGN.contents(of: many, played: true, maxGames: 10)
        #expect(capped.games.count == 10)
        #expect(capped.stoppedAtLimit)
        #expect(try !PGN.contents(of: many, played: true, maxGames: 50).stoppedAtLimit)
    }

    @Test("The game limit runs across all the files picked, and the player is told")
    func importLimitAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "checkup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let games = (1...6).map { "[Round \"\($0)\"]\n\n1. e4 e5 *\n" }.joined(separator: "\n")
        let urls = try (1...3).map { number in
            let url = directory.appending(path: "\(number).pgn")
            try games.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let read = MyGamesView.readImports(from: urls, gameLimit: 8)
        #expect(read.records.count == 8)
        #expect(read.stoppedAtGameLimit)
        #expect(read.leftOverFiles == 1)
        let message = MyGamesView.importMessage(
            for: GameArchive.ImportSummary(added: 8, kept: 8), unreadableFiles: 0, of: 3,
            leftOverFiles: read.leftOverFiles, stoppedAtGameLimit: read.stoppedAtGameLimit
        )
        #expect(message.contains(String(localized: "Reading stopped after \(MyGamesView.maxImportGames) games: the files picked hold more than can be imported at once.")))
    }
}

// MARK: - My Games

@Suite("Check-up fixes: My Games", .serialized)
struct ArchiveCheckupFixesTests {

    @Test("An import that pushes older imports out says so")
    func displacedImportsAreTold() throws {
        try withScratchStore("checkupDisplaced") {
            let old = try (0..<GameArchive.maxRecords).map {
                try record(["e2e4"], at: 700_000_000 + Double($0), source: .imported, round: $0)
            }
            #expect(GameArchive.shared.importGames(old).kept == GameArchive.maxRecords)

            let new = try (0..<5).map {
                try record(["d2d4"], at: 800_000_000 + Double($0), source: .imported, round: $0)
            }
            let summary = GameArchive.shared.importGames(new)
            #expect(summary.kept == 5)
            #expect(summary.displaced == 5)
            let message = MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 1)
            #expect(message.contains(String(localized: "\(5) games imported earlier were removed to make room.")))
        }
    }

    @Test("Export All writes a game whose moves no longer all replay, as far as they go")
    func exportKeepsWhatReplays() throws {
        var broken = try record(["e2e4", "e7e5", "g1f3"], at: 800_000_000)
        broken.moveUCIs.append("e1e8")
        #expect(broken.pgn() == nil)
        let read = try PGN.parse(broken.pgnForExport())
        #expect(read.first?.game.history.map(\.move.uci) == ["e2e4", "e7e5", "g1f3"])
    }

    @Test("Games filed while the archive did not read join it once it does")
    func unreadArchiveJoins() throws {
        try withScratchStore("checkupUnreadArchive") {
            let kept = [try record(["d2d4"], at: 800_000_100), try record(["e2e4"], at: 800_000_000)]
            try LocalStore.files.write(try JSONEncoder().encode(kept), as: "gameArchive")
            let url = LocalStore.files.url(for: "gameArchive")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            let first = try record(["c2c4"], at: 800_000_200)
            GameArchive.shared.add(first)
            #expect(GameArchive.shared.records.map(\.id) == [first.id])

            try setPermissions(0o644, of: url)
            let second = try record(["g1f3"], at: 800_000_300)
            GameArchive.shared.add(second)
            let all = [second.id, first.id] + kept.map(\.id)
            #expect(GameArchive.shared.records.map(\.id) == all)
            LocalStore.flush()
            let stored = try JSONDecoder().decode(
                [GameRecord].self, from: try #require(LocalStore.files.read("gameArchive"))
            )
            #expect(stored.map(\.id) == all, "the game filed while the archive did not read was never written")
        }
    }

    @Test("Puzzles played while the progress did not read count once it does")
    func unreadProgressIsReplayed() throws {
        try withScratchStore("checkupUnreadProgress") {
            var filed = PuzzleProgress()
            filed.attempts = 40
            filed.solved = 30
            try LocalStore.files.save(filed, as: "puzzleProgress")
            let url = LocalStore.files.url(for: "puzzleProgress")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            let puzzles = Array(PuzzleLibrary.all.prefix(2))
            PuzzleStore.shared.recordRated(puzzles[0], solved: true)
            #expect(PuzzleStore.shared.progress.attempts == 1)

            try setPermissions(0o644, of: url)
            PuzzleStore.shared.recordRated(puzzles[1], solved: false)
            #expect(PuzzleStore.shared.progress.attempts == 42)
            #expect(PuzzleStore.shared.progress.solved == 31)
            #expect(PuzzleStore.shared.progress.seen.suffix(2) == puzzles.map(\.id))
            LocalStore.flush()
            let stored = try JSONDecoder().decode(
                PuzzleProgress.self, from: try #require(LocalStore.files.read("puzzleProgress"))
            )
            #expect(stored.attempts == 42, "the puzzle played while the progress did not read was lost")
        }
    }
}

// MARK: - What the review says

@Suite("Check-up fixes: what the review says")
struct ReviewWordingCheckupFixesTests {

    private let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 100_000, timeLimitPerPosition: 10)

    private func review(_ game: Game) -> GameAnalysis {
        let jobs = GameAnalyzer.positions(of: game)
        return GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )
    }

    @Test("A walk onto the hill is a win, not a mate")
    func hillIsNoMate() throws {
        let game = try played(["e2e3", "e7e6", "e1e2", "e8e7", "e2d3", "e7d6", "d3d4"], variant: .kingOfTheHill)
        #expect(game.outcome == .kingOfTheHill(winner: .white))
        let comments = review(game).moves.map(\.comment)
        #expect(comments.last == String(localized: "The king reaches the hill — the strongest possible finish."))
        let mate = String(localized: "The strongest move — it forces mate in \(1).")
        #expect(!comments.contains(mate), "\(comments)")
        #expect(EvalFormat.spoken(centipawns: SearchScore.mate - 1, variant: .kingOfTheHill)
                == String(localized: "White wins in \(1)"))
    }

    @Test("VoiceOver hears the engine's move in words, not in notation")
    func spokenCommentInWords() throws {
        // 3...Nf6?? walks into Qxf7#.
        let game = try played(["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"])
        let blunder = try #require(review(game).moves.last)
        let written = MoveNotation.display(blunder.bestSAN)
        let spoken = BoardSpeech.spokenMove(blunder.bestMove, san: blunder.bestSAN)
        #expect(blunder.comment.contains(written))
        #expect(blunder.spokenComment.contains(spoken), "\(blunder.spokenComment)")
        #expect(!blunder.spokenComment.contains(written), "\(blunder.spokenComment)")
    }
}

// MARK: - The search

@Suite("Check-up fixes: stalemate behind a narrow window")
struct NarrowWindowStalemateCheckupFixesTests {

    /// White is two pawns down and stalemates with Kc7 or Kc8. Ke8, searched
    /// first, sets the window, and Black's stand-pat on its extra pawns cut
    /// off the search of every move after it — Kc7's stalemate included.
    @Test("A stalemate that saves the side behind is seen on a root move searched after the first")
    func stalemateAfterTheFirstMove() throws {
        let board = try #require(Board(fen: "k2K4/p7/P7/8/5p1p/5p1p/5P1P/8 w - - 0 1"))
        let analysis = try #require(analyzePosition(
            board: board, gameHashes: [board.zobrist], maxDepth: 1, nodeBudget: 100_000, timeLimit: 10
        ))
        #expect(analysis.bestScore == 0)
        #expect(["d8c7", "d8c8"].contains(analysis.bestMove.uci), "chose \(analysis.bestMove.uci)")
    }
}
