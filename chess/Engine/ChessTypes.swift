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

    var fenString: String {
        var result = ""
        if contains(.whiteKingside) { result += "K" }
        if contains(.whiteQueenside) { result += "Q" }
        if contains(.blackKingside) { result += "k" }
        if contains(.blackQueenside) { result += "q" }
        return result.isEmpty ? "-" : result
    }
}

// MARK: - Move

/// A fully-described move. `captured` includes the pawn taken en passant.
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

    /// UCI-style long algebraic, e.g. "e2e4", "e7e8q".
    var uci: String {
        var result = from.algebraic + to.algebraic
        if let promotion { result += promotion.letter.lowercased() }
        return result
    }

    var description: String { uci }
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

    var isGameOver: Bool {
        if case .ongoing = self { return false }
        return true
    }

    var isDraw: Bool {
        switch self {
        case .stalemate, .drawFiftyMoveRule, .drawThreefoldRepetition,
             .drawInsufficientMaterial, .drawAgreed:
            return true
        default:
            return false
        }
    }

    var winner: PieceColor? {
        switch self {
        case .checkmate(let winner), .resigned(let winner): return winner
        default: return nil
        }
    }
}
