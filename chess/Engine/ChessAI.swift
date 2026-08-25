//
//  ChessAI.swift
//  chess
//
//  Chess AI: iterative-deepening negamax with alpha-beta pruning, quiescence
//  search, transposition table, killer/history move ordering and a tapered
//  piece-square evaluation. Difficulty levels blend depth, time and
//  root-move randomness.
//

import Foundation
import Synchronization

// MARK: - Difficulty

nonisolated enum AIDifficulty: String, CaseIterable, Codable, Sendable, Identifiable {
    case beginner
    case easy
    case medium
    case hard
    case expert

    var id: String { rawValue }

    /// Search parameters per level. `temperature` (centipawns) controls the
    /// softmax randomness at the root; `window` caps how much worse than the
    /// best move a chosen move may be.
    var parameters: (maxDepth: Int, time: TimeInterval, temperature: Double, window: Int) {
        switch self {
        case .beginner: return (2, 0.4, 150, 550)
        case .easy: return (3, 0.7, 70, 350)
        case .medium: return (4, 1.0, 30, 180)
        case .hard: return (10, 1.4, 0, 0)
        case .expert: return (24, 2.6, 0, 0)
        }
    }
}

// MARK: - Cancellation

/// A flag a running search polls so it can be stopped from another task.
/// The search itself is a tight synchronous loop on a background thread, so it
/// cannot see `Task.isCancelled` of the task that is waiting for it.
nonisolated final class SearchCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    init() {}

    func cancel() { flag.store(true, ordering: .relaxed) }

    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

// MARK: - Result

nonisolated struct AISearchResult: Sendable {
    var move: Move
    /// Score in centipawns from the mover's perspective.
    var score: Int
    var depth: Int
    var nodes: Int
}

// MARK: - Score scale

/// The centipawn scale shared by the search and the game analyzer.
nonisolated enum SearchScore {
    static let mate = 100_000
    static let infinity = 1_000_000
    /// Scores at or beyond this magnitude encode a forced mate.
    static let mateThreshold = mate - 1000

    static func isMate(_ score: Int) -> Bool { abs(score) >= mateThreshold }

    /// Full moves until mate for a mate score: positive when the side whose
    /// perspective the score is from delivers it, negative when it receives it.
    static func mateInMoves(_ score: Int) -> Int? {
        guard isMate(score) else { return nil }
        let plies = mate - abs(score)
        let moves = max(1, (plies + 1) / 2)
        return score > 0 ? moves : -moves
    }
}

// MARK: - Analysis result

/// What the analyzer needs to know about one position: the engine's own
/// choice, what the move actually played was worth, and whether the best move
/// was the only good one.
nonisolated struct PositionAnalysis: Sendable {
    var bestMove: Move
    /// Exact score of `bestMove`, in centipawns from the mover's point of view.
    var bestScore: Int
    /// Exact score of the move the caller asked about, when it was not the
    /// engine's choice.
    var focusScore: Int?
    /// True when some other move comes close to matching `bestMove` — used to
    /// tell an only-move from one of several good options.
    var hasCloseAlternative: Bool
    var legalMoveCount: Int
    var depth: Int
    var nodes: Int
}

// MARK: - Evaluation tables

/// Classic "Simplified Evaluation Function" piece-square tables
/// (Tomasz Michniewski), tapered between middlegame and endgame.
/// Tables are written from White's perspective with rank 8 first.
nonisolated private enum EvalTables {
    /// Indexed by `PieceKind.rawValue` (which starts at 1; index 0 = empty).
    static let pieceValues: [Int] = [0] + PieceKind.allCases.map(\.centipawns)

    static let pawnMG: [Int] = [
         0,  0,  0,  0,  0,  0,  0,  0,
        50, 50, 50, 50, 50, 50, 50, 50,
        10, 10, 20, 30, 30, 20, 10, 10,
         5,  5, 10, 25, 25, 10,  5,  5,
         0,  0,  0, 20, 20,  0,  0,  0,
         5, -5,-10,  0,  0,-10, -5,  5,
         5, 10, 10,-20,-20, 10, 10,  5,
         0,  0,  0,  0,  0,  0,  0,  0,
    ]
    static let pawnEG: [Int] = [
         0,  0,  0,  0,  0,  0,  0,  0,
        90, 90, 90, 90, 90, 90, 90, 90,
        55, 55, 55, 55, 55, 55, 55, 55,
        35, 35, 35, 35, 35, 35, 35, 35,
        20, 20, 20, 20, 20, 20, 20, 20,
        10, 10, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10,
         0,  0,  0,  0,  0,  0,  0,  0,
    ]
    static let knight: [Int] = [
        -50,-40,-30,-30,-30,-30,-40,-50,
        -40,-20,  0,  0,  0,  0,-20,-40,
        -30,  0, 10, 15, 15, 10,  0,-30,
        -30,  5, 15, 20, 20, 15,  5,-30,
        -30,  0, 15, 20, 20, 15,  0,-30,
        -30,  5, 10, 15, 15, 10,  5,-30,
        -40,-20,  0,  5,  5,  0,-20,-40,
        -50,-40,-30,-30,-30,-30,-40,-50,
    ]
    static let bishop: [Int] = [
        -20,-10,-10,-10,-10,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5, 10, 10,  5,  0,-10,
        -10,  5,  5, 10, 10,  5,  5,-10,
        -10,  0, 10, 10, 10, 10,  0,-10,
        -10, 10, 10, 10, 10, 10, 10,-10,
        -10,  5,  0,  0,  0,  0,  5,-10,
        -20,-10,-10,-10,-10,-10,-10,-20,
    ]
    static let rook: [Int] = [
         0,  0,  0,  0,  0,  0,  0,  0,
         5, 10, 10, 10, 10, 10, 10,  5,
        -5,  0,  0,  0,  0,  0,  0, -5,
        -5,  0,  0,  0,  0,  0,  0, -5,
        -5,  0,  0,  0,  0,  0,  0, -5,
        -5,  0,  0,  0,  0,  0,  0, -5,
        -5,  0,  0,  0,  0,  0,  0, -5,
         0,  0,  0,  5,  5,  0,  0,  0,
    ]
    static let queen: [Int] = [
        -20,-10,-10, -5, -5,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5,  5,  5,  5,  0,-10,
         -5,  0,  5,  5,  5,  5,  0, -5,
          0,  0,  5,  5,  5,  5,  0, -5,
        -10,  5,  5,  5,  5,  5,  0,-10,
        -10,  0,  5,  0,  0,  0,  0,-10,
        -20,-10,-10, -5, -5,-10,-10,-20,
    ]
    static let kingMG: [Int] = [
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -20,-30,-30,-40,-40,-30,-30,-20,
        -10,-20,-20,-20,-20,-20,-20,-10,
         20, 20,  0,  0,  0,  0, 20, 20,
         20, 30, 10,  0,  0, 10, 30, 20,
    ]
    static let kingEG: [Int] = [
        -50,-40,-30,-20,-20,-30,-40,-50,
        -30,-20,-10,  0,  0,-10,-20,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-30,  0,  0,  0,  0,-30,-30,
        -50,-30,-30,-30,-30,-30,-30,-50,
    ]

    /// Table lookup for a piece on `squareIndex` (a1 = 0). Tables are stored
    /// rank-8-first, so White mirrors the rank.
    @inline(__always)
    static func tableValue(_ table: [Int], square: Int, color: PieceColor) -> Int {
        let file = square & 7
        let rank = square >> 3
        let row = color == .white ? 7 - rank : rank
        return table[row * 8 + file]
    }
}

// MARK: - Searcher

nonisolated final class ChessAISearcher {
    private var board: Board
    /// Hashes of positions from the real game (for repetition detection),
    /// plus the current search path.
    private var pathHashes: [UInt64]

    private var nodes = 0
    private var deadline: DispatchTime = .distantFuture
    /// Hard cap on searched nodes. A node budget is hardware-independent, so a
    /// search bounded by it returns the same answer on every machine and every
    /// run — which is what makes the game review reproducible.
    private var nodeLimit = Int.max
    private var cancellation: SearchCancellation?
    private var aborted = false

    private static let mateScore = SearchScore.mate
    private static let infinity = SearchScore.infinity

    // Transposition table
    private struct TTEntry {
        var key: UInt64
        var depth: Int
        var score: Int
        var flag: UInt8 // 0 exact, 1 lower bound, 2 upper bound
        var move: Move?
    }
    private var transpositionTable: [TTEntry?]
    private let ttMask: Int

    // Killer moves and history heuristic
    private var killers: [[Move?]] = Array(repeating: [nil, nil], count: 128)
    private var historyScores: [[Int]] = Array(repeating: Array(repeating: 0, count: 64), count: 64)

    /// Ceiling on a history score. `moveOrderScore` ranks quiet moves by their
    /// history against *fixed* bands — killers at 79 000, captures at 100 000,
    /// the transposition-table move at 1 000 000 — so an unbounded counter does
    /// not merely order quiet moves among themselves, it eventually climbs past
    /// those bands and pushes the best hints there are to the back of the list.
    /// Measured before this cap existed: in one Grandmaster game the counter
    /// passed the killers by move 2, the captures by move 3 and the TT move by
    /// move 36. The cap sits clear of the lowest band, so history now says only
    /// what it is meant to say — which quiet move to try first.
    private static let historyCap = 60_000

    /// `ttSizeLog2` sizes the transposition table; analysis runs many searches
    /// in parallel and uses a smaller one to keep memory in check.
    init(board: Board, gameHashes: [UInt64], ttSizeLog2: Int = 18) {
        self.board = board
        self.pathHashes = gameHashes
        let ttSize = 1 << ttSizeLog2
        self.transpositionTable = Array(repeating: nil, count: ttSize)
        self.ttMask = ttSize - 1
    }

    /// Points the searcher at a new position without throwing away what it has
    /// learned. Transposition entries are keyed by Zobrist hash, so they stay
    /// valid across moves of the same game; keeping them (and the history
    /// heuristic) is worth roughly a ply of depth at the same time budget.
    func reset(board: Board, gameHashes: [UInt64]) {
        self.board = board
        self.pathHashes = gameHashes
        // Killers are ply-indexed, and the tree shifts by a ply between moves,
        // so they are the one table that goes stale.
        killers = Array(repeating: [nil, nil], count: killers.count)
        // History is kept, because which quiet moves tend to work carries over
        // — but halved, so what this position learns outweighs what a position
        // twenty moves ago did.
        ageHistory()
    }

    /// Halves every history score, keeping their order while making room for
    /// what the next search learns.
    private func ageHistory() {
        for from in 0..<64 {
            for to in 0..<64 { historyScores[from][to] /= 2 }
        }
    }

    // MARK: Public search

    /// Finds a move for the current position. Returns nil when there are no
    /// legal moves.
    func search(
        difficulty: AIDifficulty,
        randomSeed: UInt64,
        cancellation: SearchCancellation? = nil
    ) -> AISearchResult? {
        let params = difficulty.parameters
        var rng = Zobrist.SplitMix64(seed: randomSeed)

        var rootMoves = board.generateLegalMoves()
        guard !rootMoves.isEmpty else { return nil }
        if rootMoves.count == 1 {
            return AISearchResult(move: rootMoves[0], score: 0, depth: 0, nodes: 1)
        }

        // Shuffle so that equally-scored moves vary between games.
        var generator = SeededGenerator(seed: rng.next())
        rootMoves.shuffle(using: &generator)

        deadline = .now() + params.time
        nodeLimit = .max
        self.cancellation = cancellation
        nodes = 0
        aborted = false

        var bestResult: AISearchResult?
        var lastScores: [(move: Move, score: Int)] = []

        for depth in 1...params.maxDepth {
            var iterationScores: [(move: Move, score: Int)] = []
            var alpha = -Self.infinity
            var bestMove: Move?
            var completed = true

            // Order root moves: previous iteration's best first.
            if let previousBest = bestResult?.move,
               let index = rootMoves.firstIndex(of: previousBest) {
                rootMoves.remove(at: index)
                rootMoves.insert(previousBest, at: 0)
            }

            for move in rootMoves {
                let undo = board.make(move)
                pathHashes.append(board.zobrist)
                let useFullWindow = params.temperature > 0
                let score: Int
                if useFullWindow {
                    // Full window per root move: exact scores for the
                    // randomized pick at lower difficulties.
                    score = -negamax(depth: depth - 1, alpha: -Self.infinity, beta: Self.infinity, ply: 1)
                } else {
                    score = -negamax(depth: depth - 1, alpha: -Self.infinity, beta: -alpha, ply: 1)
                }
                pathHashes.removeLast()
                board.unmake(move, undo: undo)

                if aborted { completed = false; break }
                iterationScores.append((move, score))
                if score > alpha {
                    alpha = score
                    bestMove = move
                }
            }

            if completed, let bestMove {
                bestResult = AISearchResult(move: bestMove, score: alpha, depth: depth, nodes: nodes)
                lastScores = iterationScores
                // Stop early once a forced mate is found.
                if alpha > Self.mateScore - 1000 { break }
            }
            if aborted { break }
        }

        // A search the caller abandoned has no answer worth returning.
        if cancellation?.isCancelled == true { return nil }

        guard var result = bestResult else {
            // Time ran out before depth 1 completed (should not happen).
            return AISearchResult(move: rootMoves[0], score: 0, depth: 0, nodes: nodes)
        }

        // Randomized pick for lower difficulties.
        if params.temperature > 0, lastScores.count > 1 {
            let best = lastScores.map(\.score).max()!
            // Never randomize away a forced mate.
            if best < Self.mateScore - 1000 {
                let candidates = lastScores.filter { best - $0.score <= params.window }
                let weights = candidates.map { exp(-Double(best - $0.score) / params.temperature) }
                let total = weights.reduce(0, +)
                var pick = Double(rng.next() % 1_000_000) / 1_000_000 * total
                for (candidate, weight) in zip(candidates, weights) {
                    pick -= weight
                    if pick <= 0 {
                        result.move = candidate.move
                        result.score = candidate.score
                        break
                    }
                }
            }
        }

        return result
    }

    // MARK: Analysis search

    /// Looks at one position from the reviewer's angle: the engine's best move
    /// with an exact score, an exact score for `focusMove` (the move that was
    /// actually played), and whether anything else came close to the best.
    ///
    /// The root uses principal-variation search, so only the moves the review
    /// really needs get an expensive full-window search.
    /// `nodeBudget` is what actually bounds the search, so two runs over the
    /// same game produce the same report. `timeLimit` is only a safety net for
    /// a position that somehow searches far slower than expected.
    func analyze(
        maxDepth: Int,
        nodeBudget: Int,
        timeLimit: TimeInterval,
        focusMove: Move? = nil,
        cancellation: SearchCancellation? = nil
    ) -> PositionAnalysis? {
        var rootMoves = board.generateLegalMoves()
        guard !rootMoves.isEmpty else { return nil }

        deadline = .now() + timeLimit
        nodeLimit = nodeBudget
        self.cancellation = cancellation
        nodes = 0
        aborted = false

        var result: PositionAnalysis?

        for depth in 1...max(1, maxDepth) {
            var alpha = -Self.infinity
            var bestMove: Move?
            var completed = true

            for (index, move) in rootMoves.enumerated() {
                var score: Int
                if index == 0 {
                    score = rootSearch(move, depth: depth, alpha: -Self.infinity, beta: Self.infinity)
                } else {
                    // Null window first: most moves only need to be shown to
                    // be worse than the best one so far.
                    score = rootSearch(move, depth: depth, alpha: alpha, beta: alpha + 1)
                    if score > alpha, !aborted {
                        score = rootSearch(move, depth: depth, alpha: alpha, beta: Self.infinity)
                    }
                }
                if aborted { completed = false; break }
                if bestMove == nil || score > alpha {
                    alpha = score
                    bestMove = move
                }
            }

            guard completed, let bestMove else { break }
            let bestScore = alpha

            // Exact score for the move that was played, so the two can be
            // compared at the same depth.
            var focusScore: Int?
            if let focusMove {
                if focusMove == bestMove {
                    focusScore = bestScore
                } else {
                    let score = rootSearch(
                        focusMove, depth: depth,
                        alpha: -Self.infinity, beta: Self.infinity
                    )
                    if aborted { break }
                    focusScore = score
                }
            }

            // Was the best move the only good one? A single null-window probe
            // per alternative answers that cheaply.
            var hasCloseAlternative = true
            if let threshold = Self.alternativeThreshold(bestScore: bestScore) {
                hasCloseAlternative = false
                for move in rootMoves where move != bestMove {
                    let score = rootSearch(
                        move, depth: depth,
                        alpha: threshold - 1, beta: threshold
                    )
                    if aborted { break }
                    if score >= threshold {
                        hasCloseAlternative = true
                        break
                    }
                }
                if aborted { break }
            }

            result = PositionAnalysis(
                bestMove: bestMove,
                bestScore: bestScore,
                focusScore: focusScore,
                hasCloseAlternative: hasCloseAlternative,
                legalMoveCount: rootMoves.count,
                depth: depth,
                nodes: nodes
            )

            // Best move first makes the next, deeper iteration cheaper.
            if let index = rootMoves.firstIndex(of: bestMove) {
                rootMoves.remove(at: index)
                rootMoves.insert(bestMove, at: 0)
            }

            // A forced mate settles the position; no need to search deeper.
            if SearchScore.isMate(bestScore) { break }
        }

        return result
    }

    private func rootSearch(_ move: Move, depth: Int, alpha: Int, beta: Int) -> Int {
        let undo = board.make(move)
        pathHashes.append(board.zobrist)
        let score = -negamax(depth: depth - 1, alpha: -beta, beta: -alpha, ply: 1)
        pathHashes.removeLast()
        board.unmake(move, undo: undo)
        return score
    }

    /// The score an alternative has to reach to count as "nearly as good as
    /// the best move" — a fixed drop in win expectancy rather than a fixed
    /// number of centipawns, so the test means the same thing in a quiet
    /// position and in a wild one. Returns nil when the position is already
    /// decided, where no move deserves singling out.
    private static func alternativeThreshold(bestScore: Int) -> Int? {
        guard !SearchScore.isMate(bestScore) else { return nil }
        let best = WinChance.percent(centipawns: bestScore) / 100
        let target = best - 0.18
        guard target > 0.02, best < 0.96 else { return nil }
        return Int((log(target / (1 - target)) / 0.00368208).rounded())
    }

    // MARK: Negamax

    private func negamax(depth: Int, alpha: Int, beta: Int, ply: Int) -> Int {
        var alpha = alpha

        if reachedLimit() { return 0 }

        // Draw detection: fifty-move rule and repetition (a single repetition
        // within the search already scores as a draw to avoid shuffling).
        // Mate outranks the clock, the same way it does in
        // `Game.evaluateOutcome`: a checkmate delivered by the hundredth quiet
        // move is still checkmate, so a node on the clock only scores as a
        // draw once it is known to have a reply.
        if board.halfmoveClock >= 100, !isCheckmated() { return 0 }
        if ply > 0, isRepetition() { return 0 }

        let inCheck = board.isInCheck
        var depth = depth
        if inCheck { depth += 1 } // check extension

        if depth <= 0 {
            return quiescence(alpha: alpha, beta: beta, ply: ply)
        }

        // Transposition table probe.
        let key = board.zobrist
        let ttIndex = Int(key & UInt64(ttMask))
        var ttMove: Move?
        if let entry = transpositionTable[ttIndex], entry.key == key {
            ttMove = entry.move
            if entry.depth >= depth {
                let score = scoreFromTT(entry.score, ply: ply)
                switch entry.flag {
                case 0: return score
                case 1: if score >= beta { return score }
                case 2: if score <= alpha { return score }
                default: break
                }
            }
        }

        // Null-move pruning: skip a turn; if the opponent still cannot beat
        // beta, this node is almost certainly a cutoff. Avoid in check and in
        // pawn-only endgames (zugzwang).
        if depth >= 3, !inCheck, beta < Self.mateScore - 1000, hasNonPawnMaterial(board.sideToMove) {
            var nullBoard = board
            nullBoard.sideToMove = board.sideToMove.opponent
            nullBoard.enPassantSquare = -1
            nullBoard.zobrist = nullBoard.computeZobrist()
            let saved = board
            board = nullBoard
            let score = -negamax(depth: depth - 3, alpha: -beta, beta: -beta + 1, ply: ply + 1)
            board = saved
            if aborted { return 0 }
            if score >= beta { return beta }
        }

        var moves = board.generatePseudoLegalMoves()
        orderMoves(&moves, ttMove: ttMove, ply: ply)

        var bestScore = -Self.infinity
        var bestMove: Move?
        var legalCount = 0
        var flag: UInt8 = 2 // upper bound until proven otherwise

        for move in moves {
            let mover = board.sideToMove
            let undo = board.make(move)
            if board.isSquareAttacked(board.kingSquare(of: mover), by: mover.opponent) {
                board.unmake(move, undo: undo)
                continue
            }
            legalCount += 1
            pathHashes.append(board.zobrist)
            let score = -negamax(depth: depth - 1, alpha: -beta, beta: -alpha, ply: ply + 1)
            pathHashes.removeLast()
            board.unmake(move, undo: undo)

            if aborted { return 0 }

            if score > bestScore {
                bestScore = score
                bestMove = move
            }
            if score > alpha {
                alpha = score
                flag = 0 // exact
            }
            if alpha >= beta {
                flag = 1 // lower bound (fail high)
                if !move.isCapture {
                    storeKiller(move, ply: ply)
                    recordHistory(move, depth: depth)
                }
                break
            }
        }

        if legalCount == 0 {
            return inCheck ? -(Self.mateScore - ply) : 0
        }

        transpositionTable[ttIndex] = TTEntry(
            key: key, depth: depth,
            score: scoreToTT(bestScore, ply: ply),
            flag: flag, move: bestMove
        )
        return bestScore
    }

    /// In check with no legal reply. Only asked on the rare node whose
    /// fifty-move clock has run down, so the full legal move list is
    /// affordable here.
    private func isCheckmated() -> Bool {
        board.isInCheck && board.generateLegalMoves().isEmpty
    }

    // MARK: Quiescence

    private func quiescence(alpha: Int, beta: Int, ply: Int) -> Int {
        if reachedLimit() { return 0 }

        var alpha = alpha
        // Standing pat says "I could simply stop here" — which is the one thing
        // a side in check may not do. `negamax` extends on check and so never
        // enters quiescence in one, but a capture searched *here* can give
        // check, and the child used to answer it by evaluating the position as
        // though the check were optional. A capture that walked into mate came
        // back scored as the material it won. In check the full move list is
        // searched instead, and running out of it is mate.
        let inCheck = board.isInCheck
        var standPat = 0
        if !inCheck {
            standPat = evaluate()
            if standPat >= beta { return beta }
            if standPat > alpha { alpha = standPat }
        }

        var moves = board.generatePseudoLegalMoves(capturesOnly: !inCheck)
        moves.sort { mvvLva($0) > mvvLva($1) }

        var legalCount = 0
        for move in moves {
            // Delta pruning: skip captures that cannot possibly raise alpha.
            // Not while in check, where the move list is about getting out,
            // not about what it wins.
            if !inCheck, let captured = move.captured,
               standPat + EvalTables.pieceValues[Int(captured.kind.rawValue)] + 200 < alpha,
               move.promotion == nil {
                continue
            }
            let mover = board.sideToMove
            let undo = board.make(move)
            if board.isSquareAttacked(board.kingSquare(of: mover), by: mover.opponent) {
                board.unmake(move, undo: undo)
                continue
            }
            legalCount += 1
            let score = -quiescence(alpha: -beta, beta: -alpha, ply: ply + 1)
            board.unmake(move, undo: undo)

            if aborted { return 0 }
            if score >= beta { return beta }
            if score > alpha { alpha = score }
        }

        // Only meaningful in check: with no legal move there, this is mate.
        // Out of check an empty list just means the position is quiet, and
        // `standPat` already stands as its score.
        if inCheck, legalCount == 0 { return -(Self.mateScore - ply) }
        return alpha
    }

    // MARK: Move ordering

    /// Each move is scored once and the pairs are sorted, rather than handing
    /// `moveOrderScore` to the comparator — which recomputed it for both sides
    /// of every comparison, so an n-move list cost O(n log n) scorings instead
    /// of n. That is not a small constant here: a scoring runs up to three
    /// `Move` equality checks, and `Move` is a nine-field struct. Measured over
    /// 3.31 M nodes on six positions, the same search went from 2.97 s to
    /// 1.98 s — a third less time for byte-identical node counts, depths,
    /// moves and scores.
    private func orderMoves(_ moves: inout [Move], ttMove: Move?, ply: Int) {
        let killer0 = ply < killers.count ? killers[ply][0] : nil
        let killer1 = ply < killers.count ? killers[ply][1] : nil
        var scored = moves.map {
            (move: $0, score: moveOrderScore($0, ttMove: ttMove, killer0: killer0, killer1: killer1))
        }
        scored.sort { $0.score > $1.score }
        for index in scored.indices { moves[index] = scored[index].move }
    }

    @inline(__always)
    private func moveOrderScore(_ move: Move, ttMove: Move?, killer0: Move?, killer1: Move?) -> Int {
        if move == ttMove { return 1_000_000 }
        if move.isCapture { return 100_000 + mvvLva(move) }
        if move.promotion == .queen { return 90_000 }
        if move == killer0 { return 80_000 }
        if move == killer1 { return 79_000 }
        return historyScores[move.from.index][move.to.index]
    }

    @inline(__always)
    private func mvvLva(_ move: Move) -> Int {
        guard let captured = move.captured else { return 0 }
        return EvalTables.pieceValues[Int(captured.kind.rawValue)] * 10
            - EvalTables.pieceValues[Int(move.piece.kind.rawValue)] / 10
    }

    /// Credits a quiet move that caused a cutoff. Deeper cutoffs count for
    /// more; the whole table is halved rather than clipped when the leader
    /// reaches the ceiling, so the moves keep their order relative to each
    /// other instead of piling up together at the top.
    private func recordHistory(_ move: Move, depth: Int) {
        let score = historyScores[move.from.index][move.to.index] + depth * depth
        if score > Self.historyCap {
            ageHistory()
            historyScores[move.from.index][move.to.index] = score / 2
        } else {
            historyScores[move.from.index][move.to.index] = score
        }
    }

    private func storeKiller(_ move: Move, ply: Int) {
        guard ply < killers.count else { return }
        if killers[ply][0] != move {
            killers[ply][1] = killers[ply][0]
            killers[ply][0] = move
        }
    }

    // MARK: Helpers

    /// Counts the node and, every 2048 of them, asks whether the search must
    /// stop — node budget spent, time up, or the caller gave up waiting.
    @inline(__always)
    private func reachedLimit() -> Bool {
        nodes += 1
        guard nodes & 2047 == 0 else { return false }
        if nodes >= nodeLimit || DispatchTime.now() > deadline
            || cancellation?.isCancelled == true {
            aborted = true
            return true
        }
        return false
    }

    private func isRepetition() -> Bool {
        let current = board.zobrist
        // Compare against both game history and the current search path.
        var count = 0
        for hash in pathHashes where hash == current {
            count += 1
            if count >= 2 { return true }
        }
        return false
    }

    private func hasNonPawnMaterial(_ color: PieceColor) -> Bool {
        for index in 0..<64 {
            guard let piece = board.piece(at: index), piece.color == color else { continue }
            if piece.kind != .pawn && piece.kind != .king { return true }
        }
        return false
    }

    private func scoreToTT(_ score: Int, ply: Int) -> Int {
        if score > Self.mateScore - 1000 { return score + ply }
        if score < -(Self.mateScore - 1000) { return score - ply }
        return score
    }

    private func scoreFromTT(_ score: Int, ply: Int) -> Int {
        if score > Self.mateScore - 1000 { return score - ply }
        if score < -(Self.mateScore - 1000) { return score + ply }
        return score
    }

    // MARK: Evaluation

    /// Static evaluation in centipawns from the side to move's perspective.
    private func evaluate() -> Int {
        // A position neither side can mate in is a draw, whatever the piece
        // count says: K+B vs K is nobody's advantage, and scoring it as the
        // bishop's worth used to let the search trade into a dead draw
        // believing it was still three pawns up — and made the game review
        // print "+3.5" beside a position the app itself calls a draw.
        //
        // Asked here rather than in `negamax` so that quiescence and every
        // other leaf gets the same answer. Material cannot come back, so a
        // node above a drawn leaf sees the zero propagate up on its own.
        if board.hasInsufficientMaterial { return 0 }

        var mgScore = 0
        var egScore = 0
        var phase = 0 // 24 = full middlegame, 0 = bare endgame
        var whiteBishops = 0
        var blackBishops = 0
        var whiteMaterial = 0 // non-king material
        var blackMaterial = 0
        var whiteKingSquare = 0
        var blackKingSquare = 0

        for index in 0..<64 {
            let packed = board.squares[index]
            guard packed != 0, let piece = Piece(packed: packed) else { continue }
            let kind = piece.kind
            let value = EvalTables.pieceValues[Int(kind.rawValue)]
            let sign = piece.color == .white ? 1 : -1

            var mg = value
            var eg = value
            switch kind {
            case .pawn:
                mg += EvalTables.tableValue(EvalTables.pawnMG, square: index, color: piece.color)
                eg += EvalTables.tableValue(EvalTables.pawnEG, square: index, color: piece.color)
            case .knight:
                let bonus = EvalTables.tableValue(EvalTables.knight, square: index, color: piece.color)
                mg += bonus; eg += bonus
                phase += 1
            case .bishop:
                let bonus = EvalTables.tableValue(EvalTables.bishop, square: index, color: piece.color)
                mg += bonus; eg += bonus
                phase += 1
                if piece.color == .white { whiteBishops += 1 } else { blackBishops += 1 }
            case .rook:
                let bonus = EvalTables.tableValue(EvalTables.rook, square: index, color: piece.color)
                mg += bonus; eg += bonus
                phase += 2
            case .queen:
                let bonus = EvalTables.tableValue(EvalTables.queen, square: index, color: piece.color)
                mg += bonus; eg += bonus
                phase += 4
            case .king:
                mg += EvalTables.tableValue(EvalTables.kingMG, square: index, color: piece.color)
                eg += EvalTables.tableValue(EvalTables.kingEG, square: index, color: piece.color)
                if piece.color == .white { whiteKingSquare = index } else { blackKingSquare = index }
            }
            mgScore += sign * mg
            egScore += sign * eg
            if kind != .king {
                if piece.color == .white { whiteMaterial += value } else { blackMaterial += value }
            }
        }

        // Bishop pair.
        if whiteBishops >= 2 { mgScore += 30; egScore += 40 }
        if blackBishops >= 2 { mgScore -= 30; egScore -= 40 }

        // Mop-up: with a bare enemy king and a decisive material edge, drive
        // the enemy king to the corner and bring the own king closer.
        if blackMaterial == 0, whiteMaterial >= 400 {
            egScore += mopUpBonus(winnerKing: whiteKingSquare, loserKing: blackKingSquare)
        } else if whiteMaterial == 0, blackMaterial >= 400 {
            egScore -= mopUpBonus(winnerKing: blackKingSquare, loserKing: whiteKingSquare)
        }

        let clampedPhase = min(phase, 24)
        var score = (mgScore * clampedPhase + egScore * (24 - clampedPhase)) / 24

        // Tempo.
        score += board.sideToMove == .white ? 10 : -10

        return board.sideToMove == .white ? score : -score
    }

    private func mopUpBonus(winnerKing: Int, loserKing: Int) -> Int {
        let loserFile = loserKing & 7, loserRank = loserKing >> 3
        let centerDistance = max(abs(loserFile * 2 - 7), abs(loserRank * 2 - 7)) // 1,3,5,7
        let kingDistance = max(abs((winnerKing & 7) - loserFile), abs((winnerKing >> 3) - loserRank))
        return centerDistance * 12 + (7 - kingDistance) * 8
    }
}

// MARK: - RandomNumberGenerator bridge

nonisolated private struct SeededGenerator: RandomNumberGenerator {
    private var rng: Zobrist.SplitMix64
    /// Takes its own stream rather than a copy of the caller's, so the values
    /// the shuffle burns cannot reappear in whatever the caller draws next.
    init(seed: UInt64) {
        rng = Zobrist.SplitMix64(seed: seed)
    }
    mutating func next() -> UInt64 { rng.next() }
}

// MARK: - Convenience entry point

/// Synchronous full-width analysis of one position; run it off the main thread.
/// Uses a small transposition table because many of these run in parallel.
nonisolated func analyzePosition(
    board: Board,
    gameHashes: [UInt64],
    maxDepth: Int,
    nodeBudget: Int,
    timeLimit: TimeInterval,
    focusMove: Move? = nil,
    cancellation: SearchCancellation? = nil
) -> PositionAnalysis? {
    let searcher = ChessAISearcher(board: board, gameHashes: gameHashes, ttSizeLog2: 16)
    return searcher.analyze(
        maxDepth: maxDepth, nodeBudget: nodeBudget, timeLimit: timeLimit,
        focusMove: focusMove, cancellation: cancellation
    )
}

/// Synchronous search; run it off the main thread.
nonisolated func findBestAIMove(
    board: Board,
    gameHashes: [UInt64],
    difficulty: AIDifficulty,
    randomSeed: UInt64 = UInt64.random(in: .min ... .max),
    cancellation: SearchCancellation? = nil
) -> AISearchResult? {
    let searcher = ChessAISearcher(board: board, gameHashes: gameHashes)
    return searcher.search(
        difficulty: difficulty, randomSeed: randomSeed, cancellation: cancellation
    )
}

// MARK: - Per-game engine

/// One searcher kept alive for a whole game, so its transposition table and
/// history heuristic carry from move to move instead of being rebuilt (and a
/// 16 MB table reallocated) every time the computer thinks.
///
/// The searcher itself is a plain class driving a tight synchronous loop; the
/// mutex is what makes it safe to hand to a background task. Only one search
/// runs at a time, so it is never contended.
nonisolated final class GameAIEngine: Sendable {
    private let searcher: Mutex<ChessAISearcher>

    init() {
        searcher = Mutex(ChessAISearcher(board: .initial, gameHashes: []))
    }

    func bestMove(
        board: Board,
        gameHashes: [UInt64],
        difficulty: AIDifficulty,
        randomSeed: UInt64 = UInt64.random(in: .min ... .max),
        cancellation: SearchCancellation? = nil
    ) -> AISearchResult? {
        searcher.withLock { searcher in
            searcher.reset(board: board, gameHashes: gameHashes)
            return searcher.search(
                difficulty: difficulty, randomSeed: randomSeed, cancellation: cancellation
            )
        }
    }
}
