//
//  EngineInputFixesTests.swift
//  chessTests
//
//  The faults the engine review found in what it is handed, each with a test
//  that fails on the code as it was: tag lines that were not quite to the
//  letter of the standard and cost a game its moves, evaluations glued to a
//  move, the result after the moves ignored, a stale castling right that
//  turned a standard FEN into Chess960, a stored Chess960 number that trapped,
//  and the rook square of a spent right that kept a position from equalling
//  its own FEN.
//

import Foundation
import Testing
@testable import chess

// MARK: - Tag lines

@Suite("Engine input fixes: tag lines")
struct PGNTagLineFixesTests {

    private let fen = "8/P6k/8/8/8/8/8/K7 w - - 0 1"

    @Test("A tag parted by a tab or by nothing, unquoted, or with a comment after it is read, and the game keeps its moves", arguments: [
        "[SetUp\t\"1\"]",
        "[SetUp\"1\"]",
        "[SetUp 1]",
        "[SetUp \"1\"] ; set up by hand",
    ])
    func lenientTagLine(setUp: String) throws {
        let text = """
            [Event "Lesson"]
            [FEN "\(fen)"]
            \(setUp)

            1. a8=Q *
            """
        let games = try PGN.parse(text)
        #expect(games.count == 1)
        let parsed = try #require(games.first)
        #expect(parsed.tags == ["Event": "Lesson", "FEN": fen, "SetUp": "1"])
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["a8=Q"])
    }

    @Test("A tag line that does not read at all is passed over, and the game is not split at it")
    func unreadableTagLine() throws {
        let text = """
            [Event "Lesson"]
            [FEN "\(fen)"]
            [Annotator "never closed]
            [White "Ann"]

            1. a8=Q *
            """
        let games = try PGN.parse(text)
        #expect(games.count == 1)
        let parsed = try #require(games.first)
        #expect(parsed.tags == ["Event": "Lesson", "FEN": fen, "White": "Ann"])
        #expect(parsed.game.history.map(\.san) == ["a8=Q"])
    }

    @Test("Two tags on one line are both read, and quotes inside a value are kept")
    func tagsSharingALine() throws {
        let parsed = try #require(try PGN.parse("[Event \"The \"Big\" Game\"] [Site \"Club\"]\n\n1. e4 *").first)
        #expect(parsed.tags == ["Event": "The \"Big\" Game", "Site": "Club"])
        #expect(parsed.game.history.map(\.san) == ["e4"])

        // What the app escapes on the way out still reads back as it was.
        let names = [("White", "back\\slash \"quoted\""), ("Black", "ends in \\")]
        let exported = try #require(try PGN.parse(PGN.export(game: Game(), tags: names)).first)
        #expect(exported.tags["White"] == "back\\slash \"quoted\"")
        #expect(exported.tags["Black"] == "ends in \\")
    }
}

// MARK: - Glued evaluations

@Suite("Engine input fixes: evaluations glued to a move")
struct GluedEvaluationTests {

    @Test("An evaluation glued to its move is read past", arguments: [
        "+-", "-+", "=", "+/-", "-/+", "+/=", "=/+", "±", "∓", "∞", "=/∞", "□", "‼", "!?+-",
    ])
    func gluedEvaluation(sign: String) throws {
        let parsed = try #require(try PGN.parse("1. e4\(sign) e5 2. Nf3\(sign) Nc6 *").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    }

    @Test("A promotion keeps its piece under a glued evaluation, and reads as it did without one")
    func promotionUnderAnEvaluation() {
        let promotion = Game(fen: "3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1")
        #expect(PGN.move(for: "e8=Q+-", in: promotion)?.uci == "e7e8q")
        #expect(PGN.move(for: "exd8=N±", in: promotion)?.uci == "e7d8n")
        #expect(PGN.move(for: "e8Q=", in: promotion)?.uci == "e7e8q")
        #expect(PGN.move(for: "e8=Q", in: promotion)?.uci == "e7e8q")
        #expect(PGN.move(for: "e8=Q+", in: promotion)?.uci == "e7e8q")
        // A sign with no piece after it is no promotion at all.
        #expect(PGN.move(for: "e8=", in: promotion) == nil)

        let castles = Game(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        #expect(PGN.move(for: "O-O-O=", in: castles)?.isCastleQueenside == true)
        #expect(PGN.move(for: "0-0+-", in: castles)?.isCastleKingside == true)
    }
}

// MARK: - Movetext result

@Suite("Engine input fixes: the result after the moves")
struct MovetextResultTests {

    @Test("The result after the moves counts where the tags give none", arguments: [
        ("", "1. e4 e5 2. Nf3 1-0", GameOutcome.resigned(winner: .white)),
        ("[Result \"*\"]\n", "1. e4 e5 2. Nf3 0-1", .resigned(winner: .black)),
        ("[Result \"?\"]\n", "1. e4 e5 1/2-1/2", .drawAgreed),
        ("", "1. e4 e5 ½-½", .drawAgreed),
        ("[Termination \"time forfeit\"]\n", "1. e4 e5 2. Nf3 1-0", .timeForfeit(winner: .white)),
    ])
    func movetextResult(tags: String, movetext: String, outcome: GameOutcome) throws {
        let parsed = try #require(try PGN.parse(tags + "\n" + movetext).first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.outcome == outcome)
    }

    @Test("A draw after the moves is claimed where it can be, and a result tag still outranks the moves")
    func claimedDrawAndTagFirst() throws {
        let repetition = "1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 1/2-1/2"
        #expect(try PGN.parse(repetition).first?.game.outcome == .drawThreefoldRepetition)

        let tagged = try #require(try PGN.parse("[Result \"1/2-1/2\"]\n\n1. e4 e5 1-0").first)
        #expect(tagged.game.outcome == .drawAgreed)
        // A result the moves never reach says nothing about where they stop.
        let unread = try #require(try PGN.parse("1. e4 e5 2. Zz9 1-0").first)
        #expect(unread.unreadMove == "Zz9")
        #expect(unread.game.outcome == .ongoing)
    }
}

// MARK: - Stale rights beside a corner rook

@Suite("Engine input fixes: a stale right beside a corner rook")
struct StaleRightBesideCornerTests {

    @Test("Both rights with the king at home and one rook off its corner stay standard chess", arguments: [
        // The h-rook stepped to g1 and the K was never struck off.
        ("4k3/8/8/8/8/8/8/R3K1R1 w KQ - 0 1", "4k3/8/8/8/8/8/8/R3K1R1 w Q - 0 1", "e1c1"),
        // The a-rook stepped to b1.
        ("4k3/8/8/8/8/8/8/1R2K2R w KQ - 0 1", "4k3/8/8/8/8/8/8/1R2K2R w K - 0 1", "e1g1"),
        // The same for Black.
        ("r3k1r1/8/8/8/8/8/8/4K3 b kq - 0 1", "r3k1r1/8/8/8/8/8/8/4K3 b q - 0 1", "e8c8"),
    ])
    func oneSideStaysStandard(input: String, expected: String, castle: String) throws {
        let board = try #require(Board(fen: input))
        #expect(!board.isChess960)
        #expect(board.fen == expected)
        #expect(board.generateLegalMoves().filter(\.isCastle).map(\.uci) == [castle])
    }

    @Test("Both sides naming their rooks on the same files still read as Chess960")
    func mirroredRightsAre960() throws {
        // The X-FEN of a 960 start with the king on e1: K is the g1 rook.
        let start = try #require(Board(fen: "rnbqknrb/pppppppp/8/8/8/8/PPPPPPPP/RNBQKNRB w KQkq - 0 1"))
        #expect(start.isChess960)
        #expect(start == Board(fen: "rnbqknrb/pppppppp/8/8/8/8/PPPPPPPP/RNBQKNRB w GAga - 0 1"))

        // A few moves on, each side has kept the same single right.
        let kept = try #require(Board(fen: "r3k1r1/8/8/8/8/8/8/R3K1R1 w Kk - 0 1"))
        #expect(kept.isChess960)
        #expect(kept.fen == "r3k1r1/8/8/8/8/8/8/R3K1R1 w Gg - 0 1")

        // Rooks on different files are no one array, and stay standard.
        let unlike = try #require(Board(fen: "r3k2r/8/8/8/8/8/8/R3K1R1 w Kk - 0 1"))
        #expect(!unlike.isChess960)
        #expect(unlike.fen == "r3k2r/8/8/8/8/8/8/R3K1R1 w k - 0 1")

        // Shredder-FEN and a king off the e-file say so on their own.
        #expect(Board(fen: "4k3/8/8/8/8/8/8/R3K1R1 w GA - 0 1")?.isChess960 == true)
        #expect(Board(fen: "4k3/8/8/8/8/8/8/R4KR1 w KQ - 0 1")?.isChess960 == true)
    }
}

// MARK: - Stored Chess960 number

@Suite("Engine input fixes: a stored Chess960 number")
@MainActor
struct StoredChess960NumberTests {

    private func decoded(_ json: String) throws -> StartPosition {
        try JSONDecoder().decode(StartPosition.self, from: Data(json.utf8))
    }

    @Test("A Chess960 number outside 0...959 reads as the standard start; every other start reads as itself")
    func outOfRangeNumber() throws {
        for number in [-1, 960, Int.max] {
            let stored = try JSONEncoder().encode(StartPosition.chess960(number: number))
            let start = try JSONDecoder().decode(StartPosition.self, from: stored)
            try #require(start == .standard, "\(number) read as \(start)")
            #expect(start.fen == Board.startFEN)
        }
        #expect(try decoded(#"{"chess960":{"number":960}}"#) == .standard)

        let options = try JSONDecoder().decode(
            GameOptions.self, from: Data(#"{"start":{"chess960":{"number":4000}},"tabletop":false}"#.utf8)
        )
        #expect(options.start == .standard)

        // The layout is the one older builds wrote, and the rest is unchanged.
        #expect(try decoded(#"{"chess960":{"number":518}}"#) == .chess960(number: 518))
        #expect(try decoded(#"{"standard":{}}"#) == .standard)
        for start: StartPosition in [
            .chess960(number: 0), .chess960(number: 959), .handicap(.knight, giver: .black),
            .custom(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1"),
        ] {
            #expect(try JSONDecoder().decode(StartPosition.self, from: JSONEncoder().encode(start)) == start)
        }
    }
}

// MARK: - Rook squares of spent rights

@Suite("Engine input fixes: the rook square of a spent right")
struct SpentRightRookSquareTests {

    @Test("A spent right's rook square goes back to its corner, so the position equals its own FEN read back")
    func spentRightSquare() throws {
        // White's queenside rook is the f1 one; moving it spends the right.
        let start = try #require(Board(fen: "bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9"))
        var board = start
        let rookMove = try #require(board.generateLegalMoves().first { $0.uci == "f1f2" })
        let undo = board.make(rookMove)
        #expect(board.castlingRights == [.whiteKingside, .blackKingside, .blackQueenside])
        #expect(board.castlingRookSquares.whiteQueenside == CastlingRookSquares.standard.whiteQueenside)
        #expect(Board(fen: board.fen) == board)
        #expect(board.zobrist == board.computeZobrist())
        board.unmake(rookMove, undo: undo)
        #expect(board == start)
    }

    @Test("A 960 castle spends both rights and undoes back to its own rook squares")
    func castleUndoesExactly() throws {
        let start = try #require(Board(fen: "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/1R4KR w HBgb - 0 1"))
        var board = start
        let castle = try #require(board.generateLegalMoves().first { $0.isCastleKingside })
        let undo = board.make(castle)
        #expect(board.castlingRookSquares.whiteKingside == CastlingRookSquares.standard.whiteKingside)
        #expect(board.castlingRookSquares.whiteQueenside == CastlingRookSquares.standard.whiteQueenside)
        #expect(Board(fen: board.fen) == board)
        #expect(board.zobrist == board.computeZobrist())

        board.unmake(castle, undo: undo)
        #expect(board == start)
        #expect(board.castlingSquares(for: castle)?.rookFrom == Square(algebraic: "h1"))
        #expect(board.generateLegalMoves() == start.generateLegalMoves())
    }
}
