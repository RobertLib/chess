//
//  PGNExportSideTests.swift
//  chessTests
//
//  Two faults in writing PGN found after the lenience round: the clock faces
//  of a game set up with Black to move charged every move's time to the side
//  that did not spend it, and a tag value with a line break in it broke its
//  tag line, so the file read back as two games.
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

/// After 1.e4, with Black to move.
private let blackToMove = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"

struct PGNExportSideTests {

    @Test("A game set up with Black to move has its clock faces on the right sides")
    func blackMovesFirst() throws {
        // Time odds make the sides tell apart: three minutes against one.
        let control = TimeControl(initial: 180, bonus: 2, initialBlack: 60)
        let faces = PGN.clockFaces(control: control, moveTimes: [4, 10, 5], firstMover: .black)
        // Black's first move is not charged; White's 10 s and Black's 5 s are,
        // each from their own clock, with the bonus on top.
        #expect(faces == [60, 172, 57])

        let game = try played(["e7e5", "g1f3", "b8c6"], from: blackToMove)
        let record = GameRecord(
            game: game, mode: .twoPlayer, options: GameOptions(timeControl: control),
            moveTimes: [4, 10, 5], finalClock: nil
        )
        let text = try #require(record.pgn())
        #expect(text.contains("e5 {[%clk 0:01:00]}"))
        #expect(text.contains("Nf3 {[%clk 0:02:52]}"))
        #expect(text.contains("Nc6 {[%clk 0:00:57]}"))
    }

    @Test("White's game keeps its faces as before")
    func whiteMovesFirst() {
        let control = TimeControl(initial: 180, bonus: 2, initialBlack: 60)
        #expect(PGN.clockFaces(control: control, moveTimes: [4, 10, 5]) == [180, 52, 177])
    }

    @Test("A line break in a tag value stays on the tag's line", arguments: ["\n", "\r\n", "\r"])
    func lineBreakInTag(lineBreak: String) throws {
        let game = try played(["e2e4", "e7e5"])
        let text = PGN.export(game: game, tags: [("Event", "Club\(lineBreak)night")])
        #expect(text.contains("[Event \"Club night\"]"))
        let games = try PGN.parse(text)
        #expect(games.count == 1)
        #expect(games.first?.tags["Event"] == "Club night")
        #expect(games.first?.game.history.count == 2)
    }
}
