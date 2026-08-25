//
//  ReviewBoardView.swift
//  chess
//
//  A read-only board for the game review: the position, the move that was
//  played, an arrow showing what the engine preferred, and a badge grading
//  the move.
//

import SwiftUI

// MARK: - Geometry

/// Maps squares to points for a board of a given size. Shared by the boards
/// that only draw a position.
struct BoardGeometry {
    let size: CGFloat
    let frameWidth: CGFloat
    let squareSize: CGFloat
    let orientation: PieceColor

    init(size: CGFloat, orientation: PieceColor) {
        self.size = size
        self.frameWidth = size * 0.040
        self.squareSize = (size - frameWidth * 2) / 8
        self.orientation = orientation
    }

    var origin: CGPoint { CGPoint(x: frameWidth, y: frameWidth) }

    func cell(_ square: Square) -> (col: Int, row: Int) {
        (
            orientation == .white ? square.file : 7 - square.file,
            orientation == .white ? 7 - square.rank : square.rank
        )
    }

    func center(of square: Square) -> CGPoint {
        let cell = self.cell(square)
        return CGPoint(
            x: origin.x + (CGFloat(cell.col) + 0.5) * squareSize,
            y: origin.y + (CGFloat(cell.row) + 0.5) * squareSize
        )
    }

    /// The inverse: which square a point lands on, or nil for the frame around
    /// the board. Every board that takes touch needs this, so it lives with
    /// the rest of the mapping rather than being written out per view.
    func square(at location: CGPoint) -> Square? {
        let col = Int(floor((location.x - origin.x) / squareSize))
        let row = Int(floor((location.y - origin.y) / squareSize))
        guard (0..<8).contains(col), (0..<8).contains(row) else { return nil }
        return Square(
            file: orientation == .white ? col : 7 - col,
            rank: orientation == .white ? 7 - row : row
        )
    }
}

// MARK: - Backdrop

/// Everything under the pieces: the wooden frame, the coordinates around it
/// and the checkered squares. Shared by the boards that only draw a position.
struct BoardBackdrop: View {
    let geometry: BoardGeometry
    let theme: BoardTheme
    let showCoordinates: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: geometry.size * 0.02, style: .continuous)
                .fill(theme.frame)
                .overlay(
                    RoundedRectangle(cornerRadius: geometry.size * 0.02, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.18), .black.opacity(0.25)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)

            squares
                .offset(x: geometry.origin.x, y: geometry.origin.y)

            if showCoordinates {
                coordinates
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var squares: some View {
        Canvas { context, _ in
            for row in 0..<8 {
                for col in 0..<8 {
                    let rect = CGRect(
                        x: CGFloat(col) * geometry.squareSize,
                        y: CGFloat(row) * geometry.squareSize,
                        width: geometry.squareSize, height: geometry.squareSize
                    )
                    let isLight = (row + col) % 2 == 0
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? theme.lightSquare : theme.darkSquare)
                    )
                }
            }
        }
        .frame(width: geometry.squareSize * 8, height: geometry.squareSize * 8)
    }

    private var coordinates: some View {
        let files = geometry.orientation == .white ? Array("abcdefgh") : Array("hgfedcba")
        let fontSize = max(7, geometry.frameWidth * 0.62)
        return ZStack {
            ForEach(0..<8, id: \.self) { index in
                let rank = geometry.orientation == .white ? "\(8 - index)" : "\(index + 1)"
                Text(rank)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.frameText)
                    .position(
                        x: geometry.frameWidth / 2,
                        y: geometry.frameWidth + (CGFloat(index) + 0.5) * geometry.squareSize
                    )
                Text(String(files[index]))
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.frameText)
                    .position(
                        x: geometry.frameWidth + (CGFloat(index) + 0.5) * geometry.squareSize,
                        y: geometry.frameWidth * 1.5 + geometry.squareSize * 8
                    )
            }
        }
    }
}

// MARK: - Board

struct ReviewBoardView: View {
    let model: GameReviewModel
    let theme: BoardTheme
    let showCoordinates: Bool

    private var playedMove: Move? { model.currentMove?.move }
    private var analysis: MoveAnalysis? { model.currentAnalysis }

    /// The engine's preferred move, shown only when it differs from the move
    /// that was actually played.
    private var suggestion: Move? {
        guard let analysis, !analysis.isBestMove else { return nil }
        return analysis.bestMove
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = BoardGeometry(size: side, orientation: model.orientation)

            ZStack(alignment: .topLeading) {
                BoardBackdrop(geometry: geometry, theme: theme, showCoordinates: showCoordinates)
                highlights(geometry)
                pieces(geometry)
                arrows(geometry)
                badge(geometry)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(swipe)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Position", comment: "VoiceOver name for the review board"))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Swiping the board steps through the game.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                if value.translation.width < -30 {
                    model.stepForward()
                } else if value.translation.width > 30 {
                    model.stepBackward()
                }
            }
    }

    // MARK: Layers

    @ViewBuilder
    private func highlights(_ geometry: BoardGeometry) -> some View {
        if let played = playedMove {
            let tint = analysis?.quality.tint ?? theme.accent
            ForEach([played.from, played.to], id: \.index) { square in
                RoundedRectangle(cornerRadius: geometry.squareSize * 0.12, style: .continuous)
                    .fill(tint.opacity(0.38))
                    .frame(width: geometry.squareSize, height: geometry.squareSize)
                    .position(geometry.center(of: square))
                    .allowsHitTesting(false)
            }
        }

        if let checked = model.checkedKingSquare {
            RadialGradient(
                colors: [Color.red.opacity(0.7), Color.red.opacity(0)],
                center: .center, startRadius: 0, endRadius: geometry.squareSize * 0.75
            )
            .frame(width: geometry.squareSize * 1.5, height: geometry.squareSize * 1.5)
            .position(geometry.center(of: checked))
            .allowsHitTesting(false)
        }
    }

    private func pieces(_ geometry: BoardGeometry) -> some View {
        ForEach(model.pieces) { rendered in
            PieceView(piece: rendered.piece)
                .frame(width: geometry.squareSize, height: geometry.squareSize)
                .position(geometry.center(of: rendered.square))
                .allowsHitTesting(false)
                // Sweeping the board reads out the position, piece by piece.
                .accessibilityElement()
                .accessibilityLabel(BoardSpeech.label(square: rendered.square, piece: rendered.piece))
        }
    }

    @ViewBuilder
    private func arrows(_ geometry: BoardGeometry) -> some View {
        if let suggestion {
            MoveArrow(from: geometry.center(of: suggestion.from),
                      to: geometry.center(of: suggestion.to),
                      squareSize: geometry.squareSize)
                .fill(MoveQuality.best.tint.opacity(0.85))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .frame(width: geometry.size, height: geometry.size)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// The grade for the move that was just played, pinned to its destination.
    @ViewBuilder
    private func badge(_ geometry: BoardGeometry) -> some View {
        if let analysis, let played = playedMove {
            let size = geometry.squareSize * 0.42
            let center = geometry.center(of: played.to)
            let inner = geometry.origin.x + geometry.squareSize * 8
            QualityBadge(quality: analysis.quality, size: size)
                // Kept inside the board, so a badge on the far rank or file
                // does not spill onto the frame.
                .position(
                    x: min(center.x + geometry.squareSize * 0.38, inner - size / 2),
                    y: max(center.y - geometry.squareSize * 0.38, geometry.origin.y + size / 2)
                )
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Arrow

/// A chess-style move arrow: a shaft from square to square with a wide head.
struct MoveArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    let squareSize: CGFloat

    func path(in rect: CGRect) -> Path {
        let vector = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let length = hypot(vector.x, vector.y)
        guard length > 1 else { return Path() }

        let direction = CGPoint(x: vector.x / length, y: vector.y / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)

        // Start just outside the origin square so the piece stays visible.
        let tailInset = squareSize * 0.30
        let headLength = squareSize * 0.44
        let headWidth = squareSize * 0.46
        let shaftWidth = squareSize * 0.17

        let start = CGPoint(x: from.x + direction.x * tailInset, y: from.y + direction.y * tailInset)
        let tip = CGPoint(x: to.x - direction.x * squareSize * 0.10,
                          y: to.y - direction.y * squareSize * 0.10)
        let neck = CGPoint(x: tip.x - direction.x * headLength, y: tip.y - direction.y * headLength)

        func offset(_ point: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.x * amount, y: point.y + normal.y * amount)
        }

        var path = Path()
        path.move(to: offset(start, shaftWidth / 2))
        path.addLine(to: offset(neck, shaftWidth / 2))
        path.addLine(to: offset(neck, headWidth / 2))
        path.addLine(to: tip)
        path.addLine(to: offset(neck, -headWidth / 2))
        path.addLine(to: offset(neck, -shaftWidth / 2))
        path.addLine(to: offset(start, -shaftWidth / 2))
        path.closeSubpath()
        return path
    }
}

// MARK: - Badge

/// The little coloured disc that grades a move.
struct QualityBadge: View {
    let quality: MoveQuality
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(quality.tint)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: max(0.8, size * 0.05)))
                .shadow(color: .black.opacity(0.4), radius: size * 0.12, y: size * 0.06)

            if let symbol = quality.badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(quality.badgeForeground)
            } else {
                Text(quality.badgeText)
                    .font(.system(size: size * 0.58, weight: .heavy, design: .rounded))
                    .foregroundStyle(quality.badgeForeground)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quality.label)
    }
}
