//
//  DynamicTypeUITests.swift
//  chessUITests
//
//  The app is drawn at specific point sizes rather than at the text styles, so
//  Larger Text used to leave half of it frozen and crush the other half: menu
//  rows truncated mid-word, the game title ran under the settings button, and
//  the review's accuracy — the one number the whole report is about — came out
//  as "9…". These tests turn the text all the way up and check that nothing
//  runs off the side of the screen.
//
//  A frame wider than the screen is the failure that matters. `.dynamicType`
//  from `performAccessibilityAudit` is not used for this: it reads the font a
//  label was built with, so it cannot tell a font that legitimately has to fit
//  a board square from one that was simply never scaled, and it flags text
//  styles it should pass. This measures the layout instead.
//

import XCTest

/// `performAccessibilityAudit`'s handler is not `Sendable`, so what it finds is
/// gathered through a reference the closure may capture.
private final class IssueLog: @unchecked Sendable {
    private(set) var labels: [String] = []
    func add(_ label: String) { labels.append(label) }
}

@MainActor
final class DynamicTypeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches with the text-size setting at the largest accessibility size.
    private func launch(_ arguments: [String], settle: TimeInterval = 3) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        Thread.sleep(forTimeInterval: settle)
        return app
    }

    /// Every piece of text has to sit inside the screen.
    ///
    /// The test is the *left* edge, not both. A view that is wider than the
    /// screen gets centred, so it spills over both sides at once and the left
    /// overhang is the tell — that is exactly how the report sheet and the
    /// lesson page failed. Checking the right edge as well would fail the
    /// board-theme picker, which is a horizontal scroller and is *meant* to run
    /// off to the right.
    ///
    /// `isHittable` must not be used to filter these: an element pushed off the
    /// screen is not hittable, so filtering on it throws away precisely the
    /// elements this is looking for.
    private func assertFitsOnScreen(_ app: XCUIApplication, _ screen: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let bounds = app.frame
        XCTAssertGreaterThan(bounds.width, 0, "\(screen): no window", file: file, line: line)

        var offenders: [String] = []
        for text in app.staticTexts.allElementsBoundByIndex where text.exists {
            let frame = text.frame
            guard frame.width > 0 else { continue }
            if frame.minX < bounds.minX - 1 {
                offenders.append("\"\(text.label)\" starts at \(Int(frame.minX))")
            } else if frame.width > bounds.width + 1 {
                offenders.append("\"\(text.label)\" is \(Int(frame.width)) wide")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "\(screen): text runs off the screen at the largest text size — "
                + "screen is \(Int(bounds.minX))…\(Int(bounds.maxX)); "
                + offenders.joined(separator: "; "),
            file: file, line: line
        )
    }

    /// Nothing may be cut off inside the box it was given either — this is what
    /// caught the review's accuracy dial rendering "95.4" as "9…".
    ///
    /// Only `.textClipped` is used, not `.dynamicType`: the latter reads the
    /// font a label was built with, which it cannot tell apart from a font that
    /// legitimately has to fit a board square, and it flags text styles that do
    /// scale. Clipping is the symptom that actually matters.
    private func assertNothingIsClipped(_ app: XCUIApplication, _ screen: String,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let log = IssueLog()
        // A failure of the audit itself must fail the test rather than pass
        // it with nothing logged — `try?` here made every clipping check
        // vacuous whenever the audit could not run.
        try app.performAccessibilityAudit(for: [.textClipped]) { issue in
            // An element hidden behind a modal has no `element`; the audit's
            // own description still names the text, so that is kept too.
            log.add("\"\(issue.element?.label ?? "?")\" (\(issue.compactDescription))")
            return true
        }
        XCTAssertTrue(
            log.labels.isEmpty,
            "\(screen): text is cut off at the largest text size — "
                + Set(log.labels).sorted().joined(separator: ", "),
            file: file, line: line
        )
    }

    private func assertLaysOutCleanly(_ app: XCUIApplication, _ screen: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        assertFitsOnScreen(app, screen, file: file, line: line)
        try assertNothingIsClipped(app, screen, file: file, line: line)
    }

    func testMenuFitsAtLargestTextSize() throws {
        let app = launch([])
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Two Players")
        ).firstMatch.waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "menu")
    }

    func testGameFitsAtLargestTextSize() throws {
        let app = launch(["--auto-game-2p"])
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "game")
    }

    /// The result card sits over the board and, until it was brought under the
    /// same text-size cap as the board, truncated every line it had at the
    /// largest sizes — "Checkm…", "Mo ves", "Back to…" — with nothing here to
    /// notice. Fool's mate ends the game in four scripted moves.
    func testGameOverFitsAtLargestTextSize() throws {
        let app = launch(["--auto-game-2p", "--script=f2f3,e7e5,g2g4,d8h4"], settle: 1)
        // Found by their own names: a label put on the card as a plain stack
        // used to be handed down to the buttons, so all three of them were
        // "Checkmate! Black wins" to VoiceOver and none of them was findable.
        let backToMenu = app.buttons["Back to Menu"]
        XCTAssertTrue(backToMenu.waitForExistence(timeout: 30), "the game never ended")
        XCTAssertTrue(app.buttons["Game Review"].exists, "the result card should offer the review")
        XCTAssertTrue(app.buttons["New Game"].exists, "the result card should offer a new game")
        // The card arrives on a spring; measured mid-bounce it is scaled past
        // its own bounds and the audit reports its text as clipped.
        Thread.sleep(forTimeInterval: 1)
        try assertLaysOutCleanly(app, "game over")
        XCTAssertTrue(backToMenu.isHittable, "the last button of the result card is off the screen")
    }

    func testSettingsFitAtLargestTextSize() throws {
        let app = launch(["--show-settings"])
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "settings")
    }

    func testTutorialContentsFitAtLargestTextSize() throws {
        let app = launch(["--tutorial"])
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "how to play")
    }

    func testLessonFitsAtLargestTextSize() throws {
        let app = launch(["--tutorial", "--tutorial-chapter=pieces", "--tutorial-page=2"])
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "lesson")
    }

    /// The accuracy cards are the point of this test, and they only replace the
    /// progress card once the engine has finished the whole game. Waiting a
    /// fixed number of seconds audited whichever of the two happened to be on
    /// screen at the time, so a clipped percentage went unnoticed in roughly
    /// two runs out of three — the progress card fits fine. This waits for the
    /// analysis to finish and then checks that a card is really there, so the
    /// test cannot pass by measuring the wrong screen.
    func testReviewFitsAtLargestTextSize() throws {
        let app = launch(["--review-script=e2e4,e7e5,g1f3,b8c6"], settle: 2)

        let analyzing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Analyzing"))
            .firstMatch
        XCTAssertTrue(analyzing.waitForExistence(timeout: 30),
                      "the review never started analyzing")
        XCTAssertTrue(analyzing.waitForNonExistence(timeout: 180),
                      "the analysis never finished")

        // `--review-script` opens the review of a game against the computer,
        // so the cards are labelled "You" and "Computer".
        let card = app.descendants(matching: .any)["You"]
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "the accuracy cards never appeared")

        // The cards arrive on a fade; let it land before frames are measured.
        Thread.sleep(forTimeInterval: 1)
        try assertLaysOutCleanly(app, "review")
    }

    /// The report is where this went most wrong: two accuracy dials side by
    /// side stopped fitting and dragged the whole sheet wider than the screen,
    /// truncating the percentage inside them.
    ///
    /// The sheet is opened by tapping its button rather than by the
    /// `--review-report` launch argument: presented over a full-screen cover,
    /// the argument's sheet does not reliably show up in the element tree.
    func testGameReportFitsAtLargestTextSize() throws {
        let app = launch(["--review-script=e2e4,e7e5,g1f3,b8c6"], settle: 2)

        let report = app.buttons["Report"]
        XCTAssertTrue(report.waitForExistence(timeout: 30), "the Report button never appeared")
        // The button is disabled until the first results land.
        let deadline = Date().addingTimeInterval(60)
        while !report.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(report.isEnabled, "the analysis never produced a report")
        report.tap()

        XCTAssertTrue(
            app.staticTexts["ACCURACY"].waitForExistence(timeout: 20),
            "the report sheet did not open"
        )
        Thread.sleep(forTimeInterval: 1)
        try assertLaysOutCleanly(app, "game report")
    }
}
