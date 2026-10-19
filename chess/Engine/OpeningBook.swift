//
//  OpeningBook.swift
//  chess
//
//  A small book of mainline openings. The analyzer uses it to name the opening
//  and to leave known theory moves unjudged instead of scoring them; the two
//  strongest levels play out of it.
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
        /// Whether the computer may play this line, rather than only know it.
        ///
        /// False for a line whose defining move theory marks as dubious — the
        /// Englund Gambit, Grob's Attack and the like. The book holds them so
        /// that a player who tries one has it named, and its moves left
        /// unjudged like any other theory; but the book is also what the top
        /// two levels open from, and weighted by line count those lines came
        /// up as often as any other single line: 1.d4 e5 in one game in
        /// twenty-three against 1.d4, 1.g4 in one in ninety.
        let isSound: Bool

        init(_ name: LocalizedStringResource, _ moves: String, isSound: Bool = true) {
            self.name = name
            self.moves = moves.split(separator: " ").map(String.init)
            self.isSound = isSound
        }
    }

    /// What the book recognises in a game.
    struct Match: Sendable {
        /// Name of the most specific line the game followed.
        var name: String?
        /// How many opening moves are known theory.
        var bookPlies: Int
    }

    /// What the book recognises in the game `sans` spells out from the
    /// standard starting position — see `match(positions:)`. The moves are
    /// read only as far as they are legal.
    static func match(sans: [String]) -> Match {
        match(positions: replay(sans).map(\.zobrist))
    }

    /// What the book recognises in a game, given the Zobrist hash of the
    /// position after each of its moves.
    ///
    /// Matched by position rather than by move sequence, so that an opening
    /// reached in another order is still that opening. Matching the sequence
    /// named 1.Nf3 d5 2.d4 Nf6 3.Bf4 the Réti, two moves into a London
    /// System, and graded three of its theory moves as though the player had
    /// found them over the board.
    ///
    /// `bookPlies` counts every leading move that lands on a position some
    /// line passes through, so a game that follows theory further than any
    /// complete line still gets credit for it — and a game that steps out of
    /// the book and back in is judged from where it stepped out. The name is
    /// that of the longest line whose final position the game reached at any
    /// point: four moves into a Najdorf it is still just a Sicilian, but a
    /// game that came to a Queen's Indian by way of a position the book does
    /// not hold is a Queen's Indian all the same.
    static func match(positions keys: [UInt64]) -> Match {
        var bookPlies = 0
        while bookPlies < keys.count, (index[keys[bookPlies]]?.plies ?? 0) > 0 {
            bookPlies += 1
        }

        var name: LocalizedStringResource?
        var nameLength = 0
        for key in keys {
            guard let known = index[key], let lineName = known.name, known.nameLength > nameLength else { continue }
            name = lineName
            nameLength = known.nameLength
        }

        return Match(name: name.map { String(localized: $0) }, bookPlies: bookPlies)
    }

    // MARK: Playing from the book

    /// One move theory continues with, and how many lines carry on down it.
    struct Continuation: Sendable {
        let san: String
        /// Sound book lines that go this way. Used as the weight when a move
        /// is picked — see `move(after:in:randomSeed:)`.
        let lines: Int
    }

    /// Every move theory continues with from the position `sans` has reached,
    /// in the SAN the book is written in. Empty once the game has left the
    /// book, and never offers a line that is not `isSound`.
    static func continuations(after sans: [String]) -> [Continuation] {
        guard let board = position(after: sans) else { return [] }
        return index[board.zobrist]?.continuations ?? []
    }

    /// Theory's own move here, or nil once the game has left the book.
    ///
    /// The answer is one of `board`'s own legal moves, matched by SAN, so a
    /// book line that does not apply to the position in front of it is passed
    /// over rather than trusted — the book's text and the position are two
    /// separate things and only the board decides what is playable. Which
    /// lines apply is decided by the position, not by the order of the moves
    /// that reached it, so the book carries on after a transposition.
    ///
    /// The pick is weighted by how many sound lines carry on down each move,
    /// which a uniform pick made the case for. The book offers nine first
    /// moves, and five of them — 1.f4, 1.b3, 1.e3, 1.g3, 1.Nc3 — are a single
    /// one-move line each: a name in a dictionary, not an opening the book has
    /// anything further to say about. Sharing the chance out equally gave each
    /// of those the same share as 1.e4, and the top level opened 1.b3 in two
    /// games out of three. Counting lines is not a chess evaluation, but in a
    /// book somebody sat down and wrote it tracks how much theory an opening
    /// has: 1.e4 carries 49 of the 83 sound lines and runs 10 plies deep,
    /// 1.d4 carries 22, and the five dictionary entries carry one apiece. That
    /// weight gives 1.e4 59 %, 1.d4 27 %, 1.Nf3 5 %, 1.c4 4 % and 6 % to all
    /// five oddities together — which is roughly how often a strong player
    /// does reach for one.
    static func move(after sans: [String], in board: Board, randomSeed: UInt64) -> Move? {
        // Opening theory is about the standard array, and a Chess960 game is
        // never in it — not even position 518, whose castling is played
        // differently. Refused here and not only by the caller, because the
        // caller's way of keeping a game out is to pass an empty history.
        guard !board.isChess960, board.variant == .standard else { return nil }
        // Asked first because it is one lookup, and for every move after the
        // opening it is the answer.
        guard let theory = index[board.zobrist]?.continuations, !theory.isEmpty else { return nil }
        // The moves still have to be this board's own history. The position
        // decides which theory applies; the history is the caller saying this
        // is a game from the standard start, and a history that does not lead
        // here means the question is about some other game. An empty one is
        // how a game set up from a FEN is kept out, even when the FEN is a
        // position the book knows.
        guard position(after: sans)?.zobrist == board.zobrist else { return nil }
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

    /// Where `sans` leads from the standard starting position, or nil if one
    /// of them is not a legal move on the way.
    private static func position(after sans: [String]) -> Board? {
        let path = replay(sans)
        guard path.count == sans.count else { return nil }
        return path.last ?? .initial
    }

    /// The positions `sans` passes through from the standard starting
    /// position, one after each move, for as long as the moves are legal.
    private static func replay(_ sans: [String]) -> [Board] {
        var board = Board.initial
        var path: [Board] = []
        path.reserveCapacity(sans.count)
        for san in sans {
            guard let next = board.playing(san: normalized(san)) else { break }
            board = next
            path.append(board)
        }
        return path
    }

    // MARK: Positions

    /// What the book knows about one position.
    private struct Position: Sendable {
        /// How many moves into its line the book first reaches it; 0 only for
        /// the starting position, which is where every line begins rather
        /// than a move of theory.
        var plies: Int
        /// The longest line that ends here, and how long it is.
        var name: LocalizedStringResource?
        var nameLength = 0
        /// The moves sound lines carry on with from here, in the order the
        /// lines first name them.
        var continuations: [Continuation] = []
    }

    /// Every position a line of the book passes through, by Zobrist hash.
    ///
    /// Built once, the first time the book is asked anything. The lines share
    /// most of their moves, so each distinct run of moves is played out only
    /// once. The hash is the one the search keys its tables and repetitions
    /// by: it includes castling rights and an en-passant square only when a
    /// capture there is really possible, so two move orders that reach the
    /// same position give the same key, as they should.
    private static let index: [UInt64: Position] = {
        var index: [UInt64: Position] = [:]
        let start = Board.initial
        index[start.zobrist] = Position(plies: 0)
        // Positions already played out, by the moves that lead to them.
        var reached: [String: Board] = [:]

        for line in lines {
            var board = start
            var played = 0
            for (ply, san) in line.moves.enumerated() {
                let path = line.moves[...ply].joined(separator: " ")
                // A line the board cannot play is left out from there on
                // rather than trusted; `everyLineIsPlayableAndNamed` keeps the
                // book free of them.
                guard let next = reached[path] ?? board.playing(san: san) else { break }
                reached[path] = next
                if line.isSound {
                    var continuations = index[board.zobrist]?.continuations ?? []
                    if let known = continuations.firstIndex(where: { $0.san == san }) {
                        continuations[known] = Continuation(san: san, lines: continuations[known].lines + 1)
                    } else {
                        continuations.append(Continuation(san: san, lines: 1))
                    }
                    index[board.zobrist]?.continuations = continuations
                }
                board = next
                played = ply + 1
                if index[board.zobrist] == nil { index[board.zobrist] = Position(plies: played) }
            }
            if played == line.moves.count, played > index[board.zobrist]?.nameLength ?? 0 {
                index[board.zobrist]?.name = line.name
                index[board.zobrist]?.nameLength = played
            }
        }
        return index
    }()

    /// Strips check and mate marks so book lines need not carry them.
    fileprivate static func normalized(_ san: String) -> String {
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
        Line(LocalizedStringResource("Ruy López: Closed", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7"),
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
        Line(LocalizedStringResource("Nimzowitsch Defense", comment: "Chess opening"), "e4 Nc6", isSound: false),
        Line(LocalizedStringResource("Owen's Defense", comment: "Chess opening"), "e4 b6", isSound: false),
        Line(LocalizedStringResource("Bird's Defense to the Ruy López", comment: "Chess opening"), "e4 e5 Nf3 Nc6 Bb5 Nd4", isSound: false),

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
        Line(LocalizedStringResource("Polish Defense", comment: "Chess opening"), "d4 b5", isSound: false),
        Line(LocalizedStringResource("Englund Gambit", comment: "Chess opening"), "d4 e5", isSound: false),

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
        Line(LocalizedStringResource("Sokolsky Opening", comment: "Chess opening"), "b4", isSound: false),
        Line(LocalizedStringResource("Grob's Attack", comment: "Chess opening"), "g4", isSound: false),
        Line(LocalizedStringResource("Van 't Kruijs Opening", comment: "Chess opening"), "e3"),
        Line(LocalizedStringResource("Hungarian Opening", comment: "Chess opening"), "g3"),
        Line(LocalizedStringResource("Dunst Opening", comment: "Chess opening"), "Nc3"),
    ]
}

nonisolated private extension Board {
    /// This position after the legal move `san` names, written without check
    /// or mate marks, or nil when no legal move is written that way.
    func playing(san: String) -> Board? {
        let legal = generateLegalMoves()
        guard let move = legal.first(where: {
            OpeningBook.normalized(self.san(for: $0, legalMoves: legal)) == san
        }) else { return nil }
        var next = self
        next.make(move)
        return next
    }
}
