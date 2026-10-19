//
//  StateRoundFixesTests.swift
//  chessTests
//
//  One test per fault found in the next round of review of the state the
//  app keeps, each written to fail on the code as it was: the time already
//  spent on a move lost on Continue, a record of move times that went on
//  from nothing and fell out of step, a Retry during the engine's check that
//  counted a miss Next did not, a second tap on the widget that let the game
//  go on under the puzzle, and wins on a shared device taken for the
//  player's own.
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

/// Waits for `condition`, a twentieth of a second at a time, counted in
/// turns rather than against a clock: a simulator running every suite at
/// once can keep the main actor busy for seconds together.
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// `withScratchStore` for a test that has to wait. The store stays swapped in
/// across the wait, under the lock the other async suites take.
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

// MARK: - Move times

@Suite("State round fixes: move times", .serialized)
@MainActor
struct MoveTimeStateRoundFixesTests {

    /// A clock the test moves by hand.
    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func play(_ model: GameViewModel, _ uci: String) throws {
        let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        #expect(model.game.lastMove == move)
    }

    /// The save as Continue reads it, once whatever is on its way has landed.
    private func savedGame() throws -> SavedGame {
        LocalStore.flush()
        return try #require(SavedGame.load())
    }

    /// The game `saved` holds, picked up the way Continue picks it up.
    private func continued(_ saved: SavedGame, at time: FakeTime) throws -> GameViewModel {
        GameViewModel(
            mode: saved.mode, settings: AppSettings(), restoredGame: saved.restoreGame(),
            options: saved.options ?? .standard, restoredClock: saved.clock,
            restoredMoveTimes: saved.moveTimes, restoredMoveElapsed: saved.moveElapsed,
            timeSource: { time.now }
        )
    }

    @Test("Time already spent on a move is still charged to it after Continue")
    func untimedMoveInProgress() throws {
        try withScratchStore("roundMoveInProgress") {
            let time = FakeTime()
            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings(), timeSource: { time.now })
            time.now += 5
            try play(model, "e2e4")
            // Two minutes on Black's reply, then the app goes to the
            // background, where the system closes it.
            time.now += 120
            model.sceneDidDeactivate()
            model.teardown()
            let saved = try savedGame()
            #expect(saved.moveElapsed == 120)

            time.now += 3_600
            let restored = try continued(saved, at: time)
            defer { restored.teardown() }
            time.now += 10
            try play(restored, "e7e5")
            #expect(restored.moveTimes == [5, 130], "only the seconds after Continue were recorded")
        }
    }

    @Test("On the clock, the move in progress comes back charged the way the clock charges it")
    func timedMoveInProgress() throws {
        try withScratchStore("roundMoveInProgressTimed") {
            let control = TimeControl.minutes(10, plus: 0)
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: control), timeSource: { time.now }
            )
            try play(model, "e2e4")
            time.now += 3
            try play(model, "e7e5")
            time.now += 120
            model.sceneDidDeactivate()
            model.teardown()

            time.now += 3_600
            let restored = try continued(try savedGame(), at: time)
            defer { restored.teardown() }
            #expect(restored.isPaused)
            restored.resume()
            time.now += 10
            try play(restored, "g1f3")
            #expect(restored.moveTimes == [0, 3, 130])
            #expect(restored.clockRemaining(for: .white) == 470)
            // The PGN export rebuilds the clock from the move times: it has
            // to come to what the clock itself shows.
            let faces = PGN.clockFaces(control: control, moveTimes: restored.moveTimes)
            #expect(faces.last == restored.clockRemaining(for: .white), "the exported clock drifted from the real one")
        }
    }

    @Test("A game saved before the move in progress was kept still reads, and takes it from the clock")
    func olderSave() throws {
        try withScratchStore("roundMoveInProgressOld") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(10, plus: 0)), timeSource: { time.now }
            )
            try play(model, "e2e4")
            time.now += 3
            try play(model, "e7e5")
            time.now += 120
            model.teardown()

            // The same save as a build before this one wrote it.
            LocalStore.flush()
            let data = try #require(LocalStore.defaults.data(forKey: "savedGame"))
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json.removeValue(forKey: "moveElapsed") != nil)
            LocalStore.defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "savedGame")
            let saved = try savedGame()
            #expect(saved.moveElapsed == nil)
            #expect(saved.clock != nil)
            #expect(saved.moveTimes == [0, 3])

            let restored = try continued(saved, at: time)
            defer { restored.teardown() }
            restored.resume()
            time.now += 10
            try play(restored, "g1f3")
            #expect(restored.moveTimes == [0, 3, 130])
        }
    }

    @Test("A game that came back without a record in step with its moves records none")
    func noRecordStaysNone() throws {
        try withScratchStore("roundNoRecord") {
            let time = FakeTime()
            // One time for two moves, and none at all — the way 1.0 saved.
            for times: [TimeInterval]? in [[4], nil] {
                let model = GameViewModel(
                    mode: .twoPlayer, settings: AppSettings(), restoredGame: try played(["e2e4", "e7e5"]),
                    restoredMoveTimes: times, timeSource: { time.now }
                )
                defer { model.teardown() }
                #expect(model.moveTimes.isEmpty)
                time.now += 7
                try play(model, "g1f3")
                time.now += 2
                try play(model, "b8c6")
                #expect(model.moveTimes.isEmpty, "a record begun part way through, out of step with the moves")
                #expect(try savedGame().moveTimes == [])
            }
        }
    }

    @Test("A record in step with the moves goes on being kept")
    func recordInStep() throws {
        try withScratchStore("roundRecordInStep") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(), restoredGame: try played(["e2e4", "e7e5"]),
                restoredMoveTimes: [4, 6], timeSource: { time.now }
            )
            defer { model.teardown() }
            time.now += 7
            try play(model, "g1f3")
            #expect(model.moveTimes == [4, 6, 7])
        }
    }
}

// MARK: - The engine's check

@Suite("State round fixes: the mistake check", .serialized)
@MainActor
struct PuzzleCheckStateRoundFixesTests {

    /// Mate in one with Ra8; the game's move was Kf2. Stored under the key
    /// 1.0.1 kept it under, which the next read moves into its file. Once
    /// the writes still on their way have landed: a move made by the run
    /// before drops the key when it lands, and took this one with it.
    private func storeMistake() throws {
        let entry = MistakeEntry(
            id: UUID(), fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: nil, bestUCI: "a1a8",
            playedSAN: "Kf2", quality: .blunder, foundAt: Date()
        )
        LocalStore.flush()
        MistakeStore.shared.reset()
        LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")
    }

    private func play(_ model: PuzzleSessionModel, _ from: String, _ to: String) throws {
        let from = try #require(Square(algebraic: from))
        let to = try #require(Square(algebraic: to))
        model.select(from)
        model.attemptMove(from: from, to: to)
    }

    private var entry: MistakeEntry? { MistakeStore.shared.entries.first }

    @Test("Retry while the engine weighs a move counts no miss, and the try after it still counts")
    func retryDuringTheCheck() throws {
        try withScratchStore("roundRetryDuringCheck") {
            try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            // Neither the answer nor the game's own move: the engine is asked.
            try play(model, "a1", "a7")
            #expect(model.phase == .checking)
            model.retry()
            #expect(model.phase == .playerToMove)
            #expect(entry?.attempts == 0, "a move still being checked was written down as a miss")

            try play(model, "a1", "a8")
            #expect(model.phase == .solved)
            #expect(entry?.fixed == true, "the clean fix after it went down as practice")
            #expect(entry?.attempts == 1)
        }
    }

    @Test("Closing the page while the engine weighs a move counts no miss either")
    func closeDuringTheCheck() throws {
        try withScratchStore("roundCloseDuringCheck") {
            try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            try play(model, "a1", "a7")
            #expect(model.phase == .checking)
            model.teardown()
            #expect(entry?.attempts == 0)
        }
    }

    @Test("A hint taken before the move being checked is a miss, whether Retry, Next or Close follows")
    func hintBeforeTheCheck() throws {
        try withScratchStore("roundHintBeforeCheck") {
            for leave: (PuzzleSessionModel) -> Void in [{ $0.retry() }, { $0.loadNext() }, { $0.teardown() }] {
                try storeMistake()
                let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
                defer { model.teardown() }
                model.showHint()
                try play(model, "a1", "a7")
                #expect(model.phase == .checking)
                leave(model)
                #expect(entry?.attempts == 1, "the hint was forgotten behind the check")
                #expect(entry?.fixed == false)
            }
        }
    }

    @Test("A wrong move before the move being checked is a miss, whether Retry or Next follows")
    func wrongMoveBeforeTheCheck() async throws {
        try await withScratchStoreAsync("roundWrongBeforeCheck") {
            for leave: (PuzzleSessionModel) -> Void in [{ $0.retry() }, { $0.loadNext() }] {
                try storeMistake()
                let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
                defer { model.teardown() }
                // The game's own move again: wrong without asking the engine.
                try play(model, "g1", "f2")
                #expect(model.phase == .wrong)
                try await waitFor { model.isInteractive(color: .white) }
                try play(model, "a1", "a7")
                #expect(model.phase == .checking)
                leave(model)
                #expect(entry?.attempts == 1, "the wrong move was forgotten behind the check")
                #expect(entry?.fixed == false)
            }
        }
    }
}

// MARK: - The daily puzzle

@Suite("State round fixes: opening the daily puzzle")
@MainActor
struct DailyPuzzleStateRoundFixesTests {

    /// What the opening sees of the screen, and what it did about it.
    final class Screen {
        /// A page presented over the root — one on its way down, or the
        /// puzzle itself once it is up.
        var presented = false
        var puzzleShowing = false
        var shown = 0
        var gaveUp = 0
    }

    private func opening(for screen: Screen) -> DailyPuzzleOpening {
        DailyPuzzleOpening(pollInterval: .milliseconds(10), polls: 5) { screen.presented }
    }

    /// A tap on the widget, as `ContentView.openDailyPuzzle` passes it on.
    private func tap(_ opening: DailyPuzzleOpening, on screen: Screen) {
        opening.start(
            isShowing: { screen.puzzleShowing },
            present: {
                screen.shown += 1
                screen.puzzleShowing = true
                screen.presented = true
            },
            giveUp: { screen.gaveUp += 1 }
        )
    }

    @Test("A second tap while the first is waiting replaces it: the puzzle goes up once, the game stays held")
    func secondTapWhileWaiting() async throws {
        let screen = Screen()
        screen.presented = true
        let opening = opening(for: screen)
        tap(opening, on: screen)
        try await Task.sleep(for: .milliseconds(20))
        tap(opening, on: screen)
        screen.presented = false
        try await waitFor { screen.shown > 0 }
        // Long past the wait, which the first tap's twin used to spend
        // looking at the puzzle it had itself put up.
        try await Task.sleep(for: .milliseconds(300))
        #expect(screen.shown == 1)
        #expect(screen.gaveUp == 0, "the game was let go with the puzzle still over it")
        #expect(!opening.isWaiting)
    }

    @Test("A wait that ends with the puzzle up neither shows it again nor lets the game go")
    func puzzleAlreadyUp() async throws {
        let screen = Screen()
        screen.presented = true
        screen.puzzleShowing = true
        let opening = opening(for: screen)
        tap(opening, on: screen)
        try await waitFor { !opening.isWaiting }
        #expect(screen.shown == 0)
        #expect(screen.gaveUp == 0)
    }

    @Test("A page that will not close gives the tap up, once, and the next tap starts afresh")
    func pageThatWillNotClose() async throws {
        let screen = Screen()
        screen.presented = true
        let opening = opening(for: screen)
        tap(opening, on: screen)
        try await waitFor { !opening.isWaiting }
        #expect(screen.gaveUp == 1)
        #expect(screen.shown == 0)

        screen.presented = false
        tap(opening, on: screen)
        try await waitFor { !opening.isWaiting }
        #expect(screen.shown == 1)
        #expect(screen.gaveUp == 1)
    }
}

// MARK: - Achievements

@Suite("State round fixes: two-player achievements", .serialized)
@MainActor
struct AchievementStateRoundFixesTests {

    /// The smothered mate, one move from the end: Nf7.
    private static let knightMate = (fen: "6rk/6pp/8/6N1/8/8/8/6K1 w - - 0 1", move: "g5f7")
    /// g7, with the king on f7 covering g8 and the pawn beside it.
    private static let pawnMate = (fen: "7k/5K1p/6P1/8/8/8/8/8 w - - 0 1", move: "g6g7")

    private static let white = GameMode.vsAI(difficulty: .easy, playerColor: .white)
    private static let black = GameMode.vsAI(difficulty: .easy, playerColor: .black)

    /// White mates with its one move. Filed as a game from the standard
    /// start, as `SetUpPositionStorageFixesTests` files its control, so that
    /// the mode alone decides what it earns.
    private func mate(_ position: (fen: String, move: String), _ mode: GameMode) throws -> GameRecord {
        let game = try played([position.move], from: position.fen)
        try #require(game.outcome == .checkmate(winner: .white))
        return GameRecord(game: game, mode: mode, options: .standard, moveTimes: [1], finalClock: nil)
    }

    /// Black's flag falls on move two.
    private func flag(_ mode: GameMode) throws -> GameRecord {
        var game = try played(["e2e4", "e7e5", "g1f3"])
        game.timeOut()
        try #require(game.outcome == .timeForfeit(winner: .white))
        return GameRecord(
            game: game, mode: mode, options: GameOptions(timeControl: .minutes(1, plus: 0)),
            moveTimes: [0, 1, 1], finalClock: [58, 0]
        )
    }

    /// Fool's mate at knight odds, Black winning.
    private func odds(_ mode: GameMode) throws -> GameRecord {
        let start = StartPosition.handicap(.knight, giver: .white)
        let game = try played(["f2f3", "e7e5", "g2g4", "d8h4"], from: start.fen)
        try #require(game.outcome == .checkmate(winner: .black))
        return GameRecord(game: game, mode: mode, options: GameOptions(start: start), moveTimes: [], finalClock: nil)
    }

    private func finish(_ records: [GameRecord]) {
        for record in records {
            Achievements.shared.gameFinished(record, archive: [record])
        }
    }

    private static let wins: [Achievement.ID] = [.winOnTime, .knightMate, .pawnMate, .handicapWin]

    @Test("A two-player game finishes a game, but its mates, flags and odds are nobody's win")
    func twoPlayerWinsNothing() throws {
        try withScratchStore("roundTwoPlayerWins") {
            let start = StartPosition.chess960(number: 518)
            var shuffled = Game(fen: start.fen)
            shuffled.resign(.white)
            finish([
                try mate(Self.knightMate, .twoPlayer), try mate(Self.pawnMate, .twoPlayer),
                try flag(.twoPlayer), try odds(.twoPlayer),
                GameRecord(game: shuffled, mode: .twoPlayer, options: GameOptions(start: start),
                           moveTimes: [], finalClock: nil),
            ])
            #expect(Achievements.shared.isUnlocked(.firstGame))
            #expect(Achievements.shared.isUnlocked(.chess960Game))
            for id in Self.wins + [.firstWin] {
                #expect(!Achievements.shared.isUnlocked(id), "\(id) earned by one person playing both sides")
            }
        }
    }

    @Test("The same games won against the computer earn them")
    func wonAgainstTheComputer() throws {
        try withScratchStore("roundComputerWins") {
            finish([
                try mate(Self.knightMate, Self.white), try mate(Self.pawnMate, Self.white),
                try flag(Self.white), try odds(Self.black),
            ])
            for id in Self.wins {
                #expect(Achievements.shared.isUnlocked(id), "\(id) not earned by beating the computer")
            }
        }
    }

    @Test("The same games lost to the computer earn none of them")
    func lostToTheComputer() throws {
        try withScratchStore("roundComputerLosses") {
            finish([
                try mate(Self.knightMate, Self.black), try mate(Self.pawnMate, Self.black),
                try flag(Self.black), try odds(Self.white),
            ])
            #expect(Achievements.shared.isUnlocked(.firstGame))
            for id in Self.wins {
                #expect(!Achievements.shared.isUnlocked(id), "\(id) earned by the computer's win")
            }
        }
    }
}
