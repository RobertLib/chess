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

        let confirm = app.buttons["Start New Game"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the menu should ask before replacing an unfinished game")
        XCTAssertFalse(app.otherElements["Chessboard"].exists, "the game must not start until confirmed")
        confirm.tap()

        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(square(app, "e 2, white pawn").waitForExistence(timeout: 5),
                      "confirming should start a fresh game, not continue the old one")
    }
}
