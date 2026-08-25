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
struct CachedPosition: Codable, Sendable, Hashable {
    var bestUCI: String
    var bestScore: Int
    var focusScore: Int?
    var hasCloseAlternative: Bool
    var legalMoveCount: Int
    var depth: Int
    var nodes: Int

    init(_ analysis: PositionAnalysis) {
        bestUCI = analysis.bestMove.uci
        bestScore = analysis.bestScore
        focusScore = analysis.focusScore
        hasCloseAlternative = analysis.hasCloseAlternative
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
struct CachedGameAnalysis: Codable, Sendable {
    /// Identifies the game *and* the search settings — see
    /// `AnalysisCache.fingerprint(game:settings:)`.
    var fingerprint: String
    var positions: [CachedPosition?]
    var updatedAt: Date

    var completedCount: Int { positions.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
}

// MARK: - The store

/// The reviews the app remembers, newest first.
///
/// Only a handful are kept. The menu offers exactly one finished game to
/// review, and the game just played is the other one a player is likely to
/// open, so three covers going back and forth between them; more would only
/// grow the store for reviews nothing can reach any more.
enum AnalysisCache {

    /// Bump this whenever a change to the search or to `PositionAnalysis`
    /// makes stored numbers no longer what a fresh run would produce.
    /// Everything cached under an older revision is simply not found, and is
    /// searched again.
    static let engineRevision = 1

    static let maxGames = 3

    private static let key = "analysisCache"

    /// Identifies a game together with the settings it was searched under, so
    /// that a review can only ever reuse numbers a re-run would reproduce.
    /// The node budget is what bounds the search, which is why it is part of
    /// this: the same game at a different budget is a different report.
    static func fingerprint(game: Game, settings: GameAnalyzer.Settings) -> String {
        let moves = game.history.map(\.move.uci).joined(separator: " ")
        return [
            "r\(engineRevision)",
            "d\(settings.maxDepth)",
            "n\(settings.nodesPerPosition)",
            game.initialFEN,
            moves,
        ].joined(separator: "|")
    }

    /// The store as it was last read or written.
    ///
    /// Kept in memory because a running review saves after every position it
    /// searches, and going back to `UserDefaults` each time would decode the
    /// other games in the store — on the main actor — only to throw them away
    /// again. `LocalStore.defaults` is a `var` that the tests point at a
    /// scratch suite, so the mirror records which store it was filled from and
    /// reads again when that changes.
    private static var mirror: [CachedGameAnalysis]?
    private static var mirrorSource: UserDefaults?

    // MARK: Reading

    static func load() -> [CachedGameAnalysis] {
        let store = LocalStore.defaults
        if let mirror, mirrorSource === store { return mirror }
        let entries: [CachedGameAnalysis]
        if let data = store.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CachedGameAnalysis].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        mirror = entries
        mirrorSource = store
        return entries
    }

    /// What has been searched of this game, or nil when nothing has.
    static func load(fingerprint: String) -> CachedGameAnalysis? {
        load().first { $0.fingerprint == fingerprint }
    }

    // MARK: Writing

    /// Stores what has been searched so far, replacing any earlier run of the
    /// same game and dropping the oldest entry once the store is full.
    ///
    /// Nothing is written for a game with no results at all: a review that was
    /// closed before the first search landed would otherwise push a useful
    /// entry out of the store to record that it knows nothing.
    static func save(_ entry: CachedGameAnalysis) {
        guard entry.completedCount > 0 else { return }
        var entries = load().filter { $0.fingerprint != entry.fingerprint }
        entries.append(entry)
        entries.sort { $0.updatedAt > $1.updatedAt }
        entries = Array(entries.prefix(maxGames))
        mirror = entries
        mirrorSource = LocalStore.defaults
        if let data = try? JSONEncoder().encode(entries) {
            LocalStore.defaults.set(data, forKey: key)
        }
    }

    static func clear() {
        mirror = nil
        mirrorSource = nil
        LocalStore.defaults.removeObject(forKey: key)
    }
}
