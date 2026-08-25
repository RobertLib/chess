//
//  BoardTests.swift
//  chessTests
//
//  FEN, make/unmake and the incremental Zobrist hash — the three things every
//  other part of the engine trusts to be exact.
//

import Testing
@testable import chess

@Suite("Board")
struct BoardTests {

    nonisolated static let fens = [
        Board.startFEN,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    ]

    // MARK: FEN

    @Test("FEN survives a round trip", arguments: fens)
    func fenRoundTrip(fen: String) throws {
        let board = try #require(Board(fen: fen))
        #expect(board.fen == fen)
    }

    @Test("Malformed FEN is rejected", arguments: [
        "",
        "not a fen",
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",      // seven ranks
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1", // no side to move
        "8/8/8/8/8/8/8/8 w - - 0 1",                            // no kings
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w XYZ - 0 1",  // bad castling
    ])
    func rejectsBadFEN(fen: String) {
        #expect(Board(fen: fen) == nil, "should not have parsed: \(fen)")
    }

    // MARK: Zobrist

    @Test("A letter that uppercases to two letters is refused, not trapped on")
    func rejectsMultiGraphemeUppercase() {
        // "ß".uppercased() is "SS"; building a Character from that used to trap
        // in Debug builds instead of failing the FEN.
        #expect(Piece(fenCharacter: "ß") == nil)
        #expect(Board(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNß w KQkq - 0 1") == nil)
    }

    @Test("An en passant square no double push could have produced is dropped")
    func ignoresImplausibleEnPassantSquare() throws {
        // e4 is empty and reachable by the d3 pawn, but nothing was pushed two
        // squares: the piece beyond it is a knight. Trusting the field made
        // the generator "capture" it en passant, and unmake put a pawn back.
        let board = try #require(Board(fen: "4k3/8/8/8/8/3Pn3/8/4K3 w - e4 0 1"))
        #expect(board.enPassantSquare == -1)
        #expect(!board.generateLegalMoves().contains { $0.isEnPassant })

        // A field that is not a square at all fails the FEN, as a bad castling field does.
        #expect(Board(fen: "4k3/8/8/8/8/8/8/4K3 w - e9 0 1") == nil)

        // The genuine article is kept.
        let genuine = try #require(Board(fen: "4k3/8/8/2pP4/8/8/8/4K3 w - c6 0 2"))
        #expect(genuine.enPassantSquare == Square(algebraic: "c6")?.index)
        #expect(genuine.generateLegalMoves().contains { $0.isEnPassant })
    }

    @Test("Incremental hash matches a full recompute", arguments: fens)
    func zobristStaysInStep(fen: String) throws {
        var board = try #require(Board(fen: fen))
        #expect(board.zobrist == board.computeZobrist(), "hash wrong straight after parsing")

        // A deterministic walk: always take the middle legal move, so a failure
        // reproduces exactly.
        for _ in 0..<40 {
            let legal = board.generateLegalMoves()
            guard !legal.isEmpty else { break }
            board.make(legal[legal.count / 2])
            #expect(board.zobrist == board.computeZobrist(), "hash drifted after \(board.fen)")
        }
    }

    @Test("Transposing to the same position gives the same hash")
    func transpositionsHashAlike() throws {
        var viaKnightFirst = Game()
        for uci in ["g1f3", "g8f6", "d2d4", "d7d5"] {
            viaKnightFirst.play(try #require(viaKnightFirst.legalMoves.first { $0.uci == uci }))
        }
        var viaPawnFirst = Game()
        for uci in ["d2d4", "d7d5", "g1f3", "g8f6"] {
            viaPawnFirst.play(try #require(viaPawnFirst.legalMoves.first { $0.uci == uci }))
        }
        // The two games reach the same pieces on the same squares. They differ
        // in the halfmove clock, and one carries an en passant square that no
        // pawn can use — neither of which makes it a different position, and
        // the hash is right to ignore both.
        #expect(viaKnightFirst.board.squares == viaPawnFirst.board.squares)
        #expect(viaKnightFirst.board.zobrist == viaPawnFirst.board.zobrist)
    }

    @Test("An en passant square only counts when a pawn can actually take")
    func irrelevantEnPassantDoesNotChangeTheHash() throws {
        // Black has just played c7-c5, but no white pawn stands next to it, so
        // the position is the same one as if it had no en passant target.
        let withTarget = try #require(Board(fen: "4k3/8/8/2p5/8/8/4P3/4K3 w - c6 0 2"))
        let without = try #require(Board(fen: "4k3/8/8/2p5/8/8/4P3/4K3 w - - 0 2"))
        #expect(withTarget.zobrist == without.zobrist)

        // With a white pawn on b5 or d5 it does matter.
        let capturable = try #require(Board(fen: "4k3/8/8/2pP4/8/8/8/4K3 w - c6 0 2"))
        let notCapturable = try #require(Board(fen: "4k3/8/8/2pP4/8/8/8/4K3 w - - 0 2"))
        #expect(capturable.zobrist != notCapturable.zobrist)
    }

    // MARK: make / unmake

    @Test("Unmake restores the position exactly", arguments: fens)
    func unmakeIsExact(fen: String) throws {
        var board = try #require(Board(fen: fen))
        let before = board
        for move in board.generateLegalMoves() {
            let undo = board.make(move)
            board.unmake(move, undo: undo)
            #expect(board == before, "\(move.uci) did not undo cleanly")
        }
    }

    @Test("Castling moves the rook and spends the rights")
    func castlingIsComplete() throws {
        var game = Game(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let kingside = try #require(game.legalMoves.first { $0.isCastleKingside })
        #expect(game.board.san(for: kingside) == "O-O")
        game.play(kingside)

        #expect(game.board.piece(at: try #require(Square(algebraic: "g1")))?.kind == .king)
        #expect(game.board.piece(at: try #require(Square(algebraic: "f1")))?.kind == .rook)
        #expect(game.board.piece(at: try #require(Square(algebraic: "h1"))) == nil)
        #expect(!game.board.castlingRights.contains(.whiteKingside))
        #expect(!game.board.castlingRights.contains(.whiteQueenside))
        #expect(game.board.castlingRights.contains(.blackKingside))
    }

    @Test("Capturing a rook on its home square spends that castling right")
    func capturedRookLosesTheRight() throws {
        var game = Game(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        game.play(try #require(game.legalMoves.first { $0.uci == "a1a8" }))
        #expect(!game.board.castlingRights.contains(.blackQueenside))
        #expect(game.board.castlingRights.contains(.blackKingside))
    }

    @Test("En passant removes the pawn that ran past")
    func enPassantTakesTheRightPawn() throws {
        var game = Game(fen: "4k3/8/8/8/4pP2/8/8/4K3 b - f3 0 1")
        let capture = try #require(game.legalMoves.first { $0.isEnPassant })
        #expect(game.board.san(for: capture) == "exf3")
        game.play(capture)
        #expect(game.board.piece(at: try #require(Square(algebraic: "f4"))) == nil, "the pushed pawn should be gone")
        #expect(game.board.piece(at: try #require(Square(algebraic: "f3")))?.kind == .pawn)
    }

    @Test("A pawn reaching the last rank may become any of four pieces")
    func promotionOffersFourPieces() throws {
        let game = Game(fen: "7k/4P3/8/8/8/8/8/4K3 w - - 0 1")
        let promotions = game.legalMoves.filter { $0.promotion != nil }
        #expect(promotions.count == 4)
        #expect(Set(promotions.compactMap(\.promotion)) == [.queen, .rook, .bishop, .knight])
        let queening = try #require(promotions.first { $0.promotion == .queen })
        #expect(game.board.san(for: queening) == "e8=Q+")
    }
}
