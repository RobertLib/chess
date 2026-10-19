//
//  PuzzleViews.swift
//  chess
//
//  The puzzle screens: the hub that leads to every kind of puzzle, and the
//  board a puzzle is solved on.
//

import SwiftUI

// MARK: - Theme names

/// The words and symbols for the Lichess theme tags the app offers.
enum PuzzleThemeLabel {
    static func name(_ tag: String) -> String {
        switch tag {
        case "mateIn1": return String(localized: "Mate in 1", comment: "Puzzle theme")
        case "mateIn2": return String(localized: "Mate in 2", comment: "Puzzle theme")
        case "mateIn3": return String(localized: "Mate in 3", comment: "Puzzle theme")
        case "fork": return String(localized: "Fork", comment: "Puzzle theme")
        case "pin": return String(localized: "Pin", comment: "Puzzle theme")
        case "skewer": return String(localized: "Skewer", comment: "Puzzle theme")
        case "discoveredAttack": return String(localized: "Discovered attack", comment: "Puzzle theme")
        case "hangingPiece": return String(localized: "Hanging piece", comment: "Puzzle theme")
        case "backRankMate": return String(localized: "Back-rank mate", comment: "Puzzle theme")
        case "sacrifice": return String(localized: "Sacrifice", comment: "Puzzle theme")
        case "deflection": return String(localized: "Deflection", comment: "Puzzle theme")
        case "attraction": return String(localized: "Attraction", comment: "Puzzle theme")
        case "promotion": return String(localized: "Promotion", comment: "Puzzle theme")
        case "defensiveMove": return String(localized: "Defensive move", comment: "Puzzle theme")
        case "trappedPiece": return String(localized: "Trapped piece", comment: "Puzzle theme")
        case "smotheredMate": return String(localized: "Smothered mate", comment: "Puzzle theme")
        case "doubleCheck": return String(localized: "Double check", comment: "Puzzle theme")
        case "quietMove": return String(localized: "Quiet move", comment: "Puzzle theme")
        case "intermezzo": return String(localized: "Intermezzo", comment: "Puzzle theme")
        case "xRayAttack": return String(localized: "X-ray attack", comment: "Puzzle theme")
        case "capturingDefender": return String(localized: "Capture the defender", comment: "Puzzle theme")
        case "clearance": return String(localized: "Clearance", comment: "Puzzle theme")
        case "interference": return String(localized: "Interference", comment: "Puzzle theme")
        case "zugzwang": return String(localized: "Zugzwang", comment: "Puzzle theme")
        case "endgame": return String(localized: "Endgame", comment: "Puzzle theme")
        case "rookEndgame": return String(localized: "Rook endgame", comment: "Puzzle theme")
        case "pawnEndgame": return String(localized: "Pawn endgame", comment: "Puzzle theme")
        case "opening": return String(localized: "Opening", comment: "Puzzle theme")
        case "middlegame": return String(localized: "Middlegame", comment: "Puzzle theme")
        case "exposedKing": return String(localized: "Exposed king", comment: "Puzzle theme")
        case "kingsideAttack": return String(localized: "Kingside attack", comment: "Puzzle theme")
        case "advancedPawn": return String(localized: "Advanced pawn", comment: "Puzzle theme")
        default: return tag
        }
    }

    static func systemImage(_ tag: String) -> String {
        switch tag {
        case "mateIn1", "mateIn2", "mateIn3", "backRankMate", "smotheredMate": return "crown.fill"
        case "fork": return "arrow.triangle.branch"
        case "pin", "skewer", "xRayAttack": return "pin.fill"
        case "discoveredAttack", "doubleCheck": return "eye.fill"
        case "hangingPiece", "trappedPiece", "capturingDefender": return "hand.raised.fill"
        case "sacrifice", "deflection", "attraction": return "flame.fill"
        case "promotion", "advancedPawn": return "arrow.up.circle.fill"
        case "defensiveMove", "quietMove", "zugzwang": return "shield.fill"
        case "intermezzo", "clearance", "interference": return "arrow.left.arrow.right"
        case "endgame", "rookEndgame", "pawnEndgame": return "flag.checkered"
        case "opening": return "book.fill"
        case "exposedKing", "kingsideAttack": return "bolt.fill"
        default: return "puzzlepiece.fill"
        }
    }
}

extension PuzzleSessionModel.RushKind {
    var title: String {
        switch self {
        case .threeMinutes: return String(localized: "3 minutes", comment: "Puzzle rush kind")
        case .fiveMinutes: return String(localized: "5 minutes", comment: "Puzzle rush kind")
        case .survival: return String(localized: "Survival", comment: "Puzzle rush kind: no clock, three strikes")
        }
    }

    var systemImage: String {
        switch self {
        case .threeMinutes: return "bolt.fill"
        case .fiveMinutes: return "stopwatch.fill"
        case .survival: return "heart.fill"
        }
    }
}

// MARK: - Shared chrome

/// The top bar of a full-screen page: a way back, a title, and room for one
/// button on the other side.
struct ScreenTopBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// The subtitle as VoiceOver should say it, where the written one holds
    /// notation that would be spelt out a letter at a time.
    var spokenSubtitle: String?
    let backLabel: LocalizedStringKey
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            CircleButton(systemName: "chevron.left", label: backLabel, action: onBack)
                .frame(width: 96, alignment: .leading)
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .contentTransition(.opacity)
                        .accessibilityLabel(Text(verbatim: spokenSubtitle ?? subtitle))
                }
            }
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack { trailing() }
                .frame(width: 96, alignment: .trailing)
        }
    }
}

extension ScreenTopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, spokenSubtitle: String? = nil,
         backLabel: LocalizedStringKey, onBack: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.spokenSubtitle = spokenSubtitle
        self.backLabel = backLabel
        self.onBack = onBack
        self.trailing = { EmptyView() }
    }
}

/// The backdrop every page shares.
struct ScreenBackground: View {
    let theme: BoardTheme
    var body: some View {
        LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// A small line chart of a rating's history.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let low = (values.min() ?? 0) - 10
            let high = (values.max() ?? 1) + 10
            let span = max(1, high - low)
            let step = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: proxy.size.height * (1 - CGFloat((value - low) / span))
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hub

struct PuzzleHubView: View {
    @Environment(AppSettings.self) private var settings
    let onClose: () -> Void

    @State private var session: SessionRequest?

    private struct SessionRequest: Identifiable {
        let kind: PuzzleSessionModel.Kind
        var id: String { "\(kind)" }
    }

    private var progress: PuzzleProgress { PuzzleStore.shared.progress }
    /// Today's day number, kept as state so that midnight can change it.
    /// Worked out afresh in the body it was only ever as new as the last
    /// redraw, and a hub left open overnight went on calling yesterday's
    /// puzzle "solved today", with yesterday's streak beside it.
    @State private var today = PuzzleLibrary.dayNumber(for: Date())

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            VStack(spacing: 10) {
                ScreenTopBar(title: String(localized: "Puzzles"), backLabel: "Back to menu", onBack: onClose)
                    .padding(.horizontal, 12)
                ScrollView {
                    VStack(spacing: 20) {
                        ratingCard
                        dailyCard
                        rushSection
                        mistakesCard
                        themesSection
                        Text("Puzzles from the Lichess database, released into the public domain (CC0).")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .fullScreenCover(item: $session) { request in
            PuzzleView(kind: request.kind, onClose: { session = nil })
                .environment(settings)
        }
        .onDayChange { today = PuzzleLibrary.dayNumber(for: Date()) }
#if DEBUG
        .onAppear {
            let arguments = LaunchArguments.once(for: "puzzles")
            if arguments.contains("--puzzle-rated") { session = SessionRequest(kind: .rated(theme: nil)) }
            if arguments.contains("--puzzle-daily") { session = SessionRequest(kind: .daily) }
            if arguments.contains("--puzzle-rush") { session = SessionRequest(kind: .rush(.threeMinutes)) }
        }
#endif
    }

    private var ratingCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PUZZLE RATING")
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(.tertiaryText)
                        .kerning(1.2)
                    Text(verbatim: "\(Int(progress.rating.rounded()))")
                        .scaledFont(40, relativeTo: .largeTitle, weight: .heavy, design: .rounded)
                        .foregroundStyle(Design.gold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(progress.solved) solved", comment: "Puzzle count")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(progress.attempts) attempted", comment: "Puzzle count")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondaryText)
                }
            }
            if progress.history.count > 1 {
                Sparkline(values: Array(progress.history.suffix(60)), tint: Design.gold)
                    .frame(height: 44)
            }
            Button {
                session = SessionRequest(kind: .rated(theme: nil))
            } label: {
                Label("Solve Rated Puzzles", systemImage: "play.fill")
                    .font(.system(.body, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Design.gold))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .setupCard(selected: false, cornerRadius: 18)
        .accessibilityElement(children: .contain)
    }

    private var dailyCard: some View {
        let solved = PuzzleStore.shared.isDailySolved(day: today)
        let streak = progress.currentDailyStreak(today: today)
        return Button {
            session = SessionRequest(kind: .daily)
        } label: {
            HStack(spacing: 14) {
                // The symbols are decoration, and VoiceOver reads one it is
                // not told to skip by its name: "Calendar, Daily Puzzle, …,
                // Forward". The words beside them say all there is to say.
                Image(systemName: solved ? "checkmark.seal.fill" : "calendar")
                    .scaledFont(22, relativeTo: .title3, weight: .semibold)
                    .foregroundStyle(solved ? MoveQuality.best.tint : Design.gold)
                    .scaledFrame(40, relativeTo: .title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Puzzle")
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(solved
                         ? String(localized: "Solved today · \(streak)-day streak")
                         : (streak > 0
                            ? String(localized: "A new puzzle is waiting · \(streak)-day streak")
                            : String(localized: "A new puzzle every day")))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.3))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .setupCard(selected: false, cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var rushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle("RACE THE CLOCK")
            Text("As many as you can, getting harder as you go. Three mistakes and it is over.")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(PuzzleSessionModel.RushKind.allCases) { rush in
                    Button {
                        session = SessionRequest(kind: .rush(rush))
                    } label: {
                        VStack(spacing: 4) {
                            // Decoration, as on the daily card: VoiceOver read
                            // the symbol's name in front of the words.
                            Image(systemName: rush.systemImage)
                                .foregroundStyle(Design.gold)
                                .accessibilityHidden(true)
                            Text(rush.title)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Best \(progress.rushBest[rush.rawValue] ?? 0)", comment: "Best puzzle rush score")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .setupCard(selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var mistakesCard: some View {
        let pending = MistakeStore.shared.pending.count
        let fixed = MistakeStore.shared.fixedCount
        return Button {
            session = SessionRequest(kind: .mistakes)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .scaledFont(22, relativeTo: .title3, weight: .semibold)
                    .foregroundStyle(Design.gold)
                    .scaledFrame(40, relativeTo: .title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fix Your Mistakes")
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(pending > 0
                         ? String(localized: "\(pending) positions from your games · \(fixed) fixed")
                         : String(localized: "Review a game and its mistakes appear here."))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.3))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .setupCard(selected: false, cornerRadius: 16)
            .opacity(pending > 0 ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(pending == 0)
    }

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle("THEMES")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(PuzzleLibrary.curatedThemes, id: \.self) { theme in
                    let result = progress.themeResults[theme] ?? [0, 0]
                    Button {
                        session = SessionRequest(kind: .rated(theme: theme))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: PuzzleThemeLabel.systemImage(theme))
                                .scaledFont(14, relativeTo: .subheadline, weight: .semibold)
                                .foregroundStyle(Design.gold)
                                .scaledFrame(width: 22, relativeTo: .subheadline)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(PuzzleThemeLabel.name(theme))
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                if result[1] > 0 {
                                    Text("\(result[0]) of \(result[1])", comment: "Puzzles solved of attempted in a theme")
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundStyle(.secondaryText)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: Design.minimumTouchTarget, alignment: .leading)
                        .setupCard(selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Solving

struct PuzzleView: View {
    @Environment(AppSettings.self) private var settings
    let kind: PuzzleSessionModel.Kind
    /// Where the way back leads. From the hub that is the hub; the widget's
    /// daily puzzle is presented over the menu or the game instead, and there
    /// "Back to puzzles" named a page the button never went to.
    var backLabel: LocalizedStringKey = "Back to puzzles"
    let onClose: () -> Void

    @State private var model: PuzzleSessionModel?

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            if let model {
                content(model)
                if model.hasPendingPromotion {
                    PromotionPickerOverlay(
                        color: model.promotionColor, theme: settings.theme,
                        onPick: { model.completePromotion(with: $0) },
                        onCancel: { model.cancelPromotion() }
                    )
                    .transition(.opacity)
                }
                if model.phase == .rushOver {
                    rushOverCard(model)
                        .transition(.opacity)
                }
            }
        }
        .boardTypeLimit()
        .onAppear {
            if model == nil { model = PuzzleSessionModel(kind: kind, settings: settings) }
#if DEBUG
            if let argument = LaunchArguments.once(for: "puzzle-session")
                .first(where: { $0.hasPrefix("--puzzle-autosolve=") }),
               let delay = Double(argument.dropFirst("--puzzle-autosolve=".count)) {
                model?.autosolve(after: delay)
            }
#endif
        }
        .onDisappear { model?.teardown() }
    }

    private var title: String {
        switch kind {
        case .rated(let theme): return theme.map(PuzzleThemeLabel.name) ?? String(localized: "Rated Puzzles")
        case .daily: return String(localized: "Daily Puzzle")
        case .rush(let rush): return String(localized: "Race the Clock · \(rush.title)")
        case .mistakes: return String(localized: "Fix Your Mistakes")
        }
    }

    private func subtitle(_ model: PuzzleSessionModel) -> String? {
        switch kind {
        case .rated, .daily:
            guard let puzzle = model.attempt?.puzzle else { return nil }
            // Ratings are passed as text: interpolated as numbers they would
            // pick up the locale's thousands separator, and "1 133" is not how
            // a rating is written anywhere.
            let yours = String(Int(PuzzleStore.shared.progress.rating.rounded()))
            // Not until the puzzle is put. Leaving during the setup move costs
            // nothing — the puzzle has not been asked yet — so a rating shown
            // then told the player which ones were hard enough to walk away
            // from, for free, before they counted.
            let theirs = model.phase == .setup ? "–" : String(puzzle.rating)
            return String(localized: "Puzzle rating \(theirs) · yours \(yours)")
        case .rush:
            return nil
        case .mistakes:
            guard let mistake = model.currentMistake else { return nil }
            return String(localized: "In the game you played \(MoveNotation.display(mistake.playedSAN))")
        }
    }

    /// The subtitle in words where it names a move. The mistake is kept only
    /// as notation, so it is found again among the moves of the position it
    /// was played in — the one the puzzle starts from, whatever the board
    /// shows now.
    private func spokenSubtitle(_ model: PuzzleSessionModel) -> String? {
        guard case .mistakes = kind, let mistake = model.currentMistake,
              let move = PuzzleAttempt(puzzle: mistake.puzzle)?.legalMove(named: mistake.playedSAN)
        else { return nil }
        let spoken = BoardSpeech.spokenMove(move, san: mistake.playedSAN)
        // A colon rather than the move as the verb's object, for the reason
        // `BoardSpeech.movedAnnouncement` gives: Czech would want the piece
        // in a case the spoken move, built in the nominative, cannot give it.
        return String(localized: "puzzle.mistakeSpoken",
                      defaultValue: "In the game you played: \(spoken)",
                      comment: "VoiceOver: the move the player made in the game a mistake puzzle comes from, e.g. 'In the game you played: knight takes e 5'")
    }

    @ViewBuilder
    private func content(_ model: PuzzleSessionModel) -> some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height * 1.15
            Group {
                if isWide {
                    HStack(spacing: 18) {
                        board(model)
                        VStack(spacing: 12) {
                            topBar(model)
                            if case .rush = kind { rushBar(model) }
                            Spacer()
                            statusCard(model)
                            controls(model)
                        }
                        .frame(maxWidth: 380)
                    }
                    .frame(maxWidth: 1100)
                } else {
                    VStack(spacing: 12) {
                        topBar(model)
                        if case .rush = kind { rushBar(model) }
                        Spacer(minLength: 4)
                        board(model).padding(.horizontal, 6)
                        statusCard(model)
                        Spacer(minLength: 4)
                        controls(model)
                    }
                    .frame(maxWidth: 640)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func topBar(_ model: PuzzleSessionModel) -> some View {
        ScreenTopBar(title: title, subtitle: subtitle(model), spokenSubtitle: spokenSubtitle(model), backLabel: backLabel) {
            model.teardown()
            onClose()
        }
    }

    private func board(_ model: PuzzleSessionModel) -> some View {
        BoardView(
            model: model, theme: settings.theme,
            showCoordinates: settings.showCoordinates, showLegalMoves: settings.showLegalMoves
        )
    }

    private func rushBar(_ model: PuzzleSessionModel) -> some View {
        HStack {
            Label {
                Text(verbatim: "\(model.rushScore)")
                    .font(.system(.title3, design: .rounded, weight: .heavy))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MoveQuality.best.tint)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Score"))
            .accessibilityValue(Text(verbatim: "\(model.rushScore)"))
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<PuzzleSessionModel.maxStrikes, id: \.self) { index in
                    Image(systemName: index < model.strikes ? "xmark.circle.fill" : "circle")
                        .foregroundStyle(index < model.strikes ? MoveQuality.blunder.tint : .white.opacity(0.3))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Mistakes"))
            .accessibilityValue(Text("\(model.strikes) of \(PuzzleSessionModel.maxStrikes)", comment: "Rush strikes"))
            Spacer()
            if model.rushTimeLeft != nil {
                // Stops with the rush: the clock under the result card has
                // nothing left to count.
                TimelineView(.animation(minimumInterval: 0.25, paused: model.phase == .rushOver)) { _ in
                    let left = model.rushTimeLeft ?? 0
                    Text(verbatim: ClockFormat.text(left))
                        .scaledFont(20, relativeTo: .title3, weight: .bold, design: .monospaced)
                        .foregroundStyle(left < 20 ? MoveQuality.blunder.tint : .white)
                        .accessibilityLabel(Text("Time left"))
                        .accessibilityValue(ClockFormat.spoken(left))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hudCard()
    }

    private func statusCard(_ model: PuzzleSessionModel) -> some View {
        HStack(spacing: 10) {
            // The prompt says what the symbol shows; read as well, the
            // symbol came first by its name — "x mark, That is not it".
            Image(systemName: statusIcon(model.phase))
                .scaledFont(18, relativeTo: .headline, weight: .bold)
                .foregroundStyle(statusTint(model.phase))
                .accessibilityHidden(true)
            Text(model.prompt)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let change = model.ratingChange {
                Text(verbatim: change >= 0 ? "+\(Int(change.rounded()))" : "\(Int(change.rounded()))")
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(change >= 0 ? MoveQuality.best.tint : MoveQuality.blunder.tint)
                    .accessibilityLabel(Text("Rating change \(Int(change.rounded()))"))
            }
            if model.phase == .checking { ProgressView().tint(.white) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .hudCard()
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(_ phase: PuzzleSessionModel.Phase) -> String {
        switch phase {
        case .solved: return "checkmark.circle.fill"
        case .correct: return "checkmark"
        case .wrong: return "xmark.circle.fill"
        case .shown: return "eye.fill"
        case .checking: return "hourglass"
        default: return "puzzlepiece.fill"
        }
    }

    private func statusTint(_ phase: PuzzleSessionModel.Phase) -> Color {
        switch phase {
        case .solved, .correct: return MoveQuality.best.tint
        case .wrong: return MoveQuality.blunder.tint
        default: return settings.theme.accent
        }
    }

    @ViewBuilder
    private func controls(_ model: PuzzleSessionModel) -> some View {
        let finished = model.phase == .solved || model.phase == .shown
        HStack(spacing: 10) {
            if case .rush = kind {
                EmptyView()
            } else if model.phase == .empty {
                ControlButton(systemName: "xmark", label: "Close", width: nil) {
                    model.teardown()
                    onClose()
                }
            } else {
                ControlButton(systemName: "lightbulb", label: "Hint", width: nil,
                              disabled: !model.canShowHint || finished) {
                    model.showHint()
                }
                ControlButton(systemName: "eye", label: "Solution", width: nil,
                              disabled: finished || model.phase == .setup || model.phase == .checking) {
                    model.showSolution()
                }
                ControlButton(systemName: "arrow.counterclockwise", label: "Retry", width: nil,
                              disabled: model.phase == .setup) {
                    model.retry()
                }
                if kind != .daily {
                    ControlButton(systemName: "forward.fill", label: "Next", width: nil,
                                  disabled: model.phase == .setup) {
                        model.loadNext()
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func rushOverCard(_ model: PuzzleSessionModel) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: model.rushIsNewBest ? "trophy.fill" : "flag.checkered")
                    .scaledFont(44, relativeTo: .largeTitle, weight: .bold)
                    .foregroundStyle(Design.gold)
                    .accessibilityHidden(true)
                Text(model.rushIsNewBest ? "New Best!" : "Race Over")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                Text("\(model.rushScore) solved", comment: "Puzzle rush result")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Design.gold)
                if let rush = model.rushKind {
                    Text("Best: \(PuzzleStore.shared.progress.rushBest[rush.rawValue] ?? 0)", comment: "Best puzzle rush score")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack(spacing: 10) {
                    OverlayButton(title: "Play Again", systemName: "arrow.counterclockwise", prominent: true) {
                        self.model?.teardown()
                        self.model = PuzzleSessionModel(kind: kind, settings: settings)
                    }
                    OverlayButton(title: "Back to Puzzles") {
                        model.teardown()
                        onClose()
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 330)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
