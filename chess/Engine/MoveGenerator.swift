//
//  MoveGenerator.swift
//  chess
//
//  Legal move generation and attack detection.
//

import Foundation

nonisolated extension Board {

    // MARK: Direction tables (file delta, rank delta)

    private static let knightOffsets: [(Int, Int)] = [
        (1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)
    ]
    private static let kingOffsets: [(Int, Int)] = [
        (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)
    ]
    private static let bishopDirections: [(Int, Int)] = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    private static let rookDirections: [(Int, Int)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]

    /// What a pawn reaching the last rank may become — see `generatePawnMoves`.
    fileprivate static let allPromotions: [PieceKind] = [.queen, .rook, .bishop, .knight]
    fileprivate static let queenPromotionOnly: [PieceKind] = [.queen]

    // MARK: Attack detection

    /// Is `index` attacked by any piece of `attacker`?
    func isSquareAttacked(_ index: Int, by attacker: PieceColor) -> Bool {
        let file = index & 7
        let rank = index >> 3

        // Pawn attacks (a pawn on rank-1 relative to attacker's direction).
        let pawnRank = attacker == .white ? rank - 1 : rank + 1
        if (0..<8).contains(pawnRank) {
            let pawn = Piece(attacker, .pawn).packed
            if file > 0, squares[pawnRank * 8 + file - 1] == pawn { return true }
            if file < 7, squares[pawnRank * 8 + file + 1] == pawn { return true }
        }

        // Knight attacks
        let knight = Piece(attacker, .knight).packed
        for (df, dr) in Board.knightOffsets {
            let f = file + df, r = rank + dr
            if (0..<8).contains(f), (0..<8).contains(r), squares[r * 8 + f] == knight {
                return true
            }
        }

        // King attacks
        let king = Piece(attacker, .king).packed
        for (df, dr) in Board.kingOffsets {
            let f = file + df, r = rank + dr
            if (0..<8).contains(f), (0..<8).contains(r), squares[r * 8 + f] == king {
                return true
            }
        }

        // Sliding attacks: bishops/queens on diagonals.
        let bishop = Piece(attacker, .bishop).packed
        let queen = Piece(attacker, .queen).packed
        for (df, dr) in Board.bishopDirections {
            var f = file + df, r = rank + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let occupant = squares[r * 8 + f]
                if occupant != 0 {
                    if occupant == bishop || occupant == queen { return true }
                    break
                }
                f += df; r += dr
            }
        }

        // Sliding attacks: rooks/queens on files and ranks.
        let rook = Piece(attacker, .rook).packed
        for (df, dr) in Board.rookDirections {
            var f = file + df, r = rank + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let occupant = squares[r * 8 + f]
                if occupant != 0 {
                    if occupant == rook || occupant == queen { return true }
                    break
                }
                f += df; r += dr
            }
        }

        return false
    }

    // MARK: Pseudo-legal generation

    /// Generates pseudo-legal moves for the side to move. Castling is emitted
    /// only when fully legal (king not in check, path safe) — bar one Chess960
    /// case the filter has to catch, see `appendCastle`. Other moves may still
    /// leave the own king in check and must be filtered.
    func generatePseudoLegalMoves(capturesOnly: Bool = false) -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        let mover = sideToMove

        for index in 0..<64 {
            let packed = squares[index]
            guard packed != 0, let piece = Piece(packed: packed), piece.color == mover else { continue }
            let file = index & 7
            let rank = index >> 3
            let from = Square(index)

            switch piece.kind {
            case .pawn:
                generatePawnMoves(piece: piece, from: from, file: file, rank: rank,
                                  capturesOnly: capturesOnly, into: &moves)

            case .knight:
                for (df, dr) in Board.knightOffsets {
                    let f = file + df, r = rank + dr
                    guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
                    appendStepMove(piece: piece, from: from, toIndex: r * 8 + f,
                                   capturesOnly: capturesOnly, into: &moves)
                }

            case .king:
                for (df, dr) in Board.kingOffsets {
                    let f = file + df, r = rank + dr
                    guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
                    appendStepMove(piece: piece, from: from, toIndex: r * 8 + f,
                                   capturesOnly: capturesOnly, into: &moves)
                }
                if !capturesOnly {
                    generateCastling(piece: piece, into: &moves)
                }

            case .bishop:
                generateSlides(piece: piece, from: from, file: file, rank: rank,
                               directions: Board.bishopDirections, capturesOnly: capturesOnly, into: &moves)
            case .rook:
                generateSlides(piece: piece, from: from, file: file, rank: rank,
                               directions: Board.rookDirections, capturesOnly: capturesOnly, into: &moves)
            case .queen:
                generateSlides(piece: piece, from: from, file: file, rank: rank,
                               directions: Board.bishopDirections + Board.rookDirections,
                               capturesOnly: capturesOnly, into: &moves)
            }
        }
        return moves
    }

    private func appendStepMove(
        piece: Piece, from: Square, toIndex: Int, capturesOnly: Bool, into moves: inout [Move]
    ) {
        let occupant = squares[toIndex]
        if occupant == 0 {
            if !capturesOnly {
                moves.append(Move(from: from, to: Square(toIndex), piece: piece))
            }
        } else if let target = Piece(packed: occupant), target.color != piece.color {
            moves.append(Move(from: from, to: Square(toIndex), piece: piece, captured: target))
        }
    }

    private func generateSlides(
        piece: Piece, from: Square, file: Int, rank: Int,
        directions: [(Int, Int)], capturesOnly: Bool, into moves: inout [Move]
    ) {
        for (df, dr) in directions {
            var f = file + df, r = rank + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let toIndex = r * 8 + f
                let occupant = squares[toIndex]
                if occupant == 0 {
                    if !capturesOnly {
                        moves.append(Move(from: from, to: Square(toIndex), piece: piece))
                    }
                } else {
                    if let target = Piece(packed: occupant), target.color != piece.color {
                        moves.append(Move(from: from, to: Square(toIndex), piece: piece, captured: target))
                    }
                    break
                }
                f += df; r += dr
            }
        }
    }

    private func generatePawnMoves(
        piece: Piece, from: Square, file: Int, rank: Int,
        capturesOnly: Bool, into moves: inout [Move]
    ) {
        let direction = piece.color == .white ? 1 : -1
        let startRank = piece.color == .white ? 1 : 6
        let promotionRank = piece.color == .white ? 7 : 0

        // Captures-only mode is the quiescence search, and there a pawn on the
        // last rank takes the queen and nothing else. The three under-
        // promotions are almost never the point, and offering them multiplies
        // the branching of every such node by four — which is what let a pawn
        // race grow a quiescence tree the whole time budget could not finish.
        // In check the full four are still generated: `capturesOnly` is false
        // there, because an evasion is an evasion whatever it promotes to, and
        // running out of them is how quiescence finds mate.
        //
        // Both lists are static so that picking one costs a retain. Written
        // inline, the literal is a fresh heap allocation on every call — and
        // this runs for every pawn of every node, promoting or not.
        let promotionKinds = capturesOnly ? Board.queenPromotionOnly : Board.allPromotions

        func appendWithPromotions(_ move: Move) {
            if move.to.rank == promotionRank {
                for kind in promotionKinds {
                    var promoted = move
                    promoted.promotion = kind
                    moves.append(promoted)
                }
            } else {
                moves.append(move)
            }
        }

        // Pushes
        let oneAhead = rank + direction
        if (0..<8).contains(oneAhead), squares[oneAhead * 8 + file] == 0 {
            // A push to the last rank is a promotion — always relevant, even
            // in captures-only (quiescence) mode.
            if !capturesOnly || oneAhead == promotionRank {
                appendWithPromotions(Move(from: from, to: Square(file: file, rank: oneAhead), piece: piece))
            }
            if !capturesOnly, rank == startRank {
                let twoAhead = rank + 2 * direction
                if squares[twoAhead * 8 + file] == 0 {
                    moves.append(Move(
                        from: from, to: Square(file: file, rank: twoAhead),
                        piece: piece, isDoublePawnPush: true
                    ))
                }
            }
        }

        // Captures (including en passant)
        for df in [-1, 1] {
            let f = file + df
            guard (0..<8).contains(f), (0..<8).contains(oneAhead) else { continue }
            let toIndex = oneAhead * 8 + f
            let occupant = squares[toIndex]
            if occupant != 0 {
                if let target = Piece(packed: occupant), target.color != piece.color {
                    appendWithPromotions(Move(
                        from: from, to: Square(toIndex), piece: piece, captured: target
                    ))
                }
            } else if toIndex == enPassantSquare {
                moves.append(Move(
                    from: from, to: Square(toIndex), piece: piece,
                    captured: Piece(piece.color.opponent, .pawn), isEnPassant: true
                ))
            }
        }
    }

    /// Castling, for both variants: one rule covers standard chess and
    /// Chess960, standard chess being the arrangement where the king starts
    /// on e1 and the rooks in the corners.
    private func generateCastling(piece: Piece, into moves: inout [Move]) {
        let color = piece.color
        let canKingside = castlingRights.contains(.right(of: color, kingside: true))
        let canQueenside = castlingRights.contains(.right(of: color, kingside: false))
        // Most nodes of a search hold no right at all, and asked first this
        // spares them the attack scan of the king's square below.
        guard canKingside || canQueenside else { return }

        // The king stands on its back rank: on e1 (e8) in standard chess,
        // where a right outlives a king that FEN put elsewhere; in Chess960
        // wherever the start position put it, which the right vouches for —
        // any king move spends both.
        let base = color == .white ? 0 : 56
        let kingFrom = kingSquare(of: color)
        if isChess960 {
            guard kingFrom >> 3 == base >> 3 else { return }
        } else {
            guard kingFrom == base + 4 else { return }
        }

        // The board's own questions — is the rook there, is the way clear —
        // before any attack scan. Through the opening the rights are held but
        // the pieces still stand in between, and asking in this order spares
        // those nodes the scan of the king's square entirely.
        let kingside = canKingside && isClearToCastle(color: color, kingFrom: kingFrom, kingside: true)
        let queenside = canQueenside && isClearToCastle(color: color, kingFrom: kingFrom, kingside: false)
        guard kingside || queenside else { return }

        // Not out of check.
        guard !isSquareAttacked(kingFrom, by: color.opponent) else { return }

        if kingside {
            appendCastleIfSafe(piece: piece, kingFrom: kingFrom, kingside: true, into: &moves)
        }
        if queenside {
            appendCastleIfSafe(piece: piece, kingFrom: kingFrom, kingside: false, into: &moves)
        }
    }

    /// Whether the rook of this castle stands on its wing of the king, with
    /// nothing in the way but the two of them.
    private func isClearToCastle(color: PieceColor, kingFrom: Int, kingside: Bool) -> Bool {
        let castle = castlingGeometry(color: color, kingside: kingside)
        guard squares[castle.rookFrom] == Piece(color, .rook).packed,
              kingside ? castle.rookFrom > kingFrom : castle.rookFrom < kingFrom
        else { return false }

        // Every square the king or the rook crosses, destinations included, is
        // empty but for the two of them. The king's path and the rook's path
        // together always make one unbroken stretch of the rank — from the
        // leftmost of the four squares to the rightmost — so one scan does.
        // Standard kingside that is f1 and g1, queenside b1, c1 and d1.
        let low = min(min(kingFrom, castle.kingTo), min(castle.rookFrom, castle.rookTo))
        let high = max(max(kingFrom, castle.kingTo), max(castle.rookFrom, castle.rookTo))
        for index in low...high where index != kingFrom && index != castle.rookFrom {
            if squares[index] != 0 { return false }
        }
        return true
    }

    /// Appends a castle that `isClearToCastle` has passed, from a king known
    /// not to be in check, unless the king would cross an attacked square.
    private func appendCastleIfSafe(piece: Piece, kingFrom: Int, kingside: Bool, into moves: inout [Move]) {
        let color = piece.color
        let castle = castlingGeometry(color: color, kingside: kingside)

        // No square the king passes through or lands on is attacked. (Its own
        // square was cleared before this; a king already on g1 or c1 passes
        // through nothing.) Asked of the board as it stands, with the rook
        // still at home.
        //
        // In standard chess that settles it. In Chess960 it can miss one
        // thing: the castling rook may be what shields the king's destination.
        // King d1 and rook b1 castling long, a black queen on a1 — c1 is safe
        // while the rook stands on b1, but the rook leaves for d1 and the
        // queen sees c1. The king-safety filter every pseudo-legal move passes
        // after `make` asks the board as it will be, and refuses that castle;
        // python-chess asks the same question in the same place. The opposite
        // mistake cannot happen: the only piece the castle puts down beside
        // the king's destination is its rook, and an attack along the rank
        // that the rook would block has to cross the king's own square on the
        // way — where the king either blocks it already or is in check from
        // it.
        let opponent = color.opponent
        if kingFrom != castle.kingTo {
            let step = castle.kingTo > kingFrom ? 1 : -1
            var index = kingFrom
            repeat {
                index += step
                guard !isSquareAttacked(index, by: opponent) else { return }
            } while index != castle.kingTo
        }

        moves.append(Move(
            from: Square(kingFrom),
            to: Square(isChess960 ? castle.rookFrom : castle.kingTo),
            piece: piece,
            isCastleKingside: kingside,
            isCastleQueenside: !kingside
        ))
    }

    // MARK: Legal generation

    /// All strictly legal moves for the side to move.
    func generateLegalMoves(capturesOnly: Bool = false) -> [Move] {
        var board = self
        return generatePseudoLegalMoves(capturesOnly: capturesOnly).filter { move in
            board.isLegal(move)
        }
    }

    /// Whether a pseudo-legal move leaves the own king safe. Mutating variant
    /// used internally (make/unmake); the board ends up unchanged.
    private mutating func isLegal(_ move: Move) -> Bool {
        let mover = sideToMove
        let undo = make(move)
        let safe = !isSquareAttacked(kingSquare(of: mover), by: mover.opponent)
        unmake(move, undo: undo)
        return safe
    }

    /// Legal moves originating from one square (for the UI).
    func legalMoves(from square: Square) -> [Move] {
        generateLegalMoves().filter { $0.from == square }
    }
}
