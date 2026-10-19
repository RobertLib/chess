//
//  ChessClock.swift
//  chess
//
//  Time controls and the clock that runs them: Fischer increment, simple
//  (US) delay and Bronstein delay, pausing, and what happens when a flag
//  falls. Pure Swift with no clock of its own — every call is handed "now" in
//  monotonic seconds, which is what lets the tests drive it to the hundredth.
//

import Foundation

// MARK: - Time control

/// How much time each player gets, and what is given back per move.
nonisolated struct TimeControl: Hashable, Codable, Sendable, Identifiable {

    /// What a player gets back for making a move.
    enum Bonus: String, Hashable, Codable, Sendable, CaseIterable {
        /// Fischer: the bonus is added after every move, used or not. What
        /// online play and nearly every tournament means by "3 + 2".
        case increment
        /// Simple (US) delay: the clock waits `bonus` seconds before it starts
        /// to run. Nothing is ever added, so time cannot be banked.
        case delay
        /// Bronstein: the time used is given back after the move, up to
        /// `bonus`. Ends in the same place as `delay`, but the clock visibly
        /// runs and then refills.
        case bronstein
    }

    /// Seconds each player starts with.
    var initial: TimeInterval
    /// Seconds of increment or delay, depending on `bonusKind`.
    var bonus: TimeInterval
    var bonusKind: Bonus = .increment
    /// Black's starting time when it differs from White's — time odds, which
    /// the stand-alone clock offers for a stronger player giving a weaker one
    /// a head start. Nil when both start level, which is every game the app
    /// plays itself.
    var initialBlack: TimeInterval?

    init(initial: TimeInterval, bonus: TimeInterval, bonusKind: Bonus = .increment, initialBlack: TimeInterval? = nil) {
        self.initial = initial
        self.bonus = bonus
        self.bonusKind = bonusKind
        self.initialBlack = initialBlack
    }

    /// `minutes + seconds`, the way the presets are written.
    static func minutes(_ minutes: Double, plus seconds: Double) -> TimeControl {
        TimeControl(initial: minutes * 60, bonus: seconds)
    }

    var id: String {
        let black = initialBlack.map { "/\(Int($0))" } ?? ""
        return "\(Int(initial))\(black)+\(Int(bonus))\(bonusKind.rawValue)"
    }

    func initialTime(for color: PieceColor) -> TimeInterval {
        color == .black ? (initialBlack ?? initial) : initial
    }

    // MARK: Categories

    /// The usual buckets. The boundaries are Lichess's: a game is classed by
    /// its estimated length, the base time plus forty moves of increment, so
    /// 2 + 1 counts as bullet and 3 + 2 as blitz the way players expect.
    enum Category: String, Hashable, Codable, Sendable, CaseIterable {
        case bullet, blitz, rapid, classical
    }

    var category: Category {
        let estimate = max(initial, initialBlack ?? 0) + 40 * bonus
        switch estimate {
        case ..<179: return .bullet
        case ..<479: return .blitz
        case ..<1499: return .rapid
        default: return .classical
        }
    }

    // MARK: Presets

    /// The controls offered with one tap — the ones online play has settled
    /// on, three or so per category.
    static let presets: [TimeControl] = [
        .minutes(1, plus: 0), .minutes(2, plus: 1),
        .minutes(3, plus: 0), .minutes(3, plus: 2), .minutes(5, plus: 0), .minutes(5, plus: 3),
        .minutes(10, plus: 0), .minutes(10, plus: 5), .minutes(15, plus: 10),
        .minutes(30, plus: 0), .minutes(30, plus: 20), .minutes(60, plus: 30),
    ]

    // MARK: Display

    /// "3 + 2", "½ + 0", "1½ + 1". Digits and fractions only, so the label
    /// needs no translation; the bonus kind is said separately where it is
    /// not the plain increment.
    var label: String {
        let black = initialBlack.map { " / " + Self.minutesText($0) } ?? ""
        return "\(Self.minutesText(initial))\(black) + \(Int(bonus.rounded()))"
    }

    /// Minutes as players write them: whole numbers, and the quarters a
    /// sub-minute game is usually given in.
    static func minutesText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds) / 60
        let rest = Int(seconds) % 60
        let fraction: String
        switch rest {
        case 0: fraction = ""
        case 15: fraction = "¼"
        case 30: fraction = "½"
        case 45: fraction = "¾"
        default:
            // Odd seconds have no fraction sign; m:ss reads unambiguously.
            return String(format: "%d:%02d", whole, rest)
        }
        if whole == 0 { return fraction.isEmpty ? "0" : fraction }
        return "\(whole)\(fraction)"
    }
}

nonisolated extension TimeControl {
    /// Read leniently. A control rides along in every archived timed game and
    /// in the game in progress, so one written without a bonus kind, or with
    /// a kind a later version added, reads as the plain increment rather than
    /// taking the record it belongs to down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initial = try container.decode(TimeInterval.self, forKey: .initial)
        bonus = try container.decodeIfPresent(TimeInterval.self, forKey: .bonus) ?? 0
        bonusKind = (try? container.decodeIfPresent(Bonus.self, forKey: .bonusKind)) ?? .increment
        initialBlack = try container.decodeIfPresent(TimeInterval.self, forKey: .initialBlack)
    }
}

// MARK: - Clock

/// A two-sided game clock.
///
/// The clock keeps no timer. Each side's committed time is stored, and the
/// side on turn has its current stretch measured from the timestamp it began
/// at, so reading the face at any moment is arithmetic — nothing drifts with a
/// timer that fires late, and a view can redraw as often or as seldom as it
/// likes. Timestamps are monotonic seconds supplied by the caller
/// (`ProcessInfo.systemUptime` in the app): wall-clock time can jump when the
/// user or the network changes it, and a clock must never run backwards.
nonisolated struct ChessClock: Hashable, Codable, Sendable {
    let control: TimeControl

    /// Time each side has left as of its last commit, `[white, black]`.
    private(set) var committed: [TimeInterval]
    /// Moves completed per side, `[white, black]` — the stand-alone clock
    /// shows them, the way a tournament clock's move counter does.
    private(set) var moves: [Int]
    /// The side whose turn it is, or nil before the first press and after the
    /// clock has been stopped for good.
    private(set) var active: PieceColor?
    /// Time the active side has already used on this turn before the current
    /// stretch — a turn interrupted by a pause is still one turn, and both the
    /// delay and the time-per-move figure care about the whole of it.
    private var usedThisTurn: TimeInterval = 0
    /// When the current stretch began. Nil while paused. Not stored: a clock
    /// read back from disk is a clock that was paused when it was saved.
    private var stretchStart: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case control, committed, moves, active, usedThisTurn
    }

    init(control: TimeControl) {
        self.control = control
        self.committed = [control.initialTime(for: .white), control.initialTime(for: .black)]
        self.moves = [0, 0]
    }

    /// Read leniently where a field can be done without — the move counter,
    /// the time already spent on the turn — so that the game in progress is
    /// not lost behind Continue for want of one. The times themselves cannot
    /// be guessed, and a clock without them is refused.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(TimeControl.self, forKey: .control)
        committed = try container.decode([TimeInterval].self, forKey: .committed)
        moves = (try? container.decodeIfPresent([Int].self, forKey: .moves)) ?? [0, 0]
        active = try? container.decodeIfPresent(PieceColor.self, forKey: .active)
        usedThisTurn = (try? container.decodeIfPresent(TimeInterval.self, forKey: .usedThisTurn)) ?? 0
        guard committed.count == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .committed, in: container, debugDescription: "A clock keeps one time per side."
            )
        }
        if moves.count != 2 { moves = [0, 0] }
    }

    // MARK: State

    /// True while time is actually passing for someone.
    var isRunning: Bool { active != nil && stretchStart != nil }

    /// True when a side is on turn but its time is held — the app went to
    /// the background, or the player asked for a pause.
    var isPaused: Bool { active != nil && stretchStart == nil }

    /// True once the clock has been started at least once.
    var hasStarted: Bool { active != nil || moves != [0, 0] }

    func moveCount(for color: PieceColor) -> Int { moves[Int(color.rawValue)] }

    /// How long the side on turn has been thinking about this move.
    func turnElapsed(at now: TimeInterval) -> TimeInterval {
        usedThisTurn + (stretchStart.map { max(0, now - $0) } ?? 0)
    }

    /// What the face shows for `color` at `now`. Never negative.
    func remaining(for color: PieceColor, at now: TimeInterval) -> TimeInterval {
        let base = committed[Int(color.rawValue)]
        guard color == active else { return base }
        let elapsed = turnElapsed(at: now)
        switch control.bonusKind {
        case .delay:
            // The clock only starts eating into the bank once the delay is
            // spent.
            return max(0, base - max(0, elapsed - control.bonus))
        case .increment, .bronstein:
            return max(0, base - elapsed)
        }
    }

    /// The side whose time has run out, if any. Only the side on turn can
    /// flag: the other one's clock is not running.
    func flagged(at now: TimeInterval) -> PieceColor? {
        guard let side = active, remaining(for: side, at: now) <= 0 else { return nil }
        return side
    }

    /// How much of the side on turn's delay is still to come: the time before
    /// its face starts to run down. Zero under the other bonuses, and with
    /// nobody on turn.
    func delayLeft(at now: TimeInterval) -> TimeInterval {
        guard control.bonusKind == .delay, active != nil else { return 0 }
        return max(0, control.bonus - turnElapsed(at: now))
    }

    /// Seconds until the side on turn runs out, or nil when nothing is
    /// running. Used to schedule the wake-up that notices a flag falling.
    func timeUntilFlag(at now: TimeInterval) -> TimeInterval? {
        guard isRunning, let side = active else { return nil }
        return remaining(for: side, at: now) + delayLeft(at: now)
    }

    // MARK: Driving

    /// Starts `color`'s clock from cold: the first move of a game, or the
    /// first tap on the stand-alone clock.
    mutating func start(_ color: PieceColor, at now: TimeInterval) {
        active = color
        usedThisTurn = 0
        stretchStart = now
    }

    /// Ends the turn of the side on move: charges it the time it used, gives
    /// back whatever the bonus says, and hands the turn to the other side.
    /// Returns how long the turn took, for the time-per-move record.
    ///
    /// Pressing while paused is allowed — the computer's search does not stop
    /// when the app does — and leaves the clock paused on the other side, so
    /// the move lands but no time passes until the game is resumed.
    @discardableResult
    mutating func press(at now: TimeInterval) -> TimeInterval {
        guard let side = active else { return 0 }
        let used = turnElapsed(at: now)
        var left = remaining(for: side, at: now)
        switch control.bonusKind {
        case .increment: left += control.bonus
        case .bronstein: left += min(used, control.bonus)
        case .delay: break
        }
        let index = Int(side.rawValue)
        committed[index] = left
        moves[index] += 1
        active = side.opponent
        usedThisTurn = 0
        stretchStart = stretchStart == nil ? nil : now
        return used
    }

    /// Holds the side on turn's time.
    mutating func pause(at now: TimeInterval) {
        guard let start = stretchStart else { return }
        usedThisTurn += max(0, now - start)
        stretchStart = nil
    }

    /// Lets the side on turn's time run again.
    mutating func resume(at now: TimeInterval) {
        guard active != nil, stretchStart == nil else { return }
        stretchStart = now
    }

    /// Stops the clock for good — the game is over. What was left stays on
    /// the faces, so the result card can still say how much time remained.
    mutating func stop(at now: TimeInterval) {
        if let side = active {
            committed[Int(side.rawValue)] = remaining(for: side, at: now)
        }
        active = nil
        usedThisTurn = 0
        stretchStart = nil
    }

    /// A copy fit for saving: paused at `now`, with nothing lost.
    func pausedCopy(at now: TimeInterval) -> ChessClock {
        var copy = self
        copy.pause(at: now)
        return copy
    }
}

// MARK: - Flag fall

nonisolated extension Board {

    /// Whether `color` could still checkmate by *some* series of legal moves,
    /// however unlikely — the test FIDE (article 6.9) puts to a flag fall: the
    /// player whose time ran out loses, unless the opponent could never have
    /// mated them, in which case it is a draw.
    ///
    /// The answer has to allow for the loser's own pieces, because they can
    /// box their king in: a lone knight cannot force mate, but against a king
    /// with a pawn beside it a mate exists. Not every piece will do, though:
    /// a queen boxing its king in always has the checking knight in its
    /// sights, and a rook or a queen can always step into a bishop's check or
    /// take the bishop. So a single knight counts when the other side has
    /// anything but queens, and bishops all on one colour count when the other
    /// side has a knight, a pawn or a bishop on the other colour. That is
    /// Lichess's rule; it misses only contrived positions where even a
    /// helpmate is impossible for reasons of geometry, which no clock rule
    /// anywhere tries to see.
    func hasMatingMaterial(_ color: PieceColor) -> Bool {
        // A king can always walk for the hill, and any piece can give a
        // check — so in the variants the question is only whether there is
        // anything to win with at all.
        switch variant {
        case .kingOfTheHill:
            return true
        case .threeCheck:
            return (0..<64).contains { piece(at: $0).map { $0.color == color && $0.kind != .king } ?? false }
        case .standard:
            break
        }
        var knights = 0
        var lightBishops = 0
        var darkBishops = 0
        var defenderHasNonQueen = false
        var defenderHasKnightOrPawn = false
        var defenderHasLightBishop = false
        var defenderHasDarkBishop = false

        for index in 0..<64 {
            guard let piece = piece(at: index), piece.kind != .king else { continue }
            if piece.color == color {
                switch piece.kind {
                case .pawn, .rook, .queen: return true
                case .knight: knights += 1
                case .bishop:
                    if Square(index).isLight { lightBishops += 1 } else { darkBishops += 1 }
                case .king: break
                }
            } else {
                switch piece.kind {
                case .pawn, .knight:
                    defenderHasNonQueen = true
                    defenderHasKnightOrPawn = true
                case .bishop:
                    defenderHasNonQueen = true
                    if Square(index).isLight { defenderHasLightBishop = true } else { defenderHasDarkBishop = true }
                case .rook:
                    defenderHasNonQueen = true
                case .queen, .king:
                    break
                }
            }
        }

        let bishops = lightBishops + darkBishops
        if knights + bishops == 0 { return false }
        // Two minor pieces of different kinds or colours can mate on their own
        // (or with the defender's help, for two knights).
        if knights >= 2 || (knights >= 1 && bishops >= 1) || (lightBishops > 0 && darkBishops > 0) {
            return true
        }
        if knights == 1 { return defenderHasNonQueen }
        // Bishops on one colour only: the squares beside a cornered king are
        // of the other colour, so it takes a defender's piece there to close
        // them — one that cannot then step into the check itself.
        return defenderHasKnightOrPawn || (lightBishops > 0 ? defenderHasDarkBishop : defenderHasLightBishop)
    }
}

// MARK: - The computer's time

/// How long the computer may think when a clock is running.
///
/// Without a clock every level has a fixed allowance per move
/// (`AIDifficulty.parameters`), and the strongest takes 2.6 s — at 1 + 0 that
/// alone would run its flag down around move twenty-three. With a clock the
/// allowance is capped by a share of what is left, the way every engine
/// budgets: the remaining time spread over the moves still expected, plus most
/// of the increment, and never more than a quarter of the bank in one go.
nonisolated enum AITimeBudget {

    static func seconds(
        remaining: TimeInterval,
        increment: TimeInterval,
        movesPlayed: Int,
        levelTime: TimeInterval
    ) -> TimeInterval {
        // Forty moves is the usual length to plan for; a game that has gone
        // long is assumed to have fifteen more in it rather than none.
        let movesToGo = Double(max(15, 40 - movesPlayed))
        var budget = remaining / movesToGo + increment * 0.75
        budget = min(budget, remaining * 0.25)
        budget = min(budget, levelTime)
        return max(0.03, budget)
    }

    /// The pause the computer waits before an instant reply, so that a book
    /// move does not land the frame after the player's. Without a clock it is
    /// a fixed 0.55 s; on a clock it is charged to the computer like any other
    /// thinking, so it shrinks with the bank — a bullet game wants its replies
    /// fast anyway.
    static func thinkingPause(remaining: TimeInterval?) -> TimeInterval {
        guard let remaining else { return 0.55 }
        return min(0.55, max(0, remaining * 0.004))
    }
}

// MARK: - Stopwatch

/// Measures how long each move took, clock or no clock — the review shows
/// time per move for every game, not only for timed ones. Paused along with
/// the game, so a phone left on the table overnight does not record a
/// twelve-hour think.
nonisolated struct Stopwatch: Hashable, Sendable {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    init() {}

    var isRunning: Bool { startedAt != nil }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now - $0) } ?? 0)
    }

    mutating func start(at now: TimeInterval) {
        accumulated = 0
        startedAt = now
    }

    mutating func pause(at now: TimeInterval) {
        guard let startedAt else { return }
        accumulated += max(0, now - startedAt)
        self.startedAt = nil
    }

    mutating func resume(at now: TimeInterval) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    /// The time since the last lap, and a fresh start — running if it was.
    mutating func lap(at now: TimeInterval) -> TimeInterval {
        let time = elapsed(at: now)
        accumulated = 0
        startedAt = startedAt == nil ? nil : now
        return time
    }
}
