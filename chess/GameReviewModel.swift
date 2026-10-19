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
    let options: GameOptions
    /// Seconds spent on each move, when the game recorded them.
    let moveTimes: [TimeInterval]
    /// The archive entry this review belongs to, so its accuracy can be noted
    /// there once the report is complete.
    let recordID: GameRecord.ID?
    /// Player names from an imported game's PGN, `[white, black]`.
    private let importedNames: [String]?

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
    /// When the cache was last written, so a running review writes it every
    /// so often rather than after every position.
    private var lastCacheSave: TimeInterval = 0
    /// Long, because a save encodes every review the cache keeps — half a
    /// megabyte of JSON, on the main actor — and the moment that matters most
    /// is caught separately: the app going to the background, see
    /// `observeBackground()`. What this still covers is the app dying in the
    /// foreground, which loses at most this much searching.
    private static let cacheSaveInterval: TimeInterval = 15
    /// Writes the cache when the app goes to the background, for as long as a
    /// run is going.
    private var backgroundObserver: (any NSObjectProtocol)?
    /// Where "now" comes from: monotonic seconds. Swappable so that a test
    /// can hold time still instead of racing it.
    private let timeSource: () -> TimeInterval
    /// `startAnalysis` is called from `onAppear`, which fires again when the
    /// review comes back from a sheet. Guarding on the task alone was enough
    /// while every run started one; a fully cached game starts none.
    private var didStartAnalysis = false
    /// Which run is current. A run stopped by `teardown` may still be winding
    /// down when the next one starts, and must leave the new one's state be.
    private var analysisRun = 0

    // MARK: Init

    init(
        game: Game, mode: GameMode, options: GameOptions = .standard,
        moveTimes: [TimeInterval] = [], recordID: GameRecord.ID? = nil,
        importedNames: [String]? = nil,
        timeSource: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.game = game
        self.mode = mode
        self.options = options
        self.moveTimes = moveTimes.count == game.history.count ? moveTimes : []
        self.recordID = recordID
        self.importedNames = importedNames
        self.timeSource = timeSource
        self.jobs = GameAnalyzer.positions(of: game)
        self.boards = jobs.map(\.board)
        self.results = [PositionAnalysis?](repeating: nil, count: jobs.count)
        // Open on the final position, the way the game just ended.
        self.plyIndex = game.history.count
        rebuildPieces()
    }

    /// The review of a game from the archive.
    convenience init(record: GameRecord, game: Game) {
        var names: [String]?
        if record.source == .imported, let tags = record.tags {
            names = [tags["White"] ?? "?", tags["Black"] ?? "?"]
        }
        self.init(
            game: game, mode: record.mode, options: record.options,
            moveTimes: record.moveTimes, recordID: record.id, importedNames: names
        )
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
        if let importedNames { return importedNames[Int(color.rawValue)] }
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
        savedCount = cacheableCount

        // The last position of a game that ended in mate or stalemate has no
        // legal move, so there is nothing to search there and the analyzer
        // hands back nothing — which the cache cannot tell apart from "not
        // searched yet". Most games end that way, so left unhandled every
        // second review of one would start a run for the single position that
        // can only ever come back empty, and flash the spinner doing it.
        // Nothing wants the entry: the final position is searched for the last
        // move's refutation, and a mated side has none.
        //
        // A variant game won on the hill or by the third check ends the same
        // way: the loser still has moves, but none that matter, and the
        // search would only misread a position whose game is already over.
        let settled = jobs.indices.filter {
            results[$0] == nil && jobs[$0].playedMove == nil
                && (jobs[$0].board.generateLegalMoves().isEmpty || jobs[$0].board.variantWinner != nil)
        }
        // A search that was cut short is shown, but it is not what a re-run
        // would produce, so a run that starts over searches it again — see
        // `PositionAnalysis.isCutShort`.
        let pending = jobs.indices.filter {
            (results[$0] == nil || results[$0]?.isCutShort == true) && !settled.contains($0)
        }
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
            reportFinished()
            return
        }

        isAnalyzing = true
        // Nothing new is worth writing yet: the first save of the run falls
        // due a full interval in.
        lastCacheSave = timeSource()
        observeBackground()

        let cancellation = SearchCancellation()
        analysisCancellation = cancellation
        analysisRun += 1
        let run = analysisRun

        analysisTask = Task { [weak self] in
            // A core is left to the UI so the screen stays responsive.
            let workers = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
            // Searched in order. A position that comes back cut short goes to
            // the back for one more try, which is why this is not `pending`.
            var queue = pending
            var retried: Set<Int> = []
            var next = 0

            await withTaskGroup(of: (Int, PositionAnalysis?).self) { group in
                func schedule() {
                    guard next < queue.count else { return }
                    let job = jobs[queue[next]]
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
                    guard let self, self.analysisRun == run else {
                        // The review is gone, or a newer run has taken over,
                        // and nothing will read the rest. Stop the searches
                        // themselves, not just the waiting — they are the
                        // expensive half.
                        cancellation.cancel()
                        group.cancelAll()
                        break
                    }
                    self.results[index] = result
                    // Cut short and not cancelled means the clock ran out,
                    // and the likeliest reason by far is that the app was
                    // suspended with the search in flight: the time limit
                    // counts that time too, so every search running when the
                    // player switched away comes back out of time when they
                    // return. Searched again, it gets the budget it is owed.
                    // The answer in hand stands in on the board meanwhile. A
                    // second cut is believed — on a device that slow, a third
                    // try would only cost another half minute.
                    let retry = result?.isCutShort == true && retried.insert(index).inserted
                    if retry {
                        queue.append(index)
                    } else {
                        completed += 1
                        self.progress = Double(completed) / Double(total)
                    }
                    schedule()

                    // Stored as the run goes, not only at its end and on the
                    // way to the background. The app can still die in the
                    // foreground, and every position not written is one the
                    // next review searches again. But not on every result —
                    // see `cacheSaveInterval`.
                    if self.timeSource() - self.lastCacheSave >= Self.cacheSaveInterval {
                        self.saveToCache()
                    }

                    // The report itself is rebuilt less often: it is the
                    // expensive half, and it only has to keep the eval graph
                    // and the move badges filling in as the engine works.
                    if !retry, completed % 5 == 0 || completed == total {
                        let snapshot = self.results
                        let assembled = await Task.detached(priority: .utility) {
                            GameAnalyzer.assemble(game: game, jobs: jobs, results: snapshot)
                        }.value
                        // Asked again after the wait: a run that was replaced
                        // while its report was being put together drew that
                        // older, thinner report over the newer run's own.
                        guard self.analysisRun == run, !Task.isCancelled else {
                            cancellation.cancel()
                            group.cancelAll()
                            break
                        }
                        self.apply(assembled)
                    }
                }
            }

            guard let self, self.analysisRun == run else { return }
            // Whatever ended the run — finished, cancelled, or the view going
            // away — the spinner must not be left turning.
            self.isAnalyzing = false
            self.stopObservingBackground()
            if !Task.isCancelled {
                self.progress = 1
                self.reportFinished()
            }
            self.saveToCache()
        }
    }

    /// What a complete report changes outside the review: the archive notes
    /// the accuracy, a brilliancy earns its achievement, and the player's own
    /// mistakes become puzzles to fix.
    ///
    /// This runs every time a review of the game completes, which for one the
    /// cache holds is every time it is opened — so each of these has to be
    /// safe to repeat. The accuracy is written over with the same figures, an
    /// achievement unlocks once, and `MistakeStore` reads a game only once.
    private func reportFinished() {
        guard let analysis, analysis.moves.count == game.history.count else { return }
        if let recordID {
            GameArchive.shared.setAccuracy([analysis.white.accuracy, analysis.black.accuracy], for: recordID)
        }
        // Only a game played here is the player's own to learn from, and only
        // under the ordinary rules: a puzzle is solved in standard chess.
        guard importedNames == nil, game.variant == .standard else { return }
        // Neither of these is ever taken back, and a search cut short twice
        // is believed for the review (see `analyze`) but is not what the
        // next review will find: it is left out of the cache and searched
        // again. Graded on it, a slow device unlocked a brilliancy, or filed
        // a mistake as a puzzle, that a full search would not have. They wait
        // for a review with every search whole; the accuracy above is written
        // over by that one anyway.
        guard !results.contains(where: { $0?.isCutShort == true }) else { return }
        let ownColors: [PieceColor] = mode.humanColor.map { [$0] } ?? [.white, .black]
        // A brilliancy found in a position set up by hand is one the player
        // may well have set up to be found — a famous combination, a puzzle
        // they knew the answer to. It is reviewed like any other, but it is
        // not the achievement.
        if !options.start.isSetUp, analysis.moves.contains(where: { $0.quality == .brilliant && ownColors.contains($0.color) }) {
            Achievements.shared.playedBrilliantMove()
        }
        MistakeStore.shared.collect(from: analysis, game: game, colors: ownColors)
    }

    // MARK: Cache

    /// Seeds `results` with everything the cache holds for this game. An entry
    /// whose stored best move is not legal in the position it is filed under
    /// is dropped: the fingerprint should make that impossible, so it means
    /// the stored data no longer matches the code that wrote it.
    ///
    /// The entry moves to the front of the cache as it is used. Left to the
    /// saves, a review the cache holds in full — which never saves again,
    /// see `saveToCache` — kept its place from when it was written, and was
    /// dropped after twenty newer ones however often it was opened.
    private func restoreFromCache(fingerprint: String) {
        guard let entry = AnalysisCache.load(fingerprint: fingerprint) else { return }
        AnalysisCache.touch(fingerprint: fingerprint)
        for (index, cached) in entry.positions.enumerated() {
            guard index < jobs.count, let cached else { continue }
            results[index] = cached.restore(in: jobs[index].board)
        }
    }

    /// Writes what the node budget reached. A search cut short is left out, as
    /// a gap the next review searches again: the cache is only allowed to hold
    /// what a re-run would reproduce, and a review takes it on trust.
    private func saveToCache() {
        guard let cacheFingerprint else { return }
        let completed = cacheableCount
        guard completed > savedCount else { return }
        savedCount = completed
        lastCacheSave = timeSource()
        AnalysisCache.save(CachedGameAnalysis(
            fingerprint: cacheFingerprint,
            positions: results.map { result in
                result.flatMap { $0.isCutShort ? nil : CachedPosition($0) }
            },
            updatedAt: Date()
        ))
    }

    /// How many results the cache may keep — see `saveToCache`.
    private var cacheableCount: Int {
        results.count { $0.map { !$0.isCutShort } ?? false }
    }

    /// The last moment a write is sure to happen is the app going to the
    /// background. Swiped away from the app switcher, or ended by the system
    /// to make room, it is already there and gets no warning of its own — so
    /// what the run has found is written now, not at the next interval.
    private func observeBackground() {
        stopObservingBackground()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue, which is where
            // this model lives.
            MainActor.assumeIsolated {
                self?.saveToCache()
            }
        }
    }

    private func stopObservingBackground() {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        backgroundObserver = nil
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
        isAnalyzing = false
        stopObservingBackground()
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
            applyForward(move, in: boards[plyIndex])
            plyIndex += 1
        }
        SoundManager.shared.play(for: move, isCheck: givesCheck)
    }

    func stepBackward() {
        guard canStepBack else { return }
        stopAutoplay()
        let move = game.history[plyIndex - 1].move
        withAnimation(Motion.meaningful(.spring(duration: 0.32, bounce: 0.16))) {
            applyBackward(move, in: boards[plyIndex - 1])
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

    /// Stops the engine when the review leaves the screen. That is also what
    /// happens when the analysis board is opened over it — a full-screen
    /// cover ends the appearance of the view beneath — so a run cut short
    /// is marked as not started, and `onAppear` on the way back picks it up
    /// where the cache left it instead of finding it already done.
    ///
    /// A replay stops with it, flag and all. Only its task used to be
    /// cancelled, from `cancelAnalysis`, which left `isAutoplaying` set: a
    /// review shown again read as still playing, with Pause on the button and
    /// a first tap that stopped nothing.
    func teardown() {
        if isAnalyzing { didStartAnalysis = false }
        stopAutoplay()
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
    /// `board` is the position the move is played in.
    private func applyForward(_ move: Move, in board: Board) {
        let mover = move.piece.color
        if moveCastlingPieces(for: move, in: board, forward: true) { return }

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
    }

    /// The same in reverse, for stepping back.
    private func applyBackward(_ move: Move, in board: Board) {
        let mover = move.piece.color
        if moveCastlingPieces(for: move, in: board, forward: false) { return }

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
    }

    /// Castling moves both pieces in one go: in Chess960 the king can land
    /// where the rook stood or the other way round, so both are looked up
    /// before either is moved. `board` is the position the move was played in.
    private func moveCastlingPieces(for move: Move, in board: Board, forward: Bool) -> Bool {
        guard move.isCastle, let squares = board.castlingSquares(for: move) else { return false }
        let kingFrom = forward ? squares.kingFrom : squares.kingTo
        let kingTo = forward ? squares.kingTo : squares.kingFrom
        let rookFrom = forward ? squares.rookFrom : squares.rookTo
        let rookTo = forward ? squares.rookTo : squares.rookFrom
        let king = pieces.firstIndex { $0.square == kingFrom && $0.piece.kind == .king }
        let rook = pieces.firstIndex { $0.square == rookFrom && $0.piece.kind == .rook }
        if let king { pieces[king].square = kingTo }
        if let rook { pieces[rook].square = rookTo }
        return true
    }
}
