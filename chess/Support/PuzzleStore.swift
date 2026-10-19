//
//  PuzzleStore.swift
//  chess
//
//  What the app remembers about puzzles: the player's rating and its history,
//  which puzzles have been seen, the rush records, the daily streak — and the
//  player's own mistakes, collected from their reviewed games as puzzles to
//  fix.
//

import Foundation

// MARK: - Progress

/// Everything about the player's puzzle solving that outlives a session.
///
/// Nonisolated, like the game records, so that it can be encoded and written
/// away from the main actor.
nonisolated struct PuzzleProgress: Codable, Hashable, Sendable {
    var rating = PuzzleRating.initial
    /// Rated attempts, solved or not.
    var attempts = 0
    /// Rated attempts solved cleanly.
    var solved = 0
    /// Puzzles solved cleanly — no wrong move, no hint, no look at the
    /// solution, not a retry — outside the rated ones: the daily puzzle, a
    /// race against the clock, the player's own mistakes. Kept apart from
    /// `solved`, which the puzzle page shows beside the attempts and the
    /// rating they were rated in.
    var unratedSolved = 0
    /// The rating after each rated attempt, newest last, for the graph.
    var history: [Double] = []
    /// Puzzles already attempted, so the next one is a new one.
    var seen: [String] = []
    /// Per theme: `[solved, attempted]`. Every entry holds both — see
    /// `init(from:)` — so a reader may index either without checking.
    var themeResults: [String: [Int]] = [:]
    /// Best rush scores by rush kind.
    var rushBest: [String: Int] = [:]
    /// The day number (see `PuzzleLibrary.dayNumber`) of the last daily
    /// puzzle solved, and how many days in a row that has been.
    var dailyLastSolved: Int?
    var dailyStreak = 0
    var dailyBestStreak = 0

    static let maxHistory = 300
    static let maxSeen = 3000

    /// Every puzzle solved cleanly, rated or not: what Puzzle Solver,
    /// Tactician and Pattern Master count.
    var puzzlesSolved: Int { solved + unratedSolved }

    init() {}

    // Field by field, so a field added in a later version is just missing —
    // and each on its own, so that one this build cannot read falls back to
    // its default and costs only itself. Read with a throwing
    // `decodeIfPresent` each, one bad field threw the whole progress away:
    // the rating, its history, every puzzle seen and the streaks with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rating = (try? c.decodeIfPresent(Double.self, forKey: .rating)) ?? PuzzleRating.initial
        attempts = (try? c.decodeIfPresent(Int.self, forKey: .attempts)) ?? 0
        solved = (try? c.decodeIfPresent(Int.self, forKey: .solved)) ?? 0
        unratedSolved = (try? c.decodeIfPresent(Int.self, forKey: .unratedSolved)) ?? 0
        history = (try? c.decodeIfPresent([Double].self, forKey: .history)) ?? []
        seen = (try? c.decodeIfPresent([String].self, forKey: .seen)) ?? []
        themeResults = Self.wellFormed(
            (try? c.decodeIfPresent([String: Lossy<[Int]>].self, forKey: .themeResults)) ?? [:]
        )
        rushBest = (try? c.decodeIfPresent([String: Int].self, forKey: .rushBest)) ?? [:]
        dailyLastSolved = try? c.decodeIfPresent(Int.self, forKey: .dailyLastSolved)
        dailyStreak = (try? c.decodeIfPresent(Int.self, forKey: .dailyStreak)) ?? 0
        dailyBestStreak = (try? c.decodeIfPresent(Int.self, forKey: .dailyBestStreak)) ?? 0
    }

    /// The theme results as every reader takes them: a pair per theme. An
    /// entry that does not read, or is shorter than the pair, is left out —
    /// the way `OpeningProgress` leaves out a line's — rather than kept for
    /// the next rated puzzle of that theme, or the theme's tile on the puzzle
    /// page, to trap on. The theme starts counting again from nothing.
    private static func wellFormed(_ stored: [String: Lossy<[Int]>]) -> [String: [Int]] {
        stored.compactMapValues { entry in
            entry.value.flatMap { $0.count >= 2 ? $0 : nil }
        }
    }

    /// The daily streak as it stands today: a streak whose last day was
    /// before yesterday has lapsed.
    func currentDailyStreak(today: Int) -> Int {
        // A last day well after today was counted some other way — see
        // `PuzzleStore.recordDailySolved` — and a streak cannot run from it.
        guard let last = dailyLastSolved, (-1...1).contains(today - last) else { return 0 }
        return dailyStreak
    }
}

/// The player's puzzle progress, kept in a file of `LocalStore.files`: the
/// puzzles seen and the rating's history alone grow to tens of kilobytes,
/// written again after every puzzle.
@Observable
@MainActor
final class PuzzleStore {
    static let shared = PuzzleStore()
    /// The file, named after the key 1.0.1 kept the progress under.
    private static let key = "puzzleProgress"

    @ObservationIgnored private var mirror: PuzzleProgress?
    @ObservationIgnored private var mirrorSource: FileStore?
    /// The changes made while the file did not read, to be made again to
    /// what is in it once it reads (see `update`).
    @ObservationIgnored private var unwritten: [(inout PuzzleProgress) -> Void] = []
    private(set) var revision = 0

    private init() {}

    /// A file that did not read is read again the next time, as the archive
    /// is (see `GameArchive.records`).
    var progress: PuzzleProgress {
        _ = revision
        let store = LocalStore.files
        if let mirror, mirrorSource === store { return mirror }
        let loaded = LocalStore.value(PuzzleProgress.self, inFile: Self.key) ?? PuzzleProgress()
        if !store.isUnread(Self.key) {
            mirror = loaded
            mirrorSource = store
        }
        return loaded
    }

    /// Makes `change` to the progress and saves it.
    ///
    /// A file that did not read turns every write away until it reads (see
    /// `FileStore.write`), and what was played meanwhile was played from a
    /// fresh start — the rating back at its first value — and lost at the
    /// next launch. So each change is kept until the file reads, and made
    /// again then to what is in it.
    private func update(_ change: @escaping (inout PuzzleProgress) -> Void) {
        let store = LocalStore.files
        var value = progress
        if store.isUnread(Self.key) {
            let filed = LocalStore.value(PuzzleProgress.self, inFile: Self.key)
            if store.isUnread(Self.key) {
                unwritten.append(change)
            } else {
                value = filed ?? PuzzleProgress()
                for change in unwritten { change(&value) }
                unwritten = []
            }
        }
        change(&value)
        mirror = value
        mirrorSource = LocalStore.files
        LocalStore.saveInBackground(value, toFile: Self.key)
        revision += 1
    }

    /// Records a rated attempt and returns the rating change.
    @discardableResult
    func recordRated(_ puzzle: Puzzle, solved: Bool) -> Double {
        var change = 0.0
        update { progress in
            let before = progress.rating
            progress.rating = PuzzleRating.updated(
                before, puzzle: puzzle.rating, solved: solved, attempts: progress.attempts
            )
            change = progress.rating - before
            progress.attempts += 1
            if solved { progress.solved += 1 }
            progress.history.append(progress.rating)
            if progress.history.count > PuzzleProgress.maxHistory {
                progress.history.removeFirst(progress.history.count - PuzzleProgress.maxHistory)
            }
            Self.markSeen(puzzle, in: &progress)
            for theme in puzzle.themes where PuzzleLibrary.curatedThemes.contains(theme) {
                // Well-formed as read (see `PuzzleProgress.init(from:)`); one
                // put in by hand since starts the theme over all the same.
                var result = progress.themeResults[theme].flatMap { $0.count >= 2 ? $0 : nil } ?? [0, 0]
                if solved { result[0] += 1 }
                result[1] += 1
                progress.themeResults[theme] = result
            }
        }
        noteSolvedCount()
        return change
    }

    /// Notes a puzzle solved in a race against the clock, which is what this
    /// is called for: seen, so that the rated puzzles pass it over, and — the
    /// first time it is seen — solved, for the puzzle achievements.
    ///
    /// Every solve in a race is a clean one: there is no hint there, no
    /// solution and no retry, and a wrong move costs a strike and moves on.
    /// But the easy puzzles every race begins with come round race after
    /// race, and counted every time, they would make Pattern Master a matter
    /// of starting enough races. So a puzzle seen before in any way counts
    /// for nothing, as one seen before is played unrated.
    func markSeen(_ puzzle: Puzzle) {
        var isNew = false
        update { progress in
            isNew = Self.markSeen(puzzle, in: &progress)
            if isNew { progress.unratedSolved += 1 }
        }
        if isNew { noteSolvedCount() }
    }

    /// Returns whether the puzzle was new.
    @discardableResult
    private static func markSeen(_ puzzle: Puzzle, in progress: inout PuzzleProgress) -> Bool {
        guard puzzle.source == .library, !progress.seen.contains(puzzle.id) else { return false }
        progress.seen.append(puzzle.id)
        if progress.seen.count > PuzzleProgress.maxSeen {
            progress.seen.removeFirst(progress.seen.count - PuzzleProgress.maxSeen)
        }
        return true
    }

    /// Counts one clean solve of a puzzle that is not rated — one of the
    /// player's own mistakes fixed (see `MistakeStore.recordAttempt`).
    fileprivate func recordUnratedSolve() {
        update { $0.unratedSolved += 1 }
        noteSolvedCount()
    }

    /// Puzzle Solver, Tactician and Pattern Master count every clean solve,
    /// whatever kind of puzzle it was. Only rated ones counted, so the first
    /// puzzle solved on the daily page, in a race or among the player's own
    /// mistakes earned nothing — "Solve your first puzzle" asked for the
    /// first rated one.
    private func noteSolvedCount() {
        let progress = self.progress
        Achievements.shared.puzzleProgress(solved: progress.puzzlesSolved, rating: progress.rating)
    }

    /// Records a finished rush; returns true for a new best.
    @discardableResult
    func recordRush(kind: String, score: Int) -> Bool {
        var isBest = false
        update { progress in
            if score > (progress.rushBest[kind] ?? 0) {
                progress.rushBest[kind] = score
                isBest = true
            }
        }
        Achievements.shared.rushFinished(score: score)
        return isBest
    }

    /// The daily puzzle of `day`, solved. It counts for the streak however it
    /// was solved — the streak is about turning up — but as a puzzle solved
    /// only when it was `clean`: no wrong move, no hint, not a retry. Once a
    /// day either way, so the same puzzle cannot be counted twice. Not known
    /// to be clean, it is not counted.
    ///
    /// The daily is one of the library's puzzles like any other, so solved it
    /// is `seen`: the rated puzzles pass it over afterwards rather than serve
    /// a known answer as a fresh one. And one seen before — met as a rated
    /// puzzle or in a race — counts for nothing again, as everywhere else.
    func recordDailySolved(_ puzzle: Puzzle? = nil, day: Int, clean: Bool = false) {
        var isNewDay = false
        var isNewPuzzle = true
        update { progress in
            // A day that is not newer than the last one changes nothing — the
            // same day solved twice, or yesterday's puzzle finished after
            // today's was already in. A last day further ahead than that was
            // numbered by the device's own calendar, as builds up to 1.0.1
            // did: under the Buddhist one it is some two hundred thousand
            // days ahead, and kept, it would stop every daily from counting
            // for centuries. The streak starts again from this day instead.
            if let last = progress.dailyLastSolved, (day...day + 1).contains(last) { return }
            isNewDay = true
            if let last = progress.dailyLastSolved, day - last == 1 {
                progress.dailyStreak += 1
            } else {
                progress.dailyStreak = 1
            }
            progress.dailyLastSolved = day
            progress.dailyBestStreak = max(progress.dailyBestStreak, progress.dailyStreak)
            if let puzzle { isNewPuzzle = Self.markSeen(puzzle, in: &progress) }
            if clean, isNewPuzzle { progress.unratedSolved += 1 }
        }
        Achievements.shared.dailyStreak(progress.dailyStreak)
        if isNewDay, clean, isNewPuzzle { noteSolvedCount() }
    }

    func isDailySolved(day: Int) -> Bool {
        progress.dailyLastSolved == day
    }

    func reset() {
        LocalStore.removeInBackground(file: Self.key)
        mirror = nil
        unwritten = []
        revision += 1
    }
}

// MARK: - The player's own mistakes

/// A position from one of the player's games where the review found a real
/// mistake, kept as a puzzle: find the move you should have played.
///
/// Nonisolated, like the game records, so that the list can be encoded and
/// written away from the main actor.
nonisolated struct MistakeEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The position before the opponent's last move, so the puzzle shows that
    /// move first — the way the game reached the moment.
    var fen: String
    var setupUCI: String?
    var bestUCI: String
    var playedSAN: String
    var quality: MoveQuality
    var foundAt: Date
    var attempts = 0
    var fixed = false

    var puzzle: Puzzle {
        Puzzle(
            id: id.uuidString, fen: fen, setup: setupUCI, solution: [bestUCI],
            rating: 0, themes: [], source: .mistake
        )
    }
}

nonisolated extension MistakeEntry {
    // Field by field, in an extension so the memberwise initializer stays.
    // The count and the flag have obvious defaults, and a grade this build
    // does not know is still a mistake worth fixing — none of them is reason
    // enough to lose the position. The keys are the synthesized ones.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fen = try container.decode(String.self, forKey: .fen)
        setupUCI = try container.decodeIfPresent(String.self, forKey: .setupUCI)
        bestUCI = try container.decode(String.self, forKey: .bestUCI)
        playedSAN = try container.decode(String.self, forKey: .playedSAN)
        quality = (try? container.decodeIfPresent(MoveQuality.self, forKey: .quality)) ?? .mistake
        foundAt = try container.decode(Date.self, forKey: .foundAt)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        fixed = try container.decodeIfPresent(Bool.self, forKey: .fixed) ?? false
    }
}

/// The player's mistakes to fix, and the games they were collected from,
/// each kept in a file of `LocalStore.files`.
@Observable
@MainActor
final class MistakeStore {
    static let shared = MistakeStore()
    /// The files, named after the keys 1.0.1 kept the two lists under.
    private static let key = "mistakes"
    static let maxEntries = 150

    /// The games `collect` has read, as digests, oldest first.
    private static let gamesKey = "mistakeGames"
    /// Well over the number of the player's own games the archive keeps
    /// (`GameArchive.maxRecords`), so no game that can still be opened is
    /// forgotten; a digest is a few bytes.
    static let maxGames = 1000

    @ObservationIgnored private var mirror: [MistakeEntry]?
    @ObservationIgnored private var mirrorSource: FileStore?
    @ObservationIgnored private var gamesMirror: [String]?
    @ObservationIgnored private var gamesMirrorSource: FileStore?
    private(set) var revision = 0

    private init() {}

    /// Newest first.
    ///
    /// A file that did not read is read again the next time, as the archive
    /// is, and joins what was added meanwhile once it reads (see
    /// `GameArchive.records`).
    var entries: [MistakeEntry] {
        _ = revision
        let store = LocalStore.files
        if let mirror, mirrorSource === store { return mirror }
        let loaded = LocalStore.list(of: MistakeEntry.self, inFile: Self.key)
        if !store.isUnread(Self.key) {
            mirror = loaded
            mirrorSource = store
        }
        return loaded
    }

    var pending: [MistakeEntry] { entries.filter { !$0.fixed } }
    var fixedCount: Int { entries.count { $0.fixed } }

    private func save(_ all: [MistakeEntry]) {
        var all = all
        if let filed = LocalStore.entriesMissing(from: all, inFile: Self.key, id: \.id) {
            all = Self.capped(all + filed)
        }
        mirror = all
        mirrorSource = LocalStore.files
        LocalStore.saveInBackground(all, toFile: Self.key)
        revision += 1
    }

    /// Over the cap, the fixed ones go first, then the oldest.
    private static func capped(_ all: [MistakeEntry]) -> [MistakeEntry] {
        var all = all
        while all.count > maxEntries {
            if let index = all.lastIndex(where: { $0.fixed }) {
                all.remove(at: index)
            } else {
                all.removeLast()
            }
        }
        return all
    }

    /// Digests of the games already read, oldest first. Read entry by entry
    /// like `entries`, so a store this build cannot read is kept aside rather
    /// than written over.
    private var collectedGames: [String] {
        let store = LocalStore.files
        if let gamesMirror, gamesMirrorSource === store { return gamesMirror }
        let loaded = LocalStore.list(of: String.self, inFile: Self.gamesKey)
        if !store.isUnread(Self.gamesKey) {
            gamesMirror = loaded
            gamesMirrorSource = store
        }
        return loaded
    }

    private func saveCollectedGames(_ games: [String]) {
        var games = games
        if let filed = LocalStore.entriesMissing(from: games, inFile: Self.gamesKey, id: { $0 }) {
            games = Array((filed + games).suffix(Self.maxGames))
        }
        gamesMirror = games
        gamesMirrorSource = LocalStore.files
        LocalStore.saveInBackground(games, toFile: Self.gamesKey)
    }

    /// A short name for a game that stays the same from one launch to the
    /// next: FNV-1a over its start, rules and moves. Swift's own `Hasher` is
    /// seeded afresh every launch, so it cannot name anything that has to be
    /// recognised again tomorrow.
    static func digest(of game: Game) -> String {
        let text = ([game.initialFEN, game.variant.rawValue] + game.history.map(\.move.uci))
            .joined(separator: " ")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Takes the real mistakes of `colors` out of a finished report. Only
    /// mistakes, misses and blunders — an inaccuracy is rarely a puzzle with
    /// one clear answer — and only where the engine's move was clearly the
    /// best, so the puzzle has an answer worth finding.
    ///
    /// Each game is read once. Its review finishes again every time it is
    /// opened, and the positions already stored were all this used to check
    /// against — so every mistake no longer stored came back, and the fixed
    /// ones are the first to go when the store is full. Opening an old review
    /// handed the player puzzles they had already solved. A new game that
    /// walks into the same mistake is another matter, and is collected again
    /// once the old entry has gone.
    func collect(from analysis: GameAnalysis, game: Game, colors: [PieceColor]) {
        let digest = Self.digest(of: game)
        var games = collectedGames
        guard !games.contains(digest) else { return }
        games.append(digest)
        if games.count > Self.maxGames {
            games.removeFirst(games.count - Self.maxGames)
        }
        saveCollectedGames(games)

        let jobs = GameAnalyzer.positions(of: game)
        var all = entries
        var known = Set(all.map { $0.fen + $0.bestUCI })
        var added: [MistakeEntry] = []
        for move in analysis.moves where colors.contains(move.color) {
            guard [.mistake, .miss, .blunder].contains(move.quality), !move.isBestMove,
                  move.pointsLost >= 10 else { continue }
            // Shown from the move before, so the opponent's move that set the
            // problem plays first. The opening move of a game has none.
            let ply = move.ply
            let fen: String
            let setup: String?
            if ply > 0, ply - 1 < jobs.count {
                fen = jobs[ply - 1].board.fen
                setup = game.history[ply - 1].move.uci
            } else {
                fen = move.board.fen
                setup = nil
            }
            let key = fen + move.bestMove.uci
            guard !known.contains(key) else { continue }
            known.insert(key)
            added.append(MistakeEntry(
                id: UUID(), fen: fen, setupUCI: setup, bestUCI: move.bestMove.uci,
                playedSAN: move.played.san, quality: move.quality, foundAt: Date()
            ))
        }
        guard !added.isEmpty else { return }
        all.insert(contentsOf: added, at: 0)
        save(Self.capped(all))
    }

    /// `solved` is a clean solve — no wrong move, no hint, no solution, not a
    /// retry — and fixes the mistake. Fixing one is also a puzzle solved, the
    /// first time only: a fixed mistake leaves the queue, and one solved
    /// again regardless counts for nothing more.
    func recordAttempt(_ id: MistakeEntry.ID, solved: Bool) {
        var all = entries
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let isFix = solved && !all[index].fixed
        all[index].attempts += 1
        if solved { all[index].fixed = true }
        save(all)
        if solved { Achievements.shared.mistakesFixed(fixedCount) }
        if isFix { PuzzleStore.shared.recordUnratedSolve() }
    }

    func remove(_ id: MistakeEntry.ID) {
        save(entries.filter { $0.id != id })
    }

    /// Forgets the games read as well, so that reviewing one again starts the
    /// collection over rather than finding it already done.
    func reset() {
        LocalStore.removeInBackground(file: Self.key)
        LocalStore.removeInBackground(file: Self.gamesKey)
        mirror = nil
        gamesMirror = nil
        revision += 1
    }
}
