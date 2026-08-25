//
//  GameControlsUITests.swift
//  chessUITests
//
//  The row of controls under the board. Its middle slot depends on the mode,
//  which is the one thing reading the code cannot confirm: the button has to
//  be on screen, enabled, named, and wired to something that answers.
//

import XCTest

@MainActor
final class GameControlsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15),
                      "the game never opened")
        return app
    }

    /// The middle control used to be Hint in both modes, and `canRequestHint`
    /// is false for a two-player game whatever the position — so a third of the
    /// row sat greyed out for the whole game. It now offers the draw the two
    /// players may settle on, which is the fifth of the five draws the guide
    /// lists and the only one the app had no way to reach.
    func testTwoPlayersCanAgreeToADrawFromTheBoard() {
        let app = launch(["--auto-game-2p", "--script=e2e4"])

        XCTAssertFalse(app.buttons["Hint"].exists,
                       "Hint is unanswerable in a two-player game and must not take the slot")
        let draw = app.buttons["Draw"]
        XCTAssertTrue(draw.waitForExistence(timeout: 5), "the Draw button is missing")
        XCTAssertTrue(draw.isEnabled, "an unfinished two-player game can always be drawn")
        draw.tap()

        let confirm = app.buttons["Agree to a Draw"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the draw should be confirmed first")
        confirm.tap()

        // The result overlay names the outcome the engine had all along but
        // nothing could produce.
        let result = app.staticTexts["Draw by agreement"]
        XCTAssertTrue(result.waitForExistence(timeout: 10),
                      "the game should end as a draw by agreement")
        XCTAssertTrue(app.buttons["Game Review"].waitForExistence(timeout: 5),
                      "an agreed draw with moves in it is still reviewable")
    }

    /// The other half of the same swap: against the computer the slot is Hint,
    /// and there is no draw to offer a machine that plays every position out.
    func testAgainstTheComputerTheSlotIsHint() {
        let app = launch(["--auto-game-ai"])

        XCTAssertTrue(app.buttons["Hint"].waitForExistence(timeout: 5), "Hint is missing")
        XCTAssertFalse(app.buttons["Draw"].exists,
                       "there is nobody to agree a draw with against the computer")
    }
}
