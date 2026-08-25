//
//  TutorialView.swift
//  chess
//
//  The "How to Play" guide: a table of contents, and a chapter reader whose
//  pages carry playable boards.
//

import SwiftUI

struct TutorialView: View {
    @Environment(AppSettings.self) private var settings

    let onClose: () -> Void

    @State private var path: [TutorialChapter] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                LinearGradient(
                    colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                contents
            }
            .navigationTitle("How to Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .tint(Design.gold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: TutorialChapter.self) { chapter in
                TutorialChapterView(chapter: chapter)
                    .environment(settings)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
#if DEBUG
            // Development helper: open one chapter straight away.
            if let argument = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--tutorial-chapter=") }),
               let chapter = TutorialGuide.chapter(id: String(argument.dropFirst("--tutorial-chapter=".count))),
               path.isEmpty {
                path = [chapter]
            }
#endif
        }
    }

    // MARK: Contents

    private var contents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Never played before? Start at the top. Nine short lessons cover every rule of the game.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                ForEach(Array(TutorialGuide.chapters.enumerated()), id: \.element.id) { index, chapter in
                    NavigationLink(value: chapter) {
                        ChapterRow(
                            number: index + 1,
                            chapter: chapter,
                            isRead: settings.readTutorialChapters.contains(chapter.id)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Text("The boards in the lessons are live: tap a piece's dots and the move really happens.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Contents row

private struct ChapterRow: View {
    let number: Int
    let chapter: TutorialChapter
    let isRead: Bool

    /// The chapter's badge is decoration; past a point a bigger circle only
    /// leaves the title beside it too narrow to break into whole words.
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var rawIconWell: CGFloat = 44
    private var iconWell: CGFloat { min(rawIconWell, 62) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.07))
                TutorialIconView(icon: chapter.icon)
            }
            .frame(width: iconWell, height: iconWell)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(number). \(chapter.title)")
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    if isRead {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(12, relativeTo: .caption)
                            .foregroundStyle(Design.gold.opacity(0.85))
                    }
                }
                Text(chapter.summary)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            // Both are decoration and both are already hidden from VoiceOver,
            // so at the accessibility sizes they stand aside and give the
            // chapter title the width it needs to break into whole words.
            if !typeSize.isAccessibilitySize {
                Text(verbatim: "\(chapter.pages.count)")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .scaledFont(13, relativeTo: .footnote, weight: .bold)
                    .foregroundStyle(.white.opacity(0.3))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }
}

/// A chapter's icon: either an SF Symbol or one of the app's own pieces.
private struct TutorialIconView: View {
    let icon: TutorialChapter.Icon

    @ScaledMetric(relativeTo: .title3) private var rawGlyph: CGFloat = 18
    @ScaledMetric(relativeTo: .title3) private var rawPiece: CGFloat = 30

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: min(rawGlyph, 26), weight: .semibold))
                .foregroundStyle(Design.gold)
        case .piece(let kind):
            PieceView(piece: Piece(.white, kind), shadow: false)
                .frame(width: min(rawPiece, 40), height: min(rawPiece, 40))
        }
    }
}

// MARK: - Chapter reader

struct TutorialChapterView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Footer chrome grows with the text setting but stops short of the point
    /// where the row would be wider than the screen and drag the page with it.
    @ScaledMetric(relativeTo: .subheadline) private var rawStepSide: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var rawStepGlyph: CGFloat = 15
    private var stepSide: CGFloat { min(rawStepSide, 60) }

    let chapter: TutorialChapter

    @State private var index = 0

    private var isLastPage: Bool { index >= chapter.pages.count - 1 }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [settings.theme.backgroundTop, settings.theme.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(chapter.pages.enumerated()), id: \.offset) { offset, page in
                        TutorialPageView(page: page, theme: settings.theme)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
        }
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
#if DEBUG
            // Development helper: jump straight to a page for screenshots.
            if let argument = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--tutorial-page=") }),
               let page = Int(argument.dropFirst("--tutorial-page=".count)),
               chapter.pages.indices.contains(page - 1) {
                index = page - 1
            }
#endif
            markRead()
        }
        .onChange(of: index) { _, _ in markRead() }
    }

    /// A chapter counts as read once its last page has been reached.
    private func markRead() {
        guard isLastPage else { return }
        settings.markTutorialChapterRead(chapter.id)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: min(rawStepGlyph, 23), weight: .bold))
                    .foregroundStyle(.white.opacity(index == 0 ? 0.2 : 0.85))
                    .frame(width: stepSide, height: stepSide)
                    .hudCard(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityLabel(Text("Previous page", comment: "VoiceOver name of the tutorial's back-one-page button"))

            HStack(spacing: 5) {
                ForEach(chapter.pages.indices, id: \.self) { page in
                    Capsule()
                        .fill(page == index ? Design.gold : Color.white.opacity(0.22))
                        .frame(width: page == index ? 16 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            Button {
                if isLastPage {
                    dismiss()
                } else {
                    step(1)
                }
            } label: {
                Text(isLastPage ? "Finish" : "Next")
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .lineLimit(1)
                    // The word keeps its width; the row of page dots beside it
                    // is what gives way when the text is turned up.
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 92)
                    .frame(height: stepSide)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Design.gold)
                            .shadow(color: Design.gold.opacity(0.3), radius: 10, y: 4)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard chapter.pages.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.28)) { index = next }
        Haptics.pieceSelected()
    }
}

// MARK: - One page

private struct TutorialPageView: View {
    let page: TutorialPage
    let theme: BoardTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(page.heading)
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)

                Text(page.text)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)

                if let diagram = page.diagram {
                    TutorialBoardView(diagram: diagram, theme: theme)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }

                if !page.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(page.bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(Design.gold.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                                Text(bullet)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudCard(cornerRadius: 16)
                }

                switch page.extra {
                case .pieceValues:
                    PieceValueTable()
                case .moveGrades:
                    MoveGradeLegend()
                case nil:
                    EmptyView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Extras

/// What each piece is worth, in pawns.
private struct PieceValueTable: View {
    private let rows: [(kind: PieceKind, name: String, value: String)] = [
        (.pawn, String(localized: "Pawn", comment: "Piece name"), "1"),
        (.knight, String(localized: "Knight", comment: "Piece name"), "3"),
        (.bishop, String(localized: "Bishop", comment: "Piece name"), "3"),
        (.rook, String(localized: "Rook", comment: "Piece name"), "5"),
        (.queen, String(localized: "Queen", comment: "Piece name"), "9"),
        (.king, String(localized: "King", comment: "Piece name"), "∞")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                HStack(spacing: 12) {
                    PieceView(piece: Piece(.white, row.kind), shadow: false)
                        .scaledFrame(30, relativeTo: .subheadline)
                    Text(row.name)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(verbatim: row.value)
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                        .foregroundStyle(Design.gold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)

                if offset < rows.count - 1 {
                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 56)
                }
            }
        }
        .padding(.vertical, 4)
        .hudCard(cornerRadius: 16)
    }
}

/// The grades the game review hands out, with what each one means.
private struct MoveGradeLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MoveQuality.summaryOrder, id: \.self) { quality in
                HStack(spacing: 11) {
                    QualityBadge(quality: quality, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(quality.label)
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(blurb(for: quality))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudCard(cornerRadius: 16)
    }

    private func blurb(for quality: MoveQuality) -> String {
        switch quality {
        case .brilliant: return String(localized: "A sacrifice that works")
        case .great: return String(localized: "The one move that held everything together")
        case .best: return String(localized: "The engine's own first choice")
        case .excellent: return String(localized: "As good as the best move, for all practical purposes")
        case .good: return String(localized: "Sound, if not the sharpest")
        case .book: return String(localized: "A known opening move")
        case .inaccuracy: return String(localized: "Gave a little something away")
        case .mistake: return String(localized: "Handed over real ground")
        case .miss: return String(localized: "A winning chance went by")
        case .blunder: return String(localized: "The move that cost the game")
        }
    }
}

#Preview("Contents") {
    TutorialView(onClose: {})
        .environment(AppSettings())
}

#Preview("Chapter") {
    NavigationStack {
        TutorialChapterView(chapter: TutorialGuide.chapter(id: "pieces")!)
            .environment(AppSettings())
    }
    .preferredColorScheme(.dark)
}
