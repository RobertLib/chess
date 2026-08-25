//
//  MenuView.swift
//  chess
//
//  Main menu: new game setup (AI difficulty & color), continue, settings.
//

import SwiftUI

struct MenuView: View {
    @Environment(AppSettings.self) private var settings

    let onStartGame: (GameMode) -> Void
    let onContinueGame: (SavedGame) -> Void
    let onReviewGame: (FinishedGame) -> Void

    private enum Stage {
        case root
        case aiSetup
    }

    private enum ColorChoice: String, CaseIterable {
        case white, random, black

        var label: String {
            switch self {
            case .white: return String(localized: "side.choice.white", defaultValue: "White", comment: "Side to play as")
            case .random: return String(localized: "Random", comment: "Side to play as")
            case .black: return String(localized: "side.choice.black", defaultValue: "Black", comment: "Side to play as")
            }
        }
    }

    @State private var stage: Stage = .root
    @State private var difficulty: AIDifficulty = .medium
    @State private var colorChoice: ColorChoice = .white
    @State private var savedGame: SavedGame?
    @State private var finishedGame: FinishedGame?
    @State private var showSettings = false
    @State private var showTutorial = false
    @State private var appeared = false
    /// A new game asked for while an unfinished one is saved. Starting it
    /// replaces that save, so the menu asks first instead of letting one stray
    /// tap on "Two Players" wipe out thirty moves of a game in progress.
    @State private var modeAwaitingConfirmation: GameMode?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            FloatingPiecesBackground()
                .ignoresSafeArea()

            // Scrollable so the largest text sizes push the menu down the
            // screen instead of crushing every row into a truncated line.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        header
                            .padding(.top, 30)

                        Spacer(minLength: 24)

                        Group {
                            switch stage {
                            case .root:
                                rootButtons
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                    ))
                            case .aiSetup:
                                aiSetup
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            }
                        }
                        .frame(maxWidth: 420)

                        Spacer(minLength: 24)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // Settings gear.
            VStack {
                HStack {
                    Spacer()
                    CircleButton(systemName: "gearshape.fill", label: "Settings") { showSettings = true }
                }
                Spacer()
            }
            .padding(20)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(settings)
        }
        .fullScreenCover(isPresented: $showTutorial) {
            TutorialView(onClose: { showTutorial = false })
                .environment(settings)
        }
        .confirmationDialog(
            "Replace the unfinished game?",
            isPresented: Binding(
                get: { modeAwaitingConfirmation != nil },
                set: { if !$0 { modeAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Start New Game", role: .destructive) {
                if let mode = modeAwaitingConfirmation { onStartGame(mode) }
                modeAwaitingConfirmation = nil
            }
        } message: {
            Text("The game waiting under Continue will be lost.")
        }
        .onAppear {
            savedGame = SavedGame.load()
            // A game that ended before a move was played has nothing to
            // review. Nothing writes one any more, but an older build could
            // have left one behind.
            finishedGame = FinishedGame.load().flatMap { $0.moveUCIs.isEmpty ? nil : $0 }
            withAnimation(Motion.decorative(.spring(duration: 0.8, bounce: 0.25).delay(0.1))) {
                appeared = true
            }
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--menu-ai-setup") {
                stage = .aiSetup
            }
            if arguments.contains("--show-settings") {
                showSettings = true
            }
            if arguments.contains("--tutorial")
                || arguments.contains(where: { $0.hasPrefix("--tutorial-chapter=") }) {
                showTutorial = true
            }
#endif
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Design.gold.opacity(0.25), .clear],
                            center: .center, startRadius: 6, endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                PieceView(piece: Piece(.white, .king), shadow: false)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
            }
            .accessibilityHidden(true)
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)

            Text("Chess")
                .scaledFont(46, relativeTo: .largeTitle, weight: .heavy, design: .rounded)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Design.gold.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            Text("The classic game of kings")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: Root buttons

    private var rootButtons: some View {
        VStack(spacing: 12) {
            if let saved = savedGame {
                MenuButton(
                    title: "Continue",
                    subtitle: continueSubtitle(for: saved),
                    systemName: "play.fill",
                    prominent: true
                ) {
                    onContinueGame(saved)
                }
            }

            MenuButton(
                title: "Play vs Computer",
                subtitle: String(localized: "Five difficulty levels"),
                systemName: "desktopcomputer",
                prominent: savedGame == nil
            ) {
                withAnimation(Motion.meaningful(.spring(duration: 0.45, bounce: 0.2))) { stage = .aiSetup }
            }

            MenuButton(
                title: "Two Players",
                subtitle: String(localized: "On one device"),
                systemName: "person.2.fill"
            ) {
                requestStart(.twoPlayer)
            }

            if let finishedGame {
                MenuButton(
                    title: "Game Review",
                    subtitle: reviewSubtitle(for: finishedGame),
                    systemName: "chart.line.uptrend.xyaxis"
                ) {
                    onReviewGame(finishedGame)
                }
            }

            MenuButton(
                title: "How to Play",
                subtitle: tutorialSubtitle,
                systemName: "graduationcap.fill"
            ) {
                showTutorial = true
            }
        }
    }

    /// Starts a game straight away unless an unfinished game with moves in it
    /// would be lost, in which case it asks.
    private func requestStart(_ mode: GameMode) {
        if let savedGame, !savedGame.moveUCIs.isEmpty {
            modeAwaitingConfirmation = mode
        } else {
            onStartGame(mode)
        }
    }

    private func reviewSubtitle(for finished: FinishedGame) -> String {
        let moves = (finished.moveUCIs.count + 1) / 2
        return String(localized: "Last game · \(moves) moves")
    }

    /// Nudges a beginner towards the guide, and shows progress once started.
    private var tutorialSubtitle: String {
        let read = settings.readTutorialChapters.count
        let total = TutorialGuide.chapters.count
        if read == 0 { return String(localized: "The rules, from the first move") }
        if read >= total { return String(localized: "All \(total) lessons read") }
        return String(localized: "\(read) of \(total) lessons read")
    }

    /// The move the game stands on — the number a player would write next to
    /// their next move. Counting the pairs already played got this wrong at
    /// both ends: a game saved before anyone had moved (which is what starting
    /// one and leaving straight away does) read "move 0", and after 1.e4 e5 it
    /// still read "move 1" although the game had reached move 2.
    private func continueSubtitle(for saved: SavedGame) -> String {
        let moves = saved.moveUCIs.count / 2 + 1
        switch saved.mode {
        case .twoPlayer: return String(localized: "Two players · move \(moves)")
        case .vsAI(let difficulty, _):
            return String(localized: "Computer (\(difficulty.displayName)) · move \(moves)")
        }
    }

    // MARK: AI setup

    private var aiSetup: some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    withAnimation(Motion.meaningful(.spring(duration: 0.45, bounce: 0.2))) { stage = .root }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("DIFFICULTY")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.2)

                VStack(spacing: 6) {
                    ForEach(AIDifficulty.allCases) { level in
                        Button {
                            difficulty = level
                            Haptics.pieceSelected()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(level.displayName)
                                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text(level.blurb)
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: difficulty == level ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(18, relativeTo: .title3)
                                    .foregroundStyle(difficulty == level ? Design.gold : .white.opacity(0.25))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(difficulty == level ? 0.12 : 0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                difficulty == level ? Design.gold.opacity(0.5) : Color.white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(difficulty == level ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PLAY AS")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.2)

                HStack(spacing: 8) {
                    ForEach(ColorChoice.allCases, id: \.self) { choice in
                        Button {
                            colorChoice = choice
                            Haptics.pieceSelected()
                        } label: {
                            VStack(spacing: 5) {
                                Group {
                                    switch choice {
                                    case .white:
                                        PieceView(piece: Piece(.white, .pawn), shadow: false)
                                    case .black:
                                        PieceView(piece: Piece(.black, .pawn), shadow: false)
                                    case .random:
                                        Image(systemName: "questionmark")
                                            .scaledFont(20, relativeTo: .title3, weight: .bold)
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                                .scaledFrame(34, relativeTo: .title3)
                                Text(choice.label)
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(colorChoice == choice ? 0.12 : 0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                colorChoice == choice ? Design.gold.opacity(0.5) : Color.white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(colorChoice == choice ? .isSelected : [])
                    }
                }
            }

            Button {
                let color: PieceColor
                switch colorChoice {
                case .white: color = .white
                case .black: color = .black
                case .random: color = Bool.random() ? .white : .black
                }
                requestStart(.vsAI(difficulty: difficulty, playerColor: color))
            } label: {
                Text("Start Game")
                    .font(.system(.body, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Design.gold)
                            .shadow(color: Design.gold.opacity(0.35), radius: 12, y: 5)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Menu button

private struct MenuButton: View {
    let title: LocalizedStringKey
    let subtitle: String
    let systemName: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .scaledFont(19, relativeTo: .title3, weight: .semibold)
                    .foregroundStyle(prominent ? Color.black.opacity(0.8) : Design.gold)
                    .scaledFrame(40, relativeTo: .title3)
                    .background(
                        Circle().fill(prominent ? Color.black.opacity(0.12) : Color.white.opacity(0.07))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(prominent ? Color.black.opacity(0.88) : .white)
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(prominent ? Color.black.opacity(0.55) : .white.opacity(0.5))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .bold)
                    .foregroundStyle(prominent ? Color.black.opacity(0.45) : .white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Design.gold) : AnyShapeStyle(Color.white.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(prominent ? 0 : 0.11), lineWidth: 1)
                    )
                    .shadow(color: prominent ? Design.gold.opacity(0.3) : .clear, radius: 14, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}

// MARK: - Floating background pieces

private struct FloatingPiecesBackground: View {
    private struct Item {
        let kind: PieceKind
        let x: CGFloat        // relative 0-1
        let y: CGFloat
        let size: CGFloat
        let rotation: Double
        let duration: Double
    }

    private let items: [Item] = [
        Item(kind: .knight, x: 0.12, y: 0.16, size: 150, rotation: -14, duration: 7.5),
        Item(kind: .rook, x: 0.88, y: 0.24, size: 120, rotation: 11, duration: 9),
        Item(kind: .bishop, x: 0.08, y: 0.72, size: 135, rotation: 9, duration: 8),
        Item(kind: .queen, x: 0.90, y: 0.78, size: 170, rotation: -8, duration: 10),
        Item(kind: .pawn, x: 0.55, y: 0.92, size: 100, rotation: 13, duration: 6.5),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                FloatingPiece(item: item)
                    .position(x: proxy.size.width * item.x, y: proxy.size.height * item.y)
            }
        }
        .accessibilityHidden(true)
    }

    private struct FloatingPiece: View {
        let item: Item
        @State private var drifting = false

        var body: some View {
            // Asked here rather than in `onAppear` so a change to Reduce Motion
            // reaches pieces that are already drifting.
            let mayDrift = Motion.allowsRepeatingDecoration
            return PieceArt.silhouette(item.kind)
                .fill(Color.white.opacity(0.045))
                .frame(width: PieceArt.designSize, height: PieceArt.designSize)
                .scaleEffect(item.size / PieceArt.designSize)
                .rotationEffect(.degrees(drifting ? item.rotation : -item.rotation))
                .offset(y: drifting ? -14 : 14)
                .animation(
                    Motion.decorative(
                        .easeInOut(duration: item.duration).repeatForever(autoreverses: true)
                    ),
                    value: drifting
                )
                .onAppear { drifting = mayDrift }
                .onChange(of: mayDrift) { _, new in drifting = new }
        }
    }
}
