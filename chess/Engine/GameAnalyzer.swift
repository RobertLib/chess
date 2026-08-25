//
//  GameAnalyzer.swift
//  chess
//
//  Post-game analysis: every position is searched full-width so each played
//  move can be compared with the engine's choice, then classified (best,
//  inaccuracy, blunder …) and turned into an accuracy score per player.
//

import Foundation

// MARK: - Move quality

/// How good a played move turned out to be. Ordered from best to worst, apart
/// from `book`, which sidesteps judgement for known opening theory.
nonisolated enum MoveQuality: String, Sendable, Hashable, CaseIterable, Codable {
    case brilliant
    case great
    case best
    case excellent
    case good
    case book
    case inaccuracy
    case mistake
    case miss
    case blunder

    /// Worth calling out in a summary of the game.
    var isMistake: Bool {
        switch self {
        case .inaccuracy, .mistake, .miss, .blunder: return true
        default: return false
        }
    }

    var isStandout: Bool {
        self == .brilliant || self == .great
    }
}

// MARK: - Win expectancy

/// Maps centipawns to win expectancy, and win expectancy to accuracy. Both
/// curves follow the ones Lichess uses, so numbers here are comparable with
/// what players are used to seeing elsewhere.
nonisolated enum WinChance {

    /// Win expectancy in percent (0...100) for the side the score belongs to.
    static func percent(centipawns: Int) -> Double {
        if SearchScore.isMate(centipawns) { return centipawns > 0 ? 100 : 0 }
        let clamped = Double(max(-2000, min(2000, centipawns)))
        return 50 + 50 * (2 / (1 + exp(-0.00368208 * clamped)) - 1)
    }

    /// Accuracy in percent for a move that gave up `pointsLost` of win
    /// expectancy. Small slips barely register; a lost game costs everything.
    static func accuracy(pointsLost: Double) -> Double {
        let value = 103.1668 * exp(-0.04354 * max(0, pointsLost)) - 3.1669
        return min(100, max(0, value))
    }
}

// MARK: - One analysed move

nonisolated struct MoveAnalysis: Sendable, Identifiable {
    /// Index into the game's move history.
    let ply: Int
    let played: PlayedMove
    /// Position the move was played in.
    let board: Board

    /// The engine's choice here, and its score (mover's point of view).
    let bestMove: Move
    let bestSAN: String
    let bestScore: Int
    /// Exact score of the move actually played (mover's point of view).
    let playedScore: Int
    /// The opponent's best answer to the move that was played.
    let refutation: Move?
    let refutationSAN: String?

    let quality: MoveQuality
    let searchDepth: Int
    /// Material the move hands over in the exchange on its target square.
    let sacrifice: Int

    var id: Int { ply }
    var color: PieceColor { played.color }
    var isBestMove: Bool { played.move == bestMove || playedScore >= bestScore }

    /// Win expectancy before and after, from the mover's point of view.
    var winBefore: Double { WinChance.percent(centipawns: bestScore) }
    var winAfter: Double { WinChance.percent(centipawns: playedScore) }
    var pointsLost: Double { max(0, winBefore - winAfter) }
    var accuracy: Double { WinChance.accuracy(pointsLost: pointsLost) }

    /// Centipawns thrown away, capped so that a mate score cannot dominate an
    /// average.
    var centipawnLoss: Int { min(1000, max(0, bestScore - playedScore)) }

    /// Evaluation after the move, always from White's point of view.
    var evalWhite: Int { color == .white ? playedScore : -playedScore }
    /// Evaluation before the move (best play), from White's point of view.
    var evalBeforeWhite: Int { color == .white ? bestScore : -bestScore }
}

// MARK: - Per-player report

nonisolated struct SideReport: Sendable {
    let color: PieceColor
    /// Mean per-move accuracy in percent, or nil when this player never got to
    /// move.
    ///
    /// Optional rather than a stand-in figure because there is no honest
    /// number for "played nothing": resigning before your first turn is legal
    /// (against the computer it is always the human who resigns, so playing
    /// Black and giving up before moving does it), and a fabricated 100 made
    /// the review congratulate the player on a flawless game they had not
    /// played a move of. A dash is what the card and the dial show instead.
    let accuracy: Double?
    let counts: [MoveQuality: Int]
    /// Mean centipawn loss over the game, nil for a player who never moved —
    /// "0 cp lost / move" would be the same invention as an accuracy of 100.
    let averageCentipawnLoss: Int?
    /// The move that cost the most, when there was a real mistake.
    let worstPly: Int?
    /// The best moment of the game, when there was a standout move.
    let bestPly: Int?

    func count(_ quality: MoveQuality) -> Int { counts[quality] ?? 0 }

    /// A short verdict on how the player did overall, or nil when there is no
    /// accuracy to pass judgement on.
    var verdict: String? {
        guard let accuracy else { return nil }
        switch accuracy {
        case 95...: return String(localized: "Flawless", comment: "Verdict on a player's accuracy")
        case 88..<95: return String(localized: "verdict.excellent", defaultValue: "Excellent", comment: "Verdict on a player's accuracy")
        case 82..<88: return String(localized: "Very good", comment: "Verdict on a player's accuracy")
        case 72..<82: return String(localized: "Solid", comment: "Verdict on a player's accuracy")
        case 58..<72: return String(localized: "Shaky", comment: "Verdict on a player's accuracy")
        default: return String(localized: "Rough", comment: "Verdict on a player's accuracy")
        }
    }
}

// MARK: - Whole-game analysis

nonisolated struct GameAnalysis: Sendable {
    let moves: [MoveAnalysis]
    let white: SideReport
    let black: SideReport
    let openingName: String?
    /// Evaluation from White's point of view, one entry per position:
    /// index 0 is the starting position, index i + 1 the position after move i.
    let evalCurve: [Int]

    func report(for color: PieceColor) -> SideReport {
        color == .white ? white : black
    }

    func move(at ply: Int) -> MoveAnalysis? {
        if moves.indices.contains(ply), moves[ply].ply == ply { return moves[ply] }
        return moves.first { $0.ply == ply }
    }
}

// MARK: - Analyzer

nonisolated enum GameAnalyzer {

    /// How hard the engine looks at each position. The node budget is the real
    /// limit — it does not depend on how fast the device is, so re-running the
    /// review over the same game gives the same grades every time. The depth
    /// cap only matters in simple endgames, and the time limit is a safety net
    /// for a position that searches unexpectedly slowly.
    struct Settings: Sendable {
        var maxDepth: Int
        var nodesPerPosition: Int
        var timeLimitPerPosition: TimeInterval

        /// The node figure is calibrated against the wall-clock budget this
        /// used to carry (0.55 s), so the review reaches the same depth it
        /// always did — it just no longer depends on how busy the device is.
        ///
        /// The time limit has to stay well clear of what the node budget
        /// actually costs, or it — not the node count — is what bounds the
        /// search, and the grades go back to depending on the hardware. The
        /// budget measures at roughly 0.8 s per position on a fast desktop
        /// core; the oldest phone this app runs on is several times slower
        /// than that, and most of the workers land on its efficiency cores, so
        /// the old 6 s could genuinely bind there. Thirty seconds is a net for
        /// a search that has gone wrong, not a second budget. Nothing hangs on
        /// it: the search polls its cancellation token every 2048 nodes, so
        /// closing the review still stops instantly.
        static let standard = Settings(
            maxDepth: 18, nodesPerPosition: 1_000_000, timeLimitPerPosition: 30.0
        )
    }

    /// One position to search. Everything here is a value type, so jobs can be
    /// handed to background tasks freely.
    struct Job: Sendable {
        let index: Int
        let board: Board
        let repetitionHashes: [UInt64]
        /// The move played from this position, so the search can score it
        /// exactly alongside its own choice. Nil for the final position.
        let playedMove: Move?
    }

    // MARK: Positions

    /// Every position of the game, from the start to the final one, together
    /// with the repetition history that applies at that point.
    static func positions(of game: Game) -> [Job] {
        var replay = Game(fen: game.initialFEN)
        var jobs: [Job] = []
        for played in game.history {
            jobs.append(Job(
                index: jobs.count,
                board: replay.board,
                repetitionHashes: replay.repetitionHashes,
                playedMove: played.move
            ))
            replay.play(played.move)
        }
        // The final position, for the last move's refutation and eval.
        jobs.append(Job(
            index: jobs.count,
            board: replay.board,
            repetitionHashes: replay.repetitionHashes,
            playedMove: nil
        ))
        return jobs
    }

    /// Searches one position. Safe to call from a background task.
    static func run(
        _ job: Job, settings: Settings, cancellation: SearchCancellation? = nil
    ) -> PositionAnalysis? {
        analyzePosition(
            board: job.board,
            gameHashes: job.repetitionHashes,
            maxDepth: settings.maxDepth,
            nodeBudget: settings.nodesPerPosition,
            timeLimit: settings.timeLimitPerPosition,
            focusMove: job.playedMove,
            cancellation: cancellation
        )
    }

    // MARK: Assembly

    /// Turns raw position searches into the finished report. `results` must line
    /// up with `positions(of:)`: one entry per position, the last of which is
    /// the final position and may be nil when the game ended there.
    static func assemble(
        game: Game,
        jobs: [Job],
        results: [PositionAnalysis?]
    ) -> GameAnalysis {
        let book = OpeningBook.match(sans: game.history.map(\.san))
        var moves: [MoveAnalysis] = []
        moves.reserveCapacity(game.history.count)

        for (ply, played) in game.history.enumerated() {
            guard ply < jobs.count, ply < results.count,
                  let analysis = results[ply] else { continue }
            let board = jobs[ply].board
            let bestMove = analysis.bestMove
            // The played move's score comes from the very same search as the
            // best move's, so the two are directly comparable. Search
            // instability can hand back a marginally higher score for the
            // played move; taking the maximum keeps "lost nothing" honest.
            let playedScore = analysis.focusScore ?? analysis.bestScore
            let bestScore = max(analysis.bestScore, playedScore)

            // The opponent's answer comes from the search of the next
            // position, which is the position this move led to.
            let nextIndex = ply + 1
            let refutation = nextIndex < results.count ? results[nextIndex]?.bestMove : nil
            let refutationSAN = refutation.flatMap { move in
                nextIndex < jobs.count ? jobs[nextIndex].board.san(for: move) : nil
            }
            let sacrifice = max(0, -board.staticExchangeEvaluation(played.move))
            // Taking back on the square the opponent just captured on is
            // forced far more often than it is inspired.
            let previous = ply > 0 ? game.history[ply - 1].move : nil
            let isRecapture = played.move.isCapture
                && previous?.isCapture == true
                && previous?.to == played.move.to

            let quality = classify(
                bestScore: bestScore,
                playedScore: playedScore,
                isBest: played.move == bestMove || playedScore >= analysis.bestScore,
                hasCloseAlternative: analysis.hasCloseAlternative,
                sacrifice: sacrifice,
                legalMoveCount: analysis.legalMoveCount,
                isRecapture: isRecapture,
                wasInCheck: board.isInCheck,
                isBook: ply < book.bookPlies
            )

            moves.append(MoveAnalysis(
                ply: ply,
                played: played,
                board: board,
                bestMove: bestMove,
                bestSAN: board.san(for: bestMove),
                bestScore: bestScore,
                playedScore: playedScore,
                refutation: refutation,
                refutationSAN: refutationSAN,
                quality: quality,
                searchDepth: analysis.depth,
                sacrifice: sacrifice
            ))
        }

        return GameAnalysis(
            moves: moves,
            white: report(for: .white, moves: moves),
            black: report(for: .black, moves: moves),
            openingName: book.name,
            evalCurve: evalCurve(plyCount: game.history.count, moves: moves)
        )
    }

    /// One evaluation per position, from White's point of view. Indexed by ply
    /// so a position the search could not reach simply holds the last value.
    private static func evalCurve(plyCount: Int, moves: [MoveAnalysis]) -> [Int] {
        let byPly = Dictionary(uniqueKeysWithValues: moves.map { ($0.ply, $0) })
        var curve = [Int](repeating: 0, count: plyCount + 1)
        // Starting point: what the engine thought before anyone had moved.
        var value = byPly[0]?.evalBeforeWhite ?? 0
        curve[0] = value
        for ply in 0..<plyCount {
            if let move = byPly[ply] { value = move.evalWhite }
            curve[ply + 1] = value
        }
        return curve
    }

    private static func report(for color: PieceColor, moves: [MoveAnalysis]) -> SideReport {
        let own = moves.filter { $0.color == color }
        guard !own.isEmpty else {
            // Nothing to grade, so nothing is claimed: no accuracy, no verdict
            // and no centipawn loss. The report still exists — the breakdown
            // table wants a column of zeroes beside the other player's grades.
            return SideReport(
                color: color, accuracy: nil, counts: [:],
                averageCentipawnLoss: nil, worstPly: nil, bestPly: nil
            )
        }

        var counts: [MoveQuality: Int] = [:]
        for move in own { counts[move.quality, default: 0] += 1 }

        // The plain mean says how the player did move to move; the harmonic
        // mean makes sure a single disaster is not averaged away. Taking both
        // together, as Lichess does, gives a figure that rewards consistency
        // without ignoring the one move that lost the game.
        let scores = own.map { max(1, $0.accuracy) }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let harmonic = Double(scores.count) / scores.reduce(0) { $0 + 1 / $1 }
        let accuracy = (mean + harmonic) / 2
        let loss = own.reduce(0) { $0 + $1.centipawnLoss } / own.count

        let worst = own
            .filter { $0.quality.isMistake }
            .max { $0.pointsLost < $1.pointsLost }
        // A brilliancy outranks a merely great move as the game's high point.
        let bestMoment = own.first { $0.quality == .brilliant }
            ?? own.first { $0.quality == .great }

        return SideReport(
            color: color,
            accuracy: accuracy,
            counts: counts,
            averageCentipawnLoss: loss,
            worstPly: worst?.ply,
            bestPly: bestMoment?.ply
        )
    }

    // MARK: Classification

    /// Grades one move. All scores are centipawns from the mover's point of
    /// view; `bestScore` is what the engine's own choice was worth.
    static func classify(
        bestScore: Int,
        playedScore: Int,
        isBest: Bool,
        hasCloseAlternative: Bool,
        sacrifice: Int,
        legalMoveCount: Int,
        isRecapture: Bool,
        wasInCheck: Bool,
        isBook: Bool
    ) -> MoveQuality {
        let winBefore = WinChance.percent(centipawns: bestScore)
        let winAfter = WinChance.percent(centipawns: playedScore)
        let lost = max(0, winBefore - winAfter)

        if isBest {
            // A sound sacrifice: material goes, the position holds up.
            if sacrifice >= 200, winAfter >= 45, winBefore <= 97 {
                return .brilliant
            }
            // The only move that keeps the position — everything else drops
            // off a cliff. Forced recaptures and check evasions do not count:
            // there the alternatives are bad by default, not by insight.
            if !hasCloseAlternative, !isRecapture, !wasInCheck, legalMoveCount >= 5 {
                return .great
            }
            return isBook ? .book : .best
        }

        if isBook { return .book }

        // Walking past a short forced mate is worth pointing out even when the
        // move played keeps a winning position.
        let mateOnOffer = SearchScore.mateInMoves(bestScore) ?? 0
        let playedMates = (SearchScore.mateInMoves(playedScore) ?? 0) > 0
        let missedMate = mateOnOffer > 0 && mateOnOffer <= 4 && !playedMates

        // A position that was overwhelmingly won and still is deserves no black
        // mark for taking the slower road home.
        if !missedMate, winBefore >= 95, winAfter >= 90 {
            return lost < 2 ? .excellent : .good
        }

        // Thresholds are in win-expectancy points, on the scale players know
        // from Lichess: a dropped pawn is an inaccuracy, an exchange a mistake,
        // a whole piece a blunder.
        switch lost {
        case ..<2: return missedMate ? .miss : .excellent
        case ..<5: return missedMate ? .miss : .good
        case ..<10: return missedMate ? .miss : .inaccuracy
        default:
            // Letting a won position slip reads as a missed chance rather than
            // a blunder, as long as it is not thrown away outright.
            if winBefore >= 65, winAfter >= 50 { return .miss }
            return lost < 25 ? .mistake : .blunder
        }
    }
}
