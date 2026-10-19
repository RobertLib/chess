//
//  Puzzle.swift
//  chess
//
//  Tactics puzzles: what one is, how an attempt at it is judged, and the
//  library of them that ships inside the app.
//
//  The library is a selection from the Lichess puzzle database, which Lichess
//  releases under CC0 — see Tools/build_puzzles.py for how it was chosen and
//  checked. Nothing is fetched at run time; the file is part of the bundle.
//

import Foundation

// MARK: - Puzzle

nonisolated struct Puzzle: Hashable, Sendable, Identifiable {
    /// Where a puzzle came from.
    enum Source: String, Hashable, Codable, Sendable {
        /// The bundled library.
        case library
        /// A position from one of the player's own games, where they went
        /// wrong. See `MistakeStore`.
        case mistake
    }

    let id: String
    /// The position before `setup` is played.
    let fen: String
    /// The opponent's move that sets the puzzle, shown to the player before
    /// they are asked anything. Nil when the puzzle starts on the player's
    /// own move.
    let setup: String?
    /// The answer, in UCI: the player's moves alternating with the opponent's
    /// replies, always ending on a move of the player's.
    let solution: [String]
    let rating: Int
    let themes: [String]
    var source: Source = .library

    /// How many moves the player has to find.
    var playerMoveCount: Int { (solution.count + 1) / 2 }

    /// The position the player is asked about, after the setup move.
    func startingGame() -> Game? {
        guard Board(fen: fen) != nil else { return nil }
        var game = Game(fen: fen)
        if let setup {
            guard let move = game.legalMoves.first(where: { $0.uci == setup }) else { return nil }
            game.play(move)
        }
        return game
    }

    /// The side the player plays.
    var playerColor: PieceColor {
        startingGame()?.sideToMove ?? .white
    }

    func hasTheme(_ theme: String) -> Bool { themes.contains(theme) }

    /// Reads one line of the bundled file: `id,fen,moves,rating,themes`, the
    /// moves starting with the opponent's setup move as Lichess writes them.
    init?(libraryLine line: Substring) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 5, let rating = Int(fields[3]) else { return nil }
        let moves = fields[2].split(separator: " ").map(String.init)
        guard moves.count >= 2 else { return nil }
        self.id = String(fields[0])
        self.fen = String(fields[1])
        self.setup = moves[0]
        self.solution = Array(moves.dropFirst())
        self.rating = rating
        self.themes = fields[4].split(separator: " ").map(String.init)
    }

    init(id: String, fen: String, setup: String?, solution: [String],
         rating: Int, themes: [String], source: Source) {
        self.id = id
        self.fen = fen
        self.setup = setup
        self.solution = solution
        self.rating = rating
        self.themes = themes
        self.source = source
    }
}

// MARK: - Attempt

/// One go at a puzzle: the position as it stands, and how far into the
/// solution the player has got.
nonisolated struct PuzzleAttempt: Sendable {

    enum Verdict: Equatable, Sendable {
        /// Right, and there is more to find; `reply` is the opponent's answer,
        /// already played.
        case correct(reply: Move)
        /// Right, and that was the last move.
        case solved
        /// Not the move. `expected` is what the solution wanted.
        case wrong(expected: Move)
    }

    let puzzle: Puzzle
    private(set) var game: Game
    /// Index into `puzzle.solution` of the next move the player must find.
    private(set) var step = 0
    /// True once any move has been wrong — the puzzle can still be finished,
    /// but it no longer counts as solved for the rating.
    private(set) var hadMistake = false
    private(set) var isSolved = false

    /// The side the player plays: the one on move once the setup move is in.
    /// Kept rather than asked of `puzzle`, which would set the puzzle up all
    /// over again — and the board asks for every piece on every redraw.
    let playerColor: PieceColor

    init?(puzzle: Puzzle) {
        guard let game = puzzle.startingGame() else { return nil }
        self.puzzle = puzzle
        self.game = game
        self.playerColor = game.sideToMove
    }

    /// The move the solution wants next.
    var expectedMove: Move? {
        guard step < puzzle.solution.count else { return nil }
        return game.legalMoves.first { $0.uci == puzzle.solution[step] }
    }

    /// The legal move in the position on the board that `san` names, or nil
    /// when none does. Matched by the board's own SAN with the check marks
    /// left off both sides, which still names one move only: SAN tells every
    /// legal move of a position apart without them.
    ///
    /// A `MistakeEntry` keeps the move that was played only as SAN, and this
    /// is how it is turned back into a move — in the very position it was
    /// played in, which is the one a mistake puzzle puts to the player.
    func legalMove(named san: String) -> Move? {
        func plain(_ san: String) -> String {
            san.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "#", with: "")
        }
        let board = game.board
        let legal = board.generateLegalMoves()
        let wanted = plain(san)
        return legal.first { plain(board.san(for: $0, legalMoves: legal)) == wanted }
    }

    /// Judges a move. A wrong move is not played: the position stays as it
    /// was, so the player can try again.
    ///
    /// On the last move any checkmate counts, the way Lichess judges it —
    /// a position can have two mates in one, and the database records only
    /// the one its engine happened to see first.
    mutating func play(_ move: Move) -> Verdict {
        guard let expected = expectedMove, !isSolved else { return .solved }
        let isLast = step == puzzle.solution.count - 1
        var accepted = move == expected
        if !accepted, isLast {
            var probe = game
            probe.play(move)
            if case .checkmate = probe.outcome { accepted = true }
        }
        guard accepted else {
            hadMistake = true
            return .wrong(expected: expected)
        }
        game.play(move)
        step += 1
        if step >= puzzle.solution.count {
            isSolved = true
            return .solved
        }
        guard let reply = game.legalMoves.first(where: { $0.uci == puzzle.solution[step] }) else {
            // A reply the position does not allow means the data is broken;
            // the player found everything there was to find.
            isSolved = true
            return .solved
        }
        game.play(reply)
        step += 1
        return .correct(reply: reply)
    }

    /// Marks the attempt as failed without a wrong move — the player asked
    /// to see the answer.
    mutating func giveUp() {
        hadMistake = true
    }

    /// Plays the next solution move whoever's it is, for showing the answer.
    mutating func playNextSolutionMove() -> Move? {
        guard step < puzzle.solution.count,
              let move = game.legalMoves.first(where: { $0.uci == puzzle.solution[step] })
        else { return nil }
        game.play(move)
        step += 1
        if step >= puzzle.solution.count { isSolved = true }
        return move
    }

    /// Accepts a move the solution did not list but that is as good — the
    /// mistake puzzles ask the engine about a move the player found instead.
    mutating func acceptAlternative(_ move: Move) -> Verdict {
        guard !isSolved else { return .solved }
        game.play(move)
        isSolved = true
        step = puzzle.solution.count
        return .solved
    }
}

// MARK: - Library

/// The bundled puzzles, read once on first use.
nonisolated enum PuzzleLibrary {

    /// Every puzzle in the bundle, easiest first.
    static let all: [Puzzle] = load()

    private static func load() -> [Puzzle] {
        guard let url = Bundle.main.url(forResource: "puzzles", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap(Puzzle.init(libraryLine:))
    }

    static func puzzle(id: String) -> Puzzle? {
        all.first { $0.id == id }
    }

    // MARK: Themes

    /// The themes the app offers to practise, in the order they are listed.
    /// Each is a Lichess theme tag; every one has at least 120 puzzles in the
    /// bundle (see the build script's quotas).
    static let curatedThemes: [String] = [
        "mateIn1", "mateIn2", "mateIn3", "fork", "pin", "skewer",
        "discoveredAttack", "hangingPiece", "backRankMate", "sacrifice",
        "deflection", "attraction", "promotion", "defensiveMove",
        "trappedPiece", "smotheredMate", "doubleCheck", "quietMove",
        "intermezzo", "xRayAttack", "capturingDefender", "clearance",
        "interference", "zugzwang", "endgame", "rookEndgame", "pawnEndgame",
        "opening", "middlegame", "exposedKing", "kingsideAttack", "advancedPawn",
    ]

    static func puzzles(theme: String) -> [Puzzle] {
        all.filter { $0.hasTheme(theme) }
    }

    // MARK: Choosing

    /// A puzzle near `rating`, skipping the ones in `exclude`. The window
    /// widens until it finds something, so a player far off either end of
    /// the library still gets a puzzle rather than nothing.
    ///
    /// Once every puzzle of the pool has been seen it starts over, among the
    /// ones nearest the rating and never with `avoiding` — the puzzle just
    /// played. It used to hand back the single nearest one, the same puzzle
    /// on every "Next".
    static func next(
        near rating: Double, theme: String? = nil, exclude: Set<String>,
        avoiding previous: String? = nil,
        using generator: inout some RandomNumberGenerator
    ) -> Puzzle? {
        let pool = theme.map(puzzles(theme:)) ?? all
        guard !pool.isEmpty else { return nil }
        for window in [100.0, 200, 350, 600, 1000, 3000] {
            let candidates = pool.filter {
                abs(Double($0.rating) - rating) <= window && !exclude.contains($0.id)
            }
            if let pick = candidates.randomElement(using: &generator) { return pick }
        }
        let nearest = pool
            .filter { $0.id != previous }
            .sorted { abs(Double($0.rating) - rating) < abs(Double($1.rating) - rating) }
            .prefix(30)
        return nearest.randomElement(using: &generator) ?? pool.first
    }

    /// The day's puzzle: the same for everybody on the same day, with no
    /// server to ask. Drawn from the middle of the range, where a puzzle is
    /// a fair challenge for most players, by a stride that is coprime with the
    /// pool so consecutive days do not land on neighbours.
    static func daily(for date: Date, calendar: Calendar = .current) -> Puzzle? {
        let pool = dailyPool
        guard !pool.isEmpty else { return nil }
        let day = dayNumber(for: date, calendar: calendar)
        let index = (day &* 7919) % pool.count
        return pool[(index + pool.count) % pool.count]
    }

    static let dailyPool: [Puzzle] = all
        .filter { (1100...2000).contains($0.rating) && $0.solution.count >= 3 }
        .sorted { $0.id < $1.id }

    /// Days since 1 January 2024 in `calendar`'s time zone — the same number
    /// for the whole of a local day.
    ///
    /// Counted in the Gregorian calendar whatever the device is set to: only
    /// the time zone is taken from `calendar`. The epoch is a Gregorian date,
    /// and read in the Buddhist or the Japanese calendar "2024" is another
    /// year altogether, so the numbers jumped by centuries with the setting —
    /// and the daily streak, which compares them, stopped counting.
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let epoch = DateComponents(calendar: gregorian, year: 2024, month: 1, day: 1).date ?? .distantPast
        let start = gregorian.startOfDay(for: epoch)
        let today = gregorian.startOfDay(for: date)
        return gregorian.dateComponents([.day], from: start, to: today).day ?? 0
    }

    /// Puzzles for a rush, easiest first: they start well below the
    /// player's level and climb about thirty points a puzzle.
    static func rushSequence(count: Int, using generator: inout some RandomNumberGenerator) -> [Puzzle] {
        var chosen: [Puzzle] = []
        var seen = Set<String>()
        for index in 0..<count {
            let target = 600.0 + Double(index) * 32
            let window = 60.0 + Double(index) * 2
            let candidates = all.filter {
                abs(Double($0.rating) - target) <= window && !seen.contains($0.id) && $0.solution.count <= 5
            }
            guard let pick = candidates.randomElement(using: &generator)
                ?? all.first(where: { !seen.contains($0.id) && $0.rating >= Int(target) })
            else { break }
            seen.insert(pick.id)
            chosen.append(pick)
        }
        return chosen
    }
}

// MARK: - Rating

/// The player's puzzle rating, on the Elo scale.
///
/// Elo rather than the Glicko the puzzle ratings themselves are measured in:
/// there is one player and nobody to compare them against, so all a rating
/// has to do is move towards the level of the puzzles being solved and stop
/// swinging once it is there. A K-factor that starts large and shrinks with
/// every puzzle does exactly that.
nonisolated enum PuzzleRating {
    static let initial = 1200.0

    static func expectedScore(player: Double, puzzle: Int) -> Double {
        1 / (1 + pow(10, (Double(puzzle) - player) / 400))
    }

    static func kFactor(attempts: Int) -> Double {
        max(16, 60 - Double(attempts) * 0.8)
    }

    /// The new rating after one attempt.
    static func updated(_ rating: Double, puzzle: Int, solved: Bool, attempts: Int) -> Double {
        let change = kFactor(attempts: attempts) * ((solved ? 1 : 0) - expectedScore(player: rating, puzzle: puzzle))
        return max(400, min(3200, rating + change))
    }
}
