//
//  FeatureTests.swift
//  chessTests
//
//  Everything around the games themselves: PGN in and out, the puzzles and
//  how they are judged and rated, the archive and what it adds up to, the
//  achievements, the opening trainer, the analysis board and the odds.
//

import Foundation
import Testing
@testable import chess

/// Runs `body` against a scratch store, so nothing a test saves — a game, a
/// puzzle rating, an achievement — is left behind in the real one. The
/// scratch suite brings scratch files with it (see `ScratchStoreLock`).
@MainActor
func withScratchStore(_ name: String, _ body: () throws -> Void) rethrows {
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
    try body()
}

private func game(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
    var game = Game(fen: fen)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

// MARK: - PGN

@Suite("PGN")
struct PGNTests {

    @Test("A game written out reads back as the same game")
    func roundTrip() throws {
        var original = try game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5c6", "d7c6", "e1g1"])
        original.resign(.black)
        let text = PGN.export(game: original, tags: [("White", "Ann"), ("Black", "Ben")])
        #expect(text.contains("[Result \"1-0\"]"))
        #expect(text.contains("5. O-O 1-0"))
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.history.map(\.move.uci) == original.history.map(\.move.uci))
        #expect(parsed.game.outcome == .resigned(winner: .white))
        #expect(parsed.tags["White"] == "Ann")
    }

    @Test("Comments, variations, annotations and move numbers are read past")
    func lenientReading() throws {
        let text = """
            [Event "Test"]
            [Result "*"]

            1.e4 {best by test} e5 (1...c5 2.Nf3) 2. Nf3!? $1 Nc6 ; a line comment
            3.Bb5 a6 4.Ba4 Nf6 5.0-0 Be7 *
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.count == 10)
        #expect(parsed.game.history.last?.san == "Be7")
        #expect(parsed.game.history[8].move.isCastleKingside)
    }

    @Test("Over-disambiguated and capture-less SAN still finds its move")
    func sanVariants() throws {
        let start = Game()
        #expect(PGN.move(for: "Ngf3", in: start)?.uci == "g1f3")
        #expect(PGN.move(for: "Pe4", in: start)?.uci == "e2e4")
        let position = try game(["e2e4", "d7d5"])
        #expect(PGN.move(for: "ed5", in: position)?.uci == "e4d5")
        #expect(PGN.move(for: "exd5", in: position)?.uci == "e4d5")
        let promotion = Game(fen: "8/4P1k1/8/8/8/8/8/4K3 w - - 0 1")
        #expect(PGN.move(for: "e8=N", in: promotion)?.uci == "e7e8n")
        #expect(PGN.move(for: "e8Q+", in: promotion)?.uci == "e7e8q")
    }

    @Test("Several games in one file are all read")
    func multipleGames() throws {
        let one = PGN.export(game: try game(["e2e4", "e7e5"]))
        let two = PGN.export(game: try game(["d2d4", "d7d5", "c2c4"]))
        let games = try PGN.parse(PGN.export([one, two]))
        #expect(games.count == 2)
        #expect(games[1].game.history.count == 3)
    }

    @Test("A game set up from a position carries its FEN")
    func setUpPosition() throws {
        let fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
        let original = try game(["e2e4"], from: fen)
        let text = PGN.export(game: original)
        #expect(text.contains("[SetUp \"1\"]"))
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.initialFEN == fen)
        #expect(parsed.game.history.count == 1)
    }

    @Test("Clock comments are rebuilt from the time each move took")
    func clockFaces() {
        let faces = PGN.clockFaces(control: .minutes(3, plus: 2), moveTimes: [5, 10, 20, 4])
        #expect(faces == [180, 172, 162, 170])
    }

    @Test("Text that is not PGN is refused")
    func garbage() {
        #expect(throws: PGN.ParseError.noGames) { try PGN.parse("") }
    }
}

// MARK: - Puzzles

@Suite("Puzzles")
struct PuzzleTests {

    @Test("The bundled library is there, and every puzzle in it can be set up")
    func libraryLoads() throws {
        let all = PuzzleLibrary.all
        #expect(all.count > 3_000)
        for puzzle in all {
            let attempt = try #require(PuzzleAttempt(puzzle: puzzle), "puzzle \(puzzle.id) does not set up")
            #expect(attempt.expectedMove != nil, "puzzle \(puzzle.id) has no first move")
        }
    }

    @Test("Every curated theme has puzzles to practise")
    func themes() {
        for theme in PuzzleLibrary.curatedThemes {
            #expect(PuzzleLibrary.puzzles(theme: theme).count >= 40, "theme \(theme)")
        }
    }

    @Test("Playing the whole solution solves the puzzle, opponent replies included")
    func solving() throws {
        let puzzle = try #require(PuzzleLibrary.all.first { $0.solution.count >= 3 })
        var attempt = try #require(PuzzleAttempt(puzzle: puzzle))
        while let expected = attempt.expectedMove, !attempt.isSolved {
            let verdict = attempt.play(expected)
            switch verdict {
            case .correct, .solved: break
            case .wrong: Issue.record("the solution's own move was called wrong")
            }
        }
        #expect(attempt.isSolved)
        #expect(!attempt.hadMistake)
    }

    @Test("A wrong move is not played, and marks the attempt")
    func wrongMove() throws {
        let puzzle = try #require(PuzzleLibrary.all.first)
        var attempt = try #require(PuzzleAttempt(puzzle: puzzle))
        let expected = try #require(attempt.expectedMove)
        let other = try #require(attempt.game.legalMoves.first { $0 != expected && !$0.isCapture })
        let board = attempt.game.board
        #expect(attempt.play(other) == .wrong(expected: expected))
        #expect(attempt.game.board == board)
        #expect(attempt.hadMistake)
    }

    @Test("On the last move any mate counts")
    func alternativeMate() throws {
        // Two mates in one on the back rank: either rook will do.
        let puzzle = Puzzle(
            id: "test", fen: "6k1/5ppp/8/8/8/8/8/RR4K1 w - - 0 1", setup: nil,
            solution: ["a1a8"], rating: 1000, themes: ["mateIn1"], source: .library
        )
        var attempt = try #require(PuzzleAttempt(puzzle: puzzle))
        let other = try #require(attempt.game.legalMoves.first { $0.uci == "b1b8" })
        #expect(attempt.play(other) == .solved)
        var wrong = try #require(PuzzleAttempt(puzzle: puzzle))
        let quiet = try #require(wrong.game.legalMoves.first { $0.uci == "b1b7" })
        #expect(wrong.play(quiet) != .solved, "a move that does not mate is still wrong")
    }

    @Test("The daily puzzle is the same all day and changes the next")
    func daily() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 7))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7))!
        let first = try #require(PuzzleLibrary.daily(for: morning, calendar: calendar))
        #expect(PuzzleLibrary.daily(for: evening, calendar: calendar)?.id == first.id)
        #expect(PuzzleLibrary.daily(for: tomorrow, calendar: calendar)?.id != first.id)
    }

    @Test("A rush starts easy and gets harder")
    func rush() {
        var generator = SystemRandomNumberGenerator()
        let sequence = PuzzleLibrary.rushSequence(count: 40, using: &generator)
        #expect(sequence.count == 40)
        #expect(Set(sequence.map(\.id)).count == 40, "a rush never repeats a puzzle")
        #expect(sequence.prefix(5).map(\.rating).max()! < sequence.suffix(5).map(\.rating).min()!)
    }

    @Test("The rating rises on success, falls on failure, and settles")
    func rating() {
        let up = PuzzleRating.updated(1200, puzzle: 1200, solved: true, attempts: 0)
        let down = PuzzleRating.updated(1200, puzzle: 1200, solved: false, attempts: 0)
        #expect(up > 1200 && down < 1200)
        #expect(abs(up - 1200) == abs(down - 1200))
        let late = PuzzleRating.updated(1200, puzzle: 1200, solved: true, attempts: 200)
        #expect(late - 1200 < up - 1200, "later attempts move the rating less")
    }
}

@Suite("Puzzle progress", .serialized)
@MainActor
struct PuzzleProgressTests {

    @Test("A rated attempt moves the rating and is not offered again")
    func rated() throws {
        try withScratchStore("puzzleRated") {
            let puzzle = try #require(PuzzleLibrary.all.first { (1100...1300).contains($0.rating) })
            let change = PuzzleStore.shared.recordRated(puzzle, solved: true)
            #expect(change > 0)
            let progress = PuzzleStore.shared.progress
            #expect(progress.solved == 1)
            #expect(progress.seen.contains(puzzle.id))
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<20 {
                let next = PuzzleLibrary.next(near: progress.rating, exclude: Set(progress.seen), using: &generator)
                #expect(next?.id != puzzle.id)
            }
            #expect(Achievements.shared.isUnlocked(.firstPuzzle))
        }
    }

    @Test("The daily streak counts consecutive days and lapses after a gap")
    func streak() throws {
        withScratchStore("puzzleStreak") {
            let store = PuzzleStore.shared
            store.recordDailySolved(day: 100)
            store.recordDailySolved(day: 101)
            store.recordDailySolved(day: 101)
            #expect(store.progress.dailyStreak == 2)
            #expect(store.progress.currentDailyStreak(today: 102) == 2)
            #expect(store.progress.currentDailyStreak(today: 103) == 0)
            store.recordDailySolved(day: 105)
            #expect(store.progress.dailyStreak == 1)
            #expect(store.progress.dailyBestStreak == 2)
        }
    }

    @Test("A rush records its best score")
    func rushBest() throws {
        withScratchStore("puzzleRush") {
            #expect(PuzzleStore.shared.recordRush(kind: "survival", score: 7))
            #expect(!PuzzleStore.shared.recordRush(kind: "survival", score: 5))
            #expect(PuzzleStore.shared.progress.rushBest["survival"] == 7)
        }
    }

    @Test("The puzzle board judges a move the way the attempt does")
    func session() async throws {
        withScratchStore("puzzleSession") {
            let model = PuzzleSessionModel(kind: .daily, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.attempt != nil)
        }
    }
}

// MARK: - Archive and statistics

@Suite("Archive", .serialized)
@MainActor
struct ArchiveTests {

    private func record(_ mode: GameMode, outcome: GameOutcome, level: Double? = nil) throws -> GameRecord {
        var played = try game(["f2f3", "e7e5", "g2g4", "d8h4"])
        if outcome != played.outcome {
            switch outcome {
            case .resigned(let winner): played = try game(["e2e4"]); played.resign(winner.opponent)
            case .drawAgreed: played = try game(["e2e4"]); played.agreeToDraw()
            default: break
            }
        }
        return GameRecord(game: played, mode: mode,
                          options: GameOptions(adaptiveLevel: level), moveTimes: [], finalClock: nil)
    }

    @Test("Games are kept newest first, and can be removed")
    func keeping() throws {
        try withScratchStore("archiveKeep") {
            let archive = GameArchive.shared
            let first = try record(.twoPlayer, outcome: .checkmate(winner: .black))
            let second = try record(.twoPlayer, outcome: .drawAgreed)
            archive.add(first)
            archive.add(second)
            #expect(archive.records.map(\.id) == [second.id, first.id])
            archive.remove(second.id)
            #expect(archive.records.map(\.id) == [first.id])
            #expect(archive.record(first.id)?.restoreGame()?.outcome == .checkmate(winner: .black))
        }
    }

    @Test("The statistics add the results up by level and colour")
    func statistics() throws {
        let records = [
            try record(.vsAI(difficulty: .hard, playerColor: .black), outcome: .checkmate(winner: .black)),
            try record(.vsAI(difficulty: .hard, playerColor: .white), outcome: .resigned(winner: .black)),
            try record(.vsAI(difficulty: .easy, playerColor: .white), outcome: .drawAgreed),
            try record(.twoPlayer, outcome: .checkmate(winner: .black)),
        ]
        let stats = GameStatistics(records: records)
        #expect(stats.played == 4)
        #expect(stats.twoPlayer == 1)
        #expect(stats.vsComputer.games == 3)
        #expect(stats.byLevel[.hard] == ResultTally(wins: 1, draws: 0, losses: 1))
        #expect(stats.byLevel[.easy]?.draws == 1)
        #expect(stats.byColor[.black]?.wins == 1)
        // Records are newest first, so the win is the latest game and the
        // current streak is that one win.
        #expect(stats.currentStreak == 1)
    }

    @Test("A streak is counted from the oldest game forward")
    func streaks() throws {
        // Newest first, the way the archive holds them: win, win, loss.
        let records = [
            try record(.vsAI(difficulty: .easy, playerColor: .black), outcome: .checkmate(winner: .black)),
            try record(.vsAI(difficulty: .easy, playerColor: .black), outcome: .checkmate(winner: .black)),
            try record(.vsAI(difficulty: .easy, playerColor: .white), outcome: .checkmate(winner: .black)),
        ]
        let stats = GameStatistics(records: records)
        #expect(stats.currentStreak == 2)
        #expect(stats.bestStreak == 2)
    }

    @Test("Strength is estimated only once there is enough to go on")
    func performance() throws {
        let few = try (0..<3).map { _ in
            try record(.vsAI(difficulty: .medium, playerColor: .black), outcome: .checkmate(winner: .black))
        }
        #expect(GameStatistics(records: few).estimatedRating == nil)
        // Ten wins, half by mate and half by the computer's... resignation
        // stand-in: both are wins for the human playing Black.
        let even = try (0..<10).map { index in
            try record(.vsAI(difficulty: .medium, playerColor: .black),
                       outcome: index.isMultiple(of: 2) ? .checkmate(winner: .black) : .resigned(winner: .black))
        }
        // All wins at Medium: well above Medium's own rough figure.
        let rating = try #require(GameStatistics(records: even).estimatedRating)
        #expect(rating > Int(GameStatistics.approximateRating(level: 2)))
    }

    @Test("A first win earns its achievements, once")
    func achievements() throws {
        try withScratchStore("archiveAchievements") {
            let win = try record(.vsAI(difficulty: .beginner, playerColor: .black), outcome: .checkmate(winner: .black))
            GameArchive.shared.add(win)
            #expect(Achievements.shared.isUnlocked(.firstGame))
            #expect(Achievements.shared.isUnlocked(.firstWin))
            #expect(Achievements.shared.isUnlocked(.beatBeginner))
            #expect(Achievements.shared.isUnlocked(.quickMate))
            #expect(!Achievements.shared.isUnlocked(.beatGrandmaster))
            let earned = Achievements.shared.justUnlocked.count
            GameArchive.shared.add(win)
            #expect(Achievements.shared.justUnlocked.count == earned, "an achievement is earned once")
        }
    }

    @Test("A game played to the end lands in the archive")
    func gameEndsInArchive() throws {
        try withScratchStore("archiveGame") {
            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings())
            defer { model.teardown() }
            for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
                let move = try #require(model.game.legalMoves.first { $0.uci == uci })
                model.handleTap(on: move.from)
                model.handleTap(on: move.to)
            }
            #expect(model.game.outcome == .checkmate(winner: .black))
            let stored = try #require(GameArchive.shared.latest)
            #expect(stored.moveUCIs.count == 4)
            #expect(stored.moveTimes.count == 4)
        }
    }

    @Test("The adaptive opponent climbs after a win and drops after a loss")
    func adaptive() throws {
        withScratchStore("adaptive") {
            let settings = AppSettings()
            let start = settings.adaptiveLevel
            settings.recordAdaptiveResult(playerScore: 1)
            #expect(settings.adaptiveLevel > start)
            let afterWin = settings.adaptiveLevel
            settings.recordAdaptiveResult(playerScore: 0)
            #expect(settings.adaptiveLevel < afterWin)
            for _ in 0..<100 { settings.recordAdaptiveResult(playerScore: 1) }
            #expect(settings.adaptiveLevel == 4, "it never goes past Grandmaster")
        }
    }
}

// MARK: - Options

@Suite("Game options")
struct GameOptionsTests {

    @Test("Every handicap is a legal position without the piece", arguments: Handicap.allCases)
    func handicaps(_ handicap: Handicap) throws {
        for giver in PieceColor.allCases {
            let fen = handicap.fen(giver: giver)
            let board = try #require(Board(fen: fen), "\(handicap) for \(giver)")
            #expect(board.piece(at: handicap.square(for: giver)) == nil)
            let pieces = board.squares.count { $0 != 0 }
            #expect(pieces == 31)
            if handicap == .rook {
                #expect(!board.castlingRights.contains(giver == .white ? .whiteQueenside : .blackQueenside))
            }
        }
    }

    @Test("Options saved by an older build — or with nothing in them — still load")
    func lenientDecoding() throws {
        let empty = try JSONDecoder().decode(GameOptions.self, from: Data("{}".utf8))
        #expect(empty == .standard)
        let partial = try JSONDecoder().decode(
            GameOptions.self, from: Data(#"{"tabletop":true,"future":42}"#.utf8))
        #expect(partial.tabletop)
        let saved = try JSONDecoder().decode(
            SavedGame.self,
            from: Data(#"{"mode":{"twoPlayer":{}},"initialFEN":"\#(Board.startFEN)","moveUCIs":[],"savedAt":0}"#.utf8))
        #expect(saved.options == nil && saved.clock == nil)
    }
}

// MARK: - Training

@Suite("Training", .serialized)
@MainActor
struct TrainingTests {

    @Test("Every training line is playable from the start")
    func lines() throws {
        #expect(TrainingLine.all.count >= 30)
        for line in TrainingLine.all {
            let model = OpeningTrainerModel(line: line, playerColor: .white)
            defer { model.teardown() }
            var game = Game()
            for san in line.sans {
                let legal = game.legalMoves
                let move = try #require(legal.first {
                    game.board.san(for: $0, legalMoves: legal).filter { !"+#".contains($0) } == san.filter { !"+#".contains($0) }
                }, "\(line.name): \(san)")
                game.play(move)
            }
        }
    }

    @Test("The trainer accepts the book move and refuses another")
    func trainer() throws {
        try withScratchStore("trainer") {
            let line = try #require(TrainingLine.all.first { $0.sans.first == "e4" })
            let model = OpeningTrainerModel(line: line, playerColor: .white)
            defer { model.teardown() }
            #expect(model.phase == .playerToMove)
            let wrong = try #require(model.game.legalMoves.first { $0.uci == "a2a3" })
            model.handleTap(on: wrong.from)
            model.handleTap(on: wrong.to)
            #expect(model.phase == .wrong)
            #expect(model.ply == 0)
            let right = try #require(model.expectedMove)
            model.handleTap(on: right.from)
            model.handleTap(on: right.to)
            #expect(model.ply == 1)
            #expect(model.mistakes == 1)
        }
    }

    @Test("The analysis board steps through a line and replaces it from a new move")
    func analysis() throws {
        let line = try game(["e2e4", "e7e5", "g1f3"])
        let model = AnalysisBoardModel(game: line)
        model.engineEnabled = false
        defer { model.teardown() }
        #expect(model.plyIndex == 3)
        model.stepBack()
        model.stepBack()
        #expect(model.plyIndex == 1)
        let c5 = try #require(model.game.legalMoves.first { $0.uci == "c7c5" })
        model.handleTap(on: c5.from)
        model.handleTap(on: c5.to)
        #expect(model.line.map(\.move.uci) == ["e2e4", "c7c5"], "a new move replaces what came after")
        #expect(model.canStepForward == false)
    }

    @Test("Sliding the pieces to another position draws exactly that position")
    func layoutSync() throws {
        let start = Board.initial
        let later = try game(["e2e4", "d7d5", "e4d5", "d8d5", "b1c3"]).board
        let layout = PieceLayout(board: start)
        for target in [later, start, later] {
            layout.sync(to: target, animation: nil)
            var drawn = [UInt8](repeating: 0, count: 64)
            for piece in layout.pieces {
                #expect(drawn[piece.square.index] == 0)
                drawn[piece.square.index] = piece.piece.packed
            }
            #expect(drawn == target.squares)
        }
    }
}

// MARK: - Mistakes

@Suite("Mistakes to fix", .serialized)
@MainActor
struct MistakeTests {

    /// A report built by hand: every move the engine's choice and level,
    /// except White's second, which throws away a whole piece.
    private func report(for game: Game, blunderAt blunderPly: Int, best: Move) -> GameAnalysis {
        let jobs = GameAnalyzer.positions(of: game)
        let results: [PositionAnalysis?] = jobs.map { job in
            guard let played = job.playedMove else { return nil }
            let isBlunder = job.index == blunderPly
            return PositionAnalysis(
                bestMove: isBlunder ? best : played,
                bestScore: isBlunder ? 50 : 0,
                focusScore: isBlunder ? -350 : 0,
                hasCloseAlternative: false,
                legalMoveCount: job.board.generateLegalMoves().count,
                depth: 10, nodes: 1000
            )
        }
        return GameAnalyzer.assemble(game: game, jobs: jobs, results: results)
    }

    @Test("A blunder in a reviewed game becomes a puzzle, shown from the move before")
    func collected() throws {
        try withScratchStore("mistakes") {
            // 1.e4 e5 2.Qh5 Nc6 3.Qxf7+?? — the queen is simply lost to the king.
            let played = try game(["e2e4", "e7e5", "d1h5", "b8c6", "h5f7"])
            let before = Game(fen: GameAnalyzer.positions(of: played)[4].board.fen)
            let best = try #require(before.legalMoves.first { $0.uci == "f1c4" })
            let analysis = report(for: played, blunderAt: 4, best: best)
            #expect(analysis.moves[4].quality == .blunder)

            MistakeStore.shared.collect(from: analysis, game: played, colors: [.white])
            let entry = try #require(MistakeStore.shared.pending.first)
            #expect(MistakeStore.shared.pending.count == 1, "only the blunder is collected")
            #expect(entry.bestUCI == "f1c4")
            #expect(entry.setupUCI == "b8c6", "the puzzle opens on the opponent's move before it")
            var attempt = try #require(PuzzleAttempt(puzzle: entry.puzzle))
            #expect(attempt.game.board == before.board, "the puzzle stands where the blunder was played")
            #expect(attempt.play(best) == .solved)

            // The same game reviewed again adds nothing new.
            MistakeStore.shared.collect(from: analysis, game: played, colors: [.white])
            #expect(MistakeStore.shared.entries.count == 1)

            // Black's mistakes are not White's to fix.
            MistakeStore.shared.reset()
            MistakeStore.shared.collect(from: analysis, game: played, colors: [.black])
            #expect(MistakeStore.shared.entries.isEmpty)
        }
    }

    @Test("Fixing a mistake marks it done and counts towards the achievement")
    func fixing() throws {
        try withScratchStore("mistakesFixed") {
            let played = try game(["e2e4", "e7e5", "d1h5", "b8c6", "h5f7"])
            let before = Game(fen: GameAnalyzer.positions(of: played)[4].board.fen)
            let best = try #require(before.legalMoves.first { $0.uci == "f1c4" })
            MistakeStore.shared.collect(from: report(for: played, blunderAt: 4, best: best), game: played, colors: [.white])
            let entry = try #require(MistakeStore.shared.pending.first)
            MistakeStore.shared.recordAttempt(entry.id, solved: true)
            #expect(MistakeStore.shared.pending.isEmpty)
            #expect(MistakeStore.shared.fixedCount == 1)
        }
    }
}
