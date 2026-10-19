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
    static func lessonAnnouncement(_ move: Move, san: String) -> String {
        String(
            localized: "announce.lessonMoveSpoken",
            defaultValue: "Played \(spokenMove(move, san: san))",
            comment: "Spoken after a move is played on a lesson diagram, e.g. 'Played knight f 3'"
        )
    }

    /// Spoken after a move so a VoiceOver user hears what happened without
    /// having to sweep the board again.
    static func announcement(for played: PlayedMove, outcome: GameOutcome, mode: GameMode) -> String {
        let sentence = movedAnnouncement(played.move, san: played.san)
        guard outcome.isGameOver else { return sentence }
        return sentence + ". " + outcome.headline(mode: mode)
    }

    /// "White: knight f 3" — who moved and what they played.
    ///
    /// A colon rather than a verb: Czech would want the piece in the
    /// instrumental after *zahrál* (*jezdcem*), which the spoken move, built
    /// in the nominative, cannot give it.
    static func movedAnnouncement(_ move: Move, san: String) -> String {
        let mover = move.piece.color.spokenName
        let spoken = spokenMove(move, san: san)
        return String(
            localized: "announce.moveSpoken",
            defaultValue: "\(mover): \(spoken)",
            comment: "Spoken after a move is made: the side, then the move, e.g. 'White: knight f 3'"
        )
    }

    // MARK: Moves

    /// A move as it is said rather than written: "knight f 3", "queen takes
    /// d 8, check", "castles kingside". VoiceOver reads written notation a
    /// letter at a time — "Q x d 8 plus" — which is no way to follow a game.
    ///
    /// `san` is only asked about the check or mate at its end; everything
    /// else comes from the move itself.
    static func spokenMove(_ move: Move, san: String) -> String {
        var spoken: String
        if move.isCastle {
            spoken = move.isCastleKingside
                ? String(localized: "speech.castle.kingside", defaultValue: "castles kingside",
                         comment: "Spoken move: castling on the king's side")
                : String(localized: "speech.castle.queenside", defaultValue: "castles queenside",
                         comment: "Spoken move: castling on the queen's side")
        } else {
            let piece = move.piece.kind.spokenName
            let square = move.to.spokenName
            spoken = move.isCapture
                ? String(localized: "speech.move.capture", defaultValue: "\(piece) takes \(square)",
                         comment: "Spoken move that captures, e.g. 'bishop takes c 6'")
                : String(localized: "speech.move.quiet", defaultValue: "\(piece) \(square)",
                         comment: "Spoken move, e.g. 'knight f 3'")
            if move.isEnPassant {
                spoken = String(localized: "speech.move.enPassant", defaultValue: "\(spoken), en passant",
                                comment: "Spoken move taken en passant, e.g. 'pawn takes d 6, en passant'")
            }
            if let promotion = move.promotion {
                let promoted = promotion.objectName
                spoken = String(localized: "speech.move.promotion", defaultValue: "\(spoken), promotes to \(promoted)",
                                comment: "Spoken promotion, e.g. 'pawn e 8, promotes to queen'")
            }
        }
        if san.hasSuffix("#") {
            spoken = String(localized: "speech.move.mate", defaultValue: "\(spoken), checkmate",
                            comment: "Spoken move that mates, e.g. 'queen h 7, checkmate'")
        } else if san.hasSuffix("+") {
            spoken = String(localized: "speech.move.check", defaultValue: "\(spoken), check",
                            comment: "Spoken move that gives check, e.g. 'rook e 1, check'")
        }
        return spoken
    }

    /// The same for a move about to be made on `board`, whose notation has
    /// not been written yet.
    static func spokenMove(_ move: Move, on board: Board) -> String {
        spokenMove(move, san: board.san(for: move))
    }

    // MARK: Move lists

    /// "Move 12, White: knight takes e 5, check" — one entry of a move list
    /// as it is said. Written, a list numbers White's move and lets Black's
    /// follow on after it; a listener going from entry to entry has no line
    /// to see that on, so every entry carries its number and its side.
    ///
    /// `mover` names the side where the screen has a better name for it than
    /// the colour, as the report has with "You" and "Computer".
    static func numberedMove(_ played: PlayedMove, mover: String? = nil) -> String {
        let number = played.moveNumber
        let side = mover ?? played.color.spokenName
        let spoken = spokenMove(played.move, san: played.san)
        return String(
            localized: "speech.numberedMove",
            defaultValue: "Move \(number), \(side): \(spoken)",
            comment: "A move of a move list read out by VoiceOver: its number, the side, then the move, e.g. 'Move 12, White: knight takes e 5'"
        )
    }

    /// Where a line that is stepped through rather than played now stands:
    /// the move the position on the board came from, or the start of the
    /// line when there is none.
    static func position(after played: PlayedMove?) -> String {
        guard let played else { return String(localized: "Starting position") }
        return numberedMove(played)
    }
}
