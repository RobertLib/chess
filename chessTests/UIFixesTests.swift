//
//  UIFixesTests.swift
//  chessTests
//
//  One test per fault found in the screens that reading the code could pin
//  down without a simulator, each written to fail on the code as it was: a
//  clock read out with a bonus of nothing, and a PGN file in UTF-16 that not
//  one game could be read from.
//

import Foundation
import Testing
@testable import chess

@Suite("UI fixes: spoken time controls")
@MainActor
struct SpokenTimeControlTests {

    /// The presets with nothing added per move: 1 + 0 through 30 + 0.
    private static let withoutBonus = TimeControl.presets.filter { $0.bonus == 0 }

    @Test("A control with no bonus says nothing about one")
    func noBonus() throws {
        try #require(Self.withoutBonus.count >= 5, "the presets have changed; pick other controls")
        let nothing = ClockFormat.spoken(0)
        for control in Self.withoutBonus {
            let spoken = control.spokenName
            // "Blitz, 3 minutes" — and not "…, 3 minutes plus 0 seconds per move".
            #expect(spoken == "\(control.category.displayName), \(ClockFormat.spoken(control.initial))",
                    "\(control.label) is read \"\(spoken)\"")
            #expect(!spoken.contains(nothing), "\(control.label) still mentions \"\(nothing)\"")
        }
    }

    @Test("A control with a bonus still says what it is")
    func withBonus() {
        let increment = TimeControl.minutes(3, plus: 2)
        #expect(increment.spokenName.contains(ClockFormat.spoken(2)))

        let delay = TimeControl(initial: 300, bonus: 5, bonusKind: .delay)
        #expect(delay.spokenName.contains(ClockFormat.spoken(5)))
        #expect(delay.spokenName.contains(TimeControl.Bonus.delay.displayName))
    }
}

@Suite("UI fixes: reading PGN files")
@MainActor
struct PGNFileTextTests {

    private static let pgn = """
        [Event "Casual"]
        [White "Dvořák"]
        [Black "Smetana"]
        [Result "1-0"]

        1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
        """

    /// The games a file's bytes come to, through the same two steps the
    /// importer takes.
    private func games(in data: Data) throws -> [PGN.ParsedGame] {
        let text = try #require(MyGamesView.pgnText(from: data), "the bytes did not decode at all")
        return try PGN.parse(text)
    }

    @Test("UTF-16 with a byte-order mark, either way round, is read as UTF-16")
    func utf16() throws {
        let little = Data([0xFF, 0xFE]) + Self.pgn.data(using: .utf16LittleEndian)!
        let big = Data([0xFE, 0xFF]) + Self.pgn.data(using: .utf16BigEndian)!
        for data in [little, big] {
            // Read as Latin-1, which takes any bytes at all, this came out
            // with a NUL after every letter and no game in it.
            let parsed = try #require(try games(in: data).first)
            #expect(parsed.tags["White"] == "Dvořák")
            #expect(parsed.game.outcome == .checkmate(winner: .white))
        }
    }

    @Test("A UTF-8 byte-order mark does not hide the first tag")
    func utf8WithMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(Self.pgn.utf8)
        let text = try #require(MyGamesView.pgnText(from: data))
        #expect(text.hasPrefix("[Event"))
        let parsed = try #require(try games(in: data).first)
        #expect(parsed.tags["Event"] == "Casual")
    }

    @Test("Plain UTF-8 and Latin-1 read as before")
    func utf8AndLatin1() throws {
        let utf8 = try #require(try games(in: Data(Self.pgn.utf8)).first)
        #expect(utf8.tags["White"] == "Dvořák")

        // "ř" has no Latin-1 form, so this file names a player who has one.
        let latin1Text = Self.pgn.replacingOccurrences(of: "Dvořák", with: "Müller")
        let latin1 = try #require(latin1Text.data(using: .isoLatin1))
        let parsed = try #require(try games(in: latin1).first)
        #expect(parsed.tags["White"] == "Müller")
    }
}
