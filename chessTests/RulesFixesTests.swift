//
//  RulesFixesTests.swift
//  chessTests
//
//  The rules faults found in the second review, each with a test that fails
//  on the code as it was — a flag fall scored as a win against a side that
//  could never have been mated, standard FENs read as Chess960 or refused, a
//  repetition missed for an en passant capture nobody could make, and PGN
//  read and written in ways other programs do not — and, beside them, what
//  the fixes must leave as it was.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN, settlesClaimableDraws: Bool = true) throws -> Game {
    var game = Game(fen: fen, settlesClaimableDraws: settlesClaimableDraws)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci) in \(game.board.fen)"))
    }
    return game
}

// MARK: - Flag fall

@Suite("Fixes: mating material on a flag fall")
struct FlagFallMaterialTests {

    private func outcome(_ fen: String) throws -> GameOutcome {
        var game = Game(fen: fen)
        try #require(game.outcome == .ongoing)
        game.timeOut()
        return game.outcome
    }

    /// No position with this material is checkmate, whoever is to move, so
    /// the side that flagged cannot lose: a rook or a queen beside its king
    /// steps into a bishop's check or takes the bishop, and a queen always
    /// has the checking knight in its sights.
    @Test("A lone bishop against a rook or a queen, or a lone knight against a queen, is a draw on time", arguments: [
        "7k/8/8/8/8/8/8/K1B4r b - - 0 1", // bishop against rook
        "7k/8/8/8/8/8/8/K1B4q b - - 0 1", // bishop against queen
        "7k/8/8/8/8/8/8/K1N4q b - - 0 1", // knight against queen
    ])
    func noHelpmate(fen: String) throws {
        #expect(try outcome(fen) == .drawTimeoutInsufficientMaterial)
    }

    /// Each of these has a mate on the board somewhere — the loser's own
    /// piece boxing its king into the corner — so the flag still loses.
    @Test("A lone minor piece wins on time where the loser's piece can box its king in", arguments: [
        "7k/8/8/8/8/8/8/K1N4r b - - 0 1", // knight against rook
        "7k/8/8/8/8/8/8/K1B4n b - - 0 1", // bishop against knight
        "7k/7p/8/8/8/8/8/K1B5 b - - 0 1", // bishop against pawn
        "7k/7p/8/8/8/8/8/K1N5 b - - 0 1", // knight against pawn
        "7k/8/8/8/8/8/8/K1N4b b - - 0 1", // knight against bishop
        "7k/8/8/8/8/8/8/K1B4b b - - 0 1", // dark bishop against a light one
    ])
    func helpmateExists(fen: String) throws {
        #expect(try outcome(fen) == .timeForfeit(winner: .white))
    }
}

// MARK: - Castling field

@Suite("Fixes: reading the castling field")
struct CastlingFieldTests {

    @Test("Rights left standing after castling are dropped, not refused")
    func staleRightsAfterCastling() throws {
        let board = try #require(Board(fen: "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R4RK1 w KQkq - 0 1"))
        #expect(!board.isChess960)
        #expect(board.castlingRights == [.blackKingside, .blackQueenside])
        #expect(board.fen == "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R4RK1 w kq - 0 1")
    }

    @Test("A rook off its corner in a standard game does not make the game Chess960")
    func rookOffItsCorner() throws {
        let board = try #require(Board(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQK1R1 w KQkq - 0 1"))
        #expect(!board.isChess960)
        #expect(board.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQK1R1 w Qkq - 0 1")

        // With the way clear, standard chess has a long castle and no short
        // one: the rook on g1 is not a castling rook.
        let open = try #require(Board(fen: "r3k2r/8/8/8/8/8/8/R3K1R1 w KQkq - 0 1"))
        #expect(!open.isChess960)
        #expect(open.generateLegalMoves().filter(\.isCastle).map(\.uci) == ["e1c1"])

        // And the game it starts is written out as standard chess.
        let game = try played(["e1c1"], from: "r3k2r/8/8/8/8/8/8/R3K1R1 w KQkq - 0 1")
        #expect(!PGN.export(game: game).contains("Chess960"))
    }

    @Test("Every 960 start position reads back as itself, in Shredder-FEN and in X-FEN")
    func startPositionsRoundTrip() throws {
        for number in Chess960.numbers {
            let fen = Chess960.fen(number: number)
            let board = try #require(Board(fen: fen))
            #expect(board.isChess960 && board.fen == fen, "\(number) does not round-trip")

            // "KQkq" is X-FEN for the outermost rooks. A king on e1 with both
            // rooks in the corners reads as standard chess, which castles the
            // same way; any other start is told apart.
            var fields = fen.split(separator: " ").map(String.init)
            fields[2] = "KQkq"
            let xfen = fields.joined(separator: " ")
            let rank = Chess960.backRank(number: number)
            let looksStandard = rank[4] == .king && rank[0] == .rook && rank[7] == .rook
            let xboard = try #require(Board(fen: xfen), "\(number) in X-FEN does not parse")
            if looksStandard {
                #expect(!xboard.isChess960, "\(number)")
            } else {
                #expect(xboard == board, "\(number) in X-FEN reads as \(xboard.fen)")
            }
        }
    }

    /// The king on e1 is the case the standard reading competes for, so most
    /// of these are such starts: 0 and 959 are there for the others.
    @Test("A 960 game's FEN reads back as the same position after every move, and its PGN as the same game")
    func midGameRoundTrip() throws {
        let kingOnE1 = Chess960.numbers.filter { number in
            let rank = Chess960.backRank(number: number)
            return rank[4] == .king && (rank[0] != .rook || rank[7] != .rook)
        }
        let numbers = [0, 959] + stride(from: 0, to: kingOnE1.count, by: kingOnE1.count / 6).map { kingOnE1[$0] }
        for number in numbers {
            var game = Game(fen: Chess960.fen(number: number))
            for step in 0..<40 {
                let legal = game.legalMoves
                guard !legal.isEmpty else { break }
                game.play(legal.first(where: \.isCastle) ?? legal[(step * 7 + 3) % legal.count])
                let board = game.board
                let reread = try #require(Board(fen: board.fen), "\(board.fen) does not parse")
                #expect(reread.fen == board.fen, "\(number): \(board.fen) reads back as \(reread.fen)")
                #expect(reread.generateLegalMoves() == board.generateLegalMoves(), "\(number): \(board.fen)")
                if !board.castlingRights.isEmpty {
                    #expect(reread.isChess960, "\(number): \(board.fen) read back as standard chess")
                }
            }

            let clocks = PGN.clockFaces(control: .minutes(3, plus: 2), moveTimes: game.history.map { _ in 3 })
            let text = PGN.export(game: game, clockAfterMove: clocks)
            #expect(text.contains("[Variant \"Chess960\"]"))
            let parsed = try #require(try PGN.parse(text).first)
            #expect(parsed.unreadMove == nil)
            #expect(parsed.game.initialFEN == game.initialFEN)
            #expect(parsed.game.history.map(\.move.uci) == game.history.map(\.move.uci), "\(number)")
            #expect(parsed.game.board == game.board, "\(number)")
        }
    }

    @Test("A Variant tag naming Chess960 is believed when the FEN alone would read as standard")
    func variantTag() throws {
        let text = """
            [Variant "Chess960"]
            [FEN "rbnqknbr/pppppppp/8/8/8/8/PPPPPPPP/RBNQKNBR w KQkq - 0 1"]

            1. e4 e5 *
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.isChess960)
        #expect(parsed.game.initialFEN == "rbnqknbr/pppppppp/8/8/8/8/PPPPPPPP/RBNQKNBR w HAha - 0 1")
        #expect(parsed.game.history.count == 2)
    }
}

// MARK: - En passant and repetition

@Suite("Fixes: en passant and repetition")
struct EnPassantRepetitionTests {

    /// After 1...c5 the b5 pawn could take on c6 but for the rook on h5,
    /// which would then see the king. A capture nobody can make does not set
    /// the position apart from the same one without it.
    private let fen = "4k3/2p5/8/KP5r/8/8/8/6N1 b - - 0 1"
    private let moves = ["c7c5", "g1f3", "e8e7", "f3g1", "e7e8", "g1f3", "e8e7", "f3g1", "e7e8"]

    @Test("An en passant capture that would expose the king does not tell positions apart")
    func illegalCaptureIsNotPartOfThePosition() throws {
        let pinned = try #require(Board(fen: "4k3/8/8/KPp4r/8/8/8/6N1 w - c6 0 2"))
        #expect(pinned.enPassantSquare >= 0)
        #expect(pinned.zobrist == Board(fen: "4k3/8/8/KPp4r/8/8/8/6N1 w - - 0 2")?.zobrist)

        // Without the rook the capture is legal, and it does.
        let free = try #require(Board(fen: "4k3/8/8/KPp5/8/8/8/6N1 w - c6 0 2"))
        #expect(free.zobrist != Board(fen: "4k3/8/8/KPp5/8/8/8/6N1 w - - 0 2")?.zobrist)
    }

    @Test("The third time the position stands is a repetition, the first one included")
    func repetitionAfterADoublePush() throws {
        let game = try played(moves, from: fen)
        #expect(game.outcome == .drawThreefoldRepetition)

        // Read under FIDE's rules, it is the draw a player may claim.
        var claimable = try played(moves, from: fen, settlesClaimableDraws: false)
        #expect(claimable.outcome == .ongoing)
        let claimed = claimable.claimDraw()
        #expect(claimed)
        #expect(claimable.outcome == .drawThreefoldRepetition)
    }

    @Test("The hash kept move by move is the hash worked out from scratch")
    func hashStaysInStep() throws {
        var board = try #require(Board(fen: fen))
        for uci in moves {
            let move = try #require(board.generateLegalMoves().first { $0.uci == uci })
            let before = board
            let undo = board.make(move)
            #expect(board.zobrist == board.computeZobrist(), "hash drifted after \(uci)")
            board.unmake(move, undo: undo)
            #expect(board == before)
            board.make(move)
        }
    }
}

// MARK: - PGN

@Suite("Fixes: PGN in and out")
struct PGNInAndOutFixesTests {

    @Test("A comment running over several lines is comment to its end, tag-like lines included")
    func multiLineComment() throws {
        let text = """
            [Event "Commented"]
            [Result "*"]

            1. e4 {Notes by
            [White "Somebody"]
            for the club} e5 2. Nf3 *
            """
        let games = try PGN.parse(text)
        #expect(games.count == 1)
        #expect(games.first?.unreadMove == nil)
        #expect(games.first?.game.history.map(\.san) == ["e4", "e5", "Nf3"])
        #expect(games.first?.tags["White"] == nil)
    }

    @Test("Evaluation signs written out in text are read past", arguments: [
        "+/-", "-/+", "+/=", "=/+", "+-", "-+", "=", "∞", "=/∞",
    ])
    func textualEvaluations(sign: String) throws {
        // The result at the end is still the result, not one more sign.
        let parsed = try #require(try PGN.parse("1. e4 \(sign) e5 2. Nf3 \(sign) Nc6 1/2-1/2").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    }

    @Test("A game that is only tags stays a game of its own")
    func gameWithoutMoves() throws {
        let text = """
            [Event "Abandoned"]
            [White "Ann"]

            [Event "Played"]
            [White "Ben"]

            1. e4 e5 *
            """
        let games = try PGN.parse(text)
        #expect(games.count == 2)
        #expect(games.first?.tags == ["Event": "Abandoned", "White": "Ann"])
        #expect(games.first?.game.history.isEmpty == true)
        #expect(games.last?.tags == ["Event": "Played", "White": "Ben"])
        #expect(games.last?.game.history.count == 2)
    }

    @Test("A draw on time comes back as a draw on time")
    func drawOnTimeRoundTrip() throws {
        // Black flags with only a rook left against White's bishop.
        var game = try played(["a1b2"], from: "7k/8/8/8/8/8/8/K1B4r w - - 0 1")
        game.timeOut()
        try #require(game.outcome == .drawTimeoutInsufficientMaterial)
        let text = PGN.export(game: game)
        #expect(text.contains("[Result \"1/2-1/2\"]"))
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.outcome == .drawTimeoutInsufficientMaterial)
    }

    @Test("A loss on time read from PGN stays a loss, whatever this app's material rule says")
    func lossOnTimeKeepsItsResult() throws {
        // Black on move with a queen against White's lone knight: this app
        // would have drawn the flag, but the server that played it did not.
        let text = """
        [SetUp "1"]
        [FEN "3qk3/8/8/8/8/8/8/1N2K3 w - - 0 1"]
        [Result "1-0"]
        [Termination "White won on time"]

        1. Nc3 1-0
        """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.outcome == .timeForfeit(winner: .white))
    }

    @Test("A Black move after a clock comment carries its move number")
    func moveNumberAfterComment() throws {
        let game = try played(["e2e4", "e7e5", "g1f3"])
        let text = PGN.export(game: game, clockAfterMove: [180, 178, 175])
        #expect(text.contains("1. e4 {[%clk 0:03:00]} 1... e5 {[%clk 0:02:58]} 2. Nf3 {[%clk 0:02:55]} *"))
        #expect(try PGN.parse(text).first?.game.history.map(\.san) == ["e4", "e5", "Nf3"])
        // Without comments Black's moves follow White's unnumbered, as before.
        #expect(PGN.export(game: game).contains("1. e4 e5 2. Nf3 *"))
    }

    @Test("A clock that ran past zero gets its increment from zero, as the clock itself gives it")
    func clockFacesFromAnEmptyBank() {
        // White's third move takes 70 s of the 60 left: the bank is empty,
        // and the increment is added to nothing rather than to minus ten.
        let faces = PGN.clockFaces(control: .minutes(1, plus: 2), moveTimes: [1, 1, 70, 1, 1])
        #expect(faces == [60, 61, 2, 62, 3])

        var clock = ChessClock(control: .minutes(1, plus: 2))
        clock.start(.white, at: 0)
        clock.press(at: 70)
        #expect(clock.remaining(for: .white, at: 70) == 2)
    }
}
