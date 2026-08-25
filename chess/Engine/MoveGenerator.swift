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
    /// only when fully legal (king not in check, path safe). Other moves may
    /// still leave the own king in check and must be filtered.
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

        func appendWithPromotions(_ move: Move) {
            if move.to.rank == promotionRank {
                for kind in [PieceKind.queen, .rook, .bishop, .knight] {
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

    private func generateCastling(piece: Piece, into moves: inout [Move]) {
        let color = piece.color
        let opponent = color.opponent
        let base = color == .white ? 0 : 56
        let kingIndex = base + 4

        // King must be on its home square and not in check.
        guard kingSquare(of: color) == kingIndex,
              !isSquareAttacked(kingIndex, by: opponent) else { return }

        let kingside: CastlingRights = color == .white ? .whiteKingside : .blackKingside
        let queenside: CastlingRights = color == .white ? .whiteQueenside : .blackQueenside

        if castlingRights.contains(kingside),
           squares[base + 5] == 0, squares[base + 6] == 0,
           squares[base + 7] == Piece(color, .rook).packed,
           !isSquareAttacked(base + 5, by: opponent),
           !isSquareAttacked(base + 6, by: opponent) {
            moves.append(Move(
                from: Square(kingIndex), to: Square(base + 6), piece: piece, isCastleKingside: true
            ))
        }

        if castlingRights.contains(queenside),
           squares[base + 3] == 0, squares[base + 2] == 0, squares[base + 1] == 0,
           squares[base + 0] == Piece(color, .rook).packed,
           !isSquareAttacked(base + 3, by: opponent),
           !isSquareAttacked(base + 2, by: opponent) {
            moves.append(Move(
                from: Square(kingIndex), to: Square(base + 2), piece: piece, isCastleQueenside: true
            ))
        }
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
