//
//  Chess960.swift
//  chess
//
//  The 960 start positions of Chess960 (Fischer Random), by their standard
//  Scharnagl numbers. The rules themselves live with the rest: `Board` reads
//  and writes 960 FENs and the move generator castles 960-style whenever
//  `Board.isChess960` is set.
//

import Foundation

nonisolated enum Chess960 {

    /// Every start position has a number in this range; 518 is the standard
    /// array.
    static let numbers = 0...959

    /// White's back rank for start position `number`, a-file first. Black's
    /// mirrors it.
    ///
    /// Scharnagl's numbering, the one every 960 site and engine uses, reads the
    /// number as a chain of remainders:
    ///
    /// 1. `n % 4` puts the light-squared bishop on b, d, f or h;
    /// 2. the next `% 4` puts the dark-squared bishop on a, c, e or g;
    /// 3. the next `% 6` puts the queen on one of the six squares still empty;
    /// 4. what is left, 0...9, picks the knights' pair of the five empty
    ///    squares — see `knightPlacements`;
    /// 5. the last three squares take rook, king, rook, in that order, which
    ///    is what keeps the king between its rooks.
    ///
    /// Position 0 is BBQNNRKR, 518 RNBQKBNR and 959 RKRNNQBB.
    static func backRank(number: Int) -> [PieceKind] {
        precondition(numbers.contains(number), "Chess960 positions are numbered 0...959, not \(number)")
        var rank = [PieceKind?](repeating: nil, count: 8)
        var rest = number

        // The light squares of the first rank are the b, d, f and h files —
        // b1 is light, a1 dark.
        rank[rest % 4 * 2 + 1] = .bishop
        rest /= 4
        rank[rest % 4 * 2] = .bishop
        rest /= 4

        // File of the `nth` still-empty square, counting from the a-file.
        func emptyFile(_ nth: Int) -> Int {
            rank.indices.filter { rank[$0] == nil }[nth]
        }

        rank[emptyFile(rest % 6)] = .queen
        rest /= 6

        // Both knight squares are found before either is placed: placing the
        // first would renumber the empty squares the second is counted among.
        let knights = knightPlacements[rest]
        let firstKnight = emptyFile(knights.0)
        let secondKnight = emptyFile(knights.1)
        rank[firstKnight] = .knight
        rank[secondKnight] = .knight

        // Each fills the first square still empty, left to right.
        for kind in [PieceKind.rook, .king, .rook] {
            rank[emptyFile(0)] = kind
        }
        return rank.map { $0! }
    }

    /// The knights' two squares among the five left empty once the bishops and
    /// the queen are placed, in Scharnagl's order: NN---, N-N--, N--N-, N---N,
    /// -NN--, -N-N-, -N--N, --NN-, --N-N, ---NN.
    private static let knightPlacements: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (1, 3), (1, 4), (2, 3), (2, 4), (3, 4),
    ]

    /// The FEN of start position `number`, castling written Shredder-style
    /// ("HAha" for 518), so that `Board(fen:)` reads it back as Chess960 —
    /// position 518 included, which as "KQkq" would read as standard chess.
    static func fen(number: Int) -> String {
        let rank = backRank(number: number)
        let white = String(rank.map { Piece(.white, $0).fenCharacter })
        let black = white.lowercased()

        // The king stands between the rooks, so the rook on the higher file is
        // the kingside one; Shredder-FEN names it first, as python-chess does.
        let rookFiles = rank.indices.filter { rank[$0] == .rook }
        let kingside = Board.fileLetter(rookFiles[1])
        let queenside = Board.fileLetter(rookFiles[0])
        let castling = kingside.uppercased() + queenside.uppercased() + kingside + queenside

        return "\(black)/pppppppp/8/8/8/8/PPPPPPPP/\(white) w \(castling) - 0 1"
    }

    /// A start position chosen uniformly from all 960.
    static func randomNumber() -> Int {
        var generator = SystemRandomNumberGenerator()
        return randomNumber(using: &generator)
    }

    /// The same, drawn from `generator`, for a pick that has to be
    /// reproducible from a seed.
    static func randomNumber<Generator: RandomNumberGenerator>(using generator: inout Generator) -> Int {
        Int.random(in: numbers, using: &generator)
    }
}
