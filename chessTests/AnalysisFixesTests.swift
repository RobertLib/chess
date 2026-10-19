//
//  AnalysisFixesTests.swift
//  chessTests
//
//  One test per fault found in the review and what it leaves behind, each
//  written to fail on the code as it was: the one way out of a forking check
//  graded brilliant, a cache that went on serving 1.0's grades, searches the
//  clock cut short kept as though the budget had ended them, and fixed
//  mistakes that came back every time an old game was looked at again.
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

/// Small budget, as in the other review suites: these tests care about which
/// grade a move gets, not about depth.
private let quick = GameAnalyzer.Settings(maxDepth: 6, nodesPerPosition: 40_000, timeLimitPerPosition: 5)

// MARK: - Brilliancies

@Suite("Fixes: brilliancies")
struct BrilliancyFixesTests {

    /// Black's pawn has just taken on d3 with check, forking the king on e2
    /// and the queen on c2. Each of the four king moves leaves the queen to
    /// dxc2; Qxd3 gives it up for the pawn and the bishop that takes it back.
    /// By exchange that is 470 thrown away, and the review called it brilliant
    /// — and unlocked the achievement for it.
    private let fork = "4k1n1/n2p3r/4ppN1/pb5p/1q2PBP1/3p4/1PQNKP1P/R4BR1 w - - 0 27"

    private func sacrifice(_ uci: String, in fen: String) throws -> Int {
        let board = try #require(Board(fen: fen))
        let move = try #require(board.generateLegalMoves().first { $0.uci == uci }, "no legal \(uci)")
        return GameAnalyzer.sacrifice(of: move, in: board)
    }

    @Test("The one way out of a forking check is not a brilliancy")
    func forcedCaptureOutOfCheck() throws {
        let game = try played(["c2d3"], from: fork)
        let jobs = GameAnalyzer.positions(of: game)
        try #require(jobs[0].board.isInCheck)
        // At the settings the review really uses, which is where it was
        // found. Only the position Qxd3 was played in is searched: its grade
        // does not depend on the one after it.
        let searched = GameAnalyzer.run(jobs[0], settings: .standard)
        let analysis = GameAnalyzer.assemble(game: game, jobs: jobs, results: [searched, nil])
        let qxd3 = try #require(analysis.moves.first)

        try #require(qxd3.isBestMove, "the engine preferred \(qxd3.bestSAN)")
        #expect(qxd3.quality != .brilliant, "Qxd3 graded brilliant, \(qxd3.playedScore) for \(qxd3.sacrifice)")
        #expect(qxd3.sacrifice == 0, "a queen the check had already lost counted as \(qxd3.sacrifice) given up")
    }

    @Test("A sacrifice is not brilliant out of check, as a recapture, or with next to no choice")
    func forcedSacrificesAreNotBrilliant() {
        func grade(isRecapture: Bool = false, wasInCheck: Bool = false, legalMoveCount: Int = 30) -> MoveQuality {
            GameAnalyzer.classify(
                bestScore: 60, playedScore: 60, isBest: true, hasCloseAlternative: true,
                sacrifice: 300, legalMoveCount: legalMoveCount, isRecapture: isRecapture,
                wasInCheck: wasInCheck, isBook: false
            )
        }
        // The same sacrifice with a free choice is still brilliant.
        #expect(grade() == .brilliant)
        #expect(grade(wasInCheck: true) == .best)
        #expect(grade(isRecapture: true) == .best)
        #expect(grade(legalMoveCount: 3) == .best)
    }

    @Test("A piece that was lost wherever it went is not sacrificed")
    func lostPiecesAreNotSacrificed() throws {
        // The queen above: every other move leaves it to the pawn.
        #expect(try sacrifice("c2d3", in: fork) == 0)
        // A knight shut in the corner by the rook on h8 — b6 is covered by
        // the a-pawn, c7 by the king. Taking the c-pawn on the way out is the
        // best of a bad job, not an offer.
        #expect(try sacrifice("a8c7", in: "N6r/p1pk4/8/8/8/8/8/6K1 w - - 0 1") == 0)
    }

    @Test("A piece that could have been saved, or was never attacked, is sacrificed in full")
    func realSacrificesCountInFull() throws {
        let knightForPawn = PieceKind.knight.centipawns - PieceKind.pawn.centipawns
        let bishopForPawn = PieceKind.bishop.centipawns - PieceKind.pawn.centipawns
        // The d-pawn attacks the knight, but it is free to retreat, so Nxf7
        // gives it up all the same.
        #expect(try sacrifice("e5f7", in: "4k3/5p2/3p4/4N3/8/8/8/4K3 w - - 0 1") == knightForPawn)
        // Bxf7+ in the Italian: nothing attacked the bishop on c4.
        #expect(try sacrifice(
            "c4f7", in: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1"
        ) == bishopForPawn)
    }

    /// Légal's: 5.Nxe5!, which lets the queen go to Bxd1 for Bxf7+ Ke7 Nd5#.
    @Test("A sacrifice that works is still brilliant")
    func legalsSacrificeIsBrilliant() throws {
        let game = try played(["f3e5"], from: "rn1qkbnr/ppp2p1p/3p2p1/4p3/2B1P1b1/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 0 5")
        let jobs = GameAnalyzer.positions(of: game)
        let analysis = GameAnalyzer.assemble(
            game: game, jobs: jobs, results: jobs.map { GameAnalyzer.run($0, settings: quick) }
        )
        let nxe5 = try #require(analysis.moves.first)
        #expect(nxe5.quality == .brilliant, "graded \(nxe5.quality), \(nxe5.playedScore) for \(nxe5.sacrifice)")
    }
}

// MARK: - Searches cut short

@Suite("Fixes: searches cut short")
struct CutShortFixesTests {

    private let start = Board.initial

    private func analyse(
        maxDepth: Int = 30, nodeBudget: Int = 50_000_000, timeLimit: TimeInterval = 60,
        cancellation: SearchCancellation? = nil
    ) throws -> PositionAnalysis {
        try #require(analyzePosition(
            board: start, gameHashes: [start.zobrist], maxDepth: maxDepth,
            nodeBudget: nodeBudget, timeLimit: timeLimit, cancellation: cancellation
        ))
    }

    /// The time limit counts the time the app spends suspended, so a search
    /// in flight when the player switched away comes back out of time. It
    /// still has an answer — the last depth it finished — which the review
    /// used to keep as the one the budget would have reached.
    @Test("A search the clock stops says so")
    func theClockCutsShort() throws {
        let analysis = try analyse(timeLimit: 0)
        #expect(analysis.isCutShort)
        #expect(analysis.depth < 30)
    }

    @Test("A search the caller stops says so too")
    func theCallerCutsShort() throws {
        let token = SearchCancellation()
        token.cancel()
        #expect(try analyse(cancellation: token).isCutShort)
    }

    @Test("A search the node budget or the depth cap ends is not cut short, and comes out the same every time")
    func theBudgetDoesNotCutShort() throws {
        let first = try analyse(nodeBudget: 30_000)
        let second = try analyse(nodeBudget: 30_000)
        #expect(!first.isCutShort)
        #expect(first.depth < 30, "the budget never bound")
        #expect(first.bestMove == second.bestMove)
        #expect(first.bestScore == second.bestScore)
        #expect(first.depth == second.depth)
        #expect(first.nodes == second.nodes)

        let capped = try analyse(maxDepth: 2)
        #expect(!capped.isCutShort)
        #expect(capped.depth == 2)
    }
}

/// Filed under the cache's own suite for the reason `cacheWritesAreSpacedOut`
/// is: it waits on the engine with a scratch store swapped in, and that suite
/// runs its tests one at a time.
extension GameAnalysisCacheTests {

    @Test("Searches the clock cut short are shown, but never cached")
    func cutShortSearchesAreNotCached() async throws {
        let game = try played(["e2e4", "e7e5", "g1f3", "b8c6"])
        // No time at all: every search is stopped by the clock at its first
        // look, long before a budget this size could end it.
        let settings = GameAnalyzer.Settings(maxDepth: 30, nodesPerPosition: 50_000_000, timeLimitPerPosition: 0)
        let suiteName = "chessTests.analysisCutShort"
        let scratch = try #require(UserDefaults(suiteName: suiteName))
        scratch.removePersistentDomain(forName: suiteName)
        await ScratchStoreLock.acquire()
        defer { ScratchStoreLock.release() }
        let store = LocalStore.defaults
        LocalStore.defaults = scratch
        let files = LocalStore.files
        defer {
            LocalStore.defaults = store
            scratch.removePersistentDomain(forName: suiteName)
            files.discard()
            Achievements.shared.justUnlocked = []
        }

        let model = GameReviewModel(game: game, mode: .twoPlayer)
        defer { model.teardown() }
        model.startAnalysis(settings: settings)
        #expect(model.isAnalyzing)
        while model.isAnalyzing { try await Task.sleep(for: .milliseconds(5)) }

        let report = try #require(model.analysis, "nothing was shown")
        #expect(report.moves.count == game.history.count, "the searches cut short were not shown")
        #expect(model.progress == 1)
        // Read from the scratch store itself: a test in another suite may
        // have swapped its own in for a moment.
        LocalStore.flush()
        #expect(files.read("analysisCache") == nil, "searches the clock cut short were cached")

        // So the next review of the game searches them again.
        let again = GameReviewModel(game: game, mode: .twoPlayer)
        defer { again.teardown() }
        again.startAnalysis(settings: settings)
        #expect(again.isAnalyzing, "the next review took the searches cut short as done")
    }
}

// MARK: - Cache revision

@Suite("Fixes: cache revision", .serialized)
@MainActor
struct CacheRevisionFixesTests {

    private let settings = GameAnalyzer.Settings(maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10)

    /// A complete review of `game`, every entry legal in the position it is
    /// filed under — so the only thing that can keep it from being reused is
    /// the fingerprint it is stored with.
    private func cachedReview(of game: Game, as fingerprint: String) -> CachedGameAnalysis {
        let positions: [CachedPosition?] = GameAnalyzer.positions(of: game).map { job in
            let legal = job.board.generateLegalMoves()
            return CachedPosition(PositionAnalysis(
                bestMove: job.playedMove ?? legal[0], bestScore: 0, focusScore: nil,
                hasCloseAlternative: true, legalMoveCount: legal.count, depth: 4, nodes: 1000
            ))
        }
        return CachedGameAnalysis(fingerprint: fingerprint, positions: positions, updatedAt: Date())
    }

    /// Writes the store as an older build left it — in UserDefaults, which
    /// the first read moves into its file — and has the cache read it afresh
    /// rather than answer from what it read before.
    private func storeAsLeft(_ entries: [CachedGameAnalysis]) throws {
        AnalysisCache.clear()
        LocalStore.defaults.set(try JSONEncoder().encode(entries), forKey: "analysisCache")
    }

    private func stored() throws -> [String]? {
        LocalStore.flush()
        guard let data = LocalStore.files.read("analysisCache") else { return nil }
        return try JSONDecoder().decode([CachedGameAnalysis].self, from: data).map(\.fingerprint)
    }

    @Test("A review cached by an older engine is not reused, and is dropped from the store")
    func olderRevisionsAreDropped() throws {
        let game = try played(["e2e4", "e7e5", "g1f3", "b8c6"])
        let current = AnalysisCache.fingerprint(game: game, settings: settings)
        let tag = "r\(AnalysisCache.engineRevision)|"
        try #require(current.hasPrefix(tag))
        // 1.0 and 1.0.1 both filed their reviews under revision 1, though
        // 1.0.1 no longer searched the way 1.0 had.
        #expect(AnalysisCache.engineRevision > 1)
        let older = "r1|" + current.dropFirst(tag.count)

        try withScratchStore("analysisRevision") {
            // Filed under this revision, the review is reused: the control.
            try storeAsLeft([cachedReview(of: game, as: current)])
            let reused = GameReviewModel(game: game, mode: .twoPlayer)
            reused.startAnalysis(settings: settings)
            #expect(!reused.isAnalyzing, "a review filed under this revision was searched again")
            reused.teardown()

            // Filed under revision 1, it is not found, and is gone from the
            // store the first time the store is read.
            let other = cachedReview(of: game, as: "other")
            try storeAsLeft([cachedReview(of: game, as: older), other])
            #expect(AnalysisCache.load(fingerprint: current) == nil)
            #expect(AnalysisCache.load().map(\.fingerprint) == ["other"])
            #expect(try stored() == ["other"], "the older review was left in the store")

            let searched = GameReviewModel(game: game, mode: .twoPlayer)
            searched.startAnalysis(settings: settings)
            #expect(searched.isAnalyzing, "a review cached by the older engine was reused")
            searched.teardown()

            // A store with nothing current left in it goes altogether.
            try storeAsLeft([cachedReview(of: game, as: older)])
            #expect(AnalysisCache.load().isEmpty)
            #expect(try stored() == nil, "a store of nothing but older reviews was kept")
        }
    }
}

// MARK: - Mistakes to fix

@Suite("Fixes: mistakes to fix", .serialized)
@MainActor
struct MistakeCollectionFixesTests {

    /// A report built by hand, as `MistakeTests` builds one: every move the
    /// engine's choice and level, except the one at `blunderPly`, which throws
    /// away a whole piece where `best` kept the balance.
    private func report(for game: Game, blunderAt blunderPly: Int, best uci: String) throws -> GameAnalysis {
        let jobs = GameAnalyzer.positions(of: game)
        let best = try #require(jobs[blunderPly].board.generateLegalMoves().first { $0.uci == uci })
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

    /// 1.e4 e5 2.Qh5 Nc6 3.Qxf7+?? — the queen is simply lost to the king.
    private let queenLost = ["e2e4", "e7e5", "d1h5", "b8c6", "h5f7"]

    @Test("A mistake that was fixed does not come back when its game is reviewed again")
    func fixedMistakesStayFixed() throws {
        try withScratchStore("analysisFixedMistakes") {
            let store = MistakeStore.shared
            let game = try played(queenLost)
            let analysis = try report(for: game, blunderAt: 4, best: "f1c4")
            store.collect(from: analysis, game: game, colors: [.white])
            let fixed = try #require(store.pending.first)
            store.recordAttempt(fixed.id, solved: true)
            try #require(store.pending.isEmpty)

            // Enough newer mistakes to fill the store, which makes room by
            // dropping the fixed ones first. Each is a one-move game from a
            // position of its own: 1.e4?? where 1.d4 was best.
            for move in 2..<(2 + MistakeStore.maxEntries) {
                let other = try played(["e2e4"], from: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 \(move)")
                store.collect(from: try report(for: other, blunderAt: 0, best: "d2d4"), game: other, colors: [.white])
            }
            try #require(store.entries.count == MistakeStore.maxEntries)
            try #require(!store.entries.contains { $0.id == fixed.id }, "the fixed mistake was not dropped to make room")

            // Opening the old review again finishes it again.
            store.collect(from: analysis, game: game, colors: [.white])
            #expect(!store.entries.contains { $0.fen == fixed.fen && $0.bestUCI == fixed.bestUCI },
                    "the fixed mistake came back")
            #expect(store.entries.count == MistakeStore.maxEntries)
        }
    }

    @Test("A game is read once, but a new game with the same mistake is read in its own right")
    func eachGameIsReadOnce() throws {
        try withScratchStore("analysisGamesReadOnce") {
            let store = MistakeStore.shared
            let game = try played(queenLost)
            let analysis = try report(for: game, blunderAt: 4, best: "f1c4")
            store.collect(from: analysis, game: game, colors: [.white])
            let entry = try #require(store.entries.first)
            store.remove(entry.id)

            store.collect(from: analysis, game: game, colors: [.white])
            #expect(store.entries.isEmpty, "the same game was read twice")
            // Remembered where a relaunch finds it, under a name that does
            // not change from one launch to the next.
            #expect(LocalStore.list(of: String.self, inFile: "mistakeGames") == [MistakeStore.digest(of: game)])
            #expect(MistakeStore.digest(of: try played(queenLost)) == MistakeStore.digest(of: game))

            // The same blunder in a game that went on is another game, and
            // another chance to learn from it.
            let longer = try played(queenLost + ["e8f7"])
            #expect(MistakeStore.digest(of: longer) != MistakeStore.digest(of: game))
            store.collect(from: try report(for: longer, blunderAt: 4, best: "f1c4"), game: longer, colors: [.white])
            #expect(store.pending.count == 1)
        }
    }

    @Test("A list of games read that does not read is kept aside, and collecting goes on")
    func unreadableGamesList() throws {
        try withScratchStore("analysisGamesUnreadable") {
            let garbage = Data("{ this is no list".utf8)
            LocalStore.defaults.set(garbage, forKey: "mistakeGames")

            let game = try played(queenLost)
            let analysis = try report(for: game, blunderAt: 4, best: "f1c4")
            MistakeStore.shared.collect(from: analysis, game: game, colors: [.white])
            #expect(MistakeStore.shared.pending.count == 1)
            #expect(LocalStore.setAsideCopy(forKey: "mistakeGames") == garbage)
            #expect(LocalStore.list(of: String.self, inFile: "mistakeGames") == [MistakeStore.digest(of: game)])
        }
    }
}
