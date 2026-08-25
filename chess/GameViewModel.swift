//
//  GameViewModel.swift
//  chess
//
//  Drives one game: board render model with stable piece identities (for
//  smooth animations), human interaction, AI turns, hints, undo and saving.
//

import SwiftUI

@Observable
@MainActor
final class GameViewModel {

    // MARK: Render model

    /// A piece on the board with a stable identity so SwiftUI can animate it.
    struct BoardPiece: Identifiable {
        let id: UUID
        var piece: Piece
        var square: Square
    }

    /// A captured piece briefly kept around while it fades out.
    struct DyingPiece: Identifiable {
        let id: UUID
        let piece: Piece
        let square: Square
    }

    private(set) var pieces: [BoardPiece] = []
    private(set) var dyingPieces: [DyingPiece] = []

    // MARK: State

    private(set) var game: Game
    let mode: GameMode
    // Strong: settings never point back at a game, so there is no cycle to
    // break — and `unowned` only bought a crash if that ownership ever moved.
    private let settings: AppSettings

    var selectedSquare: Square?
    private(set) var legalTargets: [Move] = []

    /// The squares the selected piece may go to, one entry per square even
    /// when a promotion offers four moves to the same one. The board draws a
    /// marker per square; `legalTargets` keeps every move, because that is
    /// what making the move needs.
    var legalTargetSquares: [Move] {
        var seen = Set<Int>()
        return legalTargets.filter { seen.insert($0.to.index).inserted }
    }

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

    // MARK: Init

    init(mode: GameMode, settings: AppSettings, restoredGame: Game? = nil) {
        self.mode = mode
        self.settings = settings
        self.game = restoredGame ?? Game()
        rebuildPieces()
        syncAutoFlip(afterMove: false)
        // Saved before a single move is played, so a game begun and left
        // straight away is still there under "Continue" — until now the first
        // move was what created the save, and quitting before it lost the game
        // and left the previous one on offer instead.
        persist()
        SoundManager.shared.play(.gameStart)
        Haptics.prepare()
        maybeTriggerAI()
    }

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
            base = settings.autoFlipBoard ? autoFlipOrientation : .white
        }
        if manualFlip { base = base.opponent }
        return base
    }

    private func syncAutoFlip(afterMove: Bool) {
        guard case .twoPlayer = mode else { return }
        let target = game.sideToMove
        guard autoFlipOrientation != target else { return }
        if afterMove {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                self?.performAutoFlip(to: target)
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

    /// Whether the human may currently interact with pieces of `color`.
    func isInteractive(color: PieceColor) -> Bool {
        guard !game.outcome.isGameOver, pendingPromotion == nil else { return false }
        switch mode {
        case .twoPlayer:
            return color == game.sideToMove
        case .vsAI(_, let playerColor):
            return color == game.sideToMove && color == playerColor && !aiThinking
        }
    }

    var canUndo: Bool {
        // A finished game is done with: the overlay covers the board, and
        // taking a move back would quietly revive a game whose result has
        // already been saved for review.
        guard !game.outcome.isGameOver, !game.history.isEmpty else { return false }
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
        guard case .vsAI(_, let playerColor) = mode else { return false }
        return isInteractive(color: playerColor) && !hintThinking && hintMove == nil
    }

    /// Whether the two players may settle for a draw. Two-player games only —
    /// the same slot in the control bar holds Hint against the computer, where
    /// a hint is what there is to ask for and a draw is not.
    var canAgreeToDraw: Bool {
        guard case .twoPlayer = mode else { return false }
        return !game.outcome.isGameOver && pendingPromotion == nil
    }

    // MARK: Selection & taps

    func handleTap(on square: Square) {
        guard pendingPromotion == nil, !game.outcome.isGameOver else { return }

        if let selected = selectedSquare {
            if selected == square {
                deselect()
                return
            }
            if legalTargets.contains(where: { $0.to == square }) {
                _ = attemptMove(from: selected, to: square)
                return
            }
        }

        if let piece = game.board.piece(at: square), isInteractive(color: piece.color) {
            select(square)
        } else if selectedSquare != nil {
            rejectMove()
            deselect()
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
        legalTargets = game.legalMoves(from: square)
        SoundManager.shared.play(.select)
        Haptics.pieceSelected()
    }

    func deselect() {
        selectedSquare = nil
        legalTargets = []
    }

    /// Attempts a move between two squares; shows the promotion picker when
    /// several promotion moves match. Returns true when the input was consumed.
    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool {
        let candidates = legalTargets.filter { $0.from == from && $0.to == to }
        guard !candidates.isEmpty else {
            rejectMove()
            return false
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

    // MARK: Applying moves

    private func apply(_ move: Move) {
        guard !game.outcome.isGameOver else { return }

        updateRenderModel(for: move)
        game.play(move)

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

        persist()

        if game.outcome.isGameOver {
            handleGameOver()
        } else {
            syncAutoFlip(afterMove: true)
            maybeTriggerAI()
        }
    }

    /// Mirrors a move into the animated render model.
    private func updateRenderModel(for move: Move) {
        let mover = move.piece.color
        var dyingID: UUID?

        withAnimation(Motion.meaningful(.spring(duration: 0.35, bounce: 0.18))) {
            // Remove the captured piece.
            if move.captured != nil {
                let captureSquare: Square
                if move.isEnPassant {
                    captureSquare = Square(mover == .white ? move.to.index - 8 : move.to.index + 8)
                } else {
                    captureSquare = move.to
                }
                if let index = pieces.firstIndex(where: { $0.square == captureSquare }) {
                    let dying = pieces.remove(at: index)
                    dyingID = dying.id
                    dyingPieces.append(DyingPiece(id: dying.id, piece: dying.piece, square: dying.square))
                }
            }

            // Move the piece (and promote it).
            if let index = pieces.firstIndex(where: { $0.square == move.from }) {
                pieces[index].square = move.to
                if let promotion = move.promotion {
                    pieces[index].piece = Piece(mover, promotion)
                }
            }

            // Castling: move the rook as well.
            if move.isCastleKingside || move.isCastleQueenside {
                let rank = mover == .white ? 0 : 7
                let rookFrom = Square(file: move.isCastleKingside ? 7 : 0, rank: rank)
                let rookTo = Square(file: move.isCastleKingside ? 5 : 3, rank: rank)
                if let index = pieces.firstIndex(where: { $0.square == rookFrom }) {
                    pieces[index].square = rookTo
                }
            }
        }

        // Let the fade-out play, then drop this piece — and only this one, so
        // two captures in quick succession do not cut each other short.
        if let dyingID {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    self.dyingPieces.removeAll { $0.id == dyingID }
                }
            }
        }
    }

    private func rebuildPieces() {
        pieces = Square.all.compactMap { square in
            game.board.piece(at: square).map {
                BoardPiece(id: UUID(), piece: $0, square: square)
            }
        }
        dyingPieces = []
    }

    // MARK: AI

    private func maybeTriggerAI() {
        guard case .vsAI(let difficulty, let playerColor) = mode,
              !game.outcome.isGameOver,
              game.sideToMove != playerColor,
              !aiThinking
        else { return }

        aiThinking = true
        aiGeneration += 1
        let generation = aiGeneration
        let board = game.board
        let hashes = game.repetitionHashes
        let startTime = ContinuousClock.now

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
                        difficulty: difficulty, cancellation: cancellation
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }

            // A minimum "thinking" pause keeps fast moves feeling deliberate.
            let elapsed = ContinuousClock.now - startTime
            let minimum: Duration = .milliseconds(550)
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
            self.apply(result.move)
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
        pendingPromotion = nil

        game.undoLastMove()
        if case .vsAI(_, let playerColor) = mode {
            // Roll back to the human's turn.
            while game.sideToMove != playerColor, !game.history.isEmpty {
                game.undoLastMove()
            }
        }

        rebuildPieces()
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
        persist()
        handleGameOver()
    }

    /// Ends the game as a draw the two players have settled on. Offered only
    /// on a shared device: against the computer there is nobody to agree with,
    /// and an engine that accepted would be conceding a position it can see is
    /// winning (or refusing one it cannot).
    func agreeToDraw() {
        guard canAgreeToDraw else { return }
        stopPlayForEnding()
        game.agreeToDraw()
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
        deselect()
        pendingPromotion = nil
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

    // MARK: Persistence

    private func persist() {
        if game.outcome.isGameOver {
            SavedGame.clear()
            // Keep the finished game around so it can be reviewed later — but
            // only if there is something to review. Resigning before playing a
            // move is legal and leaves an empty move list, which the reviewer
            // has nothing to say about; the previous game stays on offer
            // instead of being replaced by a report that cannot be written.
            if !game.history.isEmpty {
                FinishedGame(game: game, mode: mode).save()
            }
        } else {
            SavedGame(
                mode: mode,
                initialFEN: game.initialFEN,
                moveUCIs: game.history.map(\.move.uci),
                savedAt: Date()
            ).save()
        }
    }

    /// Abandon without resigning (game stays saved for "continue").
    func teardown() {
        aiTask?.cancel()
        cancelHint()
        gameOverTask?.cancel()
        gameOverTask = nil
    }

#if DEBUG
    /// Development helper: plays a UCI move sequence through the same code
    /// path a human uses (selection, promotion picker), for screenshots.
    func playScriptedMoves(_ uciMoves: [String], interval: TimeInterval = 1.0) {
        Task { @MainActor [weak self] in
            for uci in uciMoves {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                guard let move = self.game.legalMoves.first(where: { $0.uci.hasPrefix(uci) }) else { return }
                self.select(move.from)
                self.attemptMove(from: move.from, to: move.to)
                if self.pendingPromotion != nil { return } // leave the picker open
            }
        }
    }
#endif
}
