//
//  Statistics.swift
//  chess
//
//  What the archive adds up to: results by level, by colour and by time
//  control, streaks, accuracy over time, and a rough idea of how strong the
//  player is.
//

import Foundation

/// Wins, draws and losses.
struct ResultTally: Hashable, Sendable {
    var wins = 0
    var draws = 0
    var losses = 0

    var games: Int { wins + draws + losses }
    /// Points per game, a draw counting a half.
    var score: Double? { games == 0 ? nil : (Double(wins) + Double(draws) / 2) / Double(games) }

    mutating func add(_ playerScore: Double) {
        if playerScore >= 1 { wins += 1 } else if playerScore <= 0 { losses += 1 } else { draws += 1 }
    }
}

struct GameStatistics: Sendable {
    /// Games played in the app (imports are counted apart).
    let played: Int
    let imported: Int
    let twoPlayer: Int
    /// The results against the computer, and those below, leave out games
    /// begun from a set-up position (see `GameRecord.recordScore`); `played`
    /// counts them.
    let vsComputer: ResultTally
    let byLevel: [AIDifficulty: ResultTally]
    let byColor: [PieceColor: ResultTally]
    /// Keyed by the category's raw value, or "none" for games without a clock.
    let byTimeControl: [String: ResultTally]
    let currentStreak: Int
    let bestStreak: Int
    /// The player's own accuracy in each reviewed game against the computer,
    /// oldest first.
    let accuracyHistory: [Double]
    /// Seconds spent at the board, over every game that recorded its times.
    let totalTime: TimeInterval
    /// Rough strength from the results against the computer — see
    /// `performance(of:)`. Nil until there are enough games to say anything.
    let estimatedRating: Int?

    /// Very rough club ratings for the levels, used only to turn results into
    /// a ballpark figure. The engine has never been rated against people, so
    /// these are an estimate from how the levels search, and the app says as
    /// much wherever the figure appears.
    static func approximateRating(level: Double) -> Double {
        let anchors: [Double] = [500, 800, 1100, 1500, 1900]
        let clamped = min(4, max(0, level))
        let lower = Int(clamped.rounded(.down))
        let upper = min(4, lower + 1)
        return anchors[lower] + (anchors[upper] - anchors[lower]) * (clamped - Double(lower))
    }

    static func level(of record: GameRecord) -> Double? {
        guard case .vsAI(let difficulty, _) = record.mode else { return nil }
        if difficulty == .adaptive { return record.options.adaptiveLevel ?? 1.5 }
        return AIDifficulty.fixedLevels.firstIndex(of: difficulty).map(Double.init)
    }

    init(records: [GameRecord]) {
        let own = records.filter { $0.source == .played }
        played = own.count
        imported = records.count - own.count
        twoPlayer = own.count { !$0.mode.isVsAI }

        var vsComputer = ResultTally()
        var byLevel: [AIDifficulty: ResultTally] = [:]
        var byColor: [PieceColor: ResultTally] = [:]
        var byTime: [String: ResultTally] = [:]
        var accuracy: [Double] = []
        var totalTime: TimeInterval = 0

        // Oldest first, so streaks run forward in time. A game from a set-up
        // position is time at the board, but no result against the computer:
        // it may have been won before a move was made (see
        // `GameRecord.recordScore`). Its accuracy is left out with it, for
        // the same reason — in a position won from the start nearly every
        // move keeps the win and grades as exact.
        for record in own.reversed() {
            totalTime += record.moveTimes.reduce(0, +)
            guard let score = record.recordScore, let color = record.humanColor,
                  case .vsAI(let difficulty, _) = record.mode else { continue }
            vsComputer.add(score)
            byLevel[difficulty, default: ResultTally()].add(score)
            byColor[color, default: ResultTally()].add(score)
            byTime[record.options.timeControl?.category.rawValue ?? "none", default: ResultTally()].add(score)
            // The pair is whatever was stored, and one cut short must not trap.
            let index = Int(color.rawValue)
            if let measured = record.accuracy, measured.indices.contains(index), let value = measured[index] {
                accuracy.append(value)
            }
        }

        var current = 0
        var best = 0
        // A set-up game neither adds to a run nor breaks it.
        for score in own.reversed().compactMap(\.recordScore) {
            if score >= 1 {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }

        self.vsComputer = vsComputer
        self.byLevel = byLevel
        self.byColor = byColor
        self.byTimeControl = byTime
        self.currentStreak = current
        self.bestStreak = best
        self.accuracyHistory = accuracy
        self.totalTime = totalTime
        self.estimatedRating = Self.performance(of: own)
    }

    /// A performance rating over the last thirty games against the computer:
    /// the average strength of the opposition, plus four hundred points for
    /// every game won more than lost per game played — the old linear
    /// formula, which is good enough for "roughly where do I stand". Games
    /// from set-up positions are not among them: a won position set up
    /// against Grandmaster counted as a win at Grandmaster strength.
    static func performance(of records: [GameRecord]) -> Int? {
        let recent = records.filter { $0.recordScore != nil && level(of: $0) != nil }.prefix(30)
        guard recent.count >= 5 else { return nil }
        var opposition = 0.0
        var balance = 0.0
        for record in recent {
            opposition += approximateRating(level: level(of: record) ?? 0)
            balance += (record.recordScore ?? 0.5) * 2 - 1
        }
        let count = Double(recent.count)
        let rating = opposition / count + 400 * balance / count
        return Int(min(2600, max(200, rating)).rounded())
    }

    var averageAccuracy: Double? {
        accuracyHistory.isEmpty ? nil : accuracyHistory.reduce(0, +) / Double(accuracyHistory.count)
    }
}
