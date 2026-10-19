//
//  TrainingModels.swift
//  chess
//
//  The models behind the training screens: the opening trainer, which plays
//  a book line against the player and checks every move of theirs, and the
//  analysis board, where anything can be played and the engine says what it
//  thinks of it.
//

import SwiftUI

// MARK: - Opening lines to train

/// A line of the opening book offered for training.
struct TrainingLine: Identifiable, Hashable {
    /// The moves, which are also what identifies the line in the progress.
    let id: String
    /// A resource rather than words: `all` is a `static let`, and a resolved
    /// string in it would keep whatever language first asked — the reason
    /// `OpeningBook.Line` holds its names this way too.
    let resource: LocalizedStringResource
    let sans: [String]

    var name: String { String(localized: resource) }

    static func == (lhs: TrainingLine, rhs: TrainingLine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Which group of the list it belongs to.
    var family: String {
        switch sans.first {
        case "e4": return "1.e4"
        case "d4": return "1.d4"
        default: return String(localized: "Other first moves", comment: "Opening trainer group")
        }
    }

    /// The side the line belongs to: a defence is Black's, everything else
    /// is the side that plays its last move.
    var defaultColor: PieceColor {
        sans.count.isMultiple(of: 2) ? .black : .white
    }

    /// Every line of the book worth training: four plies at least, and not
    /// merely the start of a longer line — learning the Najdorf teaches the
    /// Sicilian on the way.
    static let all: [TrainingLine] = {
        let lines = OpeningBook.lines
        let moveLists = lines.map { $0.moves }
        return lines.compactMap { line in
            guard line.moves.count >= 4 else { return nil }
            let isPrefix = moveLists.contains { other in
                other.count > line.moves.count && Array(other.prefix(line.moves.count)) == line.moves
            }
            guard !isPrefix else { return nil }
            return TrainingLine(id: line.moves.joined(separator: " "), resource: line.name, sans: line.moves)
        }
    }()
}

/// How the player stands with each line.
struct OpeningProgress: Codable, Hashable, Sendable {
    /// Per line id: `[times completed, times completed without a mistake]`.
    var results: [String: [Int]] = [:]

    func isLearned(_ line: TrainingLine) -> Bool { (results[line.id]?[1] ?? 0) >= 1 }
    func isMastered(_ line: TrainingLine) -> Bool { (results[line.id]?[1] ?? 0) >= 3 }
    var learnedCount: Int { results.values.count { $0[1] >= 1 } }
}

extension OpeningProgress {
    // Line by line, in an extension so the memberwise initializer stays: an
    // entry that does not read costs only its own line, not the record of
    // every opening learned. An entry shorter than the pair every reader
    // indexes into is left out with it, rather than kept to trap on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([String: Lossy<[Int]>].self, forKey: .results) ?? [:]
        results = stored.compactMapValues { entry in
            entry.value.flatMap { $0.count >= 2 ? $0 : nil }
        }
    }
}

@Observable
@MainActor
final class OpeningProgressStore {
    static let shared = OpeningProgressStore()
    private static let key = "openingProgress"
    @ObservationIgnored private var mirror: OpeningProgress?
    @ObservationIgnored private var mirrorSource: UserDefaults?
    private(set) var revision = 0

    private init() {}

    var progress: OpeningProgress {
        _ = revision
        let store = LocalStore.defaults
        if let mirror, mirrorSource === store { return mirror }
        let loaded = LocalStore.value(OpeningProgress.self, forKey: Self.key) ?? OpeningProgress()
        mirror = loaded
        mirrorSource = store
        return loaded
    }

    func record(_ line: TrainingLine, clean: Bool) {
        var value = progress
        var result = value.results[line.id] ?? [0, 0]
        result[0] += 1
        if clean { result[1] += 1 }
        value.results[line.id] = result
        mirror = value
        mirrorSource = LocalStore.defaults
        if let data = try? JSONEncoder().encode(value) {
            LocalStore.defaults.set(data, forKey: Self.key)
        }
        revision += 1
        Achievements.shared.openingsLearned(value.learnedCount)
    }
}

// MARK: - Opening trainer

@Observable
@MainActor
final class OpeningTrainerModel: PlayableBoard {
    enum Phase: Equatable {
        case opponentToMove
        case playerToMove
        case wrong
        case complete
    }

    let line: TrainingLine
    let playerColor: PieceColor
    private(set) var game = Game()
    private(set) var phase: Phase = .opponentToMove
    private(set) var mistakes = 0
    private(set) var marks: [SquareMark] = []
    private(set) var arrows: [BoardArrow] = []
    let layout = PieceLayout(board: .initial)

    var selectedSquare: Square?
    private(set) var legalTargets: [Move] = []
    var legalTargetSquares: [Move] { Self.uniqueTargets(legalTargets) }
    var isDragging = false
    private var pendingTask: Task<Void, Never>?

    init(line: TrainingLine, playerColor: PieceColor) {
        self.line = line
        self.playerColor = playerColor
        advance()
    }

    var position: Board { game.board }
    var orientation: PieceColor { playerColor }
    var lastMove: Move? { game.lastMove }
    var checkedKingSquare: Square? {
        game.isInCheck ? Square(game.board.kingSquare(of: game.sideToMove)) : nil
    }
    var hintMove: Move? { nil }
    var hasPendingPromotion: Bool { false }
    var decorations: BoardDecorations { BoardDecorations(arrows: arrows, marks: marks) }

    /// How far into the line the board stands, in plies.
    var ply: Int { game.history.count }

    /// The book move due next, as a move of this position.
    var expectedMove: Move? {
        guard ply < line.sans.count else { return nil }
        let legal = game.legalMoves
        let target = Self.normalized(line.sans[ply])
        return legal.first { Self.normalized(game.board.san(for: $0, legalMoves: legal)) == target }
    }

    private static func normalized(_ san: String) -> String {
        san.filter { !"+#!?".contains($0) }
    }

    func isInteractive(color: PieceColor) -> Bool {
        (phase == .playerToMove || phase == .wrong) && color == playerColor && game.sideToMove == color
    }

    func handleTap(on square: Square) {
        if let selected = selectedSquare {
            if selected == square { deselect(); return }
            if legalTargets.contains(where: { $0.to == square }) {
                attemptMove(from: selected, to: square)
                return
            }
        }
        if let piece = game.board.piece(at: square), isInteractive(color: piece.color) {
            select(square)
        } else {
            deselect()
        }
    }

    func select(_ square: Square) {
        guard let piece = game.board.piece(at: square), isInteractive(color: piece.color) else { return }
        selectedSquare = square
        legalTargets = game.legalMoves(from: square)
        SoundManager.shared.play(.select)
    }

    func deselect() {
        selectedSquare = nil
        legalTargets = []
    }

    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool {
        let candidates = legalTargets.filter { $0.from == from && $0.to == to }
        guard let move = candidates.first(where: { $0.promotion == nil || $0.promotion == .queen }) else { return false }
        deselect()
        guard let expected = expectedMove else { return true }
        if move == expected {
            marks = [SquareMark(square: move.to, kind: .correct)]
            arrows = []
            play(move)
            advance()
        } else {
            mistakes += 1
            phase = .wrong
            marks = [SquareMark(square: move.to, kind: .wrong)]
            SoundManager.shared.play(.failure)
            Haptics.illegal()
            var spoken = String(localized: "That is not the book move. Try again.")
            // Two wrong tries and the book move is drawn on the board.
            if mistakes >= 2 {
                arrows = [BoardArrow(from: expected.from, to: expected.to, kind: .best)]
                spoken += " " + bookMoveAnnouncement(expected)
            }
            AccessibilityNotification.Announcement(spoken).post()
        }
        return true
    }

    /// Draws the move theory expects.
    func showMove() {
        guard let expected = expectedMove, phase == .playerToMove || phase == .wrong else { return }
        mistakes += 1
        arrows = [BoardArrow(from: expected.from, to: expected.to, kind: .best)]
        // The arrow is all a sighted player gets; said out loud, it is the move.
        AccessibilityNotification.Announcement(bookMoveAnnouncement(expected)).post()
    }

    private func bookMoveAnnouncement(_ move: Move) -> String {
        let spoken = BoardSpeech.spokenMove(move, on: game.board)
        return String(localized: "announce.bookMove", defaultValue: "The book move is \(spoken).",
                      comment: "Spoken when the opening trainer shows the expected move, e.g. 'The book move is knight f 3.'")
    }

    private func play(_ move: Move) {
        layout.apply(move, before: game.board, animation: Motion.meaningful(.spring(duration: 0.35, bounce: 0.15)))
        game.play(move)
        SoundManager.shared.play(for: move, isCheck: game.isInCheck)
    }

    /// Plays the opponent's book moves, then waits for the player.
    private func advance() {
        guard ply < line.sans.count else {
            phase = .complete
            OpeningProgressStore.shared.record(line, clean: mistakes == 0)
            SoundManager.shared.play(.success)
            Haptics.success()
            return
        }
        if game.sideToMove == playerColor {
            phase = .playerToMove
            return
        }
        phase = .opponentToMove
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard let self, !Task.isCancelled, let move = self.expectedMove else { return }
            self.marks = []
            self.play(move)
            // The book's reply lands on a board a VoiceOver player cannot
            // watch; it is the move they have to answer.
            if let played = self.game.history.last {
                AccessibilityNotification.Announcement(
                    BoardSpeech.movedAnnouncement(played.move, san: played.san)
                ).post()
            }
            self.advance()
        }
    }

    func restart() {
        pendingTask?.cancel()
        game = Game()
        layout.rebuild(from: game.board)
        mistakes = 0
        marks = []
        arrows = []
        deselect()
        advance()
    }

    func teardown() {
        pendingTask?.cancel()
        layout.cancelFades()
    }
}

// MARK: - Analysis board

@Observable
@MainActor
final class AnalysisBoardModel: PlayableBoard {

    /// Every position of the line on the board, from the start: index 0 is
    /// the starting position, index i the position after move i.
    private(set) var positions: [Game]
    /// Which of them is shown.
    private(set) var plyIndex: Int
    let layout: PieceLayout

    var selectedSquare: Square?
    private(set) var legalTargets: [Move] = []
    var legalTargetSquares: [Move] { Self.uniqueTargets(legalTargets) }
    private(set) var pendingPromotion: [Move]?
    var isDragging = false
    /// The colour at the bottom. Opened from a game, it is the side the
    /// review showed there — Black's player turned White-up the moment they
    /// went to analyse a position of theirs.
    var orientation: PieceColor

    // Engine.
    var engineEnabled = true {
        didSet { engineEnabled ? analyzeCurrent() : stopEngine() }
    }
    /// Evaluation from White's point of view, once the engine has one.
    private(set) var evaluation: Int?
    private(set) var bestMove: Move?
    private(set) var bestSAN: String?
    private(set) var depth = 0
    private(set) var isThinking = false
    private var analysisTask: Task<Void, Never>?
    private var cancellation: SearchCancellation?

    convenience init(game: Game, startAtEnd: Bool = true, orientation: PieceColor = .white) {
        self.init(game: game, startPly: startAtEnd ? game.history.count : 0, orientation: orientation)
    }

    init(game: Game, startPly: Int, orientation: PieceColor = .white) {
        // The positions of the given game, replayed from its start so every
        // one carries the repetition history that applies to it.
        var replay = game.atStart
        var positions = [replay]
        for played in game.history {
            replay.play(played.move)
            positions.append(replay)
        }
        self.positions = positions
        let start = max(0, min(positions.count - 1, startPly))
        self.plyIndex = start
        self.layout = PieceLayout(board: positions[start].board)
        self.orientation = orientation
        analyzeCurrent()
    }

    convenience init(fen: String, orientation: PieceColor = .white) {
        self.init(game: Game(fen: fen), orientation: orientation)
    }

    var game: Game { positions[plyIndex] }
    var position: Board { game.board }
    var lastMove: Move? { game.lastMove }
    var checkedKingSquare: Square? {
        game.isInCheck ? Square(game.board.kingSquare(of: game.sideToMove)) : nil
    }
    var hintMove: Move? { nil }
    var hasPendingPromotion: Bool { pendingPromotion != nil }

    var decorations: BoardDecorations {
        var decorations = BoardDecorations()
        if game.variant == .kingOfTheHill { decorations.zone = Board.hillSquares.map(Square.init) }
        guard engineEnabled, let bestMove else { return decorations }
        let squares = game.board.displaySquares(of: bestMove)
        decorations.arrows = [BoardArrow(from: squares.from, to: squares.to, kind: .best)]
        return decorations
    }

    /// The moves of the whole line, as played.
    var line: [PlayedMove] { positions.last?.history ?? [] }

    var canStepBack: Bool { plyIndex > 0 }
    var canStepForward: Bool { plyIndex < positions.count - 1 }

    /// Whether a game can be started from the position on the board. Asking
    /// the line is not enough: a game read from PGN leaves a fifty-move draw
    /// to be claimed, while a game begun from one of its positions settles it,
    /// so a position with a halfmove clock of a hundred or more started a game
    /// that was over before its first move — on a frozen board, with no
    /// result to show.
    var canPlayFromHere: Bool {
        !game.outcome.isGameOver && !Game(fen: game.board.fen, variant: game.variant).outcome.isGameOver
    }

    func isInteractive(color: PieceColor) -> Bool {
        pendingPromotion == nil && !game.outcome.isGameOver && color == game.sideToMove
    }

    func handleTap(on square: Square) {
        guard pendingPromotion == nil else { return }
        if let selected = selectedSquare {
            if selected == square { deselect(); return }
            if !Self.moves(from: selected, to: square, among: legalTargets, on: game.board).isEmpty {
                attemptMove(from: selected, to: square)
                return
            }
        }
        if let piece = game.board.piece(at: square), isInteractive(color: piece.color) {
            select(square)
        } else {
            deselect()
        }
    }

    func select(_ square: Square) {
        guard let piece = game.board.piece(at: square), isInteractive(color: piece.color) else { return }
        selectedSquare = square
        legalTargets = game.legalMoves(from: square)
        SoundManager.shared.play(.select)
    }

    func deselect() {
        selectedSquare = nil
        legalTargets = []
    }

    @discardableResult
    func attemptMove(from: Square, to: Square) -> Bool {
        let candidates = Self.moves(from: from, to: to, among: legalTargets, on: game.board)
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

    var promotionColor: PieceColor { game.sideToMove }

    /// Plays a move from the position shown. When that is not the end of the
    /// line, the moves after it are replaced — the board holds one line, and
    /// a new move starts a new one from here.
    private func play(_ move: Move) {
        deselect()
        // The same move as the line already continues with is just a step.
        if canStepForward, positions[plyIndex + 1].lastMove == move {
            stepForward()
            return
        }
        var next = game
        layout.apply(move, before: next.board, animation: Motion.meaningful(.spring(duration: 0.32, bounce: 0.15)))
        next.play(move)
        positions = Array(positions.prefix(plyIndex + 1)) + [next]
        plyIndex += 1
        SoundManager.shared.play(for: move, isCheck: next.isInCheck)
        announceArrival(byMove: true)
        analyzeCurrent()
    }

    func stepForward() {
        guard canStepForward else { return }
        let move = positions[plyIndex + 1].lastMove!
        layout.apply(move, before: game.board, animation: Motion.meaningful(.spring(duration: 0.3, bounce: 0.15)))
        plyIndex += 1
        SoundManager.shared.play(for: move, isCheck: game.isInCheck)
        deselect()
        announceArrival(byMove: true)
        analyzeCurrent()
    }

    func stepBack() {
        guard canStepBack else { return }
        plyIndex -= 1
        layout.sync(to: game.board, animation: Motion.meaningful(.spring(duration: 0.3, bounce: 0.15)))
        SoundManager.shared.play(.move)
        deselect()
        announceArrival(byMove: false)
        analyzeCurrent()
    }

    func go(to ply: Int) {
        let target = max(0, min(positions.count - 1, ply))
        guard target != plyIndex else { return }
        if target == plyIndex + 1 { stepForward(); return }
        plyIndex = target
        layout.sync(to: game.board, animation: Motion.meaningful(.easeInOut(duration: 0.25)))
        deselect()
        announceArrival(byMove: false)
        analyzeCurrent()
    }

    /// Says where the board has got to, which a VoiceOver player cannot
    /// watch — the game, the puzzles and the trainer all speak their moves,
    /// and the analysis board was silent. A move played or stepped into is
    /// read as a move, with the result when it ends the game; a step back or
    /// a jump is read as the move the position on the board came from.
    private func announceArrival(byMove: Bool) {
        let spoken: String
        if byMove, let played = game.history.last {
            spoken = BoardSpeech.announcement(for: played, outcome: game.outcome, mode: .twoPlayer)
        } else {
            spoken = BoardSpeech.position(after: game.history.last)
        }
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// Plays the engine's choice.
    func playBestMove() {
        guard let bestMove, game.legalMoves.contains(bestMove) else { return }
        play(bestMove)
    }

    /// Replaces the line with a position from the editor, under the rules
    /// the board was already playing by.
    func load(fen: String) {
        let start = Game(fen: fen, variant: game.variant)
        positions = [start]
        plyIndex = 0
        deselect()
        pendingPromotion = nil
        layout.sync(to: start.board, animation: Motion.meaningful(.easeInOut(duration: 0.25)))
        analyzeCurrent()
    }

    // MARK: Engine

    /// Searches the position shown, deeper and deeper, until the position
    /// changes or the engine is switched off. Each pass is a complete search
    /// with a larger node budget, so what is on screen is always a finished
    /// answer rather than a half-searched one.
    private func analyzeCurrent() {
        stopEngine()
        evaluation = nil
        bestMove = nil
        bestSAN = nil
        depth = 0
        guard engineEnabled else { return }
        let game = self.game
        guard !game.outcome.isGameOver else {
            evaluation = game.outcome.winner.map { $0 == .white ? SearchScore.mate : -SearchScore.mate } ?? 0
            return
        }
        let board = game.board
        let hashes = game.repetitionHashes
        let token = SearchCancellation()
        cancellation = token
        isThinking = true
        analysisTask = Task { [weak self] in
            for budget in [60_000, 300_000, 1_200_000, 4_000_000] {
                let result = await Task.detached(priority: .userInitiated) {
                    analyzePosition(
                        board: board, gameHashes: hashes, maxDepth: 40,
                        nodeBudget: budget, timeLimit: 30, cancellation: token
                    )
                }.value
                guard let self, !Task.isCancelled, !token.isCancelled, let result else { return }
                let white = board.sideToMove == .white ? result.bestScore : -result.bestScore
                withAnimation(.easeOut(duration: 0.25)) {
                    self.evaluation = white
                    self.bestMove = result.bestMove
                    self.bestSAN = board.san(for: result.bestMove)
                    self.depth = result.depth
                }
                if SearchScore.isMate(result.bestScore) { break }
            }
            self?.isThinking = false
        }
    }

    private func stopEngine() {
        cancellation?.cancel()
        cancellation = nil
        analysisTask?.cancel()
        analysisTask = nil
        isThinking = false
    }

    /// Starts the engine again after `teardown`, unless it is running or has
    /// already finished with this position.
    func resumeEngine() {
        guard engineEnabled, analysisTask == nil else { return }
        analyzeCurrent()
    }

    func teardown() {
        stopEngine()
        layout.cancelFades()
    }
}
