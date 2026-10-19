//
//  ImportFixesTests.swift
//  chessTests
//
//  The faults found in what comes in from elsewhere — PGN files, pasted
//  FENs, records stored by earlier builds — each with a test that fails on
//  the code as it was: a loss on time that came back from the archive drawn,
//  a stale castling right read as Chess960, a file's title read as a game,
//  glyphs and ellipses that stopped an import, three-check's counts read as
//  move counters, tags written out of order, and stored values that trapped.
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

/// A game as My Games files it on import.
private func imported(_ parsed: PGN.ParsedGame) -> GameRecord {
    GameRecord(
        game: parsed.game, mode: .twoPlayer, options: GameOptions(variant: parsed.game.variant),
        moveTimes: [], finalClock: nil, source: .imported, tags: parsed.tags
    )
}

/// The record as it comes back out of the store.
private func stored(_ record: GameRecord) throws -> GameRecord {
    try JSONDecoder().decode(GameRecord.self, from: JSONEncoder().encode(record))
}

// MARK: - Time forfeit

@Suite("Import fixes: a loss on time in the archive")
@MainActor
struct TimeForfeitArchiveTests {

    @Test("A loss on time read from PGN comes back from the archive as a loss, and is written out as one")
    func lossOnTimeSurvivesTheArchive() throws {
        // Black on move with a queen against White's lone knight: this app
        // would have drawn the flag, but the server that played it did not.
        let text = """
            [FEN "3qk3/8/8/8/8/8/8/1N2K3 w - - 0 1"]
            [Result "1-0"]
            [Termination "White won on time"]

            1. Nc3 1-0
            """
        let parsed = try #require(try PGN.parse(text).first)
        try #require(parsed.game.outcome == .timeForfeit(winner: .white))

        let record = try stored(imported(parsed))
        #expect(record.outcome == .timeForfeit(winner: .white))
        let restored = try #require(record.restoreGame())
        #expect(restored.outcome == .timeForfeit(winner: .white))

        // Tags and moves agree on the result, and it reads back the same.
        let pgn = try #require(record.pgn())
        #expect(pgn.contains("[Result \"1-0\"]"))
        #expect(pgn.contains("1. Nc3 1-0"))
        #expect(!pgn.contains("1/2-1/2"))
        #expect(try PGN.parse(pgn).first?.game.outcome == .timeForfeit(winner: .white))
    }

    @Test("A draw on time still comes back as a draw on time")
    func drawOnTimeSurvivesTheArchive() throws {
        // Black flags with only a rook left against White's bishop.
        var game = try played(["a1b2"], from: "7k/8/8/8/8/8/8/K1B4r w - - 0 1")
        game.timeOut()
        try #require(game.outcome == .drawTimeoutInsufficientMaterial)
        let record = try stored(GameRecord(
            game: game, mode: .twoPlayer, options: .standard, moveTimes: [], finalClock: nil
        ))
        #expect(record.restoreGame()?.outcome == .drawTimeoutInsufficientMaterial)
    }
}

// MARK: - Castling field

@Suite("Import fixes: stale castling rights")
struct StaleCastlingRightTests {

    @Test("A single right standard castling cannot explain leaves a standard FEN standard", arguments: [
        // The h-rook stepped to g1 and the K was never struck off.
        ("4k3/8/8/8/8/8/8/4K1R1 w K - 0 1", "4k3/8/8/8/8/8/8/4K1R1 w - - 0 1"),
        // The a-rook stepped to b8, the same for Black.
        ("1r2k3/8/8/8/8/8/8/4K3 w q - 0 1", "1r2k3/8/8/8/8/8/8/4K3 w - - 0 1"),
    ])
    func loneRightIsStale(input: String, expected: String) throws {
        let board = try #require(Board(fen: input))
        #expect(!board.isChess960)
        #expect(board.castlingRights.isEmpty)
        #expect(board.fen == expected)
        #expect(!board.generateLegalMoves().contains { $0.isCastle })
    }

    @Test("A single right with the king off the e-file and its rook off the corner is still Chess960", arguments: [
        // A 960 game a few moves in: each side has kept one right.
        ("1r3kr1/8/8/8/8/8/6P1/1R4KR w Kq - 0 1", "1r3kr1/8/8/8/8/8/6P1/1R4KR w Hb - 0 1"),
        // With the rook in the corner, "5K1R w K", it is a standard king
        // that stepped off e1 (see PGNReviewFixesTests).
        ("4k3/8/8/8/8/8/8/5KR1 w K - 0 1", "4k3/8/8/8/8/8/8/5KR1 w G - 0 1"),
    ])
    func loneRightOffTheEFileIs960(input: String, expected: String) throws {
        let board = try #require(Board(fen: input))
        #expect(board.isChess960)
        #expect(board.fen == expected)
        #expect(board.generateLegalMoves().contains { $0.isCastle })
    }

    @Test("Both sides naming the same rooks off the corner still read as Chess960 — and carry a lone right with them")
    func arrayIsStill960() throws {
        let pair = try #require(Board(fen: "r3k1r1/8/8/8/8/8/8/R3K1R1 w KQkq - 0 1"))
        #expect(pair.isChess960)
        #expect(pair.fen == "r3k1r1/8/8/8/8/8/8/R3K1R1 w GAga - 0 1")

        // One side's two rights are no evidence on their own: the h-rook
        // stepped to g1 and the K was left standing.
        let stale = try #require(Board(fen: "4k3/8/8/8/8/8/8/R3K1R1 w KQ - 0 1"))
        #expect(!stale.isChess960)
        #expect(stale.fen == "4k3/8/8/8/8/8/8/R3K1R1 w Q - 0 1")

        // Black's rights show its array; White's single one goes with it.
        let mixed = try #require(Board(fen: "1r3kr1/8/8/8/8/8/8/6KR w Kkq - 0 1"))
        #expect(mixed.isChess960)
        #expect(mixed.fen == "1r3kr1/8/8/8/8/8/8/6KR w Hgb - 0 1")
    }

    @Test("Read as Chess960, a K or Q with no rook left is dropped, and the other side's rights are kept")
    func staleXFENRightIn960() throws {
        let fen = "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/6K1 w KQkq - 0 1"
        let board = try #require(Board(fen: fen, chess960: true))
        #expect(board.isChess960)
        #expect(board.castlingRights == [.blackKingside, .blackQueenside])
        #expect(board.fen == "1r3kr1/pppppppp/8/8/8/8/PPPPPPPP/6K1 w gb - 0 1")
        // A rook file that names nothing still contradicts the board.
        #expect(Board(fen: "4k3/8/8/8/8/8/8/R3K2R w G - 0 1", chess960: true) == nil)

        // And a PGN that says Chess960 is read as Chess960, not refused into
        // standard chess, which dropped Black's rights with White's.
        let text = """
            [Variant "Chess960"]
            [FEN "\(fen)"]

            1. e4 e5 *
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.game.isChess960)
        #expect(parsed.game.initialFEN == board.fen)
        #expect(parsed.game.board.castlingRights == [.blackKingside, .blackQueenside])
        #expect(parsed.game.history.count == 2)
    }
}

// MARK: - PGN

@Suite("Import fixes: reading PGN")
struct PGNImportFixesTests {

    @Test("Text in front of the first tag is not a game of its own", arguments: [
        "{Annotated by me}\n",
        "Game 1\n",
        "% generated\nSome title\n\n",
    ])
    func textBeforeTheTags(preamble: String) throws {
        let text = preamble + """
            [Event "x"]

            1. e4 e5 *
            """
        let games = try PGN.parse(text)
        #expect(games.count == 1)
        #expect(games.first?.tags["Event"] == "x")
        #expect(games.first?.game.history.count == 2)
    }

    @Test("A game written without tags is still a game, in front of others or alone")
    func gameWithoutTags() throws {
        let games = try PGN.parse("1. e4 e5 *\n\n[Event \"x\"]\n\n1. d4 *")
        #expect(games.count == 2)
        #expect(games.first?.game.history.count == 2)
        #expect(try PGN.parse("1. e4 e5 *").first?.game.history.count == 2)
        // A title and nothing else is no game.
        #expect(throws: PGN.ParseError.noGames) { try PGN.parse("Game 1") }
    }

    @Test("A glyph glued to its move is read past")
    func gluedGlyph() throws {
        let parsed = try #require(try PGN.parse("1. e4$1 e5$2$18 2. Nf3!$3 Nc6 *").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    }

    @Test("A move number written with an ellipsis character is read past")
    func unicodeEllipsis() throws {
        let parsed = try #require(try PGN.parse("1. e4 {best by test} 1… e5 2. Nf3 2…Nc6 *").first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    }

    @Test("A promotion piece may be written lowercase after the equals sign")
    func lowercasePromotion() throws {
        let promotion = Game(fen: "3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1")
        #expect(PGN.move(for: "e8=q", in: promotion)?.uci == "e7e8q")
        #expect(PGN.move(for: "e8=n", in: promotion)?.uci == "e7e8n")
        #expect(PGN.move(for: "exd8=r+", in: promotion)?.uci == "e7d8r")
        #expect(PGN.move(for: "exd8=b", in: promotion)?.uci == "e7d8b")
        // Uppercase, with the sign or without, reads as it did.
        #expect(PGN.move(for: "e8=Q", in: promotion)?.uci == "e7e8q")
        #expect(PGN.move(for: "exd8N", in: promotion)?.uci == "e7d8n")

        let text = """
            [FEN "3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1"]

            1. exd8=q+ Kg7 *
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["exd8=Q+", "Kg7"])
    }
}

// MARK: - Three-check FEN

@Suite("Import fixes: three-check FENs")
struct ThreeCheckFENTests {

    private let twoGiven = "4k3/8/8/8/8/8/8/3QK3 w - - 1+3 5 20"

    @Test("Lichess's count of checks still to give is read, and the counters behind it")
    func lichessCounts() throws {
        let start = try #require(Board(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3 0 1"))
        #expect(start.checksGiven == CheckCounts())
        #expect(start.fen == Board.startFEN)

        let board = try #require(Board(fen: twoGiven))
        #expect(board.checksGiven == CheckCounts(white: 2, black: 0))
        #expect(board.halfmoveClock == 5)
        #expect(board.fullmoveNumber == 20)
        #expect(board.fen == twoGiven)

        // The older form, the checks given after the move number, is the
        // same position.
        #expect(Board(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 5 20 +2+0") == board)
    }

    @Test("A three-check game set up with two checks given wins on the third")
    func countsArePlayed() throws {
        var game = Game(fen: twoGiven, variant: .threeCheck)
        #expect(game.board.checksGiven.white == 2)
        #expect(game.initialFEN == twoGiven)
        game.play(try #require(game.legalMoves.first { $0.uci == "d1d7" }))
        #expect(game.outcome == .threeChecks(winner: .white))
        // The replay from the first position keeps the count.
        game.undoLastMove()
        #expect(game.board.checksGiven.white == 2)
    }

    @Test("The counts are written once a check has been given, and not before")
    func countsAreWritten() throws {
        #expect(Game(fen: Board.startFEN, variant: .threeCheck).initialFEN == Board.startFEN)
        let game = try played(["d1d7"], from: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1", variant: .threeCheck)
        #expect(game.board.fen == "4k3/3Q4/8/8/8/8/8/4K3 b - - 2+3 1 1")
        #expect(Game(fen: game.board.fen, variant: .threeCheck).board == game.board)

        // Under other rules the counts are no part of the position.
        let standard = Game(fen: twoGiven)
        #expect(standard.board.checksGiven == CheckCounts())
        #expect(standard.initialFEN == "4k3/8/8/8/8/8/8/3QK3 w - - 5 20")
    }

    @Test("A game already won by three checks is over; one won by the side to move cannot be")
    func finishedCounts() {
        let won = Game(fen: "4k3/8/8/8/8/8/8/3QK3 b - - 0+3 0 1", variant: .threeCheck)
        #expect(won.outcome == .threeChecks(winner: .white))
        #expect(Board(fen: "4k3/8/8/8/8/8/8/3QK3 w - - 0+3 0 1") == nil)
    }

    @Test("A three-check PGN set up from a counted position keeps its count")
    func pgnRoundTrip() throws {
        let text = """
            [Variant "Three-check"]
            [SetUp "1"]
            [FEN "4k3/8/8/8/8/8/8/3QK3 w - - 1+3 0 1"]

            1. Qd7+ *
            """
        let parsed = try #require(try PGN.parse(text).first)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.outcome == .threeChecks(winner: .white))
        let exported = PGN.export(game: parsed.game)
        #expect(exported.contains("[FEN \"4k3/8/8/8/8/8/8/3QK3 w - - 1+3 0 1\"]"))
        #expect(try PGN.parse(exported).first?.game.outcome == .threeChecks(winner: .white))
    }
}

// MARK: - Writing PGN

@Suite("Import fixes: writing PGN")
struct PGNExportFixesTests {

    private func tagLines(_ text: String) -> [String] {
        Array(text.components(separatedBy: "\n").prefix { $0.hasPrefix("[") })
    }

    @Test("The Seven Tag Roster comes first in the standard's order, whatever order the tags are given in")
    func sevenTagRoster() throws {
        let game = try played(["e2e4"])
        let text = PGN.export(game: game, tags: [
            ("Annotator", "Me"), ("Black", "Ben"), ("Date", "2024.01.02"),
            ("Event", "Club"), ("Result", "*"), ("White", "Ann"),
        ])
        #expect(tagLines(text) == [
            "[Event \"Club\"]", "[Site \"Chess (offline)\"]", "[Date \"2024.01.02\"]",
            "[Round \"-\"]", "[White \"Ann\"]", "[Black \"Ben\"]", "[Result \"*\"]",
            "[Annotator \"Me\"]", "[Termination \"unterminated\"]",
        ])
    }

    @Test("An imported game is written out with its roster first")
    @MainActor
    func importedGameOrder() throws {
        let text = """
            [White "Ann"]
            [Black "Ben"]
            [Event "Club"]
            [Site "Prague"]
            [ECO "C20"]
            [Date "2024.01.02"]
            [Round "3"]
            [Result "1-0"]

            1. e4 e5 1-0
            """
        let record = try stored(imported(try #require(try PGN.parse(text).first)))
        let lines = tagLines(try #require(record.pgn()))
        #expect(lines.prefix(7).map { line in String(line.prefix { $0 != " " }) } == [
            "[Event", "[Site", "[Date", "[Round", "[White", "[Black", "[Result",
        ])
        #expect(lines.contains("[ECO \"C20\"]"))
    }

    @Test("A clock face that is not a number is written as an empty clock instead of trapping")
    func nonFiniteClock() throws {
        let game = try played(["e2e4", "e7e5", "g1f3"])
        let text = PGN.export(game: game, clockAfterMove: [.nan, .infinity, 1e300])
        #expect(text.contains("1. e4 {[%clk 0:00:00]} 1... e5 {[%clk 0:00:00]} 2. Nf3 {[%clk"))
    }
}

// MARK: - Stored records

@Suite("Import fixes: stored records", .serialized)
@MainActor
struct StoredRecordFixesTests {

    private func record() throws -> GameRecord {
        GameRecord(
            game: try played(["e2e4", "e7e5"]), mode: .vsAI(difficulty: .easy, playerColor: .white),
            options: .standard, moveTimes: [], finalClock: nil
        )
    }

    @Test("An accuracy that is not one per player is dropped when the record is read")
    func shortAccuracy() throws {
        var short = try record()
        short.accuracy = [80]
        #expect(try stored(short).accuracy == nil)

        var long = try record()
        long.accuracy = [80, 70, 60]
        #expect(try stored(long).accuracy == nil)

        var good = try record()
        good.accuracy = [nil, 92.5]
        #expect(try stored(good).accuracy == [nil, 92.5])
    }

    @Test("The archive does not note an accuracy that is not one per player")
    func archiveRefusesShortAccuracy() throws {
        try withScratchStore("importFixesAccuracy") {
            let archive = GameArchive.shared
            let game = try record()
            archive.add(contentsOf: [game])
            archive.setAccuracy([80], for: game.id)
            #expect(archive.record(game.id)?.accuracy == nil)
            archive.setAccuracy([80, 75], for: game.id)
            #expect(archive.record(game.id)?.accuracy == [80, 75])
        }
    }
}
