//
//  OpeningBook.swift
//  chess
//
//  A small book of mainline openings. The analyzer uses it to name the opening
//  and to leave known theory moves unjudged instead of scoring them.
//

import Foundation

nonisolated enum OpeningBook {

    /// One named line, written in the same SAN the engine produces.
    ///
    /// The name is held as a `LocalizedStringResource` rather than an already
    /// translated `String`: `lines` is a `static let`, so a `String(localized:)`
    /// in there would be resolved once, on whatever thread first asked for the
    /// book, and keep that wording for the life of the process. A resource
    /// carries the key instead and is turned into words in `match`, when a game
    /// is actually being named.
    struct Line: Sendable {
        let name: LocalizedStringResource
        let moves: [String]

        init(_ name: LocalizedStringResource, _ moves: String) {
            self.name = name
            self.moves = moves.split(separator: " ").map(String.init)
        }
    }

    /// What the book recognises in a game.
    struct Match: Sendable {
        /// Name of the most specific line the game followed.
        var name: String?
        /// How many opening moves are known theory.
        var bookPlies: Int
    }

    /// Longest line the game followed. `bookPlies` counts every leading move
    /// that still agrees with some line in the book, so a game that follows
    /// theory further than any complete line still gets credit for it.
    static func match(sans: [String]) -> Match {
        guard !sans.isEmpty else { return Match(name: nil, bookPlies: 0) }
        let played = sans.map(normalized)

        var bookPlies = 0
        var name: LocalizedStringResource?
        var nameLength = 0

        for line in lines {
            // The leading plies the game shares with this line. A line the
            // game left on its very last move still vouches for everything
            // before that: those moves were theory whatever came after them,
            // and a review that graded them would be judging the wrong thing.
            var matched = 0
            for (expected, actual) in zip(line.moves, played) {
                guard expected == actual else { break }
                matched += 1
            }
            guard matched > 0 else { continue }

            bookPlies = max(bookPlies, matched)
            // Only a line the game actually played to the end may name the
            // opening — four moves into a Najdorf it is still just a Sicilian.
            if matched == line.moves.count, matched > nameLength {
                name = line.name
                nameLength = matched
            }
        }

        return Match(name: name.map { String(localized: $0) }, bookPlies: bookPlies)
    }

    /// Strips check and mate marks so book lines need not carry them.
    private static func normalized(_ san: String) -> String {
        san.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
    }

    // MARK: Lines

    static let lines: [Line] = [
        // 1. e4
        Line(LocalizedStringResource("King's Pawn Opening", comment: "Chess opening"), "e4"),
        Line(LocalizedStringResource("Open Game", comment: "Chess opening"), "e4 e5"),
        Line(LocalizedStringResource("King's Knight Opening", comment: "Chess opening"), "e4 e5 Nf3"),
        Line(LocalizedStringResource("Philidor Defense", comment: "Chess opening"), "e4 e5 Nf3 d6"),
        Line(LocalizedStringResource("Petrov's Defense", comment: "Chess opening"), "e4 e5 Nf3 Nf6"),
        Line(LocalizedStringResource("Italian Game", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bc4"),
        Line(LocalizedStringResource("Italian Game: Giuoco Piano", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bc4 Bc5"),
        Line(LocalizedStringResource("Italian Game: Two Knights Defense", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bc4 Nf6"),
        Line(LocalizedStringResource("Italian Game: Evans Gambit", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bc4 Bc5 b4"),
        Line(LocalizedStringResource("Hungarian Defense", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bc4 Be7"),
        Line(LocalizedStringResource("Ruy López Opening", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5"),
        Line(LocalizedStringResource("Ruy López: Morphy Defense", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 a6"),
        Line(LocalizedStringResource("Ruy López: Berlin Defense", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 Nf6"),
        Line(LocalizedStringResource("Ruy López: Exchange Variation", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 a6 Bxc6"),
        Line(LocalizedStringResource("Ruy López: Closed", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O"),
        Line(LocalizedStringResource("Scotch Game", comment: "Chess opening"), "e4 e5 Nf3 Nc6 d4"),
        Line(LocalizedStringResource("Scotch Game", comment: "Chess opening"), "e4 e5 Nf3 Nc6 d4 exd4 Nxd4"),
        Line(LocalizedStringResource("Four Knights Game", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Nc3 Nf6"),
        Line(LocalizedStringResource("Ponziani Opening", comment: "Chess opening"), "e4 e5 Nf3 Nc6 c3"),
        Line(LocalizedStringResource("Vienna Game", comment: "Chess opening"), "e4 e5 Nc3"),
        Line(LocalizedStringResource("King's Gambit", comment: "Chess opening"), "e4 e5 f4"),
        Line(LocalizedStringResource("Bishop's Opening", comment: "Chess opening"), "e4 e5 Bc4"),
        Line(LocalizedStringResource("Center Game", comment: "Chess opening"), "e4 e5 d4"),
        Line(LocalizedStringResource("Sicilian Defense", comment: "Chess opening"), "e4 c5"),
        Line(LocalizedStringResource("Sicilian Defense: Closed", comment: "Chess opening"), "e4 c5 Nc3"),
        Line(LocalizedStringResource("Sicilian Defense: Alapin Variation", comment: "Chess opening"), "e4 c5 c3"),
        Line(LocalizedStringResource("Sicilian Defense: Smith-Morra Gambit", comment: "Chess opening"), "e4 c5 d4 cxd4 c3"),
        Line(LocalizedStringResource("Sicilian Defense: Open", comment: "Chess opening"), "e4 c5 Nf3 d6 d4 cxd4 Nxd4"),
        Line(LocalizedStringResource("Sicilian Defense: Najdorf Variation", comment: "Chess opening"), "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6"),
        Line(LocalizedStringResource("Sicilian Defense: Dragon Variation", comment: "Chess opening"), "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6"),
        Line(LocalizedStringResource("Sicilian Defense: Accelerated Dragon", comment: "Chess opening"), "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 g6"),
        Line(LocalizedStringResource("Sicilian Defense: Sveshnikov Variation", comment: "Chess opening"), "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 Nf6 Nc3 e5"),
        Line(LocalizedStringResource("Sicilian Defense: Taimanov Variation", comment: "Chess opening"), "e4 c5 Nf3 e6 d4 cxd4 Nxd4 Nc6"),
        Line(LocalizedStringResource("French Defense", comment: "Chess opening"), "e4 e6"),
        Line(LocalizedStringResource("French Defense: Advance Variation", comment: "Chess opening"), "e4 e6 d4 d5 e5"),
        Line(LocalizedStringResource("French Defense: Winawer Variation", comment: "Chess opening"), "e4 e6 d4 d5 Nc3 Bb4"),
        Line(LocalizedStringResource("French Defense: Classical Variation", comment: "Chess opening"), "e4 e6 d4 d5 Nc3 Nf6"),
        Line(LocalizedStringResource("French Defense: Exchange Variation", comment: "Chess opening"), "e4 e6 d4 d5 exd5 exd5"),
        Line(LocalizedStringResource("French Defense: Tarrasch Variation", comment: "Chess opening"), "e4 e6 d4 d5 Nd2"),
        Line(LocalizedStringResource("Caro-Kann Defense", comment: "Chess opening"), "e4 c6"),
        Line(LocalizedStringResource("Caro-Kann Defense: Advance Variation", comment: "Chess opening"), "e4 c6 d4 d5 e5"),
        Line(LocalizedStringResource("Caro-Kann Defense: Classical", comment: "Chess opening"), "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5"),
        Line(LocalizedStringResource("Caro-Kann Defense: Exchange", comment: "Chess opening"), "e4 c6 d4 d5 exd5 cxd5"),
        Line(LocalizedStringResource("Caro-Kann Defense: Panov Attack", comment: "Chess opening"), "e4 c6 d4 d5 exd5 cxd5 c4"),
        Line(LocalizedStringResource("Pirc Defense", comment: "Chess opening"), "e4 d6"),
        Line(LocalizedStringResource("Pirc Defense", comment: "Chess opening"), "e4 d6 d4 Nf6 Nc3 g6"),
        Line(LocalizedStringResource("Modern Defense", comment: "Chess opening"), "e4 g6"),
        Line(LocalizedStringResource("Scandinavian Defense", comment: "Chess opening"), "e4 d5"),
        Line(LocalizedStringResource("Alekhine Defense", comment: "Chess opening"), "e4 Nf6"),
        Line(LocalizedStringResource("Nimzowitsch Defense", comment: "Chess opening"), "e4 Nc6"),
        Line(LocalizedStringResource("Owen's Defense", comment: "Chess opening"), "e4 b6"),
        Line(LocalizedStringResource("Bird's Defense to the Ruy López", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 Nd4"),

        // 1. d4
        Line(LocalizedStringResource("Queen's Pawn Opening", comment: "Chess opening"), "d4"),
        Line(LocalizedStringResource("Queen's Gambit", comment: "Chess opening"), "d4 d5 c4"),
        Line(LocalizedStringResource("Queen's Gambit Accepted", comment: "Chess opening"), "d4 d5 c4 dxc4"),
        Line(LocalizedStringResource("Queen's Gambit Declined", comment: "Chess opening"), "d4 d5 c4 e6"),
        Line(LocalizedStringResource("Slav Defense", comment: "Chess opening"), "d4 d5 c4 c6"),
        Line(LocalizedStringResource("Semi-Slav Defense", comment: "Chess opening"), "d4 d5 c4 c6 Nf3 Nf6 Nc3 e6"),
        Line(LocalizedStringResource("Albin Counter-Gambit", comment: "Chess opening"), "d4 d5 c4 e5"),
        Line(LocalizedStringResource("Chigorin Defense", comment: "Chess opening"), "d4 d5 c4 Nc6"),
        Line(LocalizedStringResource("Catalan Opening", comment: "Chess opening"), "d4 d5 c4 e6 Nf3 Nf6 g3"),
        Line(LocalizedStringResource("London System", comment: "Chess opening"), "d4 d5 Nf3 Nf6 Bf4"),
        Line(LocalizedStringResource("Indian Defense", comment: "Chess opening"), "d4 Nf6"),
        Line(LocalizedStringResource("Trompowsky Attack", comment: "Chess opening"), "d4 Nf6 Bg5"),
        Line(LocalizedStringResource("Nimzo-Indian Defense", comment: "Chess opening"), "d4 Nf6 c4 e6 Nc3 Bb4"),
        Line(LocalizedStringResource("Queen's Indian Defense", comment: "Chess opening"), "d4 Nf6 c4 e6 Nf3 b6"),
        Line(LocalizedStringResource("Bogo-Indian Defense", comment: "Chess opening"), "d4 Nf6 c4 e6 Nf3 Bb4"),
        Line(LocalizedStringResource("King's Indian Defense", comment: "Chess opening"), "d4 Nf6 c4 g6 Nc3 Bg7"),
        Line(LocalizedStringResource("Grünfeld Defense", comment: "Chess opening"), "d4 Nf6 c4 g6 Nc3 d5"),
        Line(LocalizedStringResource("Benoni Defense", comment: "Chess opening"), "d4 Nf6 c4 c5"),
        Line(LocalizedStringResource("Modern Benoni", comment: "Chess opening"), "d4 Nf6 c4 c5 d5 e6"),
        Line(LocalizedStringResource("Benko Gambit", comment: "Chess opening"), "d4 Nf6 c4 c5 d5 b5"),
        Line(LocalizedStringResource("Budapest Gambit", comment: "Chess opening"), "d4 Nf6 c4 e5"),
        Line(LocalizedStringResource("Dutch Defense", comment: "Chess opening"), "d4 f5"),
        Line(LocalizedStringResource("Polish Defense", comment: "Chess opening"), "d4 b5"),
        Line(LocalizedStringResource("Englund Gambit", comment: "Chess opening"), "d4 e5"),

        // Flank openings
        Line(LocalizedStringResource("English Opening", comment: "Chess opening"), "c4"),
        Line(LocalizedStringResource("English Opening: Symmetrical", comment: "Chess opening"), "c4 c5"),
        Line(LocalizedStringResource("English Opening: Reversed Sicilian", comment: "Chess opening"), "c4 e5"),
        Line(LocalizedStringResource("Réti Opening", comment: "Chess opening"), "Nf3"),
        Line(LocalizedStringResource("Réti Opening", comment: "Chess opening"), "Nf3 d5 c4"),
        Line(LocalizedStringResource("King's Indian Attack", comment: "Chess opening"), "Nf3 d5 g3"),
        Line(LocalizedStringResource("Zukertort Opening", comment: "Chess opening"), "Nf3 Nf6"),
        Line(LocalizedStringResource("Bird's Opening", comment: "Chess opening"), "f4"),
        Line(LocalizedStringResource("Larsen's Opening", comment: "Chess opening"), "b3"),
        Line(LocalizedStringResource("Sokolsky Opening", comment: "Chess opening"), "b4"),
        Line(LocalizedStringResource("Grob's Attack", comment: "Chess opening"), "g4"),
        Line(LocalizedStringResource("Van 't Kruijs Opening", comment: "Chess opening"), "e3"),
        Line(LocalizedStringResource("Hungarian Opening", comment: "Chess opening"), "g3"),
        Line(LocalizedStringResource("Dunst Opening", comment: "Chess opening"), "Nc3"),
    ]
}
