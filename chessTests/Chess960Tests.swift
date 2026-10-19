//
//  Chess960Tests.swift
//  chessTests
//
//  Chess960 (Fischer Random): castling from any start position, the FEN
//  spellings that carry it, Scharnagl's numbering of the 960 positions, and
//  everything downstream that used to take the king for an e1 king and the
//  rooks for corner rooks.
//
//  Reference counts: python-chess 1.11.2, `chess.Board(fen, chess960=True)`,
//  perft counted by a plain recursion over `board.legal_moves`. Before these
//  were written down the generator was also compared with it move by move
//  (perft divide) on several thousand random 960 positions, none differing.
//

import Testing
@testable import chess

// MARK: - Perft

@Suite("Chess960 perft")
struct Chess960PerftTests {

    /// Depth 4 only for the two positions richest in castling, depth 3 for the
    /// rest: that keeps the whole suite to about the node count of the
    /// standard one, which in a Debug build is what decides its time. (All
    /// eight agree with python-chess at depth 4 as well, and the deeper counts
    /// are in the comments for whoever wants to raise them.)
    nonisolated static let positions: [PerftTests.Position] = [
        PerftTests.Position(
            name: "Start position 0 — BBQNNRKR",
            fen: "bbqnnrkr/pppppppp/8/8/8/8/PPPPPPPP/BBQNNRKR w HFhf - 0 1",
            counts: [20, 400, 9_006] // depth 4: 201_143
        ),
        // The standard array as a 960 game. Castling is written king-takes-
        // rook here, but it is the same move, so the tree is the standard one.
        PerftTests.Position(
            name: "Start position 518 — the standard array, as Chess960",
            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w HAha - 0 1",
            counts: [20, 400, 8_902] // depth 4: 197_281
        ),
        PerftTests.Position(
            name: "Start position 397 — QRNBNKBR",
            fen: "qrnbnkbr/pppppppp/8/8/8/8/PPPPPPPP/QRNBNKBR w HBhb - 0 1",
            counts: [20, 400, 8_950] // depth 4: 198_623
        ),
        // White's king already stands on g1, so O-O moves only the rook;
        // Black's king on f8 and rook on g8 trade places when it castles short.
        PerftTests.Position(
            name: "King already home, and king and rook swapping",
            fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1",
            counts: [24, 576, 13_518, 317_771]
        ),
        // Both rooks already stand on their destinations, d and f.
        PerftTests.Position(
            name: "Rooks beside the king, which do not move",
            fen: "3rkr2/pppppppp/8/8/8/8/PPPPPPPP/3RKR2 w FDfd - 0 1",
            counts: [23, 529, 12_012] // depth 4: 272_716
        ),
        // O-O takes the king from b1 across the c1 rook to g1; O-O-O is
        // blocked by that same rook until it moves.
        PerftTests.Position(
            name: "Rook between the king and its destination",
            fen: "rkr5/pppppppp/8/8/8/8/PPPPPPPP/RKR5 w CAca - 0 1",
            counts: [22, 484, 10_720] // depth 4: 237_384
        ),
        // White may not castle short — the bishops watch d1 and e1 on the
        // king's way — but may castle long, the rook landing on the watched
        // d1. Black's short castle crosses f8, which the a3 bishop holds.
        PerftTests.Position(
            name: "Castling through attacked squares",
            fen: "r3k2r/8/8/8/6bb/B7/8/RK5R w HAha - 0 1",
            counts: [21, 672, 15_631] // depth 4: 514_037
        ),
        // King b1 and rook a1 castle long, with check down the d-file. Black's
        // long castle, d8 to c8, looks safe while the b8 rook shields c8 from
        // the a8 queen, and is illegal because that rook is the one leaving.
        PerftTests.Position(
            name: "King on b1 with the a1 rook, and a shielding rook",
            fen: "Qr1k4/8/8/8/8/5b2/1P6/RK6 w Ab - 0 1",
            counts: [24, 395, 9_752, 160_737]
        ),
    ]

    @Test("Node counts match python-chess", arguments: positions)
    func perftMatchesReference(position: PerftTests.Position) throws {
        var board = try #require(Board(fen: position.fen), "FEN should parse")
        #expect(board.isChess960)
        for (index, expected) in position.counts.enumerated() {
            let depth = index + 1
            #expect(
                PerftTests.perft(&board, depth) == expected,
                "perft(\(depth)) for \(position.name)"
            )
        }
    }

    @Test("Searching and unsearching leaves the position untouched", arguments: positions)
    func treeWalkIsNonDestructive(position: PerftTests.Position) throws {
        var board = try #require(Board(fen: position.fen))
        let before = board
        _ = PerftTests.perft(&board, 3)
        #expect(board == before, "\(position.name) came back changed")
    }
}

// MARK: - FEN

@Suite("Chess960 FEN")
struct Chess960FENTests {

    @Test("Shredder-FEN survives a round trip", arguments: [
        "bbqnnrkr/pppppppp/8/8/8/8/PPPPPPPP/BBQNNRKR w HFhf - 0 1",
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w HAha - 0 1",
        "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1",
        "Qr1k4/8/8/8/8/5b2/1P6/RK6 w Ab - 0 1",
        "5kr1/6p1/8/8/8/8/6P1/1r4KR w Hg - 0 2",
    ])
    func shredderRoundTrip(fen: String) throws {
        let board = try #require(Board(fen: fen))
        #expect(board.isChess960)
        #expect(board.fen == fen)
        // And reading the output again gives the same board, variant included.
        #expect(Board(fen: board.fen) == board)
    }

    @Test("X-FEN is read as the outermost rooks and written back as rook files", arguments: [
        // King off the e-file: KQkq cannot be standard castling.
        ("1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w KQkq - 0 1",
         "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1"),
        ("rkr5/pppppppp/8/8/8/8/PPPPPPPP/RKR5 w KQkq - 0 1",
         "rkr5/pppppppp/8/8/8/8/PPPPPPPP/RKR5 w CAca - 0 1"),
        // Kings on the e-file, but both kingside rooks on g, off the corner.
        ("r3k1r1/8/8/8/8/8/8/R3K1R1 w KQkq - 0 1",
         "r3k1r1/8/8/8/8/8/8/R3K1R1 w GAga - 0 1"),
        // An inner rook is named by its file: B is the b1 rook, not the
        // outermost a1 one.
        ("4k3/8/8/8/8/8/8/RR1K3R w KB - 0 1",
         "4k3/8/8/8/8/8/8/RR1K3R w HB - 0 1"),
    ])
    func xfenIsRead(input: String, expected: String) throws {
        let board = try #require(Board(fen: input))
        #expect(board.isChess960)
        #expect(board.fen == expected)
    }

    @Test("Standard FENs stay standard, and stale rights are dropped")
    func standardStaysStandard() throws {
        let start = try #require(Board(fen: Board.startFEN))
        #expect(!start.isChess960)
        #expect(start.fen == Board.startFEN)

        // Rights with no rook anywhere on that side are not a 960 setup. They
        // are not kept either: a right needs its king and its rook at home.
        let stale = try #require(Board(fen: "4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1"))
        #expect(!stale.isChess960)
        #expect(stale.fen == "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    }

    @Test("A stale right does not come back when a rook reaches the corner")
    func staleRightStaysGone() throws {
        // "K" with the rook on h2: no castling now, and none after Rh1 either.
        var game = Game(fen: "4k3/8/8/8/8/8/7R/4K3 w K - 0 1")
        #expect(game.board.castlingRights.isEmpty)
        for uci in ["h2h1", "e8d8"] {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }))
        }
        #expect(!game.legalMoves.contains { $0.isCastle })
    }

    @Test("The variant can be asked for instead of detected")
    func explicitVariant() throws {
        // Position 518 written "KQkq" is standard chess unless the caller says
        // otherwise — and then it writes itself so that it stays 960.
        let as960 = try #require(Board(fen: Board.startFEN, chess960: true))
        #expect(as960.isChess960)
        #expect(as960.fen == Chess960.fen(number: 518))

        let asStandard = try #require(Board(fen: Board.startFEN, chess960: false))
        #expect(!asStandard.isChess960)
        #expect(asStandard == Board.initial)
        // Standard castling has no way to name a rook file.
        #expect(Board(fen: Chess960.fen(number: 518), chess960: false) == nil)
    }

    @Test("A castling field that names no castling rook is refused", arguments: [
        "4k3/8/8/8/8/8/8/R3K2R w G - 0 1",       // no rook on g1
        "4k3/8/8/8/8/8/8/R3K2R w E - 0 1",       // the king's own file
        "4k3/8/8/8/8/8/8/R3K1RR w HG - 0 1",     // two rooks for one wing
        "4k3/8/8/8/8/8/4K3/R6R w HA - 0 1",      // king off its back rank
        "4k3/8/8/8/8/8/8/R3K2R w h - 0 1",       // Black has no rook on h8
        "4k3/8/8/8/8/8/8/R3K2R w B\u{301} - 0 1", // a letter with a combining accent
    ])
    func rejectsBadCastlingFields(fen: String) {
        #expect(Board(fen: fen) == nil, "should not have parsed: \(fen)")
    }

    @Test("A 960 board with no castling rights left writes a dash")
    func noRightsWriteADash() throws {
        var board = try #require(Board(fen: "1r3kr1/8/8/8/8/8/8/1R4KR w Hb - 0 1"))
        for uci in ["g1f2", "f8e8"] {
            board.make(try #require(board.generateLegalMoves().first { $0.uci == uci }))
        }
        #expect(board.isChess960)
        #expect(board.castlingRights.isEmpty)
        #expect(board.fen == "1r2k1r1/8/8/8/8/8/5K2/1R5R w - - 2 2")
        // Read back, that is a standard board — which plays exactly the same,
        // castling being the only thing the flag ever changed.
        let reread = try #require(Board(fen: board.fen))
        #expect(!reread.isChess960)
        #expect(reread.generateLegalMoves() == board.generateLegalMoves())
    }
}

// MARK: - Start positions

@Suite("Chess960 start positions")
struct Chess960StartPositionTests {

    private func rankString(_ number: Int) -> String {
        Chess960.backRank(number: number).map(\.letter).joined()
    }

    @Test("Scharnagl numbers name the published positions")
    func spotChecks() {
        #expect(rankString(0) == "BBQNNRKR")
        #expect(rankString(518) == "RNBQKBNR")
        #expect(rankString(959) == "RKRNNQBB")
        // Two more taken from python-chess's `from_chess960_pos`.
        #expect(rankString(397) == "QRNBNKBR")
        #expect(rankString(564) == "RBBNKNRQ")

        #expect(Chess960.fen(number: 0) == "bbqnnrkr/pppppppp/8/8/8/8/PPPPPPPP/BBQNNRKR w HFhf - 0 1")
        #expect(Chess960.fen(number: 518) == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w HAha - 0 1")
        #expect(Chess960.fen(number: 959) == "rkrnnqbb/pppppppp/8/8/8/8/PPPPPPPP/RKRNNQBB w CAca - 0 1")
    }

    @Test("All 960 are different, legal start positions")
    func allPositionsAreValid() throws {
        var seen = Set<String>()
        var firstMoves = 0
        var castleAtOnce = 0
        for number in Chess960.numbers {
            let rank = Chess960.backRank(number: number)
            seen.insert(rank.map(\.letter).joined())

            #expect(rank.count == 8)
            #expect(rank.filter { $0 == .rook }.count == 2)
            #expect(rank.filter { $0 == .knight }.count == 2)
            #expect(rank.filter { $0 == .queen }.count == 1)

            let bishops = rank.indices.filter { rank[$0] == .bishop }
            #expect(bishops.count == 2)
            #expect(bishops.count == 2 && bishops[0] % 2 != bishops[1] % 2,
                    "\(number): bishops on one colour")

            let king = try #require(rank.firstIndex(of: .king))
            let rooks = rank.indices.filter { rank[$0] == .rook }
            #expect(rooks.count == 2 && rooks[0] < king && king < rooks[1],
                    "\(number): king not between its rooks")

            let board = try #require(Board(fen: Chess960.fen(number: number)), "\(number) does not parse")
            #expect(board.isChess960)
            #expect(board.castlingRights == [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside])
            let legal = board.generateLegalMoves()
            firstMoves += legal.count
            if legal.contains(where: { $0.isCastle }) { castleAtOnce += 1 }
        }
        #expect(seen.count == 960)

        // Summed over all 960, from python-chess. Not every start position
        // has the standard twenty first moves: a knight in the corner has one
        // move instead of two, and in 162 positions the king can castle at
        // once — king f1 and rook g1 simply trade places, as in BQNNRKRB.
        #expect(firstMoves == 18_882)
        #expect(castleAtOnce == 162)
    }

    @Test("A random pick is a real position number")
    func randomNumbers() {
        for _ in 0..<100 {
            #expect(Chess960.numbers.contains(Chess960.randomNumber()))
        }
        // Seeded, it is reproducible.
        var first = SeededSource(seed: 960)
        var second = SeededSource(seed: 960)
        for _ in 0..<10 {
            #expect(Chess960.randomNumber(using: &first) == Chess960.randomNumber(using: &second))
        }
    }

    private struct SeededSource: RandomNumberGenerator {
        var mix: Zobrist.SplitMix64
        init(seed: UInt64) { mix = Zobrist.SplitMix64(seed: seed) }
        mutating func next() -> UInt64 { mix.next() }
    }
}

// MARK: - Castling

@Suite("Chess960 castling")
struct Chess960CastlingTests {

    private func castles(_ board: Board) -> [String] {
        board.generateLegalMoves().filter(\.isCastle).map(\.uci).sorted()
    }

    @Test("A 960 castle is written king takes own rook, a standard one as before")
    func uciStrings() throws {
        // The same diagram both ways: standard chess names the king's
        // destination, Chess960 the rook.
        let standard = try #require(Board(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        #expect(!standard.isChess960)
        #expect(castles(standard) == ["e1c1", "e1g1"])
        let as960 = try #require(Board(fen: "r3k2r/8/8/8/8/8/8/R3K2R w HAha - 0 1"))
        #expect(castles(as960) == ["e1a1", "e1h1"])

        // A king already on g1 still has a move to write down.
        let kingHome = try #require(Board(fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1"))
        #expect(castles(kingHome) == ["g1b1", "g1h1"])
        // And the move written is the move read back: no two moves share it.
        let legal = kingHome.generateLegalMoves()
        for move in legal {
            #expect(legal.filter { $0.uci == move.uci }.count == 1, "\(move.uci) is ambiguous")
        }

        let kingOnB1 = try #require(Board(fen: "Qr1k4/8/8/8/8/5b2/1P6/RK6 w Ab - 0 1"))
        #expect(castles(kingOnB1) == ["b1a1"])
    }

    @Test("Castling still reads O-O and O-O-O, check marks included")
    func sanIsUnchanged() throws {
        let kingHome = try #require(Board(fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1"))
        let sans = kingHome.generateLegalMoves().filter(\.isCastle).map { kingHome.san(for: $0) }.sorted()
        #expect(sans == ["O-O", "O-O-O"])

        // The rook lands on d1 and checks the king on d8.
        let checking = try #require(Board(fen: "Qr1k4/8/8/8/8/5b2/1P6/RK6 w Ab - 0 1"))
        let long = try #require(checking.generateLegalMoves().first { $0.isCastle })
        #expect(checking.san(for: long) == "O-O-O+")
    }

    @Test("Castling puts king and rook on the standard squares, whatever overlaps")
    func castlingLandsCorrectly() throws {
        // Black's king f8 and rook g8 trade places.
        var board = try #require(Board(fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR b HBgb - 0 1"))
        let swap = try #require(board.generateLegalMoves().first { $0.isCastleKingside })
        #expect(swap.uci == "f8g8")
        let squares = try #require(board.castlingSquares(for: swap))
        #expect([squares.kingFrom, squares.kingTo, squares.rookFrom, squares.rookTo].map(\.algebraic)
                == ["f8", "g8", "g8", "f8"])
        board.make(swap)
        #expect(board.piece(at: try #require(Square(algebraic: "g8"))) == Piece(.black, .king))
        #expect(board.piece(at: try #require(Square(algebraic: "f8"))) == Piece(.black, .rook))
        #expect(board.kingSquare(of: .black) == Square(algebraic: "g8")?.index)

        // White's king on g1 stays put while its rook comes to f1.
        let short = try #require(board.generateLegalMoves().first { $0.isCastleKingside })
        let whiteSquares = try #require(board.castlingSquares(for: short))
        #expect(whiteSquares.kingFrom == whiteSquares.kingTo)
        board.make(short)
        #expect(board.piece(at: try #require(Square(algebraic: "g1"))) == Piece(.white, .king))
        #expect(board.piece(at: try #require(Square(algebraic: "f1"))) == Piece(.white, .rook))
        #expect(board.piece(at: try #require(Square(algebraic: "h1"))) == nil)

        // The helper answers standard castling too, and nothing else.
        let standard = try #require(Board(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        let standardShort = try #require(standard.generateLegalMoves().first { $0.isCastleKingside })
        let standardSquares = try #require(standard.castlingSquares(for: standardShort))
        #expect([standardSquares.kingFrom, standardSquares.kingTo,
                 standardSquares.rookFrom, standardSquares.rookTo].map(\.algebraic)
                == ["e1", "g1", "h1", "f1"])
        let quiet = try #require(standard.generateLegalMoves().first { !$0.isCastle })
        #expect(standard.castlingSquares(for: quiet) == nil)
    }

    @Test("A rook taken on its castling square, or moving off it, takes its right along")
    func rightsFollowTheRooks() throws {
        // Black's b8 rook takes White's b1 rook: White loses the queenside
        // right (the b-file, not the a-file), Black loses its own queenside
        // right with the rook that left b8, and both kingside rights stay.
        var board = try #require(Board(fen: "1r3kr1/6p1/8/8/8/8/6P1/1R4KR b HBgb - 0 1"))
        board.make(try #require(board.generateLegalMoves().first { $0.uci == "b8b1" }))
        #expect(board.castlingRights == [.whiteKingside, .blackKingside])
        #expect(board.fen == "5kr1/6p1/8/8/8/8/6P1/1r4KR w Hg - 0 2")

        // A rook that is not a castling rook moves without costing anything:
        // here the castling rooks are b1 and h1, and the a1 rook is neither.
        var inner = try #require(Board(fen: "4k3/8/8/8/8/8/8/RR1K3R w HB - 0 1"))
        inner.make(try #require(inner.generateLegalMoves().first { $0.uci == "a1a2" }))
        #expect(inner.castlingRights == [.whiteKingside, .whiteQueenside])
        #expect(inner.fen == "4k3/8/8/8/8/8/R7/1R1K3R b HB - 1 1")
    }

    /// Positions with a castle on offer at once, so the walks below are sure
    /// to take one.
    nonisolated static let walkFENs = [
        "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1",
        "3rkr2/pppppppp/8/8/8/8/PPPPPPPP/3RKR2 w FDfd - 0 1",
        "rkr5/pppppppp/8/8/8/8/PPPPPPPP/RKR5 w CAca - 0 1",
        "r3k2r/8/8/8/6bb/B7/8/RK5R w HAha - 0 1",
        "Qr1k4/8/8/8/8/5b2/1P6/RK6 w Ab - 0 1",
    ]

    @Test("Incremental hash matches a full recompute through 960 castles", arguments: walkFENs)
    func zobristStaysInStep(fen: String) throws {
        var board = try #require(Board(fen: fen))
        #expect(board.zobrist == board.computeZobrist())
        var castled = 0
        // Deterministic: castle whenever possible, otherwise the middle move.
        for _ in 0..<60 {
            let legal = board.generateLegalMoves()
            guard !legal.isEmpty else { break }
            let move = legal.first(where: \.isCastle) ?? legal[legal.count / 2]
            if move.isCastle { castled += 1 }
            let before = board
            let undo = board.make(move)
            #expect(board.zobrist == board.computeZobrist(), "hash drifted after \(move.uci) in \(before.fen)")
            board.unmake(move, undo: undo)
            #expect(board == before, "\(move.uci) did not undo cleanly in \(before.fen)")
            board.make(move)
        }
        #expect(castled > 0, "the walk never castled, so it proved nothing about castling")
    }

    @Test("Unmake restores the position exactly", arguments: walkFENs)
    func unmakeIsExact(fen: String) throws {
        var board = try #require(Board(fen: fen))
        for side in [PieceColor.white, .black] {
            // Each side's castles, from the same diagram.
            board.sideToMove = side
            board.enPassantSquare = -1
            board.zobrist = board.computeZobrist()
            guard !board.isSquareAttacked(board.kingSquare(of: side.opponent), by: side) else { continue }
            let before = board
            for move in board.generateLegalMoves() {
                let undo = board.make(move)
                board.unmake(move, undo: undo)
                #expect(board == before, "\(move.uci) did not undo cleanly")
            }
        }
    }

    @Test("Castling hands nothing over in the exchange on its square")
    func castlingIsNoSacrifice() throws {
        // `to` is h1, the rook's square, and the e4 bishop looks at it. Read
        // as an exchange, that had the king "lost" on h1.
        let board = try #require(Board(fen: "6k1/8/8/8/4b3/8/8/6KR w H - 0 1"))
        let castle = try #require(board.generateLegalMoves().first { $0.isCastle })
        #expect(castle.uci == "g1h1")
        #expect(board.staticExchangeEvaluation(castle) == 0)
    }

    @Test("The opening book has nothing to say about a 960 game")
    func noBookIn960() throws {
        // 1.e4 is legal in every start position, and the standard array is
        // still not a position theory speaks about once it castles 960-style.
        for number in [518, 0, 397] {
            let board = try #require(Board(fen: Chess960.fen(number: number)))
            #expect(OpeningBook.move(after: [], in: board, randomSeed: 7) == nil, "book answered in \(number)")
        }
        #expect(OpeningBook.move(after: [], in: .initial, randomSeed: 7) != nil)
    }
}

// MARK: - Game

@Suite("Chess960 game")
struct Chess960GameTests {

    private func play(_ ucis: [String], from fen: String) throws -> Game {
        var game = Game(fen: fen)
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci) in \(game.board.fen)"))
        }
        return game
    }

    @Test("A 960 game castles, undoes the castle and replays it")
    func undoThroughACastle() throws {
        let fen = "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1"
        var game = try play(["g1b1", "f8g8"], from: fen)
        #expect(game.isChess960)
        #expect(game.initialFEN == fen)
        #expect(game.history.map(\.san) == ["O-O-O", "O-O"])
        #expect(game.board.fen == "1r3rk1/pppppppp/8/8/8/8/PPPPPPPP/2KR3R w - - 2 2")

        let afterLong = try play(["g1b1"], from: fen)
        game.undoLastMove()
        #expect(game.board == afterLong.board)
        #expect(game.isChess960)
        game.undoLastMove()
        #expect(game.board == Board(fen: fen))
        #expect(game.history.isEmpty)
        // The rights came back with the position, so the castle is there again.
        #expect(game.legalMoves.contains { $0.uci == "g1b1" && $0.isCastleQueenside })
    }

    @Test("A saved 960 game restores from its FEN and UCI moves")
    func savedGamesRestore() throws {
        var game = Game(fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1")
        // Both sides castle at once, then the game wanders on.
        for step in 0..<30 {
            let legal = game.legalMoves
            guard !legal.isEmpty else { break }
            game.play(legal.first(where: \.isCastle) ?? legal[(step * 5 + 1) % legal.count])
        }
        #expect(game.history.prefix(2).allSatisfy { $0.move.isCastle })
        let saved = SavedGame(
            mode: .twoPlayer,
            initialFEN: game.initialFEN,
            moveUCIs: game.history.map(\.move.uci),
            savedAt: .now
        )
        let restored = try #require(saved.restoreGame())
        #expect(restored.isChess960)
        #expect(restored.board == game.board)
        #expect(restored.history.map(\.san) == game.history.map(\.san))
    }
}
