//
//  MyGamesView.swift
//  chess
//
//  The archive: every finished game, the statistics they add up to, the
//  achievements, and PGN in and out.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - PGN as a file

extension UTType {
    /// Portable Game Notation. The system declares no type for it, so the
    /// app's Info.plist imports one: plain text underneath, under the `.pgn`
    /// extension and the PGN MIME types. A type only made up from the
    /// extension was one the Files picker did not know to be text, and it
    /// could leave `.pgn` files greyed out.
    nonisolated static var pgn: UTType {
        UTType(importedAs: "com.apple.chess.pgn", conformingTo: .plainText)
    }

    /// What the importer takes. Another app on the device may declare `.pgn`
    /// under an identifier of its own, and the system then files `.pgn` files
    /// under that one, so the type it resolves the extension to is accepted as
    /// well — and plain text, for a game saved as a `.txt` file.
    nonisolated static var pgnImportable: [UTType] {
        var types: [UTType] = [.pgn]
        if let resolved = UTType(filenameExtension: "pgn"), resolved != .pgn {
            types.append(resolved)
        }
        return types + [.plainText, .text]
    }
}

/// A PGN text the share sheet hands over as a `.pgn` file.
///
/// The text is made when the file is actually asked for, not when the share
/// button is drawn: exporting the whole archive replays every game in it, and
/// that is work for the moment somebody taps "Export", not for every redraw.
nonisolated struct PGNFile: Transferable, Sendable {
    let make: @Sendable () async -> String
    let fileName: String

    init(fileName: String, make: @escaping @Sendable () async -> String) {
        self.fileName = fileName
        self.make = make
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pgn) { file in
            Data(await file.make().utf8)
        }
        .suggestedFileName { $0.fileName }
    }
}

// Nonisolated, the PGN side of a record: "Export All as PGN" replays every
// game in the archive, and that is work for a background thread, not for the
// main actor under the share sheet. Nothing here reads more than the record's
// own fields and the engine's types.
extension GameRecord {
    /// The tags a game recorded here is written out with.
    nonisolated var pgnTags: [(String, String)] {
        if source == .imported, let tags {
            return tags.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        var result: [(String, String)] = [
            ("Event", mode.isVsAI ? "Game against the computer" : "Casual game"),
            ("Site", "Chess (offline)"),
            ("Date", formatter.string(from: finishedAt)),
            ("Round", "-"),
        ]
        switch mode {
        case .twoPlayer:
            result += [("White", "White"), ("Black", "Black")]
        case .vsAI(let difficulty, let color):
            let computer = "Computer (\(difficulty.rawValue))"
            result += color == .white ? [("White", "Player"), ("Black", computer)] : [("White", computer), ("Black", "Player")]
        }
        if let control = options.timeControl {
            result.append(("TimeControl", Self.pgnTimeControl(control)))
        }
        return result
    }

    /// The control the way the PGN standard writes one: the starting time and
    /// the increment, in whole seconds — "300+2". The standard has no way to
    /// write a delay, and "300+3" for one claimed an increment that was never
    /// given, so a delay or a Bronstein clock is written as its starting time
    /// alone: sudden death, which the standard can say.
    nonisolated static func pgnTimeControl(_ control: TimeControl) -> String {
        let initial = Int(control.initial.rounded())
        switch control.bonusKind {
        case .increment: return "\(initial)+\(Int(control.bonus.rounded()))"
        case .delay, .bronstein: return "\(initial)"
        }
    }

    nonisolated func pgn() -> String? {
        guard let game = restoreGame() else { return nil }
        let firstMover = game.history.first?.color ?? .white
        let clocks = options.timeControl.map {
            PGN.clockFaces(control: $0, moveTimes: moveTimes, firstMover: firstMover)
        }
        return PGN.export(game: game, tags: pgnTags, clockAfterMove: moveTimes.isEmpty ? nil : clocks)
    }

    /// The game as "Export All" writes it. One whose moves no longer all
    /// replay, which the list cannot open either, is written as far as they
    /// go, with the result it was filed with: left out, it went missing
    /// without a word from a file kept as a backup.
    nonisolated func pgnForExport() -> String {
        if let pgn = pgn() { return pgn }
        var tags = pgnTags
        if !tags.contains(where: { $0.0 == "Result" }) {
            tags.append(("Result", PGN.result(of: outcome)))
        }
        return PGN.export(game: replayedMoves().game, tags: tags)
    }

    /// "Vs Computer · Hard", "Two Players", or the names of an imported game.
    @MainActor
    var title: String {
        if source == .imported, let tags {
            return "\(tags["White"] ?? "?") – \(tags["Black"] ?? "?")"
        }
        switch mode {
        case .twoPlayer: return String(localized: "Two Players", comment: "Game mode")
        case .vsAI(let difficulty, _):
            return String(localized: "Vs Computer · \(difficulty.displayName)",
                          comment: "Game mode, with the difficulty level")
        }
    }
}

// MARK: - View

struct MyGamesView: View {
    @Environment(AppSettings.self) private var settings
    let onClose: () -> Void

    private enum Tab: String, CaseIterable {
        case games, statistics, achievements

        var title: String {
            switch self {
            case .games: return String(localized: "Games", comment: "My Games tab")
            case .statistics: return String(localized: "Statistics", comment: "My Games tab")
            case .achievements: return String(localized: "Achievements", comment: "My Games tab")
            }
        }
    }

    private enum Filter: CaseIterable {
        case all, computer, twoPlayer, imported

        var title: String {
            switch self {
            case .all: return String(localized: "All", comment: "Game list filter")
            case .computer: return String(localized: "Computer", comment: "Game list filter")
            case .twoPlayer: return String(localized: "Two players", comment: "Game list filter")
            case .imported: return String(localized: "Imported", comment: "Game list filter")
            }
        }

        func includes(_ record: GameRecord) -> Bool {
            switch self {
            case .all: return true
            case .computer: return record.source == .played && record.mode.isVsAI
            case .twoPlayer: return record.source == .played && !record.mode.isVsAI
            case .imported: return record.source == .imported
            }
        }
    }

    @State private var tab: Tab = .games
    @State private var filter: Filter = .all
    @State private var selected: GameRecord?
    @State private var review: GameReviewModel?
    @State private var analysis: AnalysisBoardModel?
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var isImporting = false
    /// Set when a game picked from the list no longer replays, so that the
    /// tap on Game Review or Analysis Board is answered rather than ignored.
    @State private var showUnopenable = false

    private var records: [GameRecord] { GameArchive.shared.records }

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            VStack(spacing: 10) {
                ScreenTopBar(title: String(localized: "My Games"), backLabel: "Back to menu", onBack: onClose) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import PGN", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isImporting)
                        if !records.isEmpty {
                            ShareLink(item: allGamesFile, preview: SharePreview(Self.allGamesFileName)) {
                                Label("Export All as PGN", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        // Drawn by the round buttons' own face, so it grows
                        // with the text the way the back chevron opposite it
                        // does; a 15 pt glyph of its own stayed 15 pt.
                        CircleButtonFace(systemName: "ellipsis")
                    }
                    .accessibilityLabel(Text("Import and export"))
                }
                .padding(.horizontal, 12)

                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                ScrollView {
                    Group {
                        switch tab {
                        case .games: gamesList
                        case .statistics: StatisticsPanel(stats: GameStatistics(records: records))
                        case .achievements: AchievementsPanel()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
            // A game whose moves no longer replay. The record is left where it
            // is: its result still counts in the statistics, and deleting it
            // is the player's call. Hung on this stack rather than beside the
            // import alert below, for the reason GameView keeps to one dialog:
            // two on the same view are not reliably both presented.
            .alert("This game could not be opened.", isPresented: $showUnopenable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Its moves could not be replayed. The game stays in My Games.")
            }
            // A large file takes a while to read, and nothing else on the
            // page changes until it has been.
            .overlay(alignment: .bottom) {
                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Importing games…")
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 16)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .sheet(item: $selected) { record in
            GameDetailSheet(
                record: record,
                onReview: {
                    selected = nil
                    openReview(record)
                },
                onAnalyze: {
                    selected = nil
                    let game = record.restoreGame()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if let game {
                            analysis = AnalysisBoardModel(game: game, startAtEnd: false, orientation: record.humanColor ?? .white)
                        } else {
                            showUnopenable = true
                        }
                    }
                },
                onDelete: {
                    GameArchive.shared.remove(record.id)
                    selected = nil
                }
            )
            .environment(settings)
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $review) { model in
            GameReviewView(model: model) { review = nil }
                .environment(settings)
        }
        .fullScreenCover(item: Binding(
            get: { analysis.map(AnalysisRequest.init) },
            set: { if $0 == nil { analysis = nil } }
        )) { request in
            AnalysisView(model: request.model, onClose: { analysis = nil })
                .environment(settings)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: UTType.pgnImportable,
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
        .alert(importMessage ?? "", isPresented: Binding(
            get: { importMessage != nil }, set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    private struct AnalysisRequest: Identifiable {
        let model: AnalysisBoardModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
    }

    /// The names the files are shared under, and what the share sheet calls
    /// them: one string for both, as the sheet said "games.pgn" over a file
    /// that was saved as "chess-games.pgn".
    static let allGamesFileName = String(localized: "chess-games.pgn", comment: "File name of every game exported as PGN")
    static let gameFileName = String(localized: "chess-game.pgn", comment: "File name of one game shared as PGN")

    /// Every game in the archive, written out when the share sheet asks for
    /// the file — on a background thread, from the records as they stood
    /// when the button was drawn. Replaying three hundred games on the main
    /// actor held the share sheet still while it did.
    private var allGamesFile: PGNFile {
        let records = self.records
        return PGNFile(fileName: Self.allGamesFileName) {
            await Task.detached(priority: .userInitiated) {
                PGN.export(records.map { $0.pgnForExport() })
            }.value
        }
    }

    private func openReview(_ record: GameRecord) {
        let game = record.restoreGame()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let game {
                review = GameReviewModel(record: record, game: game)
            } else {
                showUnopenable = true
            }
        }
    }

    // MARK: Games

    private var gamesList: some View {
        let shown = records.filter(filter.includes)
        return VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        Button {
                            filter = item
                        } label: {
                            Text(item.title)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(filter == item ? Color.black.opacity(0.85) : .white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(Capsule().fill(filter == item ? AnyShapeStyle(Design.gold) : AnyShapeStyle(Color.white.opacity(0.08))))
                                // The capsule keeps the size of a chip; what
                                // the finger has to hit is the 44 pt Apple asks
                                // for, the way `ReviewMoveStrip` pads its moves.
                                .frame(minHeight: Design.minimumTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
            }
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .scaledFont(34, relativeTo: .largeTitle)
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Finished games appear here, ready to review.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
            }
            LazyVStack(spacing: 8) {
                ForEach(shown) { record in
                    GameRow(record: record) { selected = record }
                }
            }
        }
    }

    // MARK: Import

    /// Reads the files on a background thread. Every game in them is
    /// replayed move by move, and a download of a few thousand games held
    /// the whole app still for seconds on the main actor — tens of seconds
    /// for a long history.
    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !isImporting else { return }
        isImporting = true
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Self.readImports(from: urls)
            }.value
            let summary = GameArchive.shared.importGames(read.records)
            importMessage = Self.importMessage(
                for: summary, unreadableFiles: read.unreadableFiles, of: urls.count,
                cutShort: read.cutShort, unreadableGames: read.unreadableGames,
                tooLargeFiles: read.tooLargeFiles, leftOverFiles: read.leftOverFiles,
                stoppedAtGameLimit: read.stoppedAtGameLimit
            )
            isImporting = false
        }
    }

    /// The most PGN read in one import, some fifteen thousand games — in one
    /// file, or in all of those picked together. Every game read is replayed
    /// and held until the newest of them are picked, and more could take the
    /// app past what the system lets it have. Counted per file, it let twenty
    /// files picked at once read in twenty times as much.
    nonisolated static let maxImportBytes = 10_000_000

    /// The most games read in one import, again in one file or in all those
    /// picked together: more than a real file inside `maxImportBytes` holds.
    /// A file written to be read as games and little else — a move a game —
    /// held four hundred thousand, every one replayed and held, and then
    /// checked against the archive and sorted on the main actor.
    nonisolated static let maxImportGames = 20_000

    nonisolated struct ImportRead: Sendable {
        var records: [GameRecord] = []
        var unreadableFiles = 0
        var tooLargeFiles = 0
        /// Files within the limit by themselves, left unread because the
        /// files read before them had used it up.
        var leftOverFiles = 0
        var cutShort = 0
        var unreadableGames = 0
        /// Whether reading stopped at `maxImportGames` with games still to
        /// come.
        var stoppedAtGameLimit = false
    }

    nonisolated static func readImports(
        from urls: [URL], limit: Int = maxImportBytes, gameLimit: Int = maxImportGames
    ) -> ImportRead {
        var read = ImportRead()
        var budget = limit
        for url in urls {
            if read.records.count >= gameLimit {
                read.leftOverFiles += 1
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Asked before reading, so that a huge file is not read in only
            // to be turned away; and again after, for a file that could not
            // say its size.
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size, size > limit {
                read.tooLargeFiles += 1
                continue
            }
            if let size, size > budget {
                read.leftOverFiles += 1
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                read.unreadableFiles += 1
                continue
            }
            guard data.count <= limit else {
                read.tooLargeFiles += 1
                continue
            }
            guard data.count <= budget else {
                read.leftOverFiles += 1
                continue
            }
            budget -= data.count
            guard let text = pgnText(from: data),
                  let games = try? importedGames(fromPGN: text, maxGames: gameLimit - read.records.count) else {
                read.unreadableFiles += 1
                continue
            }
            read.records += games.records
            read.cutShort += games.cutShort
            read.unreadableGames += games.unreadable
            if games.stoppedAtLimit { read.stoppedAtGameLimit = true }
        }
        return read
    }

    /// The games of one PGN text, as the archive files them. Throws when the
    /// text is not PGN at all; a game without a single move is left out.
    nonisolated static func importedRecords(fromPGN text: String) throws -> [GameRecord] {
        try importedGames(fromPGN: text).records
    }

    /// The same, with how many of the games stop short of the moves written
    /// for them: at a move that does not read, or is not legal, or comes after
    /// the game was already over. They are kept up to there, and the player
    /// is told — a game silently missing its ending reads as the whole game.
    ///
    /// And with how many could not be read at all, and are left out: a game
    /// whose FEN tag sets up no position, or whose very first move does not
    /// read. Either one used to drop out of its file without a word, and
    /// the file looked imported whole.
    ///
    /// No more than `maxGames` are read, and the games without a move are
    /// passed over as they are read rather than held (see `PGN.contents`).
    nonisolated static func importedGames(
        fromPGN text: String, maxGames: Int = .max
    ) throws -> (records: [GameRecord], cutShort: Int, unreadable: Int, stoppedAtLimit: Bool) {
        let contents = try PGN.contents(of: text, played: true, maxGames: maxGames)
        let games = contents.games.filter { !$0.game.history.isEmpty }
        // A game with no moves is no game to file, but one whose moves were
        // there and did not read is a game lost, unlike tags with nothing
        // after them.
        let unplayed = contents.games.count { $0.game.history.isEmpty && $0.unreadMove != nil }
        let records = games.map { parsed in
            // The variant goes with the record: replaying a King of the Hill
            // game under the ordinary rules would review it as one.
            GameRecord(
                game: parsed.game, mode: .twoPlayer, options: GameOptions(variant: parsed.game.variant),
                moveTimes: [], finalClock: nil, source: .imported, tags: parsed.tags,
                finishedAt: date(from: parsed.tags["Date"]) ?? Date()
            )
        }
        return (records, games.count { $0.unreadMove != nil }, contents.unreadableGames + unplayed,
                contents.stoppedAtLimit)
    }

    /// What the player is told after an import: how many games went in, how
    /// many were there already, how many stop short of their written moves
    /// and how many could not be read, and how many of the files picked
    /// could not be read at all — a count that used to be taken and then
    /// thrown away.
    static func importMessage(
        for summary: GameArchive.ImportSummary, unreadableFiles: Int, of files: Int,
        cutShort: Int = 0, unreadableGames: Int = 0, tooLargeFiles: Int = 0, leftOverFiles: Int = 0,
        stoppedAtGameLimit: Bool = false
    ) -> String {
        // The files turned away for their size, by themselves or together.
        var turnedAway: [String] = []
        if tooLargeFiles > 0 {
            turnedAway.append(String(localized: "\(tooLargeFiles) files are too large to import.",
                                     comment: "After a PGN import: files picked that are over the size the app reads"))
        }
        if leftOverFiles > 0 {
            turnedAway.append(String(localized: "\(leftOverFiles) files were left out: the files picked are too large to import together.",
                                     comment: "After a PGN import: files left unread because the files read before them reached the size the app reads at once"))
        }
        guard summary.added > 0 || summary.duplicates > 0 else {
            if tooLargeFiles + leftOverFiles == files { return turnedAway.joined(separator: " ") }
            let none = files > 1
                ? String(localized: "No games could be read from those files.")
                : String(localized: "No games could be read from that file.")
            return ([none] + turnedAway).joined(separator: " ")
        }
        var sentences: [String] = []
        if summary.kept < summary.added {
            sentences.append(String(localized: "Imported \(summary.kept) of \(summary.added) games — My Games keeps the newest \(GameArchive.maxRecords)."))
        } else {
            sentences.append(String(localized: "Imported \(summary.added) games."))
        }
        if summary.displaced > 0 {
            sentences.append(String(localized: "\(summary.displaced) games imported earlier were removed to make room.",
                                    comment: "After a PGN import: games imported before that the archive's cap took out for the newer ones"))
            if summary.kept == summary.added {
                sentences.append(String(localized: "My Games keeps the newest \(GameArchive.maxRecords) imported games.",
                                        comment: "After a PGN import that pushed older imports out; the number is always 300"))
            }
        }
        if stoppedAtGameLimit {
            sentences.append(String(localized: "Reading stopped after \(maxImportGames) games: the files picked hold more than can be imported at once.",
                                    comment: "After a PGN import: the files held more games than one import reads; the number is always 20,000"))
        }
        if summary.duplicates > 0 {
            sentences.append(String(localized: "Skipped \(summary.duplicates) games already in My Games.",
                                    comment: "After a PGN import: games left out because the archive already holds them"))
        }
        if cutShort > 0 {
            sentences.append(String(localized: "\(cutShort) games end early: some of their moves could not be read.",
                                    comment: "After a PGN import: games kept only up to a move that could not be read"))
        }
        if unreadableGames > 0 {
            sentences.append(String(localized: "\(unreadableGames) games could not be read.",
                                    comment: "After a PGN import: games in the files left out because not one of their moves, or their starting position, could be read"))
        }
        if unreadableFiles > 0 {
            sentences.append(String(localized: "\(unreadableFiles) files could not be read.",
                                    comment: "After a PGN import: files picked that could not be read at all"))
        }
        sentences += turnedAway
        return sentences.joined(separator: " ")
    }

    /// The text of a PGN file. Most are UTF-8; older ones are Latin-1, which
    /// any byte sequence decodes as, so it is the fallback — and that is why
    /// UTF-16 has to be caught before it. A file saved that way, as Windows
    /// tools do, starts with a byte-order mark; read as Latin-1 it came out
    /// with a NUL after every letter, and not one game could be read from it.
    ///
    /// The mark itself is dropped whatever the encoding. Left in front of the
    /// first tag, it hid the opening `[` from the parser.
    nonisolated static func pgnText(from data: Data) -> String? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text else { return nil }
        return text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
    }

    /// A PGN date, `yyyy.MM.dd`. A month or day left as `??` reads as the
    /// first, so a game known only by its year still files under that year;
    /// no year at all is no date.
    ///
    /// Nor is a date that does not exist, or one still to come. The calendar
    /// rolls "2024.13.45" over into February 2025 without complaint, and a
    /// typo in the year can put a game in the year 20240: either one sorted
    /// above every other game in My Games, and the newest imported games
    /// kept under the cap are the ones that carried it, for good.
    nonisolated static func date(from tag: String?, now: Date = Date()) -> Date? {
        guard let tag else { return nil }
        let parts = tag.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]) else { return nil }
        let month = Int(parts[1]) ?? 1
        let day = Int(parts[2]) ?? 1
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day,
              // Noon on a date that is today somewhere in the world.
              date <= now.addingTimeInterval(36 * 3600) else { return nil }
        return date
    }
}

// MARK: - Row

private struct GameRow: View {
    let record: GameRecord
    let action: () -> Void

    private var verdict: (symbol: String, tint: Color, word: String) {
        if let score = record.playerScore {
            if score >= 1 { return ("crown.fill", MoveQuality.best.tint, String(localized: "Won", comment: "Game result")) }
            if score <= 0 { return ("xmark.circle.fill", MoveQuality.blunder.tint, String(localized: "Lost", comment: "Game result")) }
            return ("equal.circle.fill", .white.opacity(0.6), String(localized: "Draw", comment: "Game result"))
        }
        return ("flag.checkered", .white.opacity(0.6), resultWord)
    }

    /// The result of a game none of whose sides was the player — two players
    /// at one device, or a game read from a file — in words. The row draws
    /// only a flag for it, so this is what VoiceOver reads first, and it used
    /// to be the PGN result: "1-0" said as a number, "½-½" as fractions.
    private var resultWord: String {
        if let winner = record.outcome.winner {
            return winner == .white
                ? String(localized: "White wins", comment: "VoiceOver: the game is over and White has won")
                : String(localized: "Black wins", comment: "VoiceOver: the game is over and Black has won")
        }
        return record.outcome.isDraw
            ? String(localized: "Draw", comment: "Game result")
            : String(localized: "Unfinished game")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: verdict.symbol)
                    .scaledFont(18, relativeTo: .headline, weight: .semibold)
                    .foregroundStyle(verdict.tint)
                    .scaledFrame(width: 28, relativeTo: .headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                if let accuracy = ownAccuracy {
                    Text(AccuracyFormat.percent(accuracy, fractionDigits: 0))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Design.gold)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .setupCard(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.title)
        .accessibilityValue("\(verdict.word), \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    private var ownAccuracy: Double? {
        guard let accuracy = record.accuracy, let color = record.humanColor else { return nil }
        // Read with the same care as the statistics read it: the list is
        // whatever the stored record holds, and one shorter than two must
        // cost this row its percentage, not the app its life.
        let index = Int(color.rawValue)
        return accuracy.indices.contains(index) ? accuracy[index] : nil
    }

    private var subtitle: String {
        var parts = [record.finishedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append(String(localized: "\(record.moveCount) moves"))
        if let control = record.options.timeControl { parts.append(control.label) }
        if record.options.variant != .standard { parts.append(record.options.variant.displayName) }
        if !record.options.start.isStandard { parts.append(record.options.start.displayName) }
        parts.append(record.outcome.headline(mode: record.mode))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

private struct GameDetailSheet: View {
    @Environment(AppSettings.self) private var settings
    let record: GameRecord
    let onReview: () -> Void
    let onAnalyze: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        ZStack {
            ScreenBackground(theme: settings.theme)
            // Scrolls so that at the largest text sizes Share and Delete are
            // still reachable below the fold of a medium sheet.
            ScrollView {
                VStack(spacing: 12) {
                    Text(record.title)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 20)
                    Text(record.outcome.headline(mode: record.mode))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    OverlayButton(title: "Game Review", systemName: "chart.line.uptrend.xyaxis", prominent: true, action: onReview)
                    OverlayButton(title: "Analysis Board", systemName: "magnifyingglass", action: onAnalyze)
                    if let pgn = record.pgn() {
                        ShareLink(item: PGNFile(fileName: MyGamesView.gameFileName) { pgn },
                                  preview: SharePreview(MyGamesView.gameFileName)) {
                            Label("Share PGN", systemImage: "square.and.arrow.up")
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.09)))
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete Game", systemImage: "trash")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(MoveQuality.blunder.tint)
                            .frame(minHeight: Design.minimumTouchTarget)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete this game?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Statistics

private struct StatisticsPanel: View {
    let stats: GameStatistics
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Three figures side by side leave each a third of the width, and at
        // the accessibility sizes "~1500" no longer fit in one: it came out
        // cut to "~1…". Stacked, each has the whole width.
        let figures = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        VStack(spacing: 14) {
            figures {
                figure("\(stats.played)", String(localized: "games played"))
                figure(stats.vsComputer.score.map { AccuracyFormat.percent($0 * 100, fractionDigits: 0) } ?? "—",
                       String(localized: "score vs computer"))
                figure(stats.estimatedRating.map { "~\($0)" } ?? "—", String(localized: "estimated strength"))
            }
            if stats.estimatedRating != nil {
                Text("A ballpark from your results against the computer levels — not an official rating.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            card(title: "VS THE COMPUTER") {
                ForEach(AIDifficulty.allCases) { level in
                    if let tally = stats.byLevel[level] {
                        tallyRow(level.displayName, tally)
                    }
                }
                if stats.byLevel.isEmpty {
                    Text("No games against the computer yet.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondaryText)
                }
            }

            card(title: "BY COLOUR") {
                tallyRow(PieceColor.white.spokenName, stats.byColor[.white] ?? ResultTally())
                tallyRow(PieceColor.black.spokenName, stats.byColor[.black] ?? ResultTally())
            }

            card(title: "BY TIME CONTROL") {
                tallyRow(String(localized: "No clock", comment: "Time control: none"), stats.byTimeControl["none"] ?? ResultTally())
                ForEach(TimeControl.Category.allCases, id: \.self) { category in
                    if let tally = stats.byTimeControl[category.rawValue] {
                        tallyRow(category.displayName, tally)
                    }
                }
            }

            card(title: "STREAKS AND TIME") {
                infoRow(String(localized: "Current winning streak"), "\(stats.currentStreak)")
                infoRow(String(localized: "Best winning streak"), "\(stats.bestStreak)")
                infoRow(String(localized: "Two-player games"), "\(stats.twoPlayer)")
                infoRow(String(localized: "Time at the board"), ClockFormat.spoken(stats.totalTime))
                if stats.imported > 0 { infoRow(String(localized: "Imported games"), "\(stats.imported)") }
            }

            if stats.accuracyHistory.count > 1 {
                card(title: "ACCURACY") {
                    HStack {
                        Text("Average")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(stats.averageAccuracy.map { AccuracyFormat.percent($0) } ?? "—")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(Design.gold)
                    }
                    Sparkline(values: Array(stats.accuracyHistory.suffix(30)), tint: Design.gold)
                        .frame(height: 50)
                    Text("Your accuracy in the reviewed games, oldest on the left.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiaryText)
                }
            }
        }
        .padding(.top, 4)
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Design.gold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(caption)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .setupCard(selected: false)
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSectionTitle(title)
            VStack(spacing: 8) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .setupCard(selected: false, cornerRadius: 14)
        }
    }

    private func tallyRow(_ name: String, _ tally: ResultTally) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text("\(tally.wins) W · \(tally.draws) D · \(tally.losses) L", comment: "Wins, draws and losses")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            ResultBar(tally: tally)
                .frame(width: 60, height: 6)
        }
        // The tally in words: read from the text it was "3 W · 1 D · 2 L",
        // letters that mean nothing by ear. Combined still, so the row keeps
        // its texts' trait: made a bare element instead, a line of text was
        // held to the size of something to tap, and failed the audit.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue([
            String(localized: "\(tally.wins) wins", comment: "VoiceOver: games won, in a row of statistics"),
            String(localized: "\(tally.draws) draws", comment: "VoiceOver: games drawn, in a row of statistics"),
            String(localized: "\(tally.losses) losses", comment: "VoiceOver: games lost, in a row of statistics"),
        ].joined(separator: ", "))
    }

    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text(verbatim: value)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wins, draws and losses as one bar.
private struct ResultBar: View {
    let tally: ResultTally

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, tally.games)
            HStack(spacing: 0) {
                Rectangle().fill(MoveQuality.best.tint)
                    .frame(width: proxy.size.width * CGFloat(tally.wins) / CGFloat(total))
                Rectangle().fill(Color.white.opacity(0.4))
                    .frame(width: proxy.size.width * CGFloat(tally.draws) / CGFloat(total))
                Rectangle().fill(MoveQuality.blunder.tint)
            }
            .clipShape(Capsule())
            .opacity(tally.games == 0 ? 0.2 : 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Achievements

private struct AchievementsPanel: View {
    var body: some View {
        let unlocked = Achievements.shared.unlocked
        VStack(alignment: .leading, spacing: 12) {
            Text("\(unlocked.count) of \(Achievement.all.count) earned", comment: "Achievement progress")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Design.gold)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Achievement.all) { achievement in
                    let date = unlocked[achievement.id]
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: achievement.systemImage)
                            .scaledFont(22, relativeTo: .title3, weight: .semibold)
                            .foregroundStyle(date != nil ? Design.gold : .white.opacity(0.25))
                            .accessibilityHidden(true)
                        Text(achievement.title)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white.opacity(date != nil ? 1 : 0.55))
                        Text(achievement.detail)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(Design.gold.opacity(0.8))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .setupCard(selected: date != nil, cornerRadius: 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(date != nil
                        ? String(localized: "earned", comment: "Achievement state")
                        : String(localized: "not yet earned", comment: "Achievement state"))
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Banner

/// The note that slides in when an achievement is earned, wherever the
/// player happens to be.
struct AchievementBanner: View {
    let achievement: Achievement

    var body: some View {
        HStack(spacing: 12) {
            // Decoration: the title says what was earned, and the symbol's
            // name read in front of it only got in the way.
            Image(systemName: achievement.systemImage)
                .scaledFont(20, relativeTo: .title3, weight: .bold)
                .foregroundStyle(Color.black.opacity(0.8))
                .scaledFrame(36, relativeTo: .title3)
                .background(Circle().fill(Color.white.opacity(0.35)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Achievement earned")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.6))
                Text(achievement.title)
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.88))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Design.gold)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .padding(.horizontal, 20)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .combine)
    }
}
