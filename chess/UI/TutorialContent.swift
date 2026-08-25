//
//  TutorialContent.swift
//  chess
//
//  The text and the board positions of the "How to Play" guide. Plain data,
//  no UI. The positions are FENs the engine itself reads, so the move dots in
//  a lesson are produced by the same code that runs a real game.
//

import Foundation

// MARK: - Arrow

/// An arrow drawn on a lesson board.
nonisolated struct TutorialArrow: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        /// A move being demonstrated.
        case move
        /// A line of attack.
        case attack
    }

    let from: String
    let to: String
    var kind: Kind = .move

    var squares: (from: Square, to: Square)? {
        guard let from = Square(algebraic: from), let to = Square(algebraic: to) else { return nil }
        return (from, to)
    }

    static func move(_ from: String, _ to: String) -> TutorialArrow {
        TutorialArrow(from: from, to: to, kind: .move)
    }

    static func attack(_ from: String, _ to: String) -> TutorialArrow {
        TutorialArrow(from: from, to: to, kind: .attack)
    }
}

// MARK: - Diagram

/// One board picture inside a lesson.
nonisolated struct TutorialDiagram: Hashable, Sendable {
    var fen: String
    var orientation: PieceColor = .white
    /// Square of the piece whose legal moves are offered. The dots come from
    /// the engine, and tapping one really plays the move.
    var focus: String?
    /// Squares tinted to draw the eye.
    var highlights: [String] = []
    var arrows: [TutorialArrow] = []
    /// One line printed under the board.
    var caption: LocalizedStringResource?

    var focusSquare: Square? {
        focus.flatMap { Square(algebraic: $0) }
    }

    var highlightSquares: [Square] {
        highlights.compactMap { Square(algebraic: $0) }
    }

    // `LocalizedStringResource` is `Equatable` but not `Hashable`, so `==`
    // is still synthesized and only the hash has to be written out. It goes
    // over the caption's key, which is what tells two captions apart before
    // either has been turned into words.
    func hash(into hasher: inout Hasher) {
        hasher.combine(fen)
        hasher.combine(orientation)
        hasher.combine(focus)
        hasher.combine(highlights)
        hasher.combine(arrows)
        hasher.combine(caption?.key)
    }
}

// MARK: - Page

nonisolated struct TutorialPage: Hashable, Sendable {
    var heading: LocalizedStringResource
    var text: LocalizedStringResource
    var bullets: [LocalizedStringResource] = []
    var diagram: TutorialDiagram?
    /// An extra panel the page wants underneath its text.
    var extra: Extra?

    nonisolated enum Extra: Hashable, Sendable {
        /// What each piece is worth.
        case pieceValues
        /// The grades the game review hands out.
        case moveGrades
    }

    /// Hashed over the keys for the same reason `TutorialDiagram` is;
    /// `==` stays synthesized.
    func hash(into hasher: inout Hasher) {
        hasher.combine(heading.key)
        hasher.combine(text.key)
        hasher.combine(bullets.map(\.key))
        hasher.combine(diagram)
        hasher.combine(extra)
    }
}

// MARK: - Chapter

nonisolated struct TutorialChapter: Hashable, Sendable, Identifiable {
    var id: String
    var title: LocalizedStringResource
    var summary: LocalizedStringResource
    var icon: Icon
    var pages: [TutorialPage]

    nonisolated enum Icon: Hashable, Sendable {
        case symbol(String)
        case piece(PieceKind)
    }

    // Written out on the id alone, the way `BoardTheme`'s is: the id is what
    // `chapter(id:)` looks a chapter up by, what the contents screen keys its
    // rows on, what the navigation path carries and what a chapter having been
    // read is recorded against in settings. Two chapters are the same chapter
    // exactly when their ids agree.
    static func == (lhs: TutorialChapter, rhs: TutorialChapter) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - The guide

nonisolated enum TutorialGuide {

    /// The nine lessons, in the order the contents screen lists them.
    ///
    /// Every string in here is a `LocalizedStringResource` rather than an
    /// already translated `String`, for the reason `OpeningBook.Line.name`
    /// and `BoardTheme.name` are: the chapters are `static let`s, so a
    /// `String(localized:)` in one would be resolved once, on whatever thread
    /// first opened the guide, and keep that wording for the life of the
    /// process. A resource carries the key instead and becomes words where it
    /// is drawn. This is by far the largest body of text in the app, so it is
    /// the last place that rule should have gone unapplied.
    static let chapters: [TutorialChapter] = [
        board, pieces, specialMoves, checkAndMate, endings, tactics, strategy, notation, thisApp
    ]

    static func chapter(id: String) -> TutorialChapter? {
        chapters.first { $0.id == id }
    }

    // MARK: 1 · The board

    private static let board = TutorialChapter(
        id: "board",
        title: LocalizedStringResource("The Board"),
        summary: LocalizedStringResource("64 squares, and how they are named"),
        icon: .symbol("square.grid.3x3.fill"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Two armies, 64 squares"),
                text: LocalizedStringResource("""
                    Chess is a battle between White and Black on a board of \
                    eight columns and eight rows. White always makes the first \
                    move, and from then on the players take turns — one move \
                    each, no passing, no skipping.
                    """),
                bullets: [
                    LocalizedStringResource("The columns are called files and are lettered a to h."),
                    LocalizedStringResource("The rows are called ranks and are numbered 1 to 8."),
                    LocalizedStringResource("Rank 1 is White's home row, rank 8 is Black's.")
                ],
                diagram: TutorialDiagram(
                    fen: "8/8/8/8/8/8/8/8 w - - 0 1",
                    caption: LocalizedStringResource("Files run away from you, ranks run across.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Every square has a name"),
                text: LocalizedStringResource("""
                    A square is named after its file and its rank. The square \
                    where the e-file crosses the fourth rank is e4. That is how \
                    chess moves are written, and it is how the move list in this \
                    app reads.
                    """),
                diagram: TutorialDiagram(
                    fen: "8/8/8/8/8/8/8/8 w - - 0 1",
                    highlights: ["e4"],
                    caption: LocalizedStringResource("The highlighted square is e4.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Setting it up"),
                text: LocalizedStringResource("""
                    Pawns fill the second rank in front of the pieces. Rooks go \
                    in the corners, then knights, then bishops, and the king and \
                    queen take the last two squares. The queen always starts on \
                    a square of her own colour: the white queen on light d1, the \
                    black queen on dark d8.
                    """),
                bullets: [
                    LocalizedStringResource("Turn the board so that each player has a light square in the near right corner."),
                    LocalizedStringResource("The two kings face each other on the e-file, the two queens on the d-file.")
                ],
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    highlights: ["h1"],
                    caption: LocalizedStringResource("h1, the near right corner, is a light square.")
                )
            )
        ]
    )

    // MARK: 2 · How the pieces move

    private static let pieces = TutorialChapter(
        id: "pieces",
        title: LocalizedStringResource("How the Pieces Move"),
        summary: LocalizedStringResource("All six pieces, one at a time"),
        icon: .piece(.knight),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("The pawn"),
                text: LocalizedStringResource("""
                    A pawn plods one square straight forward. From its starting \
                    square it may jump two squares instead. A pawn can never \
                    move backwards, and it cannot move forward onto an occupied \
                    square — not even to capture.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",
                    focus: "e2",
                    caption: LocalizedStringResource("Tap a dot to move the pawn.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The pawn captures sideways"),
                text: LocalizedStringResource("""
                    A pawn takes one square diagonally forward. So it moves in \
                    one direction and captures in another — which is why pawns \
                    lock each other up head to head and yet guard each other so \
                    well side by side.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/3p1p2/4P3/4K3 w - - 0 1",
                    focus: "e2",
                    caption: LocalizedStringResource("Rings are captures, dots are quiet moves.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The knight"),
                text: LocalizedStringResource("""
                    The knight moves in an L: two squares along one line, then \
                    one square across. It is the only piece that jumps — nothing \
                    in between can block it, and it always lands on a square of \
                    the opposite colour to the one it left.
                    """),
                bullets: [
                    LocalizedStringResource("A knight in the centre reaches eight squares; in the corner, only two."),
                    LocalizedStringResource("It is the piece that gets out of a crowded position most easily.")
                ],
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3N4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: LocalizedStringResource("Eight squares from the middle of the board.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The bishop"),
                text: LocalizedStringResource("""
                    A bishop slides any distance along a diagonal, as long as \
                    nothing stands in the way. Because it moves diagonally it \
                    can never change square colour: one of your bishops lives on \
                    light squares for the whole game, the other on dark ones.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3B4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: LocalizedStringResource("The bishop keeps to its own colour.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The rook"),
                text: LocalizedStringResource("""
                    A rook slides any distance along a rank or a file. It is at \
                    its best on an open file, where nothing blocks it, and on \
                    the seventh rank, where it attacks the enemy pawns from \
                    behind.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3R4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: LocalizedStringResource("Straight lines, any distance.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The queen"),
                text: LocalizedStringResource("""
                    The queen is a rook and a bishop in one: any distance along \
                    a rank, a file or a diagonal. She is far and away the \
                    strongest piece, which is also why she should not go hunting \
                    alone in the opening — smaller pieces chase her around and \
                    gain time.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3Q4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: LocalizedStringResource("Twenty-seven squares from d5.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The king"),
                text: LocalizedStringResource("""
                    The king moves one square in any direction. He is never \
                    actually captured: instead the rules forbid leaving him \
                    under attack, so a move that would expose your own king is \
                    simply not allowed. The two kings can also never stand next \
                    to each other.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3K4/8/8/8/8 w - - 0 1",
                    focus: "d5",
                    caption: LocalizedStringResource("One step at a time — but in every direction.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("What the pieces are worth"),
                text: LocalizedStringResource("""
                    Counting material is the quickest way to tell who is doing \
                    well. These rough values are what you weigh a trade against: \
                    a bishop for a rook is a good deal, a rook for a knight \
                    usually is not.
                    """),
                bullets: [
                    LocalizedStringResource("Two rooks or three minor pieces are worth roughly a queen."),
                    LocalizedStringResource("Values are a guide, not a law: an active knight can be worth more than a passive rook."),
                    LocalizedStringResource("The app shows the captured pieces and the material lead next to each player.")
                ],
                extra: .pieceValues
            )
        ]
    )

    // MARK: 3 · Special moves

    private static let specialMoves = TutorialChapter(
        id: "special",
        title: LocalizedStringResource("Three Special Moves"),
        summary: LocalizedStringResource("Castling, en passant, promotion"),
        icon: .symbol("sparkles"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Castling"),
                text: LocalizedStringResource("""
                    Once per game each player may castle: the king steps two \
                    squares towards a rook and that rook hops over him to the \
                    other side. It is the only move that shifts two pieces at \
                    once, and it does two useful things — the king hides behind \
                    his pawns and the rook comes into play.
                    """),
                diagram: TutorialDiagram(
                    fen: "r3k2r/pppqbppp/2np1n2/4p3/4P3/2NP1N2/PPPQBPPP/R3K2R w KQkq - 0 1",
                    focus: "e1",
                    caption: LocalizedStringResource("Tap g1 or c1: the king goes two squares, the rook lands on his other side.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("When castling is allowed"),
                text: LocalizedStringResource("""
                    Castling is fussy. All of these have to be true, or the move \
                    is not offered at all.
                    """),
                bullets: [
                    LocalizedStringResource("Neither the king nor that particular rook has moved yet."),
                    LocalizedStringResource("The squares between them are empty."),
                    LocalizedStringResource("The king is not in check right now."),
                    LocalizedStringResource("The king does not pass over, or land on, a square an enemy piece attacks."),
                    LocalizedStringResource("It does not matter whether the rook is attacked, or whether the rook crosses an attacked square.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("En passant"),
                text: LocalizedStringResource("""
                    A pawn that jumps two squares to slip past an enemy pawn can \
                    be taken anyway, as if it had only moved one square. This \
                    capture — en passant, "in passing" — is available on the very \
                    next move and never again.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
                    focus: "e5",
                    highlights: ["d5"],
                    caption: LocalizedStringResource("Black just played d7–d5. White may answer exd6.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Promotion"),
                text: LocalizedStringResource("""
                    A pawn that reaches the far side of the board turns into a \
                    queen, rook, bishop or knight of its own colour — your choice, \
                    and you can have as many queens as you can promote pawns. \
                    Almost everybody takes the queen.
                    """),
                bullets: [
                    LocalizedStringResource("This app asks which piece you want as soon as the pawn lands."),
                    LocalizedStringResource("Taking a knight instead of a queen is rare, but it can come with a check that a queen would not give.")
                ],
                diagram: TutorialDiagram(
                    fen: "k7/4P3/8/8/8/8/8/4K3 w - - 0 1",
                    focus: "e7",
                    caption: LocalizedStringResource("Tap e8: the pawn arrives and becomes a queen.")
                )
            )
        ]
    )

    // MARK: 4 · Check and checkmate

    private static let checkAndMate = TutorialChapter(
        id: "check",
        title: LocalizedStringResource("Check & Checkmate"),
        summary: LocalizedStringResource("The point of the whole game"),
        icon: .piece(.king),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Check"),
                text: LocalizedStringResource("""
                    When a piece attacks the enemy king, that is check. Nothing \
                    else may be done first: the player in check has to answer it \
                    with this move. Here the rook on e1 checks along the open \
                    e-file, so the black king must leave that file.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/8/8/4R2K b - - 0 1",
                    focus: "e8",
                    arrows: [.attack("e1", "e8")],
                    caption: LocalizedStringResource("Every legal move steps off the e-file.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Three ways out"),
                text: LocalizedStringResource("""
                    A check can be answered by moving the king away, by blocking \
                    the line between the attacker and the king, or by capturing \
                    the attacker. If none of them is possible, the game is over.
                    """),
                bullets: [
                    LocalizedStringResource("A check from a knight cannot be blocked — a knight jumps."),
                    LocalizedStringResource("Two pieces checking at once (a double check) can only be answered by moving the king.")
                ],
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/r7/8/8/4R1K1 b - - 0 1",
                    focus: "a4",
                    arrows: [.attack("e1", "e8")],
                    caption: LocalizedStringResource("The rook has exactly one legal move: e4, blocking the check.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Checkmate wins"),
                text: LocalizedStringResource("""
                    Checkmate is a check with no answer — and it ends the game on \
                    the spot. Below is the back-rank mate: the rook checks along \
                    the eighth rank, the black king cannot leave it, and his own \
                    pawns take away every escape square.
                    """),
                bullets: [
                    LocalizedStringResource("This is the most common way a beginner's game is lost."),
                    LocalizedStringResource("After castling, giving your king one free square in front of the pawns is worth a move.")
                ],
                diagram: TutorialDiagram(
                    fen: "R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1",
                    focus: "g8",
                    caption: LocalizedStringResource("No dots: Black has no legal move at all. Checkmate.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Stalemate is a draw"),
                text: LocalizedStringResource("""
                    If the player to move has no legal move but is not in check, \
                    the game is a draw — stalemate. It is the great escape of the \
                    losing side, so when you are far ahead, give the enemy king \
                    air and mate him properly.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/6Q1/8/8/8/8/6K1 b - - 0 1",
                    focus: "h8",
                    caption: LocalizedStringResource("Not in check, but nothing to play: a draw.")
                )
            )
        ]
    )

    // MARK: 5 · How games end

    private static let endings = TutorialChapter(
        id: "endings",
        title: LocalizedStringResource("How Games End"),
        summary: LocalizedStringResource("Wins, draws and the fifty-move rule"),
        icon: .symbol("flag.checkered"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Winning"),
                text: LocalizedStringResource("""
                    There are two ways to win: checkmate the enemy king, or have \
                    your opponent resign. Resigning is normal courtesy among \
                    players once a game is hopeless — the Resign button is in the \
                    row under the board.
                    """),
                bullets: [
                    LocalizedStringResource("There is no rule that you must take a piece, and no rule that pieces must be defended."),
                    LocalizedStringResource("A game with a clock can also be lost on time, but there is no clock in this app.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("The five draws"),
                text: LocalizedStringResource("""
                    A game that neither side can win is a draw, worth half a \
                    point to each player. Four of them the app spots by itself \
                    and tells you which one happened; the fifth is yours to \
                    settle — the Draw button under the board.
                    """),
                bullets: [
                    LocalizedStringResource("Stalemate: no legal move, but no check either."),
                    LocalizedStringResource("Not enough material: king against king, or king and a single knight or bishop, cannot mate."),
                    LocalizedStringResource("The fifty-move rule: fifty moves by each side with no capture and no pawn move."),
                    LocalizedStringResource("Threefold repetition: the same position, with the same player to move, for the third time."),
                    LocalizedStringResource("Agreement: both players simply settle for a draw — the Draw button, in a game of two players.")
                ],
                diagram: TutorialDiagram(
                    fen: "8/8/8/4k3/8/8/2K1B3/8 w - - 0 1",
                    caption: LocalizedStringResource("A king and one bishop can never force mate — dead drawn.")
                )
            )
        ]
    )

    // MARK: 6 · Tactics

    private static let tactics = TutorialChapter(
        id: "tactics",
        title: LocalizedStringResource("Winning Material"),
        summary: LocalizedStringResource("Forks, pins, skewers and what to look for"),
        icon: .symbol("bolt.fill"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("The fork"),
                text: LocalizedStringResource("""
                    A fork attacks two things at once. Your opponent can only \
                    save one of them, so the other is yours. Knights are the \
                    great forkers, because their jump attacks squares that no \
                    other piece would guard.
                    """),
                // The forked rook has to stand where *no* escape square of the
                // king reaches it, or the lesson does not hold: with the king
                // on h8 and the rook on f8 (which is where this diagram began)
                // both Kg8 and Kg7 defend it, so Nxf8 is answered by Kxf8 and
                // the fork wins a rook for a knight rather than a rook. Here
                // the king's five squares are f7, f8, g7, h7 and h8 and none
                // of them touches c8, so Nxc8 is free after every one of them.
                diagram: TutorialDiagram(
                    fen: "2r3k1/4N3/8/8/8/8/8/6K1 b - - 0 1",
                    focus: "g8",
                    highlights: ["c8"],
                    arrows: [.attack("e7", "g8"), .attack("e7", "c8")],
                    caption: LocalizedStringResource("King and rook at once: Black saves the king, White takes the rook.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The pin"),
                text: LocalizedStringResource("""
                    A pinned piece cannot move without exposing the king behind \
                    it — so, in the eyes of the rules, it often cannot move at \
                    all. Pin a defender and it stops defending; then pile more \
                    attackers onto it.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/4n3/8/8/8/4R1K1 b - - 0 1",
                    focus: "e5",
                    highlights: ["e5"],
                    arrows: [.attack("e1", "e8")],
                    caption: LocalizedStringResource("Tap the knight: it is pinned and has no legal move.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The skewer"),
                text: LocalizedStringResource("""
                    A skewer is a pin the other way round: the valuable piece is \
                    in front and has to move, and what stands behind it falls. \
                    Checks are the sharpest skewers, because the king has no \
                    choice.
                    """),
                // Same care as the fork: the rook checks from a distance so
                // that the king cannot step next to the queen it is abandoning.
                // Checking from e5 with the king on e6 (which is where this
                // diagram began) left d7 and f7 among the escapes, and from
                // either of them Rxe8 is met by Kxe8. From e1 the king's six
                // squares are d3, d4, d5, f3, f4 and f5, none of which touches
                // e8, so the queen really is lost.
                diagram: TutorialDiagram(
                    fen: "4q3/8/8/8/4k3/8/8/4R1K1 b - - 0 1",
                    focus: "e4",
                    highlights: ["e8"],
                    arrows: [.attack("e1", "e8")],
                    caption: LocalizedStringResource("The king must step aside, and the rook collects the queen.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("A few more patterns"),
                text: LocalizedStringResource("""
                    Almost every material win comes from one of a handful of \
                    ideas. Once you know their names you start seeing them.
                    """),
                bullets: [
                    LocalizedStringResource("Discovered attack: you move one piece and the piece behind it starts attacking."),
                    LocalizedStringResource("Double attack: one move creates two threats — a fork is the version with one piece."),
                    LocalizedStringResource("Removing the defender: capture or chase away the piece that guards your target."),
                    LocalizedStringResource("Overloading: a defender given two jobs cannot do both."),
                    LocalizedStringResource("Back rank: a castled king with no escape square is a permanent weakness.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("Before every move"),
                text: LocalizedStringResource("""
                    Most games between beginners are decided by pieces given \
                    away for nothing, not by deep plans. Four quick questions \
                    prevent nearly all of it.
                    """),
                bullets: [
                    LocalizedStringResource("What did that last move threaten?"),
                    LocalizedStringResource("Is anything of mine attacked and undefended?"),
                    LocalizedStringResource("Can I take something for free, or give check with effect?"),
                    LocalizedStringResource("If I play this, what is the best reply?")
                ]
            )
        ]
    )

    // MARK: 7 · Playing well

    private static let strategy = TutorialChapter(
        id: "strategy",
        title: LocalizedStringResource("Playing Well"),
        summary: LocalizedStringResource("Opening principles and simple plans"),
        icon: .symbol("lightbulb.fill"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Take the centre"),
                text: LocalizedStringResource("""
                    A piece in the middle of the board controls more squares than \
                    one at the edge, and pawns in the centre take space away from \
                    your opponent. That is why almost every opening starts with \
                    1.e4 or 1.d4.
                    """),
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    highlights: ["d4", "e4", "d5", "e5"],
                    caption: LocalizedStringResource("The four squares both sides are fighting over.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Get your pieces out"),
                text: LocalizedStringResource("""
                    In the first ten moves, aim to have every knight and bishop \
                    off its starting square and pointing at the centre. A piece \
                    at home does nothing, and material means little if your \
                    opponent's army is developed and yours is not.
                    """),
                bullets: [
                    LocalizedStringResource("Knights before bishops is a useful habit."),
                    LocalizedStringResource("Do not move the same piece again and again in the opening."),
                    LocalizedStringResource("Leave the queen at home for a while: she is easy to chase, and every check she has to run from costs you a move."),
                    LocalizedStringResource("Move each pawn only as far as your pieces need.")
                ],
                diagram: TutorialDiagram(
                    fen: "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1",
                    caption: LocalizedStringResource("After 1.e4 e5 2.Nf3 Nc6 3.Bc4 Bc5 — both sides developing.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Castle early"),
                text: LocalizedStringResource("""
                    The king is safest behind an untouched wall of pawns, and \
                    castling puts him there while bringing a rook towards the \
                    centre. As a rule: develop two or three pieces, castle, then \
                    start looking for a plan.
                    """),
                diagram: TutorialDiagram(
                    fen: "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQ1RK1 b kq - 0 1",
                    highlights: ["g1", "f1"],
                    caption: LocalizedStringResource("White has castled: king tucked in, rook joining the game.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Trade with a purpose"),
                text: LocalizedStringResource("""
                    Every capture changes the balance. Count before you take: if \
                    the material after the whole exchange is in your favour, take; \
                    if not, do not. When you are ahead, trading pieces makes your \
                    lead bigger and the position simpler.
                    """),
                bullets: [
                    LocalizedStringResource("Ahead in material: trade pieces, head for the endgame."),
                    LocalizedStringResource("Behind in material: keep pieces on and make things complicated."),
                    LocalizedStringResource("Before a capture, count every attacker and every defender of that square.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("Give your pieces work"),
                text: LocalizedStringResource("""
                    Good moves usually improve a piece: a rook onto an open file, \
                    a knight to a square no pawn can chase it from, a bishop onto \
                    a long clear diagonal. If you have no plan, find your worst \
                    piece and make it better.
                    """),
                bullets: [
                    LocalizedStringResource("Rooks belong on open files and behind your own passed pawns."),
                    LocalizedStringResource("Knights need a safe square in or near the centre."),
                    LocalizedStringResource("Bishops want long diagonals — do not bury them behind your own pawns."),
                    LocalizedStringResource("Pawns cannot go back: think twice before you push one.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("The endgame"),
                text: LocalizedStringResource("""
                    With few pieces left the rules of thumb change. Pawns become \
                    precious, because one that gets through becomes a queen, and \
                    the king turns into a strong piece that should march towards \
                    the action instead of hiding.
                    """),
                bullets: [
                    LocalizedStringResource("Push the pawn your king can support, and blockade your opponent's."),
                    LocalizedStringResource("To mate, drive the enemy king to the edge and bring your own king up to help."),
                    LocalizedStringResource("A lone queen or rook plus king is enough to mate; a lone bishop or knight is not.")
                ],
                diagram: TutorialDiagram(
                    fen: "5k2/5Q2/5K2/8/8/8/8/8 b - - 0 1",
                    focus: "f8",
                    caption: LocalizedStringResource("Queen and king mate at the edge: the queen checks, the king guards her.")
                )
            )
        ]
    )

    // MARK: 8 · Notation

    private static let notation = TutorialChapter(
        id: "notation",
        title: LocalizedStringResource("Reading the Moves"),
        summary: LocalizedStringResource("What Nf3 and O-O mean"),
        icon: .symbol("text.book.closed.fill"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Piece plus square"),
                text: LocalizedStringResource("""
                    A move is written as the letter of the piece and the square \
                    it goes to: Nf3 is a knight to f3, Qd8 a queen to d8. Pawns \
                    have no letter, so e4 simply means a pawn moved to e4. The \
                    knight is N, because K is taken by the king.
                    """),
                bullets: [
                    LocalizedStringResource("K king · Q queen · R rook · B bishop · N knight · pawns: nothing"),
                    LocalizedStringResource("x is a capture: Bxc6, or exd5 for a pawn taking on d5."),
                    LocalizedStringResource("+ is check, # is checkmate: Qh5#."),
                    LocalizedStringResource("O-O is castling towards the h-file, O-O-O towards the a-file."),
                    LocalizedStringResource("=Q is a promotion: e8=Q. A file letter is added when two pieces could reach the square: Nbd2.")
                ],
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 1",
                    arrows: [.move("g1", "f3")],
                    caption: LocalizedStringResource("1.e4 e5 2.Nf3 — the moves that reached this position.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("Move numbers"),
                text: LocalizedStringResource("""
                    One number covers a move by each player: "1.e4 e5" is move \
                    one. When only Black's half is quoted it is written with \
                    dots, as in "1...e5". The strip under the board in this app \
                    lists the game exactly this way, newest move last.
                    """)
            )
        ]
    )

    // MARK: 9 · This app

    private static let thisApp = TutorialChapter(
        id: "app",
        title: LocalizedStringResource("Playing in This App"),
        summary: LocalizedStringResource("Moving pieces, hints and the game review"),
        icon: .symbol("hand.tap.fill"),
        pages: [
            TutorialPage(
                heading: LocalizedStringResource("Making a move"),
                text: LocalizedStringResource("""
                    Tap a piece and the dots show every square it may legally go \
                    to; tap one of them to play the move. Dragging the piece works \
                    too, and tapping it a second time puts it back down. Illegal \
                    moves are simply not offered, so you cannot go wrong.
                    """),
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    focus: "e2",
                    caption: LocalizedStringResource("Tap e4 to open the game.")
                )
            ),
            TutorialPage(
                heading: LocalizedStringResource("The buttons"),
                text: LocalizedStringResource("""
                    Under the board are the three controls you need during a \
                    game, and the top row takes you back to the menu or spins the \
                    board around.
                    """),
                bullets: [
                    LocalizedStringResource("Undo takes back your move — and the computer's reply with it."),
                    LocalizedStringResource("Hint asks the engine for the move it would play, in games against the computer; with two players that button offers a draw instead."),
                    LocalizedStringResource("Resign ends a hopeless game."),
                    LocalizedStringResource("Top right, the gear opens the settings and the arrows flip the board; the chevron at the top left returns to the menu, keeping the game so you can continue it later.")
                ]
            ),
            TutorialPage(
                heading: LocalizedStringResource("The game review"),
                text: LocalizedStringResource("""
                    When a game is over, Game Review plays it back and has the \
                    engine grade every single move, with an accuracy score for \
                    each player and a graph of who was winning when. It is the \
                    fastest way to find out what actually went wrong.
                    """),
                bullets: [
                    LocalizedStringResource("Swipe the board, or tap a move in the strip, to walk through the game."),
                    LocalizedStringResource("A green arrow shows the move the engine would have preferred."),
                    LocalizedStringResource("The last finished game stays on the menu, so you can review it again later.")
                ],
                extra: .moveGrades
            ),
            TutorialPage(
                heading: LocalizedStringResource("Settings"),
                text: LocalizedStringResource("""
                    The gear — in the menu, and in the top row of a game — \
                    holds five board themes, sounds and haptics, and the two \
                    helpers you may want to switch off as you improve: the \
                    legal-move dots and the coordinates around the board.
                    """),
                bullets: [
                    LocalizedStringResource("Flip board (two players) turns the board towards whoever is on the move."),
                    LocalizedStringResource("Five difficulty levels wait under Play vs Computer — the lowest ones play like a beginner on purpose.")
                ]
            )
        ]
    )
}
