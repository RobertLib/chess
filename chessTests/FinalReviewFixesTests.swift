//
//  FinalReviewFixesTests.swift
//  chessTests
//
//  One test per fault found in the last review before 1.0.1 went out, each
//  written to fail on the code as it was: a piece picked up before Solution
//  that could still be played into the solution, Chess960 castling by the
//  king's square missing from mistake puzzles, Agree to a Draw that did
//  nothing once the game was held, an analysis board that always opened
//  White-up, the game 1.0 kept dropped before the archive held it, a PGN file
//  of blank lines and tags that took hours to read, an import limit that
//  twenty files picked together read twenty times over, two Czech strings
//  that said the wrong thing, and the Open Ruy López named the Closed one.
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

/// `withScratchStore` for a test that waits on the writer. The store stays
/// swapped in across the wait, under the lock the other async suites take.
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

private func setPermissions(_ permissions: Int, of url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

// MARK: - Puzzles

@Suite("Final review fixes: puzzles", .serialized)
@MainActor
struct PuzzleFinalReviewFixesTests {

    private func storeMistake(fen: String, best: String, played: String) throws {
        let entry = MistakeEntry(
            id: UUID(), fen: fen, setupUCI: nil, bestUCI: best,
            playedSAN: played, quality: .blunder, foundAt: Date()
        )
        MistakeStore.shared.reset()
        LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")
    }

    @Test("Solution puts down the piece picked up, and a tap on its old dots plays nothing")
    func solutionPutsThePieceDown() throws {
        try withScratchStore("finalSolutionSelection") {
            // Mate in one with Ra8; the game's move was Kf2.
            try storeMistake(fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", best: "a1a8", played: "Kf2")
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            let rook = try #require(Square(algebraic: "a1"))
            let dot = try #require(Square(algebraic: "a2"))
            model.select(rook)
            #expect(model.legalTargets.contains { $0.to == dot })

            model.showSolution()
            #expect(model.phase == .shown)
            #expect(model.selectedSquare == nil, "the piece stayed picked up")
            #expect(model.legalTargets.isEmpty, "its dots stayed on the board")

            // Tapped anyway — by a finger already on its way — nothing is judged.
            model.handleTap(on: dot)
            #expect(!model.attemptMove(from: rook, to: dot))
            #expect(model.phase == .shown, "a move was played into the solution")
        }
    }

    @Test("A Chess960 castle in one of the player's mistakes is reached by the king's square too")
    func chess960CastleByTheKingsSquare() throws {
        try withScratchStore("finalMistake960Castle") {
            // The king on d1 castles with the rook on h1, landing on g1. The
            // board offers it as Kxh1; players reach for g1.
            try storeMistake(fen: "1k6/8/8/8/8/8/8/3K3R w H - 0 1", best: "d1h1", played: "Kc2")
            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.position.isChess960)
            model.select(try #require(Square(algebraic: "d1")))
            model.handleTap(on: try #require(Square(algebraic: "g1")))
            #expect(model.phase == .solved, "g1 put the king down instead of castling")
        }
    }
}

// MARK: - Games and boards

@Suite("Final review fixes: games and boards", .serialized)
@MainActor
struct GameFinalReviewFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    private func play(_ model: GameViewModel, _ uci: String) throws {
        let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        #expect(model.game.lastMove == move)
    }

    @Test("Agree to a Draw answered after the game was held still ends it")
    func drawAgreedWhileHeld() throws {
        try withScratchStore("finalDrawHeld") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 0)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            try play(model, "e2e4")
            // The players open Draw, the app goes away and comes back: the
            // game is held under the dialog, and the draw is agreed there.
            model.pause()
            #expect(!model.canAgreeToDraw, "Draw is offered under the pause cover")
            model.agreeToDraw()
            #expect(model.game.outcome == .drawAgreed, "the draw was agreed and the game went on")
            #expect(!model.isPaused, "the pause cover stayed over a finished game")
        }
    }

    @Test("The analysis board opens the way up it is asked to")
    func analysisBoardOrientation() {
        let model = AnalysisBoardModel(game: Game(), startPly: 0, orientation: .black)
        defer { model.teardown() }
        #expect(model.orientation == .black, "Black's player was turned White-up")
        model.load(fen: Board.startFEN)
        #expect(model.orientation == .black, "a new position turned the board round")
    }

    @Test("The Open Ruy López is not named the Closed one")
    func closedRuyLopezNeedsBe7() {
        func name(_ sans: [String]) -> String? { OpeningBook.match(sans: sans).name }
        let fiveCastles = ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6", "O-O"]
        let closed = String(localized: "Ruy López: Closed")
        #expect(name(fiveCastles + ["Nxe4"]) != closed, "5...Nxe4 is the Open variation")
        #expect(name(fiveCastles + ["Be7"]) == closed)
    }
}

// MARK: - Storage and import

@Suite("Final review fixes: storage and import", .serialized)
@MainActor
struct StorageFinalReviewFixesTests {

    @discardableResult
    private func storeFinishedGame() throws -> FinishedGame {
        var game = try played(["e2e4", "e7e5", "g1f3"])
        game.resign(.black)
        let finished = FinishedGame(game: game, mode: .twoPlayer)
        LocalStore.defaults.set(try JSONEncoder().encode(finished), forKey: "finishedGame")
        return finished
    }

    /// Waits until the drops asked for so far have gone, or been given up:
    /// one of a key of the test's own, asked for after them and waiting on a
    /// file never written, goes the same way behind them.
    private func settleDrops() async throws {
        LocalStore.set(Data(), forKey: "finalSentinel")
        LocalStore.remove("finalSentinel", onceFiled: "finalSentinel")
        try await waitFor { LocalStore.defaults.object(forKey: "finalSentinel") == nil }
        #expect(LocalStore.defaults.object(forKey: "finalSentinel") == nil, "the drops never settled")
    }

    @Test("The game 1.0 kept stays under its key until the archive holds it")
    func migrationWaitsForTheArchive() async throws {
        try await withScratchStoreAsync("finalMigrationFiled") {
            let finished = try storeFinishedGame()
            FinishedGame.migrateToArchive()
            #expect(LocalStore.defaults.data(forKey: "finishedGame") != nil, "dropped before the archive was written")

            let files = LocalStore.files
            try await waitFor { LocalStore.defaults.object(forKey: "finishedGame") == nil }
            #expect(LocalStore.defaults.object(forKey: "finishedGame") == nil, "never dropped")
            let stored = try JSONDecoder().decode([GameRecord].self, from: try #require(files.read("gameArchive")))
            #expect(stored.first?.moveUCIs == finished.moveUCIs)
        }
    }

    @Test("The game 1.0 kept is not dropped when the archive cannot be written")
    func migrationKeepsTheGameWhenTheWriteFails() async throws {
        try await withScratchStoreAsync("finalMigrationNotFiled") {
            // A store nothing can be written into, which turns the archive's
            // write away as a full disk would.
            let directory = LocalStore.files.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try setPermissions(0o555, of: directory)
            defer { try? setPermissions(0o755, of: directory) }

            try storeFinishedGame()
            FinishedGame.migrateToArchive()
            try await settleDrops()
            #expect(!LocalStore.files.lastWriteLanded("gameArchive"), "the archive was written after all")
            #expect(LocalStore.defaults.data(forKey: "finishedGame") != nil, "the game was lost from both stores")
        }
    }

    @Test("A file of blank lines between new tags reads in one pass", .timeLimit(.minutes(1)))
    nonisolated func blankLinesBetweenTags() throws {
        // Each blank line padded out, so that the old trim of everything read
        // so far at every tag would take hours where one pass takes moments.
        let padding = String(repeating: " ", count: 100)
        let text = (0..<40_000).map { "[T\($0) \"\"]\n\(padding)" }.joined(separator: "\n")
        let contents = try PGN.contents(of: text)
        #expect(contents.games.count == 1)
        #expect(contents.games.first?.tags.count == 40_000)
    }

    private func scratchFiles(_ count: Int, holding data: Data) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "finalImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = directory.appending(path: "\(index).pgn", directoryHint: .notDirectory)
            try data.write(to: url)
            return url
        }
    }

    @Test("Files picked together share the import limit, and the player is told what was left out")
    func importLimitIsShared() throws {
        let file = Data("[Event \"a\"]\n\n1. e4 e5 1-0\n".utf8)
        let urls = try scratchFiles(3, holding: file)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }

        // Each within the limit by itself; two of them are all it takes.
        let read = MyGamesView.readImports(from: urls, limit: file.count * 2)
        #expect(read.records.count == 2, "every file was read in full")
        #expect(read.leftOverFiles == 1)
        #expect(read.tooLargeFiles == 0)

        let summary = GameArchive.ImportSummary(added: 2, duplicates: 0, kept: 2)
        let message = MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 3, leftOverFiles: 1)
        #expect(message.hasSuffix(String(localized: "\(1) files were left out: the files picked are too large to import together.")))
    }
}

// MARK: - Czech

@Suite("Final review fixes: Czech")
struct CzechFinalReviewFixesTests {

    private func czech() throws -> Bundle {
        try #require(Bundle.main.path(forResource: "cs", ofType: "lproj").flatMap(Bundle.init(path:)))
    }

    @Test("The clock is reset with Vynulovat, and the lesson keeps Znovu")
    func clockResetHasItsOwnWord() throws {
        let czech = try czech()
        #expect(String(localized: "clock.reset", defaultValue: "Reset", bundle: czech) == "Vynulovat",
                "\"Reset the clock?\" was answered with \"again\"")
        #expect(String(localized: "Reset", bundle: czech) == "Znovu")
    }

    @Test("The spoken hint names the square the piece stands on, not one to go to")
    func hintNamesTheStartingSquare() throws {
        let square = "e 2"
        #expect(String(localized: "announce.puzzleHint", defaultValue: "Hint: move the piece on \(square)", bundle: try czech())
                == "Nápověda: táhněte figurou z pole e 2")
    }
}
