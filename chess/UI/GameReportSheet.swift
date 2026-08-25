//
//  GameReportSheet.swift
//  chess
//
//  The full breakdown behind the review: accuracy, how the moves of each
//  player were graded, and the moments that decided the game.
//

import SwiftUI

struct GameReportSheet: View {
    let model: GameReviewModel
    /// Called with the ply of a move the player wants to look at.
    let onSelectPly: (Int) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The dial grows with the text inside it, so the percentage — the one
    /// number the whole report is about — never has to be truncated to fit.
    @ScaledMetric(relativeTo: .title3) private var dialSize: CGFloat = 92
    @ScaledMetric(relativeTo: .title3) private var dialStroke: CGFloat = 8
    /// The two count columns of the breakdown table. Capped: the counts are
    /// one or two digits, so past a point a wider column only steals room from
    /// the move-quality label between them.
    @ScaledMetric(relativeTo: .subheadline) private var rawCountColumn: CGFloat = 56
    private var countColumn: CGFloat { min(rawCountColumn, 80) }

    private var analysis: GameAnalysis? { model.analysis }
    private var left: PieceColor { model.primaryColor }
    private var right: PieceColor { model.primaryColor.opponent }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        resultCard
                        if let analysis {
                            accuracySection(analysis)
                            breakdownSection(analysis)
                            momentsSection(analysis)
                        } else {
                            Text("The engine is still working through the game.")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Game Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Result

    private var resultHeadline: String {
        let headline = model.game.outcome.headline(mode: model.mode)
        return headline.isEmpty ? String(localized: "Unfinished game") : headline
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(resultHeadline)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                if let opening = analysis?.openingName {
                    Label(opening, systemImage: "book.closed.fill")
                        .scaledFont(11, relativeTo: .caption2, weight: .semibold, design: .rounded)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(String(localized: "report.moveCount",
                            defaultValue: "\((model.moveCount + 1) / 2) moves",
                            comment: "How long the game was, on the report header"))
                    .scaledFont(11, relativeTo: .caption2, weight: .medium, design: .rounded)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hudCard(cornerRadius: 16)
    }

    // MARK: Accuracy

    private func accuracySection(_ analysis: GameAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ACCURACY")
            // Two dials stop fitting side by side once the text is turned up,
            // and a row that overflows drags the whole sheet wider than the
            // screen. Past the accessibility sizes they stack instead.
            let dials = ForEach([left, right], id: \.self) { color in
                accuracyDial(analysis.report(for: color), name: model.name(for: color))
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 16) { dials }
            } else {
                HStack(spacing: 12) { dials }
            }
        }
    }

    /// Green for a clean game through to red for a messy one.
    private static func tint(for accuracy: Double) -> Color {
        switch accuracy {
        case 90...: return MoveQuality.best.tint
        case 80..<90: return MoveQuality.excellent.tint
        case 68..<80: return MoveQuality.inaccuracy.tint
        case 55..<68: return MoveQuality.mistake.tint
        default: return MoveQuality.blunder.tint
        }
    }

    private func accuracyDial(_ report: SideReport, name: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: dialStroke)
                // An empty track and a dash for a player who never got to
                // move: there is no accuracy to draw an arc from.
                if let accuracy = report.accuracy {
                    Circle()
                        .trim(from: 0, to: max(0.01, accuracy / 100))
                        .stroke(Self.tint(for: accuracy),
                                style: StrokeStyle(lineWidth: dialStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(report.accuracy.map { AccuracyFormat.number($0) } ?? "—")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(.white)
                    if report.accuracy != nil {
                        Text(verbatim: "%")
                            .scaledFont(9, relativeTo: .caption2, weight: .bold, design: .rounded)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, dialStroke)
            }
            .frame(width: dialSize, height: dialSize)
            .padding(.top, 4)

            VStack(spacing: 1) {
                Text(name)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(report.verdict ?? String(
                    localized: "No moves played",
                    comment: "Stands in for the accuracy of a player who never got to move"
                ))
                    .scaledFont(11, relativeTo: .caption2, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.55))
                if let loss = report.averageCentipawnLoss {
                    Text(String(localized: "\(loss) cp lost / move",
                                comment: "Average centipawn loss per move"))
                        .scaledFont(9, relativeTo: .caption2, weight: .medium, design: .rounded)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .hudCard(cornerRadius: 16)
    }

    // MARK: Breakdown

    private func breakdownSection(_ analysis: GameAnalysis) -> some View {
        let leftReport = analysis.report(for: left)
        let rightReport = analysis.report(for: right)
        let rows = MoveQuality.summaryOrder.filter {
            leftReport.count($0) > 0 || rightReport.count($0) > 0
        }

        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MOVE BREAKDOWN")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(model.name(for: left))
                        .frame(width: countColumn, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(model.name(for: right))
                        .frame(width: countColumn, alignment: .trailing)
                }
                .scaledFont(10, relativeTo: .caption2, weight: .bold, design: .rounded)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

                ForEach(rows, id: \.self) { quality in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(leftReport.count(quality))")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white.opacity(leftReport.count(quality) > 0 ? 0.95 : 0.25))
                            .frame(width: countColumn, alignment: .leading)

                        Spacer(minLength: 0)

                        HStack(spacing: 7) {
                            QualityBadge(quality: quality, size: 18)
                            Text(quality.label)
                                .scaledFont(12, relativeTo: .caption, weight: .semibold, design: .rounded)
                                .foregroundStyle(quality.tint)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Text(verbatim: "\(rightReport.count(quality))")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white.opacity(rightReport.count(quality) > 0 ? 0.95 : 0.25))
                            .frame(width: countColumn, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .hudCard(cornerRadius: 16)
        }
    }

    // MARK: Key moments

    private func momentsSection(_ analysis: GameAnalysis) -> some View {
        let moments = keyMoments(analysis)
        return Group {
            if !moments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("KEY MOMENTS")
                    VStack(spacing: 8) {
                        ForEach(moments) { moment in
                            Button {
                                onSelectPly(moment.ply)
                            } label: {
                                HStack(spacing: 10) {
                                    QualityBadge(quality: moment.quality, size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: "\(moveLabel(moment)) · \(model.name(for: moment.color))")
                                            .scaledFont(13, relativeTo: .footnote, weight: .bold, design: .rounded)
                                            .foregroundStyle(.white)
                                        Text(moment.comment)
                                            .scaledFont(11, relativeTo: .caption2, weight: .medium, design: .rounded)
                                            .foregroundStyle(.white.opacity(0.6))
                                            .lineLimit(typeSize.isAccessibilitySize ? 8 : 2)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .scaledFont(11, relativeTo: .caption2, weight: .bold)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .hudCard(cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// The handful of moves that shaped the game: the worst slip of each
    /// player, plus anything brilliant.
    private func keyMoments(_ analysis: GameAnalysis) -> [MoveAnalysis] {
        var plies: [Int] = []
        for color in [left, right] {
            let report = analysis.report(for: color)
            if let worst = report.worstPly { plies.append(worst) }
            if let best = report.bestPly { plies.append(best) }
        }
        // Then the biggest remaining swings, so short games still show something.
        let swings = analysis.moves
            .filter { $0.quality == .blunder || $0.quality == .miss }
            .sorted { $0.pointsLost > $1.pointsLost }
            .prefix(4)
            .map(\.ply)
        plies.append(contentsOf: swings)

        var seen = Set<Int>()
        return plies
            .filter { seen.insert($0).inserted }
            .compactMap { analysis.move(at: $0) }
            .sorted { $0.ply < $1.ply }
    }

    private func moveLabel(_ moment: MoveAnalysis) -> String {
        let played = moment.played
        return "\(played.moveNumber)\(played.color == .white ? "." : "...") "
            + MoveNotation.display(played.san)
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(1.2)
    }
}
