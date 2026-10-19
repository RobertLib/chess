//
//  Achievements.swift
//  chess
//
//  Small milestones, earned and kept on the device — no Game Center, no
//  account, no network. Checked whenever something they could be about
//  happens: a game ends, a review lands, a puzzle is solved.
//

import Foundation

// MARK: - Definitions

struct Achievement: Identifiable, Hashable, Sendable {
    enum ID: String, CaseIterable, Codable, Sendable {
        case firstGame, firstWin
        case beatBeginner, beatEasy, beatMedium, beatHard, beatGrandmaster
        case winWithBlackHard, quickMate, knightMate, pawnMate
        case winOnTime, bulletWin, chess960Game, handicapWin
        case precision, brilliant, hatTrick, regular, veteran, adaptiveTop
        case firstPuzzle, puzzles50, puzzles250, puzzleRating1500, puzzleRating2000
        case rush15, dailyStreak7, mistakesFixed10
        case allLessons, openings5
    }

    let id: ID
    let systemImage: String
    /// Held as resources rather than resolved strings — the list is a
    /// `static let`, and a `String(localized:)` inside one would be frozen in
    /// whatever language first asked for it. Same reasoning as `BoardTheme`.
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    static func == (lhs: Achievement, rhs: Achievement) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [Achievement] = [
        Achievement(id: .firstGame, systemImage: "flag.checkered",
                    title: "First Game", detail: "Finish a game."),
        Achievement(id: .firstWin, systemImage: "crown.fill",
                    title: "First Victory", detail: "Beat the computer."),
        Achievement(id: .beatBeginner, systemImage: "1.circle.fill",
                    title: "First Steps", detail: "Beat the Beginner level."),
        Achievement(id: .beatEasy, systemImage: "2.circle.fill",
                    title: "Getting There", detail: "Beat the Easy level."),
        Achievement(id: .beatMedium, systemImage: "3.circle.fill",
                    title: "Club Player", detail: "Beat the Medium level."),
        Achievement(id: .beatHard, systemImage: "4.circle.fill",
                    title: "Tough Nut Cracked", detail: "Beat the Hard level."),
        Achievement(id: .beatGrandmaster, systemImage: "5.circle.fill",
                    title: "Giant Slayer", detail: "Beat the Grandmaster level."),
        Achievement(id: .winWithBlackHard, systemImage: "moon.stars.fill",
                    title: "From the Shadows", detail: "Beat Hard or Grandmaster with Black."),
        Achievement(id: .quickMate, systemImage: "bolt.fill",
                    title: "Short and Sweet", detail: "Checkmate the computer within 20 moves."),
        Achievement(id: .knightMate, systemImage: "figure.equestrian.sports",
                    title: "Knight's Tale", detail: "Checkmate the computer with a knight."),
        Achievement(id: .pawnMate, systemImage: "person.fill",
                    title: "Humble Hero", detail: "Checkmate the computer with a pawn."),
        Achievement(id: .winOnTime, systemImage: "timer",
                    title: "Flag Fall", detail: "Beat the computer on time."),
        Achievement(id: .bulletWin, systemImage: "hare.fill",
                    title: "Lightning Hands", detail: "Beat the computer in a bullet game."),
        Achievement(id: .chess960Game, systemImage: "shuffle",
                    title: "Fischer's Way", detail: "Finish a Chess960 game."),
        Achievement(id: .handicapWin, systemImage: "gift.fill",
                    title: "Generous Opponent", detail: "Beat the computer in a game at odds."),
        Achievement(id: .precision, systemImage: "scope",
                    title: "Precision", detail: "Reach 90% accuracy in a reviewed game of 15 moves or more."),
        Achievement(id: .brilliant, systemImage: "sparkles",
                    title: "Brilliant!", detail: "Play a move the review grades as brilliant."),
        Achievement(id: .hatTrick, systemImage: "3.square.fill",
                    title: "Hat Trick", detail: "Beat the computer three games in a row."),
        Achievement(id: .regular, systemImage: "calendar",
                    title: "Regular", detail: "Finish 10 games."),
        Achievement(id: .veteran, systemImage: "medal.fill",
                    title: "Veteran", detail: "Finish 50 games."),
        Achievement(id: .adaptiveTop, systemImage: "chart.line.uptrend.xyaxis",
                    title: "Unstoppable", detail: "Push the adaptive opponent up to Grandmaster strength."),
        Achievement(id: .firstPuzzle, systemImage: "puzzlepiece.fill",
                    title: "Puzzle Solver", detail: "Solve your first puzzle."),
        Achievement(id: .puzzles50, systemImage: "puzzlepiece.extension.fill",
                    title: "Tactician", detail: "Solve 50 puzzles."),
        Achievement(id: .puzzles250, systemImage: "brain.head.profile",
                    title: "Pattern Master", detail: "Solve 250 puzzles."),
        Achievement(id: .puzzleRating1500, systemImage: "arrow.up.right.circle.fill",
                    title: "Sharp Eye", detail: "Reach a puzzle rating of 1500."),
        Achievement(id: .puzzleRating2000, systemImage: "eye.fill",
                    title: "Hawk Eye", detail: "Reach a puzzle rating of 2000."),
        Achievement(id: .rush15, systemImage: "stopwatch.fill",
                    title: "Rush Hour", detail: "Solve 15 puzzles in a race against the clock."),
        Achievement(id: .dailyStreak7, systemImage: "flame.fill",
                    title: "Week of Puzzles", detail: "Solve the daily puzzle seven days in a row."),
        Achievement(id: .mistakesFixed10, systemImage: "arrow.uturn.backward.circle.fill",
                    title: "Learning from Mistakes", detail: "Fix 10 of your own mistakes."),
        Achievement(id: .allLessons, systemImage: "graduationcap.fill",
                    title: "Graduate", detail: "Read every lesson of How to Play."),
        Achievement(id: .openings5, systemImage: "book.fill",
                    title: "Opening Repertoire", detail: "Learn five opening lines."),
    ]

    static func definition(_ id: ID) -> Achievement {
        all.first { $0.id == id }!
    }
}

// MARK: - Progress

@Observable
@MainActor
final class Achievements {
    static let shared = Achievements()

    private static let key = "achievements"

    /// The achievement just earned, for the banner. Cleared by whoever shows it.
    var justUnlocked: [Achievement] = []

    @ObservationIgnored private var mirror: [Achievement.ID: Date]?
    @ObservationIgnored private var mirrorSource: UserDefaults?
    private(set) var revision = 0

    private init() {}

    /// When each earned achievement was earned.
    ///
    /// Read entry by entry, the way `LocalStore.list` reads a list: an entry
    /// this build cannot read — a damaged date, or an achievement only a
    /// later version knows — costs only itself. Whatever is left out, or the
    /// whole store when it does not read at all, is copied aside first,
    /// because the next achievement earned writes back only what was read.
    /// Read as a whole, one bad entry made everything earned read as nothing,
    /// and the next unlock wrote that over it.
    var unlocked: [Achievement.ID: Date] {
        _ = revision
        let store = LocalStore.defaults
        if let mirror, mirrorSource === store { return mirror }
        let stored = LocalStore.value([String: Lossy<Date>].self, forKey: Self.key) ?? [:]
        var loaded: [Achievement.ID: Date] = [:]
        for (raw, entry) in stored {
            if let id = Achievement.ID(rawValue: raw), let date = entry.value { loaded[id] = date }
        }
        if loaded.count < stored.count, let data = store.data(forKey: Self.key) {
            LocalStore.setAside(data, forKey: Self.key)
        }
        mirror = loaded
        mirrorSource = store
        return loaded
    }

    func isUnlocked(_ id: Achievement.ID) -> Bool { unlocked[id] != nil }

    private func unlock(_ ids: [Achievement.ID]) {
        var current = unlocked
        let fresh = ids.filter { current[$0] == nil }
        guard !fresh.isEmpty else { return }
        let date = Date()
        for id in fresh { current[id] = date }
        mirror = current
        mirrorSource = LocalStore.defaults
        let encoded = Dictionary(uniqueKeysWithValues: current.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            LocalStore.defaults.set(data, forKey: Self.key)
        }
        revision += 1
        justUnlocked.append(contentsOf: fresh.map(Achievement.definition))
        SoundManager.shared.play(.achievement)
    }

    func reset() {
        LocalStore.defaults.removeObject(forKey: Self.key)
        mirror = nil
        revision += 1
    }

    // MARK: Events

    /// `archive` is every game including this one, newest first.
    ///
    /// A game begun from a set-up position finishes a game like any other,
    /// but wins nothing: the position may have been won before a move was
    /// made (see `GameRecord.recordScore`). That covers the mates as well —
    /// a knight's or a pawn's is a few seconds' work to set up — and the
    /// flag: any position can be put on a clock. A game at odds is a real
    /// game, and earns everything a win earns, Generous Opponent besides.
    ///
    /// A game between two people on one device finishes a game too, and
    /// counts towards Regular, Veteran and Fischer's Way, but wins nothing:
    /// there is no "you" in it to have won. Every mate or flag in one was
    /// taken as the player's own, so one person playing both sides — or
    /// leaving a 1 + 0 clock to run down — had Flag Fall, a knight's mate, a
    /// pawn's and Generous Opponent each for a minute's work.
    func gameFinished(_ record: GameRecord, archive: [GameRecord]) {
        var earned: [Achievement.ID] = [.firstGame]
        let played = archive.filter { $0.source == .played }
        if played.count >= 10 { earned.append(.regular) }
        if played.count >= 50 { earned.append(.veteran) }
        if record.options.start.isChess960 { earned.append(.chess960Game) }

        let winner = record.outcome.winner
        let canWin = !record.startsFromSetUpPosition
        var humanWon = false
        if case .vsAI(let difficulty, let color) = record.mode {
            humanWon = canWin && winner == color
            if humanWon {
                earned.append(.firstWin)
                switch difficulty {
                case .beginner: earned.append(.beatBeginner)
                case .easy: earned.append(.beatEasy)
                case .medium: earned.append(.beatMedium)
                case .hard: earned.append(.beatHard)
                case .expert: earned.append(.beatGrandmaster)
                case .adaptive:
                    // The level it stood at is what was beaten.
                    let level = record.options.adaptiveLevel ?? 0
                    let beaten: [Achievement.ID] = [.beatBeginner, .beatEasy, .beatMedium, .beatHard, .beatGrandmaster]
                    earned.append(contentsOf: beaten.prefix(Int(level.rounded(.down)) + 1))
                }
                if color == .black, difficulty == .hard || difficulty == .expert {
                    earned.append(.winWithBlackHard)
                }
                if case .checkmate = record.outcome, record.moveCount <= 20 { earned.append(.quickMate) }
                if record.options.timeControl?.category == .bullet { earned.append(.bulletWin) }
                if case .handicap = record.options.start { earned.append(.handicapWin) }
            }
            // Reaching the top is noticed where the level moves, by
            // `adaptiveLevelReached`. A game begun up there earns it as well,
            // for a level that got there under 1.0.1, which only looked here
            // — at the level the game began at — and so passed over the win
            // that took it up.
            if case .vsAI(.adaptive, _) = record.mode,
               (record.options.adaptiveLevel ?? 0) >= Self.topAdaptiveLevel {
                earned.append(.adaptiveTop)
            }
            // Three wins in a row against the computer. A game from a set-up
            // position is no part of the run, neither adding to it nor
            // breaking it.
            let streak = played.lazy.compactMap(\.recordScore).prefix(3)
            if streak.count == 3, streak.allSatisfy({ $0 == 1 }) { earned.append(.hatTrick) }
        }

        if humanWon {
            if case .timeForfeit = record.outcome { earned.append(.winOnTime) }
            if case .checkmate = record.outcome, let game = record.restoreGame(),
               let mating = game.history.last?.move {
                if mating.piece.kind == .knight { earned.append(.knightMate) }
                if mating.piece.kind == .pawn, mating.promotion == nil { earned.append(.pawnMate) }
            }
        }
        unlock(earned)
    }

    /// Where the adaptive opponent's level counts as Grandmaster strength,
    /// on the 0...4 scale of `AIStrength.interpolated`.
    private static let topAdaptiveLevel = 3.95

    /// The adaptive opponent's level, just moved by a game against it (see
    /// `AppSettings.recordAdaptiveResult`). Checked as the level moves rather
    /// than from the finished game's record, which carries the level the game
    /// began at and so is one game behind: read from there, the win that took
    /// the opponent to the top earned nothing, and the next game did — even
    /// a lost one.
    func adaptiveLevelReached(_ level: Double) {
        if level >= Self.topAdaptiveLevel { unlock([.adaptiveTop]) }
    }

    func gameReviewed(_ record: GameRecord) {
        // A master game read from PGN is somebody else's accuracy. A game
        // from a set-up position earns none either: in a position won from
        // the start nearly every move keeps the win, and is graded as exact
        // as the best one — fifteen moves of a king and queen against a
        // lone king came to Precision.
        guard record.source == .played, !record.startsFromSetUpPosition,
              let accuracy = record.accuracy, record.moveCount >= 15 else { return }
        let colors: [PieceColor] = record.humanColor.map { [$0] } ?? [.white, .black]
        // The pair is whatever was stored, and one cut short must not trap.
        let best = colors.compactMap { color -> Double? in
            let index = Int(color.rawValue)
            return accuracy.indices.contains(index) ? accuracy[index] : nil
        }.max() ?? 0
        if best >= 90 { unlock([.precision]) }
    }

    func playedBrilliantMove() { unlock([.brilliant]) }

    func puzzleProgress(solved: Int, rating: Double) {
        var earned: [Achievement.ID] = []
        if solved >= 1 { earned.append(.firstPuzzle) }
        if solved >= 50 { earned.append(.puzzles50) }
        if solved >= 250 { earned.append(.puzzles250) }
        if rating >= 1500 { earned.append(.puzzleRating1500) }
        if rating >= 2000 { earned.append(.puzzleRating2000) }
        unlock(earned)
    }

    func rushFinished(score: Int) {
        if score >= 15 { unlock([.rush15]) }
    }

    func dailyStreak(_ days: Int) {
        if days >= 7 { unlock([.dailyStreak7]) }
    }

    func mistakesFixed(_ count: Int) {
        if count >= 10 { unlock([.mistakesFixed10]) }
    }

    func lessonsRead(_ count: Int, of total: Int) {
        if count >= total { unlock([.allLessons]) }
    }

    func openingsLearned(_ count: Int) {
        if count >= 5 { unlock([.openings5]) }
    }
}
