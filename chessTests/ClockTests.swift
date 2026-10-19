//
//  ClockTests.swift
//  chessTests
//
//  The clock: what each kind of bonus gives back, that a pause loses nothing,
//  what a flag fall means under FIDE 6.9, how the computer budgets its time —
//  and that a game on the clock behaves like one.
//

import Foundation
import Testing
@testable import chess

@Suite("Chess clock")
struct ChessClockTests {

    @Test("Fischer increment is added after every move")
    func increment() {
        var clock = ChessClock(control: .minutes(3, plus: 2))
        clock.start(.white, at: 0)
        #expect(clock.remaining(for: .white, at: 10) == 170)
        let used = clock.press(at: 10)
        #expect(used == 10)
        #expect(clock.remaining(for: .white, at: 10) == 172)
        #expect(clock.active == .black)
        #expect(clock.remaining(for: .black, at: 15) == 175)
        #expect(clock.moveCount(for: .white) == 1)
    }

    @Test("A simple delay spends nothing until it runs out, and adds nothing")
    func simpleDelay() {
        var clock = ChessClock(control: TimeControl(initial: 60, bonus: 5, bonusKind: .delay))
        clock.start(.white, at: 0)
        #expect(clock.remaining(for: .white, at: 4) == 60, "inside the delay the bank is untouched")
        #expect(clock.remaining(for: .white, at: 8) == 57)
        clock.press(at: 8)
        #expect(clock.remaining(for: .white, at: 8) == 57, "a delay never adds time")
        #expect(clock.timeUntilFlag(at: 8) == 65, "Black has the bank plus the delay")
    }

    @Test("Bronstein gives back what was used, up to the bonus")
    func bronstein() {
        var clock = ChessClock(control: TimeControl(initial: 60, bonus: 5, bonusKind: .bronstein))
        clock.start(.white, at: 0)
        clock.press(at: 3)
        #expect(clock.remaining(for: .white, at: 3) == 60, "three seconds used, three given back")
        clock.press(at: 13)
        #expect(clock.remaining(for: .black, at: 13) == 55, "ten used, five given back")
    }

    @Test("A pause loses nothing and survives a round trip through storage")
    func pauseAndStorage() throws {
        var clock = ChessClock(control: .minutes(5, plus: 0))
        clock.start(.white, at: 100)
        clock.pause(at: 130)
        #expect(clock.isPaused)
        #expect(clock.remaining(for: .white, at: 500) == 270, "a paused clock does not run")
        clock.resume(at: 500)
        #expect(clock.remaining(for: .white, at: 510) == 260)

        // What a save writes is a paused clock; what it reads back is the same.
        let saved = clock.pausedCopy(at: 520)
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(ChessClock.self, from: data)
        #expect(restored.isPaused)
        #expect(restored.remaining(for: .white, at: 9_999) == 250)
        #expect(restored.remaining(for: .black, at: 9_999) == 300)
        #expect(restored.turnElapsed(at: 0) == 50, "the turn interrupted by the pause is still one turn")
    }

    @Test("Pressing while paused lands the move and keeps the clock held")
    func pressWhilePaused() {
        var clock = ChessClock(control: .minutes(1, plus: 1))
        clock.start(.black, at: 0)
        clock.pause(at: 5)
        clock.press(at: 50)
        #expect(clock.active == .white)
        #expect(clock.isPaused, "the computer's move must not restart a held clock")
        #expect(clock.remaining(for: .black, at: 50) == 56)
    }

    @Test("Only the side on turn can flag, and only at zero")
    func flagFall() {
        var clock = ChessClock(control: TimeControl(initial: 10, bonus: 0))
        clock.start(.white, at: 0)
        #expect(clock.flagged(at: 9.99) == nil)
        #expect(clock.flagged(at: 10) == .white)
        #expect(clock.remaining(for: .white, at: 30) == 0, "a face never reads negative")
        clock.stop(at: 30)
        #expect(clock.flagged(at: 40) == nil, "a stopped clock has nobody on turn")
    }

    @Test("Time odds start the two sides with different banks")
    func timeOdds() {
        let control = TimeControl(initial: 300, bonus: 0, initialBlack: 120)
        let clock = ChessClock(control: control)
        #expect(clock.remaining(for: .white, at: 0) == 300)
        #expect(clock.remaining(for: .black, at: 0) == 120)
        #expect(control.label == "5 / 2 + 0")
    }

    @Test("Labels read the way players write time controls")
    func labels() {
        #expect(TimeControl.minutes(3, plus: 2).label == "3 + 2")
        #expect(TimeControl(initial: 30, bonus: 0).label == "½ + 0")
        #expect(TimeControl(initial: 90, bonus: 1).label == "1½ + 1")
        #expect(TimeControl.minutes(2, plus: 1).category == .bullet)
        #expect(TimeControl.minutes(3, plus: 2).category == .blitz)
        #expect(TimeControl.minutes(10, plus: 5).category == .rapid)
        #expect(TimeControl.minutes(30, plus: 20).category == .classical)
    }

    @Test("Faces round the way a clock must")
    func faces() {
        #expect(ClockFormat.text(299.2) == "5:00", "whole seconds round up")
        #expect(ClockFormat.text(0.05, tenths: true) == "0:00.0", "tenths round down")
        #expect(ClockFormat.text(9.87, tenths: true) == "0:09.8")
        #expect(ClockFormat.text(3725) == "1:02:05")
    }

    @Test("The stopwatch only counts while it runs")
    func stopwatch() {
        var watch = Stopwatch()
        watch.start(at: 0)
        watch.pause(at: 4)
        watch.resume(at: 100)
        #expect(watch.lap(at: 103) == 7)
        #expect(watch.elapsed(at: 110) == 7)
    }
}

@Suite("Flag fall")
struct FlagFallTests {

    private func outcome(_ fen: String) throws -> GameOutcome {
        var game = Game(fen: fen)
        try #require(game.outcome == .ongoing)
        game.timeOut()
        return game.outcome
    }

    @Test("Running out of time loses against a side that can still mate")
    func loses() throws {
        #expect(try outcome("4k3/8/8/8/8/8/4P3/4K3 b - - 0 1") == .timeForfeit(winner: .white))
        #expect(try outcome("4k3/8/8/8/8/8/8/R3K3 b - - 0 1") == .timeForfeit(winner: .white))
    }

    @Test("Against a lone king it is a draw")
    func bareKing() throws {
        #expect(try outcome("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1") == .drawTimeoutInsufficientMaterial)
    }

    /// A lone knight against a bare king is a dead draw before any clock gets
    /// a say, so the case that matters is the knight against a king that has
    /// something left: that something can box its own king in. A queen
    /// cannot — no position has a lone knight mating a king and queen.
    @Test("A lone knight still wins on time against a king with a piece beside it, but not a queen")
    func knight() throws {
        #expect(try outcome("4k3/4p3/8/8/8/8/8/1N2K3 b - - 0 1") == .timeForfeit(winner: .white))
        #expect(try outcome("3qk3/8/8/8/8/8/8/1N2K3 b - - 0 1") == .drawTimeoutInsufficientMaterial)
        #expect(Board(fen: "3qk3/8/8/8/8/8/8/1N2K3 b - - 0 1")?.hasMatingMaterial(.white) == false)
        #expect(Board(fen: "4k3/8/8/8/8/8/8/1N2K3 b - - 0 1")?.hasMatingMaterial(.white) == false)
    }

    @Test("Bishops on one colour need a blocker on the other")
    func bishops() throws {
        // c1 and f4 are both dark squares; Black's bishop on c8 is light.
        #expect(try outcome("2b1k3/8/8/8/5B2/8/8/2B1K3 b - - 0 1") == .timeForfeit(winner: .white))
        // Black's bishop on f8 is dark too. Every bishop on one colour is a
        // dead position before any clock gets a say: the game is drawn on
        // the board already.
        #expect(Game(fen: "4kb2/8/8/8/5B2/8/8/2B1K3 b - - 0 1").outcome == .drawInsufficientMaterial)
        // A bishop and a knight mate on their own.
        #expect(try outcome("4k3/8/8/8/8/8/8/1NB1K3 b - - 0 1") == .timeForfeit(winner: .white))
    }

    @Test("A flag fall survives a finished game being restored")
    func restored() throws {
        var game = Game()
        for uci in ["e2e4", "e7e5"] {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }))
        }
        game.timeOut()
        let record = FinishedGame(game: game, mode: .twoPlayer)
        #expect(record.restoreGame()?.outcome == .timeForfeit(winner: .black))
    }
}

@Suite("Computer's time")
struct AITimeBudgetTests {

    @Test("A bullet game is never allowed the strongest level's full think")
    func bullet() {
        let budget = AITimeBudget.seconds(remaining: 60, increment: 0, movesPlayed: 0, levelTime: 2.6)
        #expect(budget <= 1.6)
        // Forty moves at that rate fit inside the minute.
        #expect(budget * 40 <= 60)
    }

    @Test("Plenty of time leaves the level's own allowance alone")
    func classical() {
        let budget = AITimeBudget.seconds(remaining: 1_800, increment: 20, movesPlayed: 10, levelTime: 1.4)
        #expect(budget == 1.4)
    }

    @Test("Nearly out of time, the computer moves fast but still moves")
    func scramble() {
        let budget = AITimeBudget.seconds(remaining: 1, increment: 0, movesPlayed: 60, levelTime: 2.6)
        #expect(budget < 0.25)
        #expect(budget >= 0.03)
    }

    @Test("Adaptive strengths land on the named levels at whole numbers")
    func interpolation() {
        for (index, level) in AIDifficulty.fixedLevels.enumerated() {
            #expect(AIStrength.interpolated(Double(index)) == level.strength)
        }
        let between = AIStrength.interpolated(2.5)
        #expect(between.maxDepth > AIDifficulty.medium.strength.maxDepth)
        #expect(between.maxDepth < AIDifficulty.hard.strength.maxDepth)
        #expect(between.temperature > 0)
    }
}

@Suite("Timed game", .serialized)
@MainActor
struct TimedGameTests {

    /// A clock the test moves by hand.
    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func withScratchStore(_ body: () throws -> Void) rethrows {
        let suiteName = "chessTests.TimedGameTests"
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
        }
        try body()
    }

    private func play(_ model: GameViewModel, _ uci: String) throws {
        let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        #expect(model.game.lastMove == move)
    }

    @Test("The clock starts with the first move and charges each side its own time")
    func charging() throws {
        try withScratchStore {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(3, plus: 2)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            time.now += 30
            try play(model, "e2e4")
            #expect(model.clockRemaining(for: .white) == 180, "the first move is not charged")
            time.now += 12
            #expect(model.clockRemaining(for: .black) == 168)
            try play(model, "e7e5")
            #expect(model.clockRemaining(for: .black) == 170)
            #expect(model.moveTimes == [30, 12])
        }
    }

    @Test("On the clock there is no undo and no hint")
    func noTakebacks() throws {
        try withScratchStore {
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white), settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(5, plus: 0))
            )
            defer { model.teardown() }
            #expect(!model.canRequestHint)
            try play(model, "e2e4")
            #expect(!model.canUndo)
        }
    }

    @Test("A paused game takes no moves, and a resumed one goes on where it was")
    func pausing() throws {
        try withScratchStore {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            time.now += 5
            model.pause()
            #expect(model.isPaused)
            time.now += 600
            #expect(!model.isInteractive(color: .black))
            model.resume()
            #expect(model.clockRemaining(for: .black) == 55)
            try play(model, "e7e5")
        }
    }

    @Test("Continuing a timed game brings the clock back held, with its time")
    func continuing() throws {
        try withScratchStore {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            try play(model, "e2e4")
            time.now += 20
            model.teardown()

            let saved = try #require(SavedGame.load())
            let restored = GameViewModel(
                mode: saved.mode, settings: AppSettings(), restoredGame: saved.restoreGame(),
                options: saved.options ?? .standard, restoredClock: saved.clock,
                restoredMoveTimes: saved.moveTimes, timeSource: { time.now }
            )
            defer { restored.teardown() }
            #expect(restored.isPaused)
            #expect(restored.clockRemaining(for: .black) == 40)
            time.now += 100
            #expect(restored.clockRemaining(for: .black) == 40, "held until the player resumes")
        }
    }

    @Test("A queued premove is played the moment the computer replies")
    func premove() async throws {
        try await withScratchStoreAsync {
            let settings = AppSettings()
            settings.premovesEnabled = true
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white), settings: settings
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            #expect(model.aiThinking)
            // While the computer thinks, the player lines up Nf3.
            model.handleTap(on: Square(algebraic: "g1")!)
            model.handleTap(on: Square(algebraic: "f3")!)
            #expect(model.premove?.uci == "g1f3")
            // Up to twenty seconds: the beginner answers in well under one,
            // but a simulator running every suite at once can be slow to
            // schedule it, and the loop stops the moment the reply is in.
            for _ in 0..<400 where model.game.history.count < 3 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(model.game.history.count >= 3)
            #expect(model.game.history[2].move.uci == "g1f3")
            #expect(model.premove == nil)
        }
    }

    private func withScratchStoreAsync(_ body: () async throws -> Void) async rethrows {
        await ScratchStoreLock.acquire()
        defer { ScratchStoreLock.release() }
        let suiteName = "chessTests.TimedGameTests.async"
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
        }
        try await body()
    }
}
