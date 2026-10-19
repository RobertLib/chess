//
//  ContentView.swift
//  chess
//
//  Root navigation: menu <-> game with smooth transitions.
//

import Combine
import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var settings = AppSettings()
    @State private var gameModel: GameViewModel?
    @State private var reviewModel: GameReviewModel?
    /// Set by a tap on the daily-puzzle widget.
    @State private var showDailyPuzzle = false
    /// Bumped to close every page the menu or the game has presented — see
    /// `openDailyPuzzle`.
    @State private var presentationReset = 0
    @State private var dailyPuzzleOpening = DailyPuzzleOpening()

    var body: some View {
        ZStack {
            if let gameModel {
                GameView(
                    model: gameModel,
                    onExit: { exitToMenu() },
                    onNewGame: { mode, options in startGame(mode, options: options) },
                    onReview: { review(gameModel) }
                )
                .transition(Motion.transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 1.04)),
                    removal: .opacity
                )))
                .id(ObjectIdentifier(gameModel))
            } else {
                MenuView(
                    onStartGame: { mode, options in startGame(mode, options: options) },
                    onContinueGame: { saved in continueGame(saved) }
                )
                .transition(.opacity)
            }
        }
        .environment(settings)
        .environment(\.presentationReset, presentationReset)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $reviewModel) { review in
            GameReviewView(model: review) { reviewModel = nil }
                .environment(settings)
        }
        .fullScreenCover(isPresented: $showDailyPuzzle) {
            // Everything else has been closed to make room for it, so the
            // way back leads to the menu or to the game — not to the puzzles.
            PuzzleView(
                kind: .daily,
                backLabel: gameModel == nil ? "Back to menu" : "Back to the game",
                onClose: { showDailyPuzzle = false }
            )
            .environment(settings)
        }
        // The widget opens the app on the day's puzzle.
        .onOpenURL { url in
            guard url.host() == "puzzle" else { return }
            openDailyPuzzle()
        }
        .onChange(of: showDailyPuzzle) { _, shown in
            if !shown { gameModel?.coverDidDisappear() }
        }
        // The widget's timeline is drawn up with the midnights of the time
        // zone it was made in. A new zone, or the clock set by hand, would
        // leave it changing puzzle at the wrong hour — a different one from
        // the app's — until WidgetKit next asked for it on its own.
        .onDayChange { WidgetCenter.shared.reloadAllTimelines() }
        .onAppear {
            // 1.0 kept the last finished game under a key of its own.
            FinishedGame.migrateToArchive()
            // Synthesizing the effects takes long enough to be felt, so it
            // happens in the background while the menu is on screen rather
            // than on the main thread at the first move of the first game.
            SoundManager.shared.prepare()
            // Achievements are announced from a window of their own, above
            // whatever page is presented when one is earned.
            AchievementPresenter.shared.install()
            handleLaunchArguments()
        }
    }

    /// Presents the day's puzzle over whatever is on screen. Only one page
    /// can be presented from a view controller at a time, and the root
    /// already presenting Puzzles, My Games or the game's settings used to
    /// leave the widget's tap with nothing to show. So everything open is
    /// closed first, and the puzzle follows once the last of it has gone
    /// (see `DailyPuzzleOpening`).
    private func openDailyPuzzle() {
        guard !showDailyPuzzle else { return }
        // A game in progress is held for as long as the puzzle covers it, so
        // that no clock runs under the puzzle — including one the computer's
        // first move would start while the player is solving it.
        gameModel?.coverDidAppear()
        reviewModel = nil
        presentationReset += 1
        dailyPuzzleOpening.start(
            isShowing: { showDailyPuzzle },
            present: { showDailyPuzzle = true },
            // Still covered: the cover could not be put up, and asking for it
            // anyway left the flag set with nothing on screen — which the
            // guard above then read as the puzzle already showing, turning
            // every later tap on the widget away. Give up on this tap instead
            // and let the game run again; the next one starts afresh.
            giveUp: { gameModel?.coverDidDisappear() }
        )
    }

    private func startGame(_ mode: GameMode, options: GameOptions = .standard) {
        withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.1))) {
            gameModel?.teardown()
            gameModel = GameViewModel(mode: mode, settings: settings, options: options)
        }
    }

    /// Opens the saved game, or returns false when its moves no longer
    /// replay — the save is set aside and gone, and the menu says so.
    private func continueGame(_ saved: SavedGame) -> Bool {
        guard let game = saved.restoreForContinue() else { return false }
        withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.1))) {
            gameModel?.teardown()
            gameModel = GameViewModel(
                mode: saved.mode, settings: settings, restoredGame: game,
                options: saved.options ?? .standard,
                restoredClock: saved.clock, restoredMoveTimes: saved.moveTimes,
                restoredMoveElapsed: saved.moveElapsed
            )
        }
        return true
    }

    /// Opens the review of the game that has just been played.
    private func review(_ model: GameViewModel) {
        model.teardown()
        reviewModel = GameReviewModel(
            game: model.game, mode: model.mode, options: model.options,
            moveTimes: model.moveTimes, recordID: GameArchive.shared.latest?.id
        )
    }

    private func review(game: Game, mode: GameMode) {
        reviewModel = GameReviewModel(game: game, mode: mode)
    }

    private func exitToMenu() {
        withAnimation(Motion.meaningful(.easeInOut(duration: 0.35))) {
            gameModel?.teardown()
            gameModel = nil
        }
    }

    /// Development helper: `--auto-game` jumps straight into a game so the
    /// screen can be captured from the command line.
    private func handleLaunchArguments() {
#if DEBUG
        let arguments = LaunchArguments.once(for: "root")
        // A review reuses what an earlier one searched, so a test that wants
        // to watch the engine work has to say so — otherwise the second run of
        // it on the same simulator finds the report already finished and never
        // sees the progress it is checking for.
        if arguments.contains("--reset-analysis-cache") {
            AnalysisCache.clear()
        }
        // Shows the achievement banner without earning anything, to check it
        // lands above whatever page is open.
        if arguments.contains("--demo-achievement") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                Achievements.shared.justUnlocked.append(Achievement.definition(.firstPuzzle))
            }
        }
        if let aiArg = arguments.first(where: { $0 == "--auto-game-ai" || $0.hasPrefix("--auto-game-ai=") }) {
            // `--auto-game-ai=expert:black` picks the level and the side to
            // capture from; bare, it stays the Medium-as-White game every
            // caller of this argument has always got. The level matters
            // because only the two above Medium open out of `OpeningBook`,
            // and playing Black is what makes the computer move first.
            // Both splits are written the long way round because `split`
            // drops empty pieces by default, and every interesting typo here
            // is an empty piece: `--auto-game-ai=` would leave `[1]` off the
            // end of a one-element array, and `=:black` would collapse to
            // `["black"]`, whose first element is read as the level — so the
            // colour was dropped and the game came up as White.
            let spec = aiArg.split(separator: "=", maxSplits: 1)
                .dropFirst().first.map(String.init) ?? ""
            let parts = spec
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            let difficulty = parts.first.flatMap(AIDifficulty.init(rawValue:)) ?? .medium
            let color: PieceColor = parts.count > 1 && parts[1] == "black" ? .black : .white
            startGame(.vsAI(difficulty: difficulty, playerColor: color), options: debugOptions(arguments))
        } else if arguments.contains("--auto-game-2p") {
            startGame(.twoPlayer, options: debugOptions(arguments))
        }
        if let fenArg = arguments.first(where: { $0.hasPrefix("--fen=") }) {
            let fen = String(fenArg.dropFirst("--fen=".count))
            withAnimation(nil) {
                gameModel?.teardown()
                gameModel = GameViewModel(mode: .twoPlayer, settings: settings, restoredGame: Game(fen: fen))
            }
        }
        if let reviewArg = arguments.first(where: { $0.hasPrefix("--review-script=") }) {
            // Builds a finished game from UCI moves and opens its review, so
            // the review screen can be captured from the command line.
            var game = Game()
            for uci in String(reviewArg.dropFirst("--review-script=".count)).split(separator: ",") {
                guard let move = game.legalMoves.first(where: { $0.uci.hasPrefix(uci) }) else { break }
                game.play(move)
            }
            review(game: game, mode: .vsAI(difficulty: .medium, playerColor: .white))
        }
        if let scriptArg = arguments.first(where: { $0.hasPrefix("--script=") }) {
            let moves = String(scriptArg.dropFirst("--script=".count))
                .split(separator: ",").map(String.init)
            // One move a second suits a screenshot, where the wait is dead
            // time; an App Preview wants a game it can get through inside
            // twenty seconds. Anything unparseable — or zero, which would spin
            // the loop — falls back to the second the callers have always got.
            let interval = arguments
                .first { $0.hasPrefix("--script-interval=") }
                .flatMap { Double($0.dropFirst("--script-interval=".count)) }
                .flatMap { $0 > 0 ? $0 : nil } ?? 1.0
            gameModel?.playScriptedMoves(moves, interval: interval)
        }
        // Stands in for a tap on the widget, which a UI test cannot reach on
        // the home screen: it lands in `openDailyPuzzle`, as the widget's
        // `chessoffline://` link does through `onOpenURL`.
        if arguments.contains("--widget-tap") {
            openDailyPuzzle()
        }
#endif
    }
}

/// The wait between a tap on the daily-puzzle widget and the puzzle going
/// up: for every page presented over the root to close first, then the
/// puzzle — or, when one will not close, the tap given up.
///
/// One wait at a time. A second tap while the first is still waiting takes
/// its place, and the first does nothing more. Each used to wait on its own:
/// the first put the puzzle up, and the second, still waiting for nothing to
/// be presented — the puzzle now was — gave up two seconds later and let the
/// game go on under the puzzle, the stopwatch counting the time spent on it
/// and a timed game's clock free to start.
@MainActor
final class DailyPuzzleOpening {
    private let somethingIsPresented: () -> Bool
    private let pollInterval: Duration
    private let polls: Int
    private var task: Task<Void, Never>?

    /// Two seconds of looking, by default, is far longer than any dismissal;
    /// the limit is there so a presentation nobody can close does not keep
    /// the wait alive. The tests swap the presentation for one of their own.
    init(
        pollInterval: Duration = .milliseconds(50), polls: Int = 40,
        somethingIsPresented: @escaping () -> Bool = { DailyPuzzleOpening.rootIsPresenting }
    ) {
        self.pollInterval = pollInterval
        self.polls = polls
        self.somethingIsPresented = somethingIsPresented
    }

    /// Whether a tap is still waiting for the way to clear.
    var isWaiting: Bool { task != nil }

    /// Waits for the way to clear, then calls `present` — or `giveUp`, if
    /// something is still presented when the wait runs out. Neither, when
    /// `isShowing` says the puzzle is up already: the game stays held under
    /// it, and is let go when it closes.
    func start(
        isShowing: @escaping () -> Bool,
        present: @escaping () -> Void,
        giveUp: @escaping () -> Void
    ) {
        task?.cancel()
        let somethingIsPresented = somethingIsPresented
        let pollInterval = pollInterval
        let polls = polls
        task = Task { [weak self] in
            for _ in 0..<polls {
                guard somethingIsPresented(), !Task.isCancelled else { break }
                try? await Task.sleep(for: pollInterval)
            }
            // Replaced by a later tap, which holds the game in its turn.
            guard !Task.isCancelled else { return }
            self?.task = nil
            guard !isShowing() else { return }
            guard !somethingIsPresented() else {
                giveUp()
                return
            }
            present()
        }
    }

    static var rootIsPresenting: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}

#if DEBUG
/// `--time=3+2` puts the debug game on a clock, `--start=960` (or
/// `--start=960:412`, `--start=odds:queen`) changes where it starts,
/// `--variant=koth` or `--variant=threecheck` the rules, and `--tabletop`
/// lays a two-player game out face to face.
private func debugOptions(_ arguments: [String]) -> GameOptions {
    var options = GameOptions()
    if let time = arguments.first(where: { $0.hasPrefix("--time=") }) {
        let parts = time.dropFirst("--time=".count).split(separator: "+")
        if let minutes = parts.first.flatMap({ Double($0) }) {
            options.timeControl = .minutes(minutes, plus: parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        }
    }
    if let start = arguments.first(where: { $0.hasPrefix("--start=") }) {
        let spec = start.dropFirst("--start=".count).split(separator: ":")
        switch spec.first {
        case "960":
            let number = spec.count > 1 ? Int(spec[1]) ?? Chess960.randomNumber() : Chess960.randomNumber()
            options.start = .chess960(number: number)
        case "odds":
            let handicap = spec.count > 1 ? Handicap(rawValue: String(spec[1])) ?? .knight : .knight
            options.start = .handicap(handicap, giver: .black)
        default:
            break
        }
    }
    options.tabletop = arguments.contains("--tabletop")
    if let variant = arguments.first(where: { $0.hasPrefix("--variant=") }) {
        options.variant = PGN.variant(named: String(variant.dropFirst("--variant=".count)))
    }
    return options
}
#endif

extension EnvironmentValues {
    /// Changes whenever every page presented from the menu or the game is to
    /// close, so the daily puzzle can be presented in their place.
    @Entry var presentationReset = 0
}

extension View {
    /// Runs `action` whenever the day may have turned into another under the
    /// app: at midnight, when the clock is set by hand, when the phone moves
    /// to another time zone. A suspended app is told about any of these it
    /// slept through as it wakes, so they are noticed on the way back too.
    func onDayChange(perform action: @escaping () -> Void) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )) { _ in action() }
            .onReceive(NotificationCenter.default.publisher(
                for: .NSSystemTimeZoneDidChange
            ).receive(on: DispatchQueue.main)) { _ in
                // Foundation keeps the zone it first read until it is told
                // to look again, and "today" is worked out in it.
                NSTimeZone.resetSystemTimeZone()
                action()
            }
    }
}

#Preview {
    ContentView()
}
