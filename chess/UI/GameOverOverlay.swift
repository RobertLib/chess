//
//  GameOverOverlay.swift
//  chess
//
//  End-of-game overlay with result, confetti for wins and follow-up actions.
//

import SwiftUI

struct GameOverOverlay: View {
    let model: GameViewModel
    let theme: BoardTheme
    let onReview: () -> Void
    let onRematch: () -> Void
    let onNewGame: () -> Void
    let onExit: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var outcome: GameOutcome { model.game.outcome }

    private var isCelebration: Bool {
        switch model.mode {
        case .vsAI(_, let playerColor):
            return outcome.winner == playerColor
        case .twoPlayer:
            return outcome.winner != nil
        }
    }

    private var symbolName: String {
        if isCelebration { return "crown.fill" }
        if outcome.isDraw { return "equal.circle.fill" }
        return "flag.checkered"
    }

    private var symbolColor: Color {
        if isCelebration { return Design.gold }
        if outcome.isDraw { return .white.opacity(0.7) }
        return Color(red: 0.85, green: 0.45, blue: 0.4)
    }

    private var subtitle: String {
        switch outcome {
        case .checkmate:
            return String(localized: "The king has nowhere to run.")
        case .stalemate:
            return String(localized: "The player to move has no legal move.")
        case .drawFiftyMoveRule:
            return String(localized: "50 moves without a capture or pawn move.")
        case .drawThreefoldRepetition:
            return String(localized: "The same position occurred three times.")
        case .drawInsufficientMaterial:
            return String(localized: "Neither player can deliver checkmate.")
        case .drawAgreed:
            return String(localized: "Both players agreed to a draw.")
        case .resigned:
            return String(localized: "The game ended by resignation.")
        case .ongoing:
            return ""
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            if isCelebration, Motion.allowsRepeatingDecoration {
                ConfettiView(colors: [
                    Design.gold, theme.accent, .white,
                    Color(red: 0.4, green: 0.75, blue: 0.95),
                    Color(red: 0.9, green: 0.45, blue: 0.5),
                ])
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            // The card scrolls rather than squeezes. At the largest text sizes
            // it is taller than the screen, and a stack that has to fit
            // compresses its texts into "Checkm…" and "Back to…" instead.
            GeometryReader { proxy in
                ScrollView {
                    card
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Image(systemName: symbolName)
                .scaledFont(46, relativeTo: .largeTitle, weight: .bold)
                .foregroundStyle(symbolColor)
                .shadow(color: symbolColor.opacity(0.55), radius: 16)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(outcome.headline(mode: model.mode))
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            movesSummary

            VStack(spacing: 10) {
                // Resigning before playing a move ends the game with an
                // empty move list, and there is nothing to grade; the
                // rematch takes over as the obvious next step.
                let canReview = !model.game.history.isEmpty
                if canReview {
                    OverlayButton(
                        title: "Game Review",
                        systemName: "chart.line.uptrend.xyaxis",
                        prominent: true,
                        action: onReview
                    )
                }
                OverlayButton(title: model.mode.isVsAI ? "Rematch" : "New Game",
                              prominent: !canReview, action: onRematch)
                if model.mode.isVsAI {
                    OverlayButton(title: "Play Again (same side)", action: onNewGame)
                }
                OverlayButton(title: "Back to Menu", action: onExit)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(maxWidth: 330)
        // A container first: a label and traits put on a plain stack are
        // handed down to every element inside it, which made all three
        // buttons — and every line of text — announce themselves as
        // "Checkmate! Black wins". As a container the card carries the label
        // and the modal trait itself and the buttons keep their own names.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(outcome.headline(mode: model.mode))
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.backgroundTop, theme.backgroundBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 34, y: 14)
        )
    }

    private var movesSummary: some View {
        let moveCount = (model.game.history.count + 1) / 2
        let captureCount = model.game.history.count(where: { $0.move.isCapture })
        let checkCount = model.game.history.count(where: { $0.san.contains("+") || $0.san.contains("#") })

        // Plain category labels rather than counted phrases: the figure above
        // each one is the count, and a bare plural reads correctly in every
        // language without having to agree with it.
        // Three columns at the everyday sizes; rows at the accessibility
        // sizes, where a column too narrow for its word broke the word apart
        // ("Cap tu…"). Decided from the type size rather than measured with
        // `ViewThatFits`: the layout that one rejects stays in the view tree
        // with its text squeezed to nothing, and the accessibility audit
        // reports that as clipped text.
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    summaryItem(moveCount, "Moves", asRow: true)
                    summaryItem(captureCount, "Captures", asRow: true)
                    summaryItem(checkCount, "Checks", asRow: true)
                }
            } else {
                HStack(spacing: 18) {
                    summaryItem(moveCount, "Moves")
                    summaryItem(captureCount, "Captures")
                    summaryItem(checkCount, "Checks")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .hudCard(cornerRadius: 14)
    }

    @ViewBuilder
    private func summaryItem(_ count: Int, _ label: LocalizedStringKey, asRow: Bool = false) -> some View {
        let figure = Text(verbatim: "\(count)")
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
        let caption = Text(label)
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
        Group {
            if asRow {
                HStack(spacing: 8) {
                    figure
                    caption
                }
            } else {
                VStack(spacing: 2) {
                    figure
                    caption
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

}

struct OverlayButton: View {
    let title: LocalizedStringKey
    var systemName: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemName {
                    Image(systemName: systemName)
                        .scaledFont(15, relativeTo: .subheadline, weight: .bold)
                }
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white.opacity(0.9))
                // The height comes from the text alone: 46 pt at the default
                // size, and at the largest text sizes the title wraps and the
                // button grows with it instead of painting its second line
                // over the button below. A fixed 46 pt frame used to do the
                // latter, and the text-clipping audit rightly objected.
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(Design.gold) : AnyShapeStyle(Color.white.opacity(0.09)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(prominent ? 0 : 0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Confetti

/// Lightweight confetti burst drawn with Canvas. Deterministic per-particle
/// parameters derived from the index keep it allocation-free.
struct ConfettiView: View {
    let colors: [Color]

    /// How long the burst lasts. Once it is over the schedule is paused: the
    /// overlay behind it stays on screen until the player picks what to do
    /// next, and an unpaused `.animation` schedule would go on asking for a
    /// frame sixty times a second to draw an empty canvas.
    private static let duration: TimeInterval = 6

    @State private var startDate = Date()
    @State private var isFinished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isFinished)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startDate)
                guard elapsed < Self.duration else { return }

                for index in 0..<130 {
                    var random = UInt64(index &* 2654435761)
                    func nextUnit() -> Double {
                        random = random &* 6364136223846793005 &+ 1442695040888963407
                        return Double(random >> 40) / Double(1 << 24)
                    }

                    let delay = nextUnit() * 1.6
                    let time = elapsed - delay
                    guard time > 0 else { continue }

                    let startX = nextUnit() * size.width
                    let speed = 130 + nextUnit() * 190
                    let sway = (nextUnit() - 0.5) * 90
                    let swayFrequency = 1.2 + nextUnit() * 2.2
                    let rotationSpeed = (nextUnit() - 0.5) * 9
                    let width = 5 + nextUnit() * 6
                    let height = 8 + nextUnit() * 7
                    let color = colors[index % colors.count]

                    let y = -20 + time * speed
                    guard y < size.height + 30 else { continue }
                    let x = startX + sin(time * swayFrequency) * sway
                    let fade = max(0, min(1, 1.4 - time * 0.28))

                    var particle = context
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(time * rotationSpeed))
                    particle.opacity = fade
                    particle.fill(
                        Path(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                             cornerRadius: 1.5),
                        with: .color(color)
                    )
                }
            }
        }
        // The burst is timed from `startDate`, which is set when the state is
        // created; this only has to outlast it, so a frame either way costs
        // nothing but an empty draw.
        .task {
            try? await Task.sleep(for: .seconds(Self.duration))
            isFinished = true
        }
    }
}
