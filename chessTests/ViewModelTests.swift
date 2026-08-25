//
//  ViewModelTests.swift
//  chessTests
//
//  The layers between the engine and the screen: the review's animated board,
//  the notation shown to the reader, and the opening book that names a game.
//

import Foundation
import Testing
@testable import chess

// MARK: - Review board

/// Stepping through a finished game moves pieces one at a time rather than
/// rebuilding the board, so that SwiftUI can animate them. That shortcut is
/// only safe while it agrees with the position it is meant to be showing —
/// which is what these tests hold it to.
@Suite("Review board")
@MainActor
struct GameReviewModelTests {

    private func game(_ ucis: [String], from fen: String = Board.startFEN) throws -> Game {
        var game = Game(fen: fen)
        for uci in ucis {
            game.play(try #require(game.legalMoves.first { $0.uci == uci }, "no legal \(uci)"))
        }
        return game
    }

    /// Every piece the review draws, on the square the real position has it —
    /// and nothing drawn twice on one square.
    private func expectBoardIsDrawnCorrectly(
        _ model: GameReviewModel, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var drawn = [UInt8](repeating: 0, count: 64)
        for rendered in model.pieces {
            #expect(
                drawn[rendered.square.index] == 0,
                "\(context): two pieces drawn on \(rendered.square)",
                sourceLocation: sourceLocation
            )
            drawn[rendered.square.index] = rendered.piece.packed
        }
        #expect(
            drawn == model.board.squares,
            "\(context): the drawn pieces are not the position at ply \(model.plyIndex)",
            sourceLocation: sourceLocation
        )
    }

    private func walkThroughAndBack(
        _ game: Game, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let model = GameReviewModel(game: game, mode: .twoPlayer)

        model.goToStart()
        expectBoardIsDrawnCorrectly(model, "\(context), start", sourceLocation: sourceLocation)
        while model.canStepForward {
            model.stepForward()
            expectBoardIsDrawnCorrectly(
                model, "\(context), forward to ply \(model.plyIndex)", sourceLocation: sourceLocation
            )
        }
        while model.canStepBack {
            model.stepBackward()
            expectBoardIsDrawnCorrectly(
                model, "\(context), back to ply \(model.plyIndex)", sourceLocation: sourceLocation
            )
        }
    }

    @Test("Castling and en passant survive a walk through the game")
    func specialMovesStepCorrectly() throws {
        // 1.e4 e6 2.e5 d5 3.exd6 cxd6 4.Nf3 Nf6 5.Bc4 Be7 6.O-O O-O
        let played = try game([
            "e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
            "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"
        ])
        #expect(played.history.contains { $0.move.isEnPassant })
        #expect(played.history.count { $0.move.isCastle } == 2)
        walkThroughAndBack(played, "special moves")
    }

    @Test("Promotions survive a walk through the game")
    func promotionsStepCorrectly() throws {
        // axb8=Q+ Kg7 g4 Kf6 g5+ Ke6 g6 Kd7 gxh7 Ke6 h8=N — a pawn takes a
        // knight and becomes a queen, and a second one under-promotes.
        let played = try game(
            ["a7b8q", "h8g7", "g2g4", "g7f6", "g4g5", "f6e6", "g5g6", "e6d7", "g6h7", "d7e6", "h7h8n"],
            from: "1n5k/P6p/8/8/8/8/6P1/6K1 w - - 0 1"
        )
        #expect(played.history.count { $0.move.promotion != nil } == 2)
        #expect(played.history.contains { $0.move.promotion == .knight })
        #expect(played.history.contains { $0.move.promotion == .queen && $0.move.isCapture })
        walkThroughAndBack(played, "promotions")
    }

    /// Breadth rather than depth: games drawn from a fixed seed, biased towards
    /// the moves that make the render model interesting.
    @Test("Sixty games step forward and back without the board drifting")
    func randomGamesStepCorrectly() {
        var rng = Zobrist.SplitMix64(seed: 0xC0FFEE)
        var promotions = 0, enPassants = 0, castles = 0

        for index in 0..<60 {
            var played = Game()
            while !played.outcome.isGameOver && played.history.count < 120 {
                let legal = played.legalMoves
                guard !legal.isEmpty else { break }
                let promoting = legal.filter { $0.promotion != nil }
                let capturing = legal.filter { $0.isCapture }
                let pool = !promoting.isEmpty && rng.next() % 2 == 0 ? promoting
                    : (!capturing.isEmpty && rng.next() % 3 != 0 ? capturing : legal)
                played.play(pool[Int(rng.next() % UInt64(pool.count))])
            }
            promotions += played.history.count { $0.move.promotion != nil }
            enPassants += played.history.count { $0.move.isEnPassant }
            castles += played.history.count { $0.move.isCastle }
            walkThroughAndBack(played, "game \(index)")
        }

        // The sweep is worthless if it never reached the awkward moves.
        #expect(promotions > 0, "no promotion in the sample")
        #expect(enPassants > 0, "no en passant in the sample")
        #expect(castles > 0, "no castling in the sample")
    }

    @Test("Jumping to an arbitrary position draws that position")
    func jumpingDrawsTheRightPosition() throws {
        let played = try game([
            "e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
            "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"
        ])
        let model = GameReviewModel(game: played, mode: .twoPlayer)
        for ply in [0, 5, 12, 3, 11, 1, 12, 0] {
            model.go(to: ply)
            #expect(model.plyIndex == ply)
            expectBoardIsDrawnCorrectly(model, "jump to \(ply)")
        }
    }

    @Test("Stepping forward by hand takes over from a replay")
    func steppingForwardStopsAutoplay() throws {
        let played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
        let model = GameReviewModel(game: played, mode: .twoPlayer)
        model.goToStart()
        model.toggleAutoplay()
        #expect(model.isAutoplaying)
        model.stepForward()
        #expect(!model.isAutoplaying, "a hand-driven step must not leave the replay running")
    }
}

// MARK: - Notation

@Suite("Notation")
struct MoveNotationTests {

    /// The Czech letters, so the mapping is exercised whatever language the
    /// test host happens to run in.
    nonisolated static let czech: [Character: Character] = [
        "K": "K", "Q": "D", "R": "V", "B": "S", "N": "J"
    ]

    nonisolated struct Case: CustomStringConvertible {
        let english: String
        let czech: String
        var description: String { "\(english) → \(czech)" }
    }

    nonisolated static let cases: [Case] = [
        Case(english: "e4", czech: "e4"),             // a pawn move names no piece
        Case(english: "Nf3", czech: "Jf3"),
        Case(english: "Qxd8+", czech: "Dxd8+"),
        Case(english: "Rae1", czech: "Vae1"),
        Case(english: "Bb5", czech: "Sb5"),
        Case(english: "Kg1", czech: "Kg1"),
        Case(english: "O-O", czech: "O-O"),           // castling is not a piece letter
        Case(english: "O-O-O", czech: "O-O-O"),
        Case(english: "e8=Q", czech: "e8=D"),         // what a pawn becomes is a piece letter
        Case(english: "bxa8=N#", czech: "bxa8=J#"),   // ...even after a capture, before the mate mark
        Case(english: "exd6", czech: "exd6"),         // a file letter is never a piece letter
        Case(english: "N1d2", czech: "J1d2"),         // rank disambiguation
        Case(english: "Nbxd7", czech: "Jbxd7"),       // file disambiguation on a capture
    ]

    @Test("Piece letters follow the language, everything else is left alone", arguments: cases)
    func lettersAreRewritten(testCase: Case) {
        #expect(MoveNotation.display(testCase.english, letters: Self.czech) == testCase.czech)
    }

    @Test("A language that writes the English letters changes nothing", arguments: cases)
    func identityMappingIsAPassThrough(testCase: Case) {
        #expect(MoveNotation.display(testCase.english, letters: [:]) == testCase.english)
    }

    @Test("What the app actually shows is stable for pawn moves")
    func displayLeavesPawnMovesAlone() {
        // True in every language: a pawn move carries no piece letter at all.
        #expect(MoveNotation.display("e4") == "e4")
        #expect(MoveNotation.display("exd5") == "exd5")
    }
}

// MARK: - Opening book

@Suite("Opening book")
struct OpeningBookTests {

    /// The book stores its names as `LocalizedStringResource`, so they follow
    /// the reader's language rather than whichever one the table was first
    /// touched in. `match` hands back words; resolve the same way it does so
    /// the two can be compared whatever language the tests run in.
    private func bookName(of moves: [String]) -> String? {
        OpeningBook.lines.first { $0.moves == moves }.map { String(localized: $0.name) }
    }

    @Test("A finished line names the opening")
    func namesACompletedLine() {
        let match = OpeningBook.match(sans: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4"])
        #expect(match.name == bookName(of: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4"]))
        #expect(match.bookPlies == 7)
    }

    @Test("A line the game has not finished does not name it")
    func doesNotNameAnUnfinishedLine() {
        // Four moves into the Najdorf it is still only a Sicilian.
        let match = OpeningBook.match(sans: ["e4", "c5", "Nf3"])
        #expect(match.name == bookName(of: ["e4", "c5"]))
        #expect(match.bookPlies == 3, "the third move still agrees with the Open Sicilian")
    }

    @Test("Leaving theory stops the book count where it left")
    func stopsCountingWhenTheoryEnds() {
        let match = OpeningBook.match(sans: ["e4", "e5", "Qh5", "Nc6", "Bc4"])
        #expect(match.bookPlies == 2, "Qh5 is in no line in the book")
        #expect(match.name == bookName(of: ["e4", "e5"]))
    }

    @Test("Leaving a line on its last move still credits the moves before it")
    func creditsThePrefixOfALineLeftLate() {
        // Eight plies of the Closed Ruy López, then d3 where the line has O-O.
        // Ba4 and Nf6 were theory whatever came after them; a match that
        // demanded the whole overlap threw them out and answered 6, and the
        // review then graded two book moves.
        let match = OpeningBook.match(sans: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6", "d3"])
        #expect(match.bookPlies == 8)
        #expect(match.name == bookName(of: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"]),
                "only a line played to its end may name the opening")
    }

    @Test("Check and mate marks do not stop a line from matching")
    func ignoresCheckMarks() {
        #expect(OpeningBook.match(sans: ["e4", "e5", "Nf3+"]).bookPlies == 3)
    }

    @Test("An empty game matches nothing")
    func emptyGameMatchesNothing() {
        let match = OpeningBook.match(sans: [])
        #expect(match.name == nil)
        #expect(match.bookPlies == 0)
    }

    @Test("A line written without a check mark still matches a game that gives check")
    func checkMarksDoNotStopALineFromBeingNamed() {
        // The book writes the Bogo-Indian's last move "Bb4"; over the board it
        // is Bb4+, and `match` is what has to reconcile the two.
        let bogoIndian = ["d4", "Nf6", "c4", "e6", "Nf3", "Bb4"]
        let match = OpeningBook.match(sans: ["d4", "Nf6", "c4", "e6", "Nf3", "Bb4+"])
        #expect(match.bookPlies == 6)
        #expect(match.name == bookName(of: bogoIndian))
    }

    /// A line the engine cannot produce is a line no game will ever match, so
    /// the opening it names would be dead code. Book lines carry no check or
    /// mate marks by design — `match` strips those from the played moves — so
    /// they are stripped here too, and then the line must actually be named.
    @Test("Every line in the book is playable and names its opening")
    func everyLineIsPlayableAndNamed() throws {
        func withoutCheckMarks(_ san: String) -> String {
            san.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "#", with: "")
        }

        for line in OpeningBook.lines {
            let name = String(localized: line.name)
            var game = Game()
            var played: [String] = []
            for san in line.moves {
                let move = game.legalMoves.first { withoutCheckMarks(game.board.san(for: $0)) == san }
                #expect(move != nil, "\(name): no legal \(san) after \(played)")
                guard let move else { break }
                played.append(game.board.san(for: move))
                game.play(move)
            }
            guard played.count == line.moves.count else { continue }

            let match = OpeningBook.match(sans: played)
            #expect(match.name != nil, "\(name) is unreachable: playing it names nothing")
            #expect(
                match.bookPlies == line.moves.count,
                "\(name): played \(line.moves.count) book moves but only \(match.bookPlies) counted"
            )
        }
    }
}

// MARK: - Game board

/// The live board moves pieces one at a time so SwiftUI can animate them,
/// exactly the shortcut the review board takes — and exactly as liable to
/// drift away from the position it is meant to be showing. The review board
/// has been held to that invariant for a while; this holds the board people
/// actually play on to the same one.
@Suite("Game board render model")
@MainActor
struct GameViewModelTests {

    /// Drives `body` as if the app were running, without letting its side
    /// effects escape: `GameViewModel` saves every move it plays, and a fuzz
    /// game has no business turning up afterwards under "Continue". The saves
    /// go to a scratch suite that is wiped on both sides — saving into the real
    /// one and restoring afterwards left the fuzz game behind whenever a test
    /// died before its `defer` ran.
    private func withoutDisturbingTheApp(_ body: () -> Void) {
        let suiteName = "chessTests.GameViewModelTests"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not open the scratch defaults suite")
            return
        }
        scratch.removePersistentDomain(forName: suiteName)
        let store = GameStore.defaults
        GameStore.defaults = scratch
        let sounds = SoundManager.shared.isEnabled
        let haptics = Haptics.isEnabled
        SoundManager.shared.isEnabled = false
        Haptics.isEnabled = false
        defer {
            SoundManager.shared.isEnabled = sounds
            Haptics.isEnabled = haptics
            GameStore.defaults = store
            scratch.removePersistentDomain(forName: suiteName)
        }
        body()
    }

    /// Every piece the board draws, on the square the real position has it —
    /// and nothing drawn twice on one square. The fading ghosts of captures
    /// live in `dyingPieces` and are deliberately not part of this.
    private func expectBoardIsDrawnCorrectly(
        _ model: GameViewModel, _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var drawn = [UInt8](repeating: 0, count: 64)
        for rendered in model.pieces {
            #expect(
                drawn[rendered.square.index] == 0,
                "\(context): two pieces drawn on \(rendered.square)",
                sourceLocation: sourceLocation
            )
            drawn[rendered.square.index] = rendered.piece.packed
        }
        #expect(
            drawn == model.game.board.squares,
            "\(context): the drawn pieces are not the position after \(model.game.history.count) plies",
            sourceLocation: sourceLocation
        )
    }

    /// Plays a move the way tapping the board does: tap the piece, tap where
    /// it should go, and answer the promotion picker when it opens.
    private func tap(
        _ model: GameViewModel, _ move: Move,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        model.handleTap(on: move.from)
        model.handleTap(on: move.to)
        if model.pendingPromotion != nil {
            model.completePromotion(with: move.promotion ?? .queen)
        }
        #expect(
            model.game.lastMove == move,
            "the board would not play \(move.uci)",
            sourceLocation: sourceLocation
        )
    }

    private func model(_ fen: String = Board.startFEN, settings: AppSettings) -> GameViewModel {
        GameViewModel(mode: .twoPlayer, settings: settings, restoredGame: Game(fen: fen))
    }

    @Test("Castling and en passant leave the drawn board matching the position")
    func specialMovesAreDrawnCorrectly() throws {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            // 1.e4 e6 2.e5 d5 3.exd6 cxd6 4.Nf3 Nf6 5.Bc4 Be7 6.O-O O-O
            for uci in ["e2e4", "e7e6", "e4e5", "d7d5", "e5d6", "c7d6",
                        "g1f3", "g8f6", "f1c4", "f8e7", "e1g1", "e8g8"] {
                guard let move = model.game.legalMoves.first(where: { $0.uci == uci }) else {
                    Issue.record("no legal \(uci)")
                    return
                }
                tap(model, move)
                expectBoardIsDrawnCorrectly(model, "after \(uci)")
            }
            #expect(model.game.history.contains { $0.move.isEnPassant })
            #expect(model.game.history.count { $0.move.isCastle } == 2)
        }
    }

    @Test("Every promotion the picker offers is drawn as the piece it made")
    func promotionsAreDrawnCorrectly() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                let model = model("1n5k/P6p/8/8/8/8/6P1/6K1 w - - 0 1", settings: settings)
                guard let move = model.game.legalMoves.first(where: {
                    $0.uci == "a7b8" + kind.letter.lowercased()
                }) else {
                    Issue.record("no promotion to \(kind)")
                    return
                }
                tap(model, move)
                expectBoardIsDrawnCorrectly(model, "after promoting to \(kind)")
                #expect(model.pieces.contains { $0.square.algebraic == "b8" && $0.piece.kind == kind })
            }
        }
    }

    /// Breadth rather than depth, the same way the review board is swept:
    /// games from a fixed seed, biased towards the moves that make the render
    /// model interesting.
    @Test("Twenty games play out without the drawn board drifting")
    func randomGamesAreDrawnCorrectly() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // Picked because it reaches all three awkward move kinds within
            // the sample, which the check at the bottom then insists on.
            var rng = Zobrist.SplitMix64(seed: 0xA11CE)
            var promotions = 0, enPassants = 0, castles = 0

            for index in 0..<20 {
                let model = model(settings: settings)
                while !model.game.outcome.isGameOver && model.game.history.count < 80 {
                    let legal = model.game.legalMoves
                    guard !legal.isEmpty else { break }
                    let promoting = legal.filter { $0.promotion != nil }
                    let capturing = legal.filter { $0.isCapture }
                    let pool = !promoting.isEmpty && rng.next() % 2 == 0 ? promoting
                        : (!capturing.isEmpty && rng.next() % 3 != 0 ? capturing : legal)
                    let move = pool[Int(rng.next() % UInt64(pool.count))]

                    if move.promotion != nil { promotions += 1 }
                    if move.isEnPassant { enPassants += 1 }
                    if move.isCastle { castles += 1 }

                    tap(model, move)
                    expectBoardIsDrawnCorrectly(model, "game \(index) after \(move.uci)")
                }
            }

            // The sweep is worthless if it never reached the awkward moves.
            #expect(promotions > 0, "no promotion in the sample")
            #expect(enPassants > 0, "no en passant in the sample")
            #expect(castles > 0, "no castling in the sample")
        }
    }

    @Test("A promotion square is offered one marker, not one per piece")
    func promotionOffersOneMarkerPerSquare() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // A pawn on b7 with a rook to take on either side: three squares
            // on offer, twelve moves that reach them.
            let model = model("r1r1k3/1P6/8/8/8/8/8/4K3 w - - 0 1", settings: settings)
            model.handleTap(on: Square(algebraic: "b7")!)

            #expect(model.legalTargets.count == 12, "twelve promotion moves")
            #expect(model.legalTargetSquares.count == 3, "drawn once per square")
            #expect(Set(model.legalTargetSquares.map(\.to.algebraic)) == ["a8", "b8", "c8"])
            // Stacking four translucent markers on one square makes it read as
            // a different, far bolder kind of dot than every other target.
            #expect(
                Set(model.legalTargetSquares.map(\.to.index)).count
                    == model.legalTargetSquares.count,
                "one marker per square"
            )
            #expect(model.legalTargetSquares.filter(\.isCapture).count == 2)
        }
    }

    @Test("An ordinary move offers one marker per square too")
    func ordinaryMovesOfferOneMarkerPerSquare() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            model.handleTap(on: Square(algebraic: "e2")!)
            #expect(model.legalTargets.count == 2)
            #expect(model.legalTargetSquares.count == 2, "no square deduplicated away")
        }
    }

    /// The guide has always listed agreement among the five ways a game is
    /// drawn, and for a while it was the one the app had no way to reach: the
    /// outcome, its headline and its Czech existed, but nothing could produce
    /// it. These pin the door open.
    @Test("Two players can settle for a draw")
    func twoPlayersCanAgreeToADraw() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            let model = model(settings: settings)
            tap(model, model.game.legalMoves.first { $0.uci == "e2e4" }!)

            #expect(model.canAgreeToDraw)
            model.agreeToDraw()

            #expect(model.game.outcome == .drawAgreed)
            #expect(model.game.outcome.isDraw)
            // The board is done with, the same way resigning leaves it.
            #expect(model.selectedSquare == nil)
            #expect(model.legalTargets.isEmpty)
            #expect(!model.canAgreeToDraw, "an agreed game cannot be agreed again")
            // And it is reviewable: the moves played are still there to grade.
            #expect(FinishedGame.load()?.outcome == .drawAgreed)
            #expect(SavedGame.load() == nil, "a finished game is not on offer to continue")
        }
    }

    @Test("Against the computer there is nobody to agree with")
    func theComputerIsNotOfferedADraw() {
        let settings = AppSettings()
        withoutDisturbingTheApp {
            // White is the human and is on turn, so no search starts here.
            let model = GameViewModel(
                mode: .vsAI(difficulty: .beginner, playerColor: .white),
                settings: settings
            )
            #expect(!model.canAgreeToDraw, "the button is not offered")
            model.agreeToDraw()
            #expect(model.game.outcome == .ongoing, "and calling it anyway changes nothing")
            model.teardown()
        }
    }
}

// MARK: - Tutorial content

/// The guide's positions are hand-written FENs, and a diagram with a typo in
/// it fails quietly: a rank shifted by one file still draws a board, just the
/// wrong one, and a focus square naming an empty square draws a lesson with no
/// moves on it. Nothing else in the app reads these, so nothing else would
/// notice.
@Suite("Tutorial content")
struct TutorialContentTests {

    nonisolated struct Diagram: CustomTestStringConvertible {
        let chapter: String
        let page: Int
        let diagram: TutorialDiagram
        var testDescription: String { "\(chapter) page \(page)" }
    }

    nonisolated static let diagrams: [Diagram] = TutorialGuide.chapters.flatMap { chapter in
        chapter.pages.enumerated().compactMap { index, page in
            page.diagram.map { Diagram(chapter: chapter.id, page: index + 1, diagram: $0) }
        }
    }

    @Test("Every diagram's FEN describes a whole board", arguments: diagrams)
    func fenCoversEveryRankAndFile(entry: Diagram) throws {
        let field = try #require(entry.diagram.fen.split(separator: " ").first, "empty FEN")
        let ranks = field.split(separator: "/")
        #expect(ranks.count == 8, "\(ranks.count) ranks in \(entry.diagram.fen)")
        for (row, rank) in ranks.enumerated() {
            var files = 0
            for character in rank {
                if let skip = character.wholeNumberValue, (1...8).contains(skip) {
                    files += skip
                } else if Piece(fenCharacter: character) != nil {
                    files += 1
                } else {
                    Issue.record("rank \(8 - row) of \(entry.diagram.fen) has junk '\(character)' in it")
                }
            }
            #expect(files == 8, "rank \(8 - row) of \(entry.diagram.fen) covers \(files) files")
        }
    }

    @Test("Every square a diagram points at is a real square", arguments: diagrams)
    func squaresAreReal(entry: Diagram) {
        let diagram = entry.diagram
        if diagram.focus != nil {
            #expect(diagram.focusSquare != nil, "focus '\(diagram.focus!)' is not a square")
        }
        #expect(
            diagram.highlightSquares.count == diagram.highlights.count,
            "a highlight is not a square: \(diagram.highlights)"
        )
        for arrow in diagram.arrows {
            #expect(arrow.squares != nil, "arrow \(arrow.from)-\(arrow.to) is not a pair of squares")
        }
    }

    /// A lesson that offers a piece's moves has to have that piece, in a
    /// position the engine will read, belonging to the side on turn. Get any
    /// of the three wrong and the lesson silently shows a board with no dots.
    @Test("A diagram that offers moves really has a piece to move", arguments: diagrams)
    func focusedDiagramsOfferMoves(entry: Diagram) throws {
        guard let focus = entry.diagram.focusSquare else { return }
        let board = try #require(
            Board(fen: entry.diagram.fen),
            "a diagram with a focus square must be a position the engine reads: \(entry.diagram.fen)"
        )
        let piece = try #require(board.piece(at: focus), "nothing stands on \(focus)")
        #expect(
            piece.color == board.sideToMove,
            "\(focus) holds a \(piece.color) piece but \(board.sideToMove) is to move"
        )

        let hasMoves = !board.legalMoves(from: focus).isEmpty
        if Self.deliberatelyStuck.contains(entry.testDescription) {
            #expect(!hasMoves, "\(entry.testDescription) is listed as a piece that cannot move, but it can")
        } else {
            #expect(hasMoves, "\(focus) can move nowhere, so the lesson shows a board with no dots")
        }
    }

    /// The four lessons whose whole point is a piece that cannot move. Listing
    /// them by name is what lets every other diagram be held to the opposite
    /// rule instead of the test having to guess which silence is intended.
    nonisolated static let deliberatelyStuck: Set<String> = [
        "check page 3",     // back-rank checkmate
        "check page 4",     // stalemate
        "tactics page 2",   // a knight pinned to its king
        "strategy page 6",  // checkmate with the king walked in
    ]
}
