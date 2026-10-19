//
//  PuzzleSessionModel.swift
//  chess
//
//  Drives a run of puzzles on the board: the setup move, judging each move,
//  the opponent's replies, hints and the solution, and what happens next —
//  another rated puzzle, the next one of a rush, the next of the player's
//  own mistakes.
//

import SwiftUI

@Observable
@MainActor
final class PuzzleSessionModel: PlayableBoard {

    // MARK: Kinds

    enum RushKind: String, CaseIterable, Identifiable, Sendable {
        case threeMinutes, fiveMinutes, survival

        var id: String { rawValue }

        /// Seconds on the clock, or nil for a rush that only ends on strikes.
        var duration: TimeInterval? {
            switch self {
            case .threeMinutes: return 180
            case .fiveMinutes: return 300
            case .survival: return nil
            }
        }
    }

    enum Kind: Hashable {
        /// Rated puzzles near the player's level, of one theme or of any.
        case rated(theme: String?)
        case daily
        case rush(RushKind)
        /// The player's own mistakes, newest first.
        case mistakes
    }

    enum Phase: Equatable {
        /// The opponent's setup move is about to be shown.
        case setup
        /// Waiting for the player's move.
        case playerToMove
        /// Right; the opponent's answer is on its way.
        case correct
        /// The engine is weighing a move the solution did not list.
        case checking
        /// Not the move. The board is back where it was.
        case wrong
        case solved
        /// The solution has been played out for the player.
        case shown
        /// A rush has ended.
        case rushOver
        /// There is nothing left to solve — every mistake fixed.
        case empty
    }

    let kind: Kind
    private let settings: AppSettings

    private(set) var attempt: PuzzleAttempt?
    private(set) var phase: Phase = .setup
    private(set) var displayBoard: Board = .initial
    private(set) var lastMove: Move?
    let layout = PieceLayout(board: .initial)

    var selectedSquare: Square?
    private(set) var legalTargets: [Move] = []
    var legalTargetSquares: [Move] { Self.uniqueTargets(legalTargets) }
    private(set) var pendingPromotion: [Move]?
    var isDragging = false

    private(set) var marks: [SquareMark] = []
    private(set) var arrows: [BoardArrow] = []

    /// The rating change of the current puzzle once it has been decided.
    private(set) var ratingChange: Double?
    /// Whether this puzzle has been entered into the rating yet. A rated
    /// puzzle counts once: as a failure at the first wrong move, hint or look
    /// at the solution, or when it is skipped, or as a success when it is
    /// solved cleanly.
    private var ratedRecorded = false
    private var hintUsed = false
    /// The current puzzle has been started again with Retry, as practice —
    /// see `retry`. Whatever the player does then, they have already seen
    /// it: it is neither rated nor counted as a mistake fixed.
    private var isRetry = false
    /// Whether this try at one of the player's mistakes has been written down
    /// — solved, missed or given up — so that it is written down once.
    private var mistakeRecorded = false
    /// The day the daily puzzle on the board belongs to, taken when it was
    /// set up. Solved after midnight, it still counts for the day it was.
    private var dailyDay: Int?

    // Rush state.
    private(set) var rushScore = 0
    private(set) var strikes = 0
    static let maxStrikes = 3
    private var rushQueue: [Puzzle] = []
    private var rushDeadline: TimeInterval?
    /// When the rush ended, so its clock stops where it did.
    private var rushEndedAt: TimeInterval?
    private var rushTask: Task<Void, Never>?
    private(set) var rushIsNewBest = false

    // Mistakes.
    private var mistakeQueue: [MistakeEntry] = []
    private(set) var currentMistake: MistakeEntry?

    private var pendingTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var generator = SystemRandomNumberGenerator()
    private let timeSource: () -> TimeInterval

    init(kind: Kind, settings: AppSettings,
         timeSource: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.kind = kind
        self.settings = settings
        self.timeSource = timeSource
        switch kind {
        case .rush(let rushKind):
            rushQueue = PuzzleLibrary.rushSequence(count: 160, using: &generator)
            if let duration = rushKind.duration { rushDeadline = timeSource() + duration }
            startRushWatch()
        case .mistakes:
            mistakeQueue = MistakeStore.shared.pending
        default:
            break
        }
        loadNext()
    }

    // MARK: PlayableBoard

    var position: Board { displayBoard }
    var orientation: PieceColor { attempt?.playerColor ?? .white }
    var checkedKingSquare: Square? {
        displayBoard.isInCheck ? Square(displayBoard.kingSquare(of: displayBoard.sideToMove)) : nil
    }
    var hintMove: Move? { nil }
    var hasPendingPromotion: Bool { pendingPromotion != nil }
    var decorations: BoardDecorations {
        BoardDecorations(arrows: arrows, marks: marks)
    }

    func isInteractive(color: PieceColor) -> Bool {
        guard phase == .playerToMove || phase == .wrong, pendingPromotion == nil,
              let attempt, !attempt.isSolved else { return false }
        return color == attempt.playerColor && displayBoard.sideToMove == color
    }

    func handleTap(on square: Square) {
        guard pendingPromotion == nil else { return }
        if let selected = selectedSquare {
            if selected == square { deselect(); return }
            if !Self.moves(from: selected, to: square, among: legalTargets, on: displayBoard).isEmpty {
                attemptMove(from: selected, to: square)
                return
            }
        }
        if let piece = displayBoard.piece(at: square), isInteractive(color: piece.color) {
            select(square)
        } else if selectedSquare != nil {
            deselect()
        }
    }

    func select(_ square: Square) {
        guard let piece = displayBoard.piece(at: square), isInteractive(color: piece.color) else { return }
        selectedSquare = square
        legalTargets = displayBoard.legalMoves(from: square)
        SoundManager.shared.play(.select)
        Haptics.pieceSelected()
    }

    func deselect() {
        selectedSquare = nil
        legalTargets = []
    }

    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool {
        // One of the player's own mistakes can come from a Chess960 game,
        // where castling is also reached by the king's landing square.
        let candidates = Self.moves(from: from, to: to, among: legalTargets, on: displayBoard)
        guard !candidates.isEmpty else { return false }
        if candidates.count > 1 {
            withAnimation(Motion.meaningful(.spring(duration: 0.3))) { pendingPromotion = candidates }
            return true
        }
        play(candidates[0])
        return true
    }

    func completePromotion(with kind: PieceKind) {
        guard let moves = pendingPromotion, let move = moves.first(where: { $0.promotion == kind }) else { return }
        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { pendingPromotion = nil }
        play(move)
    }

    func cancelPromotion() {
        withAnimation(Motion.meaningful(.spring(duration: 0.3))) { pendingPromotion = nil }
        deselect()
    }

    var promotionColor: PieceColor { attempt?.playerColor ?? .white }

    // MARK: Loading

    /// The puzzle to set up next, by kind. `skipped` holds the ones passed
    /// over on the way here because they would not set up, so that a rated
    /// pick does not land on one of them again.
    private func nextPuzzle(skipping skipped: Set<String>) -> Puzzle? {
        switch kind {
        case .rated(let theme):
            let progress = PuzzleStore.shared.progress
            return PuzzleLibrary.next(
                near: progress.rating, theme: theme, exclude: Set(progress.seen).union(skipped),
                avoiding: attempt?.puzzle.id, using: &generator
            )
        case .daily:
            let now = Date()
            dailyDay = PuzzleLibrary.dayNumber(for: now)
            return PuzzleLibrary.daily(for: now)
        case .rush:
            return rushQueue.isEmpty ? nil : rushQueue.removeFirst()
        case .mistakes:
            guard !mistakeQueue.isEmpty else { return nil }
            let entry = mistakeQueue.removeFirst()
            currentMistake = entry
            return entry.puzzle
        }
    }

    /// Sets up the next puzzle of the session.
    func loadNext() {
        guard phase != .rushOver else { return }
        // Moving on from a rated puzzle that has been put to the player and
        // not yet decided is giving it up: it counts as a miss, the way
        // asking for the solution does. Free, Next was a way out of any
        // puzzle that looked hard — and one never marked seen came round
        // again, still rated.
        settleBeforeLeaving()
        // A puzzle whose data does not hold up is skipped, not shown, and the
        // next one asked for — until one comes round that has been skipped
        // already, and the session ends as though there were none left. The
        // daily puzzle is the same one however often it is asked for: when
        // `load` skipped by calling back in here, one that would not set up
        // went round for ever.
        var skipped: Set<String> = []
        while let puzzle = nextPuzzle(skipping: skipped) {
            if load(puzzle) { return }
            guard skipped.insert(puzzle.id).inserted else { break }
        }
        // Whatever the last puzzle still had running goes with it. Next is
        // offered while the engine weighs a move, and a check left running
        // came back over "No mistakes left" up to four seconds later — with
        // the chime, the controls of a puzzle and nothing on the board.
        pendingTask?.cancel()
        checkTask?.cancel()
        deselect()
        marks = []
        arrows = []
        attempt = nil
        // And so does the mistake it came from: left in place, it went on
        // naming the move "you played" over "No mistakes left".
        currentMistake = nil
        if case .rush = kind {
            // Run out of puzzles: the rush is over, and recorded like any
            // other. Setting the phase first, as this used to, left
            // `endRush` nothing to do — and the score went unsaved.
            endRush()
        } else {
            // Never `.rushOver` outside a rush: that phase puts up the race's
            // result card, "Race Over" over a page of rated puzzles.
            phase = .empty
        }
    }

    /// Starts the same puzzle again. Before anything has gone wrong or been
    /// given away — no wrong move, hint or solution, not solved — it is the
    /// same attempt begun again, and still counts: Retry is there from the
    /// moment the puzzle is put, and tapped to watch the setup move again it
    /// made the clean solve that followed count for nothing, a mistake fixed
    /// that never got marked fixed. (A rated puzzle made unrated that way
    /// could also be played through at no cost and come round again rated.)
    ///
    /// After that it is practice, and counts for nothing — but what the try
    /// before it owed is paid first: a mistake puzzle got wrong and then
    /// retried went down as no attempt at all.
    ///
    /// A move the engine is still weighing has not gone wrong — nor right:
    /// it is undecided (see `hasGoneWrong`). Retry in those seconds wrote it
    /// down as a miss, though the engine might yet have taken it, while Next
    /// let even a wrong one go; both now leave it out, and both still count
    /// whatever went wrong before it.
    func retry() {
        guard let attempt else { return }
        let untouched = !hasGoneWrong && !attempt.isSolved
            && (phase == .playerToMove || phase == .correct || phase == .checking)
        guard !untouched else {
            load(attempt.puzzle, isRetry: isRetry)
            return
        }
        recordFailureIfRated()
        recordMistakeFailureIfOwed()
        load(attempt.puzzle, isRetry: true)
    }

    /// Puts `puzzle` on the board. Returns false, with nothing set up, for a
    /// puzzle whose data does not hold up, which `loadNext` then skips.
    /// `retry` need not ask: what it starts again has been set up before.
    @discardableResult
    private func load(_ puzzle: Puzzle, isRetry: Bool = false) -> Bool {
        pendingTask?.cancel()
        checkTask?.cancel()
        guard let fresh = PuzzleAttempt(puzzle: puzzle) else { return false }
        attempt = fresh
        ratingChange = nil
        self.isRetry = isRetry
        // A rated puzzle seen before — every one in a theme has been, once the
        // theme is used up — is played unrated: one already solved and solved
        // again would otherwise lift the rating as often as it came round.
        ratedRecorded = isRetry
            || (puzzle.source == .library && PuzzleStore.shared.progress.seen.contains(puzzle.id))
        hintUsed = false
        mistakeRecorded = false
        marks = []
        arrows = []
        deselect()

        let before = Game(fen: puzzle.fen)
        displayBoard = before.board
        lastMove = nil
        layout.rebuild(from: before.board)

        guard let setupUCI = puzzle.setup,
              let setup = before.legalMoves.first(where: { $0.uci == setupUCI }) else {
            displayBoard = fresh.game.board
            layout.rebuild(from: fresh.game.board)
            phase = .playerToMove
            return true
        }
        phase = .setup
        // The setup move is played a beat after the position appears, so the
        // player sees what the opponent did rather than a position already
        // changed under them.
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, !Task.isCancelled else { return }
            self.animate(setup, from: before.board)
            self.phase = .playerToMove
            self.announceToMove(after: setup, from: before.board)
        }
        return true
    }

    private func animate(_ move: Move, from board: Board) {
        layout.apply(move, before: board, animation: Motion.meaningful(.spring(duration: 0.35, bounce: 0.15)))
        var next = board
        next.make(move)
        displayBoard = next
        lastMove = move
        SoundManager.shared.play(for: move, isCheck: next.isInCheck)
    }

    /// Says the puzzle is ready — and, first, what the opponent's setup move
    /// was, since that is the move the puzzle is an answer to and a VoiceOver
    /// player only saw the board change.
    private func announceToMove(after setup: Move, from board: Board) {
        guard let attempt else { return }
        let side = sideName(attempt.playerColor)
        let ready = String(localized: "announce.puzzleToMove",
                           defaultValue: "Find the best move for \(side)",
                           comment: "Spoken when a puzzle is ready")
        let played = BoardSpeech.movedAnnouncement(setup, san: board.san(for: setup))
        AccessibilityNotification.Announcement(played + ". " + ready).post()
    }

    /// Speaks a move the opponent (or the solution) has just played on the
    /// board, which a VoiceOver player cannot watch happen.
    private func announce(_ move: Move, from board: Board) {
        AccessibilityNotification.Announcement(
            BoardSpeech.movedAnnouncement(move, san: board.san(for: move))
        ).post()
    }

    // MARK: Judging

    private func play(_ move: Move) {
        // Only a move the player is being asked for is judged. Once the
        // solution is shown, or the puzzle is over, there is none.
        guard var current = attempt, phase == .playerToMove || phase == .wrong else {
            deselect()
            return
        }
        deselect()
        marks = []
        arrows = []
        let before = current.game.board
        let verdict = current.play(move)
        switch verdict {
        case .correct(let reply):
            attempt = current
            animate(move, from: before)
            marks = [SquareMark(square: move.to, kind: .correct)]
            phase = .correct
            Haptics.pieceMoved()
            let afterPlayer = displayBoard
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.marks = []
                self.animate(reply, from: afterPlayer)
                self.phase = .playerToMove
                self.announce(reply, from: afterPlayer)
            }
        case .solved:
            attempt = current
            animate(move, from: before)
            marks = [SquareMark(square: move.to, kind: .correct)]
            finishSolved()
        case .wrong(let expected):
            if current.puzzle.source == .mistake, !isOriginalMistake(move, in: current) {
                // The player's own position may have more than one good move;
                // the engine is asked before the answer is called wrong. The
                // copy that has already called it wrong is let go: `attempt`
                // takes whichever verdict the engine gives (see `hasGoneWrong`).
                checkAlternative(move, expected: expected, before: before)
            } else {
                attempt = current
                showWrong(move, before: before)
            }
        }
    }

    /// `alreadyShown` when the move is on the board already — it was played
    /// out while the engine was asked about it.
    private func showWrong(_ move: Move, before: Board, alreadyShown: Bool = false) {
        if !alreadyShown { animate(move, from: before) }
        marks = [SquareMark(square: move.to, kind: .wrong)]
        phase = .wrong
        SoundManager.shared.play(.failure)
        Haptics.illegal()
        AccessibilityNotification.Announcement(
            String(localized: "announce.puzzleWrong", defaultValue: "Not the move. Try again.",
                   comment: "Spoken after a wrong puzzle move")
        ).post()
        recordFailureIfRated()
        if case .rush = kind {
            strikes += 1
        }
        // The wrong move is shown, then taken back.
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, !Task.isCancelled else { return }
            self.displayBoard = before
            self.lastMove = nil
            self.layout.sync(to: before, animation: Motion.meaningful(.spring(duration: 0.3)))
            if case .rush = self.kind {
                if self.strikes >= Self.maxStrikes {
                    self.endRush()
                } else {
                    self.loadNext()
                }
            }
        }
    }

    /// Whether `move` is the one the player actually made in the game — the
    /// mistake this puzzle is about. That one is wrong without asking: the
    /// check below searches a quarter of the nodes the review did, and a
    /// shallower search can miss what made it a mistake and call it as good
    /// as the answer, marking the mistake fixed by playing it again.
    private func isOriginalMistake(_ move: Move, in attempt: PuzzleAttempt) -> Bool {
        guard let currentMistake, currentMistake.id.uuidString == attempt.puzzle.id,
              let original = attempt.legalMove(named: currentMistake.playedSAN)
        else { return false }
        return move == original
    }

    private func checkAlternative(_ move: Move, expected: Move, before: Board) {
        animate(move, from: before)
        phase = .checking
        let board = before
        let cancellation = SearchCancellation()
        checkTask = Task { [weak self] in
            // The search cannot see this task's cancellation by itself. The
            // token is how Retry, Next or closing the puzzle stops it, rather
            // than leaving up to four seconds of it running behind each tap.
            let analysis = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    analyzePosition(
                        board: board, gameHashes: [board.zobrist], maxDepth: 12,
                        nodeBudget: 250_000, timeLimit: 4, focusMove: move,
                        cancellation: cancellation
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            if let analysis, let played = analysis.focusScore {
                let lost = WinChance.percent(centipawns: analysis.bestScore) - WinChance.percent(centipawns: played)
                if lost <= 3 {
                    if var current = self.attempt {
                        _ = current.acceptAlternative(move)
                        self.attempt = current
                    }
                    self.marks = [SquareMark(square: move.to, kind: .correct)]
                    self.finishSolved()
                    return
                }
            }
            self.attempt?.giveUp()
            self.showWrong(move, before: before, alreadyShown: true)
        }
    }

    private func finishSolved() {
        phase = .solved
        SoundManager.shared.play(.success)
        Haptics.success()
        AccessibilityNotification.Announcement(
            String(localized: "announce.puzzleSolved", defaultValue: "Solved!",
                   comment: "Spoken when a puzzle is solved")
        ).post()
        guard let attempt else { return }
        let clean = !attempt.hadMistake && !hintUsed && !isRetry
        switch kind {
        case .rated:
            if !ratedRecorded {
                ratedRecorded = true
                ratingChange = PuzzleStore.shared.recordRated(attempt.puzzle, solved: clean)
            }
        case .daily:
            // The daily puzzle counts for the streak however it was solved;
            // the streak is about turning up, not about the first try. Only
            // a clean solve counts towards the puzzles solved, though.
            PuzzleStore.shared.recordDailySolved(
                attempt.puzzle, day: dailyDay ?? PuzzleLibrary.dayNumber(for: Date()), clean: clean
            )
        case .rush:
            rushScore += 1
            PuzzleStore.shared.markSeen(attempt.puzzle)
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.loadNext()
            }
        case .mistakes:
            // A retry comes after the answer has been seen or missed, so it
            // proves nothing either way and is not written down.
            if let currentMistake, !isRetry, !mistakeRecorded {
                mistakeRecorded = true
                MistakeStore.shared.recordAttempt(currentMistake.id, solved: clean)
            }
        }
    }

    private func recordFailureIfRated() {
        guard case .rated = kind, !ratedRecorded, let attempt else { return }
        ratedRecorded = true
        ratingChange = PuzzleStore.shared.recordRated(attempt.puzzle, solved: false)
    }

    /// What leaving the puzzle on the board owes: a rated one put to the
    /// player and undecided is a miss, and one of the player's mistakes that
    /// has already gone wrong, or needed a hint, is an attempt that did not
    /// fix it. A mistake skipped untried owes nothing — the list is theirs to
    /// look through. Before the setup move is in, nothing has been put yet.
    private func settleBeforeLeaving() {
        guard phase != .setup, attempt != nil else { return }
        recordFailureIfRated()
        if hasGoneWrong { recordMistakeFailureIfOwed() }
    }

    /// Whether this try has already gone wrong or been helped: a wrong move,
    /// a hint, the solution shown. The move the engine is weighing is not
    /// among them. `attempt` takes it only once the engine has given its
    /// verdict (see `checkAlternative`), so until then it is as though it
    /// had not been played — it may turn out as good as the answer — and
    /// Retry, Next and closing the page all owe only what came before it.
    private var hasGoneWrong: Bool {
        hintUsed || attempt?.hadMistake == true
    }

    /// `recordFailureIfRated` for one of the player's own mistakes: a try
    /// that went wrong, or was given up, is an attempt that did not fix it.
    /// A retry proves nothing either way and is never written down.
    private func recordMistakeFailureIfOwed() {
        guard case .mistakes = kind, !isRetry, !mistakeRecorded, let currentMistake else { return }
        mistakeRecorded = true
        MistakeStore.shared.recordAttempt(currentMistake.id, solved: false)
    }

    // MARK: Help

    /// Points at the piece that has to move. Costs the puzzle its rating.
    func showHint() {
        guard phase == .playerToMove || phase == .wrong, let expected = attempt?.expectedMove else { return }
        hintUsed = true
        recordFailureIfRated()
        marks = [SquareMark(square: expected.from, kind: .hint)]
        Haptics.pieceSelected()
        // The hint is a marked square; said out loud, it is the square.
        let square = expected.from.spokenName
        AccessibilityNotification.Announcement(
            String(localized: "announce.puzzleHint", defaultValue: "Hint: move the piece on \(square)",
                   comment: "Spoken when a puzzle hint marks the piece to move, e.g. 'Hint: move the piece on e 2'")
        ).post()
    }

    var canShowHint: Bool {
        (phase == .playerToMove || phase == .wrong) && !hintUsed
    }

    /// Plays the rest of the solution out, move by move.
    func showSolution() {
        guard var current = attempt, phase == .playerToMove || phase == .wrong else { return }
        pendingTask?.cancel()
        // Cancelling the task above can cancel the step that takes a wrong
        // move back, so it is taken back here: the solution is played from
        // the attempt's position, and the board has to show that one.
        if phase == .wrong {
            let board = current.game.board
            displayBoard = board
            lastMove = nil
            layout.sync(to: board, animation: Motion.meaningful(.spring(duration: 0.3)))
        }
        current.giveUp()
        attempt = current
        recordFailureIfRated()
        recordMistakeFailureIfOwed()
        phase = .shown
        marks = []
        // A piece picked up before Solution was tapped is put down with it.
        // Its dots stayed on the board, and a tap on one played the move into
        // the solution: over the end of it, as "Solved!" — and the day's
        // streak, for a daily puzzle given up.
        deselect()
        pendingPromotion = nil
        pendingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard var attempt = self.attempt else { return }
                let before = attempt.game.board
                guard let move = attempt.playNextSolutionMove() else { return }
                self.attempt = attempt
                self.animate(move, from: before)
                self.announce(move, from: before)
                if attempt.isSolved {
                    self.arrows = [BoardArrow(from: move.from, to: move.to, kind: .best)]
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: Rush

    var rushTimeLeft: TimeInterval? {
        rushDeadline.map { max(0, $0 - (rushEndedAt ?? timeSource())) }
    }

    var rushKind: RushKind? {
        if case .rush(let rushKind) = kind { return rushKind }
        return nil
    }

    private func startRushWatch() {
        guard rushDeadline != nil else { return }
        rushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let left = self.rushTimeLeft else { return }
                if left <= 0 {
                    self.endRush()
                    return
                }
                try? await Task.sleep(for: .seconds(min(0.25, left)))
            }
        }
    }

    private func endRush() {
        guard phase != .rushOver, let rushKind else { return }
        rushTask?.cancel()
        pendingTask?.cancel()
        deselect()
        rushEndedAt = timeSource()
        phase = .rushOver
        rushIsNewBest = PuzzleStore.shared.recordRush(kind: rushKind.rawValue, score: rushScore)
        SoundManager.shared.play(rushIsNewBest ? .win : .draw)
    }

    // MARK: Status

    /// What the card under the board says.
    var prompt: String {
        guard let attempt else {
            guard phase == .empty else { return "" }
            return kind == .mistakes
                ? String(localized: "No mistakes left to fix — review a game to find more.")
                : String(localized: "No puzzle could be set up here.")
        }
        let side = sideName(attempt.playerColor)
        switch phase {
        case .setup:
            return String(localized: "Watch the opponent's move…")
        case .playerToMove:
            return String(localized: "Find the best move for \(side)")
        case .correct:
            return String(localized: "Correct — keep going")
        case .checking:
            return String(localized: "Checking your move…")
        case .wrong:
            return String(localized: "Not the move. Try again.")
        case .solved:
            return String(localized: "Solved!")
        case .shown:
            return String(localized: "This was the solution.")
        case .rushOver:
            return String(localized: "Time's up!")
        case .empty:
            return ""
        }
    }

    /// The side in "find the best move for …". Its own pair of strings
    /// rather than `PieceColor.spokenName`: Czech needs the accusative there
    /// (*za bílého*), which the nominative used elsewhere would get wrong.
    private func sideName(_ color: PieceColor) -> String {
        color == .white
            ? String(localized: "puzzle.side.white", defaultValue: "White", comment: "Side to find the move for, as in 'Find the best move for White'")
            : String(localized: "puzzle.side.black", defaultValue: "Black", comment: "Side to find the move for, as in 'Find the best move for Black'")
    }

    func teardown() {
        // Leaving a rated puzzle that is on the board and undecided gives it
        // up, as Next does. The next one is drawn at random, so closing the
        // page and opening it again was the same free way out.
        settleBeforeLeaving()
        pendingTask?.cancel()
        checkTask?.cancel()
        rushTask?.cancel()
#if DEBUG
        autosolveTask?.cancel()
#endif
        layout.cancelFades()
    }

#if DEBUG
    private var autosolveTask: Task<Void, Never>?

    /// Development helper: plays every one of the player's moves itself,
    /// `delay` after the board is handed over, through the same selection a
    /// tap makes — `--puzzle-autosolve=`, for the App Preview's rush.
    func autosolve(after delay: TimeInterval) {
        autosolveTask = Task { [weak self] in
            // Every wait throws on cancellation and ends the loop: `try?`
            // swallowed it, and a session torn down mid-wait went on to play
            // one more move and start an answer nobody would cancel.
            do {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    guard self.phase == .playerToMove, let move = self.attempt?.expectedMove else { continue }
                    try await Task.sleep(for: .seconds(delay))
                    guard self.phase == .playerToMove, self.attempt?.expectedMove == move else { continue }
                    self.select(move.from)
                    // Long enough for the selection to be seen being made.
                    try await Task.sleep(for: .milliseconds(250))
                    guard self.phase == .playerToMove, self.attempt?.expectedMove == move else { continue }
                    self.play(move)
                }
            } catch {}
        }
    }
#endif
}
