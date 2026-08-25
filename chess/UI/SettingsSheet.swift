//
//  SettingsSheet.swift
//  chess
//
//  Board theme picker and preference toggles.
//

import SwiftUI

struct SettingsSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // Theme picker
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("BOARD THEME")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(BoardTheme.all) { theme in
                                        ThemeSwatch(
                                            theme: theme,
                                            isSelected: settings.themeID == theme.id
                                        ) {
                                            withAnimation(Motion.meaningful(.spring(duration: 0.35))) {
                                                settings.themeID = theme.id
                                            }
                                            Haptics.pieceSelected()
                                        }
                                    }
                                }
                                .padding(.horizontal, 2)
                                .padding(.vertical, 4)
                            }
                        }

                        // Toggles
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("GAME")
                            VStack(spacing: 2) {
                                settingToggle("Sounds", systemName: "speaker.wave.2.fill", isOn: $settings.soundsEnabled)
                                settingToggle("Haptics", systemName: "iphone.gen3.radiowaves.left.and.right", isOn: $settings.hapticsEnabled)
                                settingToggle("Show legal moves", systemName: "circle.dotted", isOn: $settings.showLegalMoves)
                                settingToggle("Board coordinates", systemName: "textformat.123", isOn: $settings.showCoordinates)
                                settingToggle("Flip board (two players)", systemName: "arrow.trianglehead.2.clockwise.rotate.90", isOn: $settings.autoFlipBoard)
                            }
                            .padding(.vertical, 4)
                            .hudCard(cornerRadius: 16)
                        }

                        // Credits
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("CREDITS")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Piece artwork")
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                Text("""
                                    The standard Staunton chess pieces drawn by \
                                    Cburnett for Wikimedia Commons, used under \
                                    the BSD licence.
                                    """)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .hudCard(cornerRadius: 16)
                        }

                        Text("Chess · an offline game for one or two players")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(1.2)
    }

    private func settingToggle(_ title: LocalizedStringKey, systemName: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .scaledFont(15, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(Design.gold)
                    .scaledFrame(width: 26, relativeTo: .subheadline)
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .tint(Design.gold)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// Mini 4×4 board preview for a theme.
private struct ThemeSwatch: View {
    let theme: BoardTheme
    let isSelected: Bool
    let action: () -> Void

    /// The preview grows a little with the text setting, but it is decoration:
    /// past a point a bigger swatch only pushes the themes beside it off screen.
    @ScaledMetric(relativeTo: .caption2) private var rawSquareSide: CGFloat = 17
    private var squareSide: CGFloat { min(rawSquareSide, 26) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { col in
                                Rectangle()
                                    .fill((row + col) % 2 == 0 ? theme.lightSquare : theme.darkSquare)
                                    .frame(width: squareSide, height: squareSide)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Design.gold : Color.white.opacity(0.15),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
                .shadow(color: isSelected ? Design.gold.opacity(0.35) : .clear, radius: 8)

                Text(theme.name)
                    .font(.system(.caption2, design: .rounded, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Design.gold : .white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(width: squareSide * 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
