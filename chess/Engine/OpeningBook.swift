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

    // MARK: Playing from the book

    /// One move theory continues with, and how many lines carry on down it.
    struct Continuation: Sendable {
        let san: String
        /// Book lines that go this way. Used as the weight when a move is
        /// picked — see `move(after:in:randomSeed:)`.
        let lines: Int
    }

    /// Every move theory continues with from the position `sans` has reached,
    /// in the SAN the book is written in. Empty once the game has left the
    /// book.
    static func continuations(after sans: [String]) -> [Continuation] {
        let played = sans.map(normalized)
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in lines where line.moves.count > played.count {
            guard zip(line.moves, played).allSatisfy(==) else { continue }
            let candidate = line.moves[played.count]
            if counts[candidate] == nil { order.append(candidate) }
            counts[candidate, default: 0] += 1
        }
        return order.map { Continuation(san: $0, lines: counts[$0] ?? 0) }
    }

    /// Theory's own move here, or nil once the game has left the book.
    ///
    /// The answer is one of `board`'s own legal moves, matched by SAN, so a
    /// book line that does not apply to the position in front of it is passed
    /// over rather than trusted — the book's text and the position are two
    /// separate things and only the board decides what is playable.
    ///
    /// The pick is weighted by how many lines carry on down each move, which a
    /// uniform pick made the case for. The book names eleven first moves, and
    /// seven of them — 1.f4, 1.b3, 1.b4, 1.g4, 1.e3, 1.g3, 1.Nc3 — are a
    /// single one-move line each: a name in a dictionary, not an opening the
    /// book has anything further to say about. Sharing the chance out equally
    /// gave each of those the same 9 % as 1.e4, and the top level opened 1.b3
    /// in two games out of three. Counting lines is not a chess evaluation,
    /// but in a book somebody sat down and wrote it tracks how much theory an
    /// opening has: 1.e4 carries 52 of the 90 lines and runs 10 plies deep,
    /// 1.d4 carries 24, and the seven dictionary entries carry one apiece.
    /// Measured over the same eleven moves that weight gives 1.e4 58 %, 1.d4
    /// 27 %, 1.Nf3 4 %, 1.c4 3 % and 8 % to all seven oddities together —
    /// which is roughly how often a strong player does reach for one.
    static func move(after sans: [String], in board: Board, randomSeed: UInt64) -> Move? {
        let theory = continuations(after: sans)
        guard !theory.isEmpty else { return nil }
        let weights = Dictionary(theory.map { ($0.san, $0.lines) }, uniquingKeysWith: +)

        // `generateLegalMoves` is deterministic and so is the walk below, so
        // the same seed always picks the same book move — which is what keeps
        // a game reproducible from its seed the way a searched one is.
        let legal = board.generateLegalMoves()
        var candidates: [(move: Move, weight: Int)] = []
        for move in legal {
            let san = normalized(board.san(for: move, legalMoves: legal))
            guard let weight = weights[san] else { continue }
            candidates.append((move, weight))
        }
        guard !candidates.isEmpty else { return nil }

        let total = candidates.reduce(0) { $0 + $1.weight }
        var rng = Zobrist.SplitMix64(seed: randomSeed)
        var pick = Int(rng.next() % UInt64(total))
        for candidate in candidates {
            pick -= candidate.weight
            if pick < 0 { return candidate.move }
        }
        // The weights sum to `total`, so the walk always lands. Returning the
        // first candidate rather than trapping keeps a book that somehow
        // weighs nothing from taking the game with it.
        return candidates[0].move
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
