//
//  Board.swift
//  chess
//
//  Position state with make/unmake, FEN support and Zobrist hashing.
//

import Foundation

// MARK: - Zobrist tables

nonisolated enum Zobrist {
    /// Flat table indexed by packed piece byte (1...14) * 64 + square.
    static let pieceKeys: [UInt64] = {
        var generator = SplitMix64(seed: 0x9E3779B97F4A7C15)
        return (0..<(16 * 64)).map { _ in generator.next() }
    }()

    static let blackToMoveKey: UInt64 = {
        var generator = SplitMix64(seed: 0xDEADBEEFCAFEF00D)
        return generator.next()
    }()

    static let castlingKeys: [UInt64] = {
        var generator = SplitMix64(seed: 0x1234567890ABCDEF)
        return (0..<16).map { _ in generator.next() }
    }()

    static let enPassantFileKeys: [UInt64] = {
        var generator = SplitMix64(seed: 0x0F1E2D3C4B5A6978)
        return (0..<8).map { _ in generator.next() }
    }()

    static func key(forPacked packed: UInt8, at square: Int) -> UInt64 {
        pieceKeys[Int(packed) * 64 + square]
    }

    static func key(for piece: Piece, at square: Int) -> UInt64 {
        key(forPacked: piece.packed, at: square)
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - Board

nonisolated struct Board: Hashable, Codable, Sendable {
    /// Packed pieces, index 0 = a1 ... 63 = h8. 0 = empty.
    var squares: [UInt8]
    var sideToMove: PieceColor
    var castlingRights: CastlingRights
    /// Index of the square a pawn just skipped over (target of an en passant capture), or -1.
    var enPassantSquare: Int
    /// Half-moves since the last capture or pawn move (for the fifty-move rule).
    var halfmoveClock: Int
    var fullmoveNumber: Int
    /// Cached king squares: [white, black].
    var kingSquares: [Int]
    /// Incrementally maintained Zobrist hash of the position.
    var zobrist: UInt64

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    // MARK: Accessors

    func piece(at square: Square) -> Piece? {
        Piece(packed: squares[square.index])
    }

    func piece(at index: Int) -> Piece? {
        Piece(packed: squares[index])
    }

    func kingSquare(of color: PieceColor) -> Int {
        kingSquares[Int(color.rawValue)]
    }

    var isInCheck: Bool {
        isSquareAttacked(kingSquare(of: sideToMove), by: sideToMove.opponent)
    }

    // MARK: Init

    static var initial: Board {
        Board(fen: startFEN)!
    }

    init?(fen: String) {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }

        var squares = [UInt8](repeating: 0, count: 64)
        var kingSquares = [-1, -1]

        // Piece placement: ranks 8 -> 1, files a -> h.
        let ranks = fields[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }
        for (rowIndex, rankString) in ranks.enumerated() {
            let rank = 7 - rowIndex
            var file = 0
            for character in rankString {
                if let skip = character.wholeNumberValue, (1...8).contains(skip) {
                    file += skip
                } else if let piece = Piece(fenCharacter: character) {
                    guard file < 8 else { return nil }
                    let index = rank * 8 + file
                    squares[index] = piece.packed
                    if piece.kind == .king { kingSquares[Int(piece.color.rawValue)] = index }
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        guard kingSquares[0] >= 0, kingSquares[1] >= 0 else { return nil }

        // Side to move
        guard let side: PieceColor = fields[1] == "w" ? .white : (fields[1] == "b" ? .black : nil)
        else { return nil }

        // Castling rights
        var rights: CastlingRights = []
        if fields[2] != "-" {
            for character in fields[2] {
                switch character {
                case "K": rights.insert(.whiteKingside)
                case "Q": rights.insert(.whiteQueenside)
                case "k": rights.insert(.blackKingside)
                case "q": rights.insert(.blackQueenside)
                default: return nil
                }
            }
        }

        // En passant target square. The move generator trusts this field, so a
        // square that no double pawn push could have produced is dropped
        // rather than kept: `make` would otherwise remove whatever stands
        // behind it and `unmake` would put a pawn back in its place.
        var enPassant = -1
        if fields[3] != "-" {
            guard let square = Square(algebraic: String(fields[3])) else { return nil }
            if Self.isPlausibleEnPassantSquare(square.index, squares: squares, sideToMove: side) {
                enPassant = square.index
            }
        }

        let halfmove = fields.count > 4 ? Int(fields[4]) ?? 0 : 0
        let fullmove = fields.count > 5 ? Int(fields[5]) ?? 1 : 1

        self.squares = squares
        self.sideToMove = side
        self.castlingRights = rights
        self.enPassantSquare = enPassant
        self.halfmoveClock = halfmove
        self.fullmoveNumber = fullmove
        self.kingSquares = kingSquares
        self.zobrist = 0
        self.zobrist = computeZobrist()
    }

    /// True when `epSquare` is where the pawn the opponent has just pushed two
    /// squares was skipped over: the square is empty and on the sixth rank
    /// (third for Black to move), the pushed pawn stands beyond it and the
    /// square it came from is empty.
    private static func isPlausibleEnPassantSquare(
        _ epSquare: Int, squares: [UInt8], sideToMove: PieceColor
    ) -> Bool {
        let rank = epSquare >> 3
        let pushedPawn: UInt8
        let pawnIndex: Int
        let originIndex: Int
        if sideToMove == .white {
            guard rank == 5 else { return false }
            pushedPawn = Piece(.black, .pawn).packed
            pawnIndex = epSquare - 8
            originIndex = epSquare + 8
        } else {
            guard rank == 2 else { return false }
            pushedPawn = Piece(.white, .pawn).packed
            pawnIndex = epSquare + 8
            originIndex = epSquare - 8
        }
        return squares[epSquare] == 0 && squares[pawnIndex] == pushedPawn && squares[originIndex] == 0
    }

    var fen: String {
        var placement = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var emptyCount = 0
            for file in 0..<8 {
                if let piece = piece(at: rank * 8 + file) {
                    if emptyCount > 0 {
                        placement += String(emptyCount)
                        emptyCount = 0
                    }
                    placement.append(piece.fenCharacter)
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 { placement += String(emptyCount) }
            if rank > 0 { placement += "/" }
        }
        let side = sideToMove == .white ? "w" : "b"
        let enPassant = enPassantSquare >= 0 ? Square(enPassantSquare).algebraic : "-"
        return "\(placement) \(side) \(castlingRights.fenString) \(enPassant) \(halfmoveClock) \(fullmoveNumber)"
    }

    // MARK: Zobrist

    /// True if a pawn of `mover` could (pseudo-legally) capture en passant on `epSquare`.
    /// Only then does the en passant square distinguish positions for repetition purposes.
    private func enPassantIsRelevant(epSquare: Int, mover: PieceColor) -> Bool {
        guard epSquare >= 0 else { return false }
        let file = epSquare & 7
        // The capturing pawn stands beside the double-pushed pawn, one rank
        // "behind" the target square from the mover's perspective.
        let pawnRank = mover == .white ? (epSquare >> 3) - 1 : (epSquare >> 3) + 1
        guard (0..<8).contains(pawnRank) else { return false }
        let ownPawn = Piece(mover, .pawn).packed
        if file > 0, squares[pawnRank * 8 + file - 1] == ownPawn { return true }
        if file < 7, squares[pawnRank * 8 + file + 1] == ownPawn { return true }
        return false
    }

    func computeZobrist() -> UInt64 {
        var hash: UInt64 = 0
        for index in 0..<64 where squares[index] != 0 {
            hash ^= Zobrist.key(forPacked: squares[index], at: index)
        }
        if sideToMove == .black { hash ^= Zobrist.blackToMoveKey }
        hash ^= Zobrist.castlingKeys[Int(castlingRights.rawValue)]
        if enPassantIsRelevant(epSquare: enPassantSquare, mover: sideToMove) {
            hash ^= Zobrist.enPassantFileKeys[enPassantSquare & 7]
        }
        return hash
    }

    // MARK: Make / unmake

    struct Undo {
        var castlingRights: CastlingRights
        var enPassantSquare: Int
        var halfmoveClock: Int
        var zobrist: UInt64
    }

    @discardableResult
    mutating func make(_ move: Move) -> Undo {
        let undo = Undo(
            castlingRights: castlingRights,
            enPassantSquare: enPassantSquare,
            halfmoveClock: halfmoveClock,
            zobrist: zobrist
        )

        let mover = sideToMove
        let from = move.from.index
        let to = move.to.index
        var hash = zobrist

        // Retract state-dependent hash components before mutating.
        hash ^= Zobrist.castlingKeys[Int(castlingRights.rawValue)]
        if enPassantIsRelevant(epSquare: enPassantSquare, mover: mover) {
            hash ^= Zobrist.enPassantFileKeys[enPassantSquare & 7]
        }

        // Halfmove clock
        if move.piece.kind == .pawn || move.isCapture {
            halfmoveClock = 0
        } else {
            halfmoveClock += 1
        }

        // Remove captured piece
        if let captured = move.captured {
            if move.isEnPassant {
                let capturedIndex = mover == .white ? to - 8 : to + 8
                hash ^= Zobrist.key(forPacked: squares[capturedIndex], at: capturedIndex)
                squares[capturedIndex] = 0
            } else {
                hash ^= Zobrist.key(forPacked: squares[to], at: to)
                squares[to] = 0
            }
            // Losing a rook on its home corner removes castling rights.
            if captured.kind == .rook {
                switch to {
                case 0: castlingRights.remove(.whiteQueenside)
                case 7: castlingRights.remove(.whiteKingside)
                case 56: castlingRights.remove(.blackQueenside)
                case 63: castlingRights.remove(.blackKingside)
                default: break
                }
            }
        }

        // Move the piece (with promotion)
        squares[from] = 0
        let placed = move.promotion.map { Piece(mover, $0) } ?? move.piece
        squares[to] = placed.packed
        hash ^= Zobrist.key(for: move.piece, at: from)
        hash ^= Zobrist.key(for: placed, at: to)

        // Castling: also move the rook.
        if move.isCastleKingside {
            let rookFrom = mover == .white ? 7 : 63
            let rookTo = mover == .white ? 5 : 61
            hash ^= Zobrist.key(forPacked: squares[rookFrom], at: rookFrom)
            hash ^= Zobrist.key(forPacked: squares[rookFrom], at: rookTo)
            squares[rookTo] = squares[rookFrom]
            squares[rookFrom] = 0
        } else if move.isCastleQueenside {
            let rookFrom = mover == .white ? 0 : 56
            let rookTo = mover == .white ? 3 : 59
            hash ^= Zobrist.key(forPacked: squares[rookFrom], at: rookFrom)
            hash ^= Zobrist.key(forPacked: squares[rookFrom], at: rookTo)
            squares[rookTo] = squares[rookFrom]
            squares[rookFrom] = 0
        }

        // Update castling rights for king / rook moves.
        if move.piece.kind == .king {
            if mover == .white {
                castlingRights.remove([.whiteKingside, .whiteQueenside])
            } else {
                castlingRights.remove([.blackKingside, .blackQueenside])
            }
            kingSquares[Int(mover.rawValue)] = to
        } else if move.piece.kind == .rook {
            switch from {
            case 0: castlingRights.remove(.whiteQueenside)
            case 7: castlingRights.remove(.whiteKingside)
            case 56: castlingRights.remove(.blackQueenside)
            case 63: castlingRights.remove(.blackKingside)
            default: break
            }
        }

        // En passant target square
        enPassantSquare = move.isDoublePawnPush ? (from + to) / 2 : -1

        if mover == .black { fullmoveNumber += 1 }
        sideToMove = mover.opponent

        // Reapply state-dependent hash components for the new state.
        hash ^= Zobrist.blackToMoveKey
        hash ^= Zobrist.castlingKeys[Int(castlingRights.rawValue)]
        if enPassantIsRelevant(epSquare: enPassantSquare, mover: sideToMove) {
            hash ^= Zobrist.enPassantFileKeys[enPassantSquare & 7]
        }
        zobrist = hash

        return undo
    }

    mutating func unmake(_ move: Move, undo: Undo) {
        let mover = sideToMove.opponent
        let from = move.from.index
        let to = move.to.index

        sideToMove = mover
        if mover == .black { fullmoveNumber -= 1 }

        // Move the piece back (undo promotion).
        squares[from] = move.piece.packed
        squares[to] = 0

        // Restore captured piece.
        if let captured = move.captured {
            if move.isEnPassant {
                let capturedIndex = mover == .white ? to - 8 : to + 8
                squares[capturedIndex] = captured.packed
            } else {
                squares[to] = captured.packed
            }
        }

        // Undo rook move for castling.
        if move.isCastleKingside {
            let rookFrom = mover == .white ? 7 : 63
            let rookTo = mover == .white ? 5 : 61
            squares[rookFrom] = squares[rookTo]
            squares[rookTo] = 0
        } else if move.isCastleQueenside {
            let rookFrom = mover == .white ? 0 : 56
            let rookTo = mover == .white ? 3 : 59
            squares[rookFrom] = squares[rookTo]
            squares[rookTo] = 0
        }

        if move.piece.kind == .king {
            kingSquares[Int(mover.rawValue)] = from
        }

        castlingRights = undo.castlingRights
        enPassantSquare = undo.enPassantSquare
        halfmoveClock = undo.halfmoveClock
        zobrist = undo.zobrist
    }

    // MARK: Material helpers

    /// True when neither side can possibly deliver mate:
    /// K vs K, K+B vs K, K+N vs K, K+B vs K+B with both bishops on same color.
    ///
    /// The search calls this at every leaf, so it counts into locals rather
    /// than collecting the bishops into an array: one heap allocation per node
    /// is not something a hot path can afford. Any pawn, rook or queen settles
    /// the question on the spot, which is why most positions never finish the
    /// scan at all.
    var hasInsufficientMaterial: Bool {
        var knightCount = 0
        var lightBishops = 0
        var darkBishops = 0
        for index in 0..<64 {
            guard let piece = piece(at: index) else { continue }
            switch piece.kind {
            case .pawn, .rook, .queen:
                return false
            case .knight:
                knightCount += 1
            case .bishop:
                if Square(index).isLight { lightBishops += 1 } else { darkBishops += 1 }
            case .king:
                break
            }
        }
        let bishopCount = lightBishops + darkBishops
        let minorCount = knightCount + bishopCount
        if minorCount <= 1 { return true }
        // Two bishops on the same square color (any owners) cannot mate — so
        // either both are light or neither is.
        if knightCount == 0, bishopCount == 2, lightBishops != 1 {
            return true
        }
        return false
    }
}
