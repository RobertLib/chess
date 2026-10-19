//
//  MenuView.swift
//  chess
//
//  Main menu: new game setup (opponent, side, clock and starting position),
//  continue, and the ways in to puzzles, training, the clock, the archive and
//  the guide.
//

import SwiftUI

struct MenuView: View {
    @Environment(AppSettings.self) private var settings

    let onStartGame: (GameMode, GameOptions) -> Void
    /// False when the saved game could not be opened.
    let onContinueGame: (SavedGame) -> Bool

    private enum Stage {
        case root
        case aiSetup
        case twoPlayerSetup
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
    @State private var aiStart = StartChoice()
    @State private var twoPlayerStart = StartChoice()
    @State private var aiVariant: ChessVariant = .standard
    @State private var twoPlayerVariant: ChessVariant = .standard
    @State private var savedGame: SavedGame?
    /// Continue found a save whose moves no longer replay. It has been set
    /// aside, and the button goes with it: left up, every tap on it did
    /// nothing, and a new game still asked to replace the one that was gone.
    @State private var showUnreplayable = false
    @State private var latestGame: GameRecord?
    @State private var showSettings = false
    @State private var showTutorial = false
    @State private var showPuzzles = false
    @State private var showTraining = false
    @State private var showClock = false
    @State private var showMyGames = false
    @State private var timePickerFor: Stage?
    @State private var appeared = false
    /// A new game asked for while an unfinished one is saved. Starting it
    /// replaces that save, so the menu asks first instead of letting one stray
    /// tap on "Start Game" wipe out thirty moves of a game in progress.
    @State private var gameAwaitingConfirmation: PendingStart?
    /// A game asked for from Training that needs the question above. It waits
    /// for the training page to finish closing, the way the other pages here
    /// wait before presenting: a dialog put up while the page is still sliding
    /// away is not certain to be shown, and the game would go with it.
    @State private var startAfterTraining: PendingStart?
    @Environment(\.presentationReset) private var presentationReset

    private struct PendingStart: Equatable {
        var mode: GameMode
        var options: GameOptions
    }

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

                        // The menu slides aside for a setup page and back,
                        // and under Reduce Motion it fades instead, the way
                        // every other change of page in the app does.
                        Group {
                            switch stage {
                            case .root:
                                rootButtons
                                    .transition(Motion.transition(
                                        .move(edge: .leading).combined(with: .opacity)
                                    ))
                            case .aiSetup:
                                aiSetup
                                    .transition(Motion.transition(
                                        .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            case .twoPlayerSetup:
                                twoPlayerSetup
                                    .transition(Motion.transition(
                                        .move(edge: .trailing).combined(with: .opacity)
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
        .sheet(item: Binding(
            get: { timePickerFor.map(TimePickerTarget.init) },
            set: { timePickerFor = $0?.stage }
        )) { target in
            TimeControlPicker(
                selection: Binding(
                    get: { target.stage == .aiSetup ? settings.aiTimeControl : settings.twoPlayerTimeControl },
                    set: { value in
                        if target.stage == .aiSetup {
                            settings.aiTimeControl = value
                        } else {
                            settings.twoPlayerTimeControl = value
                        }
                    }
                ),
                allowsNone: true
            )
            .environment(settings)
        }
        .fullScreenCover(isPresented: $showTutorial) {
            TutorialView(onClose: { showTutorial = false })
                .environment(settings)
        }
        .fullScreenCover(isPresented: $showPuzzles) {
            PuzzleHubView(onClose: { showPuzzles = false })
                .environment(settings)
        }
        .fullScreenCover(isPresented: $showTraining, onDismiss: askAfterTraining) {
            TrainingHubView(
                onClose: { showTraining = false },
                onPlay: { mode, options in
                    showTraining = false
                    if replacesUnfinishedGame {
                        startAfterTraining = PendingStart(mode: mode, options: options)
                    } else {
                        onStartGame(mode, options)
                    }
                }
            )
            .environment(settings)
        }
        .fullScreenCover(isPresented: $showClock) {
            ChessClockView(onClose: { showClock = false })
                .environment(settings)
        }
        .fullScreenCover(isPresented: $showMyGames, onDismiss: refresh) {
            MyGamesView(onClose: { showMyGames = false })
                .environment(settings)
        }
        .confirmationDialog(
            "Replace the unfinished game?",
            isPresented: Binding(
                get: { gameAwaitingConfirmation != nil },
                set: { if !$0 { gameAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Start New Game", role: .destructive) {
                if let pending = gameAwaitingConfirmation { onStartGame(pending.mode, pending.options) }
                gameAwaitingConfirmation = nil
            }
        } message: {
            Text("The game waiting under Continue will be lost.")
        }
        // The widget's daily puzzle is presented from the root, which has to
        // be free to present it.
        .onChange(of: presentationReset) {
            showSettings = false
            timePickerFor = nil
            showTutorial = false
            showPuzzles = false
            showTraining = false
            showClock = false
            showMyGames = false
            gameAwaitingConfirmation = nil
            startAfterTraining = nil
            // Left up, the alert kept the root presenting, and the puzzle
            // the widget was tapped for never opened.
            showUnreplayable = false
        }
        // The setup is kept in the settings, because this view is not: it
        // leaves the screen for every game and comes back with its state new.
        .onAppear { restoreSetup() }
        .onChange(of: currentSetup) { _, setup in settings.menuSetup = setup }
        .onAppear {
            refresh()
            withAnimation(Motion.decorative(.spring(duration: 0.8, bounce: 0.25).delay(0.1))) {
                appeared = true
            }
#if DEBUG
            let arguments = LaunchArguments.once(for: "menu")
            if arguments.contains("--menu-ai-setup") {
                stage = .aiSetup
            }
            if arguments.contains("--menu-2p-setup") {
                stage = .twoPlayerSetup
            }
            if arguments.contains("--show-settings") {
                showSettings = true
            }
            if arguments.contains("--tutorial")
                || arguments.contains(where: { $0.hasPrefix("--tutorial-chapter=") }) {
                showTutorial = true
            }
            if arguments.contains("--puzzles") { showPuzzles = true }
            if arguments.contains("--training") { showTraining = true }
            if arguments.contains("--chess-clock") { showClock = true }
            if arguments.contains("--my-games") { showMyGames = true }
#endif
        }
    }

    private struct TimePickerTarget: Identifiable {
        let stage: Stage
        var id: String { stage == .aiSetup ? "ai" : "2p" }
    }

    private var currentSetup: MenuSetup {
        var setup = MenuSetup()
        setup.difficulty = difficulty
        setup.side = colorChoice.rawValue
        setup.aiStart = aiStart
        setup.twoPlayerStart = twoPlayerStart
        setup.aiVariant = aiVariant
        setup.twoPlayerVariant = twoPlayerVariant
        return setup
    }

    private func restoreSetup() {
        let setup = settings.menuSetup
        difficulty = setup.difficulty
        colorChoice = ColorChoice(rawValue: setup.side) ?? .white
        aiStart = setup.aiStart
        twoPlayerStart = setup.twoPlayerStart
        aiVariant = setup.aiVariant
        twoPlayerVariant = setup.twoPlayerVariant
    }

    private func refresh() {
        savedGame = SavedGame.load()
        // The last game played here, not the newest record: imported games
        // are filed among the rest by their date, and one with no date at all
        // files as today's — so right after an import, "Last game" used to
        // count the moves of somebody else's game from the file.
        //
        // Read in the background the first time. Read here, the archive was
        // decoded on the main thread at every launch before the menu had
        // settled. Once it is in memory it is taken at once, so the menu
        // coming back after a game shows that game from its first frame.
        let archive = GameArchive.shared
        if let records = archive.recordsInMemory {
            latestGame = records.first { $0.source == .played }
        } else {
            Task { latestGame = await archive.loadRecords().first { $0.source == .played } }
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
                .foregroundStyle(.secondaryText)
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
                    if !onContinueGame(saved) {
                        refresh()
                        showUnreplayable = true
                    }
                }
            }

            MenuButton(
                title: "Play vs Computer",
                subtitle: String(localized: "Five levels and an adaptive opponent"),
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
                withAnimation(Motion.meaningful(.spring(duration: 0.45, bounce: 0.2))) { stage = .twoPlayerSetup }
            }

            MenuButton(
                title: "Puzzles",
                subtitle: puzzleSubtitle,
                systemName: "puzzlepiece.fill"
            ) {
                showPuzzles = true
            }

            MenuButton(
                title: "Training",
                subtitle: String(localized: "Openings, analysis and positions"),
                systemName: "book.fill"
            ) {
                showTraining = true
            }

            MenuButton(
                title: "Chess Clock",
                subtitle: String(localized: "For a game on a real board"),
                systemName: "timer"
            ) {
                showClock = true
            }

            MenuButton(
                title: "My Games",
                subtitle: myGamesSubtitle,
                systemName: "chart.line.uptrend.xyaxis"
            ) {
                showMyGames = true
            }

            MenuButton(
                title: "How to Play",
                subtitle: tutorialSubtitle,
                systemName: "graduationcap.fill"
            ) {
                showTutorial = true
            }
        }
        // Hung here rather than beside the dialog on the page: two on the
        // same view are not reliably both presented.
        .alert("This game could not be opened.", isPresented: $showUnreplayable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The saved game's moves could not be replayed, so it cannot be continued.")
        }
    }

    /// Starts a game straight away unless an unfinished game with moves in it
    /// would be lost, in which case it asks.
    private func requestStart(_ mode: GameMode, _ options: GameOptions) {
        if replacesUnfinishedGame {
            gameAwaitingConfirmation = PendingStart(mode: mode, options: options)
        } else {
            onStartGame(mode, options)
        }
    }

    private var replacesUnfinishedGame: Bool {
        savedGame.map { !$0.moveUCIs.isEmpty } ?? false
    }

    /// Puts the question a game from Training was waiting on, now that the
    /// training page has gone.
    private func askAfterTraining() {
        gameAwaitingConfirmation = startAfterTraining
        startAfterTraining = nil
    }

    private var puzzleSubtitle: String {
        let progress = PuzzleStore.shared.progress
        if progress.attempts == 0 { return String(localized: "Over 4,000 tactics, offline") }
        let rating = String(Int(progress.rating.rounded()))
        return String(localized: "Rating \(rating) · \(progress.solved) solved")
    }

    private var myGamesSubtitle: String {
        guard let latestGame else { return String(localized: "History, statistics and achievements") }
        return String(localized: "Last game · \(latestGame.moveCount) moves")
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
    ///
    /// Counted on from where the game began: one set up from a position starts
    /// at that position's move number, and with Black to move it starts halfway
    /// through that move.
    private func continueSubtitle(for saved: SavedGame) -> String {
        let start = Board(fen: saved.initialFEN) ?? .initial
        let plies = saved.moveUCIs.count + (start.sideToMove == .black ? 1 : 0)
        let moves = start.fullmoveNumber + plies / 2
        var text: String
        switch saved.mode {
        case .twoPlayer: text = String(localized: "Two players · move \(moves)")
        case .vsAI(let difficulty, _):
            text = String(localized: "Computer (\(difficulty.displayName)) · move \(moves)")
        }
        if let control = saved.options?.timeControl { text += " · \(control.label)" }
        return text
    }

    // MARK: Shared setup pieces

    private func backButton() -> some View {
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
                // A chevron and one short word come to 48x17 pt, and this
                // is the only way back to the menu from the setup screen —
                // it has to be the 44 pt Apple asks for. `contentShape` is
                // what makes the transparent part of the target tappable;
                // `minHeight` yields once the text is bigger than that.
                .padding(.trailing, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func timeRow(for target: Stage) -> some View {
        let control = target == .aiSetup ? settings.aiTimeControl : settings.twoPlayerTimeControl
        return VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle("TIME CONTROL")
            Button {
                timePickerFor = target
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: control.map { $0.category.systemImage } ?? "infinity")
                        .scaledFont(16, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(Design.gold)
                        .scaledFrame(width: 24, relativeTo: .subheadline)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(control?.displayName ?? String(localized: "No clock", comment: "Time control: none"))
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                        Text(control == nil
                             ? String(localized: "Take as long as you like. Undo and hints are on.")
                             : String(localized: "Undo and hints are off on the clock."))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(12, relativeTo: .footnote, weight: .bold)
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .setupCard(selected: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Time control"))
            .accessibilityValue(control?.spokenName ?? String(localized: "No clock", comment: "Time control: none"))
        }
    }

    private func startButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Start Game")
                .font(.system(.body, design: .rounded, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.85))
                .multilineTextAlignment(.center)
                // The height comes from the text, the way `OverlayButton`'s
                // does: 22 pt of body text plus these two paddings is the
                // 50 pt this button has always been, and at the largest
                // text sizes it grows instead of letting the label spill
                // out of the pill. A fixed 50 pt frame needed 56 pt at AX4
                // and 63 pt at AX5, so the word hung over both edges.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Design.gold)
                        .shadow(color: Design.gold.opacity(0.35), radius: 12, y: 5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: AI setup

    private var aiSetup: some View {
        VStack(spacing: 18) {
            backButton()

            VStack(alignment: .leading, spacing: 8) {
                SetupSectionTitle("DIFFICULTY")

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
                                    Text(blurb(for: level))
                                        .font(.system(.caption2, design: .rounded))
                                        .foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                Image(systemName: difficulty == level ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(18, relativeTo: .title3)
                                    .foregroundStyle(difficulty == level ? Design.gold : .white.opacity(0.25))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .setupCard(selected: difficulty == level)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(difficulty == level ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupSectionTitle("PLAY AS")

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
                            .setupCard(selected: colorChoice == choice)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(colorChoice == choice ? .isSelected : [])
                    }
                }
            }

            timeRow(for: .aiSetup)

            StartPositionPicker(choice: $aiStart, oddsGiverIsComputer: true)

            VariantPicker(variant: $aiVariant)

            startButton {
                let color: PieceColor
                switch colorChoice {
                case .white: color = .white
                case .black: color = .black
                case .random: color = Bool.random() ? .white : .black
                }
                var options = GameOptions(
                    timeControl: settings.aiTimeControl,
                    start: aiStart.position(computerColor: color.opponent),
                    variant: aiVariant
                )
                if difficulty == .adaptive { options.adaptiveLevel = settings.adaptiveLevel }
                requestStart(.vsAI(difficulty: difficulty, playerColor: color), options)
            }
        }
    }

    /// The adaptive level says where it currently stands, which is the thing
    /// a player choosing it wants to know.
    private func blurb(for level: AIDifficulty) -> String {
        guard level == .adaptive else { return level.blurb }
        return String(localized: "Grows stronger as you do · now \(AIStrength.describe(level: settings.adaptiveLevel))",
                      comment: "Adaptive level blurb, with where it currently stands")
    }

    // MARK: Two-player setup

    private var twoPlayerSetup: some View {
        @Bindable var settings = settings
        return VStack(spacing: 18) {
            backButton()

            timeRow(for: .twoPlayerSetup)

            StartPositionPicker(choice: $twoPlayerStart, oddsGiverIsComputer: false)

            VariantPicker(variant: $twoPlayerVariant)

            VStack(alignment: .leading, spacing: 8) {
                SetupSectionTitle("LAYOUT")
                Toggle(isOn: $settings.tabletopMode) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Face to face")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                        Text("The device lies flat between you; the far side's pieces face its player.")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Design.gold)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .setupCard(selected: false)
            }

            startButton {
                let options = GameOptions(
                    timeControl: settings.twoPlayerTimeControl,
                    start: twoPlayerStart.position(computerColor: nil),
                    tabletop: settings.tabletopMode,
                    variant: twoPlayerVariant
                )
                requestStart(.twoPlayer, options)
            }
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

    @Environment(\.colorSchemeContrast) private var contrast

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
                    // At half white, and black at 55 % on the gold, the line
                    // read at about 4 : 1 — under the 4.5 : 1 small text
                    // needs — and stayed there with Increase Contrast on.
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(prominent
                            ? AnyShapeStyle(Color.black.opacity(contrast == .increased ? 0.8 : 0.65))
                            : AnyShapeStyle(.secondaryText))
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
        // Said outright, as the other cards say it: an element rebuilt with
        // `children: .ignore` is not guaranteed to keep the button's trait.
        .accessibilityAddTraits(.isButton)
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
