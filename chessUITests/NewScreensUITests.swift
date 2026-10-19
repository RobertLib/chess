//
//  NewScreensUITests.swift
//  chessUITests
//
//  The screens added with the clock, the puzzles, the training and the
//  archive, held to the same standard as the rest: they pass the system's
//  accessibility audit, and at the largest text size nothing runs off the
//  screen.
//

import XCTest

/// `performAccessibilityAudit`'s handler is not `Sendable`, so what it finds is
/// gathered through a reference the closure may capture. Main-actor isolated,
/// like `AuditLog` beside the other audit: `label` is, and the handler written
/// inside a main-actor test inherits that isolation.
@MainActor
private final class ScreenIssueLog {
    private(set) var issues: [String] = []
    func add(_ issue: XCUIAccessibilityAuditIssue) {
        issues.append("\"\(issue.element?.label ?? "?")\" (\(issue.compactDescription))")
    }
}

@MainActor
final class NewScreensUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String], largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        return app
    }

    private func audit(_ app: XCUIApplication, _ screen: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let log = ScreenIssueLog()
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ]) { issue in
            log.add(issue)
            return true
        }
        XCTAssertTrue(log.issues.isEmpty, "\(screen): " + log.issues.sorted().joined(separator: "; "),
                      file: file, line: line)
    }

    /// No text starts left of the screen — a view wider than the screen is
    /// centred and overhangs both sides, so the left edge is the tell.
    private func assertFitsOnScreen(_ app: XCUIApplication, _ screen: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let screenFrame = app.windows.firstMatch.frame
        let overhanging = app.staticTexts.allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty && $0.frame.minX < screenFrame.minX - 1 }
            .map(\.label)
        XCTAssertTrue(overhanging.isEmpty,
                      "\(screen): text runs off the screen — " + overhanging.joined(separator: ", "),
                      file: file, line: line)
    }

    // MARK: Setup

    func testTwoPlayerSetupPassesAudit() throws {
        let app = launch(["--menu-2p-setup"])
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 10))
        try audit(app, "two-player setup")
    }

    func testTwoPlayerSetupFitsAtLargestText() {
        let app = launch(["--menu-2p-setup"], largestText: true)
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 10))
        assertFitsOnScreen(app, "two-player setup")
    }

    func testTimeControlPickerPassesAudit() throws {
        let app = launch(["--menu-ai-setup"])
        let row = app.buttons["Time control"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Time Control"].waitForExistence(timeout: 5))
        try audit(app, "time control picker")
    }

    func testTimedGameShowsTheClocksAndPauses() {
        let app = launch(["--auto-game-2p", "--time=3+2", "--script=e2e4"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8), "a game on the clock offers a pause")
        XCTAssertFalse(app.buttons["Undo"].exists, "there is no undo on the clock")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["Resume"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
    }

    // MARK: Chess clock

    func testChessClockPassesAudit() throws {
        let app = launch(["--chess-clock"])
        XCTAssertTrue(app.buttons["White's clock"].waitForExistence(timeout: 10))
        try audit(app, "chess clock")
    }

    func testChessClockRunsAndSwitchesSides() {
        let app = launch(["--chess-clock"])
        let black = app.buttons["Black's clock"]
        XCTAssertTrue(black.waitForExistence(timeout: 10))
        black.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "Black's tap starts White's clock")
        app.buttons["White's clock"].tap()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
    }

    // MARK: Puzzles

    func testPuzzleHubPassesAudit() throws {
        let app = launch(["--puzzles"])
        XCTAssertTrue(app.buttons["Solve Rated Puzzles"].waitForExistence(timeout: 10))
        try audit(app, "puzzle hub")
    }

    func testPuzzleHubFitsAtLargestText() {
        let app = launch(["--puzzles"], largestText: true)
        XCTAssertTrue(app.buttons["Solve Rated Puzzles"].waitForExistence(timeout: 10))
        assertFitsOnScreen(app, "puzzle hub")
    }

    /// The widget's daily puzzle closes everything else to make room for
    /// itself, so its way back leads to whatever was left under it — never to
    /// the puzzle hub that "Back to puzzles" promised.
    func testTheWidgetsPuzzleSaysWhereBackLeads() {
        let fromMenu = launch(["--widget-tap"])
        XCTAssertTrue(fromMenu.otherElements["Chessboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(fromMenu.buttons["Back to menu"].exists, "over the menu, the way back is to the menu")
        XCTAssertFalse(fromMenu.buttons["Back to puzzles"].exists)
        fromMenu.terminate()

        let fromGame = launch(["--auto-game-2p", "--widget-tap"])
        XCTAssertTrue(fromGame.buttons["Back to the game"].waitForExistence(timeout: 10),
                      "over a game, the way back is to the game")
        XCTAssertFalse(fromGame.buttons["Back to puzzles"].exists)
    }

    func testPuzzleBoardPassesAudit() throws {
        let app = launch(["--puzzles", "--puzzle-rated"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Hint"].waitForExistence(timeout: 5))
        try audit(app, "puzzle board")
    }

    // MARK: Training

    func testTrainingHubPassesAudit() throws {
        let app = launch(["--training"])
        XCTAssertTrue(app.buttons["Analysis Board"].waitForExistence(timeout: 10))
        try audit(app, "training hub")
    }

    func testAnalysisBoardPassesAudit() throws {
        let app = launch(["--training", "--training-analysis"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        try audit(app, "analysis board")
    }

    func testPositionEditorPassesAudit() throws {
        let app = launch(["--training", "--training-editor"])
        XCTAssertTrue(app.buttons["Analyze"].waitForExistence(timeout: 10))
        try audit(app, "position editor")
    }

    /// "O-O" is for the eye; the toggles say what they are in words.
    func testCastlingTogglesAreNamedInWords() {
        let app = launch(["--training", "--training-editor"])
        XCTAssertTrue(app.buttons["Analyze"].waitForExistence(timeout: 10))
        for name in ["White kingside castling", "White queenside castling",
                     "Black kingside castling", "Black queenside castling"] {
            XCTAssertTrue(app.buttons[name].exists, "no castling toggle is called \"\(name)\"")
        }
    }

    func testOpeningListPassesAudit() throws {
        let app = launch(["--training", "--training-openings"])
        XCTAssertTrue(app.staticTexts["Opening Trainer"].waitForExistence(timeout: 10))
        try audit(app, "opening list")
    }

    // MARK: Archive

    func testMyGamesPassesAudit() throws {
        let app = launch(["--my-games"])
        XCTAssertTrue(app.staticTexts["My Games"].waitForExistence(timeout: 10))
        try audit(app, "my games")
        app.buttons["Statistics"].tap()
        try audit(app, "statistics")
        app.buttons["Achievements"].tap()
        try audit(app, "achievements")
    }

    /// "3 W · 1 D · 2 L" is for the eye; the rows of the statistics say their
    /// tally in words.
    func testStatisticsTallyIsReadInWords() {
        let app = launch(["--my-games"])
        XCTAssertTrue(app.staticTexts["My Games"].waitForExistence(timeout: 10))
        app.buttons["Statistics"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "White", "wins"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the White row does not read its tally in words")
        XCTAssertFalse((row.value as? String ?? "").contains(" W "), "the tally is still read as letters")
    }

    func testMyGamesFitsAtLargestText() {
        let app = launch(["--my-games"], largestText: true)
        XCTAssertTrue(app.staticTexts["My Games"].waitForExistence(timeout: 10))
        assertFitsOnScreen(app, "my games")
    }
}
