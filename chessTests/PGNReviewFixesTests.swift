//
//  PGNReviewFixesTests.swift
//  chessTests
//
//  The faults a review of the PGN and FEN readers found, each with a test
//  that fails on the code as it was: a game written out with one result in
//  its tag and another after its moves; castles, results and promotions
//  written in ways other programs write them that stopped a game short;
//  moves on a tag's line, every game after the first of a text without
//  tags, and the moves of a variation never closed or played past an
//  automatic draw, all lost without a word; a byte-order mark that hid a
//  file's first tag; a King of the Hill position its side to move had
//  already won; and a standard FEN whose king had stepped off e1 read as
//  Chess960.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN, variant: ChessVariant = .standard) throws -> Game {
    var game = Game(fen: fen, variant: variant)
    for uci in ucis {
        game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci) in \(game.board.fen)"))
    }
    return game
}

/// The only game a text holds.
private func onlyGame(_ text: String) throws -> PGN.ParsedGame {
    let games = try PGN.parse(text)
    try #require(games.count == 1, "\(games.count) games")
    return games[0]
}

private func tagLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
}

/// The last token of a game's text: the result after its moves.
private func terminator(_ text: String) -> String {
    String(text.split(whereSeparator: \.isWhitespace).last ?? "")
}

// MARK: - Writing the result

@Suite("PGN review fixes: one result, in the tag and after the moves")
@MainActor
struct PGNResultAgreementTests {

    @Test("A game read with \"*\" whose moves end in mate is written out with the mate's result in its tag too")
    func boardOutcomeWins() throws {
        let parsed = try onlyGame("[Event \"x\"]\n[Result \"*\"]\n\n1. f3 e5 2. g4 Qh4# *\n")
        try #require(parsed.game.outcome == .checkmate(winner: .black))
        let text = PGN.export(game: parsed.game, tags: parsed.tags.sorted { $0.key < $1.key })
        #expect(tagLines(text).contains("[Result \"0-1\"]"))
        #expect(!text.contains("[Result \"*\"]"))
        #expect(text.contains("2. g4 Qh4# 0-1"))
        #expect(tagLines(text).contains("[Termination \"normal\"]"))

        // The same through My Games, which writes an imported game out with
        // the tags it came with.
        let record = GameRecord(
            game: parsed.game, mode: .twoPlayer, options: GameOptions(variant: parsed.game.variant),
            moveTimes: [], finalClock: nil, source: .imported, tags: parsed.tags
        )
        let archived = try #require(record.pgn())
        #expect(tagLines(archived).contains("[Result \"0-1\"]"))
        #expect(terminator(archived) == "0-1")
    }

    @Test("A result a game still going on the board was given is kept, in both places", arguments: [
        ("1-0", "1-0"), ("0-1", "0-1"), ("1/2-1/2", "1/2-1/2"), ("½-½", "1/2-1/2"), ("?", "*"),
    ])
    func recordedResultKept(recorded: String, written: String) throws {
        let game = try played(["e2e4"])
        let text = PGN.export(game: game, tags: [("Result", recorded)])
        #expect(tagLines(text).contains("[Result \"\(written)\"]"))
        #expect(terminator(text) == written)
        // How it ended the moves cannot say, and "unterminated" would be
        // wrong for a game with a result.
        #expect(text.contains("Termination") == (written == "*"))
        // Read back, it ends the way it was written.
        let back = try onlyGame(text)
        #expect(PGN.result(of: back.game.outcome) == written)
    }

    @Test("A draw the app recorded is written \"1/2-1/2\" in both places, whatever the tag said")
    func recordedOutcomeWritesItsOwnResult() throws {
        var game = try played(["e2e4", "e7e5"])
        game.agreeToDraw()
        let text = PGN.export(game: game, tags: [("Result", "½-½")])
        #expect(tagLines(text).contains("[Result \"1/2-1/2\"]"))
        #expect(terminator(text) == "1/2-1/2")
    }
}

// MARK: - Castling

@Suite("PGN review fixes: castling as other programs write it")
struct PGNCastlingSpellingTests {

    @Test("Castling with a lowercase o or a word processor's dashes is read, and the game goes on", arguments: [
        ("o-o-o", "o-o"), ("O–O–O", "O–O"), ("O—O—O", "O—O"), ("0-0-0", "0-0"),
    ])
    func castlingSpellings(queenside: String, kingside: String) throws {
        let text = "1. d4 d5 2. Nc3 Nf6 3. Bf4 e6 4. Qd2 Be7 5. \(queenside) \(kingside) 6. e3 c5 *"
        let parsed = try onlyGame(text)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == [
            "d4", "d5", "Nc3", "Nf6", "Bf4", "e6", "Qd2", "Be7", "O-O-O", "O-O", "e3", "c5",
        ])
    }
}

// MARK: - Results in the movetext

@Suite("PGN review fixes: results as other programs write them")
struct PGNMovetextResultTests {

    @Test("A result glued to the mating move is read as the result, and the mate is played")
    func resultGluedToMate() throws {
        #expect(PGN.tokens(of: "4. Qxf7#1-0") == ["Qxf7#", "1-0"])
        let parsed = try onlyGame("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#1-0")
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.last?.san == "Qxf7#")
        #expect(parsed.game.outcome == .checkmate(winner: .white))
    }

    @Test("Every result glued to a move comes off it", arguments: [
        ("Nc6*", ["Nc6", "*"]), ("Nc6 1/2-1/2", ["Nc6", "1/2-1/2"]), ("Nc61/2-1/2", ["Nc6", "1/2-1/2"]),
        ("Nc61/2", ["Nc6", "1/2"]), ("Nc6!0-1", ["Nc6!", "0-1"]), ("O-O-O1-0", ["O-O-O", "1-0"]),
        // Castling written with zeros ends in "0-0", which is no result.
        ("0-0-0", ["0-0-0"]), ("0-0", ["0-0"]),
    ])
    func gluedResults(movetext: String, tokens: [String]) {
        #expect(PGN.tokens(of: movetext) == tokens)
    }

    @Test("A bare \"1/2\" is a draw, not a move")
    func bareHalf() throws {
        let parsed = try onlyGame("1. e4 e5 2. Nf3 Nf6 1/2")
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.count == 4)
        #expect(parsed.game.outcome == .drawAgreed)
    }
}

// MARK: - Moves on a tag's line

@Suite("PGN review fixes: moves on a tag's line")
struct PGNMovesOnTagLineTests {

    @Test("Moves after a tag on its line are the game's")
    func movesAfterTag() throws {
        let parsed = try onlyGame("[Event \"x\"] 1. e4 e5 *")
        #expect(parsed.tags == ["Event": "x"])
        #expect(parsed.game.history.map(\.san) == ["e4", "e5"])
    }

    @Test("Games whose line breaks were lost, one line each, are read whole")
    func gamesOnOneLineEach() throws {
        let text = """
            [Event "a"] [White "Ann"] [Result "1-0"] 1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
            [Event "b"] [Result "0-1"] 1. f3 e5 2. g4 Qh4# 0-1
            """
        let games = try PGN.parse(text)
        try #require(games.count == 2)
        #expect(games[0].tags == ["Event": "a", "White": "Ann", "Result": "1-0"])
        #expect(games[0].game.outcome == .checkmate(winner: .white))
        #expect(games[1].tags == ["Event": "b", "Result": "0-1"])
        #expect(games[1].game.outcome == .checkmate(winner: .black))
    }

    @Test("What follows a tag and is not a game's moves is passed over, and does not part the tags from the moves", arguments: [
        "[Event \"x\"] ; a note",
        "[Event \"x\"] {a note}",
        "[Event \"x\"]4",
        "[Event \"x\"]2[Round \"3\"]",
    ])
    func debrisAfterTag(line: String) throws {
        let parsed = try onlyGame("\(line)\n[Site \"y\"]\n\n1. e4 e5 *")
        #expect(parsed.tags["Event"] == "x")
        #expect(parsed.tags["Site"] == "y")
        #expect(parsed.game.history.count == 2)
    }
}

// MARK: - Several games without tags

@Suite("PGN review fixes: several games without tags")
struct PGNUntaggedGamesTests {

    @Test("Text without tags holding several games is read as every one of them")
    func gamesSplitAtResults() throws {
        let games = try PGN.parse("1. e4 e5 1-0\n\n1. d4 d5 0-1")
        try #require(games.count == 2)
        #expect(games[0].game.history.map(\.san) == ["e4", "e5"])
        #expect(games[0].game.outcome == .resigned(winner: .white))
        #expect(games[1].game.history.map(\.san) == ["d4", "d5"])
        #expect(games[1].game.outcome == .resigned(winner: .black))

        // On one line, the last one without a result.
        let line = try PGN.parse("1. e4 e5 1/2-1/2 1. d4 d5 * 1. c4")
        #expect(line.map(\.game.history.count) == [2, 2, 1])
    }

    @Test("A game after a tagged one that lost its own tags is read too, without them")
    func untaggedAfterTagged() throws {
        let games = try PGN.parse("[Event \"a\"]\n\n1. e4 e5 1-0\n\n1. d4 d5 0-1")
        try #require(games.count == 2)
        #expect(games[0].tags == ["Event": "a"])
        #expect(games[1].tags.isEmpty)
        #expect(games[1].game.history.map(\.san) == ["d4", "d5"])
    }

    @Test("A second result, or a result alone after a game, is no game")
    func lonelyResultIsNoGame() throws {
        let parsed = try onlyGame("1. e4 e5 1-0 1-0")
        #expect(parsed.game.history.count == 2)
    }
}

// MARK: - Moves that cannot be read

@Suite("PGN review fixes: moves that cannot be read are reported")
struct PGNLostMovesTests {

    @Test("A variation never closed reports its bracket as where reading stopped", arguments: [
        "1. e4 (1. d4 d5 2. c4 e5 *",
        "1. e4 (1. d4 d5 (1... Nf6) 2. c4) (1. c4 e5 *",
    ])
    func unclosedVariation(text: String) throws {
        let parsed = try onlyGame(text)
        #expect(parsed.game.history.map(\.san) == ["e4"])
        #expect(parsed.unreadMove == "(")
    }

    @Test("A brace comment never closed reports its bracket the same way")
    func unclosedComment() throws {
        let parsed = try onlyGame("1. e4 {a comment that never ends e5 2. Nf3 *")
        #expect(parsed.game.history.map(\.san) == ["e4"])
        #expect(parsed.unreadMove == "{")
        #expect(PGN.tokens(of: "1. e4 {e5 (") == ["e4", "{"])
        #expect(PGN.tokens(of: "1. e4 (e5 {") == ["e4", "("])
    }

    @Test("Moves played on past a fivefold repetition are reported, and the game ends drawn where FIDE ends it")
    func movesAfterFivefold() throws {
        let shuffle = (1...8).map { "\($0). " + ($0 % 2 == 1 ? "Nf3 Nf6" : "Ng1 Ng8") }.joined(separator: " ")
        let parsed = try onlyGame(shuffle + " 9. e4 e5 *")
        #expect(parsed.game.history.count == 16)
        #expect(parsed.game.outcome == .drawThreefoldRepetition)
        #expect(parsed.unreadMove == "e4")
    }

    @Test("Moves played on past the seventy-fifth move are reported")
    func movesAfterSeventyFiveMoves() throws {
        let text = """
            [SetUp "1"]
            [FEN "4k3/8/8/8/8/8/8/R3K3 w - - 149 80"]

            80. Ra2 Kd7 81. Ra3 *
            """
        let parsed = try onlyGame(text)
        #expect(parsed.game.history.map(\.san) == ["Ra2"])
        #expect(parsed.game.outcome == .drawFiftyMoveRule)
        #expect(parsed.unreadMove == "Kd7")
    }

    @Test("A move after mate is reported too")
    func moveAfterMate() throws {
        let parsed = try onlyGame("1. f3 e5 2. g4 Qh4# 3. a3 0-1")
        #expect(parsed.game.outcome == .checkmate(winner: .black))
        #expect(parsed.unreadMove == "a3")
    }
}

// MARK: - Promotion

@Suite("PGN review fixes: promotion written without \"=\"")
struct PGNLowercasePromotionTests {

    @Test("A lowercase piece straight after the rank is the piece promoted to", arguments: [
        ("1r2k3/P1P5/8/8/8/8/8/4K3 w - - 0 1", "a8q", "a7a8q"),
        ("1r2k3/P1P5/8/8/8/8/8/4K3 w - - 0 1", "axb8n", "a7b8n"),
        ("1r2k3/P1P5/8/8/8/8/8/4K3 w - - 0 1", "cxb8b", "c7b8b"),
        ("1r2k3/P1P5/8/8/8/8/8/4K3 w - - 0 1", "c8r", "c7c8r"),
        // A b-pawn: the "b" in front is the file, the one after the piece.
        ("2r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1", "b8b", "b7b8b"),
        ("2r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1", "bxc8b", "b7c8b"),
        ("2r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1", "bxc8q+", "b7c8q"),
        ("4k3/8/8/8/8/8/p7/4K3 b - - 0 1", "a1q", "a2a1q"),
    ])
    func lowercaseWithoutEquals(fen: String, token: String, uci: String) {
        #expect(PGN.move(for: token, in: Game(fen: fen))?.uci == uci)
    }

    @Test("A b-file pawn move without a piece after it is still no promotion, and a bishop move is still a bishop's")
    func bFileStaysAFile() {
        let promotion = Game(fen: "2r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1")
        #expect(PGN.move(for: "bxc8", in: promotion) == nil)
        let bishop = Game(fen: "4k3/8/8/8/8/8/1B5P/4K3 w - - 0 1")
        #expect(PGN.move(for: "Bb8", in: bishop) == nil)
        #expect(PGN.move(for: "Bh8", in: bishop)?.uci == "b2h8")
    }

    @Test("A game with such a promotion is read to its end")
    func gameWithLowercasePromotion() throws {
        let parsed = try onlyGame("[FEN \"8/P6k/8/8/8/8/8/K7 w - - 0 1\"]\n\n1. a8q Kg6 2. Qb8 *")
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["a8=Q", "Kg6", "Qb8"])
    }
}

// MARK: - Byte-order mark

@Suite("PGN review fixes: a byte-order mark")
struct PGNByteOrderMarkTests {

    @Test("A byte-order mark in front of the text does not hide its first tag")
    func leadingMark() throws {
        let parsed = try onlyGame("\u{FEFF}[Event \"bom\"]\n\n1. e4 *")
        #expect(parsed.tags == ["Event": "bom"])
        #expect(parsed.game.history.map(\.san) == ["e4"])
    }

    @Test("Nor does one in front of each of two files run together")
    func marksInsideTheText() throws {
        let games = try PGN.parse("\u{FEFF}[Event \"a\"]\n\n1. e4 *\n\u{FEFF}[Event \"b\"]\n\n1. d4 *")
        #expect(games.map { $0.tags["Event"] } == ["a", "b"])
        #expect(games.map(\.game.history.count) == [1, 1])
    }
}

// MARK: - King of the Hill

@Suite("PGN review fixes: a King of the Hill position already won")
struct KingOfTheHillWonPositionTests {

    private let moverOnHill = "k7/8/8/3K4/8/8/8/7R w - - 0 1"

    @Test("A position whose side to move already has its king on the hill is refused under those rules")
    func moverOnHillRefused() throws {
        #expect(Board(fen: moverOnHill, variant: .kingOfTheHill) == nil)
        // Under any other rules it is an ordinary position.
        #expect(Board(fen: moverOnHill) != nil)
        #expect(Board(fen: moverOnHill, variant: .standard) != nil)
        #expect(Board(fen: moverOnHill, variant: .threeCheck) != nil)

        // A game asked to start from it starts from the beginning instead,
        // as from any FEN that does not read; it used to be a game still
        // going that any rook move then won.
        let game = Game(fen: moverOnHill, variant: .kingOfTheHill)
        #expect(game.board.fen == Board.startFEN)
        #expect(game.variant == .kingOfTheHill)
        #expect(game.outcome == .ongoing)
    }

    @Test("The other side's king on the hill is a game won, and still reads as one")
    func nonMoverOnHillIsFinished() throws {
        let won = "k7/8/8/3K4/8/8/8/7R b - - 0 1"
        let board = try #require(Board(fen: won, variant: .kingOfTheHill))
        #expect(board.variantWinner == .white)
        #expect(Game(fen: won, variant: .kingOfTheHill).outcome == .kingOfTheHill(winner: .white))
    }

    @Test("A PGN set up from such a position is no game")
    func pgnFromWonPosition() {
        let text = """
            [Variant "King of the Hill"]
            [SetUp "1"]
            [FEN "\(moverOnHill)"]

            1. Rh2 *
            """
        #expect(throws: PGN.ParseError.noGames) { try PGN.parse(text) }
    }

    @Test("A three-check FEN keeps its counts only under three-check, read through the board as through the game")
    func checkCountsFollowTheVariant() throws {
        let fen = "4k3/8/8/8/8/8/8/3QK3 w - - 1+3 5 20"
        #expect(Board(fen: fen, variant: .threeCheck)?.checksGiven == CheckCounts(white: 2, black: 0))
        #expect(Board(fen: fen, variant: .kingOfTheHill)?.checksGiven == CheckCounts())
        #expect(Board(fen: fen, variant: .threeCheck) == Game(fen: fen, variant: .threeCheck).board)
    }
}

// MARK: - Chess960 detection

@Suite("PGN review fixes: a standard FEN whose king stepped off e1")
struct KingSteppedAsideTests {

    @Test("A king off the e-file with its rights' rooks still in the corners stays standard chess", arguments: [
        ("4k3/8/8/8/8/8/8/R4K1R w KQ - 0 1", "4k3/8/8/8/8/8/8/R4K1R w - - 0 1"),
        ("4k3/8/8/8/8/8/8/5K1R w K - 0 1", "4k3/8/8/8/8/8/8/5K1R w - - 0 1"),
        ("r4k1r/8/8/8/8/8/8/4K3 b kq - 0 1", "r4k1r/8/8/8/8/8/8/4K3 b - - 0 1"),
        // Black's king has stepped aside too, but not to White's file.
        ("r2k3r/8/8/8/8/8/8/R4K1R w KQkq - 0 1", "r2k3r/8/8/8/8/8/8/R4K1R w - - 0 1"),
    ])
    func kingSteppedAside(input: String, expected: String) throws {
        let board = try #require(Board(fen: input))
        #expect(!board.isChess960)
        #expect(board.fen == expected)
        #expect(!board.generateLegalMoves().contains { $0.isCastle })
        // Said to be Chess960, it is.
        #expect(Board(fen: input, chess960: true)?.isChess960 == true)
    }

    @Test("A king off the e-file with a rook off its corner, or both sides showing one array, is still Chess960", arguments: [
        ("4k3/8/8/8/8/8/8/5KR1 w K - 0 1", "4k3/8/8/8/8/8/8/5KR1 w G - 0 1"),
        ("4k3/8/8/8/8/8/8/R4KR1 w KQ - 0 1", "4k3/8/8/8/8/8/8/R4KR1 w GA - 0 1"),
        // Kings and rooks mirrored, the rooks in the corners.
        ("r2k3r/8/8/8/8/8/8/R2K3R w KQkq - 0 1", "r2k3r/8/8/8/8/8/8/R2K3R w HAha - 0 1"),
        ("r4k1r/8/8/8/8/8/8/R4K1R w Kq - 0 1", "r4k1r/8/8/8/8/8/8/R4K1R w Ha - 0 1"),
    ])
    func stillChess960(input: String, expected: String) throws {
        let board = try #require(Board(fen: input))
        #expect(board.isChess960)
        #expect(board.fen == expected)
        #expect(board.generateLegalMoves().contains { $0.isCastle })
    }

    @Test("Every Chess960 start written in X-FEN reads as itself")
    func everyStartInXFEN() throws {
        for number in Chess960.numbers {
            let shredder = Chess960.fen(number: number)
            var fields = shredder.split(separator: " ").map(String.init)
            fields[2] = "KQkq"
            let board = try #require(Board(fen: fields.joined(separator: " ")), "\(number)")
            // With the king on e1 and the rooks in the corners the castles
            // are standard chess's own, and the FEN reads as standard chess,
            // every right kept — position 518 and seventeen others.
            let backRank = Array(fields[0].split(separator: "/").last ?? "")
            if backRank[4] == "K", backRank[0] == "R", backRank[7] == "R" {
                #expect(board.castlingRights.rawValue == 15, "\(number)")
            } else {
                #expect(board.isChess960, "\(number)")
                #expect(board.fen == shredder, "\(number)")
            }
        }
    }
}
