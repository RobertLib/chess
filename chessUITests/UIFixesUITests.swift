//
//  UIFixesUITests.swift
//  chessUITests
//
//  What a player hears and sees at the edges of a game: the time on a player
//  card as VoiceOver reads it while the clock runs, the names of the buttons
//  that carry an icon beside their word, a board shared across a table,
//  where the far side's pieces — and its promotion picker — face the far
//  player, and the move lists, results and time controls VoiceOver reads in
//  words rather than in notation.
//

import XCTest

@MainActor
final class UIFixesUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    private func square(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", label))
            .firstMatch
    }

    // MARK: Clock on the player card

    /// The card's words used to be worked out when the card was drawn, which
    /// is once a move: a player thinking for two minutes still heard the time
    /// the turn began with. Black's clock starts once White has moved, and
    /// three seconds later the card has to say less time than it did.
    func testPlayerCardReadsTheClockAsItRuns() {
        let app = launch(["--auto-game-2p", "--time=5+0", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15),
                      "the game never opened")

        let card = app.otherElements
            .matching(NSPredicate(format: "label == %@", "Black"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Black's card has no spoken name")

        // On turn once the scripted move has landed.
        let onTurn = NSPredicate(format: "value CONTAINS %@", "to move")
        expectation(for: onTurn, evaluatedWith: card)
        waitForExpectations(timeout: 10)

        let before = card.value as? String ?? ""
        XCTAssertTrue(before.contains("left"), "the card should say the time left, said \"\(before)\"")
        Thread.sleep(forTimeInterval: 3)
        let after = card.value as? String ?? ""
        XCTAssertTrue(after.contains("left"), "the card should say the time left, said \"\(after)\"")
        XCTAssertNotEqual(before, after, "the card kept reading the time its turn began with")
    }

    /// The other card's clock is not running, and what it says stays put.
    func testTheWaitingPlayersCardKeepsItsTime() {
        let app = launch(["--auto-game-2p", "--time=5+0", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15))

        let black = app.otherElements.matching(NSPredicate(format: "label == %@", "Black")).firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS %@", "to move"), evaluatedWith: black)
        waitForExpectations(timeout: 10)

        let white = app.otherElements.matching(NSPredicate(format: "label == %@", "White")).firstMatch
        XCTAssertTrue(white.exists, "White's card has no spoken name")
        let before = white.value as? String ?? ""
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(white.value as? String ?? "", before,
                       "a clock that is not running should not read any differently")
    }

    // MARK: Icon and word

    /// Every one of these draws a symbol beside its word. What it is called
    /// has to be the word alone: a symbol's own name read in front of it
    /// ("Pause, Pause", "Play, Resume") is noise a VoiceOver player hears on
    /// every visit to the row.
    func testIconAndWordButtonsAreCalledByTheWordAlone() {
        let app = launch(["--auto-game-2p", "--time=5+0", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15))

        func exactly(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }

        XCTAssertTrue(exactly("Draw").exists, "the Draw button should be called just that")
        XCTAssertTrue(exactly("Resign").exists, "the Resign button should be called just that")
        let pause = exactly("Pause")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: pause)
        waitForExpectations(timeout: 10)
        pause.tap()

        XCTAssertTrue(exactly("Resume").waitForExistence(timeout: 5),
                      "the pause card's Resume should be called just that")
        XCTAssertTrue(exactly("Back to Menu").exists)
    }

    // MARK: Face to face

    /// `--script` stops the moment a move raises the picker. Here it is Black,
    /// across the table, who takes the h1 rook and promotes.
    private let blackPromotes = "a2a4,h7h5,a4a5,h5h4,a5a6,h4h3,a6b7,h3g2,b1c3,g2h1"
    /// The same race the other way round: White, on the near side, takes h8.
    private let whitePromotes = "h2h4,a7a5,h4h5,a5a4,h5h6,a4a3,h6g7,a3b2,g7h8"

    /// The far player's pieces are drawn upside down, and their promotion
    /// picker used to be the near player's way up — queen to the near
    /// player's left, every piece on its head as the far player saw it.
    /// Turned to face them, the row runs the other way on screen.
    func testFarSidePromotionPickerFacesItsPlayer() {
        let app = launch([
            "--auto-game-2p", "--tabletop", "--script-interval=0.3", "--script=\(blackPromotes)",
        ])
        let queen = app.buttons["black queen"]
        XCTAssertTrue(queen.waitForExistence(timeout: 20), "Black's promotion picker never opened")
        // It arrives on a spring; measure it once it has landed.
        Thread.sleep(forTimeInterval: 1)
        let knight = app.buttons["black knight"]
        XCTAssertGreaterThan(queen.frame.midX, knight.frame.midX,
                             "turned towards the far player, the queen is on the screen's right")
        XCTAssertLessThan(queen.frame.midY - knight.frame.midY, 1,
                          "the row should still be a row")

        queen.tap()
        XCTAssertTrue(square("h 1, black queen", in: app).waitForExistence(timeout: 5),
                      "picking from the turned card should still promote")
    }

    /// The near player's picker is not turned.
    func testNearSidePromotionPickerIsUpright() {
        let app = launch([
            "--auto-game-2p", "--tabletop", "--script-interval=0.3", "--script=\(whitePromotes)",
        ])
        let queen = app.buttons["white queen"]
        XCTAssertTrue(queen.waitForExistence(timeout: 20), "White's promotion picker never opened")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(queen.frame.midX, app.buttons["white knight"].frame.midX,
                          "for the near player the queen comes first, on the left")
    }

    /// The far player's lifted piece is drawn on their side of the finger now.
    /// Where it is drawn is not something the element tree can see, but where
    /// it lands is: the drop still goes to the square under the finger.
    func testFarSideDragStillLandsUnderTheFinger() {
        let app = launch(["--auto-game-2p", "--tabletop", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15))
        XCTAssertTrue(square("e 4, white pawn", in: app).waitForExistence(timeout: 10),
                      "the scripted move never landed")

        let from = square("e 7, black pawn", in: app)
        let to = square("e 5, empty", in: app)
        XCTAssertTrue(from.exists && to.exists)
        from.press(forDuration: 0.15, thenDragTo: to)

        XCTAssertTrue(square("e 5, black pawn", in: app).waitForExistence(timeout: 5),
                      "dragging e7-e5 from the far side did not land the pawn")
    }

    // MARK: Read in words

    /// The game's move strip is read as the move is said. Combined as it is
    /// drawn, its "1." and "e4" came out as notation spelt a letter at a
    /// time — in Czech, "J x e 5 plus" for a knight's capture.
    func testGameMoveStripReadsMovesInWords() {
        let app = launch(["--auto-game-2p", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15))
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Move 1, White: pawn e 4"))
            .firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "the move strip should read the scripted move in words")
    }

    /// The analysis board's strip, and the engine's suggestion above it.
    func testAnalysisBoardReadsMovesInWords() {
        let app = launch(["--training", "--training-analysis"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        square("e 2, white pawn", in: app).tap()
        square("e 4, empty", in: app).tap()
        XCTAssertTrue(app.buttons["Move 1, White: pawn e 4"].waitForExistence(timeout: 5),
                      "the analysis strip should read the move in words")

        let best = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Best: "))
            .firstMatch
        XCTAssertTrue(best.waitForExistence(timeout: 30), "the engine never suggested a move")
        XCTAssertNotNil(
            best.label.range(of: "^Best: (pawn|knight|bishop|rook|queen|king|castles) ",
                             options: .regularExpression),
            "the engine's move should be read in words, got \"\(best.label)\""
        )
    }

    /// The control on the stand-alone clock is drawn as "5 + 3" beside the
    /// button that changes it, and that text is hidden from VoiceOver; the
    /// button has to say it instead.
    func testChessClockSaysItsTimeControl() {
        let app = launch(["--chess-clock"])
        let button = app.buttons["Time control"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let value = button.value as? String ?? ""
        XCTAssertTrue(value.contains("minute") || value.contains("second"),
                      "the Time control button should say the control on the clock, said \"\(value)\"")
    }

    /// A game with no side of the player's — two players at one device — is
    /// drawn in My Games with a flag, and its spoken value began with the
    /// PGN result: "1/2-1/2" read as numbers.
    func testMyGamesSaysATwoPlayerResultInWords() {
        let app = launch(["--auto-game-2p", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 15))
        XCTAssertTrue(square("e 4, white pawn", in: app).waitForExistence(timeout: 10),
                      "the scripted move never landed")
        app.buttons["Draw"].tap()
        let confirm = app.buttons["Agree to a Draw"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Draw by agreement"].waitForExistence(timeout: 10))

        app.buttons["Back to Menu"].tap()
        let myGames = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "My Games")).firstMatch
        XCTAssertTrue(myGames.waitForExistence(timeout: 10))
        myGames.tap()
        XCTAssertTrue(app.staticTexts["My Games"].waitForExistence(timeout: 10))

        let drawn = app.buttons.matching(NSPredicate(format: "value BEGINSWITH %@", "Draw, ")).firstMatch
        XCTAssertTrue(drawn.waitForExistence(timeout: 10), "the drawn game should be read as a draw")
        let notation = app.buttons.matching(NSPredicate(
            format: "value BEGINSWITH '1-0' OR value BEGINSWITH '0-1' OR value BEGINSWITH '1/2' OR value BEGINSWITH '*,'"
        ))
        XCTAssertEqual(notation.count, 0, "no game should be read out by its PGN result")
    }
}
