//
//  GameReviewView.swift
//  chess
//
//  The post-game review screen: accuracy per player, an evaluation graph of
//  the whole game and a move-by-move walkthrough with the engine's verdict.
//

import SwiftUI

struct GameReviewView: View {
    let model: GameReviewModel
    @Environment(AppSettings.self) private var settings

    let onClose: () -> Void

    @State private var showReport = false
    @State private var analysis: AnalysisBoardModel?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let isWide = proxy.size.width > proxy.size.height * 1.15
                Group {
                    if isWide { wideLayout } else { tallLayout }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .boardTypeLimit()
            }
        }
        .fullScreenCover(item: Binding(
            get: { analysis.map(AnalysisFromReview.init) },
            set: { if $0 == nil { analysis = nil } }
        )) { request in
            AnalysisView(model: request.model, onClose: { analysis = nil })
                .environment(settings)
        }
        .sheet(isPresented: $showReport) {
            GameReportSheet(model: model) { ply in
                showReport = false
                model.go(to: ply + 1)
            }
            .environment(settings)
        }
        .onAppear {
            model.startAnalysis()
#if DEBUG
            let arguments = LaunchArguments.once(for: "review")
            if let plyArgument = arguments.first(where: { $0.hasPrefix("--review-ply=") }),
               let ply = Int(plyArgument.dropFirst("--review-ply=".count)) {
                model.go(to: ply)
            }
            if arguments.contains("--review-report") {
                showReport = true
            }
#endif
        }
#if DEBUG
        // Development helper: says when the analysis has landed, and replays the
        // game on a loop for the App Preview. A `.task` rather than work started
        // from `onAppear`, so closing the review cancels it.
        .task { await driveShotArguments() }
#endif
        .onDisappear { model.teardown() }
        // The board is stepped through rather than watched, and a VoiceOver
        // reader cannot see where a step has landed.
        .onChange(of: model.plyIndex) { previous, ply in
            announceStep(from: previous, to: ply)
        }
    }

    /// Says what a step has brought onto the board: Next and Replay read the
    /// move made, the way the game reads every move, and a step back or a
    /// jump reads the move the position came from. The grade follows, which
    /// is what a review is for, and on the last move the result.
    private func announceStep(from previous: Int, to ply: Int) {
        let history = model.game.history
        let played = ply > 0 && ply <= history.count ? history[ply - 1] : nil
        var spoken: String
        if ply == previous + 1, let played {
            spoken = BoardSpeech.movedAnnouncement(played.move, san: played.san)
        } else {
            spoken = BoardSpeech.position(after: played)
        }
        if let quality = model.currentAnalysis?.quality {
            spoken += ". " + quality.label
        }
        if ply > 0, ply == model.moveCount, model.game.outcome.isGameOver {
            spoken += ". " + model.game.outcome.headline(mode: model.mode)
        }
        AccessibilityNotification.Announcement(spoken).post()
    }

#if DEBUG
    // MARK: Screenshot and preview helpers

    /// Waits for the analysis, drops the marker the media script waits on, and
    /// — with `--review-replay` — replays the game over and over.
    ///
    /// The replay loops on purpose. The analysis takes as long as the engine
    /// takes, so the script cannot know when the board will start moving; with
    /// the replay going round, a recording started at any point after the
    /// marker lands on a game in progress rather than on a board that has
    /// already stopped.
    private func driveShotArguments() async {
        while model.isAnalyzing {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        ShotMarker.markReady()

        guard ProcessInfo.processInfo.arguments.contains("--review-replay"),
              model.moveCount > 0 else { return }
        // The script starts recording the moment the marker lands, and the
        // recorder takes a moment to come up. Holding here means the first pass
        // begins with the camera already running, so the clip can be cut to end
        // on the mate instead of on wherever the loop happened to have got to.
        try? await Task.sleep(for: .seconds(3))
        while !Task.isCancelled {
            model.go(to: 0)
            model.toggleAutoplay()
            while model.isAutoplaying {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            // A beat on the final position before it starts over, so the last
            // move of a pass is readable rather than snapping back at once.
            try? await Task.sleep(for: .milliseconds(900))
        }
    }
#endif

    // MARK: Layout

    private var headerCard: some View {
        Group {
            if model.moveCount == 0 {
                emptyCard
            } else if model.isAnalyzing {
                progressCard
                    .transition(Motion.transition(.opacity.combined(with: .move(edge: .top))))
            } else {
                accuracyRow
                    .transition(Motion.transition(.opacity.combined(with: .move(edge: .top))))
            }
        }
    }

    /// A game that ended before a move was played — a resignation on move one —
    /// has nothing to grade. Saying so beats two accuracy cards reading "—"
    /// with no explanation and a progress bar that never appears.
    private var emptyCard: some View {
        Text("No moves to review — this game ended before anyone played.")
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .hudCard()
    }

    private var reviewBoard: some View {
        ReviewBoardView(
            model: model,
            theme: settings.theme,
            showCoordinates: settings.showCoordinates
        )
    }

    private var moveStrip: some View {
        ReviewMoveStrip(
            history: model.game.history,
            analysis: model.analysis,
            plyIndex: model.plyIndex,
            accent: settings.theme.accent,
            onSelect: { model.go(to: $0 + 1) }
        )
    }

    private var tallLayout: some View {
        VStack(spacing: 10) {
            topBar
            headerCard
            graph
            timeBars
            reviewBoard.padding(.horizontal, 4)
            banner
            moveStrip
            controls
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    /// Landscape: the board holds the height while the numbers, the graph and
    /// the verdict sit beside it, all readable at once.
    private var wideLayout: some View {
        HStack(spacing: 18) {
            reviewBoard

            VStack(spacing: 10) {
                topBar
                headerCard
                graph
                timeBars
                banner
                Spacer(minLength: 4)
                moveStrip
                controls
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            CircleButton(systemName: "chevron.left", label: "Close the review") {
                model.teardown()
                onClose()
            }

            Spacer()

            VStack(spacing: 1) {
                Text("Game Review")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            HStack(spacing: 6) {
                // Into the analysis board at the position on show, to try
                // what the engine suggested and see where it leads.
                CircleButton(systemName: "magnifyingglass", label: "Analyze this position") {
                    model.stopAutoplay()
                    analysis = AnalysisBoardModel(game: model.game, startPly: model.plyIndex, orientation: model.orientation)
                }
                CircleButton(systemName: "arrow.trianglehead.2.clockwise.rotate.90",
                             label: "Flip the board") {
                    withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.2))) {
                        model.manualFlip.toggle()
                    }
                }
            }
        }
    }

    private struct AnalysisFromReview: Identifiable {
        let model: AnalysisBoardModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
    }

    // MARK: Time

    /// Time per move, for a game that recorded it.
    @ViewBuilder
    private var timeBars: some View {
        if !model.moveTimes.isEmpty {
            TimeBars(
                times: model.moveTimes,
                firstMover: model.game.history.first?.color ?? .white,
                plyIndex: model.plyIndex,
                accent: settings.theme.accent,
                onScrub: { model.scrub(to: $0) }
            )
            .frame(height: 34)
        }
    }

    private var subtitle: String {
        if let opening = model.analysis?.openingName { return opening }
        return model.game.outcome.headline(mode: model.mode)
    }

    // MARK: Progress

    private var progressCard: some View {
        let done = Int((model.progress * Double(model.moveCount + 1)).rounded())
        return VStack(spacing: 7) {
            HStack {
                Text("Analyzing your game…")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(verbatim: "\(min(done, model.moveCount + 1))/\(model.moveCount + 1)")
                    .scaledFont(12, relativeTo: .caption, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondaryText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [settings.theme.accent, MoveQuality.best.tint],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(6, proxy.size.width * model.progress))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hudCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Analyzing your game…"))
        .accessibilityValue(Text("\(Int(model.progress * 100)) percent"))
    }

    // MARK: Accuracy

    private var accuracyRow: some View {
        HStack(spacing: 10) {
            AccuracyCard(
                name: model.name(for: model.primaryColor),
                color: model.primaryColor,
                report: model.analysis?.report(for: model.primaryColor)
            )
            AccuracyCard(
                name: model.name(for: model.primaryColor.opponent),
                color: model.primaryColor.opponent,
                report: model.analysis?.report(for: model.primaryColor.opponent)
            )
            Button {
                showReport = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "list.clipboard.fill")
                        .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                    if !typeSize.isAccessibilitySize {
                        Text("Report")
                            .scaledFont(9, relativeTo: .caption2, weight: .semibold, design: .rounded)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                // Only the icon is left at the accessibility sizes, and the
                // width its caption needed went to the two cards instead:
                // without it, a "100%" on a 390 pt phone was cut to "10…".
                .scaledFrame(width: typeSize.isAccessibilitySize ? 32 : 50, height: 48,
                             relativeTo: .subheadline)
                .hudCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Report", comment: "Opens the full game report"))
            .disabled(model.analysis == nil)
        }
        // The cards inside stretch to match each other's height, which left
        // them stretching to the screen's as well: in the column below, the
        // board is the one view that gives way, so the moment the analysis
        // finished and this row replaced the progress bar the board halved.
        // Held to the height its own contents ask for, the cards still match
        // and the board keeps the space.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 48)
    }

    // MARK: Graph

    private var graph: some View {
        EvalGraph(
            curve: model.analysis?.evalCurve ?? [],
            plyIndex: model.plyIndex,
            marks: model.analysis?.moves.filter { $0.quality.isMistake || $0.quality.isStandout } ?? [],
            variant: model.game.variant,
            accent: settings.theme.accent,
            onScrub: { model.scrub(to: $0) }
        )
        .frame(height: 58)
    }

    // MARK: Banner

    private var banner: some View {
        ReviewBanner(
            analysis: model.currentAnalysis,
            move: model.currentMove,
            eval: evalForCurrentPly,
            isAnalyzing: model.isAnalyzing,
            plyIndex: model.plyIndex,
            outcome: model.plyIndex == model.moveCount ? model.game.outcome : .ongoing,
            mode: model.mode,
            variant: model.game.variant
        )
    }

    private var evalForCurrentPly: Int? {
        guard let curve = model.analysis?.evalCurve, curve.indices.contains(model.plyIndex) else {
            return nil
        }
        // A mate already delivered has no distance left to show. The position
        // a game was won in on the board — mate, the hill, the third check —
        // scores `SearchScore.mate` itself, which `mateInMoves` floors at one,
        // so the label would read "M1"; the result line says it better. Asked
        // of the score rather than of the result, because a game resigned or
        // lost on the clock ends on an ordinary evaluation, and that one is
        // worth showing.
        let value = curve[model.plyIndex]
        if abs(value) == SearchScore.mate { return nil }
        return value
    }

    // MARK: Controls

    /// Five buttons share the row, so they fit on the narrowest phone.
    private var controls: some View {
        HStack(spacing: 8) {
            ControlButton(systemName: "backward.end.fill", label: "Start",
                          width: nil, disabled: !model.canStepBack) {
                model.goToStart()
            }
            ControlButton(systemName: "chevron.left", label: "Back",
                          width: nil, disabled: !model.canStepBack) {
                model.stepBackward()
            }
            ControlButton(
                systemName: model.isAutoplaying ? "pause.fill" : "play.fill",
                label: model.isAutoplaying ? "Pause" : "Replay",
                width: nil,
                disabled: model.moveCount == 0
            ) {
                model.toggleAutoplay()
            }
            ControlButton(systemName: "chevron.right", label: "Next",
                          width: nil, disabled: !model.canStepForward) {
                model.stepForward()
            }
            ControlButton(systemName: "forward.end.fill", label: "End",
                          width: nil, disabled: !model.canStepForward) {
                model.goToEnd()
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Accuracy card

struct AccuracyCard: View {
    let name: String
    let color: PieceColor
    let report: SideReport?

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The figure on the card. At the accessibility sizes the tenth goes the
    /// same way the name and the verdict do, just below: "100.0%" is six
    /// glyphs, and six do not fit beside the colour disc in a third of the
    /// screen — the card used to render them as "100....". Nothing is really
    /// lost. VoiceOver still hears the tenth, and so does the report sheet,
    /// which has a whole dial to put it in.
    private var accuracyText: String {
        // A dash covers both "the engine has not answered yet" and "this
        // player never got to move", which are the two cases with no figure.
        guard let accuracy = report?.accuracy else { return "—" }
        return AccuracyFormat.percent(
            accuracy,
            fractionDigits: typeSize.isAccessibilitySize ? 0 : 1
        )
    }

    /// What the card says out loud. A player who never moved has no accuracy,
    /// and "not analyzed yet" would be wrong — there was nothing to analyze.
    private var accessibilitySpeech: String {
        guard let report else {
            return String(localized: "Not analyzed yet",
                          comment: "VoiceOver value before the engine has answered")
        }
        guard let accuracy = report.accuracy, let verdict = report.verdict else {
            return String(localized: "No moves played",
                          comment: "Stands in for the accuracy of a player who never got to move")
        }
        let percent = AccuracyFormat.number(accuracy)
        return String(localized: "accuracy.spoken",
                      defaultValue: "\(percent) percent accuracy, \(verdict)",
                      comment: "VoiceOver summary of a player's accuracy card")
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color == .white
                          ? AnyShapeStyle(Color.white.opacity(0.92))
                          : AnyShapeStyle(Color.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                Text(color == .white
                     ? String(localized: "W", comment: "One-letter abbreviation for White")
                     : String(localized: "B", comment: "One-letter abbreviation for Black"))
                    .scaledFont(12, relativeTo: .caption, weight: .heavy, design: .rounded)
                    .foregroundStyle(color == .white ? Color.black.opacity(0.75) : .white.opacity(0.9))
            }
            .scaledFrame(26, relativeTo: .caption)

            VStack(alignment: .leading, spacing: 0) {
                // Two of these cards and the report button share one row above
                // the board, so at the accessibility sizes the card keeps only
                // the number and lets the name and the verdict go. Nothing is
                // lost: the card speaks all three to VoiceOver either way.
                if !typeSize.isAccessibilitySize {
                    Text(name)
                        .scaledFont(10, relativeTo: .caption2, weight: .semibold, design: .rounded)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(accuracyText)
                    .scaledFont(16, relativeTo: .callout, weight: .heavy, design: .rounded)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let verdict = report?.verdict, !typeSize.isAccessibilitySize {
                    Text(verdict)
                        .scaledFont(9, relativeTo: .caption2, weight: .bold, design: .rounded)
                        .foregroundStyle(.secondaryText)
                }
            }
            // Long names and verdicts shrink rather than push the row wider.
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilitySpeech)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hudCard(cornerRadius: 12)
    }
}

// MARK: - Evaluation graph

/// The game's evaluation as one continuous shape: the pale area is White's
/// share of the position, the dark remainder is Black's.
struct EvalGraph: View {
    let curve: [Int]
    let plyIndex: Int
    let marks: [MoveAnalysis]
    var variant: ChessVariant = .standard
    let accent: Color
    let onScrub: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, _ in
                    guard curve.count > 1 else { return }
                    let points = curve.enumerated().map { index, value in
                        CGPoint(x: x(for: index, width: size.width),
                                y: y(for: value, height: size.height))
                    }

                    // The plot is inset by the cursor's radius (see `x(for:)`),
                    // so the first and last positions are carried flat out to
                    // the card's edges rather than leaving a wedge there.
                    let leadIn = CGPoint(x: 0, y: points[0].y)
                    let leadOut = CGPoint(x: size.width, y: points[points.count - 1].y)

                    // White's share of the position.
                    var area = Path()
                    area.move(to: CGPoint(x: 0, y: size.height))
                    area.addLine(to: leadIn)
                    for point in points { area.addLine(to: point) }
                    area.addLine(to: leadOut)
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(.white.opacity(0.78)))

                    // The curve itself, so small swings stay visible.
                    var line = Path()
                    line.move(to: leadIn)
                    for point in points { line.addLine(to: point) }
                    line.addLine(to: leadOut)
                    context.stroke(line, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

                    // Midline.
                    var mid = Path()
                    mid.move(to: CGPoint(x: 0, y: size.height / 2))
                    mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(mid, with: .color(.white.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Turning points worth noticing.
                    for mark in marks where curve.indices.contains(mark.ply + 1) {
                        let point = CGPoint(
                            x: x(for: mark.ply + 1, width: size.width),
                            y: y(for: curve[mark.ply + 1], height: size.height)
                        )
                        let radius: CGFloat = mark.quality == .blunder ? 4.0 : 3.2
                        let circle = Path(ellipseIn: CGRect(
                            x: point.x - radius, y: point.y - radius,
                            width: radius * 2, height: radius * 2
                        ))
                        context.fill(circle, with: .color(mark.quality.tint))
                        context.stroke(circle, with: .color(.black.opacity(0.45)),
                                       style: StrokeStyle(lineWidth: 1))
                    }

                    // Where we are now.
                    if curve.indices.contains(plyIndex) {
                        let cursorX = x(for: plyIndex, width: size.width)
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: cursorX, y: 0))
                        cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                        context.stroke(cursor, with: .color(accent),
                                       style: StrokeStyle(lineWidth: 1.5))
                        let dot = CGPoint(x: cursorX, y: y(for: curve[plyIndex], height: size.height))
                        let ring = Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5,
                                                         width: 10, height: 10))
                        context.fill(ring, with: .color(accent))
                        context.stroke(ring, with: .color(.black.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: 1.2))
                    }
                }

                if curve.count <= 1 {
                    Text("Evaluation appears as the engine works")
                        .scaledFont(10, relativeTo: .caption2, weight: .medium, design: .rounded)
                        .foregroundStyle(.tertiaryText)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in scrub(to: value.location.x, width: size.width) }
                    .onEnded { value in scrub(to: value.location.x, width: size.width) }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.32))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Design.cardStroke, lineWidth: 1)
        )
        // A drawn curve says nothing out loud, so the graph becomes one
        // adjustable element: its value is where the game stands at the
        // position on the board, and swiping up or down walks through it —
        // the same thing dragging along the curve does by hand.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Evaluation graph", comment: "VoiceOver name for the game's evaluation chart"))
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard curve.count > 1 else { return }
            switch direction {
            case .increment: onScrub(min(curve.count - 1, plyIndex + 1))
            case .decrement: onScrub(max(0, plyIndex - 1))
            @unknown default: break
            }
        }
    }

    /// Where the game stands at the position currently on the board.
    private var accessibilityValue: String {
        guard curve.indices.contains(plyIndex) else {
            return String(localized: "Not analyzed yet",
                          comment: "VoiceOver value before the engine has answered")
        }
        // A game already won on the board scores `SearchScore.mate` itself,
        // which would read "mates in 1" — see `evalForCurrentPly`.
        let value = curve[plyIndex]
        if abs(value) == SearchScore.mate {
            return value > 0
                ? String(localized: "White wins", comment: "VoiceOver: the game is over and White has won")
                : String(localized: "Black wins", comment: "VoiceOver: the game is over and Black has won")
        }
        return EvalFormat.spoken(centipawns: value, variant: variant)
    }

    /// How far the plot is held in from both edges, so the ring marking the
    /// position on the board is drawn whole: mapping ply 0 to x = 0 and the
    /// last ply to x = width put it half outside the card, and the canvas is
    /// clipped to the card's rounded rect, so it came out cut in half. That
    /// was not an edge case — the review opens on the final position, and
    /// Start and End land on exactly these two.
    ///
    /// The ring's 5 pt radius plus half of the 1.2 pt outline drawn around it,
    /// rounded up, so the outline clears the card's border too.
    private static let cursorRadius: CGFloat = 6

    private func plotInset(width: CGFloat) -> CGFloat {
        min(Self.cursorRadius, width / 4)
    }

    private func x(for index: Int, width: CGFloat) -> CGFloat {
        guard curve.count > 1 else { return 0 }
        let inset = plotInset(width: width)
        return inset + (width - inset * 2) * CGFloat(index) / CGFloat(curve.count - 1)
    }

    /// Win expectancy makes a far more readable curve than raw centipawns:
    /// it never runs off the top of the chart.
    private func y(for centipawns: Int, height: CGFloat) -> CGFloat {
        let share = WinChance.percent(centipawns: centipawns) / 100
        return height * (1 - share)
    }

    /// The inverse of `x(for:)`, so a finger still lands on the ply drawn
    /// under it. Clamped, which is what keeps the inset margins from being
    /// dead zones: dragging into either one reaches the end position.
    private func scrub(to positionX: CGFloat, width: CGFloat) {
        guard curve.count > 1, width > 0 else { return }
        let inset = plotInset(width: width)
        let usable = width - inset * 2
        guard usable > 0 else { return }
        let fraction = max(0, min(1, (positionX - inset) / usable))
        onScrub(Int((fraction * CGFloat(curve.count - 1)).rounded()))
    }
}

// MARK: - Banner

/// The verdict on the move currently on the board.
struct ReviewBanner: View {
    let analysis: MoveAnalysis?
    let move: PlayedMove?
    let eval: Int?
    let isAnalyzing: Bool
    let plyIndex: Int
    let outcome: GameOutcome
    let mode: GameMode
    var variant: ChessVariant = .standard

    var body: some View {
        HStack(spacing: 10) {
            if let analysis {
                QualityBadge(quality: analysis.quality, size: 30)
            } else {
                Image(systemName: plyIndex == 0 ? "flag.fill" : "hourglass")
                    .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.5))
                    .scaledFrame(30, relativeTo: .subheadline)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(analysis?.quality.tint ?? .white)
                    if let eval {
                        Text(EvalFormat.text(centipawns: eval))
                            .scaledFont(11, relativeTo: .caption2, weight: .bold, design: .monospaced)
                            .foregroundStyle(.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                    }
                }
                Text(detail)
                    .scaledFont(11, relativeTo: .caption2, weight: .medium, design: .rounded)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minHeight: 54, alignment: .leading)
        .hudCard(cornerRadius: 12)
        // One element for the card: the move in words, then the evaluation
        // as a sentence and the comment. A spoken label on the headline's own
        // text was longer than the text drawn, and the accessibility audit
        // measures a text by its label, so at the largest sizes it took the
        // headline for cut off; the headline's row alone, made an element,
        // was too low a target.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenHeadline)
        .accessibilityValue(
            [eval.map { EvalFormat.spoken(centipawns: $0, variant: variant) }, detail(spoken: true)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        )
        .animation(.easeOut(duration: 0.2), value: analysis?.ply)
    }

    private var headline: String {
        guard let move else { return String(localized: "Starting position") }
        let notation = "\(move.moveNumber)\(move.color == .white ? "." : "...") "
            + MoveNotation.display(move.san)
        guard let analysis else { return notation }
        return "\(notation) · \(analysis.quality.label)"
    }

    /// The headline as VoiceOver says it, with the move in words.
    private var spokenHeadline: String {
        guard let move else { return String(localized: "Starting position") }
        let spoken = BoardSpeech.numberedMove(move)
        guard let analysis else { return spoken }
        return "\(spoken). \(analysis.quality.label)"
    }

    private var detail: String { detail(spoken: false) }

    /// The line under the headline, or — `spoken` — the same with the moves
    /// in its comment in words, for VoiceOver.
    private func detail(spoken: Bool) -> String {
        if outcome.isGameOver, plyIndex > 0 {
            let ending = outcome.headline(mode: mode)
            // A mating move is always graded "Best move", and that grade's
            // comment reads "Checkmate — the strongest possible finish" — so
            // printing the result beside it said "checkmate" twice in one
            // breath. The grade is already on the line above; here the result
            // stands on its own. So with the hill reached, or the third check.
            switch outcome {
            case .checkmate, .kingOfTheHill, .threeChecks: return ending
            default: break
            }
            // Two sentences, and most result lines bring no full stop of their
            // own: joined with a bare space one ran straight into the verdict
            // ("You resigned The strongest move in the position."). Those that
            // end in an exclamation mark already have one, though, and a full
            // stop after it read "You win on time!. …".
            if let analysis {
                let stop = ending.last.map { ".!?…".contains($0) } == true ? "" : "."
                return "\(ending)\(stop) \(spoken ? analysis.spokenComment : analysis.comment)"
            }
            return ending
        }
        if let analysis { return spoken ? analysis.spokenComment : analysis.comment }
        if move == nil { return String(localized: "Step through the game to see how each move was judged.") }
        return isAnalyzing
            ? String(localized: "Still being analyzed…")
            : String(localized: "No verdict for this move.")
    }
}

// MARK: - Move strip

struct ReviewMoveStrip: View {
    let history: [PlayedMove]
    let analysis: GameAnalysis?
    let plyIndex: Int
    let accent: Color
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(history.enumerated()), id: \.offset) { ply, played in
                        let isCurrent = ply == plyIndex - 1
                        Button {
                            onSelect(ply)
                        } label: {
                            HStack(spacing: 3) {
                                // A game set up with Black to move opens on
                                // "1…", as the game's own strip writes it.
                                if played.color == .white || ply == 0 {
                                    Text(verbatim: played.color == .white ? "\(played.moveNumber)." : "\(played.moveNumber)…")
                                        .scaledFont(11, relativeTo: .caption2, weight: .medium, design: .rounded)
                                        .foregroundStyle(.tertiaryText)
                                }
                                Text(verbatim: MoveNotation.display(played.san))
                                    .scaledFont(13, relativeTo: .footnote, weight: isCurrent ? .bold : .medium, design: .monospaced)
                                    .foregroundStyle(isCurrent ? accent : .white.opacity(0.85))
                                if let quality = analysis?.move(at: ply)?.quality {
                                    QualityBadge(quality: quality, size: 13)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isCurrent ? Color.white.opacity(0.12) : .clear)
                            )
                            // The chip stays small enough that a ribbon of them
                            // reads as one line, but what the finger has to hit
                            // is the 44pt Apple asks for — the highlight is the
                            // only part that stays chip-sized.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The move in words and the grade as its value: read
                        // as it is drawn, the chip came out as notation
                        // spelt a letter at a time.
                        .accessibilityLabel(BoardSpeech.numberedMove(played))
                        .accessibilityValue(analysis?.move(at: ply)?.quality.label ?? "")
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .id(ply)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            // A floor, not a fixed height, for the reason `MoveHistoryStrip`
            // learned it: a horizontal scroller takes its height from its
            // content, and a chip is a 44 pt touch target plus 3 pt of padding
            // a side — exactly 50 at the type cap this screen carries, and
            // more than that the moment anything inside grows. Pinned, the
            // overflow was clipped.
            .frame(minHeight: 50)
            .hudCard(cornerRadius: 10)
            .onChange(of: plyIndex) {
                withAnimation(.easeOut(duration: 0.25)) {
                    reader.scrollTo(max(0, plyIndex - 1), anchor: .center)
                }
            }
            .onAppear {
                reader.scrollTo(max(0, plyIndex - 1), anchor: .center)
            }
        }
        .opacity(history.isEmpty ? 0.4 : 1)
    }
}

// MARK: - Time per move

/// How long each move took: White's moves rise above the line, Black's hang
/// below it, the way the big servers draw a game's clock. The move on the
/// board is lit, and its time is written beside the bars.
struct TimeBars: View {
    let times: [TimeInterval]
    /// Who played the first of `times` — Black, in a game set up with Black
    /// to move, and then every bar after it belongs to the other side.
    let firstMover: PieceColor
    let plyIndex: Int
    let accent: Color
    let onScrub: (Int) -> Void

    var body: some View {
        let longest = max(1, times.max() ?? 1)
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width / CGFloat(max(1, times.count))
                let middle = proxy.size.height / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 1)
                        .offset(y: middle)
                    ForEach(Array(times.enumerated()), id: \.offset) { ply, time in
                        let height = max(1, CGFloat(sqrt(time / longest)) * (middle - 1))
                        let isCurrent = ply + 1 == plyIndex
                        let isWhite = ply.isMultiple(of: 2) == (firstMover == .white)
                        Rectangle()
                            .fill(isCurrent ? accent : (isWhite ? Color.white.opacity(0.75) : Color.white.opacity(0.35)))
                            .frame(width: max(1, width - 1), height: height)
                            .offset(x: CGFloat(ply) * width,
                                    y: isWhite ? middle - height : middle + 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let ply = Int(value.location.x / max(1, width))
                    onScrub(min(times.count, max(0, ply + 1)))
                })
            }
            Text(verbatim: plyIndex > 0 && plyIndex <= times.count ? Self.short(times[plyIndex - 1]) : "—")
                .scaledFont(12, relativeTo: .caption, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .hudCard(cornerRadius: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time per move"))
        .accessibilityValue(plyIndex > 0 && plyIndex <= times.count
                            ? ClockFormat.spoken(times[plyIndex - 1]) : "")
    }

    /// "12s", "1:05" — and "12 s" in Czech. The seconds go through the
    /// system's duration format, which knows how each language writes a unit
    /// after a number; the format string this used wrote it the English way
    /// in every language.
    static func short(_ seconds: TimeInterval) -> String {
        guard seconds < 60 else { return ClockFormat.text(seconds) }
        let whole = Int(max(0, seconds).rounded(.up))
        return Duration.seconds(whole).formatted(.units(allowed: [.seconds], width: .narrow))
    }
}
