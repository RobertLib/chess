//
//  StorageReviewFixesTests.swift
//  chessTests
//
//  One test per fault found in the review of what the app keeps and how it
//  counts it, each written to fail on the code as it was: the archive and
//  the other large stores kept in UserDefaults, with every unreadable copy
//  kept there beside them for good; puzzle progress lost whole to one field
//  it could not read, and theme results that trapped when cut short;
//  Graduate out of reach for the readers of 1.0; games from set-up
//  positions counted as wins at full strength; and the puzzle achievements
//  blind to every puzzle that was not rated.
//
//  The widget's two faults — a board VoiceOver could not read, and a puzzle
//  that kept to the old time zone after a flight — are in an extension of
//  its own, which no test target builds; the widget is checked by building.
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

// MARK: - Files

@Suite("Storage fixes: files", .serialized)
@MainActor
struct FileStorageFixesTests {

    private func record(_ ucis: [String], at seconds: TimeInterval) throws -> GameRecord {
        GameRecord(
            game: try played(ucis), mode: .vsAI(difficulty: .medium, playerColor: .white),
            options: .standard, moveTimes: Array(repeating: 2, count: ucis.count), finalClock: nil,
            finishedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )
    }

    private func mistake(_ fen: String) -> MistakeEntry {
        MistakeEntry(
            id: UUID(), fen: fen, setupUCI: nil, bestUCI: "e2e4", playedSAN: "a3",
            quality: .blunder, foundAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
    }

    /// Progress as 1.0.1 wrote it, field for field — without the count of
    /// unrated puzzles solved, which it did not keep.
    private let progressAsLeft = """
        {"rating":1432.5,"attempts":12,"solved":7,"history":[1210,1225.5],"seen":["00001","00002"],\
        "themeResults":{"fork":[2,3]},"rushBest":{"survival":11},"dailyLastSolved":1000,\
        "dailyStreak":3,"dailyBestStreak":5}
        """

    @Test("The archive, the review cache, the puzzles and the mistakes are written to files, not UserDefaults")
    func largeStoresLiveInFiles() throws {
        try withScratchStore("storageFiles") {
            GameArchive.shared.add(try record(["e2e4", "e7e5"], at: 800_000_000))
            let position = CachedPosition(PositionAnalysis(
                bestMove: try #require(Board.initial.generateLegalMoves().first), bestScore: 20,
                focusScore: nil, hasCloseAlternative: true, legalMoveCount: 20, depth: 4, nodes: 1000
            ))
            AnalysisCache.save(CachedGameAnalysis(fingerprint: "game", positions: [position], updatedAt: Date()))
            PuzzleStore.shared.recordRated(try #require(PuzzleLibrary.all.first), solved: true)
            LocalStore.defaults.set(try JSONEncoder().encode([mistake(Board.startFEN)]), forKey: "mistakes")
            let entry = try #require(MistakeStore.shared.entries.first)
            MistakeStore.shared.recordAttempt(entry.id, solved: false)

            LocalStore.flush()
            for key in ["gameArchive", "analysisCache", "puzzleProgress", "mistakes"] {
                #expect(LocalStore.defaults.object(forKey: key) == nil, "\(key) is still in UserDefaults")
                #expect(LocalStore.files.read(key) != nil, "\(key) has no file")
            }
            let archive = try JSONDecoder().decode([GameRecord].self, from: try #require(LocalStore.files.read("gameArchive")))
            #expect(archive == GameArchive.shared.records)
            let progress = try JSONDecoder().decode(PuzzleProgress.self, from: try #require(LocalStore.files.read("puzzleProgress")))
            #expect(progress == PuzzleStore.shared.progress)
            let entries = try JSONDecoder().decode([MistakeEntry].self, from: try #require(LocalStore.files.read("mistakes")))
            #expect(entries.first?.attempts == 1)
        }
    }

    @Test("What 1.0.1 kept in UserDefaults reads back after the update, moved into files, the keys dropped")
    func storesMoveOutOfUserDefaults() throws {
        try withScratchStore("storageMigration") {
            let records = [
                try record(["d2d4", "d7d5"], at: 800_000_100),
                try record(["e2e4", "c7c5"], at: 800_000_000),
            ]
            let entries = [mistake(Board.startFEN)]
            let cached = [CachedGameAnalysis(fingerprint: "game", positions: [nil], updatedAt: Date())]
            let left: [String: Data] = [
                "gameArchive": try JSONEncoder().encode(records),
                "analysisCache": try JSONEncoder().encode(cached),
                "puzzleProgress": Data(progressAsLeft.utf8),
                "mistakes": try JSONEncoder().encode(entries),
                "mistakeGames": try JSONEncoder().encode(["1f2e", "3a4b"]),
            ]
            for (key, data) in left { LocalStore.defaults.set(data, forKey: key) }

            #expect(GameArchive.shared.records == records)
            #expect(AnalysisCache.load().map(\.fingerprint) == ["game"])
            let progress = PuzzleStore.shared.progress
            #expect(progress.rating == 1432.5)
            #expect(progress.solved == 7)
            #expect(progress.seen == ["00001", "00002"])
            #expect(progress.dailyBestStreak == 5)
            #expect(MistakeStore.shared.entries == entries)
            #expect(LocalStore.list(of: String.self, inFile: "mistakeGames") == ["1f2e", "3a4b"])

            LocalStore.flush()
            for (key, data) in left {
                #expect(LocalStore.defaults.object(forKey: key) == nil, "\(key) was left in UserDefaults")
                #expect(LocalStore.files.read(key) == data, "\(key) did not move across as it was stored")
                #expect(LocalStore.setAsideCopy(forKey: key) == nil, "\(key) was set aside although it read")
            }
        }
    }

    @Test("A key still there beside its file is dropped, and the file is the store")
    func fileWinsOverALeftoverKey() throws {
        try withScratchStore("storageLeftoverKey") {
            let current = [try record(["e2e4"], at: 800_000_200)]
            let leftover = [try record(["c2c4"], at: 800_000_100)]
            try LocalStore.files.write(try JSONEncoder().encode(current), as: "gameArchive")
            LocalStore.defaults.set(try JSONEncoder().encode(leftover), forKey: "gameArchive")

            #expect(GameArchive.shared.records == current)
            #expect(LocalStore.defaults.object(forKey: "gameArchive") == nil)
        }
    }

    @Test("A store emptied before it was read is not brought back from its old key")
    func resetDropsTheOldKey() throws {
        try withScratchStore("storageReset") {
            LocalStore.defaults.set(Data(progressAsLeft.utf8), forKey: "puzzleProgress")
            PuzzleStore.shared.reset()
            #expect(PuzzleStore.shared.progress == PuzzleProgress())

            LocalStore.defaults.set(try JSONEncoder().encode([mistake(Board.startFEN)]), forKey: "mistakes")
            MistakeStore.shared.reset()
            #expect(MistakeStore.shared.entries.isEmpty)
        }
    }

    @Test("What does not read is set aside as a file — the latest copy only, and never in UserDefaults")
    func setAsideCopiesAreBounded() throws {
        try withScratchStore("storageSetAside") {
            let first = Data("{ the first damage".utf8)
            LocalStore.defaults.set(first, forKey: "gameArchive")
            #expect(GameArchive.shared.records.isEmpty)
            #expect(LocalStore.setAsideCopy(forKey: "gameArchive") == first)
            #expect(LocalStore.defaults.object(forKey: "gameArchive.unreadable") == nil, "kept in UserDefaults")

            // Gone wrong again later: the new copy takes the old one's place,
            // rather than piling up beside it.
            let second = Data("{ the second damage".utf8)
            LocalStore.setAside(second, forKey: "gameArchive")
            #expect(LocalStore.setAsideCopy(forKey: "gameArchive") == second)
            let kept = try FileManager.default.contentsOfDirectory(
                at: LocalStore.files.directory.appending(path: "Unreadable"), includingPropertiesForKeys: nil
            )
            #expect(kept.map(\.lastPathComponent) == ["gameArchive.json"])
        }
    }

    @Test("Copies earlier builds set aside in UserDefaults are moved out into files")
    func legacySetAsideCopiesMoveOut() throws {
        withScratchStore("storageLegacySetAside") {
            let kept = Data("{ kept aside by 1.0.1".utf8)
            LocalStore.defaults.set(kept, forKey: "achievements.unreadable")
            LocalStore.defaults.set(kept, forKey: "gameArchive.unreadable")

            #expect(LocalStore.setAsideCopy(forKey: "achievements") == kept)
            #expect(LocalStore.setAsideCopy(forKey: "gameArchive") == kept)
            #expect(LocalStore.defaults.object(forKey: "achievements.unreadable") == nil)
            #expect(LocalStore.defaults.object(forKey: "gameArchive.unreadable") == nil)
        }
    }

    @Test("A scratch suite brings scratch files with it, and the old files come back with the old suite")
    func scratchFilesFollowTheSuite() throws {
        let outer = LocalStore.defaults
        let outerFiles = LocalStore.files
        try withScratchStore("storageScratchFiles") {
            let suite = LocalStore.defaults
            let files = LocalStore.files
            #expect(files !== FileStore.standard)
            #expect(files !== outerFiles)
            #expect(!files.directory.path.hasPrefix(FileStore.standard.directory.path))

            // Put away and swapped in again, the same suite finds the same
            // files: a test that waits with its store put away carries on
            // where it left off.
            let other = try #require(UserDefaults(suiteName: "chessTests.storageScratchFilesOther"))
            LocalStore.defaults = other
            #expect(LocalStore.files !== files)
            LocalStore.defaults = suite
            #expect(LocalStore.files === files)
        }
        #expect(LocalStore.defaults === outer)
        #expect(LocalStore.files === outerFiles)
    }
}

// MARK: - Puzzle progress

@Suite("Storage fixes: puzzle progress", .serialized)
@MainActor
struct PuzzleProgressStorageFixesTests {

    @Test("A field that does not read falls back to its default, and the others survive")
    func oneBadFieldCostsOnlyItself() throws {
        let stored = Data("""
            {"rating":1640,"attempts":"many","solved":9,"history":"none","seen":["00a1","00b2"],\
            "rushBest":{"survival":9},"dailyLastSolved":1000,"dailyStreak":"x","dailyBestStreak":4}
            """.utf8)
        let progress = try JSONDecoder().decode(PuzzleProgress.self, from: stored)
        #expect(progress.rating == 1640, "the rating went with a field beside it")
        #expect(progress.attempts == 0)
        #expect(progress.solved == 9)
        #expect(progress.history.isEmpty)
        #expect(progress.seen == ["00a1", "00b2"])
        #expect(progress.rushBest == ["survival": 9])
        #expect(progress.dailyLastSolved == 1000)
        #expect(progress.dailyStreak == 0)
        #expect(progress.dailyBestStreak == 4)

        withScratchStore("storageProgressField") {
            LocalStore.defaults.set(stored, forKey: "puzzleProgress")
            #expect(PuzzleStore.shared.progress.rating == 1640)
            #expect(PuzzleStore.shared.progress.seen.count == 2)
        }
    }

    @Test("A theme result shorter than the pair is left out on reading, not kept to trap on")
    func shortThemeResultsAreDropped() throws {
        let fork = try #require(PuzzleLibrary.puzzles(theme: "fork").first { !$0.hasTheme("pin") })
        try withScratchStore("storageThemeResults") {
            LocalStore.defaults.set(Data(#"{"rating":1500,"themeResults":{"fork":[3],"pin":[2,5]}}"#.utf8),
                                    forKey: "puzzleProgress")
            let read = PuzzleStore.shared.progress.themeResults
            // The puzzle page reads `[1]` of every entry: they must all be pairs.
            try #require(read.values.allSatisfy { $0.count >= 2 }, "a short entry was kept: \(read)")
            #expect(read == ["pin": [2, 5]])

            PuzzleStore.shared.recordRated(fork, solved: true)
            #expect(PuzzleStore.shared.progress.themeResults["fork"] == [1, 1])
            #expect(PuzzleStore.shared.progress.themeResults["pin"] == [2, 5])
        }

        // An entry that does not read at all goes the same way, and costs
        // neither the other themes nor the rest of the progress.
        let progress = try JSONDecoder().decode(PuzzleProgress.self, from: Data(
            #"{"rating":1500,"themeResults":{"fork":"three","pin":[2,5]}}"#.utf8
        ))
        #expect(progress.themeResults == ["pin": [2, 5]])
        #expect(progress.rating == 1500)
    }
}

// MARK: - Graduate

@Suite("Storage fixes: Graduate", .serialized)
@MainActor
struct GraduateStorageFixesTests {

    private let chapters = TutorialGuide.chapters.map(\.id)

    @Test("Every chapter read under 1.0, before there was anything to earn, earns Graduate at launch")
    func earnedAtLaunch() throws {
        withScratchStore("storageGraduateLaunch") {
            LocalStore.defaults.set(chapters, forKey: "readTutorialChapters")
            let banners = Achievements.shared.justUnlocked.count
            _ = AppSettings()
            #expect(Achievements.shared.isUnlocked(.allLessons), "out of reach for a reader of 1.0")
            #expect(Achievements.shared.justUnlocked.count == banners + 1)
            #expect(Achievements.shared.justUnlocked.last?.id == .allLessons)

            // The next launch does not announce it again.
            _ = AppSettings()
            #expect(Achievements.shared.justUnlocked.count == banners + 1, "announced twice")
        }
    }

    @Test("A chapter read again to the end counts as well")
    func earnedOnReadingAgain() throws {
        withScratchStore("storageGraduateReread") {
            LocalStore.defaults.set(chapters, forKey: "readTutorialChapters")
            let settings = AppSettings()
            Achievements.shared.reset()
            settings.markTutorialChapterRead(chapters[0])
            #expect(Achievements.shared.isUnlocked(.allLessons), "a chapter already read was passed over")
        }
    }

    @Test("A chapter short, or one that no longer exists, earns nothing")
    func notEveryChapter() throws {
        withScratchStore("storageGraduateShort") {
            LocalStore.defaults.set(Array(chapters.dropLast()) + ["a chapter since dropped"],
                                    forKey: "readTutorialChapters")
            let banners = Achievements.shared.justUnlocked.count
            _ = AppSettings()
            #expect(!Achievements.shared.isUnlocked(.allLessons))
            #expect(Achievements.shared.justUnlocked.count == banners)
        }
    }
}

// MARK: - Set-up positions

@Suite("Storage fixes: set-up positions", .serialized)
@MainActor
struct SetUpPositionStorageFixesTests {

    /// King and queen against a lone king, mate in one: Qb8.
    private static let queenMate = (fen: "7k/8/6K1/8/8/8/8/1Q6 w - - 0 1", move: "b1b8")
    /// The smothered mate, one move from the end: Nf7.
    private static let knightMate = (fen: "6rk/6pp/8/6N1/8/8/8/6K1 w - - 0 1", move: "g5f7")

    /// A game set up at `position` and won by White with its one move.
    private func setUp(
        _ position: (fen: String, move: String), _ mode: GameMode, clock: TimeControl? = nil
    ) throws -> GameRecord {
        let game = try played([position.move], from: position.fen)
        try #require(game.outcome == .checkmate(winner: .white))
        return GameRecord(
            game: game, mode: mode, options: GameOptions(timeControl: clock, start: .custom(fen: position.fen)),
            moveTimes: [1], finalClock: nil
        )
    }

    /// Fool's mate, Black winning: a real game from the standard start.
    private func standardWin(as color: PieceColor = .black) throws -> GameRecord {
        GameRecord(
            game: try played(["f2f3", "e7e5", "g2g4", "d8h4"]), mode: .vsAI(difficulty: .easy, playerColor: color),
            options: .standard, moveTimes: [], finalClock: nil
        )
    }

    @Test("A won position set up against Grandmaster finishes a game but wins nothing")
    func setUpWinEarnsNoWins() throws {
        try withScratchStore("storageSetUpWin") {
            let archive = GameArchive.shared
            for _ in 0..<3 {
                archive.add(try setUp(Self.queenMate, .vsAI(difficulty: .expert, playerColor: .white),
                                      clock: .minutes(1, plus: 0)))
            }
            // Against the computer: a two-player game wins nothing whatever
            // its start (see `Achievements.gameFinished`), and so would pass
            // here without the set-up position having anything to do with it.
            archive.add(try setUp(Self.knightMate, .vsAI(difficulty: .beginner, playerColor: .white)))
            #expect(Achievements.shared.isUnlocked(.firstGame))
            for id: Achievement.ID in [.firstWin, .beatGrandmaster, .quickMate, .hatTrick, .bulletWin, .knightMate] {
                #expect(!Achievements.shared.isUnlocked(id), "\(id) earned from a set-up position")
            }
        }
    }

    @Test("A game at odds still earns what a win earns")
    func oddsStillCount() throws {
        try withScratchStore("storageOddsWin") {
            let start = StartPosition.handicap(.knight, giver: .white)
            let game = try played(["f2f3", "e7e5", "g2g4", "d8h4"], from: start.fen)
            try #require(game.outcome == .checkmate(winner: .black))
            GameArchive.shared.add(GameRecord(
                game: game, mode: .vsAI(difficulty: .hard, playerColor: .black),
                options: GameOptions(start: start), moveTimes: [], finalClock: nil
            ))
            #expect(Achievements.shared.isUnlocked(.firstWin))
            #expect(Achievements.shared.isUnlocked(.beatHard))
            #expect(Achievements.shared.isUnlocked(.handicapWin))
        }
    }

    @Test("Wins from set-up positions are no part of the results, the streaks or the strength estimate")
    func setUpGamesLeftOutOfTheStatistics() throws {
        let wins = try (0..<6).map { _ in
            try setUp(Self.queenMate, .vsAI(difficulty: .expert, playerColor: .white))
        }
        let stats = GameStatistics(records: wins)
        #expect(stats.played == 6, "a set-up game is still a game played")
        #expect(stats.estimatedRating == nil, "six set-up wins made a Grandmaster")
        #expect(stats.vsComputer.games == 0)
        #expect(stats.byLevel.isEmpty)
        #expect(stats.bestStreak == 0)

        // Newest first: a win, a set-up loss, a win. The set-up game neither
        // adds to the run nor breaks it.
        let mixed = [
            try standardWin(),
            try setUp(Self.queenMate, .vsAI(difficulty: .easy, playerColor: .black)),
            try standardWin(),
        ]
        let streak = GameStatistics(records: mixed)
        #expect(streak.currentStreak == 2)
        #expect(streak.vsComputer == ResultTally(wins: 2, draws: 0, losses: 0))

        // Against five real wins, five set-up ones change nothing.
        let real = try (0..<5).map { _ in try standardWin() }
        #expect(GameStatistics.performance(of: real + wins.prefix(5)) == GameStatistics.performance(of: real))
    }

    @Test("A reviewed game from a set-up position earns no Precision")
    func setUpGameEarnsNoPrecision() throws {
        try withScratchStore("storageSetUpPrecision") {
            var record = try setUp(Self.queenMate, .vsAI(difficulty: .easy, playerColor: .white))
            record.moveUCIs = Array(repeating: "b1b8", count: 40)
            record.accuracy = [99, 99]
            Achievements.shared.gameReviewed(record)
            #expect(!Achievements.shared.isUnlocked(.precision), "earned in a position won from the start")

            // The same figures from the standard start: the control.
            record.options.start = .standard
            Achievements.shared.gameReviewed(record)
            #expect(Achievements.shared.isUnlocked(.precision))
        }
    }
}

// MARK: - Puzzles solved

@Suite("Storage fixes: puzzles solved", .serialized)
@MainActor
struct PuzzlesSolvedStorageFixesTests {

    @Test("The daily puzzle solved cleanly is a puzzle solved; solved with help it counts for the streak only")
    func dailyPuzzle() throws {
        withScratchStore("storageSolvedDaily") {
            let store = PuzzleStore.shared
            store.recordDailySolved(day: 400)
            #expect(store.progress.dailyStreak == 1)
            #expect(!Achievements.shared.isUnlocked(.firstPuzzle), "a daily solved with help was counted")

            store.recordDailySolved(day: 401, clean: true)
            #expect(Achievements.shared.isUnlocked(.firstPuzzle), "a clean daily solve earned nothing")
            #expect(store.progress.puzzlesSolved == 1)
            #expect(store.progress.solved == 0, "the rated count took an unrated puzzle")

            // Once a day: the same day again counts nothing more.
            store.recordDailySolved(day: 401, clean: true)
            #expect(store.progress.puzzlesSolved == 1)
        }
    }

    @Test("A puzzle solved in a race counts, the first time it is seen only")
    func racePuzzles() throws {
        withScratchStore("storageSolvedRace") {
            let store = PuzzleStore.shared
            let puzzles = Array(PuzzleLibrary.all.prefix(51))
            store.markSeen(puzzles[0])
            #expect(Achievements.shared.isUnlocked(.firstPuzzle), "a puzzle solved in a race earned nothing")
            store.markSeen(puzzles[0])
            #expect(store.progress.puzzlesSolved == 1, "the same puzzle counted twice")

            // Seen first as a rated miss, it is not counted when it comes
            // round again in a race.
            store.recordRated(puzzles[50], solved: false)
            store.markSeen(puzzles[50])
            #expect(store.progress.puzzlesSolved == 1)

            for puzzle in puzzles[1..<50] { store.markSeen(puzzle) }
            #expect(store.progress.puzzlesSolved == 50)
            #expect(Achievements.shared.isUnlocked(.puzzles50))
        }
    }

    @Test("A mistake fixed is a puzzle solved, once")
    func mistakesFixed() throws {
        try withScratchStore("storageSolvedMistake") {
            let entry = MistakeEntry(
                id: UUID(), fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: nil, bestUCI: "a1a8",
                playedSAN: "Kf2", quality: .blunder, foundAt: Date()
            )
            LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")
            MistakeStore.shared.recordAttempt(entry.id, solved: false)
            #expect(!Achievements.shared.isUnlocked(.firstPuzzle))

            MistakeStore.shared.recordAttempt(entry.id, solved: true)
            #expect(Achievements.shared.isUnlocked(.firstPuzzle), "a mistake fixed earned nothing")
            MistakeStore.shared.recordAttempt(entry.id, solved: true)
            #expect(PuzzleStore.shared.progress.puzzlesSolved == 1, "a mistake fixed again counted again")
        }
    }

    @Test("Solves of every kind add up towards the same achievements")
    func everyKindAddsUp() throws {
        withScratchStore("storageSolvedTogether") {
            let store = PuzzleStore.shared
            let puzzles = Array(PuzzleLibrary.all.prefix(49))
            for puzzle in puzzles.prefix(25) { store.recordRated(puzzle, solved: true) }
            for puzzle in puzzles.dropFirst(25) { store.markSeen(puzzle) }
            #expect(!Achievements.shared.isUnlocked(.puzzles50))
            store.recordDailySolved(day: 500, clean: true)
            #expect(store.progress.solved == 25)
            #expect(store.progress.puzzlesSolved == 50)
            #expect(Achievements.shared.isUnlocked(.puzzles50))
        }
    }
}
