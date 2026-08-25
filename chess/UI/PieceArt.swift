//
//  PieceArt.swift
//  chess
//
//  Piece artwork: the standard Staunton vector set drawn by Cburnett for
//  Wikimedia Commons — the same pieces Wikipedia and lichess render. The author
//  offers the files under a choice of four licences; they are used here under
//  the BSD one. See Credits in the settings screen.
//
//  https://commons.wikimedia.org/wiki/Category:SVG_chess_pieces
//
//  The SVGs were flattened offline: inherited styles resolved, transforms
//  baked into the geometry and arcs converted to cubics, which leaves path
//  data using only absolute M / L / C / Z in the original 45×45 design box.
//

import SwiftUI

enum PieceArt {

    /// Side of the box the artwork is drawn in.
    static let designSize: CGFloat = 45

    /// A layer is painted in one of the two piece colours, or not at all.
    enum Ink {
        case none, light, dark
    }

    /// One drawing operation from the source SVG: fill, then stroke.
    struct Layer {
        let path: Path
        let fill: Ink
        let stroke: Ink
        let width: CGFloat
        let cap: CGLineCap
        let join: CGLineJoin
        let evenOdd: Bool

        init(_ data: String, fill: Ink, stroke: Ink, width: CGFloat,
             cap: CGLineCap, join: CGLineJoin, evenOdd: Bool) {
            self.path = Path(flattenedSVG: data)
            self.fill = fill
            self.stroke = stroke
            self.width = width
            self.cap = cap
            self.join = join
            self.evenOdd = evenOdd
        }
    }

    static func layers(for piece: Piece) -> [Layer] {
        switch (piece.color, piece.kind) {
        case (.white, .pawn): return whitePawn
        case (.white, .knight): return whiteKnight
        case (.white, .bishop): return whiteBishop
        case (.white, .rook): return whiteRook
        case (.white, .queen): return whiteQueen
        case (.white, .king): return whiteKing
        case (.black, .pawn): return blackPawn
        case (.black, .knight): return blackKnight
        case (.black, .bishop): return blackBishop
        case (.black, .rook): return blackRook
        case (.black, .queen): return blackQueen
        case (.black, .king): return blackKing
        }
    }

    /// Combined filled outline of a piece, for decorative use.
    static func silhouette(_ kind: PieceKind) -> Path {
        var path = Path()
        for layer in layers(for: Piece(.white, kind)) where layer.fill != .none {
            path.addPath(layer.path)
        }
        return path
    }

    // MARK: - Artwork

    private static let whitePawn: [Layer] = [
        Layer(
            "M 22.5 9 C 20.29 9 18.5 10.79 18.5 13 C 18.5 13.89 18.79 14.71 19.28 15.38 C 17.33 16.5 16 18.59 16 21 C 16 23.03 16.94 24.84 18.41 26.03 C 15.41 27.09 11 31.58 11 39.5 L 34 39.5 C 34 31.58 29.59 27.09 26.59 26.03 C 28.06 24.84 29 23.03 29 21 C 29 18.59 27.67 16.5 25.72 15.38 C 26.21 14.71 26.5 13.89 26.5 13 C 26.5 10.79 24.71 9 22.5 9 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: false
        ),
    ]

    private static let whiteKnight: [Layer] = [
        Layer(
            "M 22 10.3 C 32.5 11.3 38.5 18.3 38 39.3 L 15 39.3 C 15 30.3 25 32.8 23 18.3",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 24 18.3 C 24.38 21.21 18.45 25.67 16 27.3 C 13 29.3 13.18 31.64 11 31.3 C 9.958 30.36 12.41 28.26 11 28.3 C 10 28.3 11.19 29.53 10 30.3 C 9 30.3 5.997 31.3 6 26.3 C 6 24.3 12 14.3 12 14.3 C 12 14.3 13.89 12.4 14 10.8 C 13.27 9.806 13.5 8.8 13.5 7.8 C 14.5 6.8 16.5 10.3 16.5 10.3 L 18.5 10.3 C 18.5 10.3 19.28 8.308 21 7.3 C 22 7.3 22 10.3 22 10.3",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 9.5 25.8 C 9.5 25.888 9.477 25.974 9.433 26.05 C 9.389 26.126 9.326 26.189 9.25 26.233 C 9.174 26.277 9.088 26.3 9 26.3 C 8.912 26.3 8.826 26.277 8.75 26.233 C 8.674 26.189 8.611 26.126 8.567 26.05 C 8.523 25.974 8.5 25.888 8.5 25.8 C 8.5 25.712 8.523 25.626 8.567 25.55 C 8.611 25.474 8.674 25.411 8.75 25.367 C 8.826 25.323 8.912 25.3 9 25.3 C 9.088 25.3 9.174 25.323 9.25 25.367 C 9.326 25.411 9.389 25.474 9.433 25.55 C 9.477 25.626 9.5 25.712 9.5 25.8 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 14.933 16.05 C 14.801 16.278 14.652 16.49 14.5 16.666 C 14.348 16.842 14.199 16.974 14.067 17.05 C 13.935 17.126 13.826 17.143 13.75 17.099 C 13.674 17.055 13.634 16.952 13.634 16.8 C 13.634 16.648 13.674 16.452 13.75 16.233 C 13.826 16.014 13.935 15.778 14.067 15.55 C 14.199 15.322 14.348 15.11 14.5 14.934 C 14.652 14.758 14.801 14.626 14.933 14.55 C 15.065 14.474 15.174 14.457 15.25 14.501 C 15.326 14.545 15.366 14.648 15.366 14.8 C 15.366 14.952 15.326 15.148 15.25 15.367 C 15.174 15.586 15.065 15.822 14.933 16.05 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
    ]

    private static let whiteBishop: [Layer] = [
        Layer(
            "M 9 36.6 C 12.39 35.63 19.11 37.03 22.5 34.6 C 25.89 37.03 32.61 35.63 36 36.6 C 36 36.6 37.65 37.14 39 38.6 C 38.32 39.57 37.35 39.59 36 39.1 C 32.61 38.13 25.89 39.56 22.5 38.1 C 19.11 39.56 12.39 38.13 9 39.1 C 7.65 39.59 6.68 39.57 6 38.6 C 7.35 37.14 9 36.6 9 36.6 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 15 32.6 C 17.5 35.1 27.5 35.1 30 32.6 C 30.5 31.1 30 30.6 30 30.6 C 30 28.1 27.5 26.6 27.5 26.6 C 33 25.1 33.5 15.1 22.5 11.1 C 11.5 15.1 12 25.1 17.5 26.6 C 17.5 26.6 15 28.1 15 30.6 C 15 30.6 14.5 31.1 15 32.6 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 25 8.6 C 25 9.039 24.884 9.47 24.665 9.85 C 24.446 10.23 24.13 10.546 23.75 10.765 C 23.37 10.984 22.939 11.1 22.5 11.1 C 22.061 11.1 21.63 10.984 21.25 10.765 C 20.87 10.546 20.554 10.23 20.335 9.85 C 20.116 9.47 20 9.039 20 8.6 C 20 8.161 20.116 7.73 20.335 7.35 C 20.554 6.97 20.87 6.654 21.25 6.435 C 21.63 6.216 22.061 6.1 22.5 6.1 C 22.939 6.1 23.37 6.216 23.75 6.435 C 24.13 6.654 24.446 6.97 24.665 7.35 C 24.884 7.73 25 8.161 25 8.6 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 17.5 26.6 L 27.5 26.6 M 15 30.6 L 30 30.6 M 22.5 16.1 L 22.5 21.1 M 20 18.6 L 25 18.6",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
    ]

    private static let whiteRook: [Layer] = [
        Layer(
            "M 9 39.3 L 36 39.3 L 36 36.3 L 9 36.3 L 9 39.3 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 12 36.3 L 12 32.3 L 33 32.3 L 33 36.3 L 12 36.3 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 11 14.3 L 11 9.3 L 15 9.3 L 15 11.3 L 20 11.3 L 20 9.3 L 25 9.3 L 25 11.3 L 30 11.3 L 30 9.3 L 34 9.3 L 34 14.3",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 34 14.3 L 31 17.3 L 14 17.3 L 11 14.3",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 31 17.3 L 31 29.8 L 14 29.8 L 14 17.3",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .miter, evenOdd: true
        ),
        Layer(
            "M 31 29.8 L 32.5 32.3 L 12.5 32.3 L 14 29.8",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 11 14.3 L 34 14.3",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
    ]

    private static let whiteQueen: [Layer] = [
        Layer(
            "M 9 26 C 17.5 24.5 30 24.5 36 26 L 38.5 13.5 L 31 25 L 30.7 10.9 L 25.5 24.5 L 22.5 10 L 19.5 24.5 L 14.3 10.9 L 14 25 L 6.5 13.5 L 9 26 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 9 26 C 9 28 10.5 28 11.5 30 C 12.5 31.5 12.5 31 12 33.5 C 10.5 34.5 11 36 11 36 C 9.5 37.5 11 38.5 11 38.5 C 17.5 39.5 27.5 39.5 34 38.5 C 34 38.5 35.5 37.5 34 36 C 34 36 34.5 34.5 33 33.5 C 32.5 31 32.5 31.5 33.5 30 C 34.5 28 36 28 36 26 C 27.5 24.5 17.5 24.5 9 26 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 11.5 30 C 15 29 30 29 33.5 30",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 12 33.5 C 18 32.5 27 32.5 33 33.5",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 8 12 C 8 12.351 7.908 12.696 7.732 13 C 7.557 13.304 7.304 13.557 7 13.732 C 6.696 13.908 6.351 14 6 14 C 5.649 14 5.304 13.908 5 13.732 C 4.696 13.557 4.443 13.304 4.268 13 C 4.092 12.696 4 12.351 4 12 C 4 11.649 4.092 11.304 4.268 11 C 4.443 10.696 4.696 10.443 5 10.268 C 5.304 10.092 5.649 10 6 10 C 6.351 10 6.696 10.092 7 10.268 C 7.304 10.443 7.557 10.696 7.732 11 C 7.908 11.304 8 11.649 8 12 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 16 9 C 16 9.351 15.908 9.696 15.732 10 C 15.557 10.304 15.304 10.557 15 10.732 C 14.696 10.908 14.351 11 14 11 C 13.649 11 13.304 10.908 13 10.732 C 12.696 10.557 12.443 10.304 12.268 10 C 12.092 9.696 12 9.351 12 9 C 12 8.649 12.092 8.304 12.268 8 C 12.443 7.696 12.696 7.443 13 7.268 C 13.304 7.092 13.649 7 14 7 C 14.351 7 14.696 7.092 15 7.268 C 15.304 7.443 15.557 7.696 15.732 8 C 15.908 8.304 16 8.649 16 9 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 24.5 8 C 24.5 8.351 24.408 8.696 24.232 9 C 24.057 9.304 23.804 9.557 23.5 9.732 C 23.196 9.908 22.851 10 22.5 10 C 22.149 10 21.804 9.908 21.5 9.732 C 21.196 9.557 20.943 9.304 20.768 9 C 20.592 8.696 20.5 8.351 20.5 8 C 20.5 7.649 20.592 7.304 20.768 7 C 20.943 6.696 21.196 6.443 21.5 6.268 C 21.804 6.092 22.149 6 22.5 6 C 22.851 6 23.196 6.092 23.5 6.268 C 23.804 6.443 24.057 6.696 24.232 7 C 24.408 7.304 24.5 7.649 24.5 8 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 33 9 C 33 9.351 32.908 9.696 32.732 10 C 32.557 10.304 32.304 10.557 32 10.732 C 31.696 10.908 31.351 11 31 11 C 30.649 11 30.304 10.908 30 10.732 C 29.696 10.557 29.443 10.304 29.268 10 C 29.092 9.696 29 9.351 29 9 C 29 8.649 29.092 8.304 29.268 8 C 29.443 7.696 29.696 7.443 30 7.268 C 30.304 7.092 30.649 7 31 7 C 31.351 7 31.696 7.092 32 7.268 C 32.304 7.443 32.557 7.696 32.732 8 C 32.908 8.304 33 8.649 33 9 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 41 12 C 41 12.351 40.908 12.696 40.732 13 C 40.557 13.304 40.304 13.557 40 13.732 C 39.696 13.908 39.351 14 39 14 C 38.649 14 38.304 13.908 38 13.732 C 37.696 13.557 37.443 13.304 37.268 13 C 37.092 12.696 37 12.351 37 12 C 37 11.649 37.092 11.304 37.268 11 C 37.443 10.696 37.696 10.443 38 10.268 C 38.304 10.092 38.649 10 39 10 C 39.351 10 39.696 10.092 40 10.268 C 40.304 10.443 40.557 10.696 40.732 11 C 40.908 11.304 41 11.649 41 12 Z",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
    ]

    private static let whiteKing: [Layer] = [
        Layer(
            "M 22.5 11.63 L 22.5 6 M 20 8 L 25 8",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 22.5 25 C 22.5 25 27 17.5 25.5 14.5 C 25.5 14.5 24.5 12 22.5 12 C 20.5 12 19.5 14.5 19.5 14.5 C 18 17.5 22.5 25 22.5 25",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .butt, join: .miter, evenOdd: true
        ),
        Layer(
            "M 12.5 37 C 18 40.5 27 40.5 32.5 37 L 32.5 30 C 32.5 30 41.5 25.5 38.5 19.5 C 34.5 13 25 16 22.5 23.5 L 22.5 27 L 22.5 23.5 C 20 16 10.5 13 6.5 19.5 C 3.5 25.5 12.5 30 12.5 30 L 12.5 37",
            fill: .light, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 12.5 30 C 18 27 27 27 32.5 30 M 12.5 33.5 C 18 30.5 27 30.5 32.5 33.5 M 12.5 37 C 18 34 27 34 32.5 37",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
    ]

    private static let blackPawn: [Layer] = [
        Layer(
            "M 22.5 9 C 20.29 9 18.5 10.79 18.5 13 C 18.5 13.89 18.79 14.71 19.28 15.38 C 17.33 16.5 16 18.59 16 21 C 16 23.03 16.94 24.84 18.41 26.03 C 15.41 27.09 11 31.58 11 39.5 L 34 39.5 C 34 31.58 29.59 27.09 26.59 26.03 C 28.06 24.84 29 23.03 29 21 C 29 18.59 27.67 16.5 25.72 15.38 C 26.21 14.71 26.5 13.89 26.5 13 C 26.5 10.79 24.71 9 22.5 9 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: false
        ),
    ]

    private static let blackKnight: [Layer] = [
        Layer(
            "M 22 10.3 C 32.5 11.3 38.5 18.3 38 39.3 L 15 39.3 C 15 30.3 25 32.8 23 18.3",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 24 18.3 C 24.38 21.21 18.45 25.67 16 27.3 C 13 29.3 13.18 31.64 11 31.3 C 9.958 30.36 12.41 28.26 11 28.3 C 10 28.3 11.19 29.53 10 30.3 C 9 30.3 5.997 31.3 6 26.3 C 6 24.3 12 14.3 12 14.3 C 12 14.3 13.89 12.4 14 10.8 C 13.27 9.806 13.5 8.8 13.5 7.8 C 14.5 6.8 16.5 10.3 16.5 10.3 L 18.5 10.3 C 18.5 10.3 19.28 8.308 21 7.3 C 22 7.3 22 10.3 22 10.3",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 9.5 25.8 C 9.5 25.888 9.477 25.974 9.433 26.05 C 9.389 26.126 9.326 26.189 9.25 26.233 C 9.174 26.277 9.088 26.3 9 26.3 C 8.912 26.3 8.826 26.277 8.75 26.233 C 8.674 26.189 8.611 26.126 8.567 26.05 C 8.523 25.974 8.5 25.888 8.5 25.8 C 8.5 25.712 8.523 25.626 8.567 25.55 C 8.611 25.474 8.674 25.411 8.75 25.367 C 8.826 25.323 8.912 25.3 9 25.3 C 9.088 25.3 9.174 25.323 9.25 25.367 C 9.326 25.411 9.389 25.474 9.433 25.55 C 9.477 25.626 9.5 25.712 9.5 25.8 Z",
            fill: .light, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 14.933 16.05 C 14.801 16.278 14.652 16.49 14.5 16.666 C 14.348 16.842 14.199 16.974 14.067 17.05 C 13.935 17.126 13.826 17.143 13.75 17.099 C 13.674 17.055 13.634 16.952 13.634 16.8 C 13.634 16.648 13.674 16.452 13.75 16.233 C 13.826 16.014 13.935 15.778 14.067 15.55 C 14.199 15.322 14.348 15.11 14.5 14.934 C 14.652 14.758 14.801 14.626 14.933 14.55 C 15.065 14.474 15.174 14.457 15.25 14.501 C 15.326 14.545 15.366 14.648 15.366 14.8 C 15.366 14.952 15.326 15.148 15.25 15.367 C 15.174 15.586 15.065 15.822 14.933 16.05 Z",
            fill: .light, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 24.55 10.7 L 24.1 12.15 L 24.6 12.3 C 27.75 13.3 30.25 14.79 32.5 19.05 C 34.75 23.31 35.75 29.36 35.25 39.3 L 35.2 39.8 L 37.45 39.8 L 37.5 39.3 C 38 29.24 36.62 22.45 34.25 17.96 C 31.88 13.47 28.46 11.32 25.06 10.8 L 24.55 10.7 Z",
            fill: .light, stroke: .none, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
    ]

    private static let blackBishop: [Layer] = [
        Layer(
            "M 9 36.6 C 12.39 35.63 19.11 37.03 22.5 34.6 C 25.89 37.03 32.61 35.63 36 36.6 C 36 36.6 37.65 37.14 39 38.6 C 38.32 39.57 37.35 39.59 36 39.1 C 32.61 38.13 25.89 39.56 22.5 38.1 C 19.11 39.56 12.39 38.13 9 39.1 C 7.65 39.59 6.68 39.57 6 38.6 C 7.35 37.14 9 36.6 9 36.6 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 15 32.6 C 17.5 35.1 27.5 35.1 30 32.6 C 30.5 31.1 30 30.6 30 30.6 C 30 28.1 27.5 26.6 27.5 26.6 C 33 25.1 33.5 15.1 22.5 11.1 C 11.5 15.1 12 25.1 17.5 26.6 C 17.5 26.6 15 28.1 15 30.6 C 15 30.6 14.5 31.1 15 32.6 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 25 8.6 C 25 9.039 24.884 9.47 24.665 9.85 C 24.446 10.23 24.13 10.546 23.75 10.765 C 23.37 10.984 22.939 11.1 22.5 11.1 C 22.061 11.1 21.63 10.984 21.25 10.765 C 20.87 10.546 20.554 10.23 20.335 9.85 C 20.116 9.47 20 9.039 20 8.6 C 20 8.161 20.116 7.73 20.335 7.35 C 20.554 6.97 20.87 6.654 21.25 6.435 C 21.63 6.216 22.061 6.1 22.5 6.1 C 22.939 6.1 23.37 6.216 23.75 6.435 C 24.13 6.654 24.446 6.97 24.665 7.35 C 24.884 7.73 25 8.161 25 8.6 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 17.5 26.6 L 27.5 26.6 M 15 30.6 L 30 30.6 M 22.5 16.1 L 22.5 21.1 M 20 18.6 L 25 18.6",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
    ]

    private static let blackRook: [Layer] = [
        Layer(
            "M 9 39.3 L 36 39.3 L 36 36.3 L 9 36.3 L 9 39.3 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 12.5 32.3 L 14 29.8 L 31 29.8 L 32.5 32.3 L 12.5 32.3 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 12 36.3 L 12 32.3 L 33 32.3 L 33 36.3 L 12 36.3 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 14 29.8 L 14 16.8 L 31 16.8 L 31 29.8 L 14 29.8 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .miter, evenOdd: true
        ),
        Layer(
            "M 14 16.8 L 11 14.3 L 34 14.3 L 31 16.8 L 14 16.8 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 11 14.3 L 11 9.3 L 15 9.3 L 15 11.3 L 20 11.3 L 20 9.3 L 25 9.3 L 25 11.3 L 30 11.3 L 30 9.3 L 34 9.3 L 34 14.3 L 11 14.3 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: true
        ),
        Layer(
            "M 12 35.8 L 33 35.8 L 33 35.8",
            fill: .none, stroke: .light, width: 1,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 13 31.8 L 32 31.8",
            fill: .none, stroke: .light, width: 1,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 14 29.8 L 31 29.8",
            fill: .none, stroke: .light, width: 1,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 14 16.8 L 31 16.8",
            fill: .none, stroke: .light, width: 1,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 11 14.3 L 34 14.3",
            fill: .none, stroke: .light, width: 1,
            cap: .round, join: .miter, evenOdd: true
        ),
    ]

    private static let blackQueen: [Layer] = [
        Layer(
            "M 9 26 C 17.5 24.5 30 24.5 36 26 L 38.5 13.5 L 31 25 L 30.7 10.9 L 25.5 24.5 L 22.5 10 L 19.5 24.5 L 14.3 10.9 L 14 25 L 6.5 13.5 L 9 26 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 9 26 C 9 28 10.5 28 11.5 30 C 12.5 31.5 12.5 31 12 33.5 C 10.5 34.5 11 36 11 36 C 9.5 37.5 11 38.5 11 38.5 C 17.5 39.5 27.5 39.5 34 38.5 C 34 38.5 35.5 37.5 34 36 C 34 36 34.5 34.5 33 33.5 C 32.5 31 32.5 31.5 33.5 30 C 34.5 28 36 28 36 26 C 27.5 24.5 17.5 24.5 9 26 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 11.5 30 C 15 29 30 29 33.5 30",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 12 33.5 C 18 32.5 27 32.5 33 33.5",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 8 12 C 8 12.351 7.908 12.696 7.732 13 C 7.557 13.304 7.304 13.557 7 13.732 C 6.696 13.908 6.351 14 6 14 C 5.649 14 5.304 13.908 5 13.732 C 4.696 13.557 4.443 13.304 4.268 13 C 4.092 12.696 4 12.351 4 12 C 4 11.649 4.092 11.304 4.268 11 C 4.443 10.696 4.696 10.443 5 10.268 C 5.304 10.092 5.649 10 6 10 C 6.351 10 6.696 10.092 7 10.268 C 7.304 10.443 7.557 10.696 7.732 11 C 7.908 11.304 8 11.649 8 12 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 16 9 C 16 9.351 15.908 9.696 15.732 10 C 15.557 10.304 15.304 10.557 15 10.732 C 14.696 10.908 14.351 11 14 11 C 13.649 11 13.304 10.908 13 10.732 C 12.696 10.557 12.443 10.304 12.268 10 C 12.092 9.696 12 9.351 12 9 C 12 8.649 12.092 8.304 12.268 8 C 12.443 7.696 12.696 7.443 13 7.268 C 13.304 7.092 13.649 7 14 7 C 14.351 7 14.696 7.092 15 7.268 C 15.304 7.443 15.557 7.696 15.732 8 C 15.908 8.304 16 8.649 16 9 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 24.5 8 C 24.5 8.351 24.408 8.696 24.232 9 C 24.057 9.304 23.804 9.557 23.5 9.732 C 23.196 9.908 22.851 10 22.5 10 C 22.149 10 21.804 9.908 21.5 9.732 C 21.196 9.557 20.943 9.304 20.768 9 C 20.592 8.696 20.5 8.351 20.5 8 C 20.5 7.649 20.592 7.304 20.768 7 C 20.943 6.696 21.196 6.443 21.5 6.268 C 21.804 6.092 22.149 6 22.5 6 C 22.851 6 23.196 6.092 23.5 6.268 C 23.804 6.443 24.057 6.696 24.232 7 C 24.408 7.304 24.5 7.649 24.5 8 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 33 9 C 33 9.351 32.908 9.696 32.732 10 C 32.557 10.304 32.304 10.557 32 10.732 C 31.696 10.908 31.351 11 31 11 C 30.649 11 30.304 10.908 30 10.732 C 29.696 10.557 29.443 10.304 29.268 10 C 29.092 9.696 29 9.351 29 9 C 29 8.649 29.092 8.304 29.268 8 C 29.443 7.696 29.696 7.443 30 7.268 C 30.304 7.092 30.649 7 31 7 C 31.351 7 31.696 7.092 32 7.268 C 32.304 7.443 32.557 7.696 32.732 8 C 32.908 8.304 33 8.649 33 9 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 41 12 C 41 12.351 40.908 12.696 40.732 13 C 40.557 13.304 40.304 13.557 40 13.732 C 39.696 13.908 39.351 14 39 14 C 38.649 14 38.304 13.908 38 13.732 C 37.696 13.557 37.443 13.304 37.268 13 C 37.092 12.696 37 12.351 37 12 C 37 11.649 37.092 11.304 37.268 11 C 37.443 10.696 37.696 10.443 38 10.268 C 38.304 10.092 38.649 10 39 10 C 39.351 10 39.696 10.092 40 10.268 C 40.304 10.443 40.557 10.696 40.732 11 C 40.908 11.304 41 11.649 41 12 Z",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 11 38.5 C 14.698 39.786 18.585 40.443 22.5 40.443 C 26.415 40.443 30.302 39.786 34 38.5",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .butt, join: .round, evenOdd: false
        ),
        Layer(
            "M 11 29 C 14.698 27.714 18.585 27.057 22.5 27.057 C 26.415 27.057 30.302 27.714 34 29",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 12.5 31.5 L 32.5 31.5",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 11.5 34.5 C 15.048 35.675 18.762 36.274 22.5 36.274 C 26.238 36.274 29.952 35.675 33.5 34.5",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
        Layer(
            "M 10.5 37.5 C 14.345 38.903 18.407 39.621 22.5 39.621 C 26.593 39.621 30.655 38.903 34.5 37.5",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: false
        ),
    ]

    private static let blackKing: [Layer] = [
        Layer(
            "M 22.5 11.63 L 22.5 6",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 22.5 25 C 22.5 25 27 17.5 25.5 14.5 C 25.5 14.5 24.5 12 22.5 12 C 20.5 12 19.5 14.5 19.5 14.5 C 18 17.5 22.5 25 22.5 25",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .butt, join: .miter, evenOdd: true
        ),
        Layer(
            "M 12.5 37 C 18 40.5 27 40.5 32.5 37 L 32.5 30 C 32.5 30 41.5 25.5 38.5 19.5 C 34.5 13 25 16 22.5 23.5 L 22.5 27 L 22.5 23.5 C 20 16 10.5 13 6.5 19.5 C 3.5 25.5 12.5 30 12.5 30 L 12.5 37",
            fill: .dark, stroke: .dark, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 20 8 L 25 8",
            fill: .none, stroke: .dark, width: 1.5,
            cap: .round, join: .miter, evenOdd: true
        ),
        Layer(
            "M 32 29.5 C 32 29.5 40.5 25.5 38.03 19.85 C 34.15 14 25 18 22.5 24.5 L 22.5 26.6 L 22.5 24.5 C 20 18 10.85 14 6.97 19.85 C 4.5 25.5 13 29.5 13 29.5",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
        Layer(
            "M 12.5 30 C 18 27 27 27 32.5 30 M 12.5 33.5 C 18 30.5 27 30.5 32.5 33.5 M 12.5 37 C 18 34 27 34 32.5 37",
            fill: .none, stroke: .light, width: 1.5,
            cap: .round, join: .round, evenOdd: true
        ),
    ]
}

// MARK: - Path data

private extension Path {
    /// Reads the flattened path data above: absolute M / L / C / Z only.
    init(flattenedSVG data: String) {
        self.init()
        let tokens = data.split(separator: " ")
        var index = 0
        func number() -> CGFloat {
            defer { index += 1 }
            guard index < tokens.count else { return 0 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                move(to: CGPoint(x: number(), y: number()))
            case "L":
                addLine(to: CGPoint(x: number(), y: number()))
            case "C":
                let control1 = CGPoint(x: number(), y: number())
                let control2 = CGPoint(x: number(), y: number())
                addCurve(to: CGPoint(x: number(), y: number()),
                         control1: control1, control2: control2)
            case "Z":
                closeSubpath()
            default:
                break
            }
        }
    }
}
