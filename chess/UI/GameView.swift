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
    let onNewGame: (GameMode) -> Void
    let onReview: () -> Void

    /// A way of ending the game that is waiting to be confirmed. One piece of
    /// state and one dialog rather than a flag apiece: two
    /// `confirmationDialog`s on the same view are not reliably both presented.
    private enum EndingRequest: Equatable {
        case resign
        case draw
    }

    @State private var endingRequest: EndingRequest?
    @State private var showSettings = false

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

            if model.gameOverShown {
                GameOverOverlay(
                    model: model,
                    theme: settings.theme,
                    onReview: onReview,
                    onRematch: rematch,
                    onNewGame: { onNewGame(model.mode) },
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
        // lands — theirs or the computer's — is spoken.
        .onChange(of: model.game.history.count) { previous, current in
            // Only a move that was *added* is spoken as a move. After Undo the
            // last entry is the move before it, and reading that out would
            // announce a move nobody has just played.
            if current > previous, let played = model.game.history.last {
                AccessibilityNotification.Announcement(
                    BoardSpeech.announcement(
                        for: played, outcome: model.game.outcome, mode: model.mode
                    )
                ).post()
            } else if current < previous {
                AccessibilityNotification.Announcement(
                    String(localized: "Move taken back", comment: "Spoken by VoiceOver after Undo")
                ).post()
            }
        }
        .confirmationDialog(
            endingPrompt,
            isPresented: Binding(
                get: { endingRequest != nil },
                set: { if !$0 { endingRequest = nil } }
            ),
            titleVisibility: .visible,
            // `presenting:` rather than reading the state inside the builder:
            // the dialog then holds on to the request it was opened with, so
            // clearing the state to dismiss cannot swap the buttons underneath
            // the tap that is dismissing it.
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
    }

    /// Phones, and iPads held upright: one column.
    private var tallLayout: some View {
        VStack(spacing: 10) {
            topBar
            Spacer(minLength: 2)
            playerCard(for: model.orientation.opponent)
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

    private func rematch() {
        switch model.mode {
        case .twoPlayer:
            onNewGame(.twoPlayer)
        case .vsAI(let difficulty, let playerColor):
            onNewGame(.vsAI(difficulty: difficulty, playerColor: playerColor.opponent))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        // Both ends are held to the same width so the title stays centred even
        // though the right side carries two buttons and the left one. The lane
        // tracks the buttons as they scale, or the title runs under them.
        let sideWidth = min(rawCircleSide, Design.circleButtonMaxSide) * 2 + 8

        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                CircleButton(systemName: "chevron.left", label: "Back to menu") { onExit() }
            }
            .frame(width: sideWidth, alignment: .leading)

            VStack(spacing: 1) {
                Text(modeTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(statusLine)
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.opacity)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
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

    private var statusLine: String {
        if model.game.outcome.isGameOver {
            return model.game.outcome.headline(mode: model.mode)
        }
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
                CapturedPiecesRow(pieces: captured, advantage: advantage)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .hudCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(settings.theme.accent.opacity(isOnTurn ? 0.55 : 0), lineWidth: 1.5)
        )
        .animation(.spring(duration: 0.3), value: isOnTurn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playerName(for: color))
        .accessibilityValue(playerCardSpeech(color: color, isOnTurn: isOnTurn,
                                             captured: captured, advantage: advantage))
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
            ControlButton(systemName: "arrow.uturn.backward", label: "Undo", disabled: !model.canUndo) {
                withAnimation(Motion.meaningful(.spring(duration: 0.35))) { model.undo() }
            }
            // The middle slot holds whatever the mode has to offer. Hint is
            // only ever answerable against the computer, so in a two-player
            // game it used to sit there greyed out for the whole game — a
            // third of the row that could never do anything. That is where the
            // draw the two players may settle on now lives instead: the guide
            // has always listed agreement among the five ways a game is drawn,
            // and until now it was the one the app had no way to reach.
            if model.mode.isVsAI {
                ControlButton(
                    systemName: "lightbulb",
                    label: "Hint",
                    disabled: !model.canRequestHint,
                    loading: model.hintThinking
                ) {
                    model.requestHint()
                }
            } else {
                ControlButton(systemName: "equal.circle", label: "Draw", disabled: !model.canAgreeToDraw) {
                    endingRequest = .draw
                }
            }
            ControlButton(systemName: "flag", label: "Resign", disabled: model.game.outcome.isGameOver) {
                endingRequest = .resign
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: Promotion

    /// The picker lays four pieces out in a row, and at the design's size that
    /// row is wider than the narrowest phone the app runs on: 4 x (62 + 2 x 8)
    /// tile, three 10 pt gaps and the card's own 22 pt inset come to 386 pt
    /// against the 375 pt of an iPhone SE or a mini, which pushed the card's
    /// rounded corners and its border off both edges of the screen. So the
    /// tile is measured against the width actually on offer and only shrinks
    /// where it has to — on every wider phone it is the 62 pt it always was.
    private enum PromotionMetrics {
        static let tile: CGFloat = 62
        static let tilePadding: CGFloat = 8
        static let spacing: CGFloat = 10
        static let cardPadding: CGFloat = 22
        /// Margin the card keeps to the edges of the screen. It is what the
        /// design already had on the phone it was drawn against, so on every
        /// screen wide enough the arithmetic below returns the full 62 pt and
        /// nothing about the picker changes.
        static let screenInset: CGFloat = 8

        /// Side of one piece for a picker `width` points wide.
        static func tileSide(forWidth width: CGFloat) -> CGFloat {
            let chrome = 2 * screenInset + 2 * cardPadding + 3 * spacing + 8 * tilePadding
            return max(36, min(tile, (width - chrome) / 4))
        }
    }

    private var promotionOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { model.cancelPromotion() }

            if let pending = model.pendingPromotion {
                GeometryReader { proxy in
                    promotionCard(pending, tile: PromotionMetrics.tileSide(forWidth: proxy.size.width))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    private func promotionCard(
        _ pending: GameViewModel.PendingPromotion, tile: CGFloat
    ) -> some View {
        VStack(spacing: 14) {
            Text("Pawn Promotion")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: PromotionMetrics.spacing) {
                ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                    Button {
                        model.completePromotion(with: kind)
                    } label: {
                        PieceView(piece: Piece(pending.color, kind))
                            .frame(width: tile, height: tile)
                            .accessibilityHidden(true)
                            .padding(PromotionMetrics.tilePadding)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Piece(pending.color, kind).spokenName)
                }
            }
        }
        .padding(PromotionMetrics.cardPadding)
        // VoiceOver treats the card as the only thing on screen while it is
        // up: without this, focus could wander to Undo or Resign underneath
        // and act on a game that is waiting for an answer here. The escape
        // gesture stands in for the tap on the dimmed board.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { model.cancelPromotion() }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(settings.theme.backgroundBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        )
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

// MARK: - Small components

struct CircleButton: View {
    let systemName: String
    /// Icon-only buttons say nothing on their own, so every one names itself.
    let label: LocalizedStringKey
    let action: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var rawSide: CGFloat = Design.circleButtonSide
    @ScaledMetric(relativeTo: .subheadline) private var rawGlyph: CGFloat = Design.circleButtonGlyph
    private var side: CGFloat { min(rawSide, Design.circleButtonMaxSide) }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: min(rawGlyph, Design.circleButtonMaxGlyph), weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: side, height: side)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        HStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, piece in
                PieceView(piece: piece, shadow: false)
                    .scaledFrame(16, relativeTo: .caption2)
                    .padding(.trailing, -5)
            }
            if advantage > 0 {
                Text(verbatim: "+\(advantage)")
                    .scaledFont(11, relativeTo: .caption2, weight: .bold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.leading, 9)
            }
        }
        .frame(height: 16)
        .animation(.spring(duration: 0.3), value: pieces.count)
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
                            if played.color == .white {
                                Text(verbatim: "\(played.moveNumber).")
                                    .scaledFont(12, relativeTo: .caption, weight: .medium, design: .rounded)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Text(verbatim: MoveNotation.display(played.san))
                                .scaledFont(13, relativeTo: .footnote, weight: index == history.count - 1 ? .bold : .medium, design: .monospaced)
                                .foregroundStyle(index == history.count - 1 ? accent : .white.opacity(0.85))
                        }
                        .id(index)
                        .accessibilityElement(children: .combine)
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
        }
    }

    var blurb: String {
        switch self {
        case .beginner: return String(localized: "First steps at the board")
        case .easy: return String(localized: "Makes a mistake now and then")
        case .medium: return String(localized: "A balanced opponent")
        case .hard: return String(localized: "A tough nut to crack")
        case .expert: return String(localized: "A merciless machine")
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
        }
    }
}
