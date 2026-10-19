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
                                settingToggle("Premoves against the computer", systemName: "forward.end.alt.fill", isOn: $settings.premovesEnabled)
                            }
                            .padding(.vertical, 4)
                            .hudCard(cornerRadius: 16)
                        }

                        // Credits
                        VStack(alignment: .leading, spacing: 10) {
                            sectionTitle("CREDITS")
                            VStack(alignment: .leading, spacing: 14) {
                                creditEntry("Piece artwork", """
                                    The standard Staunton chess pieces drawn by \
                                    Cburnett for Wikimedia Commons, used under \
                                    the BSD licence.
                                    """, licence: Self.cburnettLicence)
                                creditEntry("Evaluation tables", """
                                    The piece-square tables of the Simplified \
                                    Evaluation Function by Tomasz Michniewski, \
                                    from the Chess Programming Wiki, used under \
                                    CC BY-SA 3.0, whose terms are published at:
                                    """, address: Self.ccBySALicenceAddress)
                                creditEntry("Puzzles", """
                                    A selection from the Lichess puzzle \
                                    database, released into the public domain \
                                    under CC0. Bundled with the app, so they \
                                    work without a connection.
                                    """)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .hudCard(cornerRadius: 16)
                        }

                        Text("Chess · an offline game for one or two players")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiaryText)
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

    /// One attribution in the Credits card: what is borrowed, and from whom.
    /// `licence` is a licence the app has to carry in full, shown verbatim
    /// and untranslated behind a disclosure. `address` is for a licence the
    /// app may point to rather than carry: where it is published, shown as
    /// plain text under a body that leads up to it.
    private func creditEntry(
        _ title: LocalizedStringKey, _ body: LocalizedStringKey,
        address: String? = nil, licence: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text(body)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let address {
                // Plain text that can be copied, not a link: the app makes no
                // connection of its own and says so, and a tappable address
                // in it would be the one exception.
                Text(verbatim: address)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let licence {
                DisclosureGroup {
                    Text(verbatim: licence)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("Licence text")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .tint(Design.gold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CC BY-SA asks every copy of the work to carry the licence or its
    /// address (section 4a of 3.0); the address is the shorter of the two.
    private static let ccBySALicenceAddress = "https://creativecommons.org/licenses/by-sa/3.0/"

    /// The BSD licence of the piece artwork. Its second clause asks for the
    /// notice, the conditions and the disclaimer to travel with the binary.
    private static let cburnettLicence = """
        Copyright (c) 2006 Colin M.L. Burnett

        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions \
        are met:

        1. Redistributions of source code must retain the above copyright \
        notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright \
        notice, this list of conditions and the following disclaimer in the \
        documentation and/or other materials provided with the distribution.
        3. The name of the author may not be used to endorse or promote \
        products derived from this software without specific prior written \
        permission.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR \
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED \
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
        DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, \
        INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES \
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) \
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, \
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING \
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
        POSSIBILITY OF SUCH DAMAGE.
        """

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(.tertiaryText)
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
