//
//  StaticExchange.swift
//  chess
//
//  Static exchange evaluation (SEE): what a capture sequence on one square is
//  worth if both sides keep taking with their cheapest attacker. The analyzer
//  uses it to tell a sacrifice from a plain blunder, and a piece given up
//  from one that was lost already.
//

import Foundation

nonisolated extension Board {

    /// Material the mover wins (positive) or loses (negative) in centipawns by
    /// playing `move`, assuming the exchange on its target square is played
    /// out with the cheapest attacker each time.
    ///
    /// This is the usual swap-list SEE with one rule added: a capture that
    /// would leave the capturer's own king in check is not one it can make,
    /// so a piece pinned to its king, or a side that has to answer a check
    /// first, takes no part (see `leastValuableAttacker`). Without that a
    /// knight landing where only a pinned pawn could take it read as lost,
    /// and the review called a fork that won the queen a brilliant
    /// sacrifice. Pins against anything less than the king, and attacks the
    /// exchange uncovers elsewhere, are still not seen, so treat it as a
    /// strong hint rather than a proof.
    func staticExchangeEvaluation(_ move: Move) -> Int {
        // Castling captures nothing, and the king it moves may not land where
        // it can be taken, so there is no exchange to play out. The swap list
        // would invent one: in Chess960 `to` is the rook's own square (see
        // `Move`), so it would stand the king there and count any attacker of
        // that square as winning a king — a ten-thousand-centipawn
        // "sacrifice" for the review to call brilliant.
        guard !move.isCastle else { return 0 }
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

        // Played out to the last capture, with no early stop. The textbook
        // cutoff — break once neither side can gain — assumes the entry it has
        // just written is a guess the fold throws away; here the entry is a
        // capture that really is available, and stopping after it scored the
        // exchange as if the other side could not take back. Nxe5 on a pawn
        // that two pawns defend came out at -120 rather than -220. The fold
        // below already lets either side stop where continuing loses.
        while let attacker = Self.leastValuableAttacker(of: target, by: side, in: occupancy) {
            depth += 1
            // A pawn that takes on its last rank promotes as it takes, so it
            // wins the queen it becomes as well as what stood there, and the
            // queen is what the next capture wins. Only the first move's
            // promotion used to count: a pawn taking back on the last rank
            // stayed a pawn, and a rook left where a pawn could take it and
            // queen read as 500 lost rather than 1300.
            let standing = Self.promotes(attacker.piece, on: target)
                ? Piece(side, .queen) : attacker.piece
            let promotion = Self.seeValue(standing.kind) - Self.seeValue(attacker.piece.kind)
            gain.append(valueOnTarget + promotion - gain[depth - 1])

            occupancy[attacker.square] = 0
            occupancy[target] = standing.packed
            valueOnTarget = Self.seeValue(standing.kind)
            side = side.opponent
        }

        // Fold the swap list back: at every step the side to move may stop.
        while depth > 0 {
            gain[depth - 1] = -max(-gain[depth - 1], gain[depth])
            depth -= 1
        }
        return gain[0]
    }

    /// Material the piece on `square` stands to lose where it is: what the
    /// other side would win by taking it there, were it their move, with the
    /// exchange played out as above. Zero for an empty square, for a piece
    /// nothing attacks, and for one that costs more to take than it is worth —
    /// nobody is made to start an exchange that loses them material.
    ///
    /// A pawn taking on its last rank queens, the same as it does further
    /// into the exchange.
    func materialAtRisk(on square: Square) -> Int {
        guard let victim = piece(at: square),
              let taker = Self.leastValuableAttacker(
                  of: square.index, by: victim.color.opponent, in: squares
              )
        else { return 0 }
        let capture = Move(
            from: Square(taker.square), to: square, piece: taker.piece, captured: victim,
            promotion: Self.promotes(taker.piece, on: square.index) ? .queen : nil
        )
        return max(0, staticExchangeEvaluation(capture))
    }

    /// Whether `piece` arriving on `target` is a pawn reaching its last rank.
    private static func promotes(_ piece: Piece, on target: Int) -> Bool {
        piece.kind == .pawn && target >> 3 == (piece.color == .white ? 7 : 0)
    }

    /// Piece values for exchange purposes. The king is priceless: it must
    /// never be picked as the winning target of an exchange.
    private static func seeValue(_ kind: PieceKind) -> Int {
        kind == .king ? 10_000 : kind.centipawns
    }

    /// Cheapest piece of `color` that can legally take on `target`, scanning
    /// the given occupancy so that x-rays open up as pieces are removed.
    ///
    /// Legally means its own king is not left in check by the capture. That
    /// covers a piece pinned to the king, the king stepping onto a guarded
    /// square, and a side in check taking with anything that does not end the
    /// check — each passed over for the next cheapest attacker, as a player
    /// would have to.
    private static func leastValuableAttacker(
        of target: Int, by color: PieceColor, in occupancy: [UInt8]
    ) -> (square: Int, piece: Piece)? {
        attackers(of: target, by: color, in: occupancy).first { attacker in
            var after = occupancy
            after[attacker.square] = 0
            after[target] = attacker.piece.packed
            let king = attacker.piece.kind == .king
                ? target : after.firstIndex(of: Piece(color, .king).packed)
            // A position without a king of this colour (a test fixture, say)
            // has nothing to leave in check.
            guard let king else { return true }
            return !isAttacked(king, by: color.opponent, in: after)
        }
    }

    /// Every piece of `color` bearing on `target` directly, cheapest first,
    /// the king last.
    private static func attackers(
        of target: Int, by color: PieceColor, in occupancy: [UInt8]
    ) -> [(square: Int, piece: Piece)] {
        let file = target & 7
        let rank = target >> 3
        var found: [(square: Int, piece: Piece)] = []

        // Pawns.
        let pawnRank = color == .white ? rank - 1 : rank + 1
        if (0..<8).contains(pawnRank) {
            let pawn = Piece(color, .pawn).packed
            if file > 0, occupancy[pawnRank * 8 + file - 1] == pawn {
                found.append((pawnRank * 8 + file - 1, Piece(color, .pawn)))
            }
            if file < 7, occupancy[pawnRank * 8 + file + 1] == pawn {
                found.append((pawnRank * 8 + file + 1, Piece(color, .pawn)))
            }
        }

        // Knights.
        let knight = Piece(color, .knight).packed
        for (df, dr) in SEETables.knight {
            let f = file + df, r = rank + dr
            guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
            if occupancy[r * 8 + f] == knight { found.append((r * 8 + f, Piece(color, .knight))) }
        }

        // Sliders, cheapest kind first: bishop, rook, queen.
        var sliders = slidersBearing(
            on: target, directions: SEETables.diagonal,
            kinds: [.bishop, .queen], color: color, occupancy: occupancy
        )
        sliders += slidersBearing(
            on: target, directions: SEETables.straight,
            kinds: [.rook, .queen], color: color, occupancy: occupancy
        )
        // Stable, so equal pieces keep the order they were found in.
        found += sliders.enumerated()
            .sorted { (seeValue($0.element.piece.kind), $0.offset) < (seeValue($1.element.piece.kind), $1.offset) }
            .map(\.element)

        // King last.
        let king = Piece(color, .king).packed
        for (df, dr) in SEETables.king {
            let f = file + df, r = rank + dr
            guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
            if occupancy[r * 8 + f] == king { found.append((r * 8 + f, Piece(color, .king))) }
        }

        return found
    }

    /// The first piece along each of `directions` from `target`, where it is
    /// one of `kinds`.
    private static func slidersBearing(
        on target: Int, directions: [(Int, Int)], kinds: [PieceKind],
        color: PieceColor, occupancy: [UInt8]
    ) -> [(square: Int, piece: Piece)] {
        let packedKinds = kinds.map { Piece(color, $0).packed }
        var found: [(square: Int, piece: Piece)] = []
        for (df, dr) in directions {
            var f = (target & 7) + df, r = (target >> 3) + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let occupant = occupancy[r * 8 + f]
                if occupant != 0 {
                    if let index = packedKinds.firstIndex(of: occupant) {
                        found.append((r * 8 + f, Piece(color, kinds[index])))
                    }
                    break
                }
                f += df; r += dr
            }
        }
        return found
    }

    /// Whether any piece of `by` attacks `square` in the given occupancy —
    /// `isSquareAttacked`, asked of the exchange's scratch board rather than
    /// of the real one.
    private static func isAttacked(_ square: Int, by color: PieceColor, in occupancy: [UInt8]) -> Bool {
        let file = square & 7
        let rank = square >> 3

        let pawnRank = color == .white ? rank - 1 : rank + 1
        if (0..<8).contains(pawnRank) {
            let pawn = Piece(color, .pawn).packed
            if file > 0, occupancy[pawnRank * 8 + file - 1] == pawn { return true }
            if file < 7, occupancy[pawnRank * 8 + file + 1] == pawn { return true }
        }
        for (offsets, kind) in [(SEETables.knight, PieceKind.knight), (SEETables.king, .king)] {
            let packed = Piece(color, kind).packed
            for (df, dr) in offsets {
                let f = file + df, r = rank + dr
                if (0..<8).contains(f), (0..<8).contains(r), occupancy[r * 8 + f] == packed { return true }
            }
        }
        return !slidersBearing(
            on: square, directions: SEETables.diagonal,
            kinds: [.bishop, .queen], color: color, occupancy: occupancy
        ).isEmpty || !slidersBearing(
            on: square, directions: SEETables.straight,
            kinds: [.rook, .queen], color: color, occupancy: occupancy
        ).isEmpty
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
