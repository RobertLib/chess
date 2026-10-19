//
//  AnalysisCache.swift
//  chess
//
//  Keeps the engine's output from a game review so that opening the same
//  review again does not search the same positions a second time.
//

import Foundation

// MARK: - One cached position

/// The result of searching one position, in a form that survives a relaunch.
///
/// The engine's choice is kept as UCI rather than as a coded `Move`: a `Move`
/// carries the piece it moves and the piece it captures, so a stored one could
/// decode into something the position does not actually allow. A UCI string
/// names only squares, and is resolved back against the legal moves of the
/// position it belongs to — the same way `SavedGame` restores a game.
///
/// Nonisolated, like the game records, so that the cache can be encoded and
/// written away from the main actor.
nonisolated struct CachedPosition: Codable, Sendable, Hashable {
    var bestUCI: String
    var bestScore: Int
    var focusScore: Int?
    var hasCloseAlternative: Bool
    /// Optional, so that a store written before it was asked still reads;
    /// such a store is under an older revision, and dropped unread anyway.
    var alternativeWinsOutright: Bool?
    var legalMoveCount: Int
    var depth: Int
    var nodes: Int

    init(_ analysis: PositionAnalysis) {
        bestUCI = analysis.bestMove.uci
        bestScore = analysis.bestScore
        focusScore = analysis.focusScore
        hasCloseAlternative = analysis.hasCloseAlternative
        alternativeWinsOutright = analysis.alternativeWinsOutright
        legalMoveCount = analysis.legalMoveCount
        depth = analysis.depth
        nodes = analysis.nodes
    }

    /// Rebuilds the analysis against the position it was searched in. Nil when
    /// the stored move is not legal there, which means the entry belongs to
    /// some other position and has to be searched again.
    func restore(in board: Board) -> PositionAnalysis? {
        guard let move = board.generateLegalMoves().first(where: { $0.uci == bestUCI })
        else { return nil }
        return PositionAnalysis(
            bestMove: move,
            bestScore: bestScore,
            focusScore: focusScore,
            hasCloseAlternative: hasCloseAlternative,
            alternativeWinsOutright: alternativeWinsOutright,
            legalMoveCount: legalMoveCount,
            depth: depth,
            nodes: nodes
        )
    }
}

// MARK: - One cached game

/// What has been searched of one game, indexed the way
/// `GameAnalyzer.positions(of:)` indexes its jobs: entry *i* is the position
/// move *i* was played in, and the last entry is the final position. A gap is
/// a position that has not been searched yet, so a review that was closed
/// half way through keeps the half it finished.
nonisolated struct CachedGameAnalysis: Codable, Sendable {
    /// Identifies the game *and* the search settings — see
    /// `AnalysisCache.fingerprint(game:settings:)`.
    var fingerprint: String
    var positions: [CachedPosition?]
    /// When the entry was last written. Kept for what it says, but no longer
    /// what decides which entry the store drops — see `AnalysisCache.save`.
    var updatedAt: Date

    var completedCount: Int { positions.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
}

// MARK: - The store

/// The reviews the app remembers, the one used last first.
///
/// Only a limited number are kept. "My Games" can open any game in the
/// archive, but the ones a player goes back to are the last few; twenty
/// reviews come to a few hundred kilobytes, and anything not opened since
/// twenty others were is searched again on the rare occasion it is.
enum AnalysisCache {

    /// Which engine filled the cache. It **must** be bumped with every change
    /// to the search, the evaluation or the grading — move generation, draw
    /// and repetition rules, variant scoring, `PositionAnalysis`, the grading
    /// thresholds — anything that could make a fresh run of a review come out
    /// differently from the one stored. (The depth cap and the node budget
    /// need no bump: they are part of the fingerprint already.)
    ///
    /// Grades are worked out again from the stored numbers every time a
    /// review opens, so strictly it is only what the search hands back that
    /// goes stale. But the line between the two is not where it looks —
    /// `hasCloseAlternative` is grading done inside the search — and the costs
    /// are lopsided: a needless bump has the reviews a player opens again
    /// searched once more, a missing one shows them stale grades for good,
    /// with nothing on screen to tell. 1.0 and 1.0.1 both wrote revision 1,
    /// although 1.0.1 rewrote the repetition rule the search scores draws by,
    /// so every review 1.0 had cached came back with the very grades that fix
    /// was for. When in doubt, bump.
    ///
    /// 3: the played move is searched on past a mate the engine has found,
    /// the exchange count leaves out a defender pinned to its king, and
    /// quiescence sees stalemate and the variants' quiet wins — each one
    /// changes what the search hands back for positions already cached.
    ///
    /// 4: the only-move test is asked beside a mate and in won positions too,
    /// and a sacrifice that wins outright is asked whether anything else
    /// would have won as well (`alternativeWinsOutright`). Reviews cached by
    /// 3 graded every sacrifice that forced mate a plain Best.
    ///
    /// Everything cached under another revision is never found again, and is
    /// dropped from the store the first time it is read — see `load()`.
    static let engineRevision = 4

    static let maxGames = 20

    /// The file, named after the key 1.0.1 kept the cache under.
    private static let key = "analysisCache"

    /// Identifies a game together with the settings it was searched under, so
    /// that a review can only ever reuse numbers a re-run would reproduce.
    /// The node budget is what bounds the search, which is why it is part of
    /// this: the same game at a different budget is a different report.
    static func fingerprint(game: Game, settings: GameAnalyzer.Settings) -> String {
        let moves = game.history.map(\.move.uci).joined(separator: " ")
        var parts = [
            "r\(engineRevision)",
            "d\(settings.maxDepth)",
            "n\(settings.nodesPerPosition)",
            game.initialFEN,
            moves,
        ]
        // The same moves under other rules are another game to the engine.
        if game.variant != .standard { parts.append(game.variant.rawValue) }
        return parts.joined(separator: "|")
    }

    /// The store as it was last read or written.
    ///
    /// Kept in memory because a running review saves every few seconds while
    /// it searches, and going back to the file each time would decode the
    /// other games in the store — on the main actor — only to throw them away
    /// again. `LocalStore.files` is a `var` that the tests point at a scratch
    /// directory, so the mirror records which store it was filled from and
    /// reads again when that changes.
    private static var mirror: [CachedGameAnalysis]?
    private static var mirrorSource: FileStore?

    // MARK: Reading

    /// Reviews searched under another engine revision are dropped here, and
    /// the store is written again without them. Nothing can find them any
    /// more, but left in place they stayed until twenty newer reviews pushed
    /// them out — for a player who seldom opens one, half a megabyte read on
    /// every launch, for ever. A store that does not decode at all goes the
    /// same way: it is only a cache, and the next save would replace it anyway.
    static func load() -> [CachedGameAnalysis] {
        let store = LocalStore.files
        if let mirror, mirrorSource === store { return mirror }
        var entries: [CachedGameAnalysis] = []
        var isStale = false
        if let data = LocalStore.data(inFile: key) {
            if let decoded = try? JSONDecoder().decode([CachedGameAnalysis].self, from: data) {
                entries = decoded.filter { !isFromAnotherRevision($0) }
                isStale = entries.count < decoded.count
            } else {
                isStale = true
            }
        }
        if isStale { write(entries) }
        mirror = entries
        mirrorSource = store
        return entries
    }

    /// Whether an entry was searched by some other revision of the engine. A
    /// fingerprint starts with the revision it was made under, so nothing
    /// this build looks up can match one of these again.
    private static func isFromAnotherRevision(_ entry: CachedGameAnalysis) -> Bool {
        let tag = entry.fingerprint.prefix { $0 != "|" }
        guard tag.first == "r", let revision = Int(tag.dropFirst()) else { return false }
        return revision != engineRevision
    }

    /// What has been searched of this game, or nil when nothing has.
    static func load(fingerprint: String) -> CachedGameAnalysis? {
        load().first { $0.fingerprint == fingerprint }
    }

    // MARK: Writing

    /// Stores what has been searched so far, replacing any earlier run of the
    /// same game, at the front of the store, and dropping the entry at the
    /// back once the store is full.
    ///
    /// The store is kept in the order its reviews were last used, and that
    /// order alone decides what goes: a review saved or opened again (see
    /// `touch`) moves to the front, and the one used longest ago drops off
    /// the back. Sorted by `updatedAt`, as it was, the store dropped the
    /// review written longest ago — and a review the cache holds in full is
    /// never written again, so the one a player kept going back to went
    /// after twenty newer ones all the same. A clock set back did worse: the
    /// review searched after it sorted below all twenty others and was
    /// dropped the moment it was saved. Earlier builds wrote the store sorted
    /// by `updatedAt`, newest first, which reads as this same order.
    ///
    /// Nothing is written for a game with no results at all: a review that was
    /// closed before the first search landed would otherwise push a useful
    /// entry out of the store to record that it knows nothing.
    static func save(_ entry: CachedGameAnalysis) {
        guard entry.completedCount > 0 else { return }
        var entries = load().filter { $0.fingerprint != entry.fingerprint }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(maxGames))
        mirror = entries
        mirrorSource = LocalStore.files
        write(entries)
    }

    /// Moves the review of a game to the front of the store as it is opened
    /// (see `save`). Nothing is written for the review at the front already,
    /// so a player going back to the same game again and again costs nothing.
    static func touch(fingerprint: String) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }), index > 0
        else { return }
        entries.insert(entries.remove(at: index), at: 0)
        mirror = entries
        mirrorSource = LocalStore.files
        write(entries)
    }

    /// In the background, like the archive: twenty reviews are a few hundred
    /// kilobytes to encode, every fifteen seconds while a review runs.
    private static func write(_ entries: [CachedGameAnalysis]) {
        if entries.isEmpty {
            LocalStore.removeInBackground(file: key)
        } else {
            LocalStore.saveInBackground(entries, toFile: key)
        }
    }

    static func clear() {
        mirror = nil
        mirrorSource = nil
        LocalStore.removeInBackground(file: key)
    }
}
