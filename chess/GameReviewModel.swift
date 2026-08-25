//
//  GameReviewModel.swift
//  chess
//
//  Drives the post-game review: runs the engine over every position of the
//  finished game, then lets the player walk back through it move by move.
//

import SwiftUI

@Observable
@MainActor
final class GameReviewModel: Identifiable {

    // MARK: Render model

    /// A piece with a stable identity so stepping through the game animates.
    struct RenderPiece: Identifiable {
        let id: UUID
        var piece: Piece
        var square: Square
    }

    // MARK: State

    let game: Game
    let mode: GameMode

    /// Positions of the game: index 0 is the start, index i the position after
    /// move i.
    private(set) var boards: [Board]
    private let jobs: [GameAnalyzer.Job]

    private(set) var analysis: GameAnalysis?
    /// 0...1 while the engine works, 1 when the report is complete.
    private(set) var progress: Double = 0
    private(set) var isAnalyzing = false

    /// Which position is on the board: 0 = start, n = after the nth move.
    private(set) var plyIndex: Int
    private(set) var pieces: [RenderPiece] = []

    private(set) var isAutoplaying = false
    var manualFlip = false

    private var analysisTask: Task<Void, Never>?
    /// Stops the searches themselves, not just the task waiting on them.
    private var analysisCancellation: SearchCancellation?
    private var autoplayTask: Task<Void, Never>?

    // MARK: Init

    init(game: Game, mode: GameMode) {
        self.game = game
        self.mode = mode
        self.jobs = GameAnalyzer.positions(of: game)
        self.boards = jobs.map(\.board)
        // Open on the final position, the way the game just ended.
        self.plyIndex = game.history.count
        rebuildPieces()
    }

    // MARK: Derived state

    var moveCount: Int { game.history.count }

    /// The move that produced the position currently on the board.
    var currentMove: PlayedMove? {
        plyIndex > 0 && plyIndex <= game.history.count ? game.history[plyIndex - 1] : nil
    }

    /// Analysis of the move that produced the current position.
    var currentAnalysis: MoveAnalysis? {
        guard plyIndex > 0 else { return nil }
        return analysis?.move(at: plyIndex - 1)
    }

    var board: Board { boards[min(plyIndex, boards.count - 1)] }

    /// Colour shown at the bottom: the human's side in games against the
    /// computer, White otherwise.
    var orientation: PieceColor {
        let base = mode.humanColor ?? .white
        return manualFlip ? base.opponent : base
    }

    /// The side whose play the report leads with.
    var primaryColor: PieceColor { mode.humanColor ?? .white }

    var checkedKingSquare: Square? {
        guard board.isInCheck else { return nil }
        return Square(board.kingSquare(of: board.sideToMove))
    }

    func name(for color: PieceColor) -> String {
        switch mode {
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

    var canStepBack: Bool { plyIndex > 0 }
    var canStepForward: Bool { plyIndex < moveCount }

    // MARK: Analysis

    func startAnalysis(settings: GameAnalyzer.Settings = .standard) {
        guard analysisTask == nil, !game.history.isEmpty else { return }
        isAnalyzing = true
        progress = 0

        let game = self.game
        let jobs = self.jobs
        let total = jobs.count

        let cancellation = SearchCancellation()
        analysisCancellation = cancellation

        analysisTask = Task { [weak self] in
            var results = [PositionAnalysis?](repeating: nil, count: total)
            var completed = 0
            // A core is left to the UI so the screen stays responsive.
            let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            var next = 0

            await withTaskGroup(of: (Int, PositionAnalysis?).self) { group in
                func schedule() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        // Detached so the search never lands on the main actor;
                        // the token is what lets closing the review stop the
                        // searches instead of leaving them to finish.
                        let result = await Task.detached(priority: .userInitiated) {
                            GameAnalyzer.run(job, settings: settings, cancellation: cancellation)
                        }.value
                        return (job.index, result)
                    }
                }

                for _ in 0..<workers { schedule() }

                while let (index, result) = await group.next() {
                    if Task.isCancelled {
                        cancellation.cancel()
                        group.cancelAll()
                        break
                    }
                    results[index] = result
                    completed += 1
                    guard let self else {
                        // The review is gone and nothing will read the rest.
                        // Stop the searches themselves, not just the waiting —
                        // they are the expensive half.
                        cancellation.cancel()
                        group.cancelAll()
                        break
                    }
                    self.progress = Double(completed) / Double(total)
                    schedule()

                    // Refresh the report as results arrive, so the eval graph
                    // and the move badges fill in while the engine works.
                    if completed % 5 == 0 || completed == total {
                        let snapshot = results
                        let assembled = await Task.detached(priority: .utility) {
                            GameAnalyzer.assemble(game: game, jobs: jobs, results: snapshot)
                        }.value
                        self.apply(assembled)
                    }
                }
            }

            guard let self else { return }
            // Whatever ended the run — finished, cancelled, or the view going
            // away — the spinner must not be left turning.
            self.isAnalyzing = false
            if !Task.isCancelled { self.progress = 1 }
        }
    }

    private func apply(_ assembled: GameAnalysis) {
        withAnimation(.easeOut(duration: 0.25)) {
            analysis = assembled
        }
    }

    func cancelAnalysis() {
        analysisCancellation?.cancel()
        analysisCancellation = nil
        analysisTask?.cancel()
        analysisTask = nil
        autoplayTask?.cancel()
        autoplayTask = nil
        isAnalyzing = false
    }

    // MARK: Navigation

    /// Steps forward because the player asked to. Driving the game by hand
    /// takes over from a running replay, the same way stepping back does —
    /// otherwise the two fight each other over the board.
    func stepForward() {
        stopAutoplay()
        advance()
    }

    /// Steps forward without disturbing a replay, which is how autoplay moves.
    private func advance() {
        guard canStepForward else {
            stopAutoplay()
            return
        }
        let move = game.history[plyIndex].move
        let givesCheck = boards[plyIndex + 1].isInCheck
        withAnimation(Motion.meaningful(.spring(duration: 0.32, bounce: 0.16))) {
            applyForward(move)
            plyIndex += 1
        }
        SoundManager.shared.play(for: move, isCheck: givesCheck)
    }

    func stepBackward() {
        guard canStepBack else { return }
        stopAutoplay()
        let move = game.history[plyIndex - 1].move
        withAnimation(Motion.meaningful(.spring(duration: 0.32, bounce: 0.16))) {
            applyBackward(move)
            plyIndex -= 1
        }
        SoundManager.shared.play(.move)
    }

    /// Jumps straight to a position, rebuilding the board.
    func go(to ply: Int) {
        let target = max(0, min(moveCount, ply))
        guard target != plyIndex else { return }
        if target == plyIndex + 1 {
            stepForward()
            return
        }
        if target == plyIndex - 1 {
            stepBackward()
            return
        }
        stopAutoplay()
        plyIndex = target
        withAnimation(.easeInOut(duration: 0.22)) {
            rebuildPieces()
        }
        SoundManager.shared.play(.select)
    }

    /// Dragging along the evaluation graph passes through many positions, so
    /// this jump is silent — a click per position would be unbearable.
    func scrub(to ply: Int) {
        let target = max(0, min(moveCount, ply))
        guard target != plyIndex else { return }
        stopAutoplay()
        plyIndex = target
        withAnimation(.easeInOut(duration: 0.18)) {
            rebuildPieces()
        }
    }

    func goToStart() { go(to: 0) }
    func goToEnd() { go(to: moveCount) }

    // MARK: Autoplay

    func toggleAutoplay() {
        isAutoplaying ? stopAutoplay() : startAutoplay()
    }

    private func startAutoplay() {
        guard moveCount > 0 else { return }
        // Replaying from the end starts over from the first move.
        if !canStepForward { go(to: 0) }
        isAutoplaying = true
        autoplayTask = Task { [weak self] in
            while let self, self.isAutoplaying, self.canStepForward {
                self.advance()
                try? await Task.sleep(for: .milliseconds(1100))
                if Task.isCancelled { return }
            }
            self?.isAutoplaying = false
        }
    }

    func stopAutoplay() {
        isAutoplaying = false
        autoplayTask?.cancel()
        autoplayTask = nil
    }

    func teardown() {
        cancelAnalysis()
    }

    // MARK: Render model upkeep

    private func rebuildPieces() {
        let board = boards[min(plyIndex, boards.count - 1)]
        pieces = Square.all.compactMap { square in
            board.piece(at: square).map { RenderPiece(id: UUID(), piece: $0, square: square) }
        }
    }

    /// Mirrors a move into the render model so stepping forward slides pieces.
    private func applyForward(_ move: Move) {
        let mover = move.piece.color

        if move.captured != nil {
            let captureSquare = move.isEnPassant
                ? Square(mover == .white ? move.to.index - 8 : move.to.index + 8)
                : move.to
            pieces.removeAll { $0.square == captureSquare }
        }
        if let index = pieces.firstIndex(where: { $0.square == move.from }) {
            pieces[index].square = move.to
            if let promotion = move.promotion {
                pieces[index].piece = Piece(mover, promotion)
            }
        }
        moveCastlingRook(for: move, forward: true)
    }

    /// The same in reverse, for stepping back.
    private func applyBackward(_ move: Move) {
        let mover = move.piece.color

        if let index = pieces.firstIndex(where: { $0.square == move.to }) {
            pieces[index].square = move.from
            if move.promotion != nil {
                pieces[index].piece = move.piece
            }
        }
        if let captured = move.captured {
            let captureSquare = move.isEnPassant
                ? Square(mover == .white ? move.to.index - 8 : move.to.index + 8)
                : move.to
            pieces.append(RenderPiece(id: UUID(), piece: captured, square: captureSquare))
        }
        moveCastlingRook(for: move, forward: false)
    }

    private func moveCastlingRook(for move: Move, forward: Bool) {
        guard move.isCastle else { return }
        let rank = move.piece.color == .white ? 0 : 7
        let home = Square(file: move.isCastleKingside ? 7 : 0, rank: rank)
        let castled = Square(file: move.isCastleKingside ? 5 : 3, rank: rank)
        let from = forward ? home : castled
        let to = forward ? castled : home
        if let index = pieces.firstIndex(where: { $0.square == from }) {
            pieces[index].square = to
        }
    }
}
