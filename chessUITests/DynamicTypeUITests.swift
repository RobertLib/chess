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

import UIKit
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

    /// The difficulty and side pickers, which `testMenuFitsAtLargestTextSize`
    /// never reaches: it launches with no arguments, so it audits the root menu
    /// and stops there. Every game against the computer passes through here.
    ///
    /// Its Start Game button is what this caught: a hard `.frame(height: 50)`
    /// around a `.body` label that needs 56 pt at AX4 and 63 pt at AX5, so the
    /// word hung over both edges of the gold pill.
    func testNewGameSetupFitsAtLargestTextSize() throws {
        let app = launch(["--menu-ai-setup"])
        let start = app.buttons["Start Game"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        try assertLaysOutCleanly(app, "new game setup")
        assertLabelHasRoomInside(start, textStyle: .body, "Start Game")
    }

    /// A filled control has to be taller than one line of its own label, or
    /// the text sits on the edge of the shape drawn behind it — or, if the
    /// height was pinned, spills straight out of it.
    ///
    /// It is put this way round because a label overflowing its background is
    /// **not directly measurable from here**: XCUITest reports a SwiftUI
    /// button's frame from the label it renders, not from the background, so
    /// the pinned 50 pt button came back as the 63 pt its text wanted and a
    /// "taller than one line" test passed against the very bug it was written
    /// for. What does show is that the frame stopped growing: the same button
    /// sized from its text reports 91 pt at this text size, the pinned one 63.
    /// So the room *around* the line is the signal, and 8 pt a side is the
    /// smallest the design ever leaves.
    private func assertLabelHasRoomInside(
        _ element: XCUIElement, textStyle: UIFont.TextStyle, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let lineHeight = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).lineHeight
        let needed = lineHeight + 16
        XCTAssertGreaterThanOrEqual(
            element.frame.height, needed,
            "\"\(name)\" is \(Int(element.frame.height)) pt tall; one line of its text is "
                + "\(Int(lineHeight.rounded())) pt and a filled control needs 8 pt a side around it, "
                + "so its height is not coming from its label",
            file: file, line: line
        )
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

    /// The promotion picker, which every game that runs a pawn home passes
    /// through and which nothing here reached before. Its four tiles are drawn
    /// at a fixed 62 pt and shrink only to fit a narrow screen, so what the
    /// text setting can still break is the heading over them and the card
    /// around all five. The scripted move stops at the picker by design.
    func testPromotionPickerFitsAtLargestTextSize() throws {
        let app = launch([
            "--fen=4k3/P7/8/8/8/8/8/4K3 w - - 0 1",
            "--script=a7a8",
        ])
        XCTAssertTrue(
            app.buttons["white queen"].waitForExistence(timeout: 20),
            "the promotion picker never opened"
        )
        // Same spring as the result card: measured mid-bounce its text reads
        // as clipped because the card is still scaled past its own bounds.
        Thread.sleep(forTimeInterval: 1)
        try assertLaysOutCleanly(app, "promotion picker")
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
        // The cache is cleared because this test waits for the progress
        // indicator: a review whose searches are already stored opens on a
        // finished report and shows none.
        let app = launch(
            ["--review-script=e2e4,e7e5,g1f3,b8c6", "--reset-analysis-cache"], settle: 2
        )

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
