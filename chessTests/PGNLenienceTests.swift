//
//  PGNLenienceTests.swift
//  chessTests
//
//  The faults a second review of the PGN reader and writer found, each with
//  a test that fails on the code as it was: movetext lines written eighty
//  characters long; moves on a tag's line after a comment, or without a move
//  number, lost without a word; a game whose FEN does not read dropped from
//  its file unnoticed; a Chess960 castle written as the king taking its own
//  rook, and long algebraic, refused; a move that does not read in text
//  without tags taken for no game at all; and clock comments handed out to
//  the wrong moves when there were not as many as moves.
//

import Foundation
import Testing
@testable import chess

private func played(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
    var game = Game(fen: fen)
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

/// A long game played by rote: the same rule picks every move, so a seed is
/// always the same game.
private func rote(seed: Int, plies: Int = 100) -> Game {
    var game = Game()
    for step in 0..<plies {
        let legal = game.legalMoves
        guard !legal.isEmpty else { break }
        game.play(legal[(step * (2 * seed + 3) + seed) % legal.count])
    }
    return game
}

// MARK: - Line length

@Suite("PGN lenience: movetext lines shorter than eighty characters")
struct PGNLineLengthTests {

    @Test("Every movetext line written is shorter than eighty characters, with clock comments or without")
    func linesUnderEighty() throws {
        for seed in 0..<12 {
            let game = rote(seed: seed)
            let clocks = PGN.clockFaces(control: .minutes(3, plus: 2), moveTimes: game.history.map { _ in 3 })
            for faces in [nil, clocks] {
                let text = PGN.export(game: game, clockAfterMove: faces)
                let movetext = text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("[") }
                #expect(movetext.count > 1)
                for line in movetext {
                    #expect(line.count < 80, "seed \(seed): \(line.count) characters in \(line)")
                }
                // Broken where it now is, the game still reads back whole.
                #expect(try PGN.parse(text).first?.game.history.map(\.move.uci) == game.history.map(\.move.uci))
            }
        }
    }
}

// MARK: - Moves on a tag's line

@Suite("PGN lenience: moves on a tag's line")
struct PGNTagLineMovesTests {

    @Test("Moves after the tags on their line are read after a comment, or without a move number", arguments: [
        "[Event \"x\"] [Result \"*\"] {Opening} 1. e4 e5 *",
        "[Event \"x\"] [Result \"*\"] e4 e5 *",
        "[Event \"x\"] [Result \"*\"] {Opening} e4 {King's pawn} e5 *",
        "[Event \"x\"][Result \"*\"]e4 e5 *",
    ])
    func movesAfterTags(line: String) throws {
        let parsed = try onlyGame(line)
        #expect(parsed.tags == ["Event": "x", "Result": "*"])
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5"])
    }

    @Test("A game pasted as one line without move numbers is read to its end, or to the move that does not read")
    func oneLineGame() throws {
        let mate = try onlyGame("[Event \"x\"] [Result \"0-1\"] f3 e5 g4 Qh4# 0-1")
        #expect(mate.game.history.map(\.san) == ["f3", "e5", "g4", "Qh4#"])
        #expect(mate.game.outcome == .checkmate(winner: .black))

        let stopped = try onlyGame("[Event \"x\"] e4 e5 Ke3 *")
        #expect(stopped.game.history.map(\.san) == ["e4", "e5"])
        #expect(stopped.unreadMove == "Ke3")
    }

    @Test("A word, a comment or a glyph after a tag is still passed over, and does not part the tags from the moves", arguments: [
        "[Event \"x\"] Annotated",
        "[Event \"x\"] {Opening}",
        "[Event \"x\"] $1",
    ])
    func notMovesAfterTag(line: String) throws {
        let parsed = try onlyGame("\(line)\n[Site \"y\"]\n\n1. e4 e5 *")
        #expect(parsed.tags == ["Event": "x", "Site": "y"])
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.count == 2)
    }
}

// MARK: - Games that cannot be set up

@Suite("PGN lenience: games that cannot be set up")
@MainActor
struct PGNUnreadableGameTests {

    private let mixed = """
        [Event "1"]
        [FEN "garbage"]

        1. e4 *

        [Event "2"]

        1. d4 *
        """

    @Test("A game whose FEN does not read is counted, and the games around it are still read")
    func countedNotDropped() throws {
        let contents = try PGN.contents(of: mixed)
        #expect(contents.unreadableGames == 1)
        #expect(contents.games.map { $0.tags["Event"] } == ["2"])
        #expect(contents.games.first?.game.history.map(\.san) == ["d4"])
        #expect(try PGN.parse(mixed).count == 1)
    }

    @Test("A text whose only game cannot be set up holds a game that could not be read, not no games", arguments: [
        "[Event \"1\"]\n[FEN \"garbage\"]\n\n1. e4 *",
        // A position the side to move has already won under the variant's rules.
        "[Variant \"King of the Hill\"]\n[SetUp \"1\"]\n[FEN \"k7/8/8/3K4/8/8/8/7R w - - 0 1\"]\n\n1. Rh2 *",
    ])
    func onlyGameUnreadable(text: String) throws {
        let contents = try PGN.contents(of: text)
        #expect(contents.games.isEmpty)
        #expect(contents.unreadableGames == 1)
        // `parse`, which hands back only games, still has none to hand back.
        #expect(throws: PGN.ParseError.noGames) { try PGN.parse(text) }
    }

    @Test("Text with no game in it at all is still no PGN", arguments: ["", "Game 1", "Some title\n\n"])
    func noGameAtAll(text: String) {
        #expect(throws: PGN.ParseError.noGames) { try PGN.contents(of: text) }
    }

    @Test("An import counts the games it could not read, and says so")
    func importSaysSo() throws {
        // The third game has tags and a move, and not one move of it reads.
        let games = try MyGamesView.importedGames(fromPGN: mixed + "\n\n[Event \"3\"]\n\n1. Zz4 e5 *\n")
        #expect(games.records.count == 1)
        #expect(games.records.first?.moveUCIs == ["d2d4"])
        #expect(games.cutShort == 0)
        #expect(games.unreadable == 2)

        // Tags with no moves after them are no game lost.
        let tagsOnly = try MyGamesView.importedGames(fromPGN: "[Event \"a\"]\n\n*\n\n[Event \"b\"]\n\n1. e4 *")
        #expect(tagsOnly.records.count == 1)
        #expect(tagsOnly.unreadable == 0)

        let summary = GameArchive.ImportSummary(added: 1, duplicates: 0, kept: 1)
        #expect(MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 1, unreadableGames: 2) == [
            String(localized: "Imported \(1) games."),
            String(localized: "\(2) games could not be read."),
        ].joined(separator: " "))
        #expect(MyGamesView.importMessage(for: summary, unreadableFiles: 0, of: 1)
                == String(localized: "Imported \(1) games."))
        // A file of nothing else read nothing, and says that.
        #expect(MyGamesView.importMessage(for: GameArchive.ImportSummary(), unreadableFiles: 0, of: 1, unreadableGames: 1)
                == String(localized: "No games could be read from that file."))
    }
}

// MARK: - Spellings

@Suite("PGN lenience: castling and long algebraic as other programs write them")
struct PGNLenientSpellingTests {

    private let chess960 = "rk5r/8/8/8/8/8/8/RK5R w HAha - 0 1"

    @Test("A castle written as the king taking its own rook is that castle")
    func kingTakesRook() throws {
        let game = Game(fen: chess960)
        try #require(game.board.isChess960)
        for token in ["Kxa1", "Ka1", "Kb1xa1", "Kb1a1"] {
            #expect(PGN.move(for: token, in: game)?.isCastleQueenside == true, "\(token)")
        }
        for token in ["Kxh1", "Kh1"] {
            #expect(PGN.move(for: token, in: game)?.isCastleKingside == true, "\(token)")
        }
        // The king's ordinary step to c1, where it lands castling long, is
        // still the step.
        let step = try #require(PGN.move(for: "Kc1", in: game))
        #expect(!step.isCastle)
        #expect(step.uci == "b1c1")

        let text = """
            [Variant "Chess960"]
            [SetUp "1"]
            [FEN "\(chess960)"]

            1. Kxh1 Kxa8 *
            """
        let parsed = try onlyGame(text)
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["O-O", "O-O-O"])
    }

    @Test("In standard chess too the king taking its own rook is the castle, and its landing square is not")
    func kingTakesRookInStandardChess() throws {
        let game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5"])
        #expect(PGN.move(for: "Kxh1", in: game)?.isCastleKingside == true)
        #expect(PGN.move(for: "Ke1xh1", in: game)?.isCastleKingside == true)
        #expect(PGN.move(for: "Kg1", in: game) == nil)
    }

    @Test("Long algebraic, the squares parted by a hyphen or a capture sign, is read")
    func longAlgebraic() throws {
        let parsed = try onlyGame("1. e2-e4 e7-e5 2. Ng1-f3 Nb8-c6 3. Bf1-b5 a7-a6 4. Bb5xc6 d7xc6 5. O-O Bf8-d6 *")
        #expect(parsed.unreadMove == nil)
        #expect(parsed.game.history.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Bxc6", "dxc6", "O-O", "Bd6"])

        let promotion = Game(fen: "3r2k1/4P3/8/8/8/8/8/4K3 w - - 0 1")
        #expect(PGN.move(for: "e7xd8=Q", in: promotion)?.uci == "e7d8q")
        #expect(PGN.move(for: "e7-e8=N", in: promotion)?.uci == "e7e8n")
        #expect(PGN.move(for: "e7–e8Q", in: promotion)?.uci == "e7e8q")
    }

    @Test("A hyphen anywhere but after the whole square a piece came from is still refused")
    func strayHyphens() {
        let start = Game()
        #expect(PGN.move(for: "N-f3", in: start) == nil)
        #expect(PGN.move(for: "Ng-f3", in: start) == nil)
        #expect(PGN.move(for: "e-e4", in: start) == nil)
        // The square has to be the one the piece came from.
        #expect(PGN.move(for: "Nb1-f3", in: start) == nil)
        #expect(PGN.move(for: "Ng1-f3", in: start)?.uci == "g1f3")
    }

    @Test("Without tags, a move that does not read is reported instead of the text being taken for no game", arguments: [
        ("1. Nf6 e4 *", "Nf6"), ("Kxa1", "Kxa1"), ("1. e2-e5 e7-e5 *", "e2-e5"),
    ])
    func untaggedUnreadMove(text: String, token: String) throws {
        let parsed = try onlyGame(text)
        #expect(parsed.game.history.isEmpty)
        #expect(parsed.unreadMove == token)
    }
}

// MARK: - Clock comments

@Suite("PGN lenience: a clock comment for every move, or none")
struct PGNClockCountTests {

    @Test("Clock faces that do not match the moves one for one are not written", arguments: [0, 2, 4])
    func mismatchedFaces(count: Int) throws {
        let game = try played(["e2e4", "e7e5", "g1f3"])
        let text = PGN.export(game: game, clockAfterMove: Array([180.0, 178, 175, 170].prefix(count)))
        #expect(!text.contains("%clk"))
        #expect(text.contains("1. e4 e5 2. Nf3 *"))
    }

    @Test("A recorded game whose move times do not match its moves is written without clocks")
    func recordWithMismatchedTimes() throws {
        let game = try played(["e2e4", "e7e5", "g1f3"])
        func record(_ moveTimes: [TimeInterval]) -> GameRecord {
            GameRecord(
                game: game, mode: .twoPlayer, options: GameOptions(timeControl: .minutes(3, plus: 2)),
                moveTimes: moveTimes, finalClock: nil
            )
        }
        let matched = try #require(record([5, 10, 20]).pgn())
        #expect(matched.contains("1. e4 {[%clk 0:03:00]} 1... e5 {[%clk 0:02:52]} 2. Nf3 {[%clk 0:02:42]} *"))
        for moveTimes: [TimeInterval] in [[5, 10], [5, 10, 20, 4]] {
            let text = try #require(record(moveTimes).pgn())
            #expect(!text.contains("%clk"), "\(moveTimes.count) times for 3 moves")
            #expect(text.contains("1. e4 e5 2. Nf3 *"))
        }
    }
}
