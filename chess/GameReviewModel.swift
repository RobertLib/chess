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

    /// Everything searched so far, indexed like `jobs`. Kept on the model
    /// rather than inside the analysis task so that closing the review can
    /// write the unfinished half of a run to the cache.
    private var results: [PositionAnalysis?]
    /// Identifies this game and the settings its results were searched under.
    private var cacheFingerprint: String?
    /// How many results were already in the cache when the run started, so a
    /// save is skipped when the run added nothing.
    private var savedCount = 0
    /// `startAnalysis` is called from `onAppear`, which fires again when the
    /// review comes back from a sheet. Guarding on the task alone was enough
    /// while every run started one; a fully cached game starts none.
    private var didStartAnalysis = false

    // MARK: Init

    init(game: Game, mode: GameMode) {
        self.game = game
        self.mode = mode
        self.jobs = GameAnalyzer.positions(of: game)
        self.boards = jobs.map(\.board)
        self.results = [PositionAnalysis?](repeating: nil, count: jobs.count)
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
        guard !didStartAnalysis, !game.history.isEmpty else { return }
        didStartAnalysis = true

        let game = self.game
        let jobs = self.jobs
        let total = jobs.count

        // Whatever a previous review of this game got through is reused. The
        // node budget bounds the search, so a cached position holds exactly
        // the numbers a re-run would produce — reusing it changes the report
        // in no way at all, it only skips the work.
        let fingerprint = AnalysisCache.fingerprint(game: game, settings: settings)
        cacheFingerprint = fingerprint
        restoreFromCache(fingerprint: fingerprint)
        savedCount = results.reduce(0) { $0 + ($1 == nil ? 0 : 1) }

        // The last position of a game that ended in mate or stalemate has no
        // legal move, so there is nothing to search there and the analyzer
        // hands back nothing — which the cache cannot tell apart from "not
        // searched yet". Most games end that way, so left unhandled every
        // second review of one would start a run for the single position that
        // can only ever come back empty, and flash the spinner doing it.
        // Nothing wants the entry: the final position is searched for the last
        // move's refutation, and a mated side has none.
        let settled = jobs.indices.filter {
            results[$0] == nil && jobs[$0].playedMove == nil
                && jobs[$0].board.generateLegalMoves().isEmpty
        }
        let pending = jobs.indices.filter { results[$0] == nil && !settled.contains($0) }
        var completed = total - pending.count
        progress = total > 0 ? Double(completed) / Double(total) : 0

        // Anything already cached is worth showing before the first new search
        // finishes; a fully cached game never starts one.
        if completed > 0 {
            apply(GameAnalyzer.assemble(game: game, jobs: jobs, results: results))
        }
        guard !pending.isEmpty else {
            isAnalyzing = false
            progress = 1
            return
        }

        isAnalyzing = true

        let cancellation = SearchCancellation()
        analysisCancellation = cancellation

        analysisTask = Task { [weak self] in
            // A core is left to the UI so the screen stays responsive.
            let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            var next = 0

            await withTaskGroup(of: (Int, PositionAnalysis?).self) { group in
                func schedule() {
                    guard next < pending.count else { return }
                    let job = jobs[pending[next]]
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
                    guard let self else {
                        // The review is gone and nothing will read the rest.
                        // Stop the searches themselves, not just the waiting —
                        // they are the expensive half.
                        cancellation.cancel()
                        group.cancelAll()
                        break
                    }
                    self.results[index] = result
                    completed += 1
                    self.progress = Double(completed) / Double(total)
                    schedule()

                    // Stored on every result, not every fifth. Being killed —
                    // the app swiped away, the phone deciding it has had
                    // enough — gives no chance to save on the way out, and
                    // every position not written here is one the next review
                    // searches again. It costs a small encode against a search
                    // that took the best part of a second.
                    self.saveToCache()

                    // The report itself is rebuilt less often: it is the
                    // expensive half, and it only has to keep the eval graph
                    // and the move badges filling in as the engine works.
                    if completed % 5 == 0 || completed == total {
                        let snapshot = self.results
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
            self.saveToCache()
        }
    }

    // MARK: Cache

    /// Seeds `results` with everything the cache holds for this game. An entry
    /// whose stored best move is not legal in the position it is filed under
    /// is dropped: the fingerprint should make that impossible, so it means
    /// the stored data no longer matches the code that wrote it.
    private func restoreFromCache(fingerprint: String) {
        guard let entry = AnalysisCache.load(fingerprint: fingerprint) else { return }
        for (index, cached) in entry.positions.enumerated() {
            guard index < jobs.count, let cached else { continue }
            results[index] = cached.restore(in: jobs[index].board)
        }
    }

    private func saveToCache() {
        guard let cacheFingerprint else { return }
        let completed = results.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        guard completed > savedCount else { return }
        savedCount = completed
        AnalysisCache.save(CachedGameAnalysis(
            fingerprint: cacheFingerprint,
            positions: results.map { $0.map(CachedPosition.init) },
            updatedAt: Date()
        ))
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
        // Written here rather than left to the task: cancelling it only asks
        // it to stop, and the model may be gone before it gets round to its
        // own save. Everything searched so far is already in `results`.
        saveToCache()
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
