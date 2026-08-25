//
//  MoveQualityDisplay.swift
//  chess
//
//  How move grades and evaluations are worded and coloured in the review.
//

import SwiftUI

// MARK: - Grades

extension MoveQuality {

    var label: String {
        switch self {
        case .brilliant: return String(localized: "Brilliant", comment: "Move grade")
        case .great: return String(localized: "Great move", comment: "Move grade")
        case .best: return String(localized: "Best move", comment: "Move grade")
        case .excellent: return String(localized: "grade.excellent", defaultValue: "Excellent", comment: "Move grade")
        case .good: return String(localized: "Good", comment: "Move grade")
        case .book: return String(localized: "Book move", comment: "Move grade")
        case .inaccuracy: return String(localized: "Inaccuracy", comment: "Move grade")
        case .mistake: return String(localized: "Mistake", comment: "Move grade")
        case .miss: return String(localized: "Missed chance", comment: "Move grade")
        case .blunder: return String(localized: "Blunder", comment: "Move grade")
        }
    }

    /// Colour of the badge and of the square highlight.
    var tint: Color {
        switch self {
        case .brilliant: return Color(red: 0.14, green: 0.76, blue: 0.65)
        case .great: return Color(red: 0.36, green: 0.63, blue: 0.85)
        case .best: return Color(red: 0.51, green: 0.72, blue: 0.30)
        case .excellent: return Color(red: 0.60, green: 0.76, blue: 0.34)
        case .good: return Color(red: 0.63, green: 0.71, blue: 0.55)
        case .book: return Color(red: 0.66, green: 0.53, blue: 0.40)
        case .inaccuracy: return Color(red: 0.97, green: 0.78, blue: 0.19)
        case .mistake: return Color(red: 1.00, green: 0.65, blue: 0.35)
        case .miss: return Color(red: 1.00, green: 0.47, blue: 0.41)
        case .blunder: return Color(red: 0.98, green: 0.25, blue: 0.18)
        }
    }

    /// Text drawn inside the badge, when it is not a symbol.
    var badgeText: String {
        switch self {
        case .brilliant: return "!!"
        case .great: return "!"
        case .best: return "★"
        case .excellent: return "✓"
        case .good: return "✓"
        case .book: return ""
        case .inaccuracy: return "?!"
        case .mistake: return "?"
        case .miss: return "✕"
        case .blunder: return "??"
        }
    }

    var badgeSymbol: String? {
        self == .book ? "book.closed.fill" : nil
    }

    var badgeForeground: Color {
        switch self {
        case .inaccuracy, .mistake, .good, .excellent:
            return Color.black.opacity(0.75)
        default:
            return .white
        }
    }

    /// Order used in the summary table, best first.
    static var summaryOrder: [MoveQuality] {
        [.brilliant, .great, .best, .excellent, .good, .book,
         .inaccuracy, .mistake, .miss, .blunder]
    }
}

// MARK: - Move comments

extension MoveAnalysis {

    /// The position after the move was played.
    var boardAfter: Board {
        var next = board
        next.make(played.move)
        return next
    }

    /// Material the opponent's best answer wins, by static exchange.
    var refutationGain: Int {
        guard let refutation else { return 0 }
        return boardAfter.staticExchangeEvaluation(refutation)
    }

    /// Mate the engine had available here, in moves.
    var mateAvailable: Int? {
        guard let mate = SearchScore.mateInMoves(bestScore), mate > 0 else { return nil }
        return mate
    }

    /// Whether the move played forces mate.
    var forcesMate: Bool {
        (SearchScore.mateInMoves(playedScore) ?? 0) > 0
    }

    /// A sentence or two on what this move did.
    var comment: String {
        let best = MoveNotation.display(bestSAN)
        switch quality {
        case .book:
            return String(localized: "Known opening theory.")
        case .brilliant:
            return String(localized: "A sacrifice that works — the \(played.move.piece.kind.objectName) is offered and the initiative more than pays for it.")
        case .great:
            return String(localized: "Just about the only move that holds the position together.")
        case .best:
            if played.san.hasSuffix("#") {
                return String(localized: "Checkmate — the strongest possible finish.")
            }
            if let mate = SearchScore.mateInMoves(playedScore), mate > 0 {
                return String(localized: "The strongest move — it forces mate in \(mate).")
            }
            return String(localized: "The strongest move in the position.")
        case .excellent:
            return String(localized: "Nearly the engine's choice; \(best) was a shade better.")
        case .good:
            return String(localized: "A sound move. \(best) was a little stronger.")
        case .inaccuracy:
            return String(localized: "Inaccurate — \(best) held on to more.\(threatSentence)")
        case .mistake:
            return String(localized: "A mistake. \(best) was clearly better.\(threatSentence)")
        case .miss:
            if let mate = mateAvailable, !forcesMate {
                return String(localized: "There was mate in \(mate) with \(best).")
            }
            return String(localized: "A won position slipped: \(best) was the way through.\(threatSentence)")
        case .blunder:
            return String(localized: "A blunder. \(best) was far better.\(threatSentence)")
        }
    }

    /// Names the punishment when the opponent's answer wins material.
    private var threatSentence: String {
        guard let refutationSAN, refutationGain >= 150 else { return "" }
        let answer = MoveNotation.display(refutationSAN)
        if let captured = refutation?.captured {
            return String(localized: " \(answer) now wins the \(captured.kind.objectName).")
        }
        return String(localized: " \(answer) is the strong answer.")
    }
}

extension PieceKind {
    /// The piece's name as the object of a sentence — "wins the rook". Czech
    /// and other inflected languages need the accusative here, which is not
    /// the form a bare list of pieces would use.
    var objectName: String {
        switch self {
        case .pawn: return String(localized: "piece.object.pawn", defaultValue: "pawn", comment: "Piece name in 'now wins the pawn'")
        case .knight: return String(localized: "piece.object.knight", defaultValue: "knight", comment: "Piece name in 'now wins the knight'")
        case .bishop: return String(localized: "piece.object.bishop", defaultValue: "bishop", comment: "Piece name in 'now wins the bishop'")
        case .rook: return String(localized: "piece.object.rook", defaultValue: "rook", comment: "Piece name in 'now wins the rook'")
        case .queen: return String(localized: "piece.object.queen", defaultValue: "queen", comment: "Piece name in 'now wins the queen'")
        case .king: return String(localized: "piece.object.king", defaultValue: "king", comment: "Piece name in 'now wins the king'")
        }
    }
}

// MARK: - Evaluation text

enum EvalFormat {

    /// Short evaluation label from White's point of view: "+1.4", "-0.8", "M5".
    /// Written with the reader's decimal separator — `String(format:)` prints
    /// a point in every language, where Czech writes "+1,4".
    static func text(centipawns: Int) -> String {
        if let mate = SearchScore.mateInMoves(centipawns) {
            return mate > 0 ? "M\(mate)" : "-M\(-mate)"
        }
        let pawns = Double(centipawns) / 100
        return pawns.formatted(
            .number.precision(.fractionLength(1)).sign(strategy: .always())
        )
    }

    /// The same evaluation as a sentence, for VoiceOver. "+1.4" read aloud is
    /// "plus one point four" and never says whose advantage it is, so the
    /// spoken form names the side instead of leaning on the sign.
    static func spoken(centipawns: Int) -> String {
        if let mate = SearchScore.mateInMoves(centipawns) {
            return mate > 0
                ? String(localized: "White mates in \(mate)", comment: "VoiceOver: a forced mate for White")
                : String(localized: "Black mates in \(-mate)", comment: "VoiceOver: a forced mate for Black")
        }
        let pawns = abs(Double(centipawns) / 100)
        guard pawns >= 0.05 else {
            return String(localized: "Level position", comment: "VoiceOver: neither side is better")
        }
        let amount = pawns.formatted(.number.precision(.fractionLength(1)))
        return centipawns > 0
            ? String(localized: "White ahead by \(amount)", comment: "VoiceOver: White's advantage, in pawns")
            : String(localized: "Black ahead by \(amount)", comment: "VoiceOver: Black's advantage, in pawns")
    }
}

// MARK: - Accuracy text

/// The accuracy percentage, in the reader's own numbers. `String(format:)`
/// formats against the C locale, so it printed "97.3%" even in a language that
/// writes "97,3 %".
enum AccuracyFormat {

    /// The figure with its percent sign: "97.3%" / "97,3 %".
    static func percent(_ accuracy: Double, fractionDigits: Int = 1) -> String {
        (accuracy / 100).formatted(.percent.precision(.fractionLength(fractionDigits)))
    }

    /// The bare figure, for a dial that draws the percent sign itself.
    static func number(_ accuracy: Double, fractionDigits: Int = 1) -> String {
        accuracy.formatted(.number.precision(.fractionLength(fractionDigits)))
    }
}
