//
//  AuditFixesTests.swift
//  chessTests
//
//  One test per fault found in the review of the screens and the models
//  behind them, each written to fail on the code as it was: a game set up
//  from a finished position that opened on a frozen board, a mistake check
//  that came back over an empty page, a Retry that made a clean fix count for
//  nothing, moves VoiceOver read out a letter at a time, a menu that forgot
//  its setup after every game and a clock face redrawn on a fixed beat.
//

import Foundation
import SwiftUI
import Testing
@testable import chess

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

// MARK: - Games that are over before they begin

@Suite("Audit fixes: finished positions", .serialized)
@MainActor
struct FinishedPositionAuditFixesTests {

    @Test("The editor will not start a game the rules already call finished")
    func editorRefusesFinishedPositions() {
        let bareKings = PositionEditorModel(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
        #expect(bareKings.problem == nil, "two bare kings are a legal position, and can be analysed")
        #expect(bareKings.playProblem(variant: .standard) != nil, "a game of two bare kings is drawn before it starts")

        let knight = PositionEditorModel(fen: "4k3/8/8/8/8/8/8/3NK3 w - - 0 1")
        #expect(knight.playProblem(variant: .standard) != nil)

        let rook = PositionEditorModel(fen: "4k3/8/8/8/8/8/8/3RK3 w - - 0 1")
        #expect(rook.playProblem(variant: .standard) == nil, "a rook is enough to play on with")

        // Black's king on d5, the hill: won already, under those rules only.
        let hill = PositionEditorModel(fen: "8/8/8/3k4/8/8/8/4K2R w - - 0 1")
        #expect(hill.playProblem(variant: .standard) == nil)
        #expect(hill.playProblem(variant: .kingOfTheHill) != nil)
        // And the side to move's own king up there, which no game can reach:
        // not even analysed, since the board under those rules refuses it.
        let mover = PositionEditorModel(fen: "8/8/8/3K4/8/8/8/4k2r w - - 0 1")
        #expect(mover.playProblem(variant: .kingOfTheHill) != nil)
        #expect(mover.analysisProblem(variant: .kingOfTheHill) != nil)
        #expect(mover.analysisProblem(variant: .standard) == nil)
    }

    @Test("A position from a PGN past fifty moves cannot be played on from the analysis board")
    func analysisBoardPastFiftyMoves() {
        // Read from PGN, a game at a halfmove clock of 100 is not over: the
        // draw is there to be claimed. A game begun from it would settle it.
        let pastFifty = AnalysisBoardModel(game: Game(fen: "8/8/4k3/8/8/4K3/8/R7 w - - 100 80", settlesClaimableDraws: false))
        defer { pastFifty.teardown() }
        #expect(!pastFifty.game.outcome.isGameOver)
        #expect(!pastFifty.canPlayFromHere)

        let shortOfIt = AnalysisBoardModel(game: Game(fen: "8/8/4k3/8/8/4K3/8/R7 w - - 99 80", settlesClaimableDraws: false))
        defer { shortOfIt.teardown() }
        #expect(shortOfIt.canPlayFromHere)
    }

    @Test("A game that starts finished shows its result rather than a frozen board")
    func finishedGameShowsItsResult() async throws {
        try await withScratchStoreAsync("auditFinishedStart") {
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(start: .custom(fen: "4k3/8/8/8/8/8/8/3NK3 w - - 0 1"))
            )
            defer { model.teardown() }
            #expect(model.game.outcome == .drawInsufficientMaterial)
            try await waitFor { model.gameOverShown }
            #expect(model.gameOverShown, "the result card never came up")
            #expect(GameArchive.shared.latest == nil, "a game without a move was filed in the archive")
        }
    }
}

// MARK: - Set-up positions

@Suite("Audit fixes: set-up positions", .serialized)
@MainActor
struct SetUpPositionAuditFixesTests {

    /// Plays e2e4 against the adaptive opponent from `start`, resigns, and
    /// says where the opponent's level went.
    private func levelAfterResigning(from start: StartPosition) throws -> Double {
        var level = 0.0
        try withScratchStore("auditAdaptiveSetUp") {
            let settings = AppSettings()
            let model = GameViewModel(
                mode: .vsAI(difficulty: .adaptive, playerColor: .white), settings: settings,
                options: GameOptions(start: start)
            )
            defer { model.teardown() }
            let move = try #require(model.game.legalMoves.first { $0.uci == "e2e4" })
            model.handleTap(on: move.from)
            model.handleTap(on: move.to)
            model.resign()
            level = settings.adaptiveLevel
        }
        return level
    }

    @Test("A game from a set-up position does not move the adaptive opponent")
    func setUpGamesLeaveTheLevelAlone() throws {
        let initial = try withScratchStoreValue { AppSettings().adaptiveLevel }
        #expect(try levelAfterResigning(from: .standard) < initial, "the control game did not move the level")
        #expect(try levelAfterResigning(from: .custom(fen: "4k3/8/8/8/8/8/4P3/3QK3 w - - 0 1")) == initial)
    }

    private func withScratchStoreValue<Value>(_ body: () -> Value) throws -> Value {
        var value: Value?
        withScratchStore("auditAdaptiveInitial") { value = body() }
        return try #require(value)
    }
}

// MARK: - Puzzles

@Suite("Audit fixes: puzzle sessions", .serialized)
@MainActor
struct PuzzleSessionAuditFixesTests {

    /// Mate in one with Ra8; the game's move was Kf2.
    private func storeMistake() throws -> MistakeEntry {
        let entry = MistakeEntry(
            id: UUID(), fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: nil, bestUCI: "a1a8",
            playedSAN: "Kf2", quality: .blunder, foundAt: Date()
        )
        MistakeStore.shared.reset()
        LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")
        return entry
    }

    private func play(_ model: PuzzleSessionModel, _ from: String, _ to: String) throws {
        let from = try #require(Square(algebraic: from))
        let to = try #require(Square(algebraic: to))
        model.select(from)
        model.attemptMove(from: from, to: to)
    }

    @Test("Next on the last mistake, while the engine checks a move, leaves the page empty")
    func nextDuringTheCheck() async throws {
        try await withScratchStoreAsync("auditNextDuringCheck") {
            _ = try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.phase == .playerToMove)
            // Neither the answer nor the game's own move: the engine is asked.
            try play(model, "a1", "a7")
            #expect(model.phase == .checking)
            model.loadNext()
            #expect(model.phase == .empty)

            // Long enough for a check left running to land.
            for _ in 0..<100 where model.phase == .empty {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(model.phase == .empty, "the check came back over the empty page")
            #expect(model.attempt == nil)
            #expect(MistakeStore.shared.entries.first?.attempts == 0, "an undecided check was written down")
        }
    }

    @Test("Retry before trying anything leaves the attempt counting")
    func retryBeforeTrying() throws {
        try withScratchStore("auditRetryUntouched") {
            _ = try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            model.retry()
            #expect(model.phase == .playerToMove)
            try play(model, "a1", "a8")
            #expect(model.phase == .solved)
            let entry = try #require(MistakeStore.shared.entries.first)
            #expect(entry.fixed, "a clean fix after an idle Retry was not counted")
            #expect(entry.attempts == 1)
        }
    }

    @Test("A mistake got wrong and then retried is written down as a miss, once")
    func retryAfterAWrongMove() throws {
        try withScratchStore("auditRetryAfterWrong") {
            _ = try storeMistake()
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            // The game's own move again: wrong without asking the engine.
            try play(model, "g1", "f2")
            #expect(model.phase == .wrong)
            model.retry()
            try play(model, "a1", "a8")
            #expect(model.phase == .solved)
            let entry = try #require(MistakeStore.shared.entries.first)
            #expect(entry.attempts == 1, "the try that went wrong was never written down")
            #expect(!entry.fixed, "a solve on a retry counted as a fix")
            model.loadNext()
            #expect(MistakeStore.shared.entries.first?.attempts == 1)
        }
    }

    @Test("Leaving a mistake that went wrong writes the miss down; skipping one untried does not")
    func leavingAMistake() throws {
        try withScratchStore("auditLeaveMistake") {
            _ = try storeMistake()
            let untried = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            untried.teardown()
            #expect(MistakeStore.shared.entries.first?.attempts == 0)

            let tried = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            try play(tried, "g1", "f2")
            tried.teardown()
            tried.teardown()
            #expect(MistakeStore.shared.entries.first?.attempts == 1)
        }
    }
}

// MARK: - Imports

@Suite("Audit fixes: games read only in part")
@MainActor
struct ImportAuditFixesTests {

    @Test("An import says how many games stop short of their written moves")
    func cutShortGamesAreCounted() throws {
        let pgn = """
            [Event "Cut short"]

            1. e4 e5 2. Ke3 Nc6 *

            [Event "Whole"]

            1. d4 d5 *
            """
        let games = try MyGamesView.importedGames(fromPGN: pgn)
        #expect(games.records.count == 2, "the game cut short should still be kept up to there")
        #expect(games.cutShort == 1)
        #expect(games.records.first?.moveUCIs == ["e2e4", "e7e5"])

        let summary = GameArchive.ImportSummary(added: 2, duplicates: 0, kept: 2)
        let told = MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 1, cutShort: 1)
        let untold = MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 1)
        #expect(told != untold && told.hasPrefix(untold), "the import said nothing about the game cut short")
    }
}

// MARK: - Speech

@Suite("Audit fixes: moves read aloud")
@MainActor
struct SpokenMoveAuditFixesTests {

    private func spoken(_ uci: String, in fen: String) throws -> String {
        let board = try #require(Board(fen: fen))
        let move = try #require(board.generateLegalMoves().first { $0.uci == uci }, "no legal \(uci)")
        return BoardSpeech.spokenMove(move, on: board)
    }

    /// The test host speaks whatever language the simulator is set to, and
    /// the app knows two: each case says what both of them should hear.
    private func inAppLanguage(english: String, czech: String) -> String {
        Bundle.main.preferredLocalizations.first == "cs" ? czech : english
    }

    @Test("A move is said with its piece and square, not spelled out as notation", arguments: [
        ("g1f3", Board.startFEN, "knight f 3", "jezdec f 3"),
        ("d1d2", "3k4/8/8/8/8/8/3r4/3QK3 w - - 0 1", "queen takes d 2, check", "dáma bere d 2, šach"),
        ("e1g1", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "castles kingside", "malá rošáda"),
        ("e1c1", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "castles queenside", "velká rošáda"),
        ("a7a8q", "8/P7/8/8/8/1k6/8/7K w - - 0 1", "pawn a 8, promotes to queen", "pěšec a 8, proměna v dámu"),
        ("e5d6", "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2", "pawn takes d 6, en passant", "pěšec bere d 6, mimochodem"),
        ("a1a8", "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", "rook a 8, checkmate", "věž a 8, mat"),
    ])
    func movesAreSpoken(uci: String, fen: String, english: String, czech: String) throws {
        let said = try spoken(uci, in: fen)
        #expect(said == inAppLanguage(english: english, czech: czech))
    }

    @Test("A move played is announced with the side that played it")
    func announcementNamesTheSide() throws {
        var game = Game()
        game.play(try #require(game.legalMoves.first { $0.uci == "g1f3" }))
        let played = try #require(game.history.last)
        let said = BoardSpeech.announcement(for: played, outcome: game.outcome, mode: .twoPlayer)
        #expect(said == inAppLanguage(english: "White: knight f 3", czech: "Bílý: jezdec f 3"))
    }
}

// MARK: - Menu

@Suite("Audit fixes: the menu's setup", .serialized)
@MainActor
struct MenuSetupAuditFixesTests {

    @Test("The menu's setup outlives the menu")
    func setupIsKept() throws {
        withScratchStore("auditMenuSetup") {
            let settings = AppSettings()
            #expect(settings.menuSetup == MenuSetup())
            var setup = MenuSetup()
            setup.difficulty = .expert
            setup.side = "black"
            setup.aiStart.kind = .odds
            setup.aiStart.handicap = .rook
            setup.twoPlayerVariant = .threeCheck
            settings.menuSetup = setup
            #expect(AppSettings().menuSetup == setup, "the setup was not there for the next menu")
        }
    }

    @Test("A setup saved with a choice no longer offered keeps the rest")
    func unknownChoicesFallBack() throws {
        let json = #"{"difficulty":"expert","side":"black","aiVariant":"crazyhouse","aiStart":{"kind":"bughouse","handicap":"rook"}}"#
        let setup = try JSONDecoder().decode(MenuSetup.self, from: Data(json.utf8))
        #expect(setup.difficulty == .expert)
        #expect(setup.side == "black")
        #expect(setup.aiVariant == .standard)
        #expect(setup.aiStart.kind == .standard)
        #expect(setup.aiStart.handicap == .rook)
        #expect(setup.twoPlayerStart == StartChoice())
    }
}

// MARK: - Clock faces

@Suite("Audit fixes: clock redraws")
struct ClockScheduleAuditFixesTests {

    private func offsets(_ schedule: ClockFaceSchedule, mode: TimelineScheduleMode = .normal, count: Int) -> [Double] {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        return schedule.entries(from: start, mode: mode).prefix(count).map {
            ($0.timeIntervalSince(start) * 1000).rounded() / 1000
        }
    }

    @Test("A running face is redrawn when its reading changes, and only then")
    func redrawnOnChange() {
        // 12.3 s shows 0:13 until 12.0, then a second at a time to 0:10, then
        // tenths: 9.9, 9.8, …
        let schedule = ClockFaceSchedule(remaining: 12.3, tenthsBelow: 10)
        #expect(offsets(schedule, count: 7) == [0, 0.3, 1.3, 2.3, 2.4, 2.5, 2.6])
    }

    @Test("A face whose clock is not running is drawn once")
    func stoppedIsDrawnOnce() {
        #expect(offsets(ClockFaceSchedule(remaining: 0, tenthsBelow: 10), count: 5) == [0])
    }

    @Test("A dimmed face is redrawn to the second")
    func dimmedToTheSecond() {
        let schedule = ClockFaceSchedule(remaining: 2.5, tenthsBelow: 10)
        #expect(offsets(schedule, mode: .lowFrequency, count: 10) == [0, 0.5, 1.5, 2.5])
    }

    @Test("The last entry is the flag, and nothing follows it")
    func endsAtTheFlag() {
        let schedule = ClockFaceSchedule(remaining: 0.25, tenthsBelow: 10)
        #expect(offsets(schedule, count: 10) == [0, 0.05, 0.15, 0.25])
    }
}
