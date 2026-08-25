//
//  Theme.swift
//  chess
//
//  Board themes and shared design tokens.
//

import SwiftUI
import UIKit

struct BoardTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let lightSquare: Color
    let darkSquare: Color
    let frame: Color
    let frameText: Color
    /// Background gradient behind the whole game screen.
    let backgroundTop: Color
    let backgroundBottom: Color
    let accent: Color

    static let classic = BoardTheme(
        id: "classic", name: String(localized: "Wood", comment: "Board theme"),
        lightSquare: Color(red: 0.94, green: 0.85, blue: 0.71),
        darkSquare: Color(red: 0.71, green: 0.53, blue: 0.39),
        frame: Color(red: 0.32, green: 0.22, blue: 0.15),
        frameText: Color(red: 0.87, green: 0.78, blue: 0.66),
        backgroundTop: Color(red: 0.13, green: 0.10, blue: 0.08),
        backgroundBottom: Color(red: 0.23, green: 0.16, blue: 0.11),
        accent: Color(red: 0.98, green: 0.75, blue: 0.35)
    )

    static let forest = BoardTheme(
        id: "forest", name: String(localized: "Tournament", comment: "Board theme"),
        lightSquare: Color(red: 0.92, green: 0.93, blue: 0.82),
        darkSquare: Color(red: 0.45, green: 0.58, blue: 0.32),
        frame: Color(red: 0.16, green: 0.23, blue: 0.13),
        frameText: Color(red: 0.80, green: 0.85, blue: 0.72),
        backgroundTop: Color(red: 0.07, green: 0.12, blue: 0.07),
        backgroundBottom: Color(red: 0.13, green: 0.21, blue: 0.12),
        accent: Color(red: 0.95, green: 0.82, blue: 0.38)
    )

    static let ocean = BoardTheme(
        id: "ocean", name: String(localized: "Ocean", comment: "Board theme"),
        lightSquare: Color(red: 0.87, green: 0.89, blue: 0.90),
        darkSquare: Color(red: 0.47, green: 0.58, blue: 0.67),
        frame: Color(red: 0.13, green: 0.19, blue: 0.25),
        frameText: Color(red: 0.72, green: 0.79, blue: 0.85),
        backgroundTop: Color(red: 0.05, green: 0.09, blue: 0.14),
        backgroundBottom: Color(red: 0.10, green: 0.17, blue: 0.24),
        accent: Color(red: 0.42, green: 0.80, blue: 0.93)
    )

    static let midnight = BoardTheme(
        id: "midnight", name: String(localized: "Midnight", comment: "Board theme"),
        lightSquare: Color(red: 0.55, green: 0.57, blue: 0.64),
        darkSquare: Color(red: 0.28, green: 0.30, blue: 0.38),
        frame: Color(red: 0.10, green: 0.11, blue: 0.15),
        frameText: Color(red: 0.65, green: 0.67, blue: 0.75),
        backgroundTop: Color(red: 0.04, green: 0.04, blue: 0.07),
        backgroundBottom: Color(red: 0.10, green: 0.10, blue: 0.16),
        accent: Color(red: 0.71, green: 0.54, blue: 0.98)
    )

    static let rose = BoardTheme(
        id: "rose", name: String(localized: "Marble", comment: "Board theme"),
        lightSquare: Color(red: 0.93, green: 0.90, blue: 0.87),
        darkSquare: Color(red: 0.63, green: 0.49, blue: 0.48),
        frame: Color(red: 0.25, green: 0.16, blue: 0.16),
        frameText: Color(red: 0.85, green: 0.75, blue: 0.73),
        backgroundTop: Color(red: 0.12, green: 0.07, blue: 0.08),
        backgroundBottom: Color(red: 0.21, green: 0.13, blue: 0.14),
        accent: Color(red: 0.96, green: 0.63, blue: 0.52)
    )

    static let all: [BoardTheme] = [.classic, .forest, .ocean, .midnight, .rose]

    static func theme(id: String) -> BoardTheme {
        all.first { $0.id == id } ?? .classic
    }
}

// MARK: - Shared UI constants

enum Design {
    static let cornerRadius: CGFloat = 18
    static let cardBackground = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.10)

    /// Warm gold used across menus for primary actions.
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.35)

    /// Round chrome buttons — back, settings, flip. They grow with the text
    /// setting so the glyph inside stays legible, but stop well short of the
    /// point where the two of them would leave the title between them no room.
    static let circleButtonSide: CGFloat = 38
    static let circleButtonMaxSide: CGFloat = 54
    static let circleButtonGlyph: CGFloat = 15
    static let circleButtonMaxGlyph: CGFloat = 23
}

extension View {
    /// Frosted card look used for HUD panels.
    func hudCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Design.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Design.cardStroke, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Scaled fonts

/// A system font drawn at an exact point size that still grows with Dynamic Type.
///
/// The design is laid out at specific sizes rather than at the text styles, so
/// `Font.system(size:)` was the natural way to write it — but that font never
/// scales, and Larger Text left half the app frozen at 9–13 pt while the half
/// written against text styles grew around it.
///
/// The font is built through `UIFontMetrics` rather than by scaling a number
/// ourselves. Both would grow, but only a metrics font *reports* itself as one:
/// `performAccessibilityAudit(for: [.dynamicType])` reads the rendered font, so
/// a hand-scaled `Font.system(size:)` still fails the audit that is meant to
/// keep this from regressing.
private struct ScaledFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let size: CGFloat
    let style: Font.TextStyle
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.scaledSystem(size: size, relativeTo: style, weight: weight,
                                   design: design, typeSize: typeSize))
    }
}

extension Font {
    /// `Font.system(size:weight:design:)` anchored to a text style, so it scales
    /// with the reader's text-size setting the way a text style does.
    static func scaledSystem(
        size: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight,
        design: Font.Design,
        typeSize: DynamicTypeSize
    ) -> Font {
        let base = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        let descriptor = base.fontDescriptor.withDesign(design.uiDesign) ?? base.fontDescriptor
        let metrics = UIFontMetrics(forTextStyle: style.uiStyle)
        let scaled = metrics.scaledFont(
            for: UIFont(descriptor: descriptor, size: size),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.contentSizeCategory)
        )
        return Font(scaled)
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` that honours the text-size setting.
    /// Anchor `style` to the text style nearest `size` so the growth rate matches
    /// the text around it.
    func scaledFont(
        _ size: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFont(size: size, style: style, weight: weight, design: design))
    }
}

// MARK: SwiftUI -> UIKit font vocabulary

private extension Font.Weight {
    var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private extension Font.Design {
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        default: return .default
        }
    }
}

private extension Font.TextStyle {
    var uiStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

private extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// A fixed-size well — an icon circle, a badge, a pill button — that grows
/// alongside the text it holds, so a scaled glyph never spills out of the
/// shape drawn behind it.
private struct ScaledSize: ViewModifier {
    @ScaledMetric private var width: CGFloat
    @ScaledMetric private var height: CGFloat

    init(width: CGFloat, height: CGFloat, relativeTo style: Font.TextStyle) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: style)
        _height = ScaledMetric(wrappedValue: height, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.frame(width: width, height: height)
    }
}

private struct ScaledWidth: ViewModifier {
    @ScaledMetric private var width: CGFloat

    init(width: CGFloat, relativeTo style: Font.TextStyle) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.frame(width: width)
    }
}

extension View {
    func scaledFrame(width: CGFloat, height: CGFloat, relativeTo style: Font.TextStyle) -> some View {
        modifier(ScaledSize(width: width, height: height, relativeTo: style))
    }

    func scaledFrame(width: CGFloat, relativeTo style: Font.TextStyle) -> some View {
        modifier(ScaledWidth(width: width, relativeTo: style))
    }

    func scaledFrame(_ side: CGFloat, relativeTo style: Font.TextStyle) -> some View {
        scaledFrame(width: side, height: side, relativeTo: style)
    }
}

// MARK: - Dynamic Type limits

extension View {
    /// Caps Dynamic Type on screens whose layout is bound to a square board or
    /// a dial rather than to a column of prose. Text still grows most of the
    /// way up the accessibility sizes; past that the board would be squeezed
    /// off the screen, which helps nobody.
    func boardTypeLimit() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
