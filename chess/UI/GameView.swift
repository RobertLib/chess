//
//  GameView.swift
//  chess
//
//  The full game screen: player cards, board, controls, move history,
//  promotion picker and the game-over overlay.
//

import SwiftUI

struct GameView: View {
    @Bindable var model: GameViewModel
    @Environment(AppSettings.self) private var settings

    let onExit: () -> Void
    let onNewGame: (GameMode, GameOptions) -> Void
    let onReview: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.presentationReset) private var presentationReset

    /// A way of ending the game that is waiting to be confirmed. One piece of
    /// state and one dialog rather than a flag apiece: two
    /// `confirmationDialog`s on the same view are not reliably both presented.
    private enum EndingRequest: Equatable {
        case resign
        case draw
    }

    /// What the dialog is asking about. Not an optional that dismissal clears:
    /// the *title* is drawn from this too, and a title is not part of what
    /// `presenting:` holds on to, so clearing the state would let the wording
    /// change under the dismissal. `showEndingDialog` is what presents it, and
    /// the request simply stays as it was until the next one replaces it.
    @State private var endingRequest: EndingRequest = .resign
    @State private var showEndingDialog = false
    @State private var showSettings = false

    /// What VoiceOver is told about, watched as one value: a move that ends
    /// the game changes both at once and is spoken once, as the move with
    /// the result after it, while an ending that adds no move changes only
    /// the outcome.
    private struct SpokenProgress: Equatable {
        let moves: Int
        let outcome: GameOutcome
    }

    @ScaledMetric(relativeTo: .subheadline) private var rawCircleSide: CGFloat = Design.circleButtonSide

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                // A landscape iPad has width to spare and height to spare not
                // at all, so the board keeps the height and everything else
                // moves alongside it rather than squeezing it into a letterbox.
                let isWide = proxy.size.width > proxy.size.height * 1.15
                Group {
                    if isWide { wideLayout } else { tallLayout }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            if model.pendingPromotion != nil {
                promotionOverlay
                    .transition(.opacity)
            }

            if model.isPaused {
                pauseOverlay
                    .transition(.opacity)
            }

            if model.gameOverShown {
                GameOverOverlay(
                    model: model,
                    theme: settings.theme,
                    onReview: onReview,
                    onRematch: rematch,
                    onNewGame: playAgain,
                    onExit: onExit
                )
                .transition(Motion.transition(.opacity.combined(with: .scale(scale: 1.06))))
            }
        }
        // The cap covers the overlays as well as the board. The result card
        // used to sit outside it and, at the largest sizes, truncated every
        // line it had ("Checkm…", "Back to…").
        .boardTypeLimit()
        .statusBarHidden(false)
        // A VoiceOver player cannot see the board change, so every move that
        // lands — theirs or the computer's — is spoken, and so is a game
        // that ends without one.
        .onChange(of: SpokenProgress(moves: model.game.history.count, outcome: model.game.outcome)) { previous, current in
            // Only a move that was *added* is spoken as a move. After Undo the
            // last entry is the move before it, and reading that out would
            // announce a move nobody has just played.
            //
            // Every move added is spoken, not only the last: a premove is
            // played in the same instant as the computer's reply it was
            // waiting for, and reading the last entry alone told the player
            // their own move and never what the computer had done.
            if current.moves > previous.moves, let last = model.game.history.last {
                let history = model.game.history
                let earlier = history[max(previous.moves, 0)..<(history.count - 1)].map {
                    BoardSpeech.movedAnnouncement($0.move, san: $0.san)
                }
                let final = BoardSpeech.announcement(for: last, outcome: model.game.outcome, mode: model.mode)
                AccessibilityNotification.Announcement((earlier + [final]).joined(separator: ". ")).post()
            } else if current.moves < previous.moves {
                AccessibilityNotification.Announcement(
                    String(localized: "Move taken back", comment: "Spoken by VoiceOver after Undo")
                ).post()
            } else if !previous.outcome.isGameOver, current.outcome.isGameOver {
                // A flag falling, a resignation, a draw agreed: the game is
                // over and no move says so. Heard only as a move count, a
                // game lost on time went silent, and the result card that
                // follows is not read out until focus happens to reach it.
                AccessibilityNotification.Announcement(current.outcome.headline(mode: model.mode)).post()
            }
        }
        .confirmationDialog(
            endingPrompt,
            isPresented: $showEndingDialog,
            titleVisibility: .visible,
            // `presenting:` rather than reading the state inside the builder:
            // the dialog then holds on to the request it was opened with, so
            // nothing can swap the buttons underneath the tap that is
            // dismissing it.
            presenting: endingRequest
        ) { request in
            switch request {
            case .draw:
                Button("Agree to a Draw", role: .destructive) { model.agreeToDraw() }
            case .resign:
                Button("Resign", role: .destructive) { model.resign() }
            }
            Button("Keep Playing", role: .cancel) {}
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(settings)
        }
        // The game is held under the sheet, the way it is under any other
        // page of the app's own.
        .onChange(of: showSettings) { _, shown in
            if shown { model.sheetDidAppear() } else { model.sheetDidDisappear() }
        }
        // The widget's daily puzzle is presented from the root, which has to
        // be free to present it.
        .onChange(of: presentationReset) {
            showSettings = false
            showEndingDialog = false
        }
        // A clock has to know when nobody is looking at it: a timed game is
        // held the moment the app is covered, and the time spent on a move
        // stops counting whichever kind of game it is.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneDidActivate()
            } else {
                model.sceneDidDeactivate()
            }
        }
        // A game on the clock keeps the screen awake: the display going dark
        // in the middle of a blitz game is the clock's fault, not the player's.
        .onAppear { updateIdleTimer() }
        .onChange(of: model.game.outcome.isGameOver) { updateIdleTimer() }
        .onChange(of: model.isPaused) { updateIdleTimer() }
        .onDisappear { ScreenAwake.set(false, for: model) }
    }

    /// Awake while a clock can run. A paused game is one the player has put
    /// down — kept lit, the phone left on the table with the game held stayed
    /// on until its battery ran out — and Resume locks the screen on again.
    private func updateIdleTimer() {
        ScreenAwake.set(
            model.isTimed && !model.isPaused && !model.game.outcome.isGameOver,
            for: model
        )
    }

    /// Puts the question to the player. One state and one dialog, so the
    /// request has to be set before the dialog is shown.
    private func askToEnd(_ request: EndingRequest) {
        endingRequest = request
        showEndingDialog = true
    }

    private var endingPrompt: String {
        if endingRequest == .draw {
            return String(localized: "Agree to a draw?",
                          comment: "Confirmation before ending a two-player game as a draw")
        }
        return resignPrompt
    }

    /// Resigning gives up for whoever is on turn. Against the computer that can
    /// only be the player, but on a shared device it is worth saying out loud
    /// which of the two is about to lose.
    private var resignPrompt: String {
        guard case .twoPlayer = model.mode else {
            return String(localized: "Resign this game?", comment: "Confirmation before resigning")
        }
        // Spelled out per colour rather than substituted into one sentence:
        // Czech needs the accusative here (*za bílého*), which the nominative
        // "White" used everywhere else would get wrong.
        return model.game.sideToMove == .white
            ? String(localized: "Resign for White?",
                     comment: "Confirmation before resigning in a two-player game, with White on turn")
            : String(localized: "Resign for Black?",
                     comment: "Confirmation before resigning in a two-player game, with Black on turn")
    }

    private var board: some View {
        BoardView(
            model: model,
            theme: settings.theme,
            showCoordinates: settings.showCoordinates,
            showLegalMoves: settings.showLegalMoves
        )
        // Under Reduce Motion a turn of the board is a fade: the board seen
        // from the other side takes the place of this one. Animating the
        // orientation instead, with the shorter curve `Motion.meaningful`
        // swaps in, still slid every piece across the board to its mirrored
        // square — thirty-two things in motion for one change of view. With
        // motion allowed the identity never changes and the pieces turn.
        .id(Motion.isReduced ? model.orientation : nil)
        .transition(.opacity)
    }

    /// Phones, and iPads held upright: one column.
    private var tallLayout: some View {
        VStack(spacing: 10) {
            topBar
            Spacer(minLength: 2)
            playerCard(for: model.orientation.opponent)
                // Across a table the far player reads their own card.
                .rotationEffect(model.isTabletop ? .degrees(180) : .zero)
            board.padding(.horizontal, 6)
            playerCard(for: model.orientation)
            Spacer(minLength: 2)
            MoveHistoryStrip(history: model.game.history, accent: settings.theme.accent)
            controlBar
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    /// Landscape: board on one side, everything that reads as text on the other.
    private var wideLayout: some View {
        HStack(spacing: 18) {
            board

            VStack(spacing: 12) {
                topBar
                playerCard(for: model.orientation.opponent)
                    .rotationEffect(model.isTabletop ? .degrees(180) : .zero)
                Spacer(minLength: 6)
                MoveHistoryStrip(history: model.game.history, accent: settings.theme.accent)
                Spacer(minLength: 6)
                playerCard(for: model.orientation)
                controlBar
            }
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }

    /// The options for the next game: the same setup, with the adaptive
    /// opponent at the strength the game just played has moved it to.
    private func nextOptions(rerolling: Bool) -> GameOptions {
        var options = model.options
        if rerolling { options.start = options.start.rerolled() }
        if case .vsAI(.adaptive, _) = model.mode { options.adaptiveLevel = settings.adaptiveLevel }
        return options
    }

    /// Sides swapped, same position — a Chess960 rematch is played from the
    /// position the first game was, which is what makes it a rematch.
    ///
    /// Two players get no swap: the button is "New Game" there, the app does
    /// not know which of them sat on which side, and the odds stay with the
    /// colour they were set up for.
    private func rematch() {
        switch model.mode {
        case .twoPlayer:
            onNewGame(.twoPlayer, nextOptions(rerolling: true))
        case .vsAI(let difficulty, let playerColor):
            var options = nextOptions(rerolling: false)
            // The computer gives the odds, and in the rematch it plays the
            // side the player had. Left as it was, the handicap would stay on
            // the old colour and leave the player short of the piece instead.
            if case .handicap(let handicap, _) = options.start {
                options.start = .handicap(handicap, giver: playerColor)
            }
            onNewGame(.vsAI(difficulty: difficulty, playerColor: playerColor.opponent), options)
        }
    }

    private func playAgain() {
        onNewGame(model.mode, nextOptions(rerolling: true))
    }

    // MARK: Top bar

    private var topBar: some View {
        // Both ends are held to the same width so the title stays centred even
        // though the right side carries two buttons and the left one. The lane
        // tracks the buttons as they scale, or the title runs under them — and
        // it tracks their *targets*, which are the 44 pt Apple asks for even
        // where the drawn circle is smaller. The row's own spacing gives back
        // what the padding took, so the circles sit exactly as far apart as
        // they always did; each lane grows by 6 pt and the title gives up 12,
        // which measures out to nothing — the two longest titles there are
        // ("Vs Computer · Grandmaster", "Proti počítači · Velmistrovská") ran
        // to two lines at the old width as well.
        let circleSide = min(rawCircleSide, Design.circleButtonMaxSide)
        let buttonTarget = CircleButton.target(forSide: circleSide)
        let buttonGap = CircleButton.spacing(forSide: circleSide, gap: 8)
        let sideWidth = buttonTarget * 2 + buttonGap

        return HStack(spacing: 8) {
            HStack(spacing: buttonGap) {
                CircleButton(systemName: "chevron.left", label: "Back to menu") { onExit() }
            }
            .frame(width: sideWidth, alignment: .leading)

            VStack(spacing: 1) {
                Text(modeTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                if let setup = setupLine {
                    Text(setup)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(settings.theme.accent.opacity(0.9))
                }
                Text(statusLine)
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.opacity)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            HStack(spacing: buttonGap) {
                // Sounds, haptics, the board theme and the move markers are all
                // things a player wants to change mid-game; until now reaching
                // them meant abandoning the board for the menu.
                CircleButton(systemName: "gearshape.fill", label: "Settings") {
                    showSettings = true
                }
                CircleButton(systemName: "arrow.trianglehead.2.clockwise.rotate.90",
                             label: "Flip the board") {
                    withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.2))) {
                        model.manualFlip.toggle()
                    }
                }
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
    }

    private var modeTitle: String {
        switch model.mode {
        case .twoPlayer: return String(localized: "Two Players", comment: "Game mode")
        case .vsAI(let difficulty, _):
            return String(localized: "Vs Computer · \(difficulty.displayName)",
                          comment: "Game mode, with the difficulty level")
        }
    }

    /// The clock and the starting position, when either is anything but the
    /// default — "Blitz · 3 + 2 · Chess960 #412".
    private var setupLine: String? {
        var parts: [String] = []
        if let control = model.options.timeControl { parts.append(control.displayName) }
        if model.options.variant != .standard { parts.append(model.options.variant.displayName) }
        if !model.options.start.isStandard { parts.append(model.options.start.displayName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusLine: String {
        if model.game.outcome.isGameOver {
            return model.game.outcome.headline(mode: model.mode)
        }
        if model.isPaused { return String(localized: "Paused", comment: "Status line of a held game") }
        if model.aiThinking { return String(localized: "Computer is thinking…") }
        let side = model.game.sideToMove == .white
            ? String(localized: "side.toMove.white", defaultValue: "White", comment: "Side to move")
            : String(localized: "side.toMove.black", defaultValue: "Black", comment: "Side to move")
        return model.game.isInCheck
            ? String(localized: "Check! \(side) to move")
            : String(localized: "\(side) to move")
    }

    // MARK: Player cards

    private func playerCard(for color: PieceColor) -> some View {
        let isOnTurn = model.game.sideToMove == color && !model.game.outcome.isGameOver
        let captured = model.game.capturedPieces(by: color)
        let advantage = advantagePoints(for: color)

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color == .white
                          ? AnyShapeStyle(Color.white.opacity(0.92))
                          : AnyShapeStyle(Color.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                Image(systemName: iconName(for: color))
                    .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(color == .white ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
            }
            .scaledFrame(34, relativeTo: .subheadline)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(playerName(for: color))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    if isOnTurn {
                        Circle()
                            .fill(settings.theme.accent)
                            .frame(width: 7, height: 7)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if model.aiThinking && isAI(color) {
                        ThinkingDots()
                    }
                }
                HStack(spacing: 8) {
                    CapturedPiecesRow(pieces: captured, advantage: advantage)
                    if model.game.variant == .threeCheck {
                        CheckCounter(count: Int(model.game.board.checksGiven[color]))
                    }
                }
            }

            Spacer()

            if model.isTimed {
                ClockFace(model: model, color: color, accent: settings.theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .hudCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(settings.theme.accent.opacity(isOnTurn ? 0.55 : 0), lineWidth: 1.5)
        )
        .animation(.spring(duration: 0.3), value: isOnTurn)
        // What the card says is a stand-in laid over it rather than the card
        // itself. The card is drawn when a move changes it, and the time left
        // in its words was only ever that old: a player hearing it two minutes
        // into a think was told the time their turn began with. The digits
        // redraw on a timeline of their own (`ClockFace`); so does this, once
        // a second while this side's clock runs, and nothing but an empty
        // element is drawn again for it. It is marked as updating frequently —
        // Apple's own example for the trait is a stopwatch — which has
        // VoiceOver read the value when it needs it instead of reacting to
        // every tick, so the card is current when focused and silent between.
        .accessibilityHidden(true)
        .overlay {
            let ticking = model.isClockRunning && model.isClockActive(for: color)
            TimelineView(.animation(minimumInterval: 1, paused: !ticking)) { _ in
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(playerName(for: color))
                    .accessibilityValue(playerCardSpeech(color: color, isOnTurn: isOnTurn,
                                                         captured: captured, advantage: advantage))
                    .accessibilityAddTraits(model.isTimed ? .updatesFrequently : [])
            }
            .allowsHitTesting(false)
        }
    }

    /// The player card in words: whose turn it is, and how the material stands.
    private func playerCardSpeech(
        color: PieceColor, isOnTurn: Bool, captured: [Piece], advantage: Int
    ) -> String {
        var parts: [String] = [color.spokenName]
        if model.aiThinking && isAI(color) {
            parts.append(String(localized: "thinking", comment: "VoiceOver: the computer is searching"))
        } else if isOnTurn {
            parts.append(String(localized: "to move", comment: "VoiceOver: this player is on turn"))
        }
        if advantage > 0 {
            parts.append(String(localized: "ahead by \(advantage)",
                                comment: "VoiceOver: material advantage in pawns"))
        }
        if !captured.isEmpty {
            let names = captured.map(\.kind.spokenName).joined(separator: ", ")
            parts.append(String(localized: "captured: \(names)",
                                comment: "VoiceOver: list of pieces this player has taken"))
        }
        if model.game.variant == .threeCheck {
            parts.append(String(localized: "checks.spoken",
                                defaultValue: "\(Int(model.game.board.checksGiven[color])) of 3 checks given",
                                comment: "VoiceOver: three-check progress on a player's card"))
        }
        if let remaining = model.clockRemaining(for: color) {
            parts.append(String(localized: "clock.spoken.left",
                                defaultValue: "\(ClockFormat.spoken(remaining)) left",
                                comment: "VoiceOver: time left on a player's clock"))
        }
        return parts.joined(separator: ", ")
    }

    private func isAI(_ color: PieceColor) -> Bool {
        if case .vsAI(_, let playerColor) = model.mode { return color != playerColor }
        return false
    }

    private func iconName(for color: PieceColor) -> String {
        isAI(color) ? "desktopcomputer" : "person.fill"
    }

    private func playerName(for color: PieceColor) -> String {
        switch model.mode {
        case .twoPlayer:
            return color == .white
                ? String(localized: "player.name.white", defaultValue: "White", comment: "Player name")
                : String(localized: "player.name.black", defaultValue: "Black", comment: "Player name")
        case .vsAI(_, let playerColor):
            return color == playerColor
                ? String(localized: "You", comment: "Player name")
                : String(localized: "Computer", comment: "Player name")
        }
    }

    /// Positive material advantage in pawns for `color`, 0 when behind.
    private func advantagePoints(for color: PieceColor) -> Int {
        let balance = model.game.materialBalance
        let advantage = color == .white ? balance : -balance
        return max(0, advantage)
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 14) {
            // On the clock a move cannot be taken back, so the first slot holds
            // what a clock does have to offer: a pause.
            if model.isTimed {
                ControlButton(systemName: "pause.fill", label: "Pause", disabled: !model.canPause) {
                    model.pause()
                }
            } else {
                ControlButton(systemName: "arrow.uturn.backward", label: "Undo", disabled: !model.canUndo) {
                    withAnimation(Motion.meaningful(.spring(duration: 0.35))) { model.undo() }
                }
            }
            // The middle slot holds whatever the mode has to offer. Hint is
            // only ever answerable against the computer, so in a two-player
            // game it used to sit there greyed out for the whole game — a
            // third of the row that could never do anything. That is where the
            // draw the two players may settle on now lives instead: the guide
            // has always listed agreement among the five ways a game is drawn,
            // and until now it was the one the app had no way to reach.
            if model.mode.isVsAI {
                // A hint on the clock would be the engine playing for you
                // while your time runs; the slot stays, empty-handed.
                if !model.isTimed {
                    ControlButton(
                        systemName: "lightbulb",
                        label: "Hint",
                        disabled: !model.canRequestHint,
                        loading: model.hintThinking
                    ) {
                        model.requestHint()
                    }
                }
            } else {
                ControlButton(systemName: "equal.circle", label: "Draw", disabled: !model.canAgreeToDraw) {
                    askToEnd(.draw)
                }
            }
            ControlButton(systemName: "flag", label: "Resign", disabled: model.game.outcome.isGameOver) {
                askToEnd(.resign)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: Pause

    /// Covers the board while the game is held. Opaque on purpose: on a
    /// shared device a paused clock is no reason for the position to stay on
    /// show to the player whose time it is not costing.
    private var pauseOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(0.97)
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "pause.circle.fill")
                    .scaledFont(52, relativeTo: .largeTitle, weight: .bold)
                    .foregroundStyle(settings.theme.accent)
                    .accessibilityHidden(true)
                Text("Game Paused")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                if model.isTimed {
                    HStack(spacing: 22) {
                        pausedClock(.white)
                        pausedClock(.black)
                    }
                }
                VStack(spacing: 10) {
                    OverlayButton(title: "Resume", systemName: "play.fill", prominent: true) {
                        model.resume()
                    }
                    OverlayButton(title: "Back to Menu", action: onExit)
                }
                .frame(maxWidth: 300)
            }
            .padding(26)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func pausedClock(_ color: PieceColor) -> some View {
        let remaining = model.clockRemaining(for: color) ?? 0
        return VStack(spacing: 4) {
            Text(color.spokenName)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(verbatim: ClockFormat.text(remaining, tenths: remaining < 10))
                .scaledFont(22, relativeTo: .title3, weight: .bold, design: .monospaced)
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(color.spokenName)
        .accessibilityValue(ClockFormat.spoken(remaining))
    }

    // MARK: Promotion

    private var promotionOverlay: some View {
        let color = model.pendingPromotion?.color ?? model.game.sideToMove
        return PromotionPickerOverlay(
            color: color,
            theme: settings.theme,
            // Asked of the same decoration the board turns the far side's
            // pieces by, so the picker and the pieces cannot disagree.
            facesFarSide: model.decorations.upsideDownColor == color,
            onPick: { model.completePromotion(with: $0) },
            onCancel: { model.cancelPromotion() }
        )
    }
}

// MARK: - Screen lock

/// Who is keeping the screen awake. A rematch swaps one game view for
/// another, and the old one's `onDisappear` comes after the new one's
/// `onAppear`, once the transition has run — so a plain "allow sleep again"
/// on the way out switched the new timed game's screen lock back on. Only
/// the game that holds the screen awake may let it go.
@MainActor
private enum ScreenAwake {
    private static var holder: ObjectIdentifier?

    static func set(_ awake: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if awake {
            holder = id
        } else if holder == id {
            holder = nil
        } else {
            return
        }
        UIApplication.shared.isIdleTimerDisabled = holder != nil
    }
}

// MARK: - Small components

struct CircleButton: View {
    let systemName: String
    /// Icon-only buttons say nothing on their own, so every one names itself.
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleButtonFace(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// What a `CircleButton` looks like, for a control that is not a plain
/// button — the menu behind My Games' "…" — and has to match the round
/// buttons beside it at every text size.
struct CircleButtonFace: View {
    let systemName: String

    @ScaledMetric(relativeTo: .subheadline) private var rawSide: CGFloat = Design.circleButtonSide
    @ScaledMetric(relativeTo: .subheadline) private var rawGlyph: CGFloat = Design.circleButtonGlyph
    private var side: CGFloat { min(rawSide, Design.circleButtonMaxSide) }
    /// What the finger has to hit. The circle is 38 pt at the everyday text
    /// sizes because a bigger one would crowd the title it sits beside, but
    /// these are a screen's only way back to the menu and into the settings,
    /// so the target around it is the full 44 pt.
    private var target: CGFloat { CircleButton.target(forSide: side) }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: min(rawGlyph, Design.circleButtonMaxGlyph), weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: side, height: side)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // Padded out after the circle is drawn, so the target grows
            // and the circle does not.
            .frame(width: target, height: target)
            .contentShape(Rectangle())
    }
}

extension CircleButton {
    /// The lane a row of these needs, so a caller laying them out beside a
    /// title measures the same thing the button does.
    static func target(forSide side: CGFloat) -> CGFloat {
        max(side, Design.minimumTouchTarget)
    }

    /// The spacing that leaves the circles the gap the design draws them with:
    /// the target already carries half the difference on each side, so the row
    /// only has to make up the rest.
    static func spacing(forSide side: CGFloat, gap: CGFloat) -> CGFloat {
        max(2, gap - (target(forSide: side) - side))
    }
}

struct ControlButton: View {
    let systemName: String
    let label: LocalizedStringKey
    /// Fixed width, or nil to share the row evenly with its siblings.
    var width: CGFloat? = 74
    var disabled = false
    /// Swaps the icon for a spinner while the button's work is in flight.
    var loading = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 50

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Image(systemName: systemName)
                        .scaledFont(17, relativeTo: .body, weight: .semibold)
                        .opacity(loading ? 0 : 1)
                    if loading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.82)
                    }
                }
                .scaledFrame(width: 21, height: 21, relativeTo: .body)
                Text(label)
                    .scaledFont(10, relativeTo: .caption2, weight: .semibold, design: .rounded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(.horizontal, 4)
            .foregroundStyle(.white.opacity(disabled && !loading ? 0.28 : 0.9))
            .frame(width: width)
            .frame(minHeight: controlHeight)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .hudCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct ThinkingDots: View {
    @State private var phase = false

    var body: some View {
        // Asked here rather than in `onAppear` so a change to Reduce Motion
        // reaches dots that are already bouncing.
        let mayBounce = Motion.allowsRepeatingDecoration
        return HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 4.5, height: 4.5)
                    .offset(y: phase ? -2.5 : 2)
                    .animation(
                        Motion.decorative(
                            .easeInOut(duration: 0.42)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.14)
                        ),
                        value: phase
                    )
            }
        }
        .onAppear { phase = mayBounce }
        .onChange(of: mayBounce) { _, new in phase = new }
    }
}

struct CapturedPiecesRow: View {
    let pieces: [Piece]
    let advantage: Int

    /// As tall as the pieces in it, which grow with the text setting. Pinned
    /// at 16 pt, the row stayed put while they and the "+3" beside them grew
    /// out of it, over the name above and the edge of the card below.
    @ScaledMetric(relativeTo: .caption2) private var rowHeight: CGFloat = 16

    private var sorted: [Piece] {
        pieces.sorted { value($0.kind) > value($1.kind) }
    }

    private func value(_ kind: PieceKind) -> Int {
        switch kind {
        case .queen: return 9
        case .rook: return 5
        case .bishop: return 3
        case .knight: return 3
        case .pawn: return 1
        case .king: return 0
        }
    }

    var body: some View {
        CapturedPiecesLayout(hasCount: advantage > 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, piece in
                PieceView(piece: piece, shadow: false)
                    .scaledFrame(16, relativeTo: .caption2)
            }
            if advantage > 0 {
                Text(verbatim: "+\(advantage)")
                    .scaledFont(11, relativeTo: .caption2, weight: .bold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(height: rowHeight)
        .animation(.spring(duration: 0.3), value: pieces.count)
        .accessibilityHidden(true)
    }
}

/// The captured pieces side by side, each overlapping the one before, then
/// the material count. Where the row would not fit otherwise the pieces close
/// up further: they grow with the text setting, and at the largest sizes some
/// eight of them pushed the player card — clock and all — past the edge of
/// the screen.
private struct CapturedPiecesLayout: Layout {
    /// Whether the last subview is the material count rather than a piece.
    var hasCount: Bool
    /// How much of a piece the next one covers, when there is room.
    var overlap: CGFloat = 5
    /// Between the last piece and the count.
    var gap: CGFloat = 4

    private struct Measure {
        var piece: CGSize
        var pieces: Int
        var count: CGSize?
    }

    private func measure(_ subviews: Subviews) -> Measure {
        let pieces = subviews.count - (hasCount ? 1 : 0)
        return Measure(
            piece: pieces > 0 ? subviews[0].sizeThatFits(.unspecified) : .zero,
            pieces: pieces,
            count: hasCount ? subviews[subviews.count - 1].sizeThatFits(.unspecified) : nil
        )
    }

    private func countWidth(_ measure: Measure) -> CGFloat {
        measure.count.map { $0.width + (measure.pieces > 0 ? gap : 0) } ?? 0
    }

    /// How far each piece steps on from the one before in a row `width` wide
    /// at most — never less than a quarter of a piece, so every one still
    /// shows.
    private func step(_ measure: Measure, within width: CGFloat?) -> CGFloat {
        let natural = measure.piece.width - overlap
        guard let width, measure.pieces > 1 else { return natural }
        let room = width - measure.piece.width - countWidth(measure)
        return max(measure.piece.width / 4, min(natural, room / CGFloat(measure.pieces - 1)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measure = measure(subviews)
        let step = step(measure, within: proposal.width)
        let pieces = measure.pieces > 0 ? measure.piece.width + step * CGFloat(measure.pieces - 1) : 0
        return CGSize(
            width: pieces + countWidth(measure),
            height: max(measure.piece.height, measure.count?.height ?? 0)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measure = measure(subviews)
        let step = step(measure, within: bounds.width)
        var x = bounds.minX
        for index in 0..<measure.pieces {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                                  proposal: ProposedViewSize(measure.piece))
            x += step
        }
        if let count = measure.count {
            let start = measure.pieces > 0 ? x - step + measure.piece.width + gap : x
            subviews[subviews.count - 1].place(at: CGPoint(x: start, y: bounds.midY), anchor: .leading,
                                               proposal: ProposedViewSize(count))
        }
    }
}

// MARK: - Three-check

/// Three marks, one lit for every check the player has given.
struct CheckCounter: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: index < count ? "plus.circle.fill" : "plus.circle")
                    .scaledFont(10, relativeTo: .caption2, weight: .bold)
                    .foregroundStyle(index < count ? MoveQuality.blunder.tint : .white.opacity(0.3))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Move history

struct MoveHistoryStrip: View {
    let history: [PlayedMove]
    let accent: Color

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, played in
                        HStack(spacing: 3) {
                            // A game set up with Black to move opens on "1…",
                            // as the analysis board's strip already wrote it.
                            if played.color == .white || index == 0 {
                                Text(verbatim: played.color == .white ? "\(played.moveNumber)." : "\(played.moveNumber)…")
                                    .scaledFont(12, relativeTo: .caption, weight: .medium, design: .rounded)
                                    .foregroundStyle(.tertiaryText)
                            }
                            Text(verbatim: MoveNotation.display(played.san))
                                .scaledFont(13, relativeTo: .footnote, weight: index == history.count - 1 ? .bold : .medium, design: .monospaced)
                                .foregroundStyle(index == history.count - 1 ? accent : .white.opacity(0.85))
                        }
                        .id(index)
                        // In words, not the two texts combined: notation is
                        // read a letter at a time, "J x e 5 plus" in Czech.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(BoardSpeech.numberedMove(played))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            // A floor, not a fixed height. A horizontal scroller takes its
            // height from its content, so at larger text sizes the moves grew
            // past a fixed 32 pt while the card behind them stayed put.
            .frame(minHeight: 32)
            .hudCard(cornerRadius: 10)
            .onChange(of: history.count) {
                withAnimation(.easeOut(duration: 0.25)) {
                    reader.scrollTo(history.count - 1, anchor: .trailing)
                }
            }
            // The way `ReviewMoveStrip` does it. A game continued from the
            // menu, or redrawn in the other layout after a turn of the device,
            // arrives with its moves already played, and the strip used to
            // open on move 1 with the latest of them out of sight.
            .onAppear {
                reader.scrollTo(history.count - 1, anchor: .trailing)
            }
        }
        .opacity(history.isEmpty ? 0.4 : 1)
    }
}

// MARK: - Display texts

extension AIDifficulty {
    var displayName: String {
        switch self {
        case .beginner: return String(localized: "Beginner", comment: "Difficulty level")
        case .easy: return String(localized: "Easy", comment: "Difficulty level")
        case .medium: return String(localized: "Medium", comment: "Difficulty level")
        case .hard: return String(localized: "Hard", comment: "Difficulty level")
        case .expert: return String(localized: "Grandmaster", comment: "Difficulty level")
        case .adaptive: return String(localized: "Adaptive", comment: "Difficulty level that adjusts to the player")
        }
    }

    var blurb: String {
        switch self {
        case .beginner: return String(localized: "First steps at the board")
        case .easy: return String(localized: "Makes a mistake now and then")
        case .medium: return String(localized: "A balanced opponent")
        case .hard: return String(localized: "A tough nut to crack")
        case .expert: return String(localized: "A merciless machine")
        case .adaptive: return String(localized: "Grows stronger as you do")
        }
    }
}

extension GameOutcome {
    func headline(mode: GameMode) -> String {
        switch self {
        case .ongoing:
            return ""
        case .checkmate(let winner):
            if case .vsAI(_, let playerColor) = mode {
                return winner == playerColor
                    ? String(localized: "You win by checkmate!")
                    : String(localized: "Checkmate — you lost")
            }
            return winner == .white
                ? String(localized: "Checkmate! White wins")
                : String(localized: "Checkmate! Black wins")
        case .stalemate:
            return String(localized: "Stalemate — draw")
        case .drawFiftyMoveRule:
            return String(localized: "Draw — fifty-move rule")
        case .drawThreefoldRepetition:
            return String(localized: "Draw — threefold repetition")
        case .drawInsufficientMaterial:
            return String(localized: "Draw — insufficient material")
        case .drawAgreed:
            return String(localized: "Draw by agreement")
        case .resigned(let winner):
            // Only the human ever resigns: the computer plays every position
            // out, however lost, so there is no "Computer resigned" to say.
            if case .vsAI = mode {
                return String(localized: "You resigned")
            }
            return winner == .white
                ? String(localized: "Black resigned")
                : String(localized: "White resigned")
        case .timeForfeit(let winner):
            if case .vsAI(_, let playerColor) = mode {
                return winner == playerColor
                    ? String(localized: "You win on time!")
                    : String(localized: "You lost on time")
            }
            return winner == .white
                ? String(localized: "White wins on time")
                : String(localized: "Black wins on time")
        case .drawTimeoutInsufficientMaterial:
            return String(localized: "Draw — time out, no mating material")
        case .kingOfTheHill(let winner):
            if case .vsAI(_, let playerColor) = mode {
                return winner == playerColor
                    ? String(localized: "You win — your king took the hill!")
                    : String(localized: "The computer's king took the hill")
            }
            return winner == .white
                ? String(localized: "White's king took the hill")
                : String(localized: "Black's king took the hill")
        case .threeChecks(let winner):
            if case .vsAI(_, let playerColor) = mode {
                return winner == playerColor
                    ? String(localized: "Third check — you win!")
                    : String(localized: "Third check — you lost")
            }
            return winner == .white
                ? String(localized: "Third check! White wins")
                : String(localized: "Third check! Black wins")
        }
    }
}
