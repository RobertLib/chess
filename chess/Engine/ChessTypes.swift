//
//  ChessTypes.swift
//  chess
//
//  Core value types for the chess engine. Pure Swift, no UI dependencies.
//

import Foundation

// MARK: - Color

nonisolated enum PieceColor: UInt8, Hashable, Codable, Sendable, CaseIterable {
    case white = 0
    case black = 1

    var opponent: PieceColor { self == .white ? .black : .white }
}

// MARK: - Piece kind

nonisolated enum PieceKind: UInt8, Hashable, Codable, Sendable, CaseIterable {
    case pawn = 1
    case knight = 2
    case bishop = 3
    case rook = 4
    case queen = 5
    case king = 6

    /// Rough material value in centipawns. Shared by the evaluation, static
    /// exchange evaluation and the game analyzer so they agree on what a
    /// piece is worth. The king is priceless and scores 0 here.
    var centipawns: Int {
        switch self {
        case .pawn: return 100
        case .knight: return 320
        case .bishop: return 330
        case .rook: return 500
        case .queen: return 900
        case .king: return 0
        }
    }

    /// Letter used in SAN / FEN (uppercase).
    var letter: String {
        switch self {
        case .pawn: return "P"
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }
}

// MARK: - Piece

nonisolated struct Piece: Hashable, Codable, Sendable {
    var color: PieceColor
    var kind: PieceKind

    init(_ color: PieceColor, _ kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    /// Packed byte: bits 0-2 kind, bit 3 color. 0 means empty (no piece).
    var packed: UInt8 { kind.rawValue | (color == .black ? 8 : 0) }

    init?(packed: UInt8) {
        guard packed != 0, let kind = PieceKind(rawValue: packed & 7) else { return nil }
        self.kind = kind
        self.color = (packed & 8) != 0 ? .black : .white
    }

    /// FEN character: uppercase for white, lowercase for black.
    var fenCharacter: Character {
        let letter = kind.letter
        return color == .white ? Character(letter) : Character(letter.lowercased())
    }

    init?(fenCharacter: Character) {
        // Matched letter by letter rather than through `uppercased()`: a
        // character such as "ß" uppercases to *two* letters, and building a
        // `Character` from that traps instead of failing. Twelve cases are
        // cheaper than a crash on a malformed FEN.
        switch fenCharacter {
        case "P": self = Piece(.white, .pawn)
        case "N": self = Piece(.white, .knight)
        case "B": self = Piece(.white, .bishop)
        case "R": self = Piece(.white, .rook)
        case "Q": self = Piece(.white, .queen)
        case "K": self = Piece(.white, .king)
        case "p": self = Piece(.black, .pawn)
        case "n": self = Piece(.black, .knight)
        case "b": self = Piece(.black, .bishop)
        case "r": self = Piece(.black, .rook)
        case "q": self = Piece(.black, .queen)
        case "k": self = Piece(.black, .king)
        default: return nil
        }
    }
}

// MARK: - Square

/// A board square. Index 0 = a1, 7 = h1, 56 = a8, 63 = h8 (index = rank * 8 + file).
nonisolated struct Square: Hashable, Codable, Sendable, CustomStringConvertible {
    var index: Int

    init(_ index: Int) { self.index = index }

    init(file: Int, rank: Int) { self.index = rank * 8 + file }

    /// 0 = a-file ... 7 = h-file
    var file: Int { index & 7 }
    /// 0 = rank 1 ... 7 = rank 8
    var rank: Int { index >> 3 }

    var algebraic: String {
        let files = "abcdefgh"
        let fileChar = files[files.index(files.startIndex, offsetBy: file)]
        return "\(fileChar)\(rank + 1)"
    }

    init?(algebraic: String) {
        guard algebraic.count == 2,
              let fileChar = algebraic.first, let rankChar = algebraic.last,
              let fileIndex = "abcdefgh".firstIndex(of: fileChar),
              let rankValue = rankChar.wholeNumberValue, (1...8).contains(rankValue)
        else { return nil }
        let file = "abcdefgh".distance(from: "abcdefgh".startIndex, to: fileIndex)
        self.init(file: file, rank: rankValue - 1)
    }

    var description: String { algebraic }

    var isLight: Bool { (file + rank) % 2 == 1 }

    static var all: [Square] { (0..<64).map(Square.init) }
}

// MARK: - Castling rights

nonisolated struct CastlingRights: OptionSet, Hashable, Codable, Sendable {
    var rawValue: UInt8

    static let whiteKingside = CastlingRights(rawValue: 1 << 0)
    static let whiteQueenside = CastlingRights(rawValue: 1 << 1)
    static let blackKingside = CastlingRights(rawValue: 1 << 2)
    static let blackQueenside = CastlingRights(rawValue: 1 << 3)

    /// The right to castle towards the h-file (`kingside`) or the a-file.
    static func right(of color: PieceColor, kingside: Bool) -> CastlingRights {
        switch (color, kingside) {
        case (.white, true): return .whiteKingside
        case (.white, false): return .whiteQueenside
        case (.black, true): return .blackKingside
        case (.black, false): return .blackQueenside
        }
    }

    /// The standard-chess spelling, "KQkq". A Chess960 board writes its rights
    /// differently — see `Board.fen`.
    var fenString: String {
        var result = ""
        if contains(.whiteKingside) { result += "K" }
        if contains(.whiteQueenside) { result += "Q" }
        if contains(.blackKingside) { result += "k" }
        if contains(.blackQueenside) { result += "q" }
        return result.isEmpty ? "-" : result
    }
}

// MARK: - Castling rook squares

/// The square the rook of each castling right started the game on.
///
/// In standard chess that is always a corner, and the corners used to be
/// written into `make` as constants. Chess960 stands the rooks wherever its
/// start position puts them, so the board has to carry them. Four bytes rather
/// than an array: `Board` is copied at every node of the search, and an array
/// is one more heap buffer to retain on every copy and to duplicate on the
/// first write to it.
///
/// A right is spent by moving its rook or king, or by losing the rook, never
/// handed on to another rook, so whatever a square says for a right that is
/// still held is where that rook stands. For a right that is not held the
/// square means nothing, and it stands at the standard corner: a FEN leaves
/// it there, and `Board.make` puts it back there as the right is spent, which
/// keeps a position played to and the same position read from its FEN equal.
nonisolated struct CastlingRookSquares: Hashable, Codable, Sendable {
    var whiteKingside: UInt8 = 7    // h1
    var whiteQueenside: UInt8 = 0   // a1
    var blackKingside: UInt8 = 63   // h8
    var blackQueenside: UInt8 = 56  // a8

    /// The corners: standard chess, and every right a Chess960 FEN leaves out.
    static let standard = CastlingRookSquares()

    /// The rook square of one side's kingside or queenside right.
    @inline(__always)
    func square(of color: PieceColor, kingside: Bool) -> Int {
        switch (color, kingside) {
        case (.white, true): return Int(whiteKingside)
        case (.white, false): return Int(whiteQueenside)
        case (.black, true): return Int(blackKingside)
        case (.black, false): return Int(blackQueenside)
        }
    }

    mutating func setSquare(_ index: Int, of color: PieceColor, kingside: Bool) {
        let value = UInt8(index)
        switch (color, kingside) {
        case (.white, true): whiteKingside = value
        case (.white, false): whiteQueenside = value
        case (.black, true): blackKingside = value
        case (.black, false): blackQueenside = value
        }
    }

    /// Puts the squares of `rights`, just spent, back on their corners.
    mutating func resetSquares(of rights: CastlingRights) {
        let standard = Self.standard
        if rights.rawValue & CastlingRights.whiteKingside.rawValue != 0 { whiteKingside = standard.whiteKingside }
        if rights.rawValue & CastlingRights.whiteQueenside.rawValue != 0 { whiteQueenside = standard.whiteQueenside }
        if rights.rawValue & CastlingRights.blackKingside.rawValue != 0 { blackKingside = standard.blackKingside }
        if rights.rawValue & CastlingRights.blackQueenside.rawValue != 0 { blackQueenside = standard.blackQueenside }
    }

    /// The rights whose rook starts on `index`: what a rook leaving that square,
    /// or being taken on it, costs. Empty for every other square.
    ///
    /// Asked whatever the rook's colour, exactly as the corner constants were.
    /// While a right is held its own rook stands on the square, so an enemy
    /// rook there can only strike off a right that is already gone.
    ///
    /// Built on the raw value rather than with `insert`, which in the
    /// unoptimised build the tests run is a generic `SetAlgebra` call — and
    /// this is asked on every rook move while a right is held.
    @inline(__always)
    func rights(atRookSquare index: Int) -> CastlingRights {
        var raw: UInt8 = 0
        if index == Int(whiteKingside) { raw |= CastlingRights.whiteKingside.rawValue }
        if index == Int(whiteQueenside) { raw |= CastlingRights.whiteQueenside.rawValue }
        if index == Int(blackKingside) { raw |= CastlingRights.blackKingside.rawValue }
        if index == Int(blackQueenside) { raw |= CastlingRights.blackQueenside.rawValue }
        return CastlingRights(rawValue: raw)
    }
}

// MARK: - Move

/// A fully-described move. `captured` includes the pawn taken en passant.
///
/// A castling move is the king's, flagged `isCastleKingside` or
/// `isCastleQueenside`, and its `to` depends on the variant:
///
/// - Standard chess: the king's destination, g1 or c1 — "e1g1", as UCI and
///   every saved game and the opening book have always had it.
/// - Chess960: the square of the rook it castles with — "king takes own
///   rook", the way UCI_Chess960 and python-chess write it. The king's
///   destination will not do there: the king may already stand on g1, so
///   "g1g1" would be no move at all, or g1 may be a square the king could
///   also reach by an ordinary step. The rook's square is unambiguous, since
///   no other move lands on a square the mover's own piece holds.
///
/// Either way `Board.make` works out where the king and rook land from the
/// flags and the side, never from `to`; `Board.castlingSquares(for:)` gives
/// the same four squares to anyone else who needs them.
nonisolated struct Move: Hashable, Codable, Sendable, CustomStringConvertible {
    var from: Square
    var to: Square
    var piece: Piece
    var captured: Piece?
    var promotion: PieceKind?
    var isEnPassant: Bool
    var isCastleKingside: Bool
    var isCastleQueenside: Bool
    var isDoublePawnPush: Bool

    init(
        from: Square, to: Square, piece: Piece,
        captured: Piece? = nil, promotion: PieceKind? = nil,
        isEnPassant: Bool = false,
        isCastleKingside: Bool = false, isCastleQueenside: Bool = false,
        isDoublePawnPush: Bool = false
    ) {
        self.from = from
        self.to = to
        self.piece = piece
        self.captured = captured
        self.promotion = promotion
        self.isEnPassant = isEnPassant
        self.isCastleKingside = isCastleKingside
        self.isCastleQueenside = isCastleQueenside
        self.isDoublePawnPush = isDoublePawnPush
    }

    var isCapture: Bool { captured != nil }
    var isCastle: Bool { isCastleKingside || isCastleQueenside }

    /// UCI-style long algebraic, e.g. "e2e4", "e7e8q". A Chess960 castle reads
    /// king square then rook square, "b1a1" — see the note on `to`.
    var uci: String {
        var result = from.algebraic + to.algebraic
        if let promotion { result += promotion.letter.lowercased() }
        return result
    }

    var description: String { uci }
}

// MARK: - Variant

/// The rules a game is played under, beyond the starting position (Chess960
/// is a matter of the starting position and lives on `Board.isChess960`).
nonisolated enum ChessVariant: String, Hashable, Codable, Sendable, CaseIterable {
    case standard
    /// A king that reaches one of the four centre squares — d4, e4, d5,
    /// e5 — wins on the spot. Checkmate still wins too.
    case kingOfTheHill
    /// The third check wins. Checkmate still wins too.
    case threeCheck
}

/// Checks given so far, per side — what three-check is won on. Two bytes, so
/// a `Board` stays cheap to copy.
nonisolated struct CheckCounts: Hashable, Codable, Sendable {
    var white: UInt8 = 0
    var black: UInt8 = 0

    subscript(color: PieceColor) -> UInt8 {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }
}

// MARK: - Game outcome

nonisolated enum GameOutcome: Hashable, Codable, Sendable {
    case ongoing
    case checkmate(winner: PieceColor)
    case stalemate
    case drawFiftyMoveRule
    case drawThreefoldRepetition
    case drawInsufficientMaterial
    case drawAgreed
    case resigned(winner: PieceColor)
    /// The side on move ran out of time and the other could still have mated.
    case timeForfeit(winner: PieceColor)
    /// The side on move ran out of time, but the other side has nothing left
    /// to mate with — a draw under FIDE 6.9, not a win.
    case drawTimeoutInsufficientMaterial
    /// King of the Hill: the winner's king reached the centre.
    case kingOfTheHill(winner: PieceColor)
    /// Three-check: the winner gave the third check.
    case threeChecks(winner: PieceColor)

    var isGameOver: Bool {
        if case .ongoing = self { return false }
        return true
    }

    var isDraw: Bool {
        switch self {
        case .stalemate, .drawFiftyMoveRule, .drawThreefoldRepetition,
             .drawInsufficientMaterial, .drawAgreed, .drawTimeoutInsufficientMaterial:
            return true
        default:
            return false
        }
    }

    var winner: PieceColor? {
        switch self {
        case .checkmate(let winner), .resigned(let winner), .timeForfeit(let winner),
             .kingOfTheHill(let winner), .threeChecks(let winner):
            return winner
        default: return nil
        }
    }
}
