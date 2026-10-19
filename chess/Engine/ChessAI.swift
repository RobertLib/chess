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
    /// Moves between the five levels on its own, a little stronger after the
    /// player wins and a little weaker after they lose. Its actual strength is
    /// not a property of the case — it lives with the player's settings and
    /// travels with each game in `GameOptions.adaptiveLevel` — so `parameters`
    /// here is only the Medium fallback for a caller that never resolved it.
    case adaptive

    var id: String { rawValue }

    /// The five levels that have a strength of their own, weakest first.
    static let fixedLevels: [AIDifficulty] = [.beginner, .easy, .medium, .hard, .expert]

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
        case .adaptive: return AIDifficulty.medium.parameters
        }
    }

    /// The same parameters as a value the search can be handed directly.
    var strength: AIStrength {
        let p = parameters
        return AIStrength(maxDepth: p.maxDepth, time: p.time, temperature: p.temperature, window: p.window)
    }

    /// Whether this level opens out of `OpeningBook` instead of searching the
    /// first few moves for itself.
    ///
    /// Only the levels that have no other source of variety. `temperature`
    /// randomises the root pick, so the three below `hard` already open
    /// differently from game to game — handing them theory as well would have
    /// Beginner playing a grandmaster's first eight moves. The two above have
    /// `temperature` 0, and the root shuffle only breaks *exact* score ties,
    /// which from the starting position at depth 10 and up there are none of:
    /// measured before the book was wired in, `hard` and `expert` each played
    /// 1.e4 on eight seeds out of eight and two different seeds gave a
    /// byte-identical six-ply opening.
    var playsFromBook: Bool { parameters.temperature == 0 }
}

// MARK: - Strength

/// What a search is allowed to do, as numbers rather than as a named level:
/// how deep, how long, and how much randomness goes into the pick at the root.
///
/// The five levels are five points on this scale. The adaptive opponent lives
/// *between* them, so it needs the scale itself — `interpolated(_:)` slides
/// from Beginner (0) to Grandmaster (4), and lands exactly on a named level at
/// every whole number.
nonisolated struct AIStrength: Hashable, Codable, Sendable {
    var maxDepth: Int
    var time: TimeInterval
    /// Softmax temperature at the root, in centipawns. 0 picks the best move.
    var temperature: Double
    /// How far below the best move a randomly picked move may score.
    var window: Int

    /// Same reasoning as `AIDifficulty.playsFromBook`: only a strength with no
    /// randomness of its own needs the book to vary its openings.
    var playsFromBook: Bool { temperature == 0 }

    /// A strength anywhere on the Beginner…Grandmaster scale. `level` is
    /// clamped to 0...4; whole numbers reproduce the named levels exactly.
    static func interpolated(_ level: Double) -> AIStrength {
        let levels = AIDifficulty.fixedLevels.map(\.strength)
        let clamped = min(Double(levels.count - 1), max(0, level))
        let lower = Int(clamped.rounded(.down))
        let upper = min(levels.count - 1, lower + 1)
        let t = clamped - Double(lower)
        let a = levels[lower], b = levels[upper]
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return AIStrength(
            maxDepth: Int(mix(Double(a.maxDepth), Double(b.maxDepth)).rounded()),
            time: mix(a.time, b.time),
            temperature: mix(a.temperature, b.temperature),
            window: Int(mix(Double(a.window), Double(b.window)).rounded())
        )
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
    /// True when the move came out of `OpeningBook` and was never searched, so
    /// that `depth: 0` on its own still means what it always did — a search
    /// that ran out of budget before finishing a single root move.
    var isBookMove: Bool = false
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
    ///
    /// Usually from the same depth as `bestScore`. When `bestScore` is a forced
    /// mate it can come from deeper than `depth`: the mate ends the search, and
    /// the move asked about is searched on alone until it is decided too.
    var focusScore: Int?
    /// True when some other move comes close to matching `bestMove` — used to
    /// tell an only-move from one of several good options. Beside a forced
    /// mate it is asked only when the mate is the move asked about, and true
    /// otherwise, as it always was there.
    var hasCloseAlternative: Bool
    /// Whether some move other than `bestMove` wins outright as well, by the
    /// line `GameAnalyzer.wonOutright` draws — what tells a sacrifice that won
    /// the game from one played in a game that was won anyway.
    ///
    /// Asked only where a grade can turn on it: `bestMove` gives material up
    /// (`GameAnalyzer.sacrifice(of:in:)`) and wins outright itself. Nil
    /// everywhere else, and wherever the budget ran out before the answer
    /// came in, which the grading reads as yes — no brilliancy on a guess.
    var alternativeWinsOutright: Bool? = nil
    var legalMoveCount: Int
    var depth: Int
    var nodes: Int
    /// True when the search was stopped by the clock or by the caller rather
    /// than by its node budget, its depth cap or a mate.
    ///
    /// The numbers are then whatever depth this run happened to finish, which
    /// says how fast the device was and nothing about the position. The time
    /// limit is meant only as a net, but it measures time the app spends
    /// suspended as well: a review left running in the background used to
    /// come back to every search it had in flight out of time, and stored
    /// their shallower answers as the reproducible ones. Such a result can be
    /// shown, but it is never what the cache keeps.
    var isCutShort = false
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
    /// Where the position being searched sits in `pathHashes`: everything
    /// before it is the game, everything after it the line being searched.
    private var rootIndex = 0

    private var nodes = 0
    private var deadline: DispatchTime = .distantFuture
    /// Hard cap on searched nodes. A node budget is hardware-independent, so a
    /// search bounded by it returns the same answer on every machine and every
    /// run — which is what makes the game review reproducible.
    private var nodeLimit = Int.max
    private var cancellation: SearchCancellation?
    private var aborted = false
    /// Set alongside `aborted` when what stopped the search was the clock or
    /// the caller, not the node budget — see `PositionAnalysis.isCutShort`.
    private var cutShort = false

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

    /// How many plies of captures `quiescence` may chase past a leaf.
    ///
    /// It used to chase them without limit, on the reasoning that material is
    /// finite so a capture sequence has to end. Promotions are the hole in
    /// that: they are generated in captures-only mode too (a pawn reaching the
    /// last rank is never "quiet"), each pawn offers four of them, and a pawn
    /// race is a position where *nothing* is a capture — so the tree grew on
    /// promotions alone. Measured before this cap: five pawns a side on the
    /// seventh rank burned 1.45 M nodes without finishing depth 1, and the
    /// search fell back on an unsearched move.
    ///
    /// The cap is only applied out of check. Standing pat is what it returns,
    /// and a side in check may not stand pat; in check the node searches its
    /// evasions instead. That is why this alone does not bound the recursion —
    /// see `maxQuiescenceHardPly`.
    private static let maxQuiescencePly = 8

    /// Hard ceiling on quiescence recursion, checks included.
    ///
    /// `maxQuiescencePly` is skipped whenever the node is in check, on the
    /// reasoning that the evasions it searches lead to positions that are out
    /// of check again. They need not: an evasion can itself give check — the
    /// king steps aside and uncovers a line, the capture of the checker
    /// attacks the other king, the interposing piece arrives with check — and
    /// then the child skips the cap in its turn. Measured over a 1170-position
    /// sweep of ordinary self-play, quiescence reached **14** plies against a
    /// cap of 8, and nothing but the deadline poll in `reachedLimit` stood
    /// between it and a chain of checks that never ends.
    ///
    /// At this depth the node answers with its static evaluation whether or
    /// not it is in check, which for a checked side is the very approximation
    /// `maxQuiescencePly` is careful to avoid. It is the only answer that
    /// terminates, and it is kept far enough out that it does not arrive in
    /// place of a real one: twice the soft cap, against a measured maximum of
    /// 14. Verified free — on twelve positions searched to a fixed node budget
    /// the depth, node count, move, score and `hasCloseAlternative` all came
    /// back identical with this in place.
    private static let maxQuiescenceHardPly = 2 * maxQuiescencePly

    /// Ply past which a check no longer extends the search.
    ///
    /// `depth` rises by one for every node in check and falls by one per ply,
    /// so along a forcing sequence of checks it never falls at all. Repetition
    /// detection ends a perpetual check and the node counter backstops it, but
    /// neither is a bound on recursion depth — this is. It matches the ply
    /// range `killers` is sized for, so nothing below it loses its move
    /// ordering either.
    private static let maxExtensionPly = 64

    /// `ttSizeLog2` sizes the transposition table; analysis runs many searches
    /// in parallel and uses a smaller one to keep memory in check.
    init(board: Board, gameHashes: [UInt64], ttSizeLog2: Int = 18) {
        self.board = board
        let path = Self.repetitionPath(gameHashes, endingAt: board)
        self.pathHashes = path
        self.rootIndex = path.count - 1
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
        self.pathHashes = Self.repetitionPath(gameHashes, endingAt: board)
        self.rootIndex = pathHashes.count - 1
        // Killers are ply-indexed, and the tree shifts by a ply between moves,
        // so they are the one table that goes stale.
        killers = Array(repeating: [nil, nil], count: killers.count)
        // History is kept, because which quiet moves tend to work carries over
        // — but halved, so what this position learns outweighs what a position
        // twenty moves ago did.
        ageHistory()
    }

    /// The game's repetition history with the position about to be searched
    /// as its last entry. Every caller hands over `Game.repetitionHashes`,
    /// which already ends there; the root is added only if it is missing, so
    /// that `rootIndex` can always point at it.
    private static func repetitionPath(_ gameHashes: [UInt64], endingAt board: Board) -> [UInt64] {
        gameHashes.last == board.zobrist ? gameHashes : gameHashes + [board.zobrist]
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
        search(strength: difficulty.strength, randomSeed: randomSeed, cancellation: cancellation)
    }

    /// `timeLimit`, when given, replaces the strength's own allowance — a game
    /// on the clock budgets the computer's time from what it has left (see
    /// `AITimeBudget`). It only ever shortens the think in practice: the
    /// budget is capped at the strength's own time.
    func search(
        strength params: AIStrength,
        randomSeed: UInt64,
        cancellation: SearchCancellation? = nil,
        timeLimit: TimeInterval? = nil
    ) -> AISearchResult? {
        var rng = Zobrist.SplitMix64(seed: randomSeed)

        var rootMoves = board.generateLegalMoves()
        guard !rootMoves.isEmpty else { return nil }
        if rootMoves.count == 1 {
            return AISearchResult(move: rootMoves[0], score: 0, depth: 0, nodes: 1)
        }

        // Shuffle so that equally-scored moves vary between games.
        var generator = SeededGenerator(seed: rng.next())
        rootMoves.shuffle(using: &generator)

        deadline = .now() + (timeLimit ?? params.time)
        nodeLimit = .max
        self.cancellation = cancellation
        nodes = 0
        aborted = false
        cutShort = false

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
            } else if bestResult == nil, let bestMove {
                // The iteration ran out of time part way through, and there is
                // no earlier one to fall back on. What it did find still beats
                // the alternative: without this the search returned
                // `rootMoves[0]` — which is *shuffled*, so a random legal move
                // scored and searched not at all.
                //
                // The best move of a half-finished root iteration is sound to
                // keep. `alpha` only rises on a score that came back inside an
                // open lower window, which cannot be a fail-high bound, so
                // every move that claimed the top spot was really worth it.
                // `lastScores` is deliberately left alone: the randomized pick
                // at the lower difficulties wants a full field to choose from,
                // and half a field is worse than none.
                bestResult = AISearchResult(move: bestMove, score: alpha, depth: depth, nodes: nodes)
            } else if params.temperature == 0, let previous = bestResult, let bestMove,
                      bestMove != previous.move {
                // Out of time part way through, with an earlier iteration to
                // fall back on — but this one has already overruled it. The
                // previous best is searched first, so it was given its exact
                // score at this depth, and then another move beat that score
                // with an exact score of its own, for the same reason as
                // above. Keeping the old move meant playing one the deeper
                // search had just shown to be worse.
                //
                // Only at the levels that play the best move. The randomized
                // pick below draws from `lastScores`, a complete iteration, and
                // would replace this move anyway.
                bestResult = AISearchResult(move: bestMove, score: alpha, depth: depth, nodes: nodes)
            }
            if aborted { break }
        }

        // A search the caller abandoned has no answer worth returning.
        if cancellation?.isCancelled == true { return nil }

        guard var result = bestResult else {
            // Not one root move finished — the first one alone spent the whole
            // budget. Nothing has been evaluated, so this is a shuffled move
            // chosen at random; `depth: 0` is how a caller can tell.
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
    /// a position that somehow searches far slower than expected, and a result
    /// it does cut short is marked as such (`PositionAnalysis.isCutShort`).
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
        cutShort = false

        var result: PositionAnalysis?
        let depthCap = max(1, maxDepth)

        for depth in 1...depthCap {
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
            //
            // A mate is asked only when it is the move that was played, the
            // one move whose grade turns on the answer. Any other move is
            // graded without it — unless it mates as fast, and then it is a
            // close alternative itself — and needs what is left of the budget
            // for `settleFocus` below.
            var hasCloseAlternative = true
            var alternativeWinsOutright: Bool?
            if !SearchScore.isMate(bestScore) || focusMove == bestMove {
                (hasCloseAlternative, alternativeWinsOutright) = askAlternatives(
                    to: bestMove, scoring: bestScore, among: rootMoves, depth: depth
                )
                if aborted {
                    // A mate is kept even so. Mates were never asked about
                    // their alternatives before, so one found was one kept,
                    // and losing it to the probes would hand back the depth
                    // before, which had not seen it. What they had not
                    // settled is left as it used to be: nobody singled out.
                    guard SearchScore.isMate(bestScore) else { break }
                    hasCloseAlternative = true
                    alternativeWinsOutright = nil
                }
            }

            result = PositionAnalysis(
                bestMove: bestMove,
                bestScore: bestScore,
                focusScore: focusScore,
                hasCloseAlternative: hasCloseAlternative,
                alternativeWinsOutright: alternativeWinsOutright,
                legalMoveCount: rootMoves.count,
                depth: depth,
                nodes: nodes
            )

            // Best move first makes the next, deeper iteration cheaper.
            if let index = rootMoves.firstIndex(of: bestMove) {
                rootMoves.remove(at: index)
                rootMoves.insert(bestMove, at: 0)
            }

            // A forced mate settles the position, but not the move that was
            // played. It was scored at the depth the mate turned up at — one
            // ply for a mate in one — which is too shallow to see what it
            // does: a slower mate came back as a few pawns up and was graded
            // a miss, and a move that let the other side mate first came
            // back as the material it kept. So the played move alone goes on
            // being deepened until it too comes out as a mate, either way, or
            // the budget runs out. The mate itself needs no more: it is the
            // shortest there is at any depth. When it is the move that was
            // played, the question of its alternatives goes on instead (see
            // `settleAlternatives`).
            if SearchScore.isMate(bestScore) {
                if let focusMove, let focusScore, !SearchScore.isMate(focusScore) {
                    settleFocus(focusMove, from: depth + 1, through: depthCap, into: &result)
                } else if !aborted, focusMove == bestMove {
                    settleAlternatives(
                        to: bestMove, scoring: bestScore, among: rootMoves,
                        from: depth + 1, through: depthCap, into: &result
                    )
                }
                break
            }
        }

        // An iteration the clock or the caller broke off leaves the one before
        // it standing, which a run that had the time would have gone past.
        result?.isCutShort = cutShort
        return result
    }

    /// Searches `focusMove` alone, a ply deeper each time, until its score is
    /// a mate or `lastDepth` or the budget is reached, writing each finished
    /// score into `result`.
    ///
    /// Only a search that finished is written. One the budget or the clock
    /// stops part way through has returned whatever the node it was standing
    /// on said, which is no score at all, and a review that took it would
    /// grade the move worse than the shallower search already had — so the
    /// last complete depth stands, as it does for the main iterations.
    private func settleFocus(
        _ focusMove: Move, from firstDepth: Int, through lastDepth: Int,
        into result: inout PositionAnalysis?
    ) {
        guard firstDepth <= lastDepth else { return }
        for depth in firstDepth...lastDepth {
            let score = rootSearch(focusMove, depth: depth, alpha: -Self.infinity, beta: Self.infinity)
            if aborted { return }
            result?.focusScore = score
            result?.nodes = nodes
            if SearchScore.isMate(score) { return }
        }
    }

    /// After a mate that was the move played, asks again whether anything
    /// else comes close to it, a ply deeper each time, for as long as the
    /// answer still singles the move out and neither `lastDepth` nor the
    /// budget is reached. Each finished answer is written into `result`.
    ///
    /// The mate ends the search at whatever depth it turned up at, and a
    /// combination of checks turns up at two or three plies, which is too
    /// shallow to judge a quiet move by: one that mates a move later, or
    /// wins the queen, reads as nothing much, and the mate as the only move
    /// there was. Once something does come close the move is singled out no
    /// longer, and a deeper look has nothing left to take away. No other
    /// move is graded on the answer, so no other move's mate is asked again,
    /// and the positions that cost the full budget here are the ones whose
    /// move is up for a great or a brilliant grade — the budget every other
    /// position spends anyway.
    private func settleAlternatives(
        to bestMove: Move, scoring bestScore: Int, among rootMoves: [Move],
        from firstDepth: Int, through lastDepth: Int, into result: inout PositionAnalysis?
    ) {
        guard firstDepth <= lastDepth else { return }
        for depth in firstDepth...lastDepth {
            guard result?.hasCloseAlternative == false || result?.alternativeWinsOutright == false
            else { return }
            let answer = askAlternatives(to: bestMove, scoring: bestScore, among: rootMoves, depth: depth)
            if aborted { return }
            result?.hasCloseAlternative = answer.close
            result?.alternativeWinsOutright = answer.winsOutright
            result?.nodes = nodes
        }
    }

    /// Whether any move but `bestMove` comes close to it at `depth` (see
    /// `alternativeThreshold`), and — for a sacrifice that wins outright —
    /// whether any wins outright as well (see
    /// `PositionAnalysis.alternativeWinsOutright`). Answers nothing the
    /// caller may keep once `aborted` is set.
    private func askAlternatives(
        to bestMove: Move, scoring bestScore: Int, among rootMoves: [Move], depth: Int
    ) -> (close: Bool, winsOutright: Bool?) {
        guard let threshold = Self.alternativeThreshold(bestScore: bestScore) else { return (true, nil) }
        let alternatives = rootMoves.filter { $0 != bestMove }
        let close = firstAlternative(in: alternatives[...], reaching: threshold, depth: depth)
        // A sacrifice that wins outright is a find only if nothing else did,
        // which is a higher bar than coming close: a mate with the other
        // moves a rook up is still the one that won the game. Every move
        // ahead of `close` fell short of the lower bar already, so only the
        // rest are asked; with none that came close, none won outright either.
        guard !aborted, bestScore >= Self.wonOutrightScore,
              GameAnalyzer.sacrifice(of: bestMove, in: board) >= GameAnalyzer.minimumSacrifice
        else { return (close != nil, nil) }
        let winsOutright = close.map {
            firstAlternative(in: alternatives[$0...], reaching: Self.wonOutrightScore, depth: depth) != nil
        } ?? false
        return (close != nil, winsOutright)
    }

    /// Index of the first of `moves` that scores at least `threshold` at
    /// `depth`, one null-window probe apiece; nil when none does, or when
    /// the search was stopped on the way, which the caller tells apart by
    /// `aborted`.
    private func firstAlternative(in moves: ArraySlice<Move>, reaching threshold: Int, depth: Int) -> Int? {
        for index in moves.indices {
            let score = rootSearch(moves[index], depth: depth, alpha: threshold - 1, beta: threshold)
            if aborted { return nil }
            if score >= threshold { return index }
        }
        return nil
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
    /// position and in a wild one. Returns nil when the position is lost,
    /// where every move is bad and none deserves singling out.
    ///
    /// A won position is asked like any other, with a forced mate as the
    /// certain win `WinChance` makes it. Both used to be let off, on the
    /// grounds that a decided game has no move worth singling out — but the
    /// move that decides it is often the one most worth it, and a mating
    /// combination never could be: with everything else falling back to
    /// equality, the review still called it merely best. Where several moves
    /// win comfortably the first of them clears the bar, so nothing is
    /// singled out there, and the probes stop at it.
    private static func alternativeThreshold(bestScore: Int) -> Int? {
        let best = WinChance.percent(centipawns: bestScore) / 100
        let target = best - 0.18
        guard target > 0.02 else { return nil }
        return Int((log(target / (1 - target)) / 0.00368208).rounded())
    }

    /// `GameAnalyzer.wonOutright` as a score: the lowest one above the line.
    private static let wonOutrightScore = WinChance.lowestScore(above: GameAnalyzer.wonOutright)

    // MARK: Negamax

    /// `afterNullMove` marks the child of a null move: a board that is a legal
    /// position but is not reachable from its parent by any move.
    private func negamax(
        depth: Int, alpha: Int, beta: Int, ply: Int, afterNullMove: Bool = false
    ) -> Int {
        var alpha = alpha

        if reachedLimit() { return 0 }

        // A variant won by the move that led here — the king on the hill, the
        // third check — is lost for the side on move, as surely as a mate.
        // One comparison for every standard game.
        if board.variant != .standard, board.variantWinner != nil {
            return -(Self.mateScore - ply)
        }

        // Draw detection: fifty-move rule and repetition (`isRepetition` says
        // which repetitions count). Mate outranks the clock, the same way it
        // does in `Game.evaluateOutcome`: a checkmate delivered by the
        // hundredth quiet move is still checkmate, so a node on the clock
        // only scores as a draw once it is known to have a reply.
        if board.halfmoveClock >= 100, !isCheckmated() { return 0 }
        // Every entry point passes `ply: 1` or deeper, so there is no ply-0
        // node to exempt here; the guard that used to test for one only read
        // as though the root were searched through this function too.
        //
        // A null-move child is exempt: passing the turn is not a move, so the
        // board standing here is not a position the game visited, and matching
        // its hash against the ones the game did visit answers a question
        // nobody asked. Appending the null hash to the path instead would be
        // worse — it would let a *real* position deeper down count it as its
        // own first occurrence and score a draw that is not there.
        if !afterNullMove, isRepetition() { return 0 }

        let inCheck = board.isInCheck
        var depth = depth
        if inCheck, ply < Self.maxExtensionPly { depth += 1 } // check extension

        if depth <= 0 {
            return quiescence(alpha: alpha, beta: beta, ply: ply, quiescencePly: 0)
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
            let score = -negamax(
                depth: depth - 3, alpha: -beta, beta: -beta + 1,
                ply: ply + 1, afterNullMove: true
            )
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

    /// `quiescencePly` counts the plies searched since the leaf this descent
    /// started from, which is what `maxQuiescencePly` bounds. It is not the
    /// same as `ply`, which is measured from the root and is what mate scores
    /// and killer slots are indexed by.
    private func quiescence(alpha: Int, beta: Int, ply: Int, quiescencePly: Int) -> Int {
        if reachedLimit() { return 0 }
        // The same variant win `negamax` looks for: a capture can give the
        // third check, or let a king onto the hill.
        if board.variant != .standard, board.variantWinner != nil {
            return -(Self.mateScore - ply)
        }
        // Asked before the check below, because being in check is exactly what
        // lets a node past `maxQuiescencePly` — see `maxQuiescenceHardPly`.
        if quiescencePly >= Self.maxQuiescenceHardPly { return evaluate() }

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
            // A side with no move at all is stalemated, however much it has
            // to stand on: cut off on its material, a stalemate that saves
            // the side behind scored as the position it would have lost. A
            // root move searched with a narrow window — every one after the
            // first — never saw the draw, which then came a ply too late.
            if standPat >= beta { return isStalemate() ? 0 : beta }
            // A variant can be won by a move that captures nothing — a king
            // stepping onto the hill, a quiet third check — and the captures
            // below are all this node would otherwise look at. One ply past
            // the horizon that win was invisible: the search let the other
            // king walk onto the hill to take a pawn, and called a king one
            // step from the centre worth 220 rather than the game. In check
            // every move is searched anyway, and the child's `variantWinner`
            // test sees the win.
            if board.variant != .standard, hasVariantWinningMove() {
                return Self.mateScore - (ply + 1)
            }
            if standPat > alpha { alpha = standPat }
            // Chased far enough. Standing pat is the answer, which is why this
            // is asked only out of check — see `maxQuiescencePly`.
            if quiescencePly >= Self.maxQuiescencePly { return alpha }
        }

        var moves = board.generatePseudoLegalMoves(capturesOnly: !inCheck)
        moves.sort { mvvLva($0) > mvvLva($1) }

        var legalCount = 0
        for move in moves {
            // Delta pruning: skip captures that cannot possibly raise alpha.
            // Not while in check, where the move list is about getting out,
            // not about what it wins. Nor once alpha is a mate: what raises it
            // then is a quicker mate, and no count of material says which
            // capture gives one — Qxg2# was passed over for the pawn it took,
            // behind a slower mate already found, and the review announced
            // mate in three where there was mate in two.
            if !inCheck, alpha < SearchScore.mateThreshold, let captured = move.captured,
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
            let score = -quiescence(
                alpha: -beta, beta: -alpha, ply: ply + 1, quiescencePly: quiescencePly + 1
            )
            board.unmake(move, undo: undo)

            if aborted { return 0 }
            if score >= beta { return beta }
            if score > alpha { alpha = score }
        }

        // In check, no legal move is mate.
        if inCheck, legalCount == 0 { return -(Self.mateScore - ply) }
        // Out of check an empty list usually just means the position is
        // quiet, and `standPat` already stands as its score — unless there is
        // no legal move of any kind, which is stalemate. Left at that, a
        // stalemate at the horizon scored as the material the other side had
        // left, and the search walked into it as a win.
        if !inCheck, legalCount == 0, isStalemate() { return 0 }
        return alpha
    }

    /// Whether the side to move, which is not in check, has no legal move.
    ///
    /// Quiescence asks this of every node with no capture to make, which is
    /// most of them, so it is built to say no cheaply. Only a side down to
    /// king and pawns is examined at all: stalemate with a piece left takes
    /// that piece pinned or shut in as well, rare enough not to be worth a
    /// question on every quiet node of a middlegame. Then a pawn that can
    /// step forward, or a king step to a square nothing guards, settles it;
    /// only a side with neither is given the full move generation. Asking
    /// the full question everywhere instead slowed king-and-pawn endings to
    /// less than half their speed.
    private func isStalemate() -> Bool {
        let mover = board.sideToMove
        let king = board.kingSquare(of: mover)
        let forward = mover == .white ? 8 : -8
        // From the mover's own back rank, where a piece that ends the
        // question usually stands within the first few squares.
        let fromOwnSide = mover == .white
            ? stride(from: 0, through: 63, by: 1) : stride(from: 63, through: 0, by: -1)
        for index in fromOwnSide {
            let packed = board.squares[index]
            guard packed != 0, let piece = Piece(packed: packed), piece.color == mover else { continue }
            switch piece.kind {
            case .king:
                continue
            case .pawn:
                // The square ahead is free, and nothing can pin the pawn
                // against that step: a pin along its own file lets it move,
                // and a pin along a rank or a diagonal needs it on one of
                // those with its king. Pawns never stand on the last rank,
                // so `ahead` is always on the board.
                let ahead = index + forward
                if board.squares[ahead] == 0, !Self.sharesRankOrDiagonal(index, king) { return false }
            default:
                return false
            }
        }

        let file = king & 7, rank = king >> 3
        for (df, dr) in Self.kingSteps {
            let f = file + df, r = rank + dr
            guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
            let target = r * 8 + f
            if let occupant = board.piece(at: target), occupant.color == mover { continue }
            // Out of check, no slider's line runs through the king's own
            // square, so asking with the king still standing there is exact.
            if !board.isSquareAttacked(target, by: mover.opponent) { return false }
        }

        // A pawn pinned along its file, a capture, en passant: the full list.
        for move in board.generatePseudoLegalMoves() {
            let undo = board.make(move)
            let legal = !board.isSquareAttacked(board.kingSquare(of: mover), by: mover.opponent)
            board.unmake(move, undo: undo)
            if legal { return false }
        }
        return true
    }

    private static let kingSteps: [(Int, Int)] = [
        (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)
    ]

    private static func sharesRankOrDiagonal(_ a: Int, _ b: Int) -> Bool {
        let df = (a & 7) - (b & 7), dr = (a >> 3) - (b >> 3)
        return dr == 0 || abs(df) == abs(dr)
    }

    /// Whether the side to move can win the variant with its next move: put
    /// its king on the hill, or give its third check. Only the moves that can
    /// do it are tried, and only once the side is close enough for any to —
    /// a king next to the centre, two checks already given — so a quiet
    /// node away from those pays a comparison or two.
    private func hasVariantWinningMove() -> Bool {
        let mover = board.sideToMove
        switch board.variant {
        case .standard:
            return false
        case .kingOfTheHill:
            guard Self.hillDistance(board.kingSquare(of: mover)) == 1 else { return false }
        case .threeCheck:
            guard board.checksGiven[mover] >= 2 else { return false }
        }
        let onlyKingMoves = board.variant == .kingOfTheHill
        for move in board.generatePseudoLegalMoves() {
            if onlyKingMoves, move.piece.kind != .king || !Board.isHill(move.to.index) { continue }
            let undo = board.make(move)
            let wins = !board.isSquareAttacked(board.kingSquare(of: mover), by: mover.opponent)
                && board.variantWinner == mover
            board.unmake(move, undo: undo)
            if wins { return true }
        }
        return false
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
            // The budget runs out at the same node on every run; the clock
            // and the caller stop the search wherever it happens to be.
            cutShort = nodes < nodeLimit
            return true
        }
        return false
    }

    /// Whether the position on the board, the newest entry in `pathHashes`,
    /// scores as a draw by repetition.
    ///
    /// Where the earlier occurrence lies decides it. One inside the line being
    /// searched, after the root, is enough on its own: whatever brought the
    /// line back once can bring it back again, and calling the second visit a
    /// draw is what keeps the search from shuffling. One in the game is not,
    /// because the game is drawn only on the *third* occurrence. Counting the
    /// game's history as the second used to score every return to a position
    /// seen once before as a draw — a queen up, the review graded a king step
    /// back to an earlier square as throwing the win away, and the losing side
    /// believed the same step saved it. So a position met before only in the
    /// game, the root included, has to have been met there twice.
    ///
    /// A capture or a pawn move cannot be undone, so nothing older than the
    /// last one is looked at; and the same side is on move only every other
    /// ply. Stepping by two has a side effect worth knowing: a null move is
    /// not appended to the path, so below one the parity is off by a ply and
    /// those positions are never matched against the real ones above it.
    private func isRepetition() -> Bool {
        let current = pathHashes.count - 1
        let key = board.zobrist
        let oldest = max(0, current - board.halfmoveClock)
        var earlierInGame = 0
        for index in stride(from: current - 2, through: oldest, by: -2) where pathHashes[index] == key {
            if index > rootIndex { return true }
            earlierInGame += 1
            if earlierInGame >= 2 { return true }
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

        // The variants reward what wins them. On the hill a king that is one
        // step away is a threat the ordinary tables call a weakness, so its
        // distance outweighs them; in three-check every check given is half
        // way to the next.
        switch board.variant {
        case .standard:
            break
        case .kingOfTheHill:
            score += hillBonus(whiteKingSquare) - hillBonus(blackKingSquare)
        case .threeCheck:
            score += Self.checkBonus[Int(min(2, board.checksGiven.white))]
                - Self.checkBonus[Int(min(2, board.checksGiven.black))]
        }

        // Tempo.
        score += board.sideToMove == .white ? 10 : -10

        return board.sideToMove == .white ? score : -score
    }

    /// Three-check: what one and two checks given are worth.
    private static let checkBonus = [0, 160, 420]

    /// King of the Hill: king steps from `king` to the nearest centre square.
    private static func hillDistance(_ king: Int) -> Int {
        let file = king & 7, rank = king >> 3
        let fileDistance = file < 3 ? 3 - file : (file > 4 ? file - 4 : 0)
        let rankDistance = rank < 3 ? 3 - rank : (rank > 4 ? rank - 4 : 0)
        return max(fileDistance, rankDistance)
    }

    /// King of the Hill: what a king's closeness to the centre is worth.
    private func hillBonus(_ king: Int) -> Int {
        switch Self.hillDistance(king) {
        case 0: return 1000
        case 1: return 220
        case 2: return 90
        case 3: return 30
        default: return 0
        }
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

    /// `bookSANs` is the game so far in the SAN the book is written in, which
    /// is what `OpeningBook` matches against. The book only answers when those
    /// moves, played from the standard start, lead to `board` — so an empty
    /// list means the starting position and nothing else, and any other
    /// position is searched. A hint never comes through here: it goes through
    /// `findBestAIMove`, because a hint is advice about the position in front
    /// of the player, and quoting theory at them is not the same thing as
    /// telling them what the engine would play.
    func bestMove(
        board: Board,
        gameHashes: [UInt64],
        difficulty: AIDifficulty,
        bookSANs: [String] = [],
        randomSeed: UInt64 = UInt64.random(in: .min ... .max),
        cancellation: SearchCancellation? = nil
    ) -> AISearchResult? {
        bestMove(
            board: board, gameHashes: gameHashes, strength: difficulty.strength,
            bookSANs: bookSANs, randomSeed: randomSeed, cancellation: cancellation
        )
    }

    func bestMove(
        board: Board,
        gameHashes: [UInt64],
        strength: AIStrength,
        bookSANs: [String] = [],
        randomSeed: UInt64 = UInt64.random(in: .min ... .max),
        cancellation: SearchCancellation? = nil,
        timeLimit: TimeInterval? = nil,
        useBook: Bool = true
    ) -> AISearchResult? {
        // Theory first, at the levels that would otherwise replay one game
        // every time — see `AIDifficulty.playsFromBook`. Nothing is searched
        // here, so the reply also arrives instantly; the caller's minimum
        // thinking pause is what keeps that from looking like a glitch.
        //
        // `useBook` is false for a game that did not start from the initial
        // position. The book checks that the moves lead to `board` as well,
        // which keeps it out of an odds game or a puzzle on its own; the flag
        // is the caller saying so outright.
        if useBook, strength.playsFromBook,
           let bookMove = OpeningBook.move(
               after: bookSANs, in: board, randomSeed: randomSeed
           ) {
            return AISearchResult(
                move: bookMove, score: 0, depth: 0, nodes: 0, isBookMove: true
            )
        }

        return searcher.withLock { searcher in
            searcher.reset(board: board, gameHashes: gameHashes)
            return searcher.search(
                strength: strength, randomSeed: randomSeed,
                cancellation: cancellation, timeLimit: timeLimit
            )
        }
    }
}
