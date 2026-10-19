//
//  StorageRoundFixesTests.swift
//  chessTests
//
//  One test per fault found in another look at how the app keeps what it
//  keeps, each written to fail on the code as it was: a file that did not
//  read taken for one never written, and the archive written over with a
//  single game; a game that had just ended cleared before the archive held
//  it; the archive decoded on the main thread at every launch; and a review
//  cache that dropped the review used last because it was written longest
//  ago, or because the clock had been set back.
//

import Foundation
import Synchronization
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
    var game = Game(fen: fen)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
    }
    return game
}

private func record(_ ucis: [String], at seconds: TimeInterval) throws -> GameRecord {
    GameRecord(
        game: try played(ucis), mode: .vsAI(difficulty: .medium, playerColor: .white),
        options: .standard, moveTimes: Array(repeating: 2, count: ucis.count), finalClock: nil,
        finishedAt: Date(timeIntervalSinceReferenceDate: seconds)
    )
}

private func setPermissions(_ permissions: Int, of url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

/// The archive as it is on disk, read past everything in memory.
@MainActor
private func storedArchive() throws -> [GameRecord] {
    LocalStore.flush()
    return try JSONDecoder().decode([GameRecord].self, from: try #require(LocalStore.files.read("gameArchive")))
}

/// Waits for `condition`, a twentieth of a second at a time, counted in
/// turns rather than against a clock: a simulator running every suite at
/// once can keep the main actor busy for seconds together.
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// `withScratchStore` for a test that waits — on the writer, or on a drop
/// that follows it. The store stays swapped in across the wait, so it takes
/// `ScratchStoreLock` first, as every helper of the kind does.
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

// MARK: - Files that do not read

@Suite("Storage round fixes: files that do not read", .serialized)
@MainActor
struct UnreadFileStorageRoundFixesTests {

    private let kept = [
        try! record(["d2d4", "d7d5"], at: 800_000_100),
        try! record(["e2e4", "c7c5"], at: 800_000_000),
    ]

    @Test("Only a file that is not there reads as none; one that does not read is not written over")
    func onlyAMissingFileIsAbsent() throws {
        let files = FileStore(directory: FileManager.default.temporaryDirectory.appending(
            path: "LocalStore-" + UUID().uuidString, directoryHint: .isDirectory
        ))
        defer { files.discard() }
        #expect(try files.contents(of: "store") == nil)
        #expect(!files.isUnread("store"))

        // A directory where the file should be: there, but not to be read.
        let url = files.url(for: "store")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try files.contents(of: "store") }
        #expect(files.isUnread("store"))
        #expect(throws: FileStore.UnreadFile.self) { try files.write(Data("[]".utf8), as: "store") }
        #expect(!files.lastWriteLanded("store"), "a write turned away counted as landed")
        files.remove("store")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "removed though it did not read")

        // Not there any more, and read again: it may be written once more.
        try FileManager.default.removeItem(at: url)
        #expect(try files.contents(of: "store") == nil)
        try files.write(Data("[1]".utf8), as: "store")
        #expect(files.lastWriteLanded("store"))

        // A file the app may not read for the moment is the same: noted
        // while it does not read, and read again once it does.
        try setPermissions(0o000, of: url)
        defer { try? setPermissions(0o644, of: url) }
        #expect(files.read("store") == nil)
        #expect(files.isUnread("store"))
        try setPermissions(0o644, of: url)
        #expect(files.read("store") == Data("[1]".utf8))
        #expect(!files.isUnread("store"))
    }

    @Test("An archive that does not read is not written over by the next game filed")
    func unreadArchiveIsNotWrittenOver() throws {
        try withScratchStore("roundUnreadArchive") {
            try LocalStore.files.write(try JSONEncoder().encode(kept), as: "gameArchive")
            let url = LocalStore.files.url(for: "gameArchive")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            #expect(GameArchive.shared.records.isEmpty)
            let new = try record(["c2c4"], at: 800_000_200)
            GameArchive.shared.add(new)
            #expect(GameArchive.shared.records == [new], "the game just filed is not in the archive in memory")
            LocalStore.flush()

            try setPermissions(0o644, of: url)
            #expect(try storedArchive() == kept, "the archive was written over")
            #expect(LocalStore.setAsideCopy(forKey: "gameArchive") == nil, "set aside, though nothing was read")
        }
    }

    @Test("An archive that does not read is read again when next asked for, and comes back whole")
    func unreadArchiveIsReadAgain() async throws {
        try await withScratchStoreAsync("roundUnreadArchiveAgain") {
            try LocalStore.files.write(try JSONEncoder().encode(kept), as: "gameArchive")
            let url = LocalStore.files.url(for: "gameArchive")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            #expect(GameArchive.shared.records.isEmpty)
            #expect(await GameArchive.shared.loadRecords().isEmpty)
            #expect(GameArchive.shared.recordsInMemory == nil, "kept in memory as an empty archive")

            try setPermissions(0o644, of: url)
            #expect(GameArchive.shared.records == kept, "the archive did not come back once it read")
        }
    }

    @Test("A key left in UserDefaults does not stand in for a file that does not read, nor move over it")
    func leftoverKeyDoesNotStandIn() throws {
        try withScratchStore("roundUnreadArchiveKey") {
            try LocalStore.files.write(try JSONEncoder().encode(kept), as: "gameArchive")
            LocalStore.defaults.set(try JSONEncoder().encode([try record(["c2c4"], at: 700_000_000)]), forKey: "gameArchive")
            let url = LocalStore.files.url(for: "gameArchive")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            #expect(GameArchive.shared.records.isEmpty, "the key left behind stood in for the file")
            LocalStore.flush()
            try setPermissions(0o644, of: url)
            #expect(try storedArchive() == kept, "the key was moved across over the file")

            // Read at last, the file is the store and the key goes.
            #expect(GameArchive.shared.records == kept)
            #expect(LocalStore.defaults.object(forKey: "gameArchive") == nil)
        }
    }
}

// MARK: - The game that has just ended

@Suite("Storage round fixes: the game that has just ended", .serialized)
@MainActor
struct FinishedGameStorageRoundFixesTests {

    private static let foolsMate = ["f2f3", "e7e5", "g2g4", "d8h4"]

    private func play(_ model: GameViewModel, _ ucis: [String]) throws {
        for uci in ucis {
            let move = try #require(model.game.legalMoves.first { $0.uci == uci }, "no legal \(uci)")
            model.handleTap(on: move.from)
            model.handleTap(on: move.to)
        }
        #expect(model.game.history.map(\.move.uci) == ucis)
    }

    /// Waits until the drops asked for so far have gone, or been given up:
    /// one of a key of the test's own, asked for after them and waiting on a
    /// file never written, goes the same way behind them.
    private func settleDrops() async throws {
        LocalStore.set(Data(), forKey: "roundSentinel")
        LocalStore.remove("roundSentinel", onceFiled: "roundSentinel")
        try await waitFor { LocalStore.defaults.object(forKey: "roundSentinel") == nil }
        #expect(LocalStore.defaults.object(forKey: "roundSentinel") == nil, "the drops never settled")
    }

    @Test("The game that has just ended stays saved until the archive holds it")
    func clearedOnceFiled() async throws {
        try await withScratchStoreAsync("roundClearOnceFiled") {
            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings())
            defer { model.teardown() }
            try play(model, Self.foolsMate)
            #expect(model.game.outcome.isGameOver)

            // Over, so not on offer — but still stored, with the archive's
            // write not yet behind it.
            #expect(SavedGame.load() == nil, "Continue offers a game that is over")
            #expect(LocalStore.defaults.data(forKey: "savedGame") != nil, "cleared before the archive was written")

            let files = LocalStore.files
            try await waitFor { LocalStore.defaults.object(forKey: "savedGame") == nil }
            #expect(LocalStore.defaults.object(forKey: "savedGame") == nil, "never cleared")
            // Gone, and the archive holds the game already.
            let stored = try JSONDecoder().decode([GameRecord].self, from: try #require(files.read("gameArchive")))
            #expect(stored.first?.moveUCIs == Self.foolsMate)
        }
    }

    @Test("A game whose archive write does not land stays saved for the next launch")
    func keptWhenTheArchiveIsNotWritten() async throws {
        try await withScratchStoreAsync("roundClearNotFiled") {
            // A store nothing can be written into, which turns the archive's
            // write away as a full disk would.
            let directory = LocalStore.files.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try setPermissions(0o555, of: directory)
            defer { try? setPermissions(0o755, of: directory) }

            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings())
            defer { model.teardown() }
            try play(model, Self.foolsMate)
            // Looked at before the wait: another suite's store swapped in
            // meanwhile takes the archive in memory with it.
            #expect(GameArchive.shared.latest?.moveUCIs == Self.foolsMate, "not in the archive in memory")
            try await settleDrops()

            #expect(!LocalStore.files.lastWriteLanded("gameArchive"), "the archive was written after all")
            #expect(SavedGame.load() == nil, "Continue offers a game that is over")
            let saved = try #require(LocalStore.defaults.data(forKey: "savedGame"),
                                     "cleared though the archive was never written")
            #expect(try JSONDecoder().decode(SavedGame.self, from: saved).moveUCIs == Array(Self.foolsMate.dropLast()))
        }
    }

    @Test("An archive that did not read keeps the game that has just ended saved as well")
    func keptWhenTheArchiveDidNotRead() async throws {
        try await withScratchStoreAsync("roundClearUnread") {
            try LocalStore.files.write(try JSONEncoder().encode([try record(["e2e4"], at: 800_000_000)]), as: "gameArchive")
            let url = LocalStore.files.url(for: "gameArchive")
            try setPermissions(0o000, of: url)
            defer { try? setPermissions(0o644, of: url) }

            let model = GameViewModel(mode: .twoPlayer, settings: AppSettings())
            defer { model.teardown() }
            try play(model, Self.foolsMate)
            try await settleDrops()

            #expect(LocalStore.defaults.data(forKey: "savedGame") != nil, "cleared though the archive was not written")
            try setPermissions(0o644, of: url)
            #expect(try storedArchive().map(\.moveUCIs) == [["e2e4"]])
        }
    }

    @Test("A game begun before the last one's clear has gone is not cleared with it")
    func savingCallsTheClearOff() async throws {
        try await withScratchStoreAsync("roundClearCalledOff") {
            SavedGame(mode: .twoPlayer, initialFEN: Board.startFEN, moveUCIs: ["e2e4"], savedAt: Date()).save()
            SavedGame.clear()
            #expect(SavedGame.load() == nil)
            SavedGame(mode: .twoPlayer, initialFEN: Board.startFEN, moveUCIs: ["d2d4"], savedAt: Date()).save()
            try await settleDrops()
            #expect(SavedGame.load()?.moveUCIs == ["d2d4"], "the new game was cleared with the old one")
        }
    }
}

// MARK: - The archive at launch

/// A list entry that notes whether it was decoded on the main thread.
nonisolated private struct Probe: Decodable, Sendable {
    static let decodedOnMain = Mutex(false)
    let n: Int

    init(from decoder: any Decoder) throws {
        if Thread.isMainThread { Self.decodedOnMain.withLock { $0 = true } }
        n = try decoder.singleValueContainer().decode(Int.self)
    }
}

@Suite("Storage round fixes: the archive at launch", .serialized)
@MainActor
struct LaunchArchiveStorageRoundFixesTests {

    @Test("A list read in the background is decoded off the main thread, and reads as it does in the foreground")
    func listsDecodeOffTheMainThread() async throws {
        try await withScratchStoreAsync("roundBackgroundList") {
            let data = Data(#"[1, 2, "three", 4]"#.utf8)
            try LocalStore.files.write(data, as: "probe")
            let read = await LocalStore.listInBackground(of: Probe.self, inFile: "probe")
            #expect(read.map(\.n) == [1, 2, 4])
            let onMain = Probe.decodedOnMain.withLock { $0 }
            #expect(!onMain, "decoded on the main thread")
            // Read short, so set aside, as `list(of:inFile:)` would have.
            #expect(LocalStore.setAsideCopy(forKey: "probe") == data)
        }
    }

    @Test("The archive read in the background is the one in memory after it")
    func loadedArchiveStaysInMemory() async throws {
        try await withScratchStoreAsync("roundLoadedArchive") {
            let kept = [try record(["d2d4", "d7d5"], at: 800_000_100), try record(["e2e4"], at: 800_000_000)]
            try LocalStore.files.write(try JSONEncoder().encode(kept), as: "gameArchive")
            #expect(GameArchive.shared.recordsInMemory == nil)

            #expect(await GameArchive.shared.loadRecords() == kept)
            #expect(GameArchive.shared.recordsInMemory == kept)
            // Not read again: gone from the disk, it is still all there.
            LocalStore.files.remove("gameArchive")
            #expect(GameArchive.shared.records == kept)
        }
    }

    @Test("Read in the background, an archive still under its old key is moved across all the same")
    func backgroundReadMovesTheOldKey() async throws {
        try await withScratchStoreAsync("roundLoadedArchiveKey") {
            let kept = [try record(["c2c4"], at: 800_000_000)]
            let data = try JSONEncoder().encode(kept)
            LocalStore.defaults.set(data, forKey: "gameArchive")

            #expect(await GameArchive.shared.loadRecords() == kept)
            LocalStore.flush()
            #expect(LocalStore.files.read("gameArchive") == data)
            #expect(LocalStore.defaults.object(forKey: "gameArchive") == nil)
        }
    }

    @Test("A game filed while the archive is being read is not lost to what was read")
    func gameFiledMeanwhileIsKept() async throws {
        try await withScratchStoreAsync("roundLoadedArchiveRace") {
            let old = try record(["e2e4", "c7c5"], at: 800_000_000)
            try LocalStore.files.write(try JSONEncoder().encode([old]), as: "gameArchive")
            // The writer kept busy, so the reading is still waiting its turn
            // there when the game is filed.
            LocalStore.enqueue { Thread.sleep(forTimeInterval: 0.3) }
            let loading = Task { await GameArchive.shared.loadRecords() }
            try await Task.sleep(for: .milliseconds(50))

            let new = try record(["d2d4"], at: 800_000_100)
            GameArchive.shared.add(new)
            #expect(await loading.value.map(\.id) == [new.id, old.id])
            #expect(GameArchive.shared.records.map(\.id) == [new.id, old.id], "the game filed meanwhile was lost")
            #expect(try storedArchive().map(\.id) == [new.id, old.id])
        }
    }
}

// MARK: - The review cache

@Suite("Storage round fixes: the review cache", .serialized)
@MainActor
struct ReviewCacheStorageRoundFixesTests {

    private let settings = GameAnalyzer.Settings(maxDepth: 4, nodesPerPosition: 20_000, timeLimitPerPosition: 10)

    private func entry(_ fingerprint: String, at seconds: TimeInterval) throws -> CachedGameAnalysis {
        let position = CachedPosition(PositionAnalysis(
            bestMove: try #require(Board.initial.generateLegalMoves().first), bestScore: 20,
            focusScore: nil, hasCloseAlternative: true, legalMoveCount: 20, depth: 4, nodes: 1000
        ))
        return CachedGameAnalysis(
            fingerprint: fingerprint, positions: [position], updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// A complete review of `game`, every entry legal in the position it is
    /// filed under, so that opening it searches nothing.
    private func cachedReview(of game: Game, at seconds: TimeInterval) -> CachedGameAnalysis {
        let positions: [CachedPosition?] = GameAnalyzer.positions(of: game).map { job in
            let legal = job.board.generateLegalMoves()
            return CachedPosition(PositionAnalysis(
                bestMove: job.playedMove ?? legal[0], bestScore: 0, focusScore: nil,
                hasCloseAlternative: true, legalMoveCount: legal.count, depth: 4, nodes: 1000
            ))
        }
        return CachedGameAnalysis(
            fingerprint: AnalysisCache.fingerprint(game: game, settings: settings),
            positions: positions, updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func stored() throws -> [String] {
        LocalStore.flush()
        let data = try #require(LocalStore.files.read("analysisCache"))
        return try JSONDecoder().decode([CachedGameAnalysis].self, from: data).map(\.fingerprint)
    }

    @Test("A review opened again outlives twenty reviews written after it")
    func openedReviewIsKept() throws {
        let game = try played(["e2e4", "e7e5", "g1f3", "b8c6"])
        let fingerprint = AnalysisCache.fingerprint(game: game, settings: settings)
        try withScratchStore("roundReviewOpened") {
            AnalysisCache.save(cachedReview(of: game, at: 1_000))
            for index in 1..<AnalysisCache.maxGames {
                AnalysisCache.save(try entry("other\(index)", at: 1_000 + Double(index)))
            }
            #expect(AnalysisCache.load().last?.fingerprint == fingerprint)

            // Held in full, it searches nothing and saves nothing when it is
            // opened — but it has been used.
            let review = GameReviewModel(game: game, mode: .twoPlayer)
            review.startAnalysis(settings: settings)
            #expect(!review.isAnalyzing, "the review searched again")
            review.teardown()
            #expect(AnalysisCache.load().first?.fingerprint == fingerprint, "opening it did not move it up")

            AnalysisCache.save(try entry("newer", at: 2_000))
            let kept = AnalysisCache.load().map(\.fingerprint)
            #expect(kept.count == AnalysisCache.maxGames)
            #expect(kept.contains(fingerprint), "the review opened last was dropped")
            #expect(!kept.contains("other1"), "the review used longest ago was kept")
            #expect(try stored() == kept, "the store on disk is not in the order of use")
        }
    }

    @Test("Opening the review used last writes nothing")
    func touchingTheFrontIsFree() throws {
        try withScratchStore("roundReviewFront") {
            AnalysisCache.save(try entry("older", at: 1))
            AnalysisCache.save(try entry("newest", at: 2))
            LocalStore.flush()
            LocalStore.files.remove("analysisCache")

            AnalysisCache.touch(fingerprint: "newest")
            LocalStore.flush()
            #expect(LocalStore.files.read("analysisCache") == nil, "written again for nothing")

            AnalysisCache.touch(fingerprint: "older")
            #expect(AnalysisCache.load().map(\.fingerprint) == ["older", "newest"])
            #expect(try stored() == ["older", "newest"])
        }
    }

    @Test("A review saved after the clock was set back is kept, at the front")
    func clockSetBack() throws {
        try withScratchStore("roundReviewClock") {
            for index in 0..<AnalysisCache.maxGames {
                AnalysisCache.save(try entry("game\(index)", at: 2_000_000_000 + Double(index)))
            }
            AnalysisCache.save(try entry("afterTheClockWentBack", at: 0))
            let kept = AnalysisCache.load().map(\.fingerprint)
            #expect(kept.first == "afterTheClockWentBack", "the review saved last was dropped")
            #expect(kept.count == AnalysisCache.maxGames)
            #expect(!kept.contains("game0"), "the review used longest ago was kept")
        }
    }

    @Test("A store as earlier builds wrote it, newest first, drops its oldest review first")
    func earlierOrderReadsTheSame() throws {
        try withScratchStore("roundReviewEarlier") {
            let left = try (0..<AnalysisCache.maxGames).reversed().map { try entry("game\($0)", at: Double($0)) }
            LocalStore.defaults.set(try JSONEncoder().encode(left), forKey: "analysisCache")

            AnalysisCache.save(try entry("new", at: 100))
            #expect(AnalysisCache.load().map(\.fingerprint) == ["new"] + left.dropLast().map(\.fingerprint))
        }
    }
}
