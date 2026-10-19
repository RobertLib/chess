//
//  AppSettings.swift
//  chess
//
//  User settings and persistence of an unfinished game.
//

import SwiftUI

// MARK: - Game mode

/// Nonisolated, like the engine's types, so that a record can be written out
/// as PGN away from the main actor (see `GameRecord.pgn`).
nonisolated enum GameMode: Hashable, Codable, Sendable {
    case twoPlayer
    case vsAI(difficulty: AIDifficulty, playerColor: PieceColor)

    var isVsAI: Bool {
        if case .vsAI = self { return true }
        return false
    }

    /// The human's color in AI games (nil in two-player mode).
    var humanColor: PieceColor? {
        if case .vsAI(_, let color) = self { return color }
        return nil
    }
}

// MARK: - Settings

@Observable
@MainActor
final class AppSettings {
    /// The same swappable store the saved games use, so a test that turns a
    /// setting off cannot leave it off in the real app. Reading it through
    /// `LocalStore` rather than holding `UserDefaults.standard` here is what
    /// makes that true: the store is a `var`, so pointing it at a scratch
    /// suite redirects the settings along with everything else.
    private static var defaults: UserDefaults { LocalStore.defaults }

    var themeID: String {
        didSet { Self.defaults.set(themeID, forKey: "themeID") }
    }
    var soundsEnabled: Bool {
        didSet {
            Self.defaults.set(soundsEnabled, forKey: "soundsEnabled")
            SoundManager.shared.isEnabled = soundsEnabled
        }
    }
    var hapticsEnabled: Bool {
        didSet {
            Self.defaults.set(hapticsEnabled, forKey: "hapticsEnabled")
            Haptics.isEnabled = hapticsEnabled
        }
    }
    var showLegalMoves: Bool {
        didSet { Self.defaults.set(showLegalMoves, forKey: "showLegalMoves") }
    }
    var showCoordinates: Bool {
        didSet { Self.defaults.set(showCoordinates, forKey: "showCoordinates") }
    }
    /// Rotate the board towards the player on turn in two-player games.
    var autoFlipBoard: Bool {
        didSet { Self.defaults.set(autoFlipBoard, forKey: "autoFlipBoard") }
    }
    /// Let the player queue a move while the computer is thinking.
    var premovesEnabled: Bool {
        didSet { Self.defaults.set(premovesEnabled, forKey: "premovesEnabled") }
    }

    // MARK: Remembered setups

    /// The clock last chosen against the computer, so the next game is set up
    /// the way the last one was. Nil is a real choice — no clock.
    var aiTimeControl: TimeControl? {
        didSet { Self.store(aiTimeControl, forKey: "aiTimeControl") }
    }
    /// The same for two players on one device.
    var twoPlayerTimeControl: TimeControl? {
        didSet { Self.store(twoPlayerTimeControl, forKey: "twoPlayerTimeControl") }
    }
    /// The last setting of the stand-alone chess clock.
    var standaloneTimeControl: TimeControl {
        didSet { Self.store(standaloneTimeControl, forKey: "standaloneTimeControl") }
    }
    /// Two players facing each other across a device lying flat.
    var tabletopMode: Bool {
        didSet { Self.defaults.set(tabletopMode, forKey: "tabletopMode") }
    }
    /// The rest of the menu's last setup: level, side, start and rules.
    var menuSetup: MenuSetup {
        didSet { if menuSetup != oldValue { Self.store(menuSetup, forKey: "menuSetup") } }
    }

    /// Where the adaptive opponent currently stands, on the 0...4 scale of
    /// `AIStrength.interpolated` — Beginner to Grandmaster. It starts between
    /// Easy and Medium, which is where most people who pick it turn out to be.
    var adaptiveLevel: Double {
        didSet { Self.defaults.set(adaptiveLevel, forKey: "adaptiveLevel") }
    }

    /// Moves the adaptive opponent after a game against it: up after the
    /// player wins, down after they lose. A draw holds it where it is — the
    /// step is scaled by how far the score is from an even one — but counts
    /// as a game played all the same. The steps shrink with every game
    /// played, so the level settles instead of swinging between two levels.
    func recordAdaptiveResult(playerScore: Double) {
        let played = Self.defaults.integer(forKey: "adaptiveGames")
        let step = max(0.12, 0.45 / (1 + Double(played) / 4))
        adaptiveLevel = min(4, max(0, adaptiveLevel + (playerScore - 0.5) * 2 * step))
        Self.defaults.set(played + 1, forKey: "adaptiveGames")
        Achievements.shared.adaptiveLevelReached(adaptiveLevel)
    }

    /// Ids of the "How to Play" chapters the player has read to the end.
    private(set) var readTutorialChapters: Set<String> {
        didSet { Self.defaults.set(Array(readTutorialChapters), forKey: "readTutorialChapters") }
    }

    var theme: BoardTheme { BoardTheme.theme(id: themeID) }

    func markTutorialChapterRead(_ id: String) {
        if !readTutorialChapters.contains(id) { readTutorialChapters.insert(id) }
        noteLessonsRead()
    }

    /// Hands the chapters read to Graduate: as each is read to the end, and
    /// at launch. Looked at only when a chapter was read for the first time,
    /// as it used to be, Graduate was out of reach for a player who had read
    /// all nine under 1.0, before there was anything to earn: every chapter
    /// left for them to read was one already read. Counted against the
    /// chapters there are, so an id left over from a chapter since dropped
    /// makes up for none. Earned once, it is not announced again.
    private func noteLessonsRead() {
        let read = TutorialGuide.chapters.count { readTutorialChapters.contains($0.id) }
        Achievements.shared.lessonsRead(read, of: TutorialGuide.chapters.count)
    }

    init() {
        let defaults = Self.defaults
        themeID = defaults.string(forKey: "themeID") ?? "classic"
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        showLegalMoves = defaults.object(forKey: "showLegalMoves") as? Bool ?? true
        showCoordinates = defaults.object(forKey: "showCoordinates") as? Bool ?? true
        autoFlipBoard = defaults.object(forKey: "autoFlipBoard") as? Bool ?? false
        premovesEnabled = defaults.object(forKey: "premovesEnabled") as? Bool ?? true
        aiTimeControl = Self.load(TimeControl.self, forKey: "aiTimeControl")
        twoPlayerTimeControl = Self.load(TimeControl.self, forKey: "twoPlayerTimeControl")
        standaloneTimeControl = Self.load(TimeControl.self, forKey: "standaloneTimeControl")
            ?? .minutes(5, plus: 3)
        tabletopMode = defaults.object(forKey: "tabletopMode") as? Bool ?? false
        menuSetup = Self.load(MenuSetup.self, forKey: "menuSetup") ?? MenuSetup()
        adaptiveLevel = defaults.object(forKey: "adaptiveLevel") as? Double ?? 1.5
        readTutorialChapters = Set(defaults.stringArray(forKey: "readTutorialChapters") ?? [])
        SoundManager.shared.isEnabled = soundsEnabled
        Haptics.isEnabled = hapticsEnabled
        noteLessonsRead()
    }

    /// A Codable setting as JSON. Nil removes the key, so "no clock" reads
    /// back as nil rather than as whatever was there before.
    private static func store<Value: Encodable>(_ value: Value?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Local store

/// Everything the app keeps between launches: the preferences, the unfinished
/// game and the small stores in `defaults`, the archive and the other large
/// ones in `files` (see `FileStore`). Variables rather than
/// `UserDefaults.standard` written inline so that tests can point them at a
/// scratch store: a fuzz game played by a test has no business turning up
/// under "Continue" on the developer's simulator, and neither has a setting a
/// test switched off.
enum LocalStore {
    /// Swapped only by the tests. The writes still on their way to the store
    /// being swapped out land first, so that a test's last save cannot turn
    /// up after the test has emptied its suite — or in the next test to open
    /// the same one. The files go with it (see `FileStore.paired`).
    static var defaults = UserDefaults.standard {
        willSet { flush() }
        didSet { files = FileStore.paired(with: defaults) }
    }

    /// Set by swapping `defaults`; a test that wants a directory of its own
    /// choosing sets this after that.
    static var files = FileStore.standard {
        willSet { flush() }
    }

    /// Waits until every write asked for in the background has landed.
    static func flush() {
        writer.sync {}
    }

    /// Where the writes go, one after another, off the main thread.
    static let writer = DispatchQueue(label: "cz.rob.chess.localStore", qos: .utility)

    /// The store, carried to `writer`. `UserDefaults` is documented as safe
    /// to use from any thread; this only tells the compiler so.
    nonisolated struct Destination: @unchecked Sendable {
        let store: UserDefaults
    }

    /// A stored list, read entry by entry, so that an entry this build cannot
    /// read — damaged, or written by a later version — costs only itself.
    /// Read as a whole, one bad entry made the whole list read as empty, and
    /// the next save wrote that over everything that had been there.
    ///
    /// Whenever anything is left out, the data as stored is copied aside
    /// first (see `setAside`), because the next save will not include it.
    static func list<Element: Decodable>(of type: Element.Type, inFile name: String) -> [Element] {
        guard let data = data(inFile: name) else { return [] }
        let decoded = entries(of: type, in: data)
        if !decoded.isComplete { setAside(data, forKey: name) }
        return decoded.read
    }

    /// The entries of the file `name` missing from `list`, if the file did not
    /// read the last time it was read and reads now; nil if it read then, or
    /// still does not.
    ///
    /// A store whose file did not read keeps what is added to it in memory,
    /// and the file turns every write away until it reads (see
    /// `FileStore.write`). Nothing added meanwhile was ever written, and the
    /// next launch read the file back without it — a whole session's games,
    /// and the mistakes collected from them. A store adds what this returns
    /// to its next save, so the file is written with both.
    static func entriesMissing<Element: Decodable, ID: Hashable>(
        from list: [Element], inFile name: String, id: (Element) -> ID
    ) -> [Element]? {
        guard files.isUnread(name) else { return nil }
        let filed = self.list(of: Element.self, inFile: name)
        guard !files.isUnread(name) else { return nil }
        let ids = Set(list.map(id))
        return filed.filter { !ids.contains(id($0)) }
    }

    /// The entries of a stored list that read, and whether they were all of
    /// them — false, too, for data that is no list at all. Nonisolated, so
    /// that a list too large to decode on the main actor can be decoded on
    /// the writer (see `listInBackground`).
    nonisolated static func entries<Element: Decodable>(
        of type: Element.Type, in data: Data
    ) -> (read: [Element], isComplete: Bool) {
        guard let entries = try? JSONDecoder().decode([Lossy<Element>].self, from: data) else {
            return ([], false)
        }
        let read = entries.compactMap(\.value)
        return (read, read.count == entries.count)
    }

    /// A stored value, or nil when there is none. One that is there but does
    /// not decode is copied aside before nil is returned, for the same reason
    /// as in `list(of:inFile:)`: the caller starts again from scratch, and its
    /// first save would otherwise be the end of it.
    static func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        decoded(type, from: defaults.data(forKey: key), setAsideAs: key)
    }

    /// The same for a store kept in a file.
    static func value<Value: Decodable>(_ type: Value.Type, inFile name: String) -> Value? {
        decoded(type, from: data(inFile: name), setAsideAs: name)
    }

    private static func decoded<Value: Decodable>(
        _ type: Value.Type, from data: Data?, setAsideAs key: String
    ) -> Value? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            setAside(data, forKey: key)
            return nil
        }
    }
}

/// One entry of a stored list or dictionary, or nil when that entry does not
/// decode. Decoding it never fails, so the entries around a bad one still do.
/// Nonisolated, so that a store's own nonisolated decoding can use it too.
nonisolated struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Saved game

struct SavedGame: Codable {
    var mode: GameMode
    var initialFEN: String
    var moveUCIs: [String]
    var savedAt: Date
    /// Optional, like the three below, so that a game saved by an older build —
    /// which wrote none of them — still decodes, as a game without a clock.
    var options: GameOptions?
    /// The clock as it stood when the game was saved, paused.
    var clock: ChessClock?
    /// Seconds spent on each move so far, one entry per ply.
    var moveTimes: [TimeInterval]?
    /// Seconds already spent on the move in progress, by the stopwatch that
    /// times each move (see `GameViewModel.moveTimes`). The clock keeps its
    /// own share of the turn; without this the stopwatch began again from
    /// nothing on Continue, and a move thought over for two minutes before
    /// the app was closed went down as the seconds after it was opened —
    /// two minutes short of what the clock had charged for it.
    var moveElapsed: TimeInterval?

    private static let key = "savedGame"

    /// The unfinished game, or nil when there is none. One that is stored but
    /// does not read is copied aside first (see `LocalStore.value`): there is
    /// no "Continue" for it, and the next game begun saves itself over it.
    ///
    /// Nil, too, once the game has been cleared, although it may still be
    /// stored (see `clear`): its game is over and in the archive, and Continue
    /// would offer it again a move short of its end.
    static func load() -> SavedGame? {
        guard !LocalStore.isWithdrawn(key) else { return nil }
        return LocalStore.value(SavedGame.self, forKey: key)
    }

    /// Saving calls off a clear still waiting to go (see `clear`), so that a
    /// game begun the moment the last one ended is not cleared along with it.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            LocalStore.set(data, forKey: Self.key)
        }
    }

    /// Clears the game once the archive holds it, not before. The archive is
    /// written in the background, and cleared at once, a game that had just
    /// ended was lost from both stores whenever the app was ended before that
    /// write — or the write did not land at all. Should it not land, the game
    /// stays saved for the next launch. See `LocalStore.remove(_:onceFiled:)`.
    static func clear() {
        LocalStore.remove(key, onceFiled: GameArchive.key)
    }

    /// Rebuilds the game by replaying the stored moves. Returns nil if the
    /// stored data no longer produces a valid game.
    func restoreGame() -> Game? {
        var game = Game(fen: initialFEN, variant: options?.variant ?? .standard)
        for uci in moveUCIs {
            guard let move = game.legalMoves.first(where: { $0.uci == uci }) else { return nil }
            game.play(move)
        }
        return game
    }

    /// The game for "Continue", or nil when its moves no longer replay. Such
    /// a game is dropped, so that Continue stops offering it — but copied
    /// aside first (see `LocalStore.setAside`), as a save that does not decode
    /// is: a later build may be able to replay it, and it was simply deleted.
    func restoreForContinue() -> Game? {
        if let game = restoreGame() { return game }
        if let data = LocalStore.defaults.data(forKey: Self.key) {
            LocalStore.setAside(data, forKey: Self.key)
        }
        Self.clear()
        return nil
    }
}

extension SavedGame {
    // Field by field, in an extension so the memberwise initializer stays.
    // The clock is read the way `GameOptions` reads its time control —
    // leniently. Read strictly, a clock this build could not make out (after
    // a change to `TimeControl`, say) took the whole game with it, and
    // Continue was gone; the moves are what matter.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(GameMode.self, forKey: .mode)
        initialFEN = try container.decode(String.self, forKey: .initialFEN)
        moveUCIs = try container.decode([String].self, forKey: .moveUCIs)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        options = try container.decodeIfPresent(GameOptions.self, forKey: .options)
        clock = try? container.decodeIfPresent(ChessClock.self, forKey: .clock)
        moveTimes = try? container.decodeIfPresent([TimeInterval].self, forKey: .moveTimes)
        moveElapsed = try? container.decodeIfPresent(TimeInterval.self, forKey: .moveElapsed)
        // A timed game whose clock is lost goes on without one, moves and all.
        // A fresh clock would be no substitute: a clock starts with the first
        // move, and with that long played it would sit at the starting time
        // and never run.
        if clock == nil, !moveUCIs.isEmpty { options?.timeControl = nil }
    }
}

// MARK: - Finished game

/// The last game that was played to a finish, as 1.0 kept it so it could be
/// reviewed again from the menu. The archive has done that job since 1.0.1;
/// what is left here reads the old key once and moves the game across.
struct FinishedGame: Codable {
    var mode: GameMode
    var initialFEN: String
    var moveUCIs: [String]
    var outcome: GameOutcome
    var finishedAt: Date
    var options: GameOptions?
    var moveTimes: [TimeInterval]?
    /// The clock faces at the end, `[white, black]`, for a game on the clock.
    var finalClock: [TimeInterval]?

    private static let key = "finishedGame"

    init(
        game: Game, mode: GameMode, options: GameOptions = .standard,
        moveTimes: [TimeInterval] = [], finalClock: [TimeInterval]? = nil
    ) {
        self.mode = mode
        self.initialFEN = game.initialFEN
        self.moveUCIs = game.history.map(\.move.uci)
        self.outcome = game.outcome
        self.finishedAt = Date()
        self.options = options
        self.moveTimes = moveTimes
        self.finalClock = finalClock
    }

    static func load() -> FinishedGame? {
        guard let data = LocalStore.defaults.data(forKey: key),
              let finished = try? JSONDecoder().decode(FinishedGame.self, from: data)
        else { return nil }
        return finished
    }

    static func clear() {
        LocalStore.defaults.removeObject(forKey: key)
    }

    /// Files the game 1.0 kept under its own key into the archive, unless it
    /// is there already, and drops the key. Without it, the one game a 1.0
    /// player could review again would be gone after the update.
    ///
    /// The key is dropped only once the game has been replayed. One that does
    /// not read, or no longer replays, is copied aside before it goes (see
    /// `LocalStore.setAside`) — dropped first, as it was, such a game was
    /// lost for good — and dropped all the same, so that the menu does not
    /// try it again at every launch.
    ///
    /// A game that is filed is dropped once the archive holds it, the way
    /// `SavedGame.clear` drops an unfinished one: dropped at once, a write
    /// that did not land lost it from both stores. Kept, it is filed at the
    /// next launch instead — and only once, as the archive is asked first.
    static func migrateToArchive() {
        guard let data = LocalStore.defaults.data(forKey: key) else { return }
        guard let finished = try? JSONDecoder().decode(FinishedGame.self, from: data),
              let game = finished.restoreGame()
        else {
            LocalStore.setAside(data, forKey: key)
            clear()
            return
        }
        let archive = GameArchive.shared
        guard !finished.moveUCIs.isEmpty, !archive.records.contains(where: {
            $0.initialFEN == finished.initialFEN && $0.moveUCIs == finished.moveUCIs
        }) else {
            clear()
            return
        }
        archive.add(contentsOf: [GameRecord(
            game: game, mode: finished.mode, options: finished.options ?? .standard,
            moveTimes: finished.moveTimes ?? [], finalClock: finished.finalClock,
            finishedAt: finished.finishedAt
        )])
        LocalStore.remove(key, onceFiled: GameArchive.key)
    }

    /// Replays the moves and restores how the game ended. Resignations and
    /// agreed draws leave no trace in the move list, so they are re-applied.
    func restoreGame() -> Game? {
        var game = Game(fen: initialFEN, variant: options?.variant ?? .standard)
        for uci in moveUCIs {
            guard let move = game.legalMoves.first(where: { $0.uci == uci }) else { return nil }
            game.play(move)
        }
        switch outcome {
        case .resigned(let winner): game.resign(winner.opponent)
        case .drawAgreed: game.agreeToDraw()
        // A flag falls for the side on move, so replaying the moves leaves
        // exactly that side on turn and `timeOut` reaches the same verdict.
        case .timeForfeit, .drawTimeoutInsufficientMaterial: game.timeOut()
        default: break
        }
        return game
    }
}
