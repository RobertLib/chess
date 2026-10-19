//
//  SetupLabels.swift
//  chess
//
//  The words for the parts of a game's setup: starting positions, odds,
//  the adaptive opponent's strength.
//

import Foundation

extension StartPosition {
    /// "Chess960 #412", "Queen odds", "Custom position".
    var displayName: String {
        switch self {
        case .standard:
            return String(localized: "Standard position", comment: "Starting position")
        case .chess960(let number):
            return String(localized: "Chess960 #\(number)", comment: "Starting position, with its number")
        case .handicap(let handicap, _):
            return handicap.displayName
        case .custom:
            return String(localized: "Custom position", comment: "Starting position set up by hand")
        }
    }
}

extension ChessVariant {
    var displayName: String {
        switch self {
        case .standard: return String(localized: "Standard rules", comment: "Chess variant")
        case .kingOfTheHill: return String(localized: "King of the Hill", comment: "Chess variant")
        case .threeCheck: return String(localized: "Three-check", comment: "Chess variant")
        }
    }

    var shortName: String {
        switch self {
        case .standard: return String(localized: "variant.short.standard", defaultValue: "Classic", comment: "Chess variant, short, on a setup chip")
        case .kingOfTheHill: return String(localized: "variant.short.hill", defaultValue: "Hill", comment: "Chess variant King of the Hill, short, on a setup chip")
        case .threeCheck: return String(localized: "variant.short.threeCheck", defaultValue: "3 checks", comment: "Chess variant Three-check, short, on a setup chip")
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "checkerboard.rectangle"
        case .kingOfTheHill: return "mountain.2.fill"
        case .threeCheck: return "plus.circle.fill"
        }
    }

    /// The rule in a sentence, for the setup screen.
    var rule: String {
        switch self {
        case .standard:
            return String(localized: "Checkmate wins.")
        case .kingOfTheHill:
            return String(localized: "Checkmate wins — and so does a king that reaches one of the four centre squares.")
        case .threeCheck:
            return String(localized: "Checkmate wins — and so does the third check.")
        }
    }
}

extension Handicap {
    /// "Knight odds" — the name of the odds, not of the piece.
    var displayName: String {
        switch self {
        case .pawn: return String(localized: "Pawn odds", comment: "Handicap: one side plays without the f-pawn")
        case .knight: return String(localized: "Knight odds", comment: "Handicap: one side plays without a knight")
        case .rook: return String(localized: "Rook odds", comment: "Handicap: one side plays without a rook")
        case .queen: return String(localized: "Queen odds", comment: "Handicap: one side plays without the queen")
        }
    }

    var piece: PieceKind {
        switch self {
        case .pawn: return .pawn
        case .knight: return .knight
        case .rook: return .rook
        case .queen: return .queen
        }
    }
}

extension AIStrength {
    /// Roughly how the adaptive opponent stands, named after the nearest
    /// fixed level: "Between Easy and Medium".
    static func describe(level: Double) -> String {
        let levels = AIDifficulty.fixedLevels
        let clamped = min(Double(levels.count - 1), max(0, level))
        let nearest = Int(clamped.rounded())
        if abs(clamped - Double(nearest)) < 0.2 {
            return levels[nearest].displayName
        }
        let lower = levels[Int(clamped.rounded(.down))]
        let upper = levels[min(levels.count - 1, Int(clamped.rounded(.down)) + 1)]
        return String(localized: "Between \(lower.displayName) and \(upper.displayName)",
                      comment: "The adaptive opponent's strength, between two fixed levels")
    }
}
