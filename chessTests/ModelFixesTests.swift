//
//  ModelFixesTests.swift
//  chessTests
//
//  One test per fault found in the models around a game, each written to
//  fail on the code as it was: an achievement earned a game late, a premove
//  that outlived the setting allowing it and one played under the pause
//  cover, stores that read as empty when one entry would not decode, a
//  puzzle that would not set up, and an accuracy pair read past its end.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String]) throws -> Game {
    var game = Game()
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

@MainActor
private func play(_ model: GameViewModel, _ uci: String) throws {
    let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
    model.handleTap(on: move.from)
    model.handleTap(on: move.to)
    #expect(model.game.lastMove == move)
}

/// Waits for `condition`, a twentieth of a second at a time, counted in
/// turns rather than against a clock: a simulator running every suite at
/// once can keep the main actor busy for seconds together.
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// `withScratchStore` for a test that has to wait on the computer. The store
/// stays swapped in across the wait, as in the premove test of the timed
/// game suite: the model saves the game the moment the computer's reply
/// lands, and that save belongs in the scratch store, not the real one.
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

// MARK: - The adaptive opponent

@Suite("Model fixes: the adaptive opponent", .serialized)
@MainActor
struct AdaptiveModelFixesTests {

    /// White mates in one: Ra8, along a back rank its own pawns have shut.
    private static let mateInOne = "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1"

    @Test("The win that takes the adaptive opponent to the top earns Unstoppable")
    func topReachedOnTheWin() throws {
        try withScratchStore("modelAdaptiveTop") {
            let settings = AppSettings()
            settings.adaptiveLevel = 3.9
            // A game of the ordinary start, come back from "Continue" at the
            // mating move. Set up from that position by hand, the game would
            // not move the level at all — that says nothing about the player.
            let model = GameViewModel(
                mode: .vsAI(difficulty: .adaptive, playerColor: .white), settings: settings,
                restoredGame: Game(fen: Self.mateInOne),
                options: GameOptions(adaptiveLevel: settings.adaptiveLevel)
            )
            defer { model.teardown() }
            try play(model, "a1a8")
            #expect(model.game.outcome == .checkmate(winner: .white))
            #expect(settings.adaptiveLevel >= 3.95, "the win did not take the level to the top")
            #expect(Achievements.shared.isUnlocked(.adaptiveTop), "left for the game after")
        }
    }

    @Test("A win that stops short of the top earns no Unstoppable")
    func notYetAtTheTop() throws {
        withScratchStore("modelAdaptiveShort") {
            let settings = AppSettings()
            settings.recordAdaptiveResult(playerScore: 1)
            #expect(settings.adaptiveLevel < 3.95)
            #expect(!Achievements.shared.isUnlocked(.adaptiveTop))
        }
    }
}

// MARK: - Premoves

@Suite("Model fixes: premoves", .serialized)
@MainActor
struct PremoveModelFixesTests {

    @Test("A premove queued before premoves are switched off is not played")
    func switchedOff() async throws {
        try await withScratchStoreAsync("modelPremoveOff") {
            let settings = AppSettings()
            settings.premovesEnabled = true
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white), settings: settings
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            #expect(model.aiThinking)
            model.handleTap(on: Square(algebraic: "g1")!)
            model.handleTap(on: Square(algebraic: "f3")!)
            #expect(model.premove?.uci == "g1f3")

            // The player opens the settings mid-game and turns premoves off.
            settings.premovesEnabled = false
            try await waitFor { model.premove == nil }
            #expect(model.premove == nil, "the premove is still on the board")

            try await waitFor { !model.aiThinking }
            #expect(model.game.history.count == 2, "the premove was played with premoves off")
            #expect(model.game.sideToMove == .white)
        }
    }

    @Test("A premove waits out a pause, and is played when the game resumes")
    func heldOverAPause() async throws {
        try await withScratchStoreAsync("modelPremovePause") {
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white), settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(5, plus: 0))
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            #expect(model.aiThinking)
            model.handleTap(on: Square(algebraic: "g1")!)
            model.handleTap(on: Square(algebraic: "f3")!)
            #expect(model.premove?.uci == "g1f3")

            model.pause()
            #expect(model.isPaused)
            // The computer's reply lands under the cover, as it is meant to;
            // the player's own move is not played into a board they cannot see.
            try await waitFor { !model.aiThinking }
            #expect(model.game.history.count == 2, "the premove was played while the game was held")
            #expect(model.premove?.uci == "g1f3", "the premove was dropped by the pause")

            model.resume()
            #expect(model.game.history.count == 3)
            #expect(model.game.history.last?.move.uci == "g1f3")
            #expect(model.premove == nil)
        }
    }
}

// MARK: - Stores

@Suite("Model fixes: stores", .serialized)
@MainActor
struct StoreModelFixesTests {

    private func store(_ data: Data, forKey key: String) {
        LocalStore.defaults.set(data, forKey: key)
    }

    private func setAside(forKey key: String) -> Data? {
        LocalStore.setAsideCopy(forKey: key)
    }

    @Test("Achievements that do not read are kept aside before the next one is earned")
    func unreadableAchievements() throws {
        withScratchStore("modelAchievementsUnreadable") {
            let garbage = Data("{ these are no achievements".utf8)
            store(garbage, forKey: "achievements")

            #expect(Achievements.shared.unlocked.isEmpty)
            Achievements.shared.playedBrilliantMove()
            #expect(Achievements.shared.isUnlocked(.brilliant))
            #expect(setAside(forKey: "achievements") == garbage, "written over without a copy")
        }
    }

    @Test("One achievement that does not read costs only itself, and is kept aside")
    func oneBadAchievement() throws {
        try withScratchStore("modelAchievementsBadEntry") {
            let stored = try JSONSerialization.data(withJSONObject: [
                "firstGame": 700_000_000.0,
                "firstWin": "the day before yesterday",
                "fromALaterVersion": 700_000_100.0,
            ])
            store(stored, forKey: "achievements")

            let unlocked = Achievements.shared.unlocked
            #expect(Set(unlocked.keys) == [.firstGame])
            #expect(unlocked[.firstGame] == Date(timeIntervalSinceReferenceDate: 700_000_000))
            #expect(setAside(forKey: "achievements") == stored)

            // The next one earned keeps the one that read; the copy aside
            // still has all three.
            Achievements.shared.playedBrilliantMove()
            #expect(Achievements.shared.isUnlocked(.firstGame))
            #expect(Achievements.shared.isUnlocked(.brilliant))
            #expect(setAside(forKey: "achievements") == stored)
        }
    }

    @Test("Achievements that read in full are not set aside")
    func readableAchievements() throws {
        try withScratchStore("modelAchievementsReadable") {
            store(try JSONEncoder().encode(["brilliant": Date()]), forKey: "achievements")
            #expect(Achievements.shared.isUnlocked(.brilliant))
            #expect(setAside(forKey: "achievements") == nil)
        }
    }

    @Test("A saved game that does not read is kept aside before the next one is saved")
    func unreadableSavedGame() throws {
        withScratchStore("modelSavedGameUnreadable") {
            let unreadable = Data(#"{"mode":{"twoPlayer":{}},"initialFEN":42,"moveUCIs":[]}"#.utf8)
            store(unreadable, forKey: "savedGame")

            #expect(SavedGame.load() == nil)
            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings())
            model.teardown()
            #expect(SavedGame.load() != nil)
            #expect(setAside(forKey: "savedGame") == unreadable, "written over without a copy")
        }
    }
}

// MARK: - Puzzles

@Suite("Model fixes: puzzles", .serialized)
@MainActor
struct PuzzleModelFixesTests {

    private func mistake(fen: String) -> MistakeEntry {
        MistakeEntry(
            id: UUID(), fen: fen, setupUCI: nil, bestUCI: "e2e4",
            playedSAN: "a3", quality: .mistake, foundAt: Date()
        )
    }

    @Test("A puzzle that will not set up is skipped for the next one")
    func brokenPuzzleSkipped() throws {
        try withScratchStore("modelBrokenPuzzle") {
            let broken = mistake(fen: "not a position")
            let good = mistake(fen: Board.startFEN)
            LocalStore.defaults.set(try JSONEncoder().encode([broken, good]), forKey: "mistakes")

            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.attempt?.puzzle.id == good.id.uuidString)
            #expect(model.phase == .playerToMove)
        }
    }

    @Test("A session with nothing that sets up ends, rather than going round")
    func nothingSetsUp() throws {
        try withScratchStore("modelNothingSetsUp") {
            let entries = [mistake(fen: "not a position"), mistake(fen: "8/8/8/8/8/8/8/8 w - - 0 1")]
            LocalStore.defaults.set(try JSONEncoder().encode(entries), forKey: "mistakes")

            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.attempt == nil)
            #expect(model.phase == .empty)
        }
    }
}

// MARK: - Accuracy

@Suite("Model fixes: accuracy", .serialized)
@MainActor
struct AccuracyModelFixesTests {

    /// A long enough game against the computer, as the player with Black,
    /// whose accuracy was stored with only White's figure in it.
    private func shortPair(mode: GameMode) throws -> GameRecord {
        var record = GameRecord(
            game: try played(["f2f3", "e7e5", "g2g4", "d8h4"]), mode: mode,
            options: .standard, moveTimes: [], finalClock: nil
        )
        record.moveUCIs = Array(repeating: "e2e4", count: 40)
        record.accuracy = [95]
        return record
    }

    @Test("An accuracy pair cut short is read as no figure, not past its end")
    func shortAccuracyPair() throws {
        let asBlack = try shortPair(mode: .vsAI(difficulty: .easy, playerColor: .black))
        #expect(GameStatistics(records: [asBlack]).accuracyHistory.isEmpty)

        try withScratchStore("modelShortAccuracy") {
            Achievements.shared.gameReviewed(asBlack)
            #expect(!Achievements.shared.isUnlocked(.precision), "White's figure was taken for Black's")

            // On a shared board both sides are the player's, and White's
            // figure is there to be read.
            Achievements.shared.gameReviewed(try shortPair(mode: .twoPlayer))
            #expect(Achievements.shared.isUnlocked(.precision))
        }
    }
}
