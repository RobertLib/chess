//
//  ChessWidget.swift
//  ChessWidget
//
//  The daily puzzle on the home screen. The widget picks the same puzzle the
//  app does — both ask `PuzzleLibrary.daily(for:)` against the same bundled
//  file — so there is nothing to share between them at run time, and nothing
//  to fetch: it works with the phone in flight mode like the rest of the app.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

nonisolated struct DailyPuzzleEntry: TimelineEntry {
    let date: Date
    /// The position the player is asked about, after the opponent's move.
    let board: Board?
    let playerColor: PieceColor
    let rating: Int
    let lastMove: Move?
}

/// One entry per day. Today's and the next two days' are handed over at once,
/// each starting at its midnight, so the puzzle changes on time even when
/// WidgetKit is late with the reload asked for after the first midnight.
nonisolated struct DailyPuzzleProvider: TimelineProvider {

    /// The longest a timeline is kept before it is drawn up again, midnight
    /// or not. The midnights are those of the zone the phone was in when the
    /// timeline was made, and WidgetKit says nothing to a widget when the
    /// zone changes; the app asks for a reload when it notices, but only
    /// while it runs. Someone who flies east with the app closed found the
    /// widget on yesterday's puzzle — or on tomorrow's, flying west — while
    /// the app showed today's, until the old zone's midnight came round. Now
    /// the new zone is picked up within this much of landing.
    ///
    /// Eight reloads a day, nine with the one after midnight: well inside the
    /// daily budget WidgetKit allows a widget that is often on screen, and
    /// cheap — picking the day's puzzle is arithmetic on the bundled list.
    static let refreshInterval: TimeInterval = 3 * 3600

    func placeholder(in context: Context) -> DailyPuzzleEntry {
        entry(for: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyPuzzleEntry) -> Void) {
        completion(entry(for: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyPuzzleEntry>) -> Void) {
        // The midnights are those of the zone the phone is in now. Foundation
        // keeps the zone it read first until it is told to look again, and
        // the extension's process can outlive a change of zone; the app asks
        // for this reload when the zone changes, and the reload is only as
        // good as the zone read here.
        NSTimeZone.resetSystemTimeZone()
        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        // Each the start of its own day. Where a day began at 01:00, its clock
        // put forward at midnight, a day added to that start lands at 01:00 of
        // the next day too — an hour after the app has moved on to its puzzle.
        let midnights = (1...2).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today).map { calendar.startOfDay(for: $0) }
        }
        // The puzzle for each entry is picked in that same calendar, so the
        // day it changes on and the day it is counted in cannot disagree.
        let entries = [entry(for: now, calendar: calendar)] + midnights.map { entry(for: $0, calendar: calendar) }
        // Just after midnight, to set up the next days in good time, or after
        // the refresh interval if that comes first — see `refreshInterval`.
        let afterMidnight = midnights.first.map { $0.addingTimeInterval(60) } ?? now.addingTimeInterval(86_400)
        let reload = min(afterMidnight, now.addingTimeInterval(Self.refreshInterval))
        completion(Timeline(entries: entries, policy: .after(reload)))
    }

    func entry(for date: Date, calendar: Calendar = .current) -> DailyPuzzleEntry {
        guard let puzzle = PuzzleLibrary.daily(for: date, calendar: calendar), let game = puzzle.startingGame() else {
            return DailyPuzzleEntry(date: date, board: nil, playerColor: .white, rating: 0, lastMove: nil)
        }
        return DailyPuzzleEntry(
            date: date, board: game.board, playerColor: game.sideToMove,
            rating: puzzle.rating, lastMove: game.lastMove
        )
    }
}

// MARK: - Views

/// A small static board: the squares, the last move, the pieces.
struct WidgetBoard: View {
    let board: Board
    let orientation: PieceColor
    let lastMove: Move?

    @Environment(\.widgetRenderingMode) private var renderingMode

    private static let light = Color(red: 0.94, green: 0.85, blue: 0.71)
    private static let dark = Color(red: 0.71, green: 0.53, blue: 0.39)
    private static let highlight = Color(red: 0.98, green: 0.75, blue: 0.35).opacity(0.55)

    /// On a tinted home screen, and in StandBy at night, the system paints
    /// the widget in one colour of its own and keeps only how opaque each
    /// part is — so the squares become faint washes of two strengths and the
    /// pieces are drawn the way a printed diagram draws them. Drawn as they
    /// are in full colour, the two square colours, the two piece colours and
    /// the highlight would all come out the same, and the board would read as
    /// one block.
    private var isMonochrome: Bool { renderingMode != .fullColor }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) / 8
            ZStack(alignment: .topLeading) {
                ForEach(0..<64, id: \.self) { cell in
                    let row = cell / 8, column = cell % 8
                    let square = Square(
                        file: orientation == .white ? column : 7 - column,
                        rank: orientation == .white ? 7 - row : row
                    )
                    let isLastMove = lastMove.map { $0.from == square || $0.to == square } ?? false
                    let isLight = (row + column).isMultiple(of: 2)
                    ZStack {
                        if isMonochrome {
                            Rectangle().fill(.white.opacity(isLight ? 0.08 : 0.24))
                            if isLastMove { Rectangle().fill(.white.opacity(0.45)) }
                            if let piece = board.piece(at: square) {
                                MonochromePiece(piece: piece)
                                    .widgetAccentable()
                            }
                        } else {
                            Rectangle().fill(isLight ? Self.light : Self.dark)
                            if isLastMove { Rectangle().fill(Self.highlight) }
                            if let piece = board.piece(at: square) {
                                PieceView(piece: piece, shadow: false)
                            }
                        }
                    }
                    .frame(width: side, height: side)
                    .offset(x: CGFloat(column) * side, y: CGFloat(row) * side)
                }
            }
            .frame(width: side * 8, height: side * 8)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A piece in a single colour: White's as an outline, Black's solid. Drawn
/// as one filled shape, which every rendering mode keeps as it is.
private struct MonochromePiece: View {
    let piece: Piece

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let scale = size / PieceArt.designSize
            PieceArt.monochrome(piece)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .fill(.white)
                .frame(width: size, height: size)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct DailyPuzzleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyPuzzleEntry

    private var sideText: Text {
        entry.playerColor == .white
            ? Text("White to move", comment: "Widget: the side the daily puzzle is for")
            : Text("Black to move", comment: "Widget: the side the daily puzzle is for")
    }

    /// What VoiceOver reads for the widget, as one sentence. The board is
    /// drawn in shapes, which say nothing, so read part by part the small
    /// widget came to "White to move" and no more — not what it was, nor how
    /// hard. Each side a whole sentence of its own, so that the words around
    /// the side can agree with it in every language.
    private var spokenSummary: Text {
        let rating = String(entry.rating)
        return entry.playerColor == .white
            ? Text("Daily puzzle, rating \(rating), White to move. Find the best move.",
                   comment: "Widget: what VoiceOver reads for the daily puzzle; the number is its rating")
            : Text("Daily puzzle, rating \(rating), Black to move. Find the best move.",
                   comment: "Widget: what VoiceOver reads for the daily puzzle; the number is its rating")
    }

    var body: some View {
        Group {
            if let board = entry.board {
                puzzle(board)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenSummary)
            } else {
                Text("Daily Puzzle", comment: "Widget title")
                    .foregroundStyle(.white)
            }
        }
        .widgetURL(URL(string: "chessoffline://puzzle/daily"))
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.10, blue: 0.08), Color(red: 0.23, green: 0.16, blue: 0.11)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private func puzzle(_ board: Board) -> some View {
        switch family {
        case .systemSmall:
            VStack(spacing: 4) {
                WidgetBoard(board: board, orientation: entry.playerColor, lastMove: entry.lastMove)
                // Grows with the text setting like the medium widget's lines
                // do. The board gives up the height, so the line is held to
                // one row and a size the board can spare; past that it
                // shrinks to fit.
                sideText
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        default:
            HStack(spacing: 12) {
                WidgetBoard(board: board, orientation: entry.playerColor, lastMove: entry.lastMove)
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Daily Puzzle", comment: "Widget title")
                    } icon: {
                        Image(systemName: "puzzlepiece.fill")
                    }
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color(red: 0.98, green: 0.76, blue: 0.35))
                    sideText
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Find the best move.", comment: "Widget: what the daily puzzle asks")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    Text("Rating \(String(entry.rating))", comment: "Widget: the daily puzzle's rating")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Widget

struct DailyPuzzleWidget: Widget {
    let kind = "DailyPuzzle"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyPuzzleProvider()) { entry in
            DailyPuzzleWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Daily Puzzle", comment: "Widget name in the gallery"))
        .description(Text("A new chess puzzle every day, on your home screen.", comment: "Widget description in the gallery"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ChessWidgetBundle: WidgetBundle {
    var body: some Widget {
        DailyPuzzleWidget()
    }
}
