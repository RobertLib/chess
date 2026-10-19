//
//  SessionFixesTests.swift
//  chessTests
//
//  One test per fault found in what a session leaves behind, each written to
//  fail on the code as it was: a game that ended under the pause cover and
//  kept it, saved games lost to a clock or a replay this build could not
//  manage, an archive written on the main actor, and an import that filed
//  the same games again every time a file was read in.
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
/// stays swapped in across the wait, as in the premove tests: the model saves
/// the game, and files it in the archive, the moment the computer's reply
/// lands, and both belong in the scratch store, not the real one.
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

private func setAside(forKey key: String) -> Data? {
    LocalStore.setAsideCopy(forKey: key)
}

// MARK: - The hold

@Suite("Session fixes: the hold", .serialized)
@MainActor
struct HoldSessionFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    @Test("Resigning a held game takes the cover down, and Resume cannot start the clock again")
    func resignWhileHeld() throws {
        try withScratchStore("sessionResignHeld") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            time.now += 4
            // The player opens Resign, the app goes away and comes back: the
            // game is held under the dialog, and Resign is answered there.
            model.pause()
            #expect(model.isPaused)
            model.resign()
            #expect(model.game.outcome == .resigned(winner: .white))
            #expect(!model.isPaused, "the pause cover stayed over a finished game")

            let left = model.clockRemaining(for: .black)
            let times = model.moveTimes
            model.resume()
            time.now += 30
            #expect(!model.isClockRunning, "Resume started the clock of a finished game")
            #expect(model.clockRemaining(for: .black) == left)
            #expect(model.moveTimes == times)
        }
    }

    @Test("A computer's reply that ends the game under the cover takes the cover down")
    func gameEndedUnderTheCover() async throws {
        try await withScratchStoreAsync("sessionMateHeld") {
            let time = FakeTime()
            // Black, the computer, is on move with mate in one: …g2#.
            let game = Game(fen: "8/8/8/8/8/6p1/5k1P/7K b - - 0 1")
            var clock = ChessClock(control: .minutes(5, plus: 0))
            clock.start(.black, at: time.now)
            let model = GameViewModel(
                mode: .vsAI(difficulty: .hard, playerColor: .white), settings: AppSettings(),
                restoredGame: game, options: GameOptions(timeControl: .minutes(5, plus: 0)),
                restoredClock: clock, timeSource: { time.now }
            )
            defer { model.teardown() }
            #expect(model.aiThinking)
            // The player switches away while the computer thinks.
            model.sceneDidDeactivate()
            #expect(model.isPaused)

            try await waitFor { model.game.outcome.isGameOver }
            #expect(model.game.outcome.isGameOver, "the computer did not find the mate")
            #expect(!model.isPaused, "the pause cover stayed over a finished game")

            model.sceneDidActivate()
            model.resume()
            #expect(!model.isClockRunning)
        }
    }
}

// MARK: - Saved games

@Suite("Session fixes: saved games", .serialized)
@MainActor
struct SavedGameSessionFixesTests {

    private func savedGame(moves: [String], timed: Bool) -> SavedGame {
        let control = TimeControl.minutes(3, plus: 2)
        var clock = ChessClock(control: control)
        clock.start(.black, at: 10)
        clock.pause(at: 14)
        return SavedGame(
            mode: .vsAI(difficulty: .easy, playerColor: .white),
            initialFEN: Board.startFEN, moveUCIs: moves, savedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            options: GameOptions(timeControl: timed ? control : nil),
            clock: timed ? clock : nil, moveTimes: Array(repeating: 1, count: moves.count)
        )
    }

    @Test("A saved game whose clock does not read goes on untimed, moves and all")
    func unreadableClock() throws {
        try withScratchStore("sessionSavedClock") {
            let saved = savedGame(moves: ["e2e4", "e7e5", "g1f3"], timed: true)
            var object = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
            )
            var clock = try #require(object["clock"] as? [String: Any])
            clock["control"] = ["initial": "three minutes"]
            object["clock"] = clock
            let stored = try JSONSerialization.data(withJSONObject: object)
            LocalStore.defaults.set(stored, forKey: "savedGame")

            let read = try #require(SavedGame.load(), "the whole game was lost with its clock")
            #expect(read.clock == nil)
            #expect(read.options?.timeControl == nil, "a timed game with no clock left behind")
            #expect(read.moveUCIs == saved.moveUCIs)
            #expect(read.moveTimes == saved.moveTimes)
            #expect(setAside(forKey: "savedGame") == nil, "a game that read was set aside")

            let game = try #require(read.restoreForContinue())
            let model = GameViewModel(
                mode: read.mode, settings: AppSettings(), restoredGame: game,
                options: read.options ?? .standard, restoredClock: read.clock,
                restoredMoveTimes: read.moveTimes
            )
            defer { model.teardown() }
            #expect(!model.isTimed)
            #expect(model.game.history.count == 3)
        }
    }

    @Test("A clock that reads still comes back with its game")
    func readableClock() throws {
        try withScratchStore("sessionSavedClockReads") {
            let saved = savedGame(moves: ["e2e4"], timed: true)
            saved.save()
            let read = try #require(SavedGame.load())
            #expect(read.clock == saved.clock)
            #expect(read.options?.timeControl == .minutes(3, plus: 2))
        }
    }

    @Test("A saved game that no longer replays is kept aside before Continue drops it")
    func unreplayableSavedGame() throws {
        try withScratchStore("sessionSavedReplay") {
            let saved = savedGame(moves: ["e2e4", "e7e6", "e4e6"], timed: false)
            saved.save()
            let stored = try #require(LocalStore.defaults.data(forKey: "savedGame"))

            let read = try #require(SavedGame.load())
            #expect(read.restoreForContinue() == nil)
            #expect(SavedGame.load() == nil, "Continue still offers a game it cannot open")
            #expect(setAside(forKey: "savedGame") == stored, "dropped without a copy")
        }
    }

    @Test("The game 1.0 kept is not dropped before it has been replayed")
    func migrationKeepsWhatItCannotReplay() throws {
        try withScratchStore("sessionMigration") {
            var finished = FinishedGame(game: try played(["e2e4", "e7e5"]), mode: .twoPlayer)
            finished.moveUCIs = ["e2e4", "e7e5", "e1e3"]
            let stored = try JSONEncoder().encode(finished)
            LocalStore.defaults.set(stored, forKey: "finishedGame")

            FinishedGame.migrateToArchive()
            #expect(GameArchive.shared.records.isEmpty)
            #expect(FinishedGame.load() == nil, "the key is tried again at every launch")
            #expect(setAside(forKey: "finishedGame") == stored, "the game was lost for good")

            // Nor is one that does not decode at all, whose copy takes the
            // place of the one before.
            let garbage = Data("{ no game".utf8)
            LocalStore.defaults.set(garbage, forKey: "finishedGame")
            FinishedGame.migrateToArchive()
            #expect(setAside(forKey: "finishedGame") == garbage)
            #expect(LocalStore.defaults.data(forKey: "finishedGame") == nil)
        }
    }
}

// MARK: - Archive writes

@Suite("Session fixes: archive writes", .serialized)
@MainActor
struct ArchiveWriteSessionFixesTests {

    private func record(_ ucis: [String], at seconds: TimeInterval) throws -> GameRecord {
        GameRecord(
            game: try played(ucis), mode: .vsAI(difficulty: .medium, playerColor: .white),
            options: .standard, moveTimes: Array(repeating: 1.25, count: ucis.count), finalClock: nil,
            finishedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )
    }

    private func stored() throws -> [GameRecord] {
        let data = try #require(LocalStore.files.read("gameArchive"), "nothing was written")
        return try JSONDecoder().decode([GameRecord].self, from: data)
    }

    @Test("Saves reach the store in the order they were made, the latest last")
    func writesLandInOrder() throws {
        try withScratchStore("sessionArchiveOrder") {
            let archive = GameArchive.shared
            let games = try (0..<6).map { try record(["e2e4", "e7e5"], at: 800_000_000 + Double($0)) }
            for game in games { archive.add(game) }
            archive.setAccuracy([81.5, 64], for: games[2].id)
            archive.remove(games[4].id)
            archive.add(try record(["d2d4"], at: 800_000_100))

            LocalStore.flush()
            let written = try stored()
            #expect(written == archive.records)
            #expect(written.count == 6)
            #expect(written.first?.moveUCIs == ["d2d4"])
            #expect(!written.contains { $0.id == games[4].id }, "a removed game came back")
            #expect(written.first { $0.id == games[2].id }?.accuracy == [81.5, 64],
                    "a changed game was written as it was before")
        }
    }

    @Test("A store swapped out and back again reads with its last save in it")
    func swappedStoreReadsTheLatest() throws {
        try withScratchStore("sessionArchiveSwap") {
            let archive = GameArchive.shared
            let first = try record(["e2e4"], at: 800_000_000)
            let second = try record(["c2c4"], at: 800_000_001)
            archive.add(first)
            archive.add(second)

            let own = LocalStore.defaults
            let elsewhere = try #require(UserDefaults(suiteName: "chessTests.sessionArchiveSwapOther"))
            elsewhere.removePersistentDomain(forName: "chessTests.sessionArchiveSwapOther")
            defer { elsewhere.removePersistentDomain(forName: "chessTests.sessionArchiveSwapOther") }
            LocalStore.defaults = elsewhere
            #expect(archive.records.isEmpty)
            LocalStore.defaults = own
            // Read back from the store itself, not from memory: the mirror
            // went with the swap.
            #expect(archive.records.map(\.id) == [second.id, first.id])
        }
    }
}

// MARK: - Import

@Suite("Session fixes: import", .serialized)
@MainActor
struct ImportSessionFixesTests {

    /// Two games between the same players with no date, told apart only by
    /// their moves.
    private let twoGames = """
        [Event "Club night"]
        [White "Ann"]
        [Black "Ben"]
        [Result "1-0"]

        1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0

        [Event "Club night"]
        [White "Ann"]
        [Black "Ben"]
        [Result "0-1"]

        1. f3 e5 2. g4 Qh4# 0-1
        """

    @Test("A file read in twice files its games once")
    func sameFileTwice() throws {
        try withScratchStore("sessionImportTwice") {
            let archive = GameArchive.shared
            let first = archive.importGames(try MyGamesView.importedRecords(fromPGN: twoGames))
            #expect(first == GameArchive.ImportSummary(added: 2, duplicates: 0, kept: 2),
                    "two games between the same players on no date were taken for one")
            let second = archive.importGames(try MyGamesView.importedRecords(fromPGN: twoGames))
            #expect(second == GameArchive.ImportSummary(added: 0, duplicates: 2, kept: 0))
            #expect(archive.records.count == 2, "the same games were filed again")
        }
    }

    @Test("The same game twice in one import is filed once")
    func repeatsWithinOneImport() throws {
        try withScratchStore("sessionImportRepeat") {
            let games = try MyGamesView.importedRecords(fromPGN: twoGames)
            let summary = GameArchive.shared.importGames(games + games)
            #expect(summary == GameArchive.ImportSummary(added: 2, duplicates: 2, kept: 2))
            #expect(GameArchive.shared.records.count == 2)
        }
    }

    @Test("The same moves by other players, or at another event, are another game")
    func sameMovesOtherGame() throws {
        try withScratchStore("sessionImportOther") {
            let archive = GameArchive.shared
            archive.importGames(try MyGamesView.importedRecords(fromPGN: twoGames))
            let others = twoGames.replacingOccurrences(of: "Ben", with: "Cyril")
            let event = twoGames.replacingOccurrences(of: "Club night", with: "Club final")
            #expect(archive.importGames(try MyGamesView.importedRecords(fromPGN: others)).added == 2)
            #expect(archive.importGames(try MyGamesView.importedRecords(fromPGN: event)).added == 2)
            #expect(archive.records.count == 6)
        }
    }

    @Test("A game exported from My Games and read back in is already there")
    func exportedAndReadBack() throws {
        try withScratchStore("sessionImportRoundTrip") {
            let archive = GameArchive.shared
            let own = GameRecord(
                game: try played(["f2f3", "e7e5", "g2g4", "d8h4"]),
                mode: .vsAI(difficulty: .hard, playerColor: .white),
                options: .standard, moveTimes: [1, 2, 3, 4], finalClock: nil
            )
            archive.add(own)
            var imported = try MyGamesView.importedRecords(fromPGN: twoGames)
            archive.importGames(imported)
            #expect(archive.records.count == 3)

            let exported = PGN.export(archive.records.compactMap { $0.pgn() })
            imported = try MyGamesView.importedRecords(fromPGN: exported)
            #expect(imported.count == 3)
            let summary = archive.importGames(imported)
            #expect(summary == GameArchive.ImportSummary(added: 0, duplicates: 3, kept: 0))
            #expect(archive.records.count == 3)
        }
    }

    @Test("The import message counts what went in, what was there already and what could not be read")
    func importMessage() {
        let nothing = GameArchive.ImportSummary()
        #expect(MyGamesView.importMessage(for: nothing, unreadableFiles: 1, of: 1)
                == String(localized: "No games could be read from that file."))
        #expect(MyGamesView.importMessage(for: nothing, unreadableFiles: 2, of: 2)
                == String(localized: "No games could be read from those files."))

        let mixed = GameArchive.ImportSummary(added: 3, duplicates: 2, kept: 3)
        let message = MyGamesView.importMessage(for: mixed, unreadableFiles: 1, of: 3)
        #expect(message == [
            String(localized: "Imported \(3) games."),
            String(localized: "Skipped \(2) games already in My Games."),
            String(localized: "\(1) files could not be read."),
        ].joined(separator: " "))

        let allThere = GameArchive.ImportSummary(added: 0, duplicates: 4, kept: 0)
        #expect(MyGamesView.importMessage(for: allThere, unreadableFiles: 0, of: 1).contains(
            String(localized: "Skipped \(4) games already in My Games.")
        ))
    }
}
