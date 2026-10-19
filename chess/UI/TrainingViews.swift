//
//  TrainingViews.swift
//  chess
//
//  The training screens: the hub, the opening trainer, the analysis board,
//  the position editor and the sheet a PGN or FEN is pasted into.
//

import SwiftUI

// MARK: - Hub

struct TrainingHubView: View {
    @Environment(AppSettings.self) private var settings
    let onClose: () -> Void
    let onPlay: (GameMode, GameOptions) -> Void

    private enum Route: Identifiable {
        case openings
        case analysis(AnalysisBoardModel)
        case editor(String)

        var id: String {
            switch self {
            case .openings: return "openings"
            case .analysis(let model): return "analysis-\(ObjectIdentifier(model).hashValue)"
            case .editor(let fen): return "editor-\(fen)"
            }
        }
    }

    @State private var route: Route?
    @State private var showPaste = false

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            VStack(spacing: 10) {
                ScreenTopBar(title: String(localized: "Training"), backLabel: "Back to menu", onBack: onClose)
                    .padding(.horizontal, 12)
                ScrollView {
                    VStack(spacing: 12) {
                        hubCard(
                            title: "Opening Trainer",
                            subtitle: String(localized: "\(OpeningProgressStore.shared.progress.learnedCount) of \(TrainingLine.all.count) lines learned"),
                            systemName: "book.fill"
                        ) { route = .openings }
                        hubCard(
                            title: "Analysis Board",
                            subtitle: String(localized: "Play any moves and see what the engine thinks"),
                            systemName: "magnifyingglass"
                        ) { route = .analysis(AnalysisBoardModel(game: Game())) }
                        hubCard(
                            title: "Set Up a Position",
                            subtitle: String(localized: "Place the pieces, then analyse or play it"),
                            systemName: "square.and.pencil"
                        ) { route = .editor(Board.startFEN) }
                        hubCard(
                            title: "Paste PGN or FEN",
                            subtitle: String(localized: "Open a game or a position from elsewhere"),
                            systemName: "doc.on.clipboard"
                        ) { showPaste = true }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .fullScreenCover(item: $route) { route in
            Group {
                switch route {
                case .openings:
                    OpeningListView(onClose: { self.route = nil })
                case .analysis(let model):
                    AnalysisView(model: model, onClose: { self.route = nil }, onPlay: play)
                case .editor(let fen):
                    PositionEditorView(
                        initialFEN: fen,
                        onClose: { self.route = nil },
                        onAnalyze: { fen, orientation in
                            self.route = nil
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                self.route = .analysis(AnalysisBoardModel(fen: fen, orientation: orientation))
                            }
                        },
                        onPlay: play
                    )
                }
            }
            .environment(settings)
        }
        .sheet(isPresented: $showPaste) {
            PasteGameSheet { game in
                showPaste = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    route = .analysis(AnalysisBoardModel(game: game))
                }
            }
            .environment(settings)
        }
#if DEBUG
        .onAppear {
            let arguments = LaunchArguments.once(for: "training")
            if arguments.contains("--training-analysis") { route = .analysis(AnalysisBoardModel(game: Game())) }
            if arguments.contains("--training-editor") { route = .editor(Board.startFEN) }
            if arguments.contains("--training-openings") { route = .openings }
        }
#endif
    }

    private func play(_ mode: GameMode, _ options: GameOptions) {
        route = nil
        onPlay(mode, options)
    }

    private func hubCard(
        title: LocalizedStringKey, subtitle: String, systemName: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .scaledFont(19, relativeTo: .title3, weight: .semibold)
                    .foregroundStyle(Design.gold)
                    .scaledFrame(40, relativeTo: .title3)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .bold)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .setupCard(selected: false, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Opening list

struct OpeningListView: View {
    @Environment(AppSettings.self) private var settings
    let onClose: () -> Void

    private struct Session: Identifiable {
        let line: TrainingLine
        let color: PieceColor
        var id: String { line.id + "\(color)" }
    }

    @State private var session: Session?

    private var families: [(String, [TrainingLine])] {
        let grouped = Dictionary(grouping: TrainingLine.all, by: \.family)
        let order = ["1.e4", "1.d4"]
        return grouped.sorted { a, b in
            (order.firstIndex(of: a.key) ?? 9) < (order.firstIndex(of: b.key) ?? 9)
        }
        // In the reader's alphabet: compared code point by code point, Czech
        // put "Španělská hra" and "Čigorinova obrana" after Z.
        .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        let progress = OpeningProgressStore.shared.progress
        ZStack {
            ScreenBackground(theme: settings.theme)
            VStack(spacing: 10) {
                ScreenTopBar(
                    title: String(localized: "Opening Trainer"),
                    subtitle: String(localized: "\(progress.learnedCount) of \(TrainingLine.all.count) lines learned"),
                    backLabel: "Back to training", onBack: onClose
                )
                .padding(.horizontal, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("The computer plays its side of the line; you play yours. A line is learned once you play it through without a slip, and mastered after three.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(families, id: \.0) { family, lines in
                            VStack(alignment: .leading, spacing: 8) {
                                // Not upper-cased: the groups are named by a
                                // first move, and "1.E4" is no move at all.
                                Text(verbatim: family)
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.tertiaryText)
                                    .kerning(1.2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(lines) { line in
                                    lineRow(line, progress: progress)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .fullScreenCover(item: $session) { session in
            OpeningTrainerView(line: session.line, color: session.color, onClose: { self.session = nil })
                .environment(settings)
        }
    }

    private func lineRow(_ line: TrainingLine, progress: OpeningProgress) -> some View {
        let mastered = progress.isMastered(line)
        let learned = progress.isLearned(line)
        return Button {
            session = Session(line: line, color: line.defaultColor)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mastered ? "star.fill" : (learned ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(mastered ? Design.gold : (learned ? MoveQuality.best.tint : .white.opacity(0.3)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: Self.movesText(line.sans))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                PieceView(piece: Piece(line.defaultColor, .pawn), shadow: false)
                    .scaledFrame(20, relativeTo: .caption)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .setupCard(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.name)
        .accessibilityValue(mastered
            ? String(localized: "mastered", comment: "Opening line state")
            : (learned ? String(localized: "learned", comment: "Opening line state") : ""))
        .accessibilityAddTraits(.isButton)
    }

    static func movesText(_ sans: [String]) -> String {
        sans.enumerated().map { index, san in
            index.isMultiple(of: 2) ? "\(index / 2 + 1).\(MoveNotation.display(san))" : MoveNotation.display(san)
        }.joined(separator: " ")
    }
}

// MARK: - Opening trainer

struct OpeningTrainerView: View {
    @Environment(AppSettings.self) private var settings
    let line: TrainingLine
    let color: PieceColor
    let onClose: () -> Void

    @State private var model: OpeningTrainerModel?

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            if let model {
                VStack(spacing: 12) {
                    ScreenTopBar(
                        title: line.name,
                        subtitle: String(localized: "You play \(model.playerColor.spokenName)", comment: "Opening trainer: the side the player takes"),
                        backLabel: "Back to openings"
                    ) {
                        model.teardown()
                        onClose()
                    }
                    Spacer(minLength: 4)
                    BoardView(model: model, theme: settings.theme,
                              showCoordinates: settings.showCoordinates, showLegalMoves: settings.showLegalMoves)
                        .padding(.horizontal, 6)
                    progressStrip(model)
                    statusCard(model)
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        ControlButton(systemName: "eye", label: "Show Move", width: nil,
                                      disabled: !(model.phase == .playerToMove || model.phase == .wrong)) {
                            model.showMove()
                        }
                        ControlButton(systemName: "arrow.counterclockwise", label: "Restart", width: nil) {
                            model.restart()
                        }
                        ControlButton(systemName: "arrow.left.arrow.right", label: "Other Side", width: nil) {
                            model.teardown()
                            self.model = OpeningTrainerModel(line: line, playerColor: model.playerColor.opponent)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: 640)
            }
        }
        .boardTypeLimit()
        .onAppear {
            if model == nil { model = OpeningTrainerModel(line: line, playerColor: color) }
        }
        .onDisappear { model?.teardown() }
    }

    private func progressStrip(_ model: OpeningTrainerModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(line.sans.enumerated()), id: \.offset) { index, san in
                    let played = index < model.ply
                    Text(verbatim: index.isMultiple(of: 2) ? "\(index / 2 + 1).\(MoveNotation.display(san))" : MoveNotation.display(san))
                        .scaledFont(13, relativeTo: .footnote, weight: played ? .bold : .medium, design: .monospaced)
                        .foregroundStyle(played ? .white : .white.opacity(0.2))
                        .redacted(reason: played ? [] : .placeholder)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(minHeight: 32)
        .hudCard(cornerRadius: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Moves of the line"))
        .accessibilityValue(Text("\(model.ply) of \(line.sans.count)", comment: "Opening trainer progress"))
    }

    private func statusCard(_ model: OpeningTrainerModel) -> some View {
        let text: String
        let icon: String
        let tint: Color
        switch model.phase {
        case .opponentToMove:
            text = String(localized: "The computer plays its move…")
            icon = "hourglass"; tint = settings.theme.accent
        case .playerToMove:
            text = String(localized: "Your move — play the book line.")
            icon = "book.fill"; tint = settings.theme.accent
        case .wrong:
            text = String(localized: "That is not the book move. Try again.")
            icon = "xmark.circle.fill"; tint = MoveQuality.blunder.tint
        case .complete:
            text = model.mistakes == 0
                ? String(localized: "Line complete — no mistakes!")
                : String(localized: "Line complete. Play it once more without a slip to learn it.")
            icon = "checkmark.circle.fill"; tint = MoveQuality.best.tint
        }
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .hudCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Analysis

struct AnalysisView: View {
    @Environment(AppSettings.self) private var settings
    let model: AnalysisBoardModel
    let onClose: () -> Void
    var onPlay: ((GameMode, GameOptions) -> Void)?

    @State private var showEditor = false
    @State private var showPlaySheet = false
    @State private var copied = false

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            GeometryReader { proxy in
                let isWide = proxy.size.width > proxy.size.height * 1.15
                Group {
                    if isWide {
                        HStack(spacing: 18) {
                            board
                            VStack(spacing: 10) {
                                topBar
                                evalBar
                                engineLine
                                Spacer(minLength: 4)
                                moveStrip
                                controls
                            }
                            .frame(maxWidth: 400)
                        }
                        .frame(maxWidth: 1100)
                    } else {
                        VStack(spacing: 10) {
                            topBar
                            evalBar
                            board.padding(.horizontal, 6)
                            engineLine
                            Spacer(minLength: 2)
                            moveStrip
                            controls
                        }
                        .frame(maxWidth: 640)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            if model.hasPendingPromotion {
                PromotionPickerOverlay(
                    color: model.promotionColor, theme: settings.theme,
                    onPick: { model.completePromotion(with: $0) },
                    onCancel: { model.cancelPromotion() }
                )
            }
        }
        .boardTypeLimit()
        // The editor is a full-screen cover, and opening it ends this view's
        // appearance too: the engine stopped then has to start again on the
        // way back, whether or not the position changed.
        .onAppear { model.resumeEngine() }
        .onDisappear { model.teardown() }
        .fullScreenCover(isPresented: $showEditor) {
            PositionEditorView(
                initialFEN: model.game.board.fen,
                initialOrientation: model.orientation,
                variant: model.game.variant,
                onClose: { showEditor = false },
                onAnalyze: { fen, orientation in
                    showEditor = false
                    model.load(fen: fen)
                    model.orientation = orientation
                },
                // Offered only where there is somewhere to play it: the
                // analysis board opened from a review has no game to start.
                onPlay: onPlay.map { play -> (GameMode, GameOptions) -> Void in
                    { mode, options in
                        showEditor = false
                        play(mode, options)
                    }
                }
            )
            .environment(settings)
        }
        .sheet(isPresented: $showPlaySheet) {
            PlayFromPositionSheet(fen: model.game.board.fen, variant: model.game.variant) { mode, options in
                showPlaySheet = false
                onPlay?(mode, options)
            }
            .environment(settings)
            .presentationDetents([.medium, .large])
        }
    }

    private var board: some View {
        BoardView(model: model, theme: settings.theme,
                  showCoordinates: settings.showCoordinates, showLegalMoves: settings.showLegalMoves)
    }

    private var topBar: some View {
        ScreenTopBar(
            title: String(localized: "Analysis Board"),
            subtitle: model.game.outcome.isGameOver ? model.game.outcome.headline(mode: .twoPlayer) : nil,
            backLabel: "Close the analysis"
        ) {
            model.teardown()
            onClose()
        } trailing: {
            CircleButton(systemName: "arrow.trianglehead.2.clockwise.rotate.90", label: "Flip the board") {
                withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.2))) { model.orientation = model.orientation.opponent }
            }
        }
    }

    /// White's share of the bar, from the win expectancy of the evaluation.
    private var whiteShare: Double {
        guard let evaluation = model.evaluation else { return 0.5 }
        return WinChance.percent(centipawns: evaluation) / 100
    }

    private var evalBar: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.7))
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: max(6, proxy.size.width * whiteShare))
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.3), value: whiteShare)
            Text(verbatim: model.evaluation.map { EvalFormat.text(centipawns: $0) } ?? "…")
                .scaledFont(14, relativeTo: .subheadline, weight: .bold, design: .monospaced)
                .foregroundStyle(.white)
                .frame(minWidth: 52, alignment: .trailing)
            // A button rather than a switch: a switch's frame is 31 pt tall,
            // short of the 44 pt a target needs, and it is the one control in
            // the bar.
            Button {
                model.engineEnabled.toggle()
            } label: {
                Image(systemName: model.engineEnabled ? "cpu.fill" : "cpu")
                    .scaledFont(16, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(model.engineEnabled ? Design.gold : .white.opacity(0.5))
                    .frame(width: Design.minimumTouchTarget, height: Design.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Engine"))
            .accessibilityValue(model.engineEnabled
                ? String(localized: "on", comment: "State of a switch")
                : String(localized: "off", comment: "State of a switch"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hudCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Evaluation"))
        .accessibilityValue(model.evaluation.map { EvalFormat.spoken(centipawns: $0, variant: model.game.variant) } ?? "")
    }

    private var engineLine: some View {
        HStack(spacing: 8) {
            if model.engineEnabled, let san = model.bestSAN {
                // Decoration beside the words, and not inside a button that
                // would swallow it: left as it was, VoiceOver stopped on it
                // as an element of its own and read out the symbol's name.
                Image(systemName: "cpu").foregroundStyle(MoveQuality.best.tint)
                    .accessibilityHidden(true)
                Text("Best: \(MoveNotation.display(san))", comment: "The engine's preferred move")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    // The move in words: notation is read a letter at a time.
                    .accessibilityLabel(Text(
                        "Best: \(model.bestMove.map { BoardSpeech.spokenMove($0, san: san) } ?? san)",
                        comment: "The engine's preferred move"
                    ))
                Text("depth \(model.depth)", comment: "Search depth")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondaryText)
                Spacer()
                if model.isThinking {
                    ProgressView().tint(.white).scaleEffect(0.8)
                        // The depth beside it already says the search is on.
                        .accessibilityHidden(true)
                }
                Button {
                    model.playBestMove()
                } label: {
                    Text("Play It")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Design.gold)
                        .padding(.horizontal, 8)
                        .frame(minHeight: Design.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if model.engineEnabled {
                ProgressView().tint(.white).scaleEffect(0.8)
                    .accessibilityHidden(true)
                Text("The engine is thinking…")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                Text("The engine is off.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .hudCard()
    }

    private var moveStrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(model.line.enumerated()), id: \.offset) { index, played in
                        Button {
                            model.go(to: index + 1)
                        } label: {
                            HStack(spacing: 3) {
                                if played.color == .white || index == 0 {
                                    Text(verbatim: played.color == .white ? "\(played.moveNumber)." : "\(played.moveNumber)…")
                                        .scaledFont(12, relativeTo: .caption, weight: .medium, design: .rounded)
                                        .foregroundStyle(.tertiaryText)
                                }
                                Text(verbatim: MoveNotation.display(played.san))
                                    .scaledFont(13, relativeTo: .footnote,
                                                weight: index + 1 == model.plyIndex ? .bold : .medium, design: .monospaced)
                                    .foregroundStyle(index + 1 == model.plyIndex ? settings.theme.accent : .white.opacity(0.85))
                            }
                            // A move is a button here, and a 13 pt word is a
                            // small thing to hit. Padded out to the 44 pt
                            // Apple asks for, the way `ReviewMoveStrip` pads
                            // its chips; the ribbon still reads as one line.
                            .padding(.horizontal, 3)
                            .frame(minWidth: Design.minimumTouchTarget, minHeight: Design.minimumTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(BoardSpeech.numberedMove(played))
                        .accessibilityAddTraits(index + 1 == model.plyIndex ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            // A floor for the reason `ReviewMoveStrip` gives: a 44 pt chip
            // plus 3 pt a side, more once the text inside grows.
            .frame(minHeight: 50)
            .hudCard(cornerRadius: 10)
            .onChange(of: model.plyIndex) { _, ply in
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(max(0, ply - 1), anchor: .center) }
            }
            // Opened from a review, the board starts part way into the game.
            .onAppear { reader.scrollTo(max(0, model.plyIndex - 1), anchor: .center) }
        }
        .opacity(model.line.isEmpty ? 0.4 : 1)
        // Before the first move the strip is an empty scroller with nothing
        // to say or do.
        .accessibilityHidden(model.line.isEmpty)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ControlButton(systemName: "chevron.left", label: "Back", width: nil, disabled: !model.canStepBack) {
                model.stepBack()
            }
            ControlButton(systemName: "chevron.right", label: "Next", width: nil, disabled: !model.canStepForward) {
                model.stepForward()
            }
            ControlButton(systemName: "square.and.pencil", label: "Edit", width: nil) {
                showEditor = true
            }
            ControlButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "Copy FEN", width: nil) {
                UIPasteboard.general.string = model.game.board.fen
                copied = true
                Haptics.success()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            if onPlay != nil {
                ControlButton(systemName: "play.fill", label: "Play", width: nil,
                              disabled: !model.canPlayFromHere) {
                    showPlaySheet = true
                }
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Play from a position

struct PlayFromPositionSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let fen: String
    /// The rules the position was reached under: a King of the Hill position
    /// played on as ordinary chess is a different game.
    var variant: ChessVariant = .standard
    let onPlay: (GameMode, GameOptions) -> Void

    @State private var difficulty: AIDifficulty = .medium
    @State private var color: PieceColor = .white

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(theme: settings.theme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SetupSectionTitle("VS COMPUTER")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(AIDifficulty.fixedLevels) { level in
                                OptionChip(title: level.displayName, isSelected: difficulty == level) {
                                    difficulty = level
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            ForEach([PieceColor.white, .black], id: \.self) { side in
                                OptionChip(title: side.spokenName, isSelected: color == side) {
                                    PieceView(piece: Piece(side, .king), shadow: false)
                                        .scaledFrame(24, relativeTo: .subheadline)
                                } action: { color = side }
                            }
                        }
                        OverlayButton(title: "Play vs Computer", systemName: "desktopcomputer", prominent: true) {
                            onPlay(.vsAI(difficulty: difficulty, playerColor: color),
                                   GameOptions(start: .custom(fen: fen), variant: variant))
                        }
                        SetupSectionTitle("TWO PLAYERS")
                        OverlayButton(title: "Two Players", systemName: "person.2.fill") {
                            onPlay(.twoPlayer, GameOptions(start: .custom(fen: fen), variant: variant))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Play from Here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            color = Board(fen: fen)?.sideToMove ?? .white
        }
    }
}

// MARK: - Position editor

@Observable
@MainActor
final class PositionEditorModel {
    enum Tool: Hashable {
        case piece(Piece)
        case eraser
    }

    private(set) var squares: [Piece?]
    var sideToMove: PieceColor
    /// The rights the player has asked for; only those the position allows
    /// make it into the FEN.
    var requestedRights: CastlingRights
    var tool: Tool = .piece(Piece(.white, .pawn))
    var orientation: PieceColor = .white

    init(fen: String) {
        let board = Board(fen: fen) ?? .initial
        squares = (0..<64).map { board.piece(at: $0) }
        sideToMove = board.sideToMove
        requestedRights = board.castlingRights
    }

    func tap(_ square: Square) {
        switch tool {
        case .eraser:
            squares[square.index] = nil
        case .piece(let piece):
            // Tapping the same piece again takes it off, so a misplaced tap
            // is one tap to undo.
            squares[square.index] = squares[square.index] == piece ? nil : piece
        }
        Haptics.pieceSelected()
    }

    func clear() {
        squares = Array(repeating: nil, count: 64)
        squares[4] = Piece(.white, .king)
        squares[60] = Piece(.black, .king)
        requestedRights = []
    }

    func reset() {
        let board = Board.initial
        squares = (0..<64).map { board.piece(at: $0) }
        sideToMove = .white
        requestedRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]
    }

    func load(fen: String) -> Bool {
        guard let board = Board(fen: fen) else { return false }
        squares = (0..<64).map { board.piece(at: $0) }
        sideToMove = board.sideToMove
        requestedRights = board.castlingRights
        return true
    }

    /// Whether a castling right is possible at all: king and rook on their
    /// home squares.
    func isPossible(_ right: CastlingRights) -> Bool {
        let (king, rook, color): (Int, Int, PieceColor)
        switch right {
        case .whiteKingside: (king, rook, color) = (4, 7, .white)
        case .whiteQueenside: (king, rook, color) = (4, 0, .white)
        case .blackKingside: (king, rook, color) = (60, 63, .black)
        default: (king, rook, color) = (60, 56, .black)
        }
        return squares[king] == Piece(color, .king) && squares[rook] == Piece(color, .rook)
    }

    var fen: String {
        var placement = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                if let piece = squares[rank * 8 + file] {
                    if empty > 0 { placement += String(empty); empty = 0 }
                    placement.append(piece.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { placement += String(empty) }
            if rank > 0 { placement += "/" }
        }
        var rights = CastlingRights()
        for right in [CastlingRights.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]
        where requestedRights.contains(right) && isPossible(right) {
            rights.insert(right)
        }
        return "\(placement) \(sideToMove == .white ? "w" : "b") \(rights.fenString) - 0 1"
    }

    /// Why the position cannot be played, or nil when it can.
    var problem: String? {
        let kings = PieceColor.allCases.map { color in squares.count { $0 == Piece(color, .king) } }
        if kings != [1, 1] {
            return String(localized: "Each side needs exactly one king.")
        }
        let backRanks = Array(0..<8) + Array(56..<64)
        if backRanks.contains(where: { squares[$0]?.kind == .pawn }) {
            return String(localized: "Pawns cannot stand on the first or last rank.")
        }
        guard let board = Board(fen: fen) else {
            return String(localized: "The side that is not to move is in check.")
        }
        if board.generateLegalMoves().isEmpty {
            return board.isInCheck
                ? String(localized: "The side to move is already checkmated.")
                : String(localized: "The side to move is stalemated.")
        }
        return nil
    }

    /// Why the position cannot be analysed under `variant`, or nil when it
    /// can: `problem`, or a position those rules cannot reach. King of the
    /// Hill with the side to move already on the hill is one — it would have
    /// won the move before — and `Board(fen:variant:)` refuses it, so the
    /// analysis board, taking it, quietly started from the opening position.
    func analysisProblem(variant: ChessVariant) -> String? {
        if let problem { return problem }
        guard Board(fen: fen, variant: variant) == nil else { return nil }
        return String(localized: "The side to move already has its king on the hill.")
    }

    /// Why a game cannot be started from the position under `variant`, or
    /// nil when it can. A legal position can still be one the rules call
    /// finished before anybody moves — two bare kings, a knight against a
    /// king, a king already on the hill — and a game begun from it opened on
    /// a frozen board with no result to show and nothing to do but leave.
    /// It can still be analysed; it is only playing it that makes no sense.
    func playProblem(variant: ChessVariant) -> String? {
        if let problem = analysisProblem(variant: variant) { return problem }
        switch Game(fen: fen, variant: variant).outcome {
        case .ongoing:
            return nil
        case .drawInsufficientMaterial:
            return String(localized: "Neither side has enough material left to mate.")
        case .kingOfTheHill:
            return String(localized: "A king already stands on the hill.")
        default:
            return String(localized: "The game would be over before the first move.")
        }
    }
}

struct PositionEditorView: View {
    @Environment(AppSettings.self) private var settings
    let initialFEN: String
    /// The side at the bottom when the editor opens: the analysis board's,
    /// when it is opened from there. Analyze hands back the side it ends on.
    var initialOrientation: PieceColor = .white
    /// The rules of the analysis board the editor was opened from, which a
    /// game played from the edited position keeps.
    var variant: ChessVariant = .standard
    let onClose: () -> Void
    let onAnalyze: (String, PieceColor) -> Void
    /// Nil hides Play.
    let onPlay: ((GameMode, GameOptions) -> Void)?

    @State private var model: PositionEditorModel?
    @State private var showPlaySheet = false
    @State private var fenText = ""
    /// The text that last failed to load. The error under the field speaks
    /// of that text only: editing the board writes a new FEN into the field,
    /// and an error that stayed under it called a perfectly good position
    /// illegal.
    @State private var rejectedFEN: String?
    @FocusState private var fenFocused: Bool

    private var fenError: Bool { rejectedFEN != nil && rejectedFEN == fenText }

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            if let model {
                ScrollView {
                    VStack(spacing: 12) {
                        ScreenTopBar(title: String(localized: "Set Up a Position"), backLabel: "Close the editor", onBack: onClose) {
                            CircleButton(systemName: "arrow.trianglehead.2.clockwise.rotate.90", label: "Flip the board") {
                                model.orientation = model.orientation.opponent
                            }
                        }
                        EditorBoard(model: model, theme: settings.theme)
                            .frame(maxWidth: 520)
                        palette(model)
                        options(model)
                        // Asked once per redraw: both go through move
                        // generation, and the label and the buttons need them.
                        let analysisProblem = model.analysisProblem(variant: variant)
                        let playProblem = onPlay == nil ? analysisProblem : model.playProblem(variant: variant)
                        if let problem = playProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(MoveQuality.mistake.tint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 10) {
                            OverlayButton(title: "Analyze", systemName: "magnifyingglass", prominent: analysisProblem == nil) {
                                onAnalyze(model.fen, model.orientation)
                            }
                            .disabled(analysisProblem != nil)
                            if onPlay != nil {
                                OverlayButton(title: "Play", systemName: "play.fill") {
                                    showPlaySheet = true
                                }
                                .disabled(playProblem != nil)
                            }
                        }
                        fenField(model)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .boardTypeLimit()
        .onAppear {
            if model == nil {
                let created = PositionEditorModel(fen: initialFEN)
                created.orientation = initialOrientation
                model = created
                fenText = created.fen
            }
        }
        .sheet(isPresented: $showPlaySheet) {
            if let model {
                PlayFromPositionSheet(fen: model.fen, variant: variant) { mode, options in
                    showPlaySheet = false
                    onPlay?(mode, options)
                }
                .environment(settings)
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func palette(_ model: PositionEditorModel) -> some View {
        VStack(spacing: 6) {
            ForEach([PieceColor.white, .black], id: \.self) { color in
                HStack(spacing: 6) {
                    ForEach([PieceKind.king, .queen, .rook, .bishop, .knight, .pawn], id: \.self) { kind in
                        let piece = Piece(color, kind)
                        let selected = model.tool == .piece(piece)
                        Button {
                            model.tool = .piece(piece)
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(PieceView(piece: piece, shadow: false).padding(4))
                                .setupCard(selected: selected, cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(piece.spokenName)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    if color == .white {
                        Button {
                            model.tool = .eraser
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    Image(systemName: "eraser.fill")
                                        .foregroundStyle(model.tool == .eraser ? Design.gold : .white.opacity(0.7))
                                )
                                .setupCard(selected: model.tool == .eraser, cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Eraser"))
                        .accessibilityAddTraits(model.tool == .eraser ? .isSelected : [])
                    } else {
                        Button {
                            model.clear()
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Image(systemName: "trash").foregroundStyle(.white.opacity(0.7)))
                                .setupCard(selected: false, cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear the board"))
                    }
                }
            }
        }
    }

    private func options(_ model: PositionEditorModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach([PieceColor.white, .black], id: \.self) { side in
                    OptionChip(title: side == .white
                               ? String(localized: "White to move")
                               : String(localized: "Black to move"),
                               isSelected: model.sideToMove == side) {
                        model.sideToMove = side
                    }
                }
                OptionChip(title: String(localized: "Starting position"), isSelected: false) {
                    model.reset()
                }
            }
            HStack(spacing: 8) {
                Text("Castling")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(CastleToggle.all, id: \.right.rawValue) { toggle in
                    let label = toggle.label, right = toggle.right, color = toggle.color
                    let possible = model.isPossible(right)
                    let on = model.requestedRights.contains(right) && possible
                    Button {
                        if model.requestedRights.contains(right) {
                            model.requestedRights.remove(right)
                        } else {
                            model.requestedRights.insert(right)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            PieceView(piece: Piece(color, .king), shadow: false).frame(width: 14, height: 14)
                            Text(verbatim: label)
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                        }
                        .foregroundStyle(on ? Design.gold : .white.opacity(possible ? 0.7 : 0.25))
                        .padding(.horizontal, 6)
                        .frame(minHeight: Design.minimumTouchTarget)
                        .setupCard(selected: on, cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!possible)
                    .accessibilityLabel(toggle.spokenName)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func fenField(_ model: PositionEditorModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SetupSectionTitle("FEN")
            HStack {
                TextField("FEN", text: $fenText, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($fenFocused)
                    .onSubmit { loadFEN(into: model) }
                Button {
                    loadFEN(into: model)
                } label: {
                    Text("Load")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Design.gold)
                        .padding(.horizontal, 8)
                        .frame(minHeight: Design.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .setupCard(selected: false)
            if fenError {
                Text(Self.fenErrorMessage)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(MoveQuality.mistake.tint)
            }
        }
        .onChange(of: model.fen) { _, fen in fenText = fen }
        // A field that wraps takes Return as a new line rather than as the
        // Done it is labelled, and `onSubmit` never came: the key added a line
        // break and left the keyboard up. The line break is the key press, so
        // it is read as one — and a FEN pasted with one at its end loads.
        .onChange(of: fenText) { _, text in
            guard text.contains(where: \.isNewline) else { return }
            fenFocused = false
            loadFEN(into: model)
        }
    }

    private static let fenErrorMessage = String(localized: "That FEN does not describe a legal position.")

    /// A FEN turned away is said as well as shown: the line under the field
    /// came up without a word, and with the keyboard gone a VoiceOver user
    /// heard nothing happen at all.
    private func loadFEN(into model: PositionEditorModel) {
        let fen = fenText.filter { !$0.isNewline }
        if fen != fenText { fenText = fen }
        rejectedFEN = model.load(fen: fen) ? nil : fen
        if rejectedFEN != nil { AccessibilityNotification.Announcement(Self.fenErrorMessage).post() }
    }
}

private struct CastleToggle {
    let label: String
    let right: CastlingRights
    let color: PieceColor

    /// The right in words. "O-O" is notation for the eye; read out as it
    /// stands, "White O-O" — "Bílý O-O" — tells a listener very little.
    var spokenName: String {
        switch right {
        case .whiteKingside:
            return String(localized: "White kingside castling", comment: "VoiceOver: castling right toggle in the position editor")
        case .whiteQueenside:
            return String(localized: "White queenside castling", comment: "VoiceOver: castling right toggle in the position editor")
        case .blackKingside:
            return String(localized: "Black kingside castling", comment: "VoiceOver: castling right toggle in the position editor")
        default:
            // `.blackQueenside`: an option set cannot be switched over
            // exhaustively, so the last of the four is the default.
            return String(localized: "Black queenside castling", comment: "VoiceOver: castling right toggle in the position editor")
        }
    }

    static let all = [
        CastleToggle(label: "O-O", right: .whiteKingside, color: .white),
        CastleToggle(label: "O-O-O", right: .whiteQueenside, color: .white),
        CastleToggle(label: "O-O", right: .blackKingside, color: .black),
        CastleToggle(label: "O-O-O", right: .blackQueenside, color: .black),
    ]
}

/// The editor's board: a plain board where a tap places the chosen piece.
private struct EditorBoard: View {
    let model: PositionEditorModel
    let theme: BoardTheme

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(size: side, orientation: model.orientation)
            ZStack(alignment: .topLeading) {
                BoardBackdrop(geometry: geometry, theme: theme, showCoordinates: true)
                ForEach(Square.all, id: \.index) { square in
                    if let piece = model.squares[square.index] {
                        PieceView(piece: piece)
                            .frame(width: geometry.squareSize, height: geometry.squareSize)
                            .position(geometry.center(of: square))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(Square.all, id: \.index) { square in
                    Color.clear
                        .frame(width: geometry.squareSize, height: geometry.squareSize)
                        .position(geometry.center(of: square))
                        .accessibilityElement()
                        .accessibilityLabel(BoardSpeech.label(square: square, piece: model.squares[square.index]))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.tap(square) }
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let square = geometry.square(at: location) { model.tap(square) }
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Position editor board"))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Paste

struct PasteGameSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Game) -> Void

    @State private var text = ""
    /// Why the text could not be opened, once the player has been told: it
    /// is neither a game nor a position, or a game that cannot be set up, or
    /// one not a single move of which reads.
    @State private var failure: String?
    /// The move reading stopped at, once the player has been told about it.
    @State private var stoppedAt: String?
    /// How many games of the text could not be read at all, once the player
    /// has been told about them.
    @State private var skippedGames = 0
    /// The text is being read, away from the main thread: every game in it
    /// is replayed, and a long file pasted in held the sheet up while it was.
    @State private var isReading = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(theme: settings.theme)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste a game in PGN, or a single position in FEN.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .setupCard(selected: false)
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // What was said about the old text says nothing about
                        // the new one.
                        .onChange(of: text) {
                            failure = nil
                            stoppedAt = nil
                            skippedGames = 0
                        }
                    if let failure {
                        Text(failure)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(MoveQuality.mistake.tint)
                    }
                    if let skipped = skippedMessage {
                        Text(skipped)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(MoveQuality.inaccuracy.tint)
                    }
                    if let stopped = stoppedMessage {
                        Text(stopped)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(MoveQuality.inaccuracy.tint)
                    }
                    HStack(spacing: 10) {
                        // The system's own paste button: reading the
                        // pasteboard from an ordinary button asks "Allow
                        // Paste?" every time, and this one never has to.
                        PasteButton(payloadType: String.self) { strings in
                            let pasted = strings.first ?? ""
                            Task { @MainActor in text = pasted }
                        }
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .controlSize(.large)
                        .tint(Color.white.opacity(0.15))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        OverlayButton(title: "Open", systemName: "magnifyingglass", prominent: true) {
                            open()
                        }
                        .disabled(isReading)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Paste PGN or FEN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func open() {
        guard !isReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Board(fen: trimmed) != nil {
            onOpen(Game(fen: trimmed))
            return
        }
        isReading = true
        Task {
            let contents = await Task.detached(priority: .userInitiated) {
                try? PGN.contents(of: trimmed)
            }.value
            isReading = false
            // Edited while it was read, the text is no longer what was read.
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            open(contents)
        }
    }

    private var skippedMessage: String? {
        guard skippedGames > 0 else { return nil }
        return String(localized: "\(skippedGames) games could not be read. Tap Open again to see the first one that could.")
    }

    private var stoppedMessage: String? {
        stoppedAt.map { String(localized: "Reading stopped at “\($0)”. Tap Open again to see the game up to there.") }
    }

    /// What is said under the text is said aloud as well. It came up without
    /// a word, nothing opened, and a VoiceOver user was left to find out why —
    /// and that Open has to be tapped a second time — by exploring the sheet.
    private func open(_ contents: PGN.Contents?) {
        guard !open(read: contents) else { return }
        let said = [failure, skippedMessage, stoppedMessage].compactMap { $0 }
        if !said.isEmpty { AccessibilityNotification.Announcement(said.joined(separator: " ")).post() }
    }

    /// Whether a game opened.
    private func open(read contents: PGN.Contents?) -> Bool {
        guard let contents else {
            failure = String(localized: "Neither a game nor a position could be read from that.")
            return false
        }
        if let parsed = contents.games.first, !parsed.game.history.isEmpty || parsed.tags["FEN"] != nil {
            // A game that stops short of what was pasted is said so once,
            // before it opens: opened straight away, it looked like the whole
            // game, and the moves it lost were never missed. So are games of
            // the text that could not be read at all: one whose FEN tag sets
            // up no position was left out without a word, and the game that
            // opened in its place was another.
            let told = stoppedAt != nil || skippedGames > 0
            if !told, parsed.unreadMove != nil || contents.unreadableGames > 0 {
                stoppedAt = parsed.unreadMove
                skippedGames = contents.unreadableGames
                return false
            }
            onOpen(parsed.game)
            return true
        }
        // Nothing to open; but where the text was a game after all, the
        // player is told what stood in the way rather than that nothing was
        // there: the move reading stopped at before it had read one, or a
        // FEN tag that sets up no position.
        if let unread = contents.games.first?.unreadMove {
            failure = String(localized: "Reading stopped at “\(unread)”: not one move could be read.")
        } else if contents.unreadableGames > 0 {
            failure = String(localized: "That FEN does not describe a legal position.")
        } else {
            failure = String(localized: "Neither a game nor a position could be read from that.")
        }
        return false
    }
}
