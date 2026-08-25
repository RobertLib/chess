//
//  AppSettings.swift
//  chess
//
//  User settings and persistence of an unfinished game.
//

import SwiftUI

// MARK: - Game mode

enum GameMode: Hashable, Codable {
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
    private static let defaults = UserDefaults.standard

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

    /// Ids of the "How to Play" chapters the player has read to the end.
    private(set) var readTutorialChapters: Set<String> {
        didSet { Self.defaults.set(Array(readTutorialChapters), forKey: "readTutorialChapters") }
    }

    var theme: BoardTheme { BoardTheme.theme(id: themeID) }

    func markTutorialChapterRead(_ id: String) {
        guard !readTutorialChapters.contains(id) else { return }
        readTutorialChapters.insert(id)
    }

    init() {
        let defaults = Self.defaults
        themeID = defaults.string(forKey: "themeID") ?? "classic"
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        showLegalMoves = defaults.object(forKey: "showLegalMoves") as? Bool ?? true
        showCoordinates = defaults.object(forKey: "showCoordinates") as? Bool ?? true
        autoFlipBoard = defaults.object(forKey: "autoFlipBoard") as? Bool ?? false
        readTutorialChapters = Set(defaults.stringArray(forKey: "readTutorialChapters") ?? [])
        SoundManager.shared.isEnabled = soundsEnabled
        Haptics.isEnabled = hapticsEnabled
    }
}

// MARK: - Game store

/// Where the unfinished and the last finished game are kept. A variable
/// rather than `UserDefaults.standard` written inline so that tests can point
/// it at a scratch suite: a fuzz game played by a test has no business turning
/// up under "Continue" on the developer's simulator.
enum GameStore {
    static var defaults = UserDefaults.standard
}

// MARK: - Saved game

struct SavedGame: Codable {
    var mode: GameMode
    var initialFEN: String
    var moveUCIs: [String]
    var savedAt: Date

    private static let key = "savedGame"

    static func load() -> SavedGame? {
        guard let data = GameStore.defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedGame.self, from: data)
        else { return nil }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            GameStore.defaults.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        GameStore.defaults.removeObject(forKey: key)
    }

    /// Rebuilds the game by replaying the stored moves. Returns nil if the
    /// stored data no longer produces a valid game.
    func restoreGame() -> Game? {
        var game = Game(fen: initialFEN)
        for uci in moveUCIs {
            guard let move = game.legalMoves.first(where: { $0.uci == uci }) else { return nil }
            game.play(move)
        }
        return game
    }
}

// MARK: - Finished game

/// The last game that was played to a finish, kept so it can be reviewed
/// again from the menu.
struct FinishedGame: Codable {
    var mode: GameMode
    var initialFEN: String
    var moveUCIs: [String]
    var outcome: GameOutcome
    var finishedAt: Date

    private static let key = "finishedGame"

    init(game: Game, mode: GameMode) {
        self.mode = mode
        self.initialFEN = game.initialFEN
        self.moveUCIs = game.history.map(\.move.uci)
        self.outcome = game.outcome
        self.finishedAt = Date()
    }

    static func load() -> FinishedGame? {
        guard let data = GameStore.defaults.data(forKey: key),
              let finished = try? JSONDecoder().decode(FinishedGame.self, from: data)
        else { return nil }
        return finished
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            GameStore.defaults.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        GameStore.defaults.removeObject(forKey: key)
    }

    /// Replays the moves and restores how the game ended. Resignations and
    /// agreed draws leave no trace in the move list, so they are re-applied.
    func restoreGame() -> Game? {
        var game = Game(fen: initialFEN)
        for uci in moveUCIs {
            guard let move = game.legalMoves.first(where: { $0.uci == uci }) else { return nil }
            game.play(move)
        }
        switch outcome {
        case .resigned(let winner): game.resign(winner.opponent)
        case .drawAgreed: game.agreeToDraw()
        default: break
        }
        return game
    }
}
