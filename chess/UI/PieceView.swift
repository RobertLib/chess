//
//  PieceView.swift
//  chess
//
//  Draws one piece by painting the layers of `PieceArt` in order.
//

import SwiftUI

struct PieceView: View {
    let piece: Piece
    var shadow: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let scale = size / PieceArt.designSize
            let transform = CGAffineTransform(scaleX: scale, y: scale)

            ZStack {
                ForEach(Array(PieceArt.layers(for: piece).enumerated()), id: \.offset) { _, layer in
                    let path = layer.path.applying(transform)
                    ZStack {
                        if layer.fill != .none {
                            path.fill(color(layer.fill), style: FillStyle(eoFill: layer.evenOdd))
                        }
                        if layer.stroke != .none {
                            path.stroke(color(layer.stroke), style: StrokeStyle(
                                lineWidth: layer.width * scale,
                                lineCap: layer.cap,
                                lineJoin: layer.join
                            ))
                        }
                    }
                }
            }
            // One shadow for the whole piece rather than one per layer.
            .compositingGroup()
            .shadow(color: .black.opacity(shadow ? 0.32 : 0),
                    radius: size * 0.030, y: size * 0.026)
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Colors

    private func color(_ ink: PieceArt.Ink) -> Color {
        switch ink {
        case .none:
            return .clear
        case .light:
            return piece.color == .white
                ? Color(red: 0.99, green: 0.98, blue: 0.96)
                : Color(red: 0.93, green: 0.92, blue: 0.90)
        case .dark:
            return Color(red: 0.09, green: 0.08, blue: 0.07)
        }
    }
}

#Preview("Pieces") {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)
    return VStack(spacing: 0) {
        ForEach([PieceColor.white, .black], id: \.self) { color in
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(PieceKind.allCases, id: \.self) { kind in
                    ZStack {
                        Rectangle().fill(Color(red: 0.71, green: 0.53, blue: 0.39))
                        PieceView(piece: Piece(color, kind))
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }
    .padding()
}
