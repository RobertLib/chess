//
//  ClockViews.swift
//  chess
//
//  How a clock reads: the digits on a player card, the same in words for
//  VoiceOver, and the time-control labels the setup screens show.
//

import SwiftUI

// MARK: - Formatting

nonisolated enum ClockFormat {

    /// "4:59", "1:02:03", and "0:09.4" once tenths matter.
    static func text(_ seconds: TimeInterval, tenths: Bool = false) -> String {
        let clamped = max(0, seconds)
        if tenths {
            // Rounded down, never up: a face that reads 0.0 while the flag is
            // still up — or 0.1 once it has fallen — is a clock that lies.
            let tenthsTotal = Int((clamped * 10).rounded(.down))
            let minutes = tenthsTotal / 600
            let secs = (tenthsTotal / 10) % 60
            return String(format: "%d:%02d.%d", minutes, secs, tenthsTotal % 10)
        }
        // Whole seconds round up: a clock showing 0:00 should mean the time
        // is gone, not that there is most of a second left.
        let total = Int(clamped.rounded(.up))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "4 minutes, 59 seconds" in the reader's language, for VoiceOver.
    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = seconds >= 3600 ? hoursAndMinutes : minutesAndSeconds
        let rounded = max(0, seconds.rounded(.up))
        return formatter.string(from: rounded) ?? text(seconds)
    }

    // One formatter per set of units, made once. Making one is the expensive
    // part, and the chess clock's VoiceOver value asked for a new one with
    // every frame it drew.
    private static let minutesAndSeconds = spokenFormatter([.minute, .second])
    private static let hoursAndMinutes = spokenFormatter([.hour, .minute])

    private static func spokenFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = units
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }
}

// MARK: - Redraw schedule

/// The moments a running clock's face next reads differently: each time the
/// whole seconds tick over, and every tenth once tenths are on show. A clock
/// redrawn on a fixed beat instead — ten or twenty times a second — drew the
/// same "4:59" nine times out of ten for most of a game.
///
/// `remaining` is the time on the clock at the schedule's start; a clock that
/// is not running is given zero, which asks for nothing after the first draw.
/// The face is redrawn with a fresh schedule whenever its model changes — a
/// press, a pause — so the count only has to hold while the clock runs down
/// at one second per second, which it does under every kind of bonus once a
/// delay is spent.
///
/// `heldFor` is the delay still to come, during which the face stands still.
/// Counted down from the start of the turn instead, a schedule under a 5 s
/// delay ran out 5 s before the flag: the face stopped being redrawn and
/// read 0:04.0 until it fell.
nonisolated struct ClockFaceSchedule: TimelineSchedule {
    let remaining: TimeInterval
    /// Below this the face shows tenths.
    let tenthsBelow: TimeInterval
    var heldFor: TimeInterval = 0

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // Dimmed, the face is shown to the second at most.
        Entries(date: startDate, left: remaining, hold: max(0, heldFor),
                tenthsBelow: mode == .lowFrequency ? 0 : tenthsBelow, isFirst: true)
    }

    struct Entries: Sequence, IteratorProtocol {
        var date: Date
        var left: TimeInterval
        var hold: TimeInterval
        let tenthsBelow: TimeInterval
        var isFirst: Bool

        mutating func next() -> Date? {
            if isFirst {
                isFirst = false
                return date
            }
            // Short of zero by a rounding error is zero: the flag is down.
            guard left > 1e-6 else { return nil }
            let delay = Self.untilNextChange(left: left, tenthsBelow: tenthsBelow)
            date += hold + delay
            hold = 0
            left -= delay
            return date
        }

        /// Seconds until the reading changes. Whole seconds round up on the
        /// face, so 4:59 holds until a full 299 is reached; tenths round down,
        /// so 9.9 holds until 9.8 is. Measured from the reading now shown,
        /// with a hair of slack so that arriving a rounding error short of a
        /// boundary does not ask for a redraw a hair later.
        static func untilNextChange(left: TimeInterval, tenthsBelow: TimeInterval) -> TimeInterval {
            let scale: Double = left <= tenthsBelow ? 10 : 1
            let scaled = left * scale
            let shown = (scaled - 1e-6).rounded(.up)
            return Swift.max(0.001, scaled - (shown - 1)) / scale
        }
    }
}

extension TimeControl.Category {
    var displayName: String {
        switch self {
        case .bullet: return String(localized: "Bullet", comment: "Time control category")
        case .blitz: return String(localized: "Blitz", comment: "Time control category")
        case .rapid: return String(localized: "Rapid", comment: "Time control category")
        case .classical: return String(localized: "Classical", comment: "Time control category")
        }
    }

    var systemImage: String {
        switch self {
        case .bullet: return "bolt.fill"
        case .blitz: return "flame.fill"
        case .rapid: return "hare.fill"
        case .classical: return "tortoise.fill"
        }
    }
}

extension TimeControl.Bonus {
    var displayName: String {
        switch self {
        case .increment: return String(localized: "Increment", comment: "Time added after each move (Fischer)")
        case .delay: return String(localized: "Delay", comment: "Simple (US) delay before the clock starts running")
        case .bronstein: return String(localized: "Bronstein", comment: "Bronstein delay: time used is given back up to a limit")
        }
    }
}

extension TimeControl {
    /// "Blitz · 3 + 2", or with the bonus kind when it is not the increment.
    var displayName: String {
        var text = "\(category.displayName) · \(label)"
        if bonusKind != .increment, bonus > 0 { text += " · \(bonusKind.displayName)" }
        return text
    }

    /// The same in words, for VoiceOver: "3 minutes plus 2 seconds per move".
    var spokenName: String {
        // Both amounts go through the system's duration formatter, which
        // knows each language's plurals — "2 sekundy" but "5 sekund".
        let base = ClockFormat.spoken(initial)
        // Nothing given back, nothing to say about it: 3 + 0 used to be read
        // as "3 minutes plus 0 seconds per move".
        guard bonus > 0 else {
            return String(localized: "time.spoken.noBonus",
                          defaultValue: "\(category.displayName), \(base)",
                          comment: "VoiceOver: a time control with nothing added per move, e.g. 'Blitz, 3 minutes'")
        }
        let bonusText = ClockFormat.spoken(bonus)
        switch bonusKind {
        case .increment:
            return String(localized: "time.spoken.increment",
                          defaultValue: "\(category.displayName), \(base) plus \(bonusText) per move",
                          comment: "VoiceOver: a time control with an increment, e.g. 'Blitz, 3 minutes plus 2 seconds per move'")
        case .delay, .bronstein:
            return String(localized: "time.spoken.delay",
                          defaultValue: "\(category.displayName), \(base), \(bonusKind.displayName) \(bonusText)",
                          comment: "VoiceOver: a time control with a delay, e.g. 'Blitz, 3 minutes, Delay 2 seconds'")
        }
    }
}

// MARK: - Clock face

/// The time on a player card. Redraws itself on a schedule while its clock
/// runs, so nothing else on the screen has to.
struct ClockFace: View {
    let model: GameViewModel
    let color: PieceColor
    let accent: Color

    var body: some View {
        let running = model.isClockRunning && model.isClockActive(for: color)
        let schedule = ClockFaceSchedule(
            remaining: running ? model.clockRemaining(for: color) ?? 0 : 0,
            tenthsBelow: 10,
            heldFor: model.clock?.delayLeft(at: model.clockNow) ?? 0
        )
        TimelineView(schedule) { _ in
            let remaining = model.clockRemaining(for: color) ?? 0
            let threshold = model.lowTimeThreshold(for: color)
            let isLow = remaining <= threshold && model.isClockActive(for: color)
            let isActive = model.isClockActive(for: color)
            Text(verbatim: ClockFormat.text(remaining, tenths: remaining < 10))
                .scaledFont(17, relativeTo: .headline, weight: .bold, design: .monospaced)
                .monospacedDigit()
                .foregroundStyle(isLow ? Color.white : (isActive ? Color.black.opacity(0.85) : .white.opacity(0.75)))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isLow
                              ? AnyShapeStyle(Color(red: 0.85, green: 0.22, blue: 0.22))
                              : (isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.08))))
                )
                .animation(.easeOut(duration: 0.2), value: isActive)
                .animation(.easeOut(duration: 0.2), value: isLow)
        }
        .accessibilityHidden(true)
    }
}
