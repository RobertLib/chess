//
//  GameViewModel.swift
//  chess
//
//  Drives one game: board render model with stable piece identities (for
//  smooth animations), human interaction, AI turns, hints, undo, the clock,
//  premoves and saving.
//

import SwiftUI

@Observable
@MainActor
final class GameViewModel: PlayableBoard {

    // MARK: Render model

    typealias BoardPiece = PieceLayout.BoardPiece
    typealias DyingPiece = PieceLayout.DyingPiece

    /// The animated pieces. One layout for the life of the game: moves are
    /// mirrored into it, and anything that jumps rebuilds it.
    let layout: PieceLayout

    var pieces: [BoardPiece] { layout.pieces }
    var dyingPieces: [DyingPiece] { layout.dyingPieces }

    // MARK: State

    private(set) var game: Game
    let mode: GameMode
    /// The clock, the starting position, the adaptive strength and the layout
    /// this game was set up with.
    let options: GameOptions
    // Strong: settings never point back at a game, so there is no cycle to
    // break — and `unowned` only bought a crash if that ownership ever moved.
    private let settings: AppSettings

    var selectedSquare: Square?
    private(set) var legalTargets: [Move] = []

    /// The squares the selected piece may go to, one entry per square even
    /// when a promotion offers four moves to the same one. The board draws a
    /// marker per square; `legalTargets` keeps every move, because that is
    /// what making the move needs.
    var legalTargetSquares: [Move] { Self.uniqueTargets(legalTargets) }

    struct PendingPromotion {
        var moves: [Move]
        var from: Square { moves[0].from }
        var to: Square { moves[0].to }
        var color: PieceColor { moves[0].piece.color }
    }
    var pendingPromotion: PendingPromotion?

    private(set) var aiThinking = false
    private var aiTask: Task<Void, Never>?
    /// Bumped for every search started. A search that has been superseded
    /// carries a stale number and knows to keep its hands off shared state.
    private var aiGeneration = 0
    /// One searcher for the whole game: its transposition table and history
    /// heuristic carry over between moves instead of being rebuilt each time.
    private let aiEngine = GameAIEngine()

    private(set) var hintMove: Move?
    /// True while the hint search is running, so the button can show progress.
    private(set) var hintThinking = false
    private var hintTask: Task<Void, Never>?
    /// Bumped by every cancellation, the way `aiGeneration` is by every search.
    /// A hint that has been superseded carries a stale number and must keep its
    /// hands off `hintThinking`: clearing it would put out the spinner of the
    /// hint that replaced it and hand the button back mid-search.
    private var hintGeneration = 0
    /// The short pause between the last move and the result overlay. Held on to
    /// so that leaving the game in that moment does not fan the overlay and its
    /// victory chime out over the menu.
    private var gameOverTask: Task<Void, Never>?
    /// The delayed half-turn of the board in two-player auto-flip mode. Held
    /// for the same reason `gameOverTask` is: a turn falling due just as the
    /// game is left has nothing left to turn.
    private var autoFlipTask: Task<Void, Never>?

    var manualFlip = false
    var gameOverShown = false

    /// True while a finger is dragging a piece. The board reports it so that
    /// an auto-flip falling due in that moment waits: turning the board under
    /// an in-flight drag would map the drop through the mirrored geometry and
    /// land the piece on the wrong square.
    var isDragging = false {
        didSet {
            guard oldValue, !isDragging, autoFlipDeferred else { return }
            autoFlipDeferred = false
            performAutoFlip(to: game.sideToMove)
        }
    }
    private var autoFlipDeferred = false

    // MARK: Clock state

    /// The game clock, for a game on the clock.
    private(set) var clock: ChessClock?
    /// True while a timed game is held — by the player, or because the app
    /// went to the background. The board is covered then: a clock that has
    /// stopped is no reason for the position to stay on show to the player
    /// whose time it is not costing.
    private(set) var isPaused = false
    /// Seconds spent on each move so far, one per ply, kept for every game —
    /// or none at all, for a game restored without a record that lines up
    /// with its moves (see `recordsMoveTimes`).
    private(set) var moveTimes: [TimeInterval]
    /// False for a game that came back without a usable record of its move
    /// times: saved by a build that kept none, or with one that does not
    /// line up with the moves. Such a game records nothing from then on.
    /// Recording on from an empty record left it short and every entry one
    /// move or more out — the review then dropped it as not matching, while
    /// the PGN export rebuilt its clocks from it and put each against the
    /// wrong move. Complete and in step, or empty: nothing in between.
    private let recordsMoveTimes: Bool
    private var stopwatch = Stopwatch()
    /// Wakes up while a clock runs, to notice a flag falling and to sound the
    /// low-time warning.
    private var clockTask: Task<Void, Never>?
    /// Sides already warned that their time is running low. Re-armed once an
    /// increment has lifted them clear again.
    private var lowTimeWarned: Set<PieceColor> = []
    /// Where "now" comes from: monotonic seconds. Swappable so that a test can
    /// move time forward by hand instead of waiting for it.
    private let timeSource: () -> TimeInterval
    /// Set once the end of the game has been recorded — the adaptive
    /// opponent's step must not be taken twice for one game.
    private var resultRecorded = false
    /// False while the app is covered or in the background, so that a clock
    /// started in that time — by the computer's first move — starts held.
    private var sceneIsActive = true
    /// True while a page of the app's own is over the board — the daily
    /// puzzle the widget opens. Kept apart from `sceneIsActive`, which the
    /// scene sets back to true when the app returns with the page still up.
    private var isCovered = false
    /// True while the game's own settings sheet is up. A flag of its own
    /// rather than `isCovered`: the widget's tap closes the sheet on its way
    /// to the daily puzzle, and that closing must not let go of the game the
    /// puzzle is about to cover.
    private var isUnderSheet = false
    private var isOnScreen: Bool { sceneIsActive && !isCovered && !isUnderSheet }

    // MARK: Premove state

    /// A move the player has queued while the computer is thinking. It is
    /// played the instant the computer's reply lands, if it is still legal —
    /// or, when the reply lands while the game is held, once it is resumed.
    private(set) var premove: Move?
    /// True while the selection is for a premove rather than a real move.
    private var isSelectingPremove = false

    // MARK: Init

    init(
        mode: GameMode,
        settings: AppSettings,
        restoredGame: Game? = nil,
        options: GameOptions = .standard,
        restoredClock: ChessClock? = nil,
        restoredMoveTimes: [TimeInterval]? = nil,
        restoredMoveElapsed: TimeInterval? = nil,
        timeSource: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.mode = mode
        self.settings = settings
        self.options = options
        self.timeSource = timeSource
        let game = restoredGame ?? Game(fen: options.start.fen, variant: options.variant)
        self.game = game
        self.layout = PieceLayout(board: game.board)
        let times = restoredMoveTimes ?? []
        // A record that does not line up with the moves is no record at all.
        let inStep = times.count == game.history.count
        recordsMoveTimes = inStep
        self.moveTimes = inStep ? times : []
        if let restoredClock, options.timeControl != nil {
            clock = restoredClock
        } else if let control = options.timeControl {
            clock = ChessClock(control: control)
        }

        let time = timeSource()
        // The move in progress goes on from the time already spent on it. A
        // game saved by a build that did not keep it takes it from the clock,
        // which is held and let go with the stopwatch once the first move is
        // in, and so has the same figure on every turn but the first.
        let spent = restoredMoveElapsed ?? clock?.turnElapsed(at: time) ?? 0
        stopwatch = .held(at: max(0, spent), now: time)
        if game.outcome.isGameOver {
            clock?.stop(at: time)
        } else if clock?.isPaused == true {
            // A timed game coming back from "Continue" opens held, with the
            // board covered: the player is still finding their seat, and
            // their time should not be running while they do.
            isPaused = true
        } else {
            stopwatch.resume(at: time)
        }

        syncAutoFlip(afterMove: false)
        // Saved before a single move is played, so a game begun and left
        // straight away is still there under "Continue" — until now the first
        // move was what created the save, and quitting before it lost the game
        // and left the previous one on offer instead.
        persist()
        SoundManager.shared.play(.gameStart)
        Haptics.prepare()
        maybeTriggerAI()
        followPremoveSetting()
        // A game can be over before it starts — set up from a position the
        // rules already call finished, or restored under a rule that has
        // since settled it. The setup screens refuse the first kind, but the
        // ending still has to go up through the one door every ending uses:
        // with only the clock stopped, the board sat frozen with no result,
        // no way to review it and nothing to do but leave.
        if game.outcome.isGameOver { handleGameOver() }
    }

    private func now() -> TimeInterval { timeSource() }

    // MARK: Derived state

    /// In two-player auto-flip mode this trails the side to move so the board
    /// only rotates after the move animation has finished.
    private(set) var autoFlipOrientation: PieceColor = .white

    /// Color rendered at the bottom of the screen.
    var orientation: PieceColor {
        var base: PieceColor
        switch mode {
        case .vsAI(_, let playerColor):
            base = playerColor
        case .twoPlayer:
            base = autoFlips ? autoFlipOrientation : .white
        }
        if manualFlip { base = base.opponent }
        return base
    }

    /// Whether the board turns towards the player on move. Never at a shared
    /// table: there each player sits on their own side, and the far side's
    /// pieces are turned towards them instead.
    private var autoFlips: Bool {
        settings.autoFlipBoard && !isTabletop
    }

    /// Two players facing each other across the device.
    var isTabletop: Bool {
        guard case .twoPlayer = mode else { return false }
        return options.tabletop
    }

    var position: Board { game.board }

    var hasPendingPromotion: Bool { pendingPromotion != nil }

    var decorations: BoardDecorations {
        var decorations = BoardDecorations()
        decorations.premove = premove
        if isTabletop { decorations.upsideDownColor = orientation.opponent }
        if game.variant == .kingOfTheHill { decorations.zone = Board.hillSquares.map(Square.init) }
        return decorations
    }

    var isTimed: Bool { clock != nil }

    private func syncAutoFlip(afterMove: Bool) {
        guard case .twoPlayer = mode else { return }
        // A turn that was already due is superseded by this one, whichever way
        // this one resolves — an undo settles the orientation on the spot and
        // must not leave a delayed turn behind to fire over it.
        autoFlipTask?.cancel()
        autoFlipTask = nil
        let target = game.sideToMove
        guard autoFlipOrientation != target else { return }
        if afterMove {
            autoFlipTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                guard let self, !Task.isCancelled else { return }
                self.performAutoFlip(to: target)
            }
        } else {
            autoFlipOrientation = target
        }
    }

    /// Turns the board towards `target` — unless a drag is in progress, in
    /// which case the turn is held until the finger lifts. Half a turn of the
    /// board is movement with meaning, so Reduce Motion flattens it to a fade
    /// rather than dropping it.
    private func performAutoFlip(to target: PieceColor) {
        guard game.sideToMove == target, autoFlipOrientation != target else { return }
        if isDragging {
            autoFlipDeferred = true
            return
        }
        withAnimation(Motion.meaningful(.spring(duration: 0.55, bounce: 0.15))) {
            autoFlipOrientation = target
        }
    }

    var lastMove: Move? { game.lastMove }

    /// Square of the king currently in check (for the red glow).
    var checkedKingSquare: Square? {
        guard game.isInCheck || isCheckmateOutcome else { return nil }
        return Square(game.board.kingSquare(of: game.sideToMove))
    }

    private var isCheckmateOutcome: Bool {
        if case .checkmate = game.outcome { return true }
        return false
    }

    /// Whether premoves are on offer in this game at all.
    private var allowsPremoves: Bool {
        mode.isVsAI && settings.premovesEnabled
    }

    /// Whether the human may currently interact with pieces of `color`.
    func isInteractive(color: PieceColor) -> Bool {
        guard !game.outcome.isGameOver, pendingPromotion == nil, !isPaused else { return false }
        switch mode {
        case .twoPlayer:
            return color == game.sideToMove
        case .vsAI(_, let playerColor):
            guard color == playerColor else { return false }
            if color == game.sideToMove && !aiThinking { return true }
            // The computer is on move: the player may line up their reply.
            return allowsPremoves
        }
    }

    var canUndo: Bool {
        // A finished game is done with: the overlay covers the board, and
        // taking a move back would quietly revive a game whose result has
        // already been saved for review.
        guard !game.outcome.isGameOver, !game.history.isEmpty else { return false }
        // On the clock a move is a move, the way it is over any real board.
        // Taking one back would also have to hand back the time it cost and
        // take away the increment it earned, and there is no version of that
        // which is fair to both sides.
        guard !isTimed else { return false }
        if case .vsAI(_, let playerColor) = mode {
            // Undo makes sense whenever the human has made at least one move.
            return game.history.contains { $0.color == playerColor }
        }
        return true
    }

    /// Whether asking for a hint would actually do something. It carries the
    /// whole precondition, including the search already running and the three
    /// seconds a hint stays on the board, because the button reads this to
    /// decide whether to look enabled: with only the turn tested, the button
    /// sat there bright and answered a tap with nothing at all.
    var canRequestHint: Bool {
        guard case .vsAI(_, let playerColor) = mode, !isTimed else { return false }
        return game.sideToMove == playerColor && !aiThinking
            && isInteractive(color: playerColor) && !hintThinking && hintMove == nil
    }

    /// Whether the two players may settle for a draw. Two-player games only —
    /// the same slot in the control bar holds Hint against the computer, where
    /// a hint is what there is to ask for and a draw is not.
    var canAgreeToDraw: Bool {
        drawIsOpen && !isPaused
    }

    /// `canAgreeToDraw` short of the pause. Draw is not offered under the
    /// pause cover, but a dialog opened before the app went away is answered
    /// there, as Resign is — and Agree to a Draw, tapped, did nothing.
    private var drawIsOpen: Bool {
        guard case .twoPlayer = mode else { return false }
        return !game.outcome.isGameOver && pendingPromotion == nil
    }

    // MARK: Selection & taps

    func handleTap(on square: Square) {
        guard pendingPromotion == nil, !game.outcome.isGameOver, !isPaused else { return }

        if let selected = selectedSquare {
            if selected == square {
                deselect()
                return
            }
            if !Self.moves(from: selected, to: square, among: legalTargets, on: game.board).isEmpty {
                _ = attemptMove(from: selected, to: square)
                return
            }
        }

        if let piece = game.board.piece(at: square), isInteractive(color: piece.color) {
            select(square)
        } else if selectedSquare != nil {
            if !isSelectingPremove { rejectMove() }
            deselect()
        } else if premove != nil {
            // A tap anywhere else takes a queued premove back.
            cancelPremove()
        }
    }

    /// Says no to a move the rules do not allow, so a misplaced tap or a
    /// dropped piece is answered rather than silently ignored.
    private func rejectMove() {
        SoundManager.shared.play(.illegal)
        Haptics.illegal()
    }

    func select(_ square: Square) {
        guard let piece = game.board.piece(at: square), isInteractive(color: piece.color) else { return }
        selectedSquare = square
        if piece.color == game.sideToMove && !aiThinking {
            isSelectingPremove = false
            legalTargets = game.legalMoves(from: square)
        } else {
            isSelectingPremove = true
            legalTargets = premoveCandidates(from: square)
        }
        SoundManager.shared.play(.select)
        Haptics.pieceSelected()
    }

    func deselect() {
        selectedSquare = nil
        legalTargets = []
        isSelectingPremove = false
    }

    /// Attempts a move between two squares; shows the promotion picker when
    /// several promotion moves match. Returns true when the input was consumed.
    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool {
        let candidates = Self.moves(from: from, to: to, among: legalTargets, on: game.board)
        guard !candidates.isEmpty else {
            if !isSelectingPremove { rejectMove() }
            return false
        }
        if isSelectingPremove {
            // A queued promotion becomes a queen: there is no time to ask, and
            // the reply it is waiting for will not wait either.
            queuePremove(candidates.first { $0.promotion == .queen } ?? candidates[0])
            return true
        }
        if candidates.count > 1 {
            // Promotion: keep the selection, ask which piece. The order here
            // does not matter — the picker lays the four pieces out itself and
            // `completePromotion` looks its answer up by kind.
            withAnimation(Motion.meaningful(.spring(duration: 0.3))) {
                pendingPromotion = PendingPromotion(moves: candidates)
            }
            return true
        }
        apply(candidates[0])
        return true
    }

    func completePromotion(with kind: PieceKind) {
        guard let pending = pendingPromotion,
              let move = pending.moves.first(where: { $0.promotion == kind }) else { return }
        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { pendingPromotion = nil }
        apply(move)
    }

    func cancelPromotion() {
        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { pendingPromotion = nil }
        deselect()
    }

    // MARK: Premoves

    /// Where a piece could go once the computer has replied, as far as can be
    /// told now: its moves as though it were already the player's turn, with
    /// the king-safety test left out — the reply has not been played, so
    /// whether the king will be safe is not knowable yet. The premove is
    /// checked against the real position when its turn comes.
    private func premoveCandidates(from square: Square) -> [Move] {
        var board = game.board
        board.sideToMove = board.sideToMove.opponent
        board.enPassantSquare = -1
        return board.generatePseudoLegalMoves().filter { $0.from == square }
    }

    private func queuePremove(_ move: Move) {
        deselect()
        withAnimation(.easeOut(duration: 0.15)) { premove = move }
        SoundManager.shared.play(.select)
        Haptics.pieceSelected()
    }

    func cancelPremove() {
        guard premove != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { premove = nil }
    }

    /// Takes back a queued premove, and one being lined up, the moment
    /// premoves are switched off. The settings sheet opens over a game in
    /// progress, so the switch can be thrown with a premove waiting on the
    /// computer's reply — which then went and played it all the same.
    ///
    /// Observation reports one change and is spent, so the setting is
    /// watched again after each. A two-player game reads no setting here and
    /// so is never woken.
    private func followPremoveSetting() {
        let allowed = withObservationTracking {
            allowsPremoves
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPremoveSetting() }
        }
        guard !allowed else { return }
        cancelPremove()
        if isSelectingPremove { deselect() }
    }

    /// Plays the queued premove if it is legal in the position the computer's
    /// reply has left, and drops it quietly if not, or if premoves have been
    /// switched off since it was queued.
    ///
    /// A held game keeps it queued. The computer's search does not stop for a
    /// pause, so its reply can land under the cover (see `ChessClock.press`),
    /// but the player's own move waits until they can see what it is played
    /// into: `resume` plays it then.
    private func playPremoveIfLegal() {
        guard let queued = premove, !isPaused else { return }
        premove = nil
        guard allowsPremoves, case .vsAI(_, let playerColor) = mode, game.sideToMove == playerColor,
              !game.outcome.isGameOver else { return }
        let match = game.legalMoves.first {
            $0.from == queued.from && $0.to == queued.to && $0.promotion == queued.promotion
        }
        if let match {
            deselect()
            apply(match)
        }
    }

    // MARK: Applying moves

    private func apply(_ move: Move) {
        guard !game.outcome.isGameOver else { return }

        let wasFirstMove = game.history.isEmpty
        let time = now()
        // A move that lands after the flag fell but before the clock watch
        // woke to notice — a premove, a reply in the same instant — is too
        // late. Pressing the clock now would hand the increment back to a
        // side that has already lost on time.
        if !wasFirstMove, clock?.flagged(at: time) != nil {
            handleFlag()
            return
        }
        recordTime(forMoveAt: time, startsClock: wasFirstMove)

        layout.apply(move, before: game.board, animation: Motion.meaningful(.spring(duration: 0.35, bounce: 0.18)))
        game.play(move)

        // The clock starts once the first move is on the board: the side that
        // opens the game is not charged for finding its first move, the same
        // allowance the big servers make.
        if wasFirstMove, !game.outcome.isGameOver {
            clock?.start(game.sideToMove, at: now())
            if isOnScreen {
                scheduleClockWatch()
            } else {
                // The computer's first move has landed while the app was
                // covered — a call, the app switcher. Before it there was no
                // clock to hold on the way out, so it is held now, the way a
                // running one would have been: started running, it spent the
                // player's time all the while they were away, and nothing on
                // their return stopped it.
                pause()
            }
        }

        deselect()
        cancelHint()

        // Feedback.
        let isCheck = game.isInCheck
        SoundManager.shared.play(for: move, isCheck: isCheck)
        if isCheck {
            Haptics.check()
        } else if move.isCapture {
            Haptics.capture()
        } else {
            Haptics.pieceMoved()
        }

        if game.outcome.isGameOver {
            // A premove queued for after the computer's reply has nothing
            // left to be played into.
            premove = nil
            stopClock()
            persist()
            handleGameOver()
        } else {
            persist()
            syncAutoFlip(afterMove: true)
            maybeTriggerAI()
            if case .vsAI(_, let playerColor) = mode, move.piece.color != playerColor {
                playPremoveIfLegal()
            }
        }
    }

    /// Charges the move about to be played to the clock and the record.
    private func recordTime(forMoveAt now: TimeInterval, startsClock: Bool) {
        let lap = stopwatch.lap(at: now)
        if recordsMoveTimes { moveTimes.append(lap) }
        guard var clock, !startsClock else { return }
        clock.press(at: now)
        self.clock = clock
        // The increment may have lifted a warned side clear again.
        if let mover = clock.active?.opponent,
           clock.remaining(for: mover, at: now) > lowTimeThreshold(for: mover) * 1.5 {
            lowTimeWarned.remove(mover)
        }
        scheduleClockWatch()
    }

    // MARK: AI

    /// The strength the computer plays at: the adaptive opponent's level as it
    /// stood when the game began, or the fixed level's own.
    private var aiStrength: AIStrength {
        guard case .vsAI(let difficulty, _) = mode else { return AIDifficulty.medium.strength }
        if difficulty == .adaptive {
            return AIStrength.interpolated(options.adaptiveLevel ?? settings.adaptiveLevel)
        }
        return difficulty.strength
    }

    private func maybeTriggerAI() {
        guard case .vsAI(_, let playerColor) = mode,
              !game.outcome.isGameOver,
              game.sideToMove != playerColor,
              !aiThinking,
              // A held game stays held: the computer waits for it like
              // anyone else, rather than playing its move while nobody's
              // clock is running.
              !isPaused
        else { return }

        aiThinking = true
        aiGeneration += 1
        let generation = aiGeneration
        let board = game.board
        let hashes = game.repetitionHashes
        // The game so far, for `OpeningBook` to match against. Read here on
        // the main actor rather than inside the detached search, which has no
        // business touching the model.
        //
        // Only for a game that began from the standard position. The book is
        // written as move sequences, so an empty history reads as "nothing
        // played yet" whatever board it is asked about, and a game set up from
        // a FEN would have theory quoted at a position theory has never seen —
        // 1.e4 is legal in plenty of them. `OpeningBook.move` does check its
        // answer against the board, which catches the absurd cases, but the
        // honest question is whether this is a game the book can speak about
        // at all, and that is what `initialFEN` answers.
        let useBook = game.initialFEN == Board.startFEN && !game.isChess960
        let bookSANs = useBook ? game.history.map(\.san) : []
        let startTime = ContinuousClock.now
        let strength = aiStrength

        // On the clock the computer budgets from what it has left; see
        // `AITimeBudget`.
        let aiColor = playerColor.opponent
        let timeNow = now()
        let remaining = clock.map { $0.remaining(for: aiColor, at: timeNow) }
        let timeLimit: TimeInterval? = clock.map { clock in
            AITimeBudget.seconds(
                remaining: clock.remaining(for: aiColor, at: timeNow),
                increment: clock.control.bonus,
                movesPlayed: game.history.count / 2,
                levelTime: strength.time
            )
        }
        let minimum = Duration.seconds(AITimeBudget.thinkingPause(remaining: remaining))

        let engine = aiEngine
        let cancellation = SearchCancellation()

        aiTask = Task { [weak self] in
            // The search is a synchronous loop on a background thread, so it
            // cannot see this task's cancellation by itself — the token is how
            // undo or leaving the game stops it instead of letting it run out
            // its whole time budget.
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    engine.bestMove(
                        board: board, gameHashes: hashes,
                        strength: strength, bookSANs: bookSANs,
                        cancellation: cancellation, timeLimit: timeLimit, useBook: useBook
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }

            // A minimum "thinking" pause keeps fast moves feeling deliberate.
            let elapsed = ContinuousClock.now - startTime
            if elapsed < minimum {
                try? await Task.sleep(for: minimum - elapsed)
            }

            guard let self else { return }
            // Only the newest search owns the flag. Clearing it before the
            // cancellation check means a caller that cancels without resetting
            // it cannot leave the game frozen with the computer "thinking" —
            // but a search that has already been replaced must not clear the
            // flag the search replacing it has just set.
            guard self.aiGeneration == generation else { return }
            self.aiThinking = false
            guard !Task.isCancelled, let result else { return }
            // The selection may have been made for a premove; the real turn
            // starts now, so it is made again against the real moves.
            let wasPremoveSelection = self.isSelectingPremove
            let selected = self.selectedSquare
            self.apply(result.move)
            if wasPremoveSelection, let selected, self.premove == nil,
               self.game.board.piece(at: selected)?.color == playerColor {
                self.select(selected)
            }
        }
    }

    // MARK: Hint

    func requestHint() {
        guard canRequestHint else { return }
        cancelHint()
        let board = game.board
        let hashes = game.repetitionHashes

        hintThinking = true
        let generation = hintGeneration
        let cancellation = SearchCancellation()
        hintTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    findBestAIMove(
                        board: board, gameHashes: hashes,
                        difficulty: .hard, cancellation: cancellation
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            guard let self, self.hintGeneration == generation else { return }
            // Cleared before the cancellation check, so a caller that cancels
            // without resetting the flag cannot leave the button spinning.
            self.hintThinking = false
            guard !Task.isCancelled, let result else { return }
            withAnimation(Motion.meaningful(.spring(duration: 0.3))) {
                self.hintMove = result.move
            }
            SoundManager.shared.play(.select)
            // The hint is two highlighted squares, which a VoiceOver player
            // never sees: without this the button clicked and did nothing.
            let spoken = BoardSpeech.spokenMove(result.move, on: board)
            AccessibilityNotification.Announcement(
                String(localized: "announce.hint", defaultValue: "Hint: \(spoken)",
                       comment: "Spoken when a hint is shown, e.g. 'Hint: knight f 3'")
            ).post()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.hintMove = nil
            }
        }
    }

    private func cancelHint() {
        hintGeneration += 1
        hintTask?.cancel()
        hintTask = nil
        hintThinking = false
        hintMove = nil
    }

    // MARK: Undo / resign

    func undo() {
        guard canUndo else { return }
        aiTask?.cancel()
        aiThinking = false
        cancelHint()
        cancelPremove()
        pendingPromotion = nil

        // How far back to go, counted before anything is taken back so the
        // whole takeback is one replay of the game rather than one per ply.
        // The side to move after dropping `plies` is the colour of the move
        // that was played from that position, which is the entry `plies` from
        // the end — so this asks the same question the loop here used to ask
        // after each undo.
        var plies = 1
        if case .vsAI(_, let playerColor) = mode {
            // Roll back to the human's turn.
            while plies < game.history.count,
                  game.history[game.history.count - plies].color != playerColor {
                plies += 1
            }
        }
        game.undoLastMoves(plies)
        moveTimes.removeLast(min(plies, moveTimes.count))
        _ = stopwatch.lap(at: now())

        layout.rebuild(from: game.board)
        deselect()
        gameOverShown = false
        withAnimation(Motion.meaningful(.spring(duration: 0.4))) {
            syncAutoFlip(afterMove: false)
        }
        SoundManager.shared.play(.move)
        Haptics.pieceMoved()
        persist()
        maybeTriggerAI()
    }

    func resign() {
        guard !game.outcome.isGameOver else { return }
        stopPlayForEnding()
        let resigningColor: PieceColor
        if case .vsAI(_, let playerColor) = mode {
            resigningColor = playerColor
        } else {
            resigningColor = game.sideToMove
        }
        game.resign(resigningColor)
        stopClock()
        persist()
        handleGameOver()
    }

    /// Ends the game as a draw the two players have settled on. Offered only
    /// on a shared device: against the computer there is nobody to agree with,
    /// and an engine that accepted would be conceding a position it can see is
    /// winning (or refusing one it cannot).
    func agreeToDraw() {
        guard drawIsOpen else { return }
        stopPlayForEnding()
        game.agreeToDraw()
        stopClock()
        persist()
        handleGameOver()
    }

    /// Puts the board down before a result goes up. A hint still searching
    /// would otherwise come back after the overlay, click, and paint its
    /// squares underneath it; a selection would sit on the finished position.
    private func stopPlayForEnding() {
        aiTask?.cancel()
        aiThinking = false
        cancelHint()
        cancelPremove()
        deselect()
        pendingPromotion = nil
    }

    // MARK: Clock

    /// What the clock shows for `color` right now.
    func clockRemaining(for color: PieceColor) -> TimeInterval? {
        clock?.remaining(for: color, at: now())
    }

    /// The same at a given moment — for a view redrawing on a schedule.
    func clockRemaining(for color: PieceColor, at time: TimeInterval) -> TimeInterval? {
        clock?.remaining(for: color, at: time)
    }

    /// Monotonic "now", for views that draw the clock on a schedule.
    var clockNow: TimeInterval { now() }

    var isClockRunning: Bool { clock?.isRunning == true }

    /// Whether `color`'s clock is the one ticking (or held, while paused).
    func isClockActive(for color: PieceColor) -> Bool {
        clock?.active == color && !game.outcome.isGameOver
    }

    /// The point below which a clock reads as short of time: ten seconds, or
    /// a sixth of the starting time for games shorter than a minute.
    func lowTimeThreshold(for color: PieceColor) -> TimeInterval {
        guard let control = clock?.control else { return 0 }
        return min(10, control.initialTime(for: color) / 6)
    }

    /// Whether the game can be held right now.
    var canPause: Bool {
        guard let clock, !game.outcome.isGameOver else { return false }
        return clock.isRunning
    }

    /// Holds the game: the clock stops, the board is covered.
    func pause() {
        guard canPause, var clock else { return }
        let time = now()
        clock.pause(at: time)
        self.clock = clock
        stopwatch.pause(at: time)
        clockTask?.cancel()
        clockTask = nil
        deselect()
        pendingPromotion = nil
        withAnimation(Motion.meaningful(.easeInOut(duration: 0.25))) { isPaused = true }
        persist()
    }

    /// Lets a held game go on. A finished game has nothing to go on with:
    /// its clock is stopped for good, and the stopwatch along with it.
    func resume() {
        guard isPaused, !game.outcome.isGameOver else { return }
        let time = now()
        clock?.resume(at: time)
        stopwatch.resume(at: time)
        withAnimation(Motion.meaningful(.easeInOut(duration: 0.25))) { isPaused = false }
        scheduleClockWatch()
        maybeTriggerAI()
        // The computer's reply may have come in under the cover, with the
        // premove held back behind it (see `playPremoveIfLegal`). With the
        // computer not thinking, the reply is in, and the premove goes now.
        if !aiThinking { playPremoveIfLegal() }
    }

    /// The app is going to the background, or something has covered it — a
    /// call, the control centre. A timed game is held; an untimed one only
    /// stops counting the time on the move.
    func sceneDidDeactivate() {
        sceneIsActive = false
        holdWhileAway()
    }

    func sceneDidActivate() {
        sceneIsActive = true
        resumeOnReturn()
    }

    /// A page of the app's own has gone up over the board, or come down
    /// again. The game is held exactly as when the app leaves the screen.
    func coverDidAppear() {
        isCovered = true
        holdWhileAway()
    }

    func coverDidDisappear() {
        isCovered = false
        resumeOnReturn()
    }

    /// The settings sheet has gone up over the game, or come down again. On
    /// a phone it hides the board, and a clock that ran on under it let the
    /// flag fall on a player who was choosing a board theme.
    func sheetDidAppear() {
        isUnderSheet = true
        holdWhileAway()
    }

    func sheetDidDisappear() {
        isUnderSheet = false
        resumeOnReturn()
    }

    private func holdWhileAway() {
        if canPause {
            pause()
        } else {
            stopwatch.pause(at: now())
            persist()
        }
    }

    private func resumeOnReturn() {
        guard isOnScreen, !isPaused, !game.outcome.isGameOver else { return }
        stopwatch.resume(at: now())
    }

    /// Keeps watch while a clock runs: notices a flag falling the moment it
    /// does, and sounds the warning when time gets short.
    ///
    /// It sleeps until the next thing that could happen rather than ticking at
    /// a fixed rate — at most a quarter of a second, so a warning is never
    /// late by more than that, and exactly until the flag when that is sooner.
    private func scheduleClockWatch() {
        clockTask?.cancel()
        clockTask = nil
        guard let clock, clock.isRunning, !game.outcome.isGameOver else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let clock = self.clock, clock.isRunning else { return }
                let time = self.now()
                if clock.flagged(at: time) != nil {
                    self.handleFlag()
                    return
                }
                self.warnIfShortOfTime(clock, at: time)
                let wait = min(0.25, max(0.01, clock.timeUntilFlag(at: time) ?? 0.25))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func warnIfShortOfTime(_ clock: ChessClock, at time: TimeInterval) {
        guard let side = clock.active, !lowTimeWarned.contains(side) else { return }
        // Only a person needs telling. The computer budgets for itself.
        if case .vsAI(_, let playerColor) = mode, side != playerColor { return }
        let threshold = lowTimeThreshold(for: side)
        guard clock.control.initialTime(for: side) > threshold * 2,
              clock.remaining(for: side, at: time) <= threshold else { return }
        lowTimeWarned.insert(side)
        SoundManager.shared.play(.lowTime)
        Haptics.lowTime()
        AccessibilityNotification.Announcement(
            String(localized: "announce.lowTime",
                   defaultValue: "\(side.spokenName): \(ClockFormat.spoken(threshold)) left",
                   comment: "Spoken when a player's clock runs low, e.g. 'White: 10 seconds left'")
        ).post()
    }

    /// The side on move has run out of time.
    private func handleFlag() {
        guard !game.outcome.isGameOver else { return }
        stopPlayForEnding()
        game.timeOut()
        stopClock()
        SoundManager.shared.play(.lowTime)
        persist()
        handleGameOver()
    }

    /// Every ending comes through here — the last move, a resignation, an
    /// agreed draw, a flag — so this is also where a hold ends with the game.
    /// A game can end while it is held: the computer's reply lands under the
    /// cover (see `playPremoveIfLegal`), and Resign can be answered in a
    /// dialog opened before the app went away. Left set, the opaque cover
    /// stayed under the result card for good and hid the final position.
    private func stopClock() {
        let time = now()
        clock?.stop(at: time)
        stopwatch.pause(at: time)
        clockTask?.cancel()
        clockTask = nil
        if isPaused {
            withAnimation(Motion.meaningful(.easeInOut(duration: 0.25))) { isPaused = false }
        }
    }

    // MARK: Game over

    private func handleGameOver() {
        let outcome = game.outcome
        guard outcome.isGameOver else { return }

        let humanWon: Bool?
        if case .vsAI(_, let playerColor) = mode {
            humanWon = outcome.winner.map { $0 == playerColor }
        } else {
            // Any mate or resignation on a shared device is somebody's win.
            // A draw is nobody's — mapping it to `false`, which is what the
            // plain `winner != nil` did, answered every two-player stalemate
            // and repetition with the losing sting instead of the draw chime.
            humanWon = outcome.winner != nil ? true : nil
        }

        recordResult()

        gameOverTask?.cancel()
        gameOverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.25))) {
                self.gameOverShown = true
            }
            switch humanWon {
            case .some(true):
                SoundManager.shared.play(.win)
                Haptics.gameEnded(win: true)
            case .some(false):
                SoundManager.shared.play(.lose)
                Haptics.gameEnded(win: false)
            case .none:
                SoundManager.shared.play(.draw)
                Haptics.gameEnded(win: false)
            }
        }
    }

    /// What the end of a game changes beyond the game itself: the adaptive
    /// opponent's strength, the archive, the statistics and the achievements.
    /// Once per game, however the end was reached.
    private func recordResult() {
        guard !resultRecorded else { return }
        resultRecorded = true
        // Not for a game from a set-up position: one a player arranged to win
        // says nothing about how strong they are, and won a few times over it
        // walked the adaptive opponent up to its top level. Nor for a game at
        // odds: won with the computer a queen down, it lifted the level the
        // next even game is played at well above the player.
        if case .vsAI(.adaptive, let playerColor) = mode, !game.history.isEmpty,
           !options.start.isSetUp, !options.start.isHandicap {
            let score: Double = game.outcome.winner.map { $0 == playerColor ? 1 : 0 } ?? 0.5
            settings.recordAdaptiveResult(playerScore: score)
        }
        guard !game.history.isEmpty else { return }
        GameArchive.shared.add(GameRecord(
            game: game, mode: mode, options: options,
            moveTimes: moveTimes, finalClock: finalClockFaces
        ))
    }

    private var finalClockFaces: [TimeInterval]? {
        guard let clock else { return nil }
        let time = now()
        return [clock.remaining(for: .white, at: time), clock.remaining(for: .black, at: time)]
    }

    // MARK: Persistence

    private func persist() {
        if game.outcome.isGameOver {
            // The finished game is kept by the archive (`recordResult`), from
            // where My Games and the menu offer it for review.
            SavedGame.clear()
        } else {
            let time = now()
            SavedGame(
                mode: mode,
                initialFEN: game.initialFEN,
                moveUCIs: game.history.map(\.move.uci),
                savedAt: Date(),
                options: options,
                clock: clock?.pausedCopy(at: time),
                moveTimes: moveTimes,
                moveElapsed: stopwatch.elapsed(at: time)
            ).save()
        }
    }

    /// Abandon without resigning (game stays saved for "continue").
    func teardown() {
        // Leaving for the menu holds the clock where it stands, so "Continue"
        // picks the game up with the time it was left with.
        if !game.outcome.isGameOver {
            let time = now()
            clock?.pause(at: time)
            stopwatch.pause(at: time)
            persist()
        }
        aiTask?.cancel()
        cancelHint()
        clockTask?.cancel()
        clockTask = nil
        gameOverTask?.cancel()
        gameOverTask = nil
        autoFlipTask?.cancel()
        autoFlipTask = nil
        layout.cancelFades()
    }

#if DEBUG
    /// Development helper: plays a UCI move sequence through the same code
    /// path a human uses (selection, promotion picker), for screenshots.
    /// `engine` in place of a move plays what Hard would, which stays sound
    /// whatever the computer replied — a written-down line cannot, against an
    /// opponent that opens out of the book at random.
    func playScriptedMoves(_ uciMoves: [String], interval: TimeInterval = 1.0) {
        Task { @MainActor [weak self] in
            for uci in uciMoves {
                try? await Task.sleep(for: .seconds(interval))
                // Against the computer the next move is only ours once it has
                // replied. A reply slower than the interval used to end the
                // script there, as if the move had been illegal.
                while self?.aiThinking == true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                let found: Move?
                if uci == "engine" {
                    let board = self.game.board
                    let hashes = self.game.repetitionHashes
                    found = await Task.detached(priority: .userInitiated) {
                        findBestAIMove(board: board, gameHashes: hashes, difficulty: .hard)?.move
                    }.value
                } else {
                    found = self.game.legalMoves.first(where: { $0.uci.hasPrefix(uci) })
                }
                guard let move = found else { return }
                self.select(move.from)
                self.attemptMove(from: move.from, to: move.to)
                if self.pendingPromotion != nil { return } // leave the picker open
            }
        }
    }
#endif
}

private extension Stopwatch {
    /// A stopwatch that has already run for `elapsed` by `now`, held there —
    /// the move a saved game was left in the middle of, ready to go on.
    static func held(at elapsed: TimeInterval, now: TimeInterval) -> Stopwatch {
        var stopwatch = Stopwatch()
        stopwatch.start(at: now - elapsed)
        stopwatch.pause(at: now)
        return stopwatch
    }
}
