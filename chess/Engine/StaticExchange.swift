//
//  StaticExchange.swift
//  chess
//
//  Static exchange evaluation (SEE): what a capture sequence on one square is
//  worth if both sides keep taking with their cheapest attacker. The analyzer
//  uses it to tell a sacrifice from a plain blunder.
//

import Foundation

nonisolated extension Board {

    /// Material the mover wins (positive) or loses (negative) in centipawns by
    /// playing `move`, assuming the exchange on its target square is played
    /// out with the cheapest attacker each time.
    ///
    /// This is the usual swap-list SEE: it ignores pins and discovered
    /// attacks, so treat it as a strong hint rather than a proof.
    func staticExchangeEvaluation(_ move: Move) -> Int {
        let target = move.to.index
        var occupancy = squares

        // Play the move onto a scratch copy of the position.
        occupancy[move.from.index] = 0
        if move.isEnPassant {
            occupancy[move.piece.color == .white ? target - 8 : target + 8] = 0
        }
        let landed = move.promotion.map { Piece(move.piece.color, $0) } ?? move.piece
        occupancy[target] = landed.packed

        // gain[0]: material already banked by the move itself.
        var gain: [Int] = [move.captured.map { Self.seeValue($0.kind) } ?? 0]
        if let promotion = move.promotion {
            gain[0] += Self.seeValue(promotion) - Self.seeValue(.pawn)
        }

        // Value of the piece now standing on the target square — that is what
        // the next capture wins.
        var valueOnTarget = Self.seeValue(landed.kind)
        var side = move.piece.color.opponent
        var depth = 0

        while let attacker = Self.leastValuableAttacker(of: target, by: side, in: occupancy) {
            depth += 1
            gain.append(valueOnTarget - gain[depth - 1])
            // Neither side is forced to continue an exchange that loses.
            if max(-gain[depth - 1], gain[depth]) < 0 { break }

            occupancy[attacker.square] = 0
            occupancy[target] = attacker.piece.packed
            valueOnTarget = Self.seeValue(attacker.piece.kind)
            side = side.opponent
        }

        // Fold the swap list back: at every step the side to move may stop.
        while depth > 0 {
            gain[depth - 1] = -max(-gain[depth - 1], gain[depth])
            depth -= 1
        }
        return gain[0]
    }

    /// Piece values for exchange purposes. The king is priceless: it must
    /// never be picked as the winning target of an exchange.
    private static func seeValue(_ kind: PieceKind) -> Int {
        kind == .king ? 10_000 : kind.centipawns
    }

    /// Cheapest piece of `color` attacking `target`, scanning the given
    /// occupancy so that x-rays open up as pieces are removed.
    private static func leastValuableAttacker(
        of target: Int, by color: PieceColor, in occupancy: [UInt8]
    ) -> (square: Int, piece: Piece)? {
        let file = target & 7
        let rank = target >> 3

        // Pawns.
        let pawnRank = color == .white ? rank - 1 : rank + 1
        if (0..<8).contains(pawnRank) {
            let pawn = Piece(color, .pawn).packed
            if file > 0, occupancy[pawnRank * 8 + file - 1] == pawn {
                return (pawnRank * 8 + file - 1, Piece(color, .pawn))
            }
            if file < 7, occupancy[pawnRank * 8 + file + 1] == pawn {
                return (pawnRank * 8 + file + 1, Piece(color, .pawn))
            }
        }

        // Knights.
        let knight = Piece(color, .knight).packed
        for (df, dr) in SEETables.knight {
            let f = file + df, r = rank + dr
            guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
            if occupancy[r * 8 + f] == knight { return (r * 8 + f, Piece(color, .knight)) }
        }

        // Sliders, cheapest kind first: bishop, rook, queen.
        let diagonal = firstSlider(
            from: target, directions: SEETables.diagonal,
            kinds: [.bishop, .queen], color: color, occupancy: occupancy
        )
        let straight = firstSlider(
            from: target, directions: SEETables.straight,
            kinds: [.rook, .queen], color: color, occupancy: occupancy
        )
        let sliders = [diagonal, straight].compactMap { $0 }
        if let cheapest = sliders.min(by: { seeValue($0.piece.kind) < seeValue($1.piece.kind) }) {
            return cheapest
        }

        // King last.
        let king = Piece(color, .king).packed
        for (df, dr) in SEETables.king {
            let f = file + df, r = rank + dr
            guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
            if occupancy[r * 8 + f] == king { return (r * 8 + f, Piece(color, .king)) }
        }

        return nil
    }

    /// Cheapest slider of `kinds` bearing on `from` along `directions`.
    private static func firstSlider(
        from: Int, directions: [(Int, Int)], kinds: [PieceKind],
        color: PieceColor, occupancy: [UInt8]
    ) -> (square: Int, piece: Piece)? {
        let packedKinds = kinds.map { Piece(color, $0).packed }
        var found: (square: Int, piece: Piece)?
        for (df, dr) in directions {
            var f = (from & 7) + df, r = (from >> 3) + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let occupant = occupancy[r * 8 + f]
                if occupant != 0 {
                    if let index = packedKinds.firstIndex(of: occupant) {
                        let candidate = (r * 8 + f, Piece(color, kinds[index]))
                        if found == nil || seeValue(kinds[index]) < seeValue(found!.piece.kind) {
                            found = candidate
                        }
                    }
                    break
                }
                f += df; r += dr
            }
        }
        return found
    }
}

// MARK: - Direction tables

/// The move generator keeps its own private copies; these serve the exchange
/// scan above.
nonisolated private enum SEETables {
    static let knight: [(Int, Int)] = [
        (1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)
    ]
    static let king: [(Int, Int)] = [
        (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)
    ]
    static let diagonal: [(Int, Int)] = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    static let straight: [(Int, Int)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
}
