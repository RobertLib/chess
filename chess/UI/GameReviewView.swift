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
            let arguments = ProcessInfo.processInfo.arguments
            if let plyArgument = arguments.first(where: { $0.hasPrefix("--review-ply=") }),
               let ply = Int(plyArgument.dropFirst("--review-ply=".count)) {
                model.go(to: ply)
            }
            if arguments.contains("--review-report") {
                showReport = true
            }
#endif
        }
        .onDisappear { model.teardown() }
    }

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

            CircleButton(systemName: "arrow.trianglehead.2.clockwise.rotate.90",
                         label: "Flip the board") {
                withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.2))) {
                    model.manualFlip.toggle()
                }
            }
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
                    .foregroundStyle(.white.opacity(0.55))
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
                .scaledFrame(width: 50, height: 48, relativeTo: .subheadline)
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
            mode: model.mode
        )
    }

    private var evalForCurrentPly: Int? {
        guard let curve = model.analysis?.evalCurve, curve.indices.contains(model.plyIndex) else {
            return nil
        }
        // On the final position of a game that ended in mate the score would
        // read "mate in 1" — the result line already says it better.
        if model.plyIndex == model.moveCount, model.game.outcome.winner != nil { return nil }
        return curve[model.plyIndex]
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
                        .foregroundStyle(.white.opacity(0.5))
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
                        .foregroundStyle(.white.opacity(0.35))
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
        return EvalFormat.spoken(centipawns: curve[plyIndex])
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
                            .foregroundStyle(.white.opacity(0.55))
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
        .animation(.easeOut(duration: 0.2), value: analysis?.ply)
    }

    private var headline: String {
        guard let move else { return String(localized: "Starting position") }
        let notation = "\(move.moveNumber)\(move.color == .white ? "." : "...") "
            + MoveNotation.display(move.san)
        guard let analysis else { return notation }
        return "\(notation) · \(analysis.quality.label)"
    }

    private var detail: String {
        if outcome.isGameOver, plyIndex > 0 {
            let ending = outcome.headline(mode: mode)
            // A mating move is always graded "Best move", and that grade's
            // comment reads "Checkmate — the strongest possible finish" — so
            // printing the result beside it said "checkmate" twice in one
            // breath. The grade is already on the line above; here the result
            // stands on its own.
            if case .checkmate = outcome { return ending }
            // Two sentences, and the result line brings no full stop of its
            // own: joined with a bare space it ran straight into the verdict
            // ("You resigned The strongest move in the position.").
            if let analysis { return "\(ending). \(analysis.comment)" }
            return ending
        }
        if let analysis { return analysis.comment }
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
                                if played.color == .white {
                                    Text(verbatim: "\(played.moveNumber).")
                                        .scaledFont(11, relativeTo: .caption2, weight: .medium, design: .rounded)
                                        .foregroundStyle(.white.opacity(0.4))
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
                        .id(ply)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .frame(height: 50)
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
