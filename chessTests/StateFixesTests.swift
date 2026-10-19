//
//  StateFixesTests.swift
//  chessTests
//
//  One test per fault found in the state the app keeps and the timing around
//  it, each written to fail on the code as it was: a clock started behind the
//  player's back, a store wiped by one entry it could not read, puzzles
//  skipped for nothing, day numbers that followed the calendar setting, a
//  review cache written after every position and a replay that outlived its
//  review.
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

/// Waits for `condition`, a twentieth of a second at a time. Counted in
/// turns rather than against a clock, the way the premove test waits: a
/// simulator running every suite at once can keep the main actor busy for
/// seconds together, and that is no reason to give up.
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// A scratch store for a test that has to wait on a timer. It is swapped in
/// only for the synchronous stretches handed to it, never across an `await`:
/// the suites run side by side, and a store swapped while its test was
/// suspended is one the next test to resume writes into instead of its own.
/// The model under test must touch no store while it is being waited on.
@MainActor
private struct ScratchStore {
    let suiteName: String
    let defaults: UserDefaults
    /// The files that come with `defaults` each time it is swapped in.
    let files: FileStore

    init(_ name: String) {
        suiteName = "chessTests.\(name)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "soundsEnabled")
        defaults.set(false, forKey: "hapticsEnabled")
        files = FileStore.paired(with: defaults)
    }

    @discardableResult
    func callAsFunction<Result>(_ body: () throws -> Result) rethrows -> Result {
        let store = LocalStore.defaults
        LocalStore.defaults = defaults
        let sounds = SoundManager.shared.isEnabled
        let haptics = Haptics.isEnabled
        SoundManager.shared.isEnabled = false
        Haptics.isEnabled = false
        defer {
            SoundManager.shared.isEnabled = sounds
            Haptics.isEnabled = haptics
            LocalStore.defaults = store
            Achievements.shared.justUnlocked = []
        }
        return try body()
    }

    func discard() {
        defaults.removePersistentDomain(forName: suiteName)
        files.discard()
    }
}

// MARK: - The clock

/// The clock starts with the first move on the board, whoever plays it. Here
/// a person plays it, synchronously, standing in for the computer's opening
/// move — which reaches the clock by the same path, but only after a search
/// the test would have to wait on with the store swapped.
@Suite("State fixes: the clock", .serialized)
@MainActor
struct ClockStateFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func play(_ model: GameViewModel, _ uci: String) throws {
        let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        #expect(model.game.lastMove == move)
    }

    @Test("A clock started while the app is covered starts held")
    func clockStartedWhileCovered() throws {
        try withScratchStore("stateCoveredStart") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            // A call comes in before the first move, and the move lands
            // while it lasts.
            model.sceneDidDeactivate()
            time.now += 300
            try play(model, "e2e4")
            #expect(model.isPaused, "the clock started running with nobody there")
            #expect(!model.isClockRunning)
            #expect(model.moveTimes == [0], "the time away was counted as thinking")

            // Ten minutes later the player is back: the game waits for them.
            time.now += 600
            model.sceneDidActivate()
            #expect(model.isPaused)
            #expect(model.clockRemaining(for: .black) == 60)
            model.resume()
            time.now += 5
            #expect(model.clockRemaining(for: .black) == 55)
        }
    }

    @Test("Against the computer, a clock started held keeps the computer waiting")
    func computerWaitsForHeldClock() throws {
        try withScratchStore("stateCoveredComputer") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white), settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            model.sceneDidDeactivate()
            try play(model, "e2e4")
            #expect(model.isPaused)
            #expect(!model.aiThinking, "the computer went on thinking on a held clock")
            time.now += 600
            #expect(model.clockRemaining(for: .black) == 60)
            #expect(model.clockRemaining(for: .white) == 60)
        }
    }

    @Test("A clock started under the daily puzzle starts held, even after the app comes back")
    func clockStartedUnderAPage() throws {
        try withScratchStore("stateCoveredByPage") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            model.coverDidAppear()
            // The app goes away and comes back with the puzzle still up: the
            // scene is active again, the board is not.
            model.sceneDidDeactivate()
            model.sceneDidActivate()
            try play(model, "e2e4")
            #expect(model.isPaused, "the clock ran under the puzzle")
            time.now += 120
            model.coverDidDisappear()
            #expect(model.isPaused)
            #expect(model.clockRemaining(for: .black) == 60)
        }
    }

    @Test("A first move with the app in front starts the clock running, as before")
    func clockStartedInFront() throws {
        try withScratchStore("stateActiveStart") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            // Covered and back again before the first move: nothing to hold.
            model.sceneDidDeactivate()
            model.sceneDidActivate()
            try play(model, "e2e4")
            #expect(!model.isPaused)
            #expect(model.isClockRunning)
            time.now += 5
            #expect(model.clockRemaining(for: .black) == 55)
        }
    }
}

// MARK: - Stores

/// What 1.0.1 wrote, produced by its own encoder before any of these fixes:
/// two games (one against the computer on the clock, ended in mate and
/// reviewed; one imported, with a Bronstein clock, time odds and three-check
/// rules), two mistakes and the opening trainer's progress.
private enum Fixtures {
    static let archive = #"""
        [{"accuracy":[null,92.5],"options":{"variant":"standard","adaptiveLevel":2.25,"timeControl":{"initial":180,"bonus":2,"bonusKind":"increment"},"tabletop":false,"start":{"standard":{}}},"moveUCIs":["f2f3","e7e5","g2g4","d8h4"],"outcome":{"checkmate":{"winner":1}},"id":"11111111-2222-3333-4444-555555555555","mode":{"vsAI":{"playerColor":1,"difficulty":"adaptive"}},"source":"played","moveTimes":[1.5,2,0.5,3],"finishedAt":800000000,"initialFEN":"rnbqkbnr\/pppppppp\/8\/8\/8\/8\/PPPPPPPP\/RNBQKBNR w KQkq - 0 1","finalClock":[170.5,175]},{"options":{"variant":"threeCheck","tabletop":true,"start":{"standard":{}},"timeControl":{"bonus":5,"initialBlack":240,"initial":300,"bonusKind":"bronstein"}},"moveUCIs":["e2e4","e7e5"],"outcome":{"resigned":{"winner":1}},"id":"66666666-7777-8888-9999-AAAAAAAAAAAA","mode":{"twoPlayer":{}},"source":"imported","moveTimes":[],"finishedAt":790000000,"initialFEN":"rnbqkbnr\/pppppppp\/8\/8\/8\/8\/PPPPPPPP\/RNBQKBNR w KQkq - 0 1","tags":{"Black":"Ben","White":"Ann"}}]
        """#
    static let mistakes = #"""
        [{"bestUCI":"a1a8","setupUCI":"h8g8","attempts":2,"fixed":true,"playedSAN":"Kf2","foundAt":780000000,"id":"BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF","quality":"blunder","fen":"6k1\/5ppp\/8\/8\/8\/8\/8\/R5K1 w - - 0 1"},{"bestUCI":"e2e4","attempts":0,"fixed":false,"playedSAN":"a3","foundAt":781000000,"id":"01234567-89AB-CDEF-0123-456789ABCDEF","quality":"miss","fen":"rnbqkbnr\/pppppppp\/8\/8\/8\/8\/PPPPPPPP\/RNBQKBNR w KQkq - 0 1"}]
        """#
    static let openings = #"""
        {"results":{"d4 d5 c4":[1,0],"e4 e5 Nf3 Nc6 Bb5":[3,1]}}
        """#

    /// The values the fixtures were written from.
    static func records() throws -> [GameRecord] {
        var timed = GameRecord(
            game: try played(["f2f3", "e7e5", "g2g4", "d8h4"]),
            mode: .vsAI(difficulty: .adaptive, playerColor: .black),
            options: GameOptions(timeControl: .minutes(3, plus: 2), adaptiveLevel: 2.25),
            moveTimes: [1.5, 2, 0.5, 3], finalClock: [170.5, 175],
            finishedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        timed.id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        timed.accuracy = [nil, 92.5]
        var resigned = try played(["e2e4", "e7e5"])
        resigned.resign(.white)
        var imported = GameRecord(
            game: resigned, mode: .twoPlayer,
            options: GameOptions(
                timeControl: TimeControl(initial: 300, bonus: 5, bonusKind: .bronstein, initialBlack: 240),
                tabletop: true, variant: .threeCheck
            ),
            moveTimes: [], finalClock: nil, source: .imported,
            tags: ["White": "Ann", "Black": "Ben"],
            finishedAt: Date(timeIntervalSinceReferenceDate: 790_000_000)
        )
        imported.id = try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))
        return [timed, imported]
    }

    static func mistakeEntries() throws -> [MistakeEntry] {
        var fixed = MistakeEntry(
            id: try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")),
            fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: "h8g8", bestUCI: "a1a8",
            playedSAN: "Kf2", quality: .blunder, foundAt: Date(timeIntervalSinceReferenceDate: 780_000_000)
        )
        fixed.attempts = 2
        fixed.fixed = true
        let fresh = MistakeEntry(
            id: try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")),
            fen: Board.startFEN, setupUCI: nil, bestUCI: "e2e4",
            playedSAN: "a3", quality: .miss, foundAt: Date(timeIntervalSinceReferenceDate: 781_000_000)
        )
        return [fixed, fresh]
    }

    static let openingProgress = OpeningProgress(results: ["e4 e5 Nf3 Nc6 Bb5": [3, 1], "d4 d5 c4": [1, 0]])

    /// The same JSON, as objects, for a change to be made to before storing.
    static func objects(_ json: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    static func data(_ objects: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: objects)
    }
}

@Suite("State fixes: stores", .serialized)
@MainActor
struct StoreStateFixesTests {

    private func store(_ data: Data, forKey key: String) {
        LocalStore.defaults.set(data, forKey: key)
    }

    private func setAside(forKey key: String) -> Data? {
        LocalStore.setAsideCopy(forKey: key)
    }

    /// Whether two pieces of JSON say the same thing, whatever order their
    /// keys come in.
    private func sameJSON(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs) as AnyObject
        let right = try JSONSerialization.jsonObject(with: rhs) as AnyObject
        return left.isEqual(right)
    }

    @Test("Games, mistakes and openings written by 1.0.1 read back unchanged")
    func olderDataReadsBack() throws {
        let expectedRecords = try Fixtures.records()
        let expectedEntries = try Fixtures.mistakeEntries()
        try withScratchStore("stateFixtures") {
            store(Data(Fixtures.archive.utf8), forKey: "gameArchive")
            store(Data(Fixtures.mistakes.utf8), forKey: "mistakes")
            store(Data(Fixtures.openings.utf8), forKey: "openingProgress")

            let records = GameArchive.shared.records
            #expect(records == expectedRecords)
            let entries = MistakeStore.shared.entries
            #expect(entries == expectedEntries)
            let progress = OpeningProgressStore.shared.progress
            #expect(progress == Fixtures.openingProgress)
            for key in ["gameArchive", "mistakes", "openingProgress"] {
                #expect(setAside(forKey: key) == nil, "\(key) was set aside although it read in full")
            }

            // Written out again, each is what it was read from.
            let encoder = JSONEncoder()
            let rewritten = [
                try encoder.encode(records), try encoder.encode(entries), try encoder.encode(progress),
            ]
            let originals = [Fixtures.archive, Fixtures.mistakes, Fixtures.openings].map { Data($0.utf8) }
            for (written, original) in zip(rewritten, originals) {
                #expect(try sameJSON(written, original))
            }
        }
    }

    @Test("One game that does not read costs only itself, and is kept aside")
    func oneBadGame() throws {
        let expected = try Fixtures.records()
        try withScratchStore("stateBadGame") {
            var objects: [Any] = try Fixtures.objects(Fixtures.archive)
            objects.insert(["id": "not a game"], at: 1)
            let stored = try Fixtures.data(objects)
            store(stored, forKey: "gameArchive")

            let archive = GameArchive.shared
            #expect(archive.records == expected)
            #expect(setAside(forKey: "gameArchive") == stored)

            // The next game saved keeps the two that read; the copy aside
            // still has all three.
            archive.add(GameRecord(
                game: try played(["d2d4"]), mode: .twoPlayer, options: .standard,
                moveTimes: [], finalClock: nil
            ))
            #expect(archive.records.count == 3)
            #expect(archive.records.dropFirst().map(\.id) == expected.map(\.id))
            #expect(setAside(forKey: "gameArchive") == stored)
        }
    }

    @Test("One mistake that does not read costs only itself, and is kept aside")
    func oneBadMistake() throws {
        let expected = try Fixtures.mistakeEntries()
        try withScratchStore("stateBadMistake") {
            var objects: [Any] = try Fixtures.objects(Fixtures.mistakes)
            objects.append(["fen": 42])
            let stored = try Fixtures.data(objects)
            store(stored, forKey: "mistakes")

            #expect(MistakeStore.shared.entries == expected)
            #expect(setAside(forKey: "mistakes") == stored)
        }
    }

    @Test("A store that does not read at all is kept aside before it is written over")
    func unreadableStores() throws {
        try withScratchStore("stateUnreadable") {
            let garbage = Data("{ this is no store".utf8)
            for key in ["gameArchive", "mistakes", "openingProgress", "puzzleProgress"] {
                store(garbage, forKey: key)
            }

            #expect(GameArchive.shared.records.isEmpty)
            GameArchive.shared.add(GameRecord(
                game: try played(["d2d4"]), mode: .twoPlayer, options: .standard,
                moveTimes: [], finalClock: nil
            ))
            #expect(GameArchive.shared.records.count == 1)

            #expect(MistakeStore.shared.entries.isEmpty)
            let line = try #require(TrainingLine.all.first)
            OpeningProgressStore.shared.record(line, clean: true)
            #expect(OpeningProgressStore.shared.progress.isLearned(line))
            let puzzle = try #require(PuzzleLibrary.all.first)
            PuzzleStore.shared.recordRated(puzzle, solved: true)
            #expect(PuzzleStore.shared.progress.attempts == 1)

            for key in ["gameArchive", "mistakes", "openingProgress", "puzzleProgress"] {
                #expect(setAside(forKey: key) == garbage, "\(key) was written over without a copy")
            }
        }
    }

    @Test("A field with an obvious default may be missing, and a clock may not read")
    func missingFields() throws {
        try withScratchStore("stateMissingFields") {
            var records = try Fixtures.objects(Fixtures.archive)
            records[0]["moveTimes"] = nil
            records[0]["source"] = nil
            var options = try #require(records[0]["options"] as? [String: Any])
            options["timeControl"] = ["initial": "three minutes"]
            records[0]["options"] = options
            records[1]["options"] = nil
            store(try Fixtures.data(records), forKey: "gameArchive")

            let read = GameArchive.shared.records
            try #require(read.count == 2)
            #expect(read[0].moveTimes.isEmpty)
            #expect(read[0].source == .played)
            #expect(read[0].options.timeControl == nil, "an unreadable clock is no clock")
            #expect(read[0].options.adaptiveLevel == 2.25, "the rest of the options were lost with it")
            #expect(read[0].restoreGame()?.outcome == .checkmate(winner: .black))
            #expect(read[1].options == .standard)
            #expect(read[1].source == .imported)
            #expect(setAside(forKey: "gameArchive") == nil)

            var mistakes = try Fixtures.objects(Fixtures.mistakes)
            mistakes[0]["attempts"] = nil
            mistakes[0]["fixed"] = nil
            mistakes[0]["quality"] = "catastrophe"
            store(try Fixtures.data(mistakes), forKey: "mistakes")

            let entries = MistakeStore.shared.entries
            try #require(entries.count == 2)
            #expect(entries[0].attempts == 0)
            #expect(!entries[0].fixed)
            #expect(entries[0].quality == .mistake)
            #expect(entries[0].bestUCI == "a1a8")
        }
    }

    @Test("A time control or a clock missing a field it can do without still reads")
    func lenientClocks() throws {
        let control = try JSONDecoder().decode(TimeControl.self, from: Data(#"{"initial":180,"bonus":2}"#.utf8))
        #expect(control == .minutes(3, plus: 2))
        let future = try JSONDecoder().decode(
            TimeControl.self, from: Data(#"{"initial":300,"bonus":3,"bonusKind":"hourglass"}"#.utf8)
        )
        #expect(future.bonusKind == .increment)

        // Written by 1.0.1, then read back: nothing changes.
        var clock = ChessClock(control: .minutes(3, plus: 2))
        clock.start(.white, at: 10)
        clock.press(at: 14)
        clock.pause(at: 20)
        let written = try JSONEncoder().encode(clock)
        let reread = try JSONDecoder().decode(ChessClock.self, from: written)
        #expect(reread == clock)

        var object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        object["moves"] = nil
        object["usedThisTurn"] = nil
        let sparse = try JSONDecoder().decode(ChessClock.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(sparse.remaining(for: .white, at: 0) == clock.remaining(for: .white, at: 0))
        #expect(sparse.moveCount(for: .white) == 0)

        object["committed"] = [180]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChessClock.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("An opening entry that does not read costs only its own line")
    func badOpeningEntry() {
        withScratchStore("stateBadOpening") {
            store(Data(#"{"results":{"good":[2,1],"short":[1],"wrong":"x"}}"#.utf8), forKey: "openingProgress")
            let progress = OpeningProgressStore.shared.progress
            #expect(progress.results == ["good": [2, 1]])
            #expect(progress.learnedCount == 1)
        }
    }
}

// MARK: - Puzzles

/// The puzzle model touches the store only from the calls a test makes —
/// the opponent's moves it plays on a timer do not — so these tests hold
/// their scratch store for those calls alone and wait with it put away.
@Suite("State fixes: puzzles", .serialized)
@MainActor
struct PuzzleStateFixesTests {

    /// Plays the rest of the solution the way a player would, a move at a
    /// time, waiting for each of the opponent's replies.
    private func solve(_ model: PuzzleSessionModel, in scratch: ScratchStore) async throws {
        for _ in 0..<20 {
            try await waitFor { model.phase == .playerToMove || model.phase == .solved }
            if model.phase == .solved { return }
            try scratch {
                try #require(model.phase == .playerToMove)
                let move = try #require(model.attempt?.expectedMove)
                model.select(move.from)
                model.attemptMove(from: move.from, to: move.to)
                if let promotion = move.promotion, model.hasPendingPromotion {
                    model.completePromotion(with: promotion)
                }
            }
        }
        #expect(model.phase == .solved, "the solution did not solve the puzzle")
    }

    @Test("Next on a rated puzzle that is not yet decided counts as a miss")
    func nextIsAMiss() async throws {
        let scratch = ScratchStore("stateNextIsAMiss")
        defer { scratch.discard() }
        let model = scratch { PuzzleSessionModel(kind: .rated(theme: nil), settings: AppSettings()) }
        // Leaving an undecided rated puzzle records it, so even the last
        // teardown has to happen against the scratch store.
        defer { scratch { model.teardown() } }

        // Before the opponent's move is in, the puzzle has not been put to
        // the player yet.
        scratch {
            #expect(model.phase == .setup)
            model.loadNext()
            #expect(PuzzleStore.shared.progress.attempts == 0)
        }

        try await waitFor { model.phase == .playerToMove }
        try scratch {
            let skipped = try #require(model.attempt?.puzzle)
            model.loadNext()
            let progress = PuzzleStore.shared.progress
            #expect(progress.attempts == 1, "skipped for nothing")
            #expect(progress.solved == 0)
            #expect(progress.rating < PuzzleRating.initial)
            #expect(progress.seen.contains(skipped.id), "a skipped puzzle can come round again")
            #expect(model.attempt?.puzzle.id != skipped.id)
        }

        // One already decided costs nothing more to leave.
        try await waitFor { model.phase == .playerToMove }
        scratch {
            model.showSolution()
            #expect(PuzzleStore.shared.progress.attempts == 2)
            model.loadNext()
            #expect(PuzzleStore.shared.progress.attempts == 2)
        }
    }

    @Test("Closing the page on a rated puzzle that is not yet decided counts as a miss")
    func closingIsAMiss() async throws {
        let scratch = ScratchStore("stateCloseIsAMiss")
        defer { scratch.discard() }
        let model = scratch { PuzzleSessionModel(kind: .rated(theme: nil), settings: AppSettings()) }

        try await waitFor { model.phase == .playerToMove }
        try scratch {
            let left = try #require(model.attempt?.puzzle)
            model.teardown()
            let progress = PuzzleStore.shared.progress
            #expect(progress.attempts == 1, "closed for nothing")
            #expect(progress.rating < PuzzleRating.initial)
            #expect(progress.seen.contains(left.id))
            // Closing twice — the button, then the page going away — is one miss.
            model.teardown()
            #expect(PuzzleStore.shared.progress.attempts == 1)
        }
    }

    @Test("Retry keeps a puzzle rated until its result is in")
    func retryBeforeTheResult() async throws {
        let scratch = ScratchStore("stateRetryRated")
        defer { scratch.discard() }
        let model = scratch { PuzzleSessionModel(kind: .rated(theme: nil), settings: AppSettings()) }
        // Leaving an undecided rated puzzle records it, so even the last
        // teardown has to happen against the scratch store.
        defer { scratch { model.teardown() } }

        try await waitFor { model.phase == .playerToMove }
        let puzzle = try #require(model.attempt?.puzzle)
        scratch { model.retry() }
        #expect(model.attempt?.puzzle.id == puzzle.id)
        try await solve(model, in: scratch)
        scratch {
            let progress = PuzzleStore.shared.progress
            #expect(progress.attempts == 1, "the retried puzzle was not rated")
            #expect(progress.solved == 1, "a clean solve after a retry was counted as a miss")
            #expect(progress.rating > PuzzleRating.initial)
        }

        // Once it is in, a retry is practice and counts for nothing.
        scratch { model.retry() }
        try await solve(model, in: scratch)
        scratch {
            let progress = PuzzleStore.shared.progress
            #expect(progress.attempts == 1)
            #expect(progress.solved == 1)
        }
    }
}

// MARK: - Daily puzzle days

@Suite("State fixes: daily puzzle days", .serialized)
@MainActor
struct DailyDayStateFixesTests {

    @Test("Day numbers are Gregorian whatever calendar the device is set to")
    func dayNumbersIgnoreTheCalendar() throws {
        let prague = try #require(TimeZone(identifier: "Europe/Prague"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = prague
        let firstDay = try #require(gregorian.date(from: DateComponents(year: 2024, month: 1, day: 1, minute: 30)))
        let morning = try #require(gregorian.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7)))
        // The numbers a Gregorian device has always had.
        #expect(PuzzleLibrary.dayNumber(for: firstDay, calendar: gregorian) == 0)
        #expect(PuzzleLibrary.dayNumber(for: morning, calendar: gregorian) == 1023)

        let daily = try #require(PuzzleLibrary.daily(for: morning, calendar: gregorian))
        for identifier: Calendar.Identifier in [.buddhist, .japanese, .islamicUmmAlQura, .hebrew] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = prague
            #expect(PuzzleLibrary.dayNumber(for: morning, calendar: calendar) == 1023, "\(identifier)")
            #expect(PuzzleLibrary.daily(for: morning, calendar: calendar)?.id == daily.id, "\(identifier)")
        }
    }

    @Test("The day still turns at local midnight")
    func dayFollowsTheTimeZone() throws {
        // 20:00 in New York is already 09:00 the next morning in Tokyo.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var tokyo = Calendar(identifier: .japanese)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let evening = try #require(newYork.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20)))
        #expect(PuzzleLibrary.dayNumber(for: evening, calendar: newYork) == 1023)
        #expect(PuzzleLibrary.dayNumber(for: evening, calendar: tokyo) == 1024)
    }

    @Test("A last day counted under another calendar does not stop the streak for good")
    func staleLastDay() {
        withScratchStore("stateStaleDaily") {
            let store = PuzzleStore.shared
            // Roughly where the Buddhist calendar's "2024" put October 2026.
            store.recordDailySolved(day: 199_000)
            #expect(store.progress.currentDailyStreak(today: 1023) == 0)
            store.recordDailySolved(day: 1023)
            #expect(store.progress.dailyLastSolved == 1023)
            #expect(store.progress.dailyStreak == 1)
            #expect(store.isDailySolved(day: 1023))
            store.recordDailySolved(day: 1024)
            #expect(store.progress.dailyStreak == 2)
            #expect(store.progress.currentDailyStreak(today: 1024) == 2)
        }
    }
}

// MARK: - Review

@Suite("State fixes: review")
@MainActor
struct ReviewStateFixesTests {

    @Test("Closing the review stops a replay, flag and all")
    func closingStopsTheReplay() async throws {
        let model = GameReviewModel(game: try played(["e2e4", "e7e5", "g1f3", "b8c6"]), mode: .twoPlayer)
        model.goToStart()
        model.toggleAutoplay()
        #expect(model.isAutoplaying)
        try await waitFor { model.plyIndex >= 1 }
        let ply = model.plyIndex
        model.teardown()
        #expect(!model.isAutoplaying, "the review still reads as playing")
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(model.plyIndex == ply, "the replay played on after the review closed")
    }
}

/// Filed under the cache's own suite rather than a suite of its own. It waits
/// on the engine with the scratch store swapped in, as that suite's tests do,
/// and the suite runs its tests one at a time — beside one of them, either
/// would swap the store out from under the other. That the finished run, and
/// one closed part way, are written is what the suite's own tests hold it to.
extension GameAnalysisCacheTests {

    @Test("A running review writes its cache every few seconds, not after every position")
    func cacheWritesAreSpacedOut() async throws {
        let game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6", "e1g1", "f8e7"])
        let settings = GameAnalyzer.Settings(maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10)
        let scratch = ScratchStore("stateReviewCache")
        defer { scratch.discard() }
        await ScratchStoreLock.acquire()
        defer { ScratchStoreLock.release() }
        let store = LocalStore.defaults
        LocalStore.defaults = scratch.defaults
        defer { LocalStore.defaults = store }

        // Time stands still, so no interval is ever up while it runs.
        let model = GameReviewModel(game: game, mode: .twoPlayer, timeSource: { 1_000 })
        defer { model.teardown() }
        model.startAnalysis(settings: settings)
        #expect(model.isAnalyzing)
        var writtenEarly = false
        while model.isAnalyzing {
            // Read from the scratch store itself: a test in another suite may
            // have swapped its own in for a moment.
            LocalStore.flush()
            if model.progress > 0, scratch.files.read("analysisCache") != nil {
                writtenEarly = true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!writtenEarly, "the cache was written before the interval was up")
        #expect(model.progress == 1)
    }
}
