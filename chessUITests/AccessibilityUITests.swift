//
//  AccessibilityUITests.swift
//  chessUITests
//
//  The board is drawn as a stack of decorative layers, so nothing about it is
//  automatically readable. These tests are what keep the separate accessibility
//  layer honest: if a square stops describing itself, or the drag gesture stops
//  reaching the board underneath it, they fail here rather than in someone's
//  hands.
//

import XCTest

/// `performAccessibilityAudit`'s handler is not `Sendable`, so what it finds is
/// gathered through a reference the closure may capture. Worth the few lines:
/// the audit's own failure message names the *rule* that was broken and not the
/// element that broke it, which is the half you need.
/// Main-actor isolated, and that is the whole trick: the target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, so a plain class here reads
/// `XCUIElement.label` and `.frame` — both main-actor isolated — from a
/// nonisolated method, which built with three concurrency warnings that only a
/// *clean* build ever showed, because an incremental one does not recompile
/// this file. The audit's handler is a non-`Sendable` closure written inside a
/// main-actor test, so it inherits that isolation and can call this directly.
@MainActor
private final class AuditLog {
    private(set) var issues: [String] = []
    func add(_ issue: XCUIAccessibilityAuditIssue) {
        let name = issue.element?.label ?? "?"
        let frame = issue.element.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "?"
        issues.append("\"\(name)\" [\(frame)] \(issue.compactDescription)")
    }
}

/// Apple asks for a 44 x 44 pt touch target. `performAccessibilityAudit`'s
/// `.hitRegion` check does **not** enforce it — a 26 pt button passed it
/// without a murmur — so the size is measured here rather than audited.
///
/// Named controls only: a board square is as big as a board on a phone lets it
/// be (42 pt), and no padding can change that.
@MainActor
private func assertTappable(
    _ element: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard element.exists else {
        XCTFail("no such control to measure", file: file, line: line)
        return
    }
    let frame = element.frame
    XCTAssertGreaterThanOrEqual(
        min(frame.width, frame.height), 44,
        "\"\(element.label)\" is \(Int(frame.width))x\(Int(frame.height)) pt, "
            + "under the 44 pt an adult finger needs",
        file: file, line: line
    )
}

/// XCUITest's API is main-actor isolated, while this target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` (XCTestCase's own members are
/// nonisolated). Isolating the class is what reconciles the two.
@MainActor
final class AccessibilityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// English, so the expected labels below do not depend on the simulator's
    /// language, and straight into a two-player game so the board is live.
    private func launchIntoGame() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--auto-game-2p", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    // MARK: Board

    func testBoardExposesEverySquareToVoiceOver() {
        let app = launchIntoGame()
        let board = app.otherElements["Chessboard"]
        XCTAssertTrue(board.waitForExistence(timeout: 10), "the board should be a named container")

        // Eight files times eight ranks, each one describing itself.
        for file in "abcdefgh" {
            for rank in 1...8 {
                let label = "\(file) \(rank)"
                let square = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                    .firstMatch
                XCTAssertTrue(square.exists, "square \(label) is invisible to VoiceOver")
            }
        }
    }

    func testStartingPositionIsReadOutCorrectly() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))

        let expected = [
            "e 1, white king",
            "d 1, white queen",
            "a 1, white rook",
            "b 1, white knight",
            "c 1, white bishop",
            "e 2, white pawn",
            "e 8, black king",
            "d 8, black queen",
            "e 4, empty",
        ]
        for label in expected {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(
                    NSPredicate(format: "label BEGINSWITH %@", label)
                ).firstMatch.exists,
                "expected a square described as \"\(label)\""
            )
        }
    }

    /// Tapping one square then another has to move the piece. Touching down
    /// selects, and lifting used to hand the same square back to the model,
    /// which read as a second tap and deselected it again — leaving drag as the
    /// only way to play. This is the regression test for that.
    func testTappingTwoSquaresMovesAPiece() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))

        func square(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                .firstMatch
        }

        square("e 2, white pawn").tap()
        square("e 4, empty").tap()

        XCTAssertTrue(
            square("e 4, white pawn").waitForExistence(timeout: 5),
            "the pawn should now be described as standing on e4"
        )
        XCTAssertTrue(square("e 2, empty").exists, "e2 should now read as empty")
    }

    func testTappingASelectedPieceAgainDeselectsIt() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))

        func square(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                .firstMatch
        }

        let pawn = square("e 2, white pawn")
        pawn.tap()
        XCTAssertTrue(pawn.isSelected, "touching down should select the piece")

        square("e 2, white pawn").tap()
        XCTAssertFalse(
            square("e 2, white pawn").isSelected,
            "tapping the selected piece again should let it go"
        )
        XCTAssertTrue(square("e 2, white pawn").exists, "the pawn should not have moved")
    }

    /// The accessibility layer sits on top of the board, so this is the test
    /// that would catch it swallowing touches meant for the drag recognizer.
    func testDraggingAPieceStillWorks() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))

        func square(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                .firstMatch
        }

        let from = square("d 2, white pawn")
        let to = square("d 4, empty")
        XCTAssertTrue(from.exists && to.exists)

        from.press(forDuration: 0.15, thenDragTo: to)

        XCTAssertTrue(
            square("d 4, white pawn").waitForExistence(timeout: 5),
            "dragging d2-d4 did not land the pawn"
        )
    }

    /// A swipe that begins on an empty square is not a move. The gesture picks
    /// nothing up, and the release used to be handed to the model as a tap on
    /// whichever square the finger happened to lift over — so brushing across
    /// the board played a move for the piece that was already selected.
    func testSwipingFromAnEmptySquareDoesNotMoveTheSelectedPiece() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))

        func square(_ label: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                .firstMatch
        }

        // Select the pawn, so e4 is a legal target sitting there waiting.
        square("e 2, white pawn").tap()
        XCTAssertTrue(square("e 2, white pawn").isSelected, "the pawn should be selected")

        // Now brush from one empty square to another, ending on that target.
        square("h 3, empty").press(forDuration: 0.1, thenDragTo: square("e 4, empty"))

        XCTAssertTrue(
            square("e 2, white pawn").waitForExistence(timeout: 3),
            "a swipe across the board should have left the pawn on e2"
        )
        XCTAssertTrue(square("e 4, empty").exists, "e4 should still read as empty")
    }

    // MARK: Audits

    func testGameScreenPassesAccessibilityAudit() throws {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ])
    }

    func testMenuPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let twoPlayers = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Two Players")
        ).firstMatch
        XCTAssertTrue(twoPlayers.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ])
    }

    /// The difficulty and side pickers are the one screen every game against
    /// the computer goes through, and until now nothing audited it at all —
    /// neither here nor in `DynamicTypeUITests`, which launched the menu with
    /// no arguments and so only ever saw the root.
    func testNewGameSetupPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--menu-ai-setup", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 10))
        // Both pickers say which option is chosen, not just draw it.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Medium"))
                .firstMatch.isSelected,
            "the chosen difficulty should be selected to VoiceOver, not only tinted"
        )
        XCTAssertTrue(app.buttons["White"].isSelected, "the chosen side should be selected")
        let log = AuditLog()
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ]) { issue in
            log.add(issue)
            return true
        }
        XCTAssertTrue(
            log.issues.isEmpty,
            "new game setup: " + log.issues.sorted().joined(separator: "; ")
        )
    }

    func testIconOnlyControlsAreNamed() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        for name in ["Back to menu", "Settings", "Flip the board"] {
            XCTAssertTrue(app.buttons[name].exists, "\"\(name)\" has no spoken name")
        }
    }

    /// The round chrome buttons draw a 38 pt circle on purpose — a 44 pt one
    /// would crowd the title between them — so their target is padded out
    /// instead. Measured, because the audit lets 38 pt through.
    func testGameControlsAreBigEnoughToTap() {
        let app = launchIntoGame()
        XCTAssertTrue(app.otherElements["Chessboard"].waitForExistence(timeout: 10))
        for name in ["Back to menu", "Settings", "Flip the board", "Undo", "Draw", "Resign"] {
            assertTappable(app.buttons[name])
        }
    }

    // MARK: Promotion picker

    /// A white pawn one square from promoting, with the picker already open.
    /// `playScriptedMoves` stops as soon as a move raises it — that is what
    /// puts the four pieces on screen without anything having to tap them —
    /// and two-player mode means nothing moves underneath while they sit there.
    private func launchIntoPromotionPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--fen=4k3/P7/8/8/8/8/8/4K3 w - - 0 1",
            "--script=a7a8",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    /// The four pieces every promotion is chosen from. The picker is the one
    /// modal in the app nothing measured: its tiles are a fixed 62 pt plus 8 pt
    /// of padding a side rather than a `@ScaledMetric`, so nothing about the
    /// text setting protects them, and a change to `PromotionMetrics` could
    /// take them under the 44 pt a finger needs without a single test noticing.
    func testPromotionPieceButtonsAreBigEnoughToTap() {
        let app = launchIntoPromotionPicker()
        let names = ["white queen", "white rook", "white bishop", "white knight"]
        XCTAssertTrue(
            app.buttons[names[0]].waitForExistence(timeout: 20),
            "the promotion picker never opened"
        )
        for name in names {
            assertTappable(app.buttons[name])
        }
    }

    /// Each piece has to name itself, or the picker is four unlabelled tiles —
    /// and it is modal, so a VoiceOver player has nothing else to move to.
    func testPromotionPickerPassesAccessibilityAudit() throws {
        let app = launchIntoPromotionPicker()
        XCTAssertTrue(
            app.buttons["white queen"].waitForExistence(timeout: 20),
            "the promotion picker never opened"
        )
        // It arrives on a spring. Measured mid-bounce the card is scaled past
        // its own bounds and the audit reads that as a fault of the layout.
        Thread.sleep(forTimeInterval: 1)
        let log = AuditLog()
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ]) { issue in
            log.add(issue)
            return true
        }
        XCTAssertTrue(
            log.issues.isEmpty,
            "promotion picker: " + log.issues.sorted().joined(separator: "; ")
        )
    }
}

// MARK: - Lesson diagrams

/// The boards inside "How to Play" are their own accessibility layer, built on
/// the same idea as the live board but exposing only the squares that carry
/// something — a piece, or a move on offer. These tests hold that layer to its
/// promise, and check that laying it over the board did not swallow the taps
/// that make a lesson diagram playable.
@MainActor
final class TutorialAccessibilityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Straight to the knight's page: a white knight on d5, a black king on h8,
    /// a white king on a1, and eight squares the knight may jump to.
    private func launchIntoKnightLesson() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--tutorial-chapter=pieces", "--tutorial-page=3",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    private func square(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", label))
            .firstMatch
    }

    func testLessonDiagramIsANamedContainer() {
        let app = launchIntoKnightLesson()
        let diagram = app.otherElements["Lesson diagram"]
        XCTAssertTrue(diagram.waitForExistence(timeout: 10), "a lesson board should name itself")
        // An empty value is exactly the regression this guards against — the
        // focus piece not being wired through — so it is not accepted.
        let value = diagram.value as? String ?? ""
        XCTAssertTrue(
            value.contains("knight") && value.contains("d 5"),
            "the diagram should say which piece the lesson is about, got \"\(value)\""
        )
    }

    func testLessonDiagramReadsOutItsPieces() {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))

        for label in ["d 5, white knight", "h 8, black king", "a 1, white king"] {
            XCTAssertTrue(
                square(app, label).exists,
                "expected the diagram to describe a square as \"\(label)\""
            )
        }
    }

    func testTheMovesOnOfferAreReachable() {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))

        // The knight on d5 reaches these; each one has to be an element a
        // VoiceOver reader can land on and activate.
        for label in ["b 4, empty", "b 6, empty", "c 3, empty", "c 7, empty",
                      "e 3, empty", "e 7, empty", "f 4, empty", "f 6, empty"] {
            XCTAssertTrue(square(app, label).exists, "\(label) is on offer but invisible to VoiceOver")
        }
    }

    /// A diagram is read far more often than it is played, so an empty square
    /// with nothing on offer is deliberately left out rather than padding every
    /// lesson page with sixty-four stops.
    func testEmptySquaresWithNothingOnOfferAreNotElements() {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))
        for label in ["a 8, empty", "h 1, empty", "d 4, empty"] {
            XCTAssertFalse(
                square(app, label).exists,
                "\(label) carries nothing and should not be a stop on the sweep"
            )
        }
    }

    /// The accessibility layer sits on top of the diagram, so this is the test
    /// that would catch it swallowing the taps that play a lesson move.
    func testTappingAnOfferedSquarePlaysTheMove() {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))

        square(app, "f 6, empty").tap()

        XCTAssertTrue(
            square(app, "f 6, white knight").waitForExistence(timeout: 5),
            "tapping f6 should have jumped the knight there"
        )
        XCTAssertTrue(app.buttons["Put the pieces back"].exists, "a played diagram should offer a reset")
    }

    /// The reset pill only exists once a lesson move has been played, which is
    /// why no audit had ever seen it: the screen the audit opens does not have
    /// one. It is caption2 text in two 6 pt paddings — 26 pt of pill — so what
    /// the finger has to hit is padded out around it.
    func testAPlayedLessonKeepsItsControlsTappable() {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))
        square(app, "f 6, empty").tap()

        let reset = app.buttons["Put the pieces back"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        assertTappable(reset)
        assertTappable(app.buttons["Previous page"])
        assertTappable(app.buttons["Next"])
    }

    func testLessonScreenPassesAccessibilityAudit() throws {
        let app = launchIntoKnightLesson()
        XCTAssertTrue(app.otherElements["Lesson diagram"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ])
    }

    func testTutorialContentsPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--tutorial", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // Case matters: "The board" would be satisfied by the footer sentence
        // ("The boards in the lessons are live…"), not by the chapter row.
        let firstChapter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "The Board"))
            .firstMatch
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10), "the contents should list the chapters")
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ])
    }
}

// MARK: - Game review

/// The review is the densest screen in the app — an evaluation curve, a strip
/// of graded moves and a board that is stepped through rather than played — and
/// it was the one screen no audit covered. These tests hold it to the same bar
/// as the board and the lessons.
@MainActor
final class ReviewAccessibilityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Straight into the review of a finished Evans Gambit, so the screen has a
    /// real game behind it: a curve to draw, graded moves and a named opening.
    private func launchIntoReview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--review-script=e2e4,e7e5,g1f3,b8c6,f1c4,f8c5,b2b4,c5b4,c2c3,b4a5,d2d4,e5d4,e1g1,d4c3",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    func testReviewBoardReadsOutItsPieces() {
        let app = launchIntoReview()
        XCTAssertTrue(app.otherElements["Position"].waitForExistence(timeout: 15),
                      "the review board should be a named container")
        // The final position of the scripted game: a black pawn has just taken
        // on c3 and White has castled.
        for label in ["c 3, black pawn", "g 1, white king", "a 5, black bishop"] {
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", label))
                    .firstMatch.exists,
                "expected the review board to describe a square as \"\(label)\""
            )
        }
    }

    /// The curve is drawn into a `Canvas`, which says nothing on its own. It has
    /// to name itself and report where the game stands at the position on the
    /// board — otherwise the whole graph is silent to a VoiceOver reader.
    func testEvaluationGraphIsReadableAndTracksTheBoard() {
        let app = launchIntoReview()
        XCTAssertTrue(app.otherElements["Position"].waitForExistence(timeout: 15))

        let graph = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Evaluation graph"))
            .firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 15), "the evaluation graph should name itself")

        // Wait for the engine to finish, not merely to say something. Sampled
        // mid-analysis the curve is a handful of real evaluations followed by
        // the last of them carried forward, so its start and its end can
        // legitimately read the same — which made this test fail about as
        // often as the engine's speed happened to line up with the polling.
        // The finished curve is reproducible, because the review is bounded by
        // a node count rather than by the clock.
        let progress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Analyzing your game…"))
            .firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: progress)
        waitForExpectations(timeout: 180)

        // The review opens on the final position, where Black is a pawn up out
        // of the gambit. Jumping back to move one has to change what the graph
        // reads out, or it is not following the board at all.
        let atEnd = graph.value as? String ?? ""
        XCTAssertTrue(
            atEnd.contains("ahead by") || atEnd.contains("Level position")
                || atEnd.contains("mates in"),
            "the graph should report an evaluation, got \"\(atEnd)\""
        )
        app.buttons["Start"].tap()
        expectation(for: NSPredicate(format: "value != %@", atEnd), evaluatedWith: graph)
        waitForExpectations(timeout: 15)
    }

    func testReviewScreenPassesAccessibilityAudit() throws {
        let app = launchIntoReview()
        XCTAssertTrue(app.otherElements["Position"].waitForExistence(timeout: 15))
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait,
        ])
    }

    /// The audit above says nothing about size — it passed a 26 pt button
    /// elsewhere in the app — so the review's own chrome is measured.
    func testReviewControlsAreBigEnoughToTap() {
        let app = launchIntoReview()
        XCTAssertTrue(app.otherElements["Position"].waitForExistence(timeout: 15))
        for name in ["Close the review", "Flip the board", "Start", "Back", "Replay", "Next", "End"] {
            assertTappable(app.buttons[name])
        }
    }
}
