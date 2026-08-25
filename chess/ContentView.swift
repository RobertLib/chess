//
//  ContentView.swift
//  chess
//
//  Root navigation: menu <-> game with smooth transitions.
//

import SwiftUI

struct ContentView: View {
    @State private var settings = AppSettings()
    @State private var gameModel: GameViewModel?
    @State private var reviewModel: GameReviewModel?

    var body: some View {
        ZStack {
            if let gameModel {
                GameView(
                    model: gameModel,
                    onExit: { exitToMenu() },
                    onNewGame: { mode in startGame(mode) },
                    onReview: { review(gameModel) }
                )
                .transition(Motion.transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 1.04)),
                    removal: .opacity
                )))
                .id(ObjectIdentifier(gameModel))
            } else {
                MenuView(
                    onStartGame: { mode in startGame(mode) },
                    onContinueGame: { saved in continueGame(saved) },
                    onReviewGame: { finished in reviewGame(finished) }
                )
                .transition(.opacity)
            }
        }
        .environment(settings)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $reviewModel) { review in
            GameReviewView(model: review) { reviewModel = nil }
                .environment(settings)
        }
        .onAppear {
            // Synthesizing the effects takes long enough to be felt, so it
            // happens in the background while the menu is on screen rather
            // than on the main thread at the first move of the first game.
            SoundManager.shared.prepare()
            handleLaunchArguments()
        }
    }

    private func startGame(_ mode: GameMode) {
        withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.1))) {
            gameModel?.teardown()
            gameModel = GameViewModel(mode: mode, settings: settings)
        }
    }

    private func continueGame(_ saved: SavedGame) {
        guard let game = saved.restoreGame() else {
            SavedGame.clear()
            return
        }
        withAnimation(Motion.meaningful(.spring(duration: 0.5, bounce: 0.1))) {
            gameModel?.teardown()
            gameModel = GameViewModel(mode: saved.mode, settings: settings, restoredGame: game)
        }
    }

    /// Opens the review of the game that has just been played.
    private func review(_ model: GameViewModel) {
        model.teardown()
        review(game: model.game, mode: model.mode)
    }

    /// Opens the review of a game that was finished earlier.
    private func reviewGame(_ finished: FinishedGame) {
        guard let game = finished.restoreGame() else {
            FinishedGame.clear()
            return
        }
        review(game: game, mode: finished.mode)
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
        let arguments = ProcessInfo.processInfo.arguments
        // A review reuses what an earlier one searched, so a test that wants
        // to watch the engine work has to say so — otherwise the second run of
        // it on the same simulator finds the report already finished and never
        // sees the progress it is checking for.
        if arguments.contains("--reset-analysis-cache") {
            AnalysisCache.clear()
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
            startGame(.vsAI(difficulty: difficulty, playerColor: color))
        } else if arguments.contains("--auto-game-2p") {
            startGame(.twoPlayer)
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
#endif
    }
}

#Preview {
    ContentView()
}
