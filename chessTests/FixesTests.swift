//
//  FixesTests.swift
//  chessTests
//
//  One test per fault found in the review of 1.0.1, each written to fail on
//  the code as it was: a FEN that crashed the app, a PGN read wrong, an
//  exchange scored short, games pushed out of the archive, puzzles and clocks
//  that miscounted.
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

// MARK: - Rules

@Suite("Fixes: rules")
struct RulesFixesTests {

    @Test("A FEN with huge move counters is read, and its moves can be played")
    func hugeCounters() throws {
        // Both used to trap on the first `+= 1`, as soon as the game looked
        // for legal moves.
        var game = Game(fen: "4k3/8/8/8/8/8/8/4K2R b K - 0 9223372036854775807")
        let move = try #require(game.legalMoves.first)
        game.play(move)
        #expect(game.history.count == 1)
        #expect(game.board.fullmoveNumber == Board.counterLimit + 1)

        // A halfmove clock that large is past the fifty moves already.
        let stale = Game(fen: "4k3/8/8/8/8/8/8/4K2R w K - 9223372036854775807 1")
        #expect(stale.outcome == .drawFiftyMoveRule)
    }

    @Test("Bishops all on one colour are insufficient material, however many")
    func sameColouredBishops() throws {
        // a1, c1 and g1 are all dark squares.
        let three = try #require(Board(fen: "4k3/8/8/8/8/8/8/B1B1K1B1 w - - 0 1"))
        #expect(three.hasInsufficientMaterial)
        // One of them light (b1), and mate is possible again.
        let mixed = try #require(Board(fen: "4k3/8/8/8/8/8/8/BBB1K3 w - - 0 1"))
        #expect(!mixed.hasInsufficientMaterial)
    }

    @Test("An exchange is played out to the last recapture")
    func exchangeAfterCutoff() throws {
        // Nxe5 dxe5, and White stops there: dxe5 would only lose the d-pawn
        // to fxe5. A knight for a pawn — the cutoff scored it as if Black
        // could not answer dxe5, a knight for two.
        let knight = try #require(Board(fen: "4k3/8/3p1p2/4p3/3P4/5N2/8/4K3 w - - 0 1"))
        let nxe5 = try #require(knight.generateLegalMoves().first { $0.uci == "f3e5" })
        #expect(knight.staticExchangeEvaluation(nxe5) == PieceKind.pawn.centipawns - PieceKind.knight.centipawns)

        let bishop = try #require(Board(fen: "4k3/8/3p1p2/4p3/3P4/6B1/8/4K3 w - - 0 1"))
        let bxe5 = try #require(bishop.generateLegalMoves().first { $0.uci == "g3e5" })
        #expect(bishop.staticExchangeEvaluation(bxe5) == PieceKind.pawn.centipawns - PieceKind.bishop.centipawns)

        // An exchange that stops early still stops: a defended pawn taken
        // by a pawn is a pawn up.
        let simple = try #require(Board(fen: "4k3/8/3p4/4p3/3P4/8/8/4K3 w - - 0 1"))
        let dxe5 = try #require(simple.generateLegalMoves().first { $0.uci == "d4e5" })
        #expect(simple.staticExchangeEvaluation(dxe5) == 0)
    }

    @Test("A draw a player could claim is claimed only when asked for")
    func claimingADraw() throws {
        var game = Game(settlesClaimableDraws: false)
        for uci in ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"] {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }))
        }
        #expect(game.outcome == .ongoing, "a third repetition is a claim, not an ending")
        let claimed = game.claimDraw()
        #expect(claimed)
        #expect(game.outcome == .drawThreefoldRepetition)

        // The app's own games still end on it by themselves.
        let own = try played(["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"])
        #expect(own.outcome == .drawThreefoldRepetition)
    }
}

// MARK: - PGN

@Suite("Fixes: PGN")
struct PGNFixesTests {

    @Test("A game that played on past an unclaimed repetition is read to its end")
    func playsOnPastRepetition() throws {
        let text = """
            [Result "1-0"]

            1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 5. e4 e5 1-0
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.count == 10)
        #expect(parsed.game.outcome == .resigned(winner: .white))

        // And it comes back the same way out of the archive.
        let record = GameRecord(
            game: parsed.game, mode: .twoPlayer, options: .standard,
            moveTimes: [], finalClock: nil, source: .imported
        )
        let restored = try #require(record.restoreGame())
        #expect(restored.history.count == 10)
        #expect(restored.outcome == .resigned(winner: .white))
    }

    @Test("A drawn game that ends on a repetition is read as the repetition")
    func claimedRepetition() throws {
        let text = """
            [Result "1/2-1/2"]

            1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 1/2-1/2
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.outcome == .drawThreefoldRepetition)
        let record = GameRecord(
            game: parsed.game, mode: .twoPlayer, options: .standard,
            moveTimes: [], finalClock: nil, source: .imported
        )
        #expect(record.restoreGame()?.outcome == .drawThreefoldRepetition)
    }

    @Test("Figurines are read as the pieces they show")
    func figurines() throws {
        let parsed = try #require(try PGN.parse("1. e4 e5 2. ♘f3 ♞c6 3. ♗b5 *").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.move.uci) == ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
    }

    @Test("A piece letter the reader does not know stops the import instead of moving a pawn")
    func unknownLetters() {
        let start = Game()
        #expect(PGN.move(for: "Zf3", in: start) == nil)
        #expect(PGN.move(for: "nf3", in: start) == nil)
        #expect(PGN.move(for: "f3", in: start)?.uci == "f2f3")
        // Disambiguation is still read.
        #expect(PGN.move(for: "Ngf3", in: start)?.uci == "g1f3")
    }

    @Test("An annotation or an e.p. standing apart from its move is read past")
    func detachedAnnotations() throws {
        let parsed = try #require(try PGN.parse("1. e4 !? a6 2. e5 d5 3. exd6 e.p. Qxd6 +- *").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.move.uci) == ["e2e4", "a7a6", "e4e5", "d7d5", "e5d6", "d8d6"])
    }

    @Test("A PGN date with unknown parts still files the game under its year")
    @MainActor
    func partialDates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let full = try #require(MyGamesView.date(from: "2023.05.17"))
        #expect(calendar.component(.year, from: full) == 2023)
        #expect(calendar.component(.month, from: full) == 5)
        let yearOnly = try #require(MyGamesView.date(from: "2023.??.??"))
        #expect(calendar.component(.year, from: yearOnly) == 2023)
        #expect(MyGamesView.date(from: "????.??.??") == nil)
        #expect(MyGamesView.date(from: nil) == nil)
    }
}

// MARK: - Archive and achievements

@Suite("Fixes: archive", .serialized)
@MainActor
struct ArchiveFixesTests {

    private func record(source: GameRecord.Source, at date: Date) throws -> GameRecord {
        GameRecord(
            game: try played(["e2e4", "e7e5"]), mode: .twoPlayer, options: .standard,
            moveTimes: [], finalClock: nil, source: source, finishedAt: date
        )
    }

    @Test("Importing a large file never pushes the player's own games out")
    func importsHaveTheirOwnRoom() throws {
        try withScratchStore("fixesArchiveCap") {
            let archive = GameArchive.shared
            let old = Date(timeIntervalSince1970: 1_000_000)
            let own = try (0..<GameArchive.maxRecords).map { _ in try record(source: .played, at: old) }
            archive.add(contentsOf: own)

            // Undated imports file as today's, newer than every game played.
            let imported = try (0..<(GameArchive.maxRecords + 50)).map { _ in try record(source: .imported, at: Date()) }
            let kept = archive.add(contentsOf: imported)

            #expect(kept == GameArchive.maxRecords)
            #expect(archive.records.count { $0.source == .played } == GameArchive.maxRecords)
            #expect(archive.records.count { $0.source == .imported } == GameArchive.maxRecords)
        }
    }

    @Test("Reviewing somebody else's game earns no accuracy achievement")
    func precisionIsOwnGamesOnly() throws {
        try withScratchStore("fixesPrecision") {
            var record = try record(source: .imported, at: Date())
            record.moveUCIs = Array(repeating: "e2e4", count: 40)
            record.accuracy = [95, 95]
            Achievements.shared.gameReviewed(record)
            #expect(!Achievements.shared.isUnlocked(.precision))

            record.source = .played
            Achievements.shared.gameReviewed(record)
            #expect(Achievements.shared.isUnlocked(.precision))
        }
    }

    @Test("The game 1.0 kept for review is moved into the archive, once")
    func finishedGameMigrates() throws {
        try withScratchStore("fixesMigration") {
            var game = try played(["e2e4", "e7e5", "g1f3"])
            game.resign(.black)
            let finished = FinishedGame(game: game, mode: .twoPlayer)
            LocalStore.defaults.set(try JSONEncoder().encode(finished), forKey: "finishedGame")

            FinishedGame.migrateToArchive()
            let records = GameArchive.shared.records
            #expect(records.count == 1)
            #expect(records.first?.moveUCIs == ["e2e4", "e7e5", "g1f3"])
            #expect(records.first?.restoreGame()?.outcome == .resigned(winner: .white))

            // Run again — or with the same game already archived — it adds
            // nothing, and the old key is dropped. (Filed, the key waits for
            // the archive's write: see `FinishedGameFilingFixesTests`.)
            LocalStore.defaults.set(try JSONEncoder().encode(finished), forKey: "finishedGame")
            FinishedGame.migrateToArchive()
            #expect(GameArchive.shared.records.count == 1)
            #expect(FinishedGame.load() == nil, "the old key is dropped")
        }
    }
}

// MARK: - Puzzles

@Suite("Fixes: puzzles", .serialized)
@MainActor
struct PuzzleFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    @Test("Yesterday's puzzle finished after today's leaves the streak alone")
    func dailyOutOfOrder() {
        withScratchStore("fixesDaily") {
            let store = PuzzleStore.shared
            store.recordDailySolved(day: 100)
            store.recordDailySolved(day: 101)
            store.recordDailySolved(day: 100)
            #expect(store.progress.dailyLastSolved == 101)
            #expect(store.progress.dailyStreak == 2)
        }
    }

    @Test("A used-up theme starts over at random, never on the puzzle just played")
    func usedUpTheme() throws {
        let pool = PuzzleLibrary.puzzles(theme: "smotheredMate")
        let everything = Set(pool.map(\.id))
        let previous = try #require(pool.first).id
        var generator = SystemRandomNumberGenerator()
        var picks = Set<String>()
        for _ in 0..<30 {
            let next = try #require(PuzzleLibrary.next(
                near: 1500, theme: "smotheredMate", exclude: everything, avoiding: previous, using: &generator
            ))
            #expect(next.id != previous)
            picks.insert(next.id)
        }
        #expect(picks.count > 1, "the same puzzle came back every time")
    }

    @Test("A rush that runs out of puzzles ends like any other, its clock stopped")
    func rushRunsOut() {
        withScratchStore("fixesRush") {
            let time = FakeTime()
            let model = PuzzleSessionModel(kind: .rush(.threeMinutes), settings: AppSettings(), timeSource: { time.now })
            defer { model.teardown() }
            for _ in 0..<400 where model.phase != .rushOver {
                model.loadNext()
            }
            #expect(model.phase == .rushOver)
            let left = model.rushTimeLeft
            time.now += 60
            #expect(model.rushTimeLeft == left, "the clock under the result card kept counting")
        }
    }

    @Test("A mistake solved on a retry is not counted as fixed")
    func retryIsNotAFix() throws {
        try withScratchStore("fixesRetry") {
            let entry = MistakeEntry(
                id: UUID(), fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", setupUCI: nil, bestUCI: "a1a8",
                playedSAN: "Kf2", quality: .blunder, foundAt: Date()
            )
            MistakeStore.shared.reset()
            LocalStore.defaults.set(try JSONEncoder().encode([entry]), forKey: "mistakes")

            let model = PuzzleSessionModel(kind: .mistakes, settings: AppSettings())
            defer { model.teardown() }
            #expect(model.phase == .playerToMove)
            model.showSolution()
            model.retry()
            #expect(model.phase == .playerToMove)

            let from = try #require(Square(algebraic: "a1"))
            let to = try #require(Square(algebraic: "a8"))
            model.select(from)
            model.attemptMove(from: from, to: to)
            #expect(model.phase == .solved)
            #expect(MistakeStore.shared.entries.first?.fixed == false)
        }
    }

    @Test("The English subtitle of the mistakes card agrees with its number")
    func mistakesSubtitlePlural() {
        let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let one = 1, two = 2, none = 0
        #expect(String(localized: "\(one) positions from your games · \(none) fixed", bundle: english)
                == "1 position from your games · 0 fixed")
        #expect(String(localized: "\(two) positions from your games · \(one) fixed", bundle: english)
                == "2 positions from your games · 1 fixed")
    }
}

// MARK: - Clocks, review, analysis

@Suite("Fixes: clocks and boards", .serialized)
@MainActor
struct ClockAndBoardFixesTests {

    final class FakeTime {
        var now: TimeInterval = 1_000
    }

    @Test("A move that lands after the flag fell loses on time instead of earning the increment")
    func lateMoveLoses() throws {
        try withScratchStore("fixesLateMove") {
            let time = FakeTime()
            let model = GameViewModel(
                mode: .twoPlayer, settings: AppSettings(),
                options: GameOptions(timeControl: .minutes(1, plus: 2)),
                timeSource: { time.now }
            )
            defer { model.teardown() }
            let e4 = try #require(model.game.legalMoves.first { $0.uci == "e2e4" })
            model.handleTap(on: e4.from)
            model.handleTap(on: e4.to)
            // Black's minute runs out before the watch wakes to notice.
            time.now += 61
            let e5 = try #require(model.game.legalMoves.first { $0.uci == "e7e5" })
            model.handleTap(on: e5.from)
            model.handleTap(on: e5.to)
            #expect(model.game.history.count == 1)
            #expect(model.game.outcome == .timeForfeit(winner: .white))
        }
    }

    @Test("A tap on the chess clock after the flag fell does not press it")
    func lateTapLoses() {
        withScratchStore("fixesLateTap") {
            let time = FakeTime()
            let model = ChessClockModel(control: .minutes(1, plus: 2), timeSource: { time.now })
            defer { model.teardown() }
            model.tap(.black)
            time.now += 61
            model.tap(.white)
            #expect(model.flagged == .white)
            #expect(model.remaining(for: .white) <= 0, "the increment was handed back")
        }
    }

    @Test("A review stopped by a cover over it starts its analysis again")
    func reviewResumes() throws {
        try withScratchStore("fixesReview") {
            let game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"])
            let model = GameReviewModel(game: game, mode: .twoPlayer)
            defer { model.teardown() }
            model.startAnalysis()
            #expect(model.isAnalyzing)
            model.teardown()
            #expect(!model.isAnalyzing)
            model.startAnalysis()
            #expect(model.isAnalyzing, "the analysis did not pick up again")
        }
    }

    @Test("The analysis board takes the position the editor hands back")
    func analysisLoadsEditedPosition() throws {
        let model = AnalysisBoardModel(fen: Board.startFEN)
        defer { model.teardown() }
        let edited = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
        model.load(fen: edited)
        #expect(model.game.board.fen == edited)
        #expect(model.line.isEmpty)
        #expect(!model.canStepBack)
    }
}
