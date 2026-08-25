//
//  Accessibility.swift
//  chess
//
//  How the board reads out loud. The visual board is a pile of decorative
//  layers, so VoiceOver is given its own description of every square instead.
//

import SwiftUI

// MARK: - Piece names

extension PieceKind {
    /// The piece's name on its own, as a list or a label would say it — the
    /// nominative, which in Czech differs from the accusative `objectName`.
    var spokenName: String {
        switch self {
        case .pawn: return String(localized: "piece.name.pawn", defaultValue: "pawn", comment: "Piece name, spoken on its own")
        case .knight: return String(localized: "piece.name.knight", defaultValue: "knight", comment: "Piece name, spoken on its own")
        case .bishop: return String(localized: "piece.name.bishop", defaultValue: "bishop", comment: "Piece name, spoken on its own")
        case .rook: return String(localized: "piece.name.rook", defaultValue: "rook", comment: "Piece name, spoken on its own")
        case .queen: return String(localized: "piece.name.queen", defaultValue: "queen", comment: "Piece name, spoken on its own")
        case .king: return String(localized: "piece.name.king", defaultValue: "king", comment: "Piece name, spoken on its own")
        }
    }
}

extension PieceColor {
    var spokenName: String {
        self == .white
            ? String(localized: "color.name.white", defaultValue: "White", comment: "Piece colour, spoken on its own")
            : String(localized: "color.name.black", defaultValue: "Black", comment: "Piece colour, spoken on its own")
    }

}

extension Piece {
    /// "white pawn" — what stands on a square.
    ///
    /// Spelled out for all twelve pieces rather than glued together from a
    /// colour and a kind: in Czech the adjective agrees with the noun's gender,
    /// so the same "white" is *bílý* pěšec but *bílá* věž. A composed string
    /// would get half of them wrong.
    var spokenName: String {
        switch (color, kind) {
        case (.white, .pawn):   return String(localized: "piece.white.pawn", defaultValue: "white pawn", comment: "Piece on a square, read out by VoiceOver")
        case (.white, .knight): return String(localized: "piece.white.knight", defaultValue: "white knight", comment: "Piece on a square, read out by VoiceOver")
        case (.white, .bishop): return String(localized: "piece.white.bishop", defaultValue: "white bishop", comment: "Piece on a square, read out by VoiceOver")
        case (.white, .rook):   return String(localized: "piece.white.rook", defaultValue: "white rook", comment: "Piece on a square, read out by VoiceOver")
        case (.white, .queen):  return String(localized: "piece.white.queen", defaultValue: "white queen", comment: "Piece on a square, read out by VoiceOver")
        case (.white, .king):   return String(localized: "piece.white.king", defaultValue: "white king", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .pawn):   return String(localized: "piece.black.pawn", defaultValue: "black pawn", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .knight): return String(localized: "piece.black.knight", defaultValue: "black knight", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .bishop): return String(localized: "piece.black.bishop", defaultValue: "black bishop", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .rook):   return String(localized: "piece.black.rook", defaultValue: "black rook", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .queen):  return String(localized: "piece.black.queen", defaultValue: "black queen", comment: "Piece on a square, read out by VoiceOver")
        case (.black, .king):   return String(localized: "piece.black.king", defaultValue: "black king", comment: "Piece on a square, read out by VoiceOver")
        }
    }
}

// MARK: - Squares

extension Square {
    /// "e4" read out as a file and a rank, with a space so speech does not run
    /// the two together.
    var spokenName: String {
        "\(Board.fileLetter(file)) \(rank + 1)"
    }
}

// MARK: - Board square description

/// Builds the label and hint VoiceOver reads for one square of a live game.
@MainActor
enum BoardSpeech {

    /// "e4, white pawn" / "e4, empty".
    static func label(square: Square, piece: Piece?) -> String {
        guard let piece else {
            return String(
                localized: "square.empty",
                defaultValue: "\(square.spokenName), empty",
                comment: "VoiceOver label for an empty board square"
            )
        }
        return String(
            localized: "square.occupied",
            defaultValue: "\(square.spokenName), \(piece.spokenName)",
            comment: "VoiceOver label for a square with a piece on it"
        )
    }

    /// What activating the square would do right now.
    static func hint(
        square: Square,
        piece: Piece?,
        isSelected: Bool,
        isLegalTarget: Bool,
        isCaptureTarget: Bool,
        canSelect: Bool
    ) -> String? {
        if isCaptureTarget {
            return String(localized: "Double tap to capture", comment: "VoiceOver hint on a square the selected piece can take")
        }
        if isLegalTarget {
            return String(localized: "Double tap to move here", comment: "VoiceOver hint on a square the selected piece can go to")
        }
        if isSelected {
            return String(localized: "Selected. Double tap to deselect", comment: "VoiceOver hint on the square of the selected piece")
        }
        if canSelect {
            return String(localized: "Double tap to select", comment: "VoiceOver hint on a piece the player may move")
        }
        return nil
    }

    // MARK: Lesson diagrams

    /// What a lesson diagram is showing, read as the board's value: which piece
    /// the lesson is pointing at, and that its moves are marked.
    static func lessonValue(focus: Piece?, at square: Square?) -> String {
        guard let focus, let square else { return "" }
        return String(
            localized: "tutorial.focusValue",
            defaultValue: "\(focus.spokenName) on \(square.spokenName), the moves on offer are marked",
            comment: "VoiceOver summary of a lesson diagram that offers a piece's moves"
        )
    }

    /// What activating a square of a lesson diagram would do. Empty squares and
    /// bystanders have nothing to offer and stay hintless.
    static func lessonHint(isFocus: Bool, isLegalTarget: Bool, isCaptureTarget: Bool) -> String? {
        if isCaptureTarget {
            return String(localized: "Double tap to capture", comment: "VoiceOver hint on a square the selected piece can take")
        }
        if isLegalTarget {
            return String(localized: "Double tap to move here", comment: "VoiceOver hint on a square the selected piece can go to")
        }
        if isFocus {
            return String(
                localized: "tutorial.focusHint",
                defaultValue: "The moves of this piece are marked on the board.",
                comment: "VoiceOver hint on the piece a lesson is about"
            )
        }
        return nil
    }

    /// Spoken when a lesson move is played, since the diagram cannot be seen.
    static func lessonAnnouncement(san: String) -> String {
        String(
            localized: "announce.lessonMove",
            defaultValue: "Played \(MoveNotation.display(san))",
            comment: "Spoken after a move is played on a lesson diagram"
        )
    }

    /// Spoken after a move so a VoiceOver user hears what happened without
    /// having to sweep the board again.
    static func announcement(for played: PlayedMove, outcome: GameOutcome, mode: GameMode) -> String {
        let move = MoveNotation.display(played.san)
        let mover = played.color.spokenName
        let sentence = String(
            localized: "announce.move",
            defaultValue: "\(mover) played \(move)",
            comment: "Spoken after a move is made, e.g. 'White played Nf3'"
        )
        guard outcome.isGameOver else { return sentence }
        return sentence + ". " + outcome.headline(mode: mode)
    }
}
