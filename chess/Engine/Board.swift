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

    /// Three-check's counters: one key per side and count, `color * 4 + count`.
    static let checkKeys: [UInt64] = {
        var generator = SplitMix64(seed: 0x3C3C3C3C5A5A5A5A)
        return (0..<8).map { _ in generator.next() }
    }()

    static func checkKey(_ color: PieceColor, _ count: UInt8) -> UInt64 {
        checkKeys[Int(color.rawValue) * 4 + Int(min(3, count))]
    }

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
    /// Chess960 (Fischer Random): the back-rank pieces start in one of 960
    /// arrangements, and castling takes king and rook to the squares standard
    /// castling would — g and f, or c and d — from wherever they stand. That
    /// is the only rule that differs, so only castling reads this: generating
    /// it, encoding it in a `Move` (see `Move.to`) and writing it in a FEN.
    /// Fixed for the whole game.
    var isChess960: Bool
    /// Where the rook of each castling right started. Always the corners in
    /// standard chess; see `CastlingRookSquares`.
    var castlingRookSquares: CastlingRookSquares
    /// Index of the square a pawn just skipped over (target of an en passant capture), or -1.
    var enPassantSquare: Int
    /// Half-moves since the last capture or pawn move (for the fifty-move rule).
    var halfmoveClock: Int
    var fullmoveNumber: Int
    /// Cached king squares: [white, black].
    var kingSquares: [Int]
    /// Incrementally maintained Zobrist hash of the position.
    var zobrist: UInt64
    /// The rules beyond the usual ones — King of the Hill, three-check. Fixed
    /// for the whole game; set by `Game(fen:variant:)`, since a FEN does not
    /// say.
    var variant: ChessVariant = .standard
    /// Checks each side has given, counted only in three-check, where they
    /// are part of the position: the same placement with one check more is a
    /// different position, and the hash says so. A three-check FEN carries
    /// them, and the board reads and writes them with the rest (see
    /// `checkCounts(_:remaining:)`); `Game(fen:variant:)` keeps them only
    /// for a three-check game.
    var checksGiven = CheckCounts()

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    /// The largest halfmove clock or move number a FEN is read with.
    static let counterLimit = 100_000

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

    /// Reads a FEN, telling Chess960 from standard chess by its castling
    /// field.
    ///
    /// The field may be written three ways, and all three are read:
    ///
    /// - "KQkq", standard chess.
    /// - Shredder-FEN, "HAha": each right named by the file of its rook,
    ///   uppercase for White. Only Chess960 writes rights this way, so a file
    ///   letter anywhere makes the board a Chess960 one.
    /// - X-FEN, the 960 reading of "KQkq": K is the outermost white rook on
    ///   the king's h-side, Q the outermost on its a-side, and a file letter
    ///   stands in only for an inner rook. Those letters are standard chess's
    ///   before they are X-FEN's, so a board is taken for Chess960 only when
    ///   they describe a 960 back rank: every right names a rook in 960
    ///   terms, no side's rights all fit standard castling, and the array
    ///   shows — a side's king off the e-file *and* one of its rights naming
    ///   a rook off its corner, or both sides showing the same array, kings
    ///   on one file and rooks on the same files, the one back rank mirrored
    ///   the way every 960 game begins. Anything else is a standard FEN with
    ///   stale rights — "KQkq" still written after White castled, a "K" kept
    ///   after the rook stepped off its corner, or "KQ" kept after the king
    ///   stepped off e1 — and stays standard, the rights that no longer hold
    ///   dropped.
    ///
    /// What this cannot see is a 960 game in which the rights no longer show
    /// its array: the standard array written "KQkq", or, once the other
    /// side's rights are gone, a side whose rights are one piece away from
    /// standard castling — its king on the e-file, or its rooks in the
    /// corners. Where only 960 explains a right, it is dropped.
    /// `init(fen:chess960:)` says which it is explicitly, a PGN's Variant
    /// tag says it for the PGN reader, and the app's own 960 FENs are
    /// Shredder-FEN, which always says so.
    init?(fen: String) {
        self.init(fen: fen, castlingMode: nil)
    }

    /// Reads a FEN as Chess960 (`chess960: true`) or as standard chess
    /// (`false`) instead of deciding from the castling field.
    ///
    /// As Chess960, "KQkq" is X-FEN — the outermost rooks — so the standard
    /// start FEN reads as position 518 with castling written king-takes-rook,
    /// and a K or Q with no rook left to name is a stale right, dropped. As
    /// standard chess a rook-file letter is refused, since standard castling
    /// has no way to name one.
    init?(fen: String, chess960: Bool) {
        self.init(fen: fen, castlingMode: chess960)
    }

    /// Reads a FEN as a position of a game played under `variant`, which a
    /// FEN has no way to say — what `Game(fen:variant:)` starts every game
    /// from. The check counts a three-check FEN carries are kept only for a
    /// three-check game: under any other rules they are not part of the
    /// position, and would only be written into every FEN of the game.
    ///
    /// A King of the Hill position whose side to move already has its king
    /// on the hill is refused. That side would have won on its own last
    /// move, before the other side moved, so no game reaches it — the same
    /// reason a three-check FEN in which the side to move has given three
    /// checks is refused. Accepted, it read as a game still going, and
    /// `variantWinner`, which asks only about the side that has just moved,
    /// handed that side the game on whatever it played next. The other
    /// side's king on the hill is where a game won that way ends, and reads
    /// as that game, over.
    init?(fen: String, variant: ChessVariant) {
        self.init(fen: fen)
        if variant == .kingOfTheHill, Self.isHill(kingSquare(of: sideToMove)) { return nil }
        if variant != .threeCheck { checksGiven = CheckCounts() }
        self.variant = variant
        zobrist = computeZobrist()
    }

    /// `castlingMode` is nil to detect the variant, or the variant itself.
    private init?(fen: String, castlingMode: Bool?) {
        var fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }

        // Three-check's counts, wherever the FEN carries them (see
        // `checkCounts(_:remaining:)`), taken out first so that the counters
        // behind them are read where they always are. Lichess's "1+3" in
        // front of them used to be read as a halfmove clock that did not
        // parse, and the halfmove clock as the move number.
        var checks = CheckCounts()
        if fields.count > 4, fields[4].contains("+") {
            checks = Self.checkCounts(fields.remove(at: 4), remaining: true)
        } else if fields.count > 6, fields[6].hasPrefix("+") {
            checks = Self.checkCounts(fields.remove(at: 6).dropFirst(), remaining: false)
        }

        var squares = [UInt8](repeating: 0, count: 64)
        var kingSquares = [-1, -1]
        var kingCounts = [0, 0]

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
                    // A pawn cannot stand on the rank it promotes on, nor on
                    // the one behind its own start. No game reaches such a
                    // position, so what a FEN carrying one really is, is a
                    // typo — and the app's FENs are hand-written lesson
                    // diagrams. Refusing it draws a blank board, which somebody
                    // notices; accepting it draws a lesson with a pawn that has
                    // no moves at all, and quietly teaches the wrong thing.
                    guard piece.kind != .pawn || (1...6).contains(rank) else { return nil }
                    let index = rank * 8 + file
                    squares[index] = piece.packed
                    if piece.kind == .king {
                        kingSquares[Int(piece.color.rawValue)] = index
                        kingCounts[Int(piece.color.rawValue)] += 1
                    }
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        // Exactly one king each. Two of a colour is not merely unreachable: the
        // second one overwrites the first in `kingSquares`, so `isInCheck` and
        // every legality filter would watch one king while the other sat in
        // check — and a king could be captured with the entry left pointing at
        // an empty square.
        guard kingCounts == [1, 1] else { return nil }

        // Side to move
        guard let side: PieceColor = fields[1] == "w" ? .white : (fields[1] == "b" ? .black : nil)
        else { return nil }
        // The third check ends the game, so the side to move cannot have
        // given three already: the game was over before the other side
        // moved. Refused for the reason a side left in check is —
        // `variantWinner` asks only about the side that has just moved, and
        // would hand this one the game on whatever it played next.
        guard checks[side] < 3 else { return nil }

        // Castling rights
        guard let castling = Self.parseCastling(
            fields[2], squares: squares, kingSquares: kingSquares, mode: castlingMode
        ) else { return nil }

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

        // Clamped, because the counters are only ever counted up: a pasted
        // FEN carrying Int.max would trap on the first `+= 1` in `make`. No
        // game comes near either bound, and the fifty-move rule reads 150 as
        // well as it reads 9 223 372 036 854 775 807.
        let halfmove = min(max(fields.count > 4 ? Int(fields[4]) ?? 0 : 0, 0), Self.counterLimit)
        let fullmove = min(max(fields.count > 5 ? Int(fields[5]) ?? 1 : 1, 1), Self.counterLimit)

        self.squares = squares
        self.sideToMove = side
        self.castlingRights = castling.rights
        self.isChess960 = castling.isChess960
        self.castlingRookSquares = castling.rookSquares
        self.enPassantSquare = enPassant
        self.halfmoveClock = halfmove
        self.fullmoveNumber = fullmove
        self.kingSquares = kingSquares
        self.checksGiven = checks
        self.zobrist = 0
        self.zobrist = computeZobrist()

        // The side that has just moved may not still be in check: the move
        // that left its king there would have been illegal, so no such
        // position can arise from play. Two kings standing next to each other
        // is the same fault seen from the other end — each attacks the other,
        // so one of them is the non-mover in check.
        //
        // Refused rather than tolerated because the move generator would
        // otherwise offer a capture of the enemy *king*, and `make` keeps
        // `kingSquares` in step only for the side that moves: taking a king
        // would leave the entry pointing at an empty square, and every later
        // `isInCheck` would read it. Checked here, at the same door the en
        // passant square is vetted at, so nothing downstream has to.
        guard !isSquareAttacked(kingSquare(of: side.opponent), by: side) else { return nil }
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

    /// Three-check's counts as a FEN writes them, "w+b", White's first.
    /// Lichess writes the checks each side has still to give, as a field of
    /// its own before the halfmove clock — "3+3" at the start, "1+3" once
    /// White has given two (`remaining`). Older Lichess FENs wrote the checks
    /// given so far after the move number instead, "+2+0". These are the two
    /// forms python-chess reads, and the counts mean the same in both. A
    /// count that does not read counts as no check given, the way a counter
    /// that does not read is taken as its default.
    private static func checkCounts(_ field: Substring, remaining: Bool) -> CheckCounts {
        let parts = field.split(separator: "+", omittingEmptySubsequences: false)
        func given(_ index: Int) -> UInt8 {
            guard parts.count == 2, let count = Int(parts[index]) else { return 0 }
            let clamped = UInt8(min(max(count, 0), 3))
            return remaining ? 3 - clamped : clamped
        }
        return CheckCounts(white: given(0), black: given(1))
    }

    // MARK: Castling field

    private struct CastlingSetup {
        var rights: CastlingRights
        var rookSquares: CastlingRookSquares
        var isChess960: Bool
    }

    /// One letter of the castling field: a wing (K, Q, k, q) or a rook file
    /// (A–H, a–h).
    private enum CastlingToken {
        case wing(PieceColor, kingside: Bool)
        case file(PieceColor, Int)
    }

    /// Reads the castling field — see `init(fen:)` for the three spellings.
    /// `mode` is nil to detect the variant, true for Chess960, false for
    /// standard chess.
    private static func parseCastling(
        _ field: Substring, squares: [UInt8], kingSquares: [Int], mode: Bool?
    ) -> CastlingSetup? {
        guard field != "-" else {
            return CastlingSetup(rights: [], rookSquares: .standard, isChess960: mode ?? false)
        }

        var tokens: [CastlingToken] = []
        for character in field {
            // Matched on the ASCII value, not on a `Character` range: "A"..."H"
            // also holds "B" followed by a combining accent, which sorts
            // between "B" and "C" and has no ASCII value to take a file from.
            guard let ascii = character.asciiValue else { return nil }
            switch ascii {
            case UInt8(ascii: "K"): tokens.append(.wing(.white, kingside: true))
            case UInt8(ascii: "Q"): tokens.append(.wing(.white, kingside: false))
            case UInt8(ascii: "k"): tokens.append(.wing(.black, kingside: true))
            case UInt8(ascii: "q"): tokens.append(.wing(.black, kingside: false))
            case UInt8(ascii: "A")...UInt8(ascii: "H"):
                tokens.append(.file(.white, Int(ascii - UInt8(ascii: "A"))))
            case UInt8(ascii: "a")...UInt8(ascii: "h"):
                tokens.append(.file(.black, Int(ascii - UInt8(ascii: "a"))))
            default: return nil
            }
        }

        let isChess960: Bool
        switch mode {
        case true?:
            isChess960 = true
        case false?:
            guard tokens.allSatisfy({ if case .wing = $0 { true } else { false } }) else { return nil }
            isChess960 = false
        case nil:
            isChess960 = isChess960Field(tokens, squares: squares, kingSquares: kingSquares)
        }

        // Standard chess keeps a right only while its king stands on e1 (e8)
        // and its rook in the corner. One whose king or rook has gone is not
        // merely inert: the generator asks for both only when it castles, so
        // a right kept for an empty corner would come back to life the moment
        // some other rook walked into it — "K" pasted with the rook on h2,
        // then Rh1, and O-O was on offer.
        guard isChess960 else {
            var rights: CastlingRights = []
            for case .wing(let color, let kingside) in tokens
            where isStandardCastlingSetup(color, kingside: kingside, king: kingSquares[Int(color.rawValue)], squares: squares) {
                rights.insert(.right(of: color, kingside: kingside))
            }
            return CastlingSetup(rights: rights, rookSquares: .standard, isChess960: false)
        }

        // Chess960 has to know *which* rook each right castles with, so every
        // right must name one: a king on its back rank and a rook of its colour
        // on that rank, on the side the right belongs to. None is kept inert
        // as standard chess would keep it, because it would have no square to
        // be written back with — the FEN this board writes would name an empty
        // file, and fail to read.
        //
        // A file letter that names nothing contradicts the board, and the FEN
        // is refused. A K or Q that names nothing — no rook left on that side
        // of the king, or the king gone from its rank — is the stale right an
        // X-FEN leaves behind, and is dropped, as standard chess drops one.
        // Refusing it cost the whole FEN: a PGN whose Variant tag said 960 was
        // read as standard chess instead, and the other side's rights, which
        // only 960 explains, went with it.
        var rights: CastlingRights = []
        var rookSquares = CastlingRookSquares.standard
        for token in tokens {
            let color: PieceColor
            let kingside: Bool
            let rookSquare: Int
            switch token {
            case .wing(let wingColor, let wingKingside):
                color = wingColor
                kingside = wingKingside
                guard let outermost = outermostRook(
                    color, kingside: kingside, king: kingSquares[Int(color.rawValue)], squares: squares
                ) else { continue }
                rookSquare = outermost
            case .file(let fileColor, let file):
                color = fileColor
                let base = color == .white ? 0 : 56
                let king = kingSquares[Int(color.rawValue)]
                guard king >> 3 == base >> 3, file != king & 7,
                      squares[base + file] == Piece(color, .rook).packed
                else { return nil }
                kingside = file > king & 7
                rookSquare = base + file
            }
            let right = CastlingRights.right(of: color, kingside: kingside)
            // Saying the same right twice is harmless ("KH" with the rook on
            // h1); naming two different rooks for one wing is not.
            if rights.contains(right),
               rookSquares.square(of: color, kingside: kingside) != rookSquare {
                return nil
            }
            rights.insert(right)
            rookSquares.setSquare(rookSquare, of: color, kingside: kingside)
        }
        return CastlingSetup(rights: rights, rookSquares: rookSquares, isChess960: true)
    }

    /// Whether a castling field read without being told the variant is a
    /// Chess960 one — see `init(fen:)` for the rule.
    ///
    /// A side whose rights all fit standard castling is evidence for standard
    /// chess, not against it. A FEN pairing "kq" from the corners with a "K"
    /// for a rook on g1 cannot be a 960 game at all — both sides start from
    /// one array — and is a standard one that forgot to strike the K off. A
    /// right that names no rook is the stale right a standard FEN leaves
    /// behind once the side has castled; read as 960 it would refuse the FEN.
    ///
    /// A side whose rights are one piece away from standard castling is no
    /// evidence either way, however many rights it holds. A standard FEN
    /// leaves rights behind whenever a piece leaves its square and nobody
    /// strikes them off — a rook stepping off its corner, or the king off e1
    /// with both rooks still at home, the commonest way a king loses the
    /// right to castle — and a 960 game whose king starts on the e-file, or
    /// whose rooks start in the corners, has the same rights. A FEN without
    /// a word about the variant is far more often the first. "KQ" with the
    /// king on e1 and the rooks on a1 and g1 was read as 960, written "GA"
    /// and offering O-O, which standard chess does not have there; so was
    /// "KQ" with the king on f1 and the rooks on a1 and h1, offering both.
    ///
    /// What does show the array is a side two pieces away — its king off the
    /// e-file and a rook it names off its corner, which no single stale
    /// right explains — or the two sides together: kings on one file, and
    /// every wing both of them hold naming a rook on the same file, an array
    /// that is not the standard one. That is how every 960 game begins and
    /// no pair of stale rights is likely to look. A 960 game in which each
    /// side has kept a right, so most of them a few moves in, still reads as
    /// 960 by either.
    private static func isChess960Field(
        _ tokens: [CastlingToken], squares: [UInt8], kingSquares: [Int]
    ) -> Bool {
        if tokens.contains(where: { if case .file = $0 { true } else { false } }) { return true }
        // The file of the rook each right names, by side and by wing
        // (kingside first), or -1 for a right not held.
        var rookFiles = [[-1, -1], [-1, -1]]
        var namesRookOffCorner = [false, false]
        for case .wing(let color, let kingside) in tokens {
            let side = Int(color.rawValue)
            guard let rook = outermostRook(color, kingside: kingside, king: kingSquares[side], squares: squares)
            else { return false }
            rookFiles[side][kingside ? 0 : 1] = rook & 7
            if rook & 7 != (kingside ? 7 : 0) { namesRookOffCorner[side] = true }
        }
        // Every right names a rook on its king's back rank, so the king
        // stands there, and its file is all that is left to ask about.
        let kingFiles = kingSquares.map { $0 & 7 }
        let holdsRight = rookFiles.map { $0 != [-1, -1] }
        for side in 0..<2 where holdsRight[side] {
            // Standard castling, every right of it.
            guard kingFiles[side] != 4 || namesRookOffCorner[side] else { return false }
        }
        if (0..<2).contains(where: { holdsRight[$0] && kingFiles[$0] != 4 && namesRookOffCorner[$0] }) { return true }

        guard holdsRight[0], holdsRight[1], kingFiles[0] == kingFiles[1] else { return false }
        var isStandardArray = kingFiles[0] == 4
        for wing in 0..<2 where rookFiles[0][wing] >= 0 && rookFiles[1][wing] >= 0 {
            guard rookFiles[0][wing] == rookFiles[1][wing] else { return false }
            if rookFiles[0][wing] != (wing == 0 ? 7 : 0) { isStandardArray = false }
        }
        return !isStandardArray
    }

    /// Whether a K/Q/k/q right can be standard castling: the king on e1 (e8)
    /// and a rook of its colour in that corner.
    private static func isStandardCastlingSetup(
        _ color: PieceColor, kingside: Bool, king: Int, squares: [UInt8]
    ) -> Bool {
        let base = color == .white ? 0 : 56
        return king == base + 4 && squares[base + (kingside ? 7 : 0)] == Piece(color, .rook).packed
    }

    /// The rook an X-FEN K/Q (k/q) stands for: the outermost rook of `color`
    /// on its back rank on that side of the king. Nil when the king is off its
    /// back rank or there is no such rook.
    private static func outermostRook(
        _ color: PieceColor, kingside: Bool, king: Int, squares: [UInt8]
    ) -> Int? {
        let base = color == .white ? 0 : 56
        guard king >> 3 == base >> 3 else { return nil }
        let rook = Piece(color, .rook).packed
        let kingFile = king & 7
        if kingside {
            for file in stride(from: 7, to: kingFile, by: -1) where squares[base + file] == rook {
                return base + file
            }
        } else {
            for file in 0..<kingFile where squares[base + file] == rook {
                return base + file
            }
        }
        return nil
    }

    /// The castling field this board writes.
    ///
    /// Standard chess writes "KQkq" as it always has. Chess960 writes
    /// Shredder-FEN, every right as its rook's file: "HAha" for the standard
    /// array. X-FEN would write that same position "KQkq", which reads back as
    /// standard chess — the one spelling that cannot carry the variant
    /// through `Game`'s replay from its `initialFEN`. With no rights left the
    /// variant no longer matters to anything, and the field is "-".
    private var castlingField: String {
        guard isChess960, !castlingRights.isEmpty else { return castlingRights.fenString }
        var field = ""
        for (color, kingside) in [(PieceColor.white, true), (.white, false), (.black, true), (.black, false)]
        where castlingRights.contains(.right(of: color, kingside: kingside)) {
            let letter = Board.fileLetter(castlingRookSquares.square(of: color, kingside: kingside) & 7)
            field += color == .white ? letter.uppercased() : letter
        }
        return field
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
        // Three-check's counts go in once a check has been given, the way
        // Lichess and python-chess write them (see `checkCounts`). Until then
        // the FEN is the plain one, which every reader takes for no checks
        // given — so a three-check game from the start still has the start
        // FEN as its `initialFEN`, and a FEN that does carry counts carries
        // them through the replay `Game.atStart` makes from it.
        var counts = ""
        if checksGiven != CheckCounts() {
            counts = " \(3 - min(3, checksGiven.white))+\(3 - min(3, checksGiven.black))"
        }
        return "\(placement) \(side) \(castlingField) \(enPassant)\(counts) \(halfmoveClock) \(fullmoveNumber)"
    }

    // MARK: Zobrist

    /// True if a pawn of `mover` can capture en passant on `epSquare` without
    /// leaving its own king in check. Only then does the en passant square
    /// distinguish positions for repetition purposes: positions are the same
    /// when the same moves can be played in them, and a capture that would
    /// expose the king is not one that can be — the way FIDE counts them,
    /// and python-chess.
    ///
    /// Mutating only to try the capture on the board and take it back, which
    /// is asked for only once a pawn stands ready to make it: after most
    /// double pushes none does, and the search pays for two square reads.
    private mutating func enPassantIsRelevant(epSquare: Int, mover: PieceColor) -> Bool {
        guard epSquare >= 0 else { return false }
        let file = epSquare & 7
        // The capturing pawn stands beside the double-pushed pawn, one rank
        // "behind" the target square from the mover's perspective.
        let pawnRank = mover == .white ? (epSquare >> 3) - 1 : (epSquare >> 3) + 1
        guard (0..<8).contains(pawnRank) else { return false }
        let ownPawn = Piece(mover, .pawn).packed
        let pushedPawn = pawnRank * 8 + file
        if file > 0, squares[pushedPawn - 1] == ownPawn,
           enPassantKeepsKingSafe(from: pushedPawn - 1, to: epSquare, taking: pushedPawn, mover: mover) {
            return true
        }
        if file < 7, squares[pushedPawn + 1] == ownPawn,
           enPassantKeepsKingSafe(from: pushedPawn + 1, to: epSquare, taking: pushedPawn, mover: mover) {
            return true
        }
        return false
    }

    /// Plays an en passant capture on the squares alone, asks whether the
    /// mover's king is attacked, and puts the three squares back. The king
    /// itself never moves in one, so `kingSquares` is left alone.
    private mutating func enPassantKeepsKingSafe(from: Int, to: Int, taking captured: Int, mover: PieceColor) -> Bool {
        let pawn = squares[from]
        let capturedPawn = squares[captured]
        squares[from] = 0
        squares[captured] = 0
        squares[to] = pawn
        let safe = !isSquareAttacked(kingSquares[Int(mover.rawValue)], by: mover.opponent)
        squares[from] = pawn
        squares[captured] = capturedPawn
        squares[to] = 0
        return safe
    }

    func computeZobrist() -> UInt64 {
        var hash: UInt64 = 0
        for index in 0..<64 where squares[index] != 0 {
            hash ^= Zobrist.key(forPacked: squares[index], at: index)
        }
        if sideToMove == .black { hash ^= Zobrist.blackToMoveKey }
        hash ^= Zobrist.castlingKeys[Int(castlingRights.rawValue)]
        if enPassantSquare >= 0 {
            // A copy to try the capture on; its squares are copied only if a
            // pawn stands ready to make it.
            var probe = self
            if probe.enPassantIsRelevant(epSquare: enPassantSquare, mover: sideToMove) {
                hash ^= Zobrist.enPassantFileKeys[enPassantSquare & 7]
            }
        }
        if variant == .threeCheck {
            hash ^= Zobrist.checkKey(.white, checksGiven.white) ^ Zobrist.checkKey(.black, checksGiven.black)
        }
        return hash
    }

    // MARK: Variants

    /// The four centre squares King of the Hill is won on: d4, e4, d5, e5.
    static let hillSquares = [27, 28, 35, 36]

    @inline(__always)
    static func isHill(_ index: Int) -> Bool {
        index == 27 || index == 28 || index == 35 || index == 36
    }

    /// The side that has won by the variant's own rule. Only the move just
    /// played can have done it, so the answer is always the side that is not
    /// on move — or nobody.
    var variantWinner: PieceColor? {
        switch variant {
        case .standard:
            return nil
        case .kingOfTheHill:
            let mover = sideToMove.opponent
            return Self.isHill(kingSquare(of: mover)) ? mover : nil
        case .threeCheck:
            let mover = sideToMove.opponent
            return checksGiven[mover] >= 3 ? mover : nil
        }
    }

    // MARK: Castling squares

    /// Where the king and the rook of a castling move start and end, or nil
    /// for any other move — for whoever has to show a castle rather than play
    /// it, such as a board animating its pieces.
    ///
    /// Ask the board the move is played from. Where the king lands and where
    /// the rook goes depend only on the move, so any position of the same
    /// game gives those two; where the rook starts is known only while its
    /// right is held, and the board after the castle has spent it (see
    /// `CastlingRookSquares`).
    ///
    /// The four squares may overlap. In Chess960 the king can already stand on
    /// its destination (`kingFrom == kingTo`), and so can the rook; or the two
    /// can trade places, the king landing where the rook stood. A caller moving
    /// pieces by square therefore has to find both pieces before moving
    /// either. `move.to` is not one of the answers to rely on: it is the king's
    /// destination in standard chess but the rook's square in Chess960 (see
    /// `Move`).
    func castlingSquares(
        for move: Move
    ) -> (kingFrom: Square, kingTo: Square, rookFrom: Square, rookTo: Square)? {
        guard move.isCastle else { return nil }
        let castle = castlingGeometry(color: move.piece.color, kingside: move.isCastleKingside)
        return (move.from, Square(castle.kingTo), Square(castle.rookFrom), Square(castle.rookTo))
    }

    /// The squares of one side's castle as indices: the rook it castles with,
    /// and where king and rook land — g and f kingside, c and d queenside, in
    /// either variant.
    @inline(__always)
    func castlingGeometry(color: PieceColor, kingside: Bool) -> (kingTo: Int, rookFrom: Int, rookTo: Int) {
        let base = color == .white ? 0 : 56
        return (
            kingTo: base + (kingside ? 6 : 2),
            rookFrom: castlingRookSquares.square(of: color, kingside: kingside),
            rookTo: base + (kingside ? 5 : 3)
        )
    }

    // MARK: Make / unmake

    struct Undo {
        var castlingRights: CastlingRights
        var castlingRookSquares: CastlingRookSquares
        var enPassantSquare: Int
        var halfmoveClock: Int
        var zobrist: UInt64
        var checksGiven: CheckCounts
    }

    @discardableResult
    mutating func make(_ move: Move) -> Undo {
        let undo = Undo(
            castlingRights: castlingRights,
            castlingRookSquares: castlingRookSquares,
            enPassantSquare: enPassantSquare,
            halfmoveClock: halfmoveClock,
            zobrist: zobrist,
            checksGiven: checksGiven
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
            // Losing a rook on its castling square removes that right. Most of
            // a game is played with no rights left, and then there is nothing
            // to look up. (The raw value is compared because `isEmpty` is a
            // generic `SetAlgebra` call in the unoptimised build the tests run.)
            if captured.kind == .rook, castlingRights.rawValue != 0 {
                castlingRights.remove(castlingRookSquares.rights(atRookSquare: to))
            }
        }

        if move.isCastleKingside || move.isCastleQueenside {
            // King and rook both move, to squares worked out from the flag and
            // the side rather than read from `to`, which names the king's
            // destination in standard chess and the rook's square in Chess960
            // (see `Move`). Both are lifted before either is put down: in 960
            // one may land where the other stood — king f1 and rook g1 simply
            // swap — and writing in order would overwrite one with the other.
            let castle = castlingGeometry(color: mover, kingside: move.isCastleKingside)
            let king = move.piece.packed
            let rook = squares[castle.rookFrom]
            hash ^= Zobrist.key(forPacked: king, at: from)
            hash ^= Zobrist.key(forPacked: rook, at: castle.rookFrom)
            hash ^= Zobrist.key(forPacked: king, at: castle.kingTo)
            hash ^= Zobrist.key(forPacked: rook, at: castle.rookTo)
            squares[from] = 0
            squares[castle.rookFrom] = 0
            squares[castle.kingTo] = king
            squares[castle.rookTo] = rook
            kingSquares[Int(mover.rawValue)] = castle.kingTo
        } else {
            // Move the piece (with promotion)
            squares[from] = 0
            let placed = move.promotion.map { Piece(mover, $0) } ?? move.piece
            squares[to] = placed.packed
            hash ^= Zobrist.key(for: move.piece, at: from)
            hash ^= Zobrist.key(for: placed, at: to)
            if move.piece.kind == .king {
                kingSquares[Int(mover.rawValue)] = to
            }
        }

        // Update castling rights for king / rook moves.
        if move.piece.kind == .king {
            if mover == .white {
                castlingRights.remove([.whiteKingside, .whiteQueenside])
            } else {
                castlingRights.remove([.blackKingside, .blackQueenside])
            }
        } else if move.piece.kind == .rook, castlingRights.rawValue != 0 {
            castlingRights.remove(castlingRookSquares.rights(atRookSquare: from))
        }
        // A right spent names no rook any more, and its square goes back to
        // the corner, where a FEN read afresh would leave it.
        if castlingRights.rawValue != undo.castlingRights.rawValue {
            castlingRookSquares.resetSquares(
                of: CastlingRights(rawValue: undo.castlingRights.rawValue & ~castlingRights.rawValue)
            )
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
        // Three-check counts a check as it is given. The only variant that
        // pays for the attack test here; every other game skips it on one
        // comparison.
        if variant == .threeCheck,
           isSquareAttacked(kingSquares[Int(sideToMove.rawValue)], by: mover) {
            let before = checksGiven[mover]
            if before < 3 {
                hash ^= Zobrist.checkKey(mover, before) ^ Zobrist.checkKey(mover, before + 1)
                checksGiven[mover] = before + 1
            }
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
        // First, because a castle has just spent the right that says where
        // its rook came from.
        castlingRookSquares = undo.castlingRookSquares

        if move.isCastleKingside || move.isCastleQueenside {
            // The mirror of `make`: both pieces lifted before either goes
            // back, for the same overlap.
            let castle = castlingGeometry(color: mover, kingside: move.isCastleKingside)
            let rook = squares[castle.rookTo]
            squares[castle.kingTo] = 0
            squares[castle.rookTo] = 0
            squares[castle.rookFrom] = rook
            squares[from] = move.piece.packed
        } else {
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
        }

        if move.piece.kind == .king {
            kingSquares[Int(mover.rawValue)] = from
        }

        castlingRights = undo.castlingRights
        enPassantSquare = undo.enPassantSquare
        halfmoveClock = undo.halfmoveClock
        zobrist = undo.zobrist
        checksGiven = undo.checksGiven
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
    ///
    /// The variants change the question. On the hill a bare king can still
    /// win by walking to the centre, so nothing is ever insufficient; in
    /// three-check any piece at all can give checks, so only two bare kings
    /// are a dead draw.
    var hasInsufficientMaterial: Bool {
        if variant != .standard {
            guard variant == .threeCheck else { return false }
            for index in 0..<64 where squares[index] != 0 && squares[index] & 7 != PieceKind.king.rawValue {
                return false
            }
            return true
        }
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
        // Bishops that all run on one colour of square can never mate,
        // however many there are and whoever owns them. More than two takes
        // an underpromotion, but a dead position is dead either way.
        if knightCount == 0, bishopCount >= 2, lightBishops == 0 || darkBishops == 0 {
            return true
        }
        return false
    }
}
