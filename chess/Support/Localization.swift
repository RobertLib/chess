//
//  Localization.swift
//  chess
//
//  The parts of the translation that are more than a lookup: chess notation
//  spells the pieces differently from one language to the next.
//

import Foundation

/// Algebraic notation writes a move as a piece letter plus a square, and the
/// letters follow the language: a knight is `N` in English and `J` (jezdec)
/// in Czech. Every move shown on screen goes through here, while the SAN the
/// engine, the opening book and the saved games work with stays English.
nonisolated enum MoveNotation {

    /// The English piece letters mapped onto the ones this language writes.
    /// Empty when the two agree, which lets `display` bail out immediately.
    private static let letters: [Character: Character] = {
        let english = Array("KQRBN")
        let localized = Array(String(
            localized: "notation.pieceLetters",
            defaultValue: "KQRBN",
            comment: """
                The five piece letters used when a move is written down, in the \
                order king, queen, rook, bishop, knight — no separators. Czech \
                chess writes KDVSJ (král, dáma, věž, střelec, jezdec).
                """
        ))
        guard localized.count == english.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(english, localized))
            .filter { $0.key != $0.value }
    }()

    /// Rewrites one move for display: `Nf3` reads `Jf3` in Czech.
    static func display(_ san: String) -> String {
        display(san, letters: letters)
    }

    /// The rewrite itself, with the mapping passed in. Split out from `display`
    /// so it can be tested against a language whose letters differ from
    /// English, whatever language the test happens to run in.
    static func display(_ san: String, letters: [Character: Character]) -> String {
        guard !letters.isEmpty else { return san }
        var result = ""
        result.reserveCapacity(san.count)
        // Only two characters of a move name a piece: the first one, and
        // whatever a pawn promotes to after the `=`.
        var namesAPiece = true
        for character in san {
            result.append(namesAPiece ? letters[character] ?? character : character)
            namesAPiece = character == "="
        }
        return result
    }
}
