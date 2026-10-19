//
//  GameOptions.swift
//  chess
//
//  Everything about a game beyond who is playing whom: the clock, the
//  position it starts from, the adaptive opponent's strength and how the
//  board is laid out for two players.
//

import Foundation

// MARK: - Options

/// The parts of a game's setup that `GameMode` does not carry.
///
/// Kept apart from `GameMode` rather than added to its cases: the mode is
/// written into every saved and finished game, and an enum case that grew a
/// new associated value would no longer decode from what older builds wrote.
/// A separate struct that is simply missing from old data decodes as the
/// standard options instead.
nonisolated struct GameOptions: Hashable, Codable, Sendable {
    /// Nil for a game without a clock.
    var timeControl: TimeControl?
    var start: StartPosition = .standard
    /// The adaptive opponent's strength when the game began, on the 0...4
    /// scale of `AIStrength.interpolated`. Nil for the fixed levels.
    var adaptiveLevel: Double?
    /// Two players facing each other across a device lying flat: the far
    /// side's pieces and card are turned towards them and the board stays put.
    var tabletop = false
    /// King of the Hill, three-check, or the ordinary rules.
    var variant: ChessVariant = .standard

    static let standard = GameOptions()

    init(
        timeControl: TimeControl? = nil,
        start: StartPosition = .standard,
        adaptiveLevel: Double? = nil,
        tabletop: Bool = false,
        variant: ChessVariant = .standard
    ) {
        self.timeControl = timeControl
        self.start = start
        self.adaptiveLevel = adaptiveLevel
        self.tabletop = tabletop
        self.variant = variant
    }

    // Decoded field by field so that a field added later is simply missing
    // from what an older build wrote, rather than a reason to throw the whole
    // saved game away.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A clock this build cannot read leaves the game untimed rather than
        // unreadable. Thrown from here, it took the whole game with it — and
        // after a change to `TimeControl`, every timed game in the archive.
        timeControl = try? container.decodeIfPresent(TimeControl.self, forKey: .timeControl)
        start = (try? container.decodeIfPresent(StartPosition.self, forKey: .start)) ?? .standard
        adaptiveLevel = try container.decodeIfPresent(Double.self, forKey: .adaptiveLevel)
        tabletop = try container.decodeIfPresent(Bool.self, forKey: .tabletop) ?? false
        variant = (try? container.decodeIfPresent(ChessVariant.self, forKey: .variant)) ?? .standard
    }

    var isTimed: Bool { timeControl != nil }
}

// MARK: - Start position

/// Where a game begins.
nonisolated enum StartPosition: Hashable, Codable, Sendable {
    case standard
    /// Fischer Random, by its standard (Scharnagl) number 0...959.
    case chess960(number: Int)
    /// The standard position with one of `giver`'s pieces taken off — the old
    /// way a strong player gives a weaker one a fair game.
    case handicap(Handicap, giver: PieceColor)
    /// A position set up by hand or pasted in.
    case custom(fen: String)

    /// Read in the layout the compiler writes, unchanged, and then vetted: a
    /// Chess960 number outside 0...959, which only stored data gone bad can
    /// carry, is the standard start rather than a trap in
    /// `Chess960.backRank` the moment the game is set up.
    init(from decoder: Decoder) throws {
        switch try Stored(from: decoder) {
        case .standard: self = .standard
        case .chess960(let number):
            self = Chess960.numbers.contains(number) ? .chess960(number: number) : .standard
        case .handicap(let handicap, let giver): self = .handicap(handicap, giver: giver)
        case .custom(let fen): self = .custom(fen: fen)
        }
    }

    /// The same cases, for the decoder the compiler synthesizes.
    private enum Stored: Decodable {
        case standard
        case chess960(number: Int)
        case handicap(Handicap, giver: PieceColor)
        case custom(fen: String)
    }

    var fen: String {
        switch self {
        case .standard: return Board.startFEN
        case .chess960(let number): return Chess960.fen(number: number)
        case .handicap(let handicap, let giver): return handicap.fen(giver: giver)
        case .custom(let fen): return fen
        }
    }

    var isStandard: Bool { self == .standard }

    var isChess960: Bool {
        if case .chess960 = self { return true }
        return false
    }

    /// A position set up by hand or pasted in, rather than one the app deals.
    var isSetUp: Bool {
        if case .custom = self { return true }
        return false
    }

    /// One side begins a piece or a pawn down.
    var isHandicap: Bool {
        if case .handicap = self { return true }
        return false
    }

    /// A fresh start of the same kind, for "play again": a Chess960 game
    /// draws a new position, everything else starts where it did.
    func rerolled() -> StartPosition {
        if case .chess960 = self { return .chess960(number: Chess960.randomNumber()) }
        return self
    }
}

/// Which piece a handicapped side plays without.
nonisolated enum Handicap: String, Hashable, Codable, Sendable, CaseIterable, Identifiable {
    /// The f-pawn — "pawn and move", the gentlest of the classical odds.
    case pawn
    /// The queen's knight.
    case knight
    /// The queen's rook, together with the right to castle on that side.
    case rook
    case queen

    var id: String { rawValue }

    /// The square the piece is taken from, for the side giving the odds.
    func square(for giver: PieceColor) -> Square {
        let rank = giver == .white ? 0 : 7
        switch self {
        case .pawn: return Square(file: 5, rank: giver == .white ? 1 : 6)
        case .knight: return Square(file: 1, rank: rank)
        case .rook: return Square(file: 0, rank: rank)
        case .queen: return Square(file: 3, rank: rank)
        }
    }

    /// The standard position without the piece. Built by editing the board
    /// rather than written out as eight FEN strings, so the two cannot drift
    /// apart — and it goes back through `Board(fen:)` when the game starts, so
    /// the hash and the king squares are rebuilt by the code that owns them.
    func fen(giver: PieceColor) -> String {
        var board = Board.initial
        board.squares[square(for: giver).index] = 0
        if self == .rook {
            board.castlingRights.remove(giver == .white ? .whiteQueenside : .blackQueenside)
        }
        return board.fen
    }
}
