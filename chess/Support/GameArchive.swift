//
//  GameArchive.swift
//  chess
//
//  Every finished game, kept on the device: the list under "My Games", what
//  the statistics and achievements are counted from, and what PGN export
//  writes out.
//

import Foundation

// MARK: - Record

/// One finished game, as the archive keeps it.
///
/// Moves are stored as UCI and replayed into a `Game` when one is needed, the
/// same way `SavedGame` does it: a UCI string names only squares, so nothing
/// stored can describe a move the position does not allow.
///
/// Nonisolated, like the engine's types, so that the archive can be encoded
/// and exported away from the main actor.
nonisolated struct GameRecord: Codable, Hashable, Identifiable, Sendable {

    nonisolated enum Source: String, Codable, Sendable {
        /// Played in the app.
        case played
        /// Read in from a PGN file.
        case imported
    }

    var id: UUID
    var mode: GameMode
    var options: GameOptions
    var initialFEN: String
    var moveUCIs: [String]
    var outcome: GameOutcome
    var finishedAt: Date
    /// Seconds per ply; empty for an imported game.
    var moveTimes: [TimeInterval]
    /// Clock faces at the end, `[white, black]`, for a timed game.
    var finalClock: [TimeInterval]?
    /// Accuracy per player, `[white, black]`, once the game has been reviewed.
    var accuracy: [Double?]?
    var source: Source
    /// The player names and event of an imported game, from its PGN tags.
    var tags: [String: String]?

    init(
        game: Game, mode: GameMode, options: GameOptions,
        moveTimes: [TimeInterval], finalClock: [TimeInterval]?,
        source: Source = .played, tags: [String: String]? = nil,
        finishedAt: Date = Date()
    ) {
        self.id = UUID()
        self.mode = mode
        self.options = options
        self.initialFEN = game.initialFEN
        self.moveUCIs = game.history.map(\.move.uci)
        self.outcome = game.outcome
        self.finishedAt = finishedAt
        self.moveTimes = moveTimes
        self.finalClock = finalClock
        self.source = source
        self.tags = tags
    }

    // Field by field, so that a field with an obvious default does not cost
    // the whole game when it is missing — from an older build, or dropped by
    // a later one. The keys and how each is written are the synthesized ones,
    // unchanged, so everything 1.0 and 1.0.1 wrote reads back as it was.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(GameMode.self, forKey: .mode)
        options = try container.decodeIfPresent(GameOptions.self, forKey: .options) ?? .standard
        initialFEN = try container.decode(String.self, forKey: .initialFEN)
        moveUCIs = try container.decode([String].self, forKey: .moveUCIs)
        outcome = try container.decode(GameOutcome.self, forKey: .outcome)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        moveTimes = try container.decodeIfPresent([TimeInterval].self, forKey: .moveTimes) ?? []
        finalClock = try container.decodeIfPresent([TimeInterval].self, forKey: .finalClock)
        accuracy = Self.checked(accuracy: try container.decodeIfPresent([Double?].self, forKey: .accuracy))
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .played
        tags = try container.decodeIfPresent([String: String].self, forKey: .tags)
    }

    /// An accuracy that is not one entry per player, `[white, black]`, is no
    /// accuracy at all: everything that reads it takes a player's entry by
    /// colour, and a stored array one short trapped there. Dropped, the game
    /// reads as not reviewed yet, which reviewing it again puts right.
    static func checked(accuracy: [Double?]?) -> [Double?]? {
        guard let accuracy, accuracy.count == 2 else { return nil }
        return accuracy
    }

    /// Replays the moves and restores how the game ended. Resignations,
    /// agreed draws and flag falls leave no trace in the move list, so they
    /// are re-applied — the same way `FinishedGame.restoreGame` does it.
    ///
    /// An imported game is replayed under FIDE's draw rules, as it was read
    /// (see `Game.settlesClaimableDraws`): its players may have played on past
    /// a repetition, and a draw they did claim is claimed again here.
    ///
    /// A loss on time is filed as it was ruled and comes back as it was filed
    /// (`Game.recordTimeForfeit`). Judged again by `timeOut`, a game read from
    /// PGN that a server had scored as a win on time — a queen against a lone
    /// knight — came back drawn, and was written out again with "1-0" in its
    /// tags and "1/2-1/2" after its moves. A draw on time is the verdict
    /// `timeOut` gives and is reached the same way again.
    func restoreGame() -> Game? {
        let replayed = replayedMoves()
        guard replayed.isWhole else { return nil }
        var game = replayed.game
        if !game.outcome.isGameOver {
            switch outcome {
            case .resigned(let winner): game.resign(winner.opponent)
            case .drawAgreed: game.agreeToDraw()
            case .drawThreefoldRepetition, .drawFiftyMoveRule: game.claimDraw()
            case .timeForfeit: game.recordTimeForfeit()
            case .drawTimeoutInsufficientMaterial: game.timeOut()
            default: break
            }
        }
        return game
    }

    /// The moves replayed as far as they go — up to the first that is not
    /// legal where it stands — and whether that was all of them.
    func replayedMoves() -> (game: Game, isWhole: Bool) {
        var game = Game(fen: initialFEN, variant: options.variant, settlesClaimableDraws: source != .imported)
        for uci in moveUCIs {
            guard let move = game.legalMoves.first(where: { $0.uci == uci }) else { return (game, false) }
            game.play(move)
        }
        return (game, true)
    }

    /// Full moves, counted the way the menu counts them — and the way
    /// `Game.movesPlayed` does, for a game set up with Black to move.
    var moveCount: Int {
        let blackFirst = initialFEN.split(separator: " ").dropFirst().first == "b"
        return (moveUCIs.count + (blackFirst ? 2 : 1)) / 2
    }

    /// The human's colour in a game against the computer.
    var humanColor: PieceColor? { mode.humanColor }

    /// The result from the human's side, for a game against the computer:
    /// 1 a win, ½ a draw, 0 a loss. Nil for two players or imports.
    var playerScore: Double? {
        guard source == .played, let color = humanColor else { return nil }
        if let winner = outcome.winner { return winner == color ? 1 : 0 }
        return outcome.isDraw ? 0.5 : nil
    }

    /// Whether the game began from a position set up by hand or pasted in,
    /// rather than from one of the starts the app deals.
    var startsFromSetUpPosition: Bool { options.start.isSetUp }

    /// The result as it counts in the player's record against the computer —
    /// the results by level, colour and clock, the streaks, the strength
    /// estimate and the achievements for beating it: `playerScore`, for every
    /// game but one begun from a set-up position, which counts for nothing
    /// there. Such a position can be won before a move is made — a king and
    /// queen against a lone king, set up and played out against Grandmaster,
    /// earned First Victory, Giant Slayer, Short and Sweet and a share of a
    /// Hat Trick, and lifted the strength estimate as a win at that level.
    ///
    /// A game at odds still counts, as it always has: it starts from the
    /// standard position less one piece — the old, recognised way of evening
    /// out a game between unequal players — and nothing about it can be
    /// arranged to win itself. A set-up game is still a game finished, and
    /// counts towards those achievements and the number of games played; it
    /// keeps its result in My Games as well, which reads `playerScore`.
    var recordScore: Double? {
        startsFromSetUpPosition ? nil : playerScore
    }

    /// What makes two records the same game when PGN is imported: where it
    /// starts, under which rules, every move, the result, and the tags that
    /// name the game — event, site, date, round and players. The moves are
    /// what tell apart two games between the same two players on a date
    /// nobody wrote down; the tags are what tell apart two games that went
    /// the same way. A game played here is compared by the tags it is
    /// exported with, so a file exported from My Games and read back in finds
    /// its games already there.
    struct ImportIdentity: Hashable {
        let initialFEN: String
        let variant: ChessVariant
        let moves: [String]
        let result: String
        let tags: [String]
    }

    /// The tags that name a game, each with what `PGN.export` writes in its
    /// place when a game has none — so that a game read in without an event
    /// and the same game exported and read in again, now with the export's
    /// "Casual game", still compare equal.
    private static let identifyingTags: [(name: String, exported: String)] = [
        ("Event", "Casual game"), ("Site", "Chess (offline)"), ("Date", ""),
        ("Round", ""), ("White", ""), ("Black", ""),
    ]

    var importIdentity: ImportIdentity {
        let tags = Dictionary(pgnTags, uniquingKeysWith: { first, _ in first })
        return ImportIdentity(
            initialFEN: initialFEN,
            variant: options.variant,
            moves: moveUCIs,
            result: PGN.result(of: outcome),
            tags: Self.identifyingTags.map { Self.normalizedTag(tags[$0.name] ?? $0.exported) }
        )
    }

    /// A tag as compared: trimmed, and empty when it says only that the
    /// value is unknown, as `?`, `-` and `????.??.??` do.
    private static func normalizedTag(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.allSatisfy { "?.-".contains($0) } ? "" : trimmed
    }
}

// MARK: - Archive

/// The finished games, newest first.
///
/// Kept in a file of `LocalStore.files` — the largest store the app has, and
/// the reason the large ones left UserDefaults — so that a test pointing the
/// store at a scratch one takes the archive with it: a fuzz game a test plays
/// to mate has no business turning up under "My Games". Capped, because a
/// store that only grows is a store that one day makes the app slow to
/// launch: three hundred games is a long way back for anyone. Played and
/// imported games have three hundred places each, which together come to a
/// megabyte or two.
@Observable
@MainActor
final class GameArchive {
    static let shared = GameArchive()

    /// Per source: this many played games, and this many imported ones.
    static let maxRecords = 300
    /// The file, named after the key 1.0.1 kept the archive under. Known
    /// outside, because the unfinished game waits on it (see `SavedGame.clear`).
    static let key = "gameArchive"

    /// Bumped by every change, so a view can redraw on it without comparing
    /// three hundred records.
    private(set) var revision = 0

    // Ignored by observation: they are filled in from inside `records`, which
    // a view body reads, and a write to an observed property during a body
    // evaluation is a change SwiftUI would answer by evaluating it again.
    @ObservationIgnored private var mirror: [GameRecord]?
    @ObservationIgnored private var mirrorSource: FileStore?

    private init() {}

    /// Every game, newest first.
    ///
    /// An archive that is there but did not read is not kept in memory as an
    /// empty one: it is read again the next time it is asked for, and comes
    /// back whole once it reads (see `FileStore.contents(of:)`). A game filed
    /// before then is kept in memory, and the file is not written over; it is
    /// read again at every change after that, and the games filed meanwhile
    /// join it once it reads (see `save`).
    var records: [GameRecord] {
        _ = revision
        let store = LocalStore.files
        if let mirror, mirrorSource === store { return mirror }
        let loaded = LocalStore.list(of: GameRecord.self, inFile: Self.key)
        adopt(loaded, from: store)
        return loaded
    }

    /// Every game, as `records` has it, if it is in memory already; nil if
    /// it would have to be read.
    var recordsInMemory: [GameRecord]? {
        guard let mirror, mirrorSource === LocalStore.files else { return nil }
        return mirror
    }

    /// Every game, newest first, read and decoded off the main actor the
    /// first time (see `LocalStore.listInBackground`): decoded on it, six
    /// hundred games held the menu up at every launch before it had settled.
    /// The menu reads the archive this way; whoever asks for `records` after
    /// finds it in memory, and whoever asks meanwhile reads it for itself,
    /// as before.
    ///
    /// What the reading here brings back is let go whenever the archive was
    /// read meanwhile, or changed while it was being read: a game filed in
    /// the meantime is newer than anything read.
    func loadRecords() async -> [GameRecord] {
        if let recordsInMemory { return recordsInMemory }
        let store = LocalStore.files
        let unchanged = revision
        let loaded = await LocalStore.listInBackground(of: GameRecord.self, inFile: Self.key)
        guard revision == unchanged, LocalStore.files === store else { return records }
        if let recordsInMemory { return recordsInMemory }
        adopt(loaded, from: store)
        return loaded
    }

    /// Keeps what was read as the archive, unless it is nothing but a file
    /// that did not read (see `records`).
    private func adopt(_ loaded: [GameRecord], from store: FileStore) {
        guard !store.isUnread(Self.key) else { return }
        mirror = loaded
        mirrorSource = store
    }

    var latest: GameRecord? { records.first }

    func add(_ record: GameRecord) {
        var all = records
        all.insert(record, at: 0)
        save(Self.capped(all))
        if record.source == .played {
            Achievements.shared.gameFinished(record, archive: all)
        }
    }

    /// Files games read from PGN, or carried over from an older build, among
    /// the rest by date. Returns how many of `added` the cap left in the
    /// archive, newest first being the ones kept. Nothing is checked for
    /// being there already — that is `importGames`.
    @discardableResult
    func add(contentsOf added: [GameRecord]) -> Int {
        guard !added.isEmpty else { return 0 }
        var all = records
        all.append(contentsOf: added)
        all.sort { $0.finishedAt > $1.finishedAt }
        let kept = Self.capped(all)
        save(kept)
        let addedIDs = Set(added.map(\.id))
        return kept.count { addedIDs.contains($0.id) }
    }

    /// What an import came to.
    struct ImportSummary: Equatable {
        /// Games new to the archive.
        var added = 0
        /// Games it held already, or that came twice in the same import.
        var duplicates = 0
        /// How many of `added` the cap left in it.
        var kept = 0
        /// Games imported before that the cap took out to make room for
        /// newer ones. They went without a word: the import said only how
        /// many games it had brought in.
        var displaced = 0
    }

    /// Files games read from PGN, leaving out each one the archive already
    /// holds (see `GameRecord.importIdentity`) and each repeat within `games`
    /// — the same file picked twice, or one game in two files. Read in again,
    /// a file used to file every one of its games a second time.
    @discardableResult
    func importGames(_ games: [GameRecord]) -> ImportSummary {
        let before = records
        var known = Set(before.map(\.importIdentity))
        let fresh = games.filter { known.insert($0.importIdentity).inserted }
        let kept = add(contentsOf: fresh)
        let after = Set(records.map(\.id))
        return ImportSummary(
            added: fresh.count, duplicates: games.count - fresh.count, kept: kept,
            displaced: before.count { !after.contains($0.id) }
        )
    }

    /// The cap applies to the games played here and to imported ones
    /// separately. Counted together, one large PGN file — whose undated games
    /// all file as today's — pushed every game the player had played out of
    /// My Games and out of the statistics.
    private static func capped(_ all: [GameRecord]) -> [GameRecord] {
        var played = 0
        var imported = 0
        return all.filter { record in
            switch record.source {
            case .played:
                played += 1
                return played <= maxRecords
            case .imported:
                imported += 1
                return imported <= maxRecords
            }
        }
    }

    func remove(_ id: GameRecord.ID) {
        save(records.filter { $0.id != id })
    }

    /// Notes the accuracy a review measured, so the list and the statistics
    /// can show it without running the review again.
    func setAccuracy(_ accuracy: [Double?], for id: GameRecord.ID) {
        guard let accuracy = GameRecord.checked(accuracy: accuracy) else { return }
        var all = records
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        guard all[index].accuracy != accuracy else { return }
        all[index].accuracy = accuracy
        save(all)
        Achievements.shared.gameReviewed(all[index])
    }

    func record(_ id: GameRecord.ID) -> GameRecord? {
        records.first { $0.id == id }
    }

    func clear() {
        save([])
    }

    /// Makes `all` the archive: at once in memory, which is what the app
    /// reads, and in the store in the background. Encoding three hundred
    /// games cost a frame or two under the move that ended one.
    private func save(_ all: [GameRecord]) {
        let all = Self.joined(all)
        mirror = all
        mirrorSource = LocalStore.files
        revision += 1
        LocalStore.saveInBackground(all, toFile: Self.key)
    }

    /// `all`, joined by the games in the file if the file did not read when
    /// the archive was read, and reads now (see `LocalStore.entriesMissing`).
    /// Of the games filed meanwhile, only the last used to reach the next
    /// launch, as the unfinished game.
    private static func joined(_ all: [GameRecord]) -> [GameRecord] {
        guard let filed = LocalStore.entriesMissing(from: all, inFile: key, id: \.id) else { return all }
        return capped((all + filed).sorted { $0.finishedAt > $1.finishedAt })
    }
}
