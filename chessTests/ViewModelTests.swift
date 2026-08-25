//
//  ViewModelTests.swift
//  chessTests
//
//  The layers between the engine and the screen: the review's animated board,
//  the notation shown to the reader, and the opening book that names a game.
//

import Foundation
import Testing
@testable import chess

// MARK: - Review board

/// Stepping through a finished game moves pieces one at a time rather than
/// rebuilding the board, so that SwiftUI can animate them. That shortcut is
/// only safe while it agrees with the position it is meant to be showing —
/// which is what these tests hold it to.
@Suite("Review board")
@MainActor
struct GameReviewModelTests {

    private func game(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
        var game = Game(fen: fen)
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
        }
        return game
    }

    /// Every piece the review draws, on the square the real position has it —
    /// and nothing drawn twice on one square.
    private func expectBoardIsDrawnCorrectly(
        _ model: GameReviewModel, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var drawn = [UInt8](repeating: 0, count: 64)
        for rendered in model.pieces {
            #expect(
                drawn[rendered.square.index] == 0,
                "\(context): two pieces drawn on \(rendered.square)",
                sourceLocation: sourceLocation
            )
            drawn[rendered.square.index] = rendered.piece.packed
        }
        #expect(
            drawn == model.board.squares,
            "\(context): the drawn pieces are not the position at ply \(model.plyIndex)",
            sourceLocation: sourceLocation
        )
    }

    private func walkThroughAndBack(
        _ game: Game, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let model = GameReviewModel(game: game, mode: .twoPlayer)

        model.goToStart()
        expectBoardIsDrawnCorrectly(model, "\(context), start", sourceLocation: sourceLocation)
        while model.canStepForward {
            model.stepForward()
            expectBoardIsDrawnCorrectly(
                model, "\(context), forward to ply \(model.plyIndex)", sourceLocation: sourceLocation
            )
        }
        while model.canStepBack {
            model.stepBackward()
            expectBoardIsDrawnCorrectly(
                model, "\(context), back to ply \(model.plyIndex)", sourceLocation: sourceLocation
            )
        }
    }

    @Test("Castling and en passant survive a walk through the game")
    func specialMovesStepCorrectly() throws {
        // 1.e4 e6 2.e5 d5 3.exd6 cxd6 4.Nf3 Nf6 5.Bc4 Be7 6.O-O O-O
        let played = try game([
            "e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
            "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"
        ])
        #expect(played.history.contains { $0.move.isEnPassant })
        #expect(played.history.count { $0.move.isCastle } == 2)
        walkThroughAndBack(played, "special moves")
    }

    @Test("Promotions survive a walk through the game")
    func promotionsStepCorrectly() throws {
        // axb8=Q+ Kg7 g4 Kf6 g5+ Ke6 g6 Kd7 gxh7 Ke6 h8=N — a pawn takes a
        // knight and becomes a queen, and a second one under-promotes.
        let played = try game(
            ["a7b8q", "h8g7", "g2g4", "g7f6", "g4g5", "f6e6", "g5g6", "e6d7", "g6h7", "d7e6", "h7h8n"],
            from: "1n5k/P6p/8/8/8/8/6P1/6K1 w - - 0 1"
        )
        #expect(played.history.count { $0.move.promotion != nil } == 2)
        #expect(played.history.contains { $0.move.promotion == .knight })
        #expect(played.history.contains { $0.move.promotion == .queen && $0.move.isCapture })
        walkThroughAndBack(played, "promotions")
    }

    /// Breadth rather than depth: games drawn from a fixed seed, biased towards
    /// the moves that make the render model interesting.
    @Test("Sixty games step forward and back without the board drifting")
    func randomGamesStepCorrectly() {
        var rng = Zobrist.SplitMix64(seed: 0xC0FFEE)
        var promotions = 0, enPassants = 0, castles = 0

        for index in 0..<60 {
            var played = Game()
            while !played.outcome.isGameOver && played.history.count < 120 {
                let legal = played.legalMoves
                guard !legal.isEmpty else { break }
                let promoting = legal.filter { $0.promotion != nil }
                let capturing = legal.filter { $0.isCapture }
                let pool = !promoting.isEmpty && rng.next() % 2 == 0 ? promoting
                    : (!capturing.isEmpty && rng.next() % 3 != 0 ? capturing : legal)
                played.play(pool[Int(rng.next() % UInt64(pool.count))])
            }
            promotions += played.history.count { $0.move.promotion != nil }
            enPassants += played.history.count { $0.move.isEnPassant }
            castles += played.history.count { $0.move.isCastle }
            walkThroughAndBack(played, "game \(index)")
        }

        // The sweep is worthless if it never reached the awkward moves.
        #expect(promotions > 0, "no promotion in the sample")
        #expect(enPassants > 0, "no en passant in the sample")
        #expect(castles > 0, "no castling in the sample")
    }

    @Test("Jumping to an arbitrary position draws that position")
    func jumpingDrawsTheRightPosition() throws {
        let played = try game([
            "e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
            "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"
        ])
        let model = GameReviewModel(game: played, mode: .twoPlayer)
        for ply in [0, 5, 12, 3, 11, 1, 12, 0] {
            model.go(to: ply)
            #expect(model.plyIndex == ply)
            expectBoardIsDrawnCorrectly(model, "jump to \(ply)")
        }
    }

    @Test("Stepping forward by hand takes over from a replay")
    func steppingForwardStopsAutoplay() throws {
        let played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
        let model = GameReviewModel(game: played, mode: .twoPlayer)
        model.goToStart()
        model.toggleAutoplay()
        #expect(model.isAutoplaying)
        model.stepForward()
        #expect(!model.isAutoplaying, "a hand-driven step must not leave the replay running")
    }
}

// MARK: - Cached analysis

/// A review searches every position of the game, which is the whole cost of
/// opening one — so the results are kept and a second review of the same game
/// reuses them. These tests hold the cache to the only thing that makes it
/// safe: what comes back out of it is what a re-run would have produced.
///
/// Serialized, and asynchronous: they swap `LocalStore.defaults` for a scratch
/// suite and then wait on the engine, so two of them running at once on the
/// main actor would each restore the other's store. The synchronous helper the
/// other suites use has no such window — it never suspends while holding the
/// swap.
@Suite("Cached analysis", .serialized)
@MainActor
struct GameAnalysisCacheTests {

    private func game(_ ucis: [String]) throws -> Game {
        var game = Game()
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
        }
        return game
    }

    /// The searches are the whole cost of a review, so a second review of the
    /// same game must not run any: the report has to come back from the cache
    /// complete, and identical to the one that was stored.
    @Test("Reviewing the same game again reuses the searches")
    func analysisIsCached() async throws {
        let played = try game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
        // A small budget: this test is about the cache, not about depth.
        let settings = GameAnalyzer.Settings(
            maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10
        )

        try await withScratchStoreAsync {
            let first = GameReviewModel(game: played, mode: .twoPlayer)
            first.startAnalysis(settings: settings)
            while first.isAnalyzing { await Task.yield() }
            let original = try #require(first.analysis, "the first run produced no report")
            #expect(original.moves.count == played.history.count)
            first.teardown()

            let second = GameReviewModel(game: played, mode: .twoPlayer)
            second.startAnalysis(settings: settings)
            // No searching at all: a complete cache hit is applied inline.
            #expect(!second.isAnalyzing, "the second review searched again")
            #expect(second.progress == 1)
            let reused = try #require(second.analysis, "nothing came back from the cache")

            #expect(reused.moves.count == original.moves.count)
            for (cached, fresh) in zip(reused.moves, original.moves) {
                #expect(cached.bestMove == fresh.bestMove, "ply \(fresh.ply): a different best move")
                #expect(cached.bestScore == fresh.bestScore, "ply \(fresh.ply): a different score")
                #expect(cached.playedScore == fresh.playedScore, "ply \(fresh.ply): a different played score")
                #expect(cached.quality == fresh.quality, "ply \(fresh.ply): a different grade")
                #expect(cached.refutationSAN == fresh.refutationSAN, "ply \(fresh.ply): a different refutation")
            }
            #expect(reused.evalCurve == original.evalCurve)
            #expect(reused.white.accuracy == original.white.accuracy)
            #expect(reused.black.accuracy == original.black.accuracy)
            second.teardown()
        }
    }

    /// Half a review is worth keeping. Closing one part way through used to
    /// throw away everything it had searched.
    @Test("A review closed part way through keeps what it searched")
    func partialAnalysisIsKept() async throws {
        let played = try game([
            "e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6"
        ])
        let settings = GameAnalyzer.Settings(
            maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10
        )
        let fingerprint = AnalysisCache.fingerprint(game: played, settings: settings)

        try await withScratchStoreAsync {
            let interrupted = GameReviewModel(game: played, mode: .twoPlayer)
            interrupted.startAnalysis(settings: settings)
            // Let a few positions land, then close the review the way the view
            // does when it goes away.
            while interrupted.progress == 0, interrupted.isAnalyzing { await Task.yield() }
            interrupted.teardown()

            let saved = try #require(
                AnalysisCache.load(fingerprint: fingerprint),
                "closing the review stored nothing"
            )
            #expect(saved.completedCount > 0, "nothing of the run was kept")

            // And the run that follows starts from there rather than from zero.
            let resumed = GameReviewModel(game: played, mode: .twoPlayer)
            resumed.startAnalysis(settings: settings)
            #expect(resumed.progress > 0, "the second run ignored the stored half")
            while resumed.isAnalyzing { await Task.yield() }
            let report = try #require(resumed.analysis)
            #expect(report.moves.count == played.history.count, "the resumed run left gaps")
            resumed.teardown()
        }
    }

    /// The cache may only answer for the exact game and settings it was filled
    /// under: a different game, or a different node budget, is a different
    /// report and has to be searched.
    @Test("The cache does not answer for a different game or budget")
    func cacheIsKeyedOnGameAndSettings() throws {
        let played = try game(["e2e4", "e7e5", "g1f3"])
        let other = try game(["d2d4", "d7d5", "g1f3"])
        let settings = GameAnalyzer.Settings(
            maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10
        )
        let deeper = GameAnalyzer.Settings(
            maxDepth: 4, nodesPerPosition: 40_000, timeLimitPerPosition: 10
        )

        let key = AnalysisCache.fingerprint(game: played, settings: settings)
        #expect(AnalysisCache.fingerprint(game: other, settings: settings) != key,
                "two different games share a cache key")
        #expect(AnalysisCache.fingerprint(game: played, settings: deeper) != key,
                "two different node budgets share a cache key")
        // A prefix of the game is a different game too. The last entry of a
        // run is the final position, searched with no move to score, and in
        // the longer game that same position carries one — so the two runs
        // disagree about what that entry holds.
        let prefix = try game(["e2e4", "e7e5"])
        #expect(AnalysisCache.fingerprint(game: prefix, settings: settings) != key,
                "a game and its prefix share a cache key")
    }

    /// Most games end in mate, and the position they end on has no legal move
    /// — nothing to search, and nothing the analyzer hands back. That blank is
    /// the one entry the cache cannot record, so the review has to know it
    /// needs no searching rather than starting a run for it every time.
    @Test("A game that ended in mate reopens without searching again")
    func aMatedGameIsFullyCached() async throws {
        // Fool's mate: the last position has no legal move at all.
        let played = try game(["f2f3", "e7e5", "g2g4", "d8h4"])
        #expect(played.board.generateLegalMoves().isEmpty, "the game is not a mate")
        let settings = GameAnalyzer.Settings(
            maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10
        )

        try await withScratchStoreAsync {
            let first = GameReviewModel(game: played, mode: .twoPlayer)
            first.startAnalysis(settings: settings)
            while first.isAnalyzing { await Task.yield() }
            #expect(first.progress == 1)
            first.teardown()

            let second = GameReviewModel(game: played, mode: .twoPlayer)
            second.startAnalysis(settings: settings)
            #expect(!second.isAnalyzing, "the mated position sent it searching again")
            #expect(second.progress == 1)
            let reused = try #require(second.analysis, "nothing came back from the cache")
            #expect(reused.moves.count == played.history.count, "the report has gaps")
            // The mate has no answer, so the move that gave it has no
            // refutation — which is exactly the blank being reasoned about.
            #expect(reused.moves.last?.refutation == nil, "a mated side was given a move")
            second.teardown()
        }
    }

    /// The store is bounded, so it cannot grow with every game ever reviewed —
    /// and what it drops when it fills up has to be the oldest entry, not the
    /// one the player is most likely to open again.
    @Test("The store keeps the newest reviews and no more")
    func theStoreIsBoundedAndKeepsTheNewest() async throws {
        try await withScratchStoreAsync {
            let position = CachedPosition(PositionAnalysis(
                bestMove: try #require(Board.initial.generateLegalMoves().first),
                bestScore: 20, focusScore: nil, hasCloseAlternative: true,
                legalMoveCount: 20, depth: 4, nodes: 1000
            ))
            let count = AnalysisCache.maxGames + 2
            for index in 0..<count {
                AnalysisCache.save(CachedGameAnalysis(
                    fingerprint: "game\(index)",
                    positions: [position],
                    // Written oldest first, a second apart, so "newest" is not
                    // the same thing as "written last by accident".
                    updatedAt: Date(timeIntervalSince1970: Double(index))
                ))
            }

            let kept = AnalysisCache.load()
            #expect(kept.count == AnalysisCache.maxGames, "the store is not bounded")
            let fingerprints = Set(kept.map(\.fingerprint))
            for index in (count - AnalysisCache.maxGames)..<count {
                #expect(fingerprints.contains("game\(index)"), "game\(index) was dropped")
            }
            #expect(!fingerprints.contains("game0"), "the oldest review was kept")

            // An entry with nothing searched in it must not push a real one out.
            AnalysisCache.save(CachedGameAnalysis(
                fingerprint: "empty", positions: [nil, nil], updatedAt: Date()
            ))
            #expect(Set(AnalysisCache.load().map(\.fingerprint)) == fingerprints,
                    "an empty entry displaced a real one")
        }
    }

    /// A scratch defaults suite, so a test's cached analysis never turns up in
    /// a review on the developer's simulator — and so one test's cache is not
    /// visible to the next.
    private func withScratchStoreAsync(_ body: () async throws -> Void) async rethrows {
        let suiteName = "chessTests.GameReviewModelTests"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not open the scratch defaults suite")
            return
        }
        scratch.removePersistentDomain(forName: suiteName)
        let store = LocalStore.defaults
        LocalStore.defaults = scratch
        defer {
            LocalStore.defaults = store
            scratch.removePersistentDomain(forName: suiteName)
        }
        try await body()
    }
}

// MARK: - Notation

@Suite("Notation")
struct MoveNotationTests {

    /// The Czech letters, so the mapping is exercised whatever language the
    /// test host happens to run in.
    nonisolated static let czech: [Character: Character] = [
        "K": "K", "Q": "D", "R": "V", "B": "S", "N": "J"
    ]

    nonisolated struct Case: CustomStringConvertible {
        let english: String
        let czech: String
        var description: String { "\(english) → \(czech)" }
    }

    nonisolated static let cases: [Case] = [
        Case(english: "e4", czech: "e4"),             // a pawn move names no piece
        Case(english: "Nf3", czech: "Jf3"),
        Case(english: "Qxd8+", czech: "Dxd8+"),
        Case(english: "Rae1", czech: "Vae1"),
        Case(english: "Bb5", czech: "Sb5"),
        Case(english: "Kg1", czech: "Kg1"),
        Case(english: "O-O", czech: "O-O"),           // castling is not a piece letter
        Case(english: "O-O-O", czech: "O-O-O"),
        Case(english: "e8=Q", czech: "e8=D"),         // what a pawn becomes is a piece letter
        Case(english: "bxa8=N#", czech: "bxa8=J#"),   // ...even after a capture, before the mate mark
        Case(english: "exd6", czech: "exd6"),         // a file letter is never a piece letter
        Case(english: "N1d2", czech: "J1d2"),         // rank disambiguation
        Case(english: "Nbxd7", czech: "Jbxd7"),       // file disambiguation on a capture
    ]

    @Test("Piece letters follow the language, everything else is left alone", arguments: cases)
    func lettersAreRewritten(testCase: Case) {
        #expect(MoveNotation.display(testCase.english, letters: Self.czech) == testCase.czech)
    }

    @Test("A language that writes the English letters changes nothing", arguments: cases)
    func identityMappingIsAPassThrough(testCase: Case) {
        #expect(MoveNotation.display(testCase.english, letters: [:]) == testCase.english)
    }

    @Test("What the app actually shows is stable for pawn moves")
    func displayLeavesPawnMovesAlone() {
        // True in every language: a pawn move carries no piece letter at all.
        #expect(MoveNotation.display("e4") == "e4")
        #expect(MoveNotation.display("exd5") == "exd5")
    }
}

// MARK: - Evaluation text

@Suite("Evaluation text")
struct EvalFormatTests {

    /// What a figure that has rounded to nothing looks like, and what the
    /// spoken form says about it. Both are read out of the formatter rather
    /// than written down here, so these tests say the same thing on a host
    /// whose language writes "0,0" and calls a level position something else.
    static let zero = EvalFormat.text(centipawns: 0)
    static let levelPhrase = EvalFormat.spoken(centipawns: 0)

    /// Every centipawn value around the boundary, plus a few real ones.
    static let centipawns: [Int] = Array(-60...60) + [120, -150, 940, -940]

    @Test("A figure that has rounded to nothing is never given a sign")
    func noSignedZero() {
        // "+0.0" beside a dead draw, and "-0.0" for a four-centipawn edge, put
        // a sign in front of a number that says the position does not lean.
        #expect(!Self.zero.hasPrefix("+"))
        #expect(!Self.zero.hasPrefix("-"))
        for centipawns in Self.centipawns {
            let text = EvalFormat.text(centipawns: centipawns)
            #expect(text != "+" + Self.zero, "signed zero at \(centipawns) centipawns")
            #expect(text != "-" + Self.zero, "signed zero at \(centipawns) centipawns")
        }
    }

    @Test("The pill and what VoiceOver says agree on whether it is level")
    func pillAndSpeechAgree() {
        for centipawns in Self.centipawns {
            let looksLevel = EvalFormat.text(centipawns: centipawns) == Self.zero
            let saysLevel = EvalFormat.spoken(centipawns: centipawns) == Self.levelPhrase
            #expect(looksLevel == saysLevel, "disagreement at \(centipawns) centipawns")
        }
    }

    @Test("The boundary is where the figure rounds away, not a centipawn cutoff")
    func boundaryFollowsTheFormatter() {
        // The case a plain cutoff got wrong: five centipawns passes a "< 5"
        // test, and the formatter then rounds it to zero anyway, so the signed
        // zero came straight back.
        #expect(EvalFormat.text(centipawns: 5) == Self.zero)
        #expect(EvalFormat.text(centipawns: -5) == Self.zero)
        #expect(EvalFormat.text(centipawns: 6) != Self.zero)
        #expect(EvalFormat.text(centipawns: -6) != Self.zero)
    }

    @Test("A real advantage keeps its sign, and a mate is still a mate")
    func realValuesAreUnchanged() {
        #expect(EvalFormat.text(centipawns: 150).hasPrefix("+"))
        #expect(EvalFormat.text(centipawns: -150).hasPrefix("-"))
        #expect(EvalFormat.text(centipawns: SearchScore.mate - 5) == "M3")
        #expect(EvalFormat.text(centipawns: -(SearchScore.mate - 5)) == "-M3")
    }
}

// MARK: - Opening book

@Suite("Opening book")
struct OpeningBookTests {

    /// The book stores its names as `LocalizedStringResource`, so they follow
    /// the reader's language rather than whichever one the table was first
    /// touched in. `match` hands back words; resolve the same way it does so
    /// the two can be compared whatever language the tests run in.
    private func bookName(of moves: [String]) -> String? {
        OpeningBook.lines.first { $0.moves == moves }.map { String(localized: $0.name) }
    }

    @Test("A finished line names the opening")
    func namesACompletedLine() {
        let match = OpeningBook.match(sans: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4"])
        #expect(match.name == bookName(of: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4"]))
        #expect(match.bookPlies == 7)
    }

    @Test("A line the game has not finished does not name it")
    func doesNotNameAnUnfinishedLine() {
        // Four moves into the Najdorf it is still only a Sicilian.
        let match = OpeningBook.match(sans: ["e4", "c5", "Nf3"])
        #expect(match.name == bookName(of: ["e4", "c5"]))
        #expect(match.bookPlies == 3, "the third move still agrees with the Open Sicilian")
    }

    @Test("Leaving theory stops the book count where it left")
    func stopsCountingWhenTheoryEnds() {
        let match = OpeningBook.match(sans: ["e4", "e5", "Qh5", "Nc6", "Bc4"])
        #expect(match.bookPlies == 2, "Qh5 is in no line in the book")
        #expect(match.name == bookName(of: ["e4", "e5"]))
    }

    @Test("Leaving a line on its last move still credits the moves before it")
    func creditsThePrefixOfALineLeftLate() {
        // Eight plies of the Closed Ruy López, then d3 where the line has O-O.
        // Ba4 and Nf6 were theory whatever came after them; a match that
        // demanded the whole overlap threw them out and answered 6, and the
        // review then graded two book moves.
        let match = OpeningBook.match(sans: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6", "d3"])
        #expect(match.bookPlies == 8)
        #expect(match.name == bookName(of: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"]),
                "only a line played to its end may name the opening")
    }

    @Test("Check and mate marks do not stop a line from matching")
    func ignoresCheckMarks() {
        #expect(OpeningBook.match(sans: ["e4", "e5", "Nf3+"]).bookPlies == 3)
    }

    @Test("An empty game matches nothing")
    func emptyGameMatchesNothing() {
        let match = OpeningBook.match(sans: [])
        #expect(match.name == nil)
        #expect(match.bookPlies == 0)
    }

    @Test("A line written without a check mark still matches a game that gives check")
    func checkMarksDoNotStopALineFromBeingNamed() {
        // The book writes the Bogo-Indian's last move "Bb4"; over the board it
        // is Bb4+, and `match` is what has to reconcile the two.
        let bogoIndian = ["d4", "Nf6", "c4", "e6", "Nf3", "Bb4"]
        let match = OpeningBook.match(sans: ["d4", "Nf6", "c4", "e6", "Nf3", "Bb4+"])
        #expect(match.bookPlies == 6)
        #expect(match.name == bookName(of: bogoIndian))
    }

    /// A line the engine cannot produce is a line no game will ever match, so
    /// the opening it names would be dead code. Book lines carry no check or
    /// mate marks by design — `match` strips those from the played moves — so
    /// they are stripped here too, and then the line must actually be named.
    @Test("Every line in the book is playable and names its opening")
    func everyLineIsPlayableAndNamed() throws {
        func withoutCheckMarks(_ san: String) -> String {
            san.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "#", with: "")
        }

        for line in OpeningBook.lines {
            let name = String(localized: line.name)
            var game = Game()
            var played: [String] = []
            for san in line.moves {
                let move = game.legalMoves.first { withoutCheckMarks(game.board.san(for: $0)) == san }
                #expect(move != nil, "\(name): no legal \(san) after \(played)")
                guard let move else { break }
                played.append(game.board.san(for: move))
                game.play(move)
            }
            guard played.count == line.moves.count else { continue }

            let match = OpeningBook.match(sans: played)
            #expect(match.name != nil, "\(name) is unreachable: playing it names nothing")
            #expect(
                match.bookPlies == line.moves.count,
                "\(name): played \(line.moves.count) book moves but only \(match.bookPlies) counted"
            )
        }
    }

    // MARK: Playing out of the book

    @Test("Theory offers continuations from the start and runs out when it ends")
    func continuationsFollowTheory() {
        #expect(!OpeningBook.continuations(after: []).isEmpty)
        #expect(OpeningBook.continuations(after: ["e4", "e5"]).contains { $0.san == "Nf3" })
        #expect(
            OpeningBook.continuations(after: ["h3", "a6"]).isEmpty,
            "the book answered a game it has never seen"
        )
        // A completed line that nothing extends is the end of the road.
        if let deepest = OpeningBook.lines.max(by: { $0.moves.count < $1.moves.count }) {
            #expect(OpeningBook.continuations(after: deepest.moves).isEmpty)
        }
    }

    @Test("A book move is one of the position's own legal moves")
    func bookMovesAreLegal() throws {
        var game = Game()
        var played = 0
        while !OpeningBook.continuations(after: game.history.map(\.san)).isEmpty {
            let move = try #require(
                OpeningBook.move(
                    after: game.history.map(\.san), in: game.board,
                    randomSeed: UInt64(played) &* 6_364_136_223_846_793_005 &+ 3
                ),
                "the book offered theory it then declined to name a move for"
            )
            #expect(game.legalMoves.contains(move), "illegal book move \(move.uci) at ply \(played)")
            game.play(move)
            played += 1
        }
        // Depth is the luck of which line came up and is held to a mean in
        // `SearchTests.topLevelsPlayTheory`; what matters here is that every
        // move the book handed over was one this position could actually play.
        #expect(played >= 1, "the book had nothing to say about the starting position")
        #expect(OpeningBook.match(sans: game.history.map(\.san)).bookPlies == played)
    }

    /// The book is matched by SAN against the position in front of it, so a
    /// board its lines cannot be played on has to be declined rather than
    /// trusted — otherwise an empty history would have it offering 1.e4 in an
    /// endgame.
    @Test("A position the book's lines do not fit is declined")
    func bookDeclinesAPositionItDoesNotFit() throws {
        let board = try #require(Board(fen: "8/8/4k3/8/8/4K3/8/8 w - - 0 1"))
        #expect(!OpeningBook.continuations(after: []).isEmpty, "the book has first moves to offer")
        #expect(OpeningBook.move(after: [], in: board, randomSeed: 5) == nil)
    }

    @Test("The same seed always picks the same book move")
    func bookPickIsDeterministic() {
        let board = Board.initial
        let first = OpeningBook.move(after: [], in: board, randomSeed: 12_345)
        let second = OpeningBook.move(after: [], in: board, randomSeed: 12_345)
        #expect(first == second)
    }

    /// The weighting is the whole reason the pick is not uniform. Eleven first
    /// moves are named and seven of them are a single one-move line each — a
    /// name in a dictionary, not an opening the book can continue. Sharing the
    /// chance out equally had the top level opening 1.b3 as often as 1.e4.
    @Test("A book move is picked in proportion to the theory behind it")
    func bookPickFollowsItsWeights() {
        let theory = OpeningBook.continuations(after: [])
        let total = theory.reduce(0) { $0 + $1.lines }
        let board = Board.initial
        let legal = board.generateLegalMoves()
        let samples = 20_000

        var counts: [String: Int] = [:]
        for seed in 0..<samples {
            guard let move = OpeningBook.move(
                after: [], in: board,
                randomSeed: UInt64(seed) &* 6_364_136_223_846_793_005 &+ 1
            ) else { continue }
            counts[board.san(for: move, legalMoves: legal), default: 0] += 1
        }
        #expect(counts.values.reduce(0, +) == samples, "the book declined a position it has lines for")

        for continuation in theory {
            let expected = Double(continuation.lines) / Double(total)
            let observed = Double(counts[continuation.san] ?? 0) / Double(samples)
            #expect(
                abs(observed - expected) < 0.02,
                "\(continuation.san): weighted for \(expected) of the games, played \(observed)"
            )
        }

        // What the weighting buys: the moves the book can only name come up a
        // long way behind the one it has the most theory for.
        let mainline = theory.max { $0.lines < $1.lines }
        let namedOnly = theory.filter { $0.lines == 1 }
        #expect(!namedOnly.isEmpty, "no single-line first moves left to hold this to")
        for continuation in namedOnly {
            let odd = counts[continuation.san] ?? 0
            let main = counts[mainline?.san ?? ""] ?? 0
            #expect(odd * 10 < main, "\(continuation.san) came up \(odd) times against \(main)")
        }
    }
}

// MARK: - Game board

/// The live board moves pieces one at a time so SwiftUI can animate them,
/// exactly the shortcut the review board takes — and exactly as liable to
/// drift away from the position it is meant to be showing. The review board
/// has been held to that invariant for a while; this holds the board people
/// actually play on to the same one.
@Suite("Game board render model")
@MainActor
struct GameViewModelTests {

    /// Drives `body` as if the app were running, without letting its side
    /// effects escape: `GameViewModel` saves every move it plays, and a fuzz
    /// game has no business turning up afterwards under "Continue". The saves
    /// go to a scratch suite that is wiped on both sides — saving into the real
    /// one and restoring afterwards left the fuzz game behind whenever a test
    /// died before its `defer` ran.
    private func withoutDisturbingTheApp(_ body: () -> Void) {
        let suiteName = "chessTests.GameViewModelTests"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not open the scratch defaults suite")
            return
        }
        scratch.removePersistentDomain(forName: suiteName)
        // Written into the suite, not just onto the singletons: `AppSettings`
        // reads the store when a test builds one, and reading `true` back out
        // of an empty suite would switch the sounds straight on again.
        scratch.set(false, forKey: "soundsEnabled")
        scratch.set(false, forKey: "hapticsEnabled")
        let store = LocalStore.defaults
        LocalStore.defaults = scratch
        let sounds = SoundManager.shared.isEnabled
        let haptics = Haptics.isEnabled
        SoundManager.shared.isEnabled = false
        Haptics.isEnabled = false
        defer {
            SoundManager.shared.isEnabled = sounds
            Haptics.isEnabled = haptics
            LocalStore.defaults = store
            scratch.removePersistentDomain(forName: suiteName)
        }
        body()
    }

    /// Every piece the board draws, on the square the real position has it —
    /// and nothing drawn twice on one square. The fading ghosts of captures
    /// live in `dyingPieces` and are deliberately not part of this.
    private func expectBoardIsDrawnCorrectly(
        _ model: GameViewModel, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var drawn = [UInt8](repeating: 0, count: 64)
        for rendered in model.pieces {
            #expect(
                drawn[rendered.square.index] == 0,
                "\(context): two pieces drawn on \(rendered.square)",
                sourceLocation: sourceLocation
            )
            drawn[rendered.square.index] = rendered.piece.packed
        }
        #expect(
            drawn == model.game.board.squares,
            "\(context): the drawn pieces are not the position after \(model.game.history.count) plies",
            sourceLocation: sourceLocation
        )
    }

    /// Plays a move the way tapping the board does: tap the piece, tap where
    /// it should go, and answer the promotion picker when it opens.
    private func tap(
        _ model: GameViewModel, _ move: Move,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        if model.pendingPromotion != nil {
            model.completePromotion(with: move.promotion ?? .queen)
        }
        #expect(
            model.game.lastMove == move,
            "the board would not play \(move.uci)",
            sourceLocation: sourceLocation
        )
    }

    private func model(_ fen: String = Board.startFEN, settings: AppSettings) -> GameViewModel {
        GameViewModel(mode: .twoPlayer, settings: settings, restoredGame: Game(fen: fen))
    }

    @Test("Castling and en passant leave the drawn board matching the position")
    func specialMovesAreDrawnCorrectly() throws {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            // 1.e4 e6 2.e5 d5 3.exd6 cxd6 4.Nf3 Nf6 5.Bc4 Be7 6.O-O O-O
            for uci in ["e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
                        "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"] {
                guard let move = model.game.legalMoves.first(where: { $0.uci == uci }) else {
                    Issue.record("no legal \(uci)")
                    return
                }
                tap(model, move)
                expectBoardIsDrawnCorrectly(model, "after \(uci)")
            }
            #expect(model.game.history.contains { $0.move.isEnPassant })
            #expect(model.game.history.count { $0.move.isCastle } == 2)
        }
    }

    @Test("Every promotion the picker offers is drawn as the piece it made")
    func promotionsAreDrawnCorrectly() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                let model = model("1n5k/P6p/8/8/8/8/6P1/6K1 w - - 0 1", settings: settings)
                guard let move = model.game.legalMoves.first(where: {
                    $0.uci == "a7b8" + kind.letter.lowercased()
                }) else {
                    Issue.record("no promotion to \(kind)")
                    return
                }
                tap(model, move)
                expectBoardIsDrawnCorrectly(model, "after promoting to \(kind)")
                #expect(model.pieces.contains { $0.square.algebraic == "b8" && $0.piece.kind == kind })
            }
        }
    }

    /// Breadth rather than depth, the same way the review board is swept:
    /// games from a fixed seed, biased towards the moves that make the render
    /// model interesting.
    @Test("Twenty games play out without the drawn board drifting")
    func randomGamesAreDrawnCorrectly() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // Picked because it reaches all three awkward move kinds within
            // the sample, which the check at the bottom then insists on.
            var rng = Zobrist.SplitMix64(seed: 0xA11CE)
            var promotions = 0, enPassants = 0, castles = 0

            for index in 0..<20 {
                let model = model(settings: settings)
                while !model.game.outcome.isGameOver && model.game.history.count < 80 {
                    let legal = model.game.legalMoves
                    guard !legal.isEmpty else { break }
                    let promoting = legal.filter { $0.promotion != nil }
                    let capturing = legal.filter { $0.isCapture }
                    let pool = !promoting.isEmpty && rng.next() % 2 == 0 ? promoting
                        : (!capturing.isEmpty && rng.next() % 3 != 0 ? capturing : legal)
                    let move = pool[Int(rng.next() % UInt64(pool.count))]

                    if move.promotion != nil { promotions += 1 }
                    if move.isEnPassant { enPassants += 1 }
                    if move.isCastle { castles += 1 }

                    tap(model, move)
                    expectBoardIsDrawnCorrectly(model, "game \(index) after \(move.uci)")
                }
            }

            // The sweep is worthless if it never reached the awkward moves.
            #expect(promotions > 0, "no promotion in the sample")
            #expect(enPassants > 0, "no en passant in the sample")
            #expect(castles > 0, "no castling in the sample")
        }
    }

    @Test("A promotion square is offered one marker, not one per piece")
    func promotionOffersOneMarkerPerSquare() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // A pawn on b7 with a rook to take on either side: three squares
            // on offer, twelve moves that reach them.
            let model = model("r1r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1", settings: settings)
            model.handleTap(on: Square(algebraic: "b7")!)

            #expect(model.legalTargets.count == 12, "twelve promotion moves")
            #expect(model.legalTargetSquares.count == 3, "drawn once per square")
            #expect(Set(model.legalTargetSquares.map(\.to.algebraic)) == ["a8", "b8", "c8"])
            // Stacking four translucent markers on one square makes it read as
            // a different, far bolder kind of dot than every other target.
            #expect(
                Set(model.legalTargetSquares.map(\.to.index)).count
                    == model.legalTargetSquares.count,
                "one marker per square"
            )
            #expect(model.legalTargetSquares.filter(\.isCapture).count == 2)
        }
    }

    @Test("An ordinary move offers one marker per square too")
    func ordinaryMovesOfferOneMarkerPerSquare() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            model.handleTap(on: Square(algebraic: "e2")!)
            #expect(model.legalTargets.count == 2)
            #expect(model.legalTargetSquares.count == 2, "no square deduplicated away")
        }
    }

    /// The guide has always listed agreement among the five ways a game is
    /// drawn, and for a while it was the one the app had no way to reach: the
    /// outcome, its headline and its Czech existed, but nothing could produce
    /// it. These pin the door open.
    @Test("Two players can settle for a draw")
    func twoPlayersCanAgreeToADraw() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            tap(model, model.game.legalMoves.first { $0.uci == "e2e4" }!)

            #expect(model.canAgreeToDraw)
            model.agreeToDraw()

            #expect(model.game.outcome == .drawAgreed)
            #expect(model.game.outcome.isDraw)
            // The board is done with, the same way resigning leaves it.
            #expect(model.selectedSquare == nil)
            #expect(model.legalTargets.isEmpty)
            #expect(!model.canAgreeToDraw, "an agreed game cannot be agreed again")
            // And it is reviewable: the moves played are still there to grade.
            #expect(FinishedGame.load()?.outcome == .drawAgreed)
            #expect(SavedGame.load() == nil, "a finished game is not on offer to continue")
        }
    }

    /// Against the computer, Undo has to land on the human's turn — it used to
    /// get there by taking one ply back at a time and asking after each whose
    /// turn it now was. It counts the plies up front instead, so the takeback
    /// is one replay of the game rather than one per ply, and this is what
    /// holds the new arithmetic to the old answer. Both colours, because the
    /// count is one ply in the middle of the game and two at its edges.
    @Test("Undo against the computer stops on the human's turn",
          arguments: [PieceColor.white, .black])
    func undoLandsOnTheHumansTurn(playerColor: PieceColor) {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // Both lines leave the human on turn, so building the model starts
            // no search and neither does the undo.
            let ucis = playerColor == .white
                ? ["e2e4", "e7e5", "g1f3", "b8c6"]
                : ["e2e4", "e7e5", "g1f3"]
            var game = Game()
            for uci in ucis {
                guard let move = game.legalMoves.first(where: { $0.uci == uci }) else {
                    Issue.record("no legal \(uci)")
                    return
                }
                game.play(move)
            }

            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: playerColor),
                settings: settings,
                restoredGame: game
            )
            #expect(model.game.sideToMove == playerColor, "the setup is not the human's turn")
            #expect(model.canUndo)

            model.undo()

            #expect(model.game.sideToMove == playerColor,
                    "undo left it the computer's turn")
            #expect(model.game.history.count == ucis.count - 2,
                    "took \(ucis.count - model.game.history.count) plies back, not two")
            #expect(!model.aiThinking)
            expectBoardIsDrawnCorrectly(model, "after undo")
            model.teardown()
        }
    }

    @Test("Against the computer there is nobody to agree with")
    func theComputerIsNotOfferedADraw() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // White is the human and is on turn, so no search starts here.
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white),
                settings: settings
            )
            #expect(!model.canAgreeToDraw, "the button is not offered")
            model.agreeToDraw()
            #expect(model.game.outcome == .ongoing, "and calling it anyway changes nothing")
            model.teardown()
        }
    }
}

// MARK: - Tutorial content

/// The guide's positions are hand-written FENs, and a diagram with a typo in
/// it fails quietly: a rank shifted by one file still draws a board, just the
/// wrong one, and a focus square naming an empty square draws a lesson with no
/// moves on it. Nothing else in the app reads these, so nothing else would
/// notice.
@Suite("Tutorial content")
struct TutorialContentTests {

    nonisolated struct Diagram: CustomTestStringConvertible {
        let chapter: String
        let page: Int
        let diagram: TutorialDiagram
        var testDescription: String { "\(chapter) page \(page)" }
    }

    nonisolated static let diagrams: [Diagram] = TutorialGuide.chapters.flatMap { chapter in
        chapter.pages.enumerated().compactMap { index, page in
            page.diagram.map { Diagram(chapter: chapter.id, page: index + 1, diagram: $0) }
        }
    }

    @Test("Every diagram's FEN describes a whole board", arguments: diagrams)
    func fenCoversEveryRankAndFile(entry: Diagram) throws {
        let field = try #require(entry.diagram.fen.split(separator: " ").first, "empty FEN")
        let ranks = field.split(separator: "/")
        #expect(ranks.count == 8, "\(ranks.count) ranks in \(entry.diagram.fen)")
        for (row, rank) in ranks.enumerated() {
            var files = 0
            for character in rank {
                if let skip = character.wholeNumberValue, (1...8).contains(skip) {
                    files += skip
                } else if Piece(fenCharacter: character) != nil {
                    files += 1
                } else {
                    Issue.record("rank \(8 - row) of \(entry.diagram.fen) has junk '\(character)' in it")
                }
            }
            #expect(files == 8, "rank \(8 - row) of \(entry.diagram.fen) covers \(files) files")
        }
    }

    @Test("Every square a diagram points at is a real square", arguments: diagrams)
    func squaresAreReal(entry: Diagram) {
        let diagram = entry.diagram
        if diagram.focus != nil {
            #expect(diagram.focusSquare != nil, "focus '\(diagram.focus!)' is not a square")
        }
        #expect(
            diagram.highlightSquares.count == diagram.highlights.count,
            "a highlight is not a square: \(diagram.highlights)"
        )
        for arrow in diagram.arrows {
            #expect(arrow.squares != nil, "arrow \(arrow.from)-\(arrow.to) is not a pair of squares")
        }
    }

    /// A lesson that offers a piece's moves has to have that piece, in a
    /// position the engine will read, belonging to the side on turn. Get any
    /// of the three wrong and the lesson silently shows a board with no dots.
    @Test("A diagram that offers moves really has a piece to move", arguments: diagrams)
    func focusedDiagramsOfferMoves(entry: Diagram) throws {
        guard let focus = entry.diagram.focusSquare else { return }
        let board = try #require(
            Board(fen: entry.diagram.fen),
            "a diagram with a focus square must be a position the engine reads: \(entry.diagram.fen)"
        )
        let piece = try #require(board.piece(at: focus), "nothing stands on \(focus)")
        #expect(
            piece.color == board.sideToMove,
            "\(focus) holds a \(piece.color) piece but \(board.sideToMove) is to move"
        )

        let hasMoves = !board.legalMoves(from: focus).isEmpty
        if Self.deliberatelyStuck.contains(entry.testDescription) {
            #expect(!hasMoves, "\(entry.testDescription) is listed as a piece that cannot move, but it can")
        } else {
            #expect(hasMoves, "\(focus) can move nowhere, so the lesson shows a board with no dots")
        }
    }

    /// The four lessons whose whole point is a piece that cannot move. Listing
    /// them by name is what lets every other diagram be held to the opposite
    /// rule instead of the test having to guess which silence is intended.
    nonisolated static let deliberatelyStuck: Set<String> = [
        "check page 3",     // back-rank checkmate
        "check page 4",     // stalemate
        "tactics page 2",   // a knight pinned to its king
        "strategy page 6",  // checkmate with the king walked in
    ]

    /// How big the guide is, is quoted in prose that cannot be generated from
    /// it: the contents screen opens with "Nine short lessons cover every rule
    /// of the game" and the README advertises the pages, the diagrams and how
    /// many of them are playable. Growing the guide is fine — leaving those
    /// two sentences behind is not, and nothing else in the app would notice.
    @Test("The guide is the size the prose says it is")
    func guideMatchesWhatIsAdvertised() {
        #expect(
            TutorialGuide.chapters.count == 9,
            "the contents screen says nine lessons, and the README a 9-chapter guide"
        )
        #expect(
            TutorialGuide.chapters.reduce(0) { $0 + $1.pages.count } == 38,
            "the README says 38 pages"
        )
        #expect(Self.diagrams.count == 27, "the README says 27 board diagrams")
        // Playable means a focus square whose piece really has moves, which is
        // every focused diagram bar the four that are stuck on purpose.
        let focused = Self.diagrams.filter { $0.diagram.focus != nil }
        #expect(focused.count == Self.deliberatelyStuck.count + 15,
                "the README says 15 of the diagrams are playable")
    }
}
