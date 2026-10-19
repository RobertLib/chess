//
//  MenuUITests.swift
//  chessUITests
//
//  What the menu does between games: guarding the unfinished game under
//  "Continue" from a stray tap on a new-game button.
//

import XCTest

@MainActor
final class MenuUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func square(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", label))
            .firstMatch
    }

    /// Starting a new game replaces the unfinished one, and a game screen saves
    /// itself the moment it opens. One tap on "Two Players" used to do that
    /// silently; now the menu asks first, and only when there is something to
    /// lose — a game with moves in it.
    ///
    /// The question now comes from the setup's Start Game button rather than
    /// from the menu row, since a two-player game has a setup screen of its
    /// own.
    func testStartingANewGameOverAnUnfinishedOneAsksFirst() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--auto-game-2p", "--script=e2e4",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        // The scripted move is what makes the saved game worth protecting.
        XCTAssertTrue(square(app, "e 4, white pawn").waitForExistence(timeout: 15),
                      "the scripted move was never played")

        app.buttons["Back to menu"].tap()
        let twoPlayers = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Two Players"))
            .firstMatch
        XCTAssertTrue(twoPlayers.waitForExistence(timeout: 10))
        twoPlayers.tap()
        // Two players now pick a clock and a starting position first; the
        // guard sits on the button that actually starts the game.
        let start = app.buttons["Start Game"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start New Game"].exists, "opening the setup must not ask anything yet")
        start.tap()

        let confirm = app.buttons["Start New Game"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the menu should ask before replacing an unfinished game")
        XCTAssertFalse(app.otherElements["Chessboard"].exists, "the game must not start until confirmed")
        confirm.tap()

        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(square(app, "e 2, white pawn").waitForExistence(timeout: 5),
                      "confirming should start a fresh game, not continue the old one")
    }

    /// An achievement's banner is drawn in a window of its own, above every
    /// page, for the few seconds it is up. That window must take only the
    /// touches that land on the banner: the page underneath stays usable, and
    /// the banner itself still goes away when it is tapped.
    ///
    /// The banner is held up for twenty seconds here. At the usual three, a
    /// slow simulator could spend them on the tap through to the menu, and
    /// the test failed either way round — the banner gone before it was
    /// tapped, or the timer and the tap too close to tell apart.
    func testTheAchievementBannerTakesOnlyTheTouchesOnIt() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-achievement", "--banner-seconds=20",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()

        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Puzzle Solver"))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the demo banner never came up")

        // A coordinate tap, so the test asks what the window does with the
        // touch rather than whether XCUITest thinks the button is hittable.
        let twoPlayers = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Two Players"))
            .firstMatch
        twoPlayers.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 2),
                      "a tap on the menu under the banner's window never reached the menu")
        XCTAssertTrue(banner.exists, "the banner had gone before the tap; the test proved nothing")

        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5),
                      "a tap on the banner should put it away long before its time is up")
    }

    /// The same question for a game started from Training. "Play" there closes
    /// the training pages on its way out, and the question waits until they
    /// have gone: put while they are still sliding away, it is not certain to
    /// be shown at all, and the game asked for would never start.
    func testPlayingFromTrainingOverAnUnfinishedGameAsksFirst() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--auto-game-2p", "--script=e2e4",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(square(app, "e 4, white pawn").waitForExistence(timeout: 15),
                      "the scripted move was never played")

        app.buttons["Back to menu"].tap()
        let training = app.buttons["Training"]
        XCTAssertTrue(training.waitForExistence(timeout: 10))
        training.tap()
        let analysis = app.buttons["Analysis Board"]
        XCTAssertTrue(analysis.waitForExistence(timeout: 10))
        analysis.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.navigationBars["Play from Here"].waitForExistence(timeout: 5))
        // The menu's own "Two Players" is still in the tree under the training
        // pages; the one in the sheet is the one on screen.
        let twoPlayers = app.buttons
            .matching(NSPredicate(format: "label == %@", "Two Players"))
            .allElementsBoundByIndex
            .first { $0.isHittable }
        XCTAssertNotNil(twoPlayers, "the sheet should offer a two-player game")
        twoPlayers?.tap()

        let confirm = app.buttons["Start New Game"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the menu should ask before replacing an unfinished game")
        XCTAssertFalse(app.otherElements["Chessboard"].exists, "the game must not start until confirmed")
        confirm.tap()

        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(square(app, "e 2, white pawn").waitForExistence(timeout: 5),
                      "confirming should start the game from the analysis board, not continue the old one")
    }
}
