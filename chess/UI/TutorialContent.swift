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
    var caption: String?

    var focusSquare: Square? {
        focus.flatMap { Square(algebraic: $0) }
    }

    var highlightSquares: [Square] {
        highlights.compactMap { Square(algebraic: $0) }
    }
}

// MARK: - Page

nonisolated struct TutorialPage: Hashable, Sendable {
    var heading: String
    var text: String
    var bullets: [String] = []
    var diagram: TutorialDiagram?
    /// An extra panel the page wants underneath its text.
    var extra: Extra?

    nonisolated enum Extra: Hashable, Sendable {
        /// What each piece is worth.
        case pieceValues
        /// The grades the game review hands out.
        case moveGrades
    }
}

// MARK: - Chapter

nonisolated struct TutorialChapter: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var icon: Icon
    var pages: [TutorialPage]

    nonisolated enum Icon: Hashable, Sendable {
        case symbol(String)
        case piece(PieceKind)
    }
}

// MARK: - The guide

nonisolated enum TutorialGuide {

    static let chapters: [TutorialChapter] = [
        board, pieces, specialMoves, checkAndMate, endings, tactics, strategy, notation, thisApp
    ]

    static func chapter(id: String) -> TutorialChapter? {
        chapters.first { $0.id == id }
    }

    // MARK: 1 · The board

    private static let board = TutorialChapter(
        id: "board",
        title: String(localized: "The Board"),
        summary: String(localized: "64 squares, and how they are named"),
        icon: .symbol("square.grid.3x3.fill"),
        pages: [
            TutorialPage(
                heading: String(localized: "Two armies, 64 squares"),
                text: String(localized: """
                    Chess is a battle between White and Black on a board of \
                    eight columns and eight rows. White always makes the first \
                    move, and from then on the players take turns — one move \
                    each, no passing, no skipping.
                    """),
                bullets: [
                    String(localized: "The columns are called files and are lettered a to h."),
                    String(localized: "The rows are called ranks and are numbered 1 to 8."),
                    String(localized: "Rank 1 is White's home row, rank 8 is Black's.")
                ],
                diagram: TutorialDiagram(
                    fen: "8/8/8/8/8/8/8/8 w - - 0 1",
                    caption: String(localized: "Files run away from you, ranks run across.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Every square has a name"),
                text: String(localized: """
                    A square is named after its file and its rank. The square \
                    where the e-file crosses the fourth rank is e4. That is how \
                    chess moves are written, and it is how the move list in this \
                    app reads.
                    """),
                diagram: TutorialDiagram(
                    fen: "8/8/8/8/8/8/8/8 w - - 0 1",
                    highlights: ["e4"],
                    caption: String(localized: "The highlighted square is e4.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Setting it up"),
                text: String(localized: """
                    Pawns fill the second rank in front of the pieces. Rooks go \
                    in the corners, then knights, then bishops, and the king and \
                    queen take the last two squares. The queen always starts on \
                    a square of her own colour: the white queen on light d1, the \
                    black queen on dark d8.
                    """),
                bullets: [
                    String(localized: "Turn the board so that each player has a light square in the near right corner."),
                    String(localized: "The two kings face each other on the e-file, the two queens on the d-file.")
                ],
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    highlights: ["h1"],
                    caption: String(localized: "h1, the near right corner, is a light square.")
                )
            )
        ]
    )

    // MARK: 2 · How the pieces move

    private static let pieces = TutorialChapter(
        id: "pieces",
        title: String(localized: "How the Pieces Move"),
        summary: String(localized: "All six pieces, one at a time"),
        icon: .piece(.knight),
        pages: [
            TutorialPage(
                heading: String(localized: "The pawn"),
                text: String(localized: """
                    A pawn plods one square straight forward. From its starting \
                    square it may jump two squares instead. A pawn can never \
                    move backwards, and it cannot move forward onto an occupied \
                    square — not even to capture.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",
                    focus: "e2",
                    caption: String(localized: "Tap a dot to move the pawn.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The pawn captures sideways"),
                text: String(localized: """
                    A pawn takes one square diagonally forward. So it moves in \
                    one direction and captures in another — which is why pawns \
                    lock each other up head to head and yet guard each other so \
                    well side by side.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/3p1p2/4P3/4K3 w - - 0 1",
                    focus: "e2",
                    caption: String(localized: "Rings are captures, dots are quiet moves.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The knight"),
                text: String(localized: """
                    The knight moves in an L: two squares along one line, then \
                    one square across. It is the only piece that jumps — nothing \
                    in between can block it, and it always lands on a square of \
                    the opposite colour to the one it left.
                    """),
                bullets: [
                    String(localized: "A knight in the centre reaches eight squares; in the corner, only two."),
                    String(localized: "It is the piece that gets out of a crowded position most easily.")
                ],
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3N4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: String(localized: "Eight squares from the middle of the board.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The bishop"),
                text: String(localized: """
                    A bishop slides any distance along a diagonal, as long as \
                    nothing stands in the way. Because it moves diagonally it \
                    can never change square colour: one of your bishops lives on \
                    light squares for the whole game, the other on dark ones.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3B4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: String(localized: "The bishop keeps to its own colour.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The rook"),
                text: String(localized: """
                    A rook slides any distance along a rank or a file. It is at \
                    its best on an open file, where nothing blocks it, and on \
                    the seventh rank, where it attacks the enemy pawns from \
                    behind.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3R4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: String(localized: "Straight lines, any distance.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The queen"),
                text: String(localized: """
                    The queen is a rook and a bishop in one: any distance along \
                    a rank, a file or a diagonal. She is far and away the \
                    strongest piece, which is also why she should not go hunting \
                    alone in the opening — smaller pieces chase her around and \
                    gain time.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3Q4/8/8/8/K7 w - - 0 1",
                    focus: "d5",
                    caption: String(localized: "Twenty-seven squares from d5.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The king"),
                text: String(localized: """
                    The king moves one square in any direction. He is never \
                    actually captured: instead the rules forbid leaving him \
                    under attack, so a move that would expose your own king is \
                    simply not allowed. The two kings can also never stand next \
                    to each other.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/8/3K4/8/8/8/8 w - - 0 1",
                    focus: "d5",
                    caption: String(localized: "One step at a time — but in every direction.")
                )
            ),
            TutorialPage(
                heading: String(localized: "What the pieces are worth"),
                text: String(localized: """
                    Counting material is the quickest way to tell who is doing \
                    well. These rough values are what you weigh a trade against: \
                    a bishop for a rook is a good deal, a rook for a knight \
                    usually is not.
                    """),
                bullets: [
                    String(localized: "Two rooks or three minor pieces are worth roughly a queen."),
                    String(localized: "Values are a guide, not a law: an active knight can be worth more than a passive rook."),
                    String(localized: "The app shows the captured pieces and the material lead next to each player.")
                ],
                extra: .pieceValues
            )
        ]
    )

    // MARK: 3 · Special moves

    private static let specialMoves = TutorialChapter(
        id: "special",
        title: String(localized: "Three Special Moves"),
        summary: String(localized: "Castling, en passant, promotion"),
        icon: .symbol("sparkles"),
        pages: [
            TutorialPage(
                heading: String(localized: "Castling"),
                text: String(localized: """
                    Once per game each player may castle: the king steps two \
                    squares towards a rook and that rook hops over him to the \
                    other side. It is the only move that shifts two pieces at \
                    once, and it does two useful things — the king hides behind \
                    his pawns and the rook comes into play.
                    """),
                diagram: TutorialDiagram(
                    fen: "r3k2r/pppqbppp/2np1n2/4p3/4P3/2NP1N2/PPPQBPPP/R3K2R w KQkq - 0 1",
                    focus: "e1",
                    caption: String(localized: "Tap g1 or c1: the king goes two squares, the rook lands on his other side.")
                )
            ),
            TutorialPage(
                heading: String(localized: "When castling is allowed"),
                text: String(localized: """
                    Castling is fussy. All of these have to be true, or the move \
                    is not offered at all.
                    """),
                bullets: [
                    String(localized: "Neither the king nor that particular rook has moved yet."),
                    String(localized: "The squares between them are empty."),
                    String(localized: "The king is not in check right now."),
                    String(localized: "The king does not pass over, or land on, a square an enemy piece attacks."),
                    String(localized: "It does not matter whether the rook is attacked, or whether the rook crosses an attacked square.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "En passant"),
                text: String(localized: """
                    A pawn that jumps two squares to slip past an enemy pawn can \
                    be taken anyway, as if it had only moved one square. This \
                    capture — en passant, "in passing" — is available on the very \
                    next move and never again.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
                    focus: "e5",
                    highlights: ["d5"],
                    caption: String(localized: "Black just played d7–d5. White may answer exd6.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Promotion"),
                text: String(localized: """
                    A pawn that reaches the far side of the board turns into a \
                    queen, rook, bishop or knight of its own colour — your choice, \
                    and you can have as many queens as you can promote pawns. \
                    Almost everybody takes the queen.
                    """),
                bullets: [
                    String(localized: "This app asks which piece you want as soon as the pawn lands."),
                    String(localized: "Taking a knight instead of a queen is rare, but it can come with a check that a queen would not give.")
                ],
                diagram: TutorialDiagram(
                    fen: "k7/4P3/8/8/8/8/8/4K3 w - - 0 1",
                    focus: "e7",
                    caption: String(localized: "Tap e8: the pawn arrives and becomes a queen.")
                )
            )
        ]
    )

    // MARK: 4 · Check and checkmate

    private static let checkAndMate = TutorialChapter(
        id: "check",
        title: String(localized: "Check & Checkmate"),
        summary: String(localized: "The point of the whole game"),
        icon: .piece(.king),
        pages: [
            TutorialPage(
                heading: String(localized: "Check"),
                text: String(localized: """
                    When a piece attacks the enemy king, that is check. Nothing \
                    else may be done first: the player in check has to answer it \
                    with this move. Here the rook on e1 checks along the open \
                    e-file, so the black king must leave that file.
                    """),
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/8/8/8/4R2K b - - 0 1",
                    focus: "e8",
                    arrows: [.attack("e1", "e8")],
                    caption: String(localized: "Every legal move steps off the e-file.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Three ways out"),
                text: String(localized: """
                    A check can be answered by moving the king away, by blocking \
                    the line between the attacker and the king, or by capturing \
                    the attacker. If none of them is possible, the game is over.
                    """),
                bullets: [
                    String(localized: "A check from a knight cannot be blocked — a knight jumps."),
                    String(localized: "Two pieces checking at once (a double check) can only be answered by moving the king.")
                ],
                diagram: TutorialDiagram(
                    fen: "4k3/8/8/8/r7/8/8/4R1K1 b - - 0 1",
                    focus: "a4",
                    arrows: [.attack("e1", "e8")],
                    caption: String(localized: "The rook has exactly one legal move: e4, blocking the check.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Checkmate wins"),
                text: String(localized: """
                    Checkmate is a check with no answer — and it ends the game on \
                    the spot. Below is the back-rank mate: the rook checks along \
                    the eighth rank, the black king cannot leave it, and his own \
                    pawns take away every escape square.
                    """),
                bullets: [
                    String(localized: "This is the most common way a beginner's game is lost."),
                    String(localized: "After castling, giving your king one free square in front of the pawns is worth a move.")
                ],
                diagram: TutorialDiagram(
                    fen: "R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1",
                    focus: "g8",
                    caption: String(localized: "No dots: Black has no legal move at all. Checkmate.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Stalemate is a draw"),
                text: String(localized: """
                    If the player to move has no legal move but is not in check, \
                    the game is a draw — stalemate. It is the great escape of the \
                    losing side, so when you are far ahead, give the enemy king \
                    air and mate him properly.
                    """),
                diagram: TutorialDiagram(
                    fen: "7k/8/6Q1/8/8/8/8/6K1 b - - 0 1",
                    focus: "h8",
                    caption: String(localized: "Not in check, but nothing to play: a draw.")
                )
            )
        ]
    )

    // MARK: 5 · How games end

    private static let endings = TutorialChapter(
        id: "endings",
        title: String(localized: "How Games End"),
        summary: String(localized: "Wins, draws and the fifty-move rule"),
        icon: .symbol("flag.checkered"),
        pages: [
            TutorialPage(
                heading: String(localized: "Winning"),
                text: String(localized: """
                    There are two ways to win: checkmate the enemy king, or have \
                    your opponent resign. Resigning is normal courtesy among \
                    players once a game is hopeless — the Resign button is in the \
                    row under the board.
                    """),
                bullets: [
                    String(localized: "There is no rule that you must take a piece, and no rule that pieces must be defended."),
                    String(localized: "A game with a clock can also be lost on time, but there is no clock in this app.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "The five draws"),
                text: String(localized: """
                    A game that neither side can win is a draw, worth half a \
                    point to each player. Four of them the app spots by itself \
                    and tells you which one happened; the fifth is yours to \
                    settle — the Draw button under the board.
                    """),
                bullets: [
                    String(localized: "Stalemate: no legal move, but no check either."),
                    String(localized: "Not enough material: king against king, or king and a single knight or bishop, cannot mate."),
                    String(localized: "The fifty-move rule: fifty moves by each side with no capture and no pawn move."),
                    String(localized: "Threefold repetition: the same position, with the same player to move, for the third time."),
                    String(localized: "Agreement: both players simply settle for a draw — the Draw button, in a game of two players.")
                ],
                diagram: TutorialDiagram(
                    fen: "8/8/8/4k3/8/8/2K1B3/8 w - - 0 1",
                    caption: String(localized: "A king and one bishop can never force mate — dead drawn.")
                )
            )
        ]
    )

    // MARK: 6 · Tactics

    private static let tactics = TutorialChapter(
        id: "tactics",
        title: String(localized: "Winning Material"),
        summary: String(localized: "Forks, pins, skewers and what to look for"),
        icon: .symbol("bolt.fill"),
        pages: [
            TutorialPage(
                heading: String(localized: "The fork"),
                text: String(localized: """
                    A fork attacks two things at once. Your opponent can only \
                    save one of them, so the other is yours. Knights are the \
                    great forkers, because their jump attacks squares that no \
                    other piece would guard.
                    """),
                diagram: TutorialDiagram(
                    fen: "5r1k/8/6N1/8/8/8/8/6K1 b - - 0 1",
                    focus: "h8",
                    highlights: ["f8"],
                    arrows: [.attack("g6", "h8"), .attack("g6", "f8")],
                    caption: String(localized: "King and rook at once: Black saves the king, White takes the rook.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The pin"),
                text: String(localized: """
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
                    caption: String(localized: "Tap the knight: it is pinned and has no legal move.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The skewer"),
                text: String(localized: """
                    A skewer is a pin the other way round: the valuable piece is \
                    in front and has to move, and what stands behind it falls. \
                    Checks are the sharpest skewers, because the king has no \
                    choice.
                    """),
                diagram: TutorialDiagram(
                    fen: "4q3/8/4k3/4R3/3P4/8/8/6K1 b - - 0 1",
                    focus: "e6",
                    highlights: ["e8"],
                    arrows: [.attack("e5", "e8")],
                    caption: String(localized: "The king must step aside, and the rook collects the queen.")
                )
            ),
            TutorialPage(
                heading: String(localized: "A few more patterns"),
                text: String(localized: """
                    Almost every material win comes from one of a handful of \
                    ideas. Once you know their names you start seeing them.
                    """),
                bullets: [
                    String(localized: "Discovered attack: you move one piece and the piece behind it starts attacking."),
                    String(localized: "Double attack: one move creates two threats — a fork is the version with one piece."),
                    String(localized: "Removing the defender: capture or chase away the piece that guards your target."),
                    String(localized: "Overloading: a defender given two jobs cannot do both."),
                    String(localized: "Back rank: a castled king with no escape square is a permanent weakness.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "Before every move"),
                text: String(localized: """
                    Most games between beginners are decided by pieces given \
                    away for nothing, not by deep plans. Four quick questions \
                    prevent nearly all of it.
                    """),
                bullets: [
                    String(localized: "What did that last move threaten?"),
                    String(localized: "Is anything of mine attacked and undefended?"),
                    String(localized: "Can I take something for free, or give check with effect?"),
                    String(localized: "If I play this, what is the best reply?")
                ]
            )
        ]
    )

    // MARK: 7 · Playing well

    private static let strategy = TutorialChapter(
        id: "strategy",
        title: String(localized: "Playing Well"),
        summary: String(localized: "Opening principles and simple plans"),
        icon: .symbol("lightbulb.fill"),
        pages: [
            TutorialPage(
                heading: String(localized: "Take the centre"),
                text: String(localized: """
                    A piece in the middle of the board controls more squares than \
                    one at the edge, and pawns in the centre take space away from \
                    your opponent. That is why almost every opening starts with \
                    1.e4 or 1.d4.
                    """),
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    highlights: ["d4", "e4", "d5", "e5"],
                    caption: String(localized: "The four squares both sides are fighting over.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Get your pieces out"),
                text: String(localized: """
                    In the first ten moves, aim to have every knight and bishop \
                    off its starting square and pointing at the centre. A piece \
                    at home does nothing, and material means little if your \
                    opponent's army is developed and yours is not.
                    """),
                bullets: [
                    String(localized: "Knights before bishops is a useful habit."),
                    String(localized: "Do not move the same piece again and again in the opening."),
                    String(localized: "Leave the queen at home for a while: she is easy to chase, and every check she has to run from costs you a move."),
                    String(localized: "Move each pawn only as far as your pieces need.")
                ],
                diagram: TutorialDiagram(
                    fen: "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1",
                    caption: String(localized: "After 1.e4 e5 2.Nf3 Nc6 3.Bc4 Bc5 — both sides developing.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Castle early"),
                text: String(localized: """
                    The king is safest behind an untouched wall of pawns, and \
                    castling puts him there while bringing a rook towards the \
                    centre. As a rule: develop two or three pieces, castle, then \
                    start looking for a plan.
                    """),
                diagram: TutorialDiagram(
                    fen: "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQ1RK1 b kq - 0 1",
                    highlights: ["g1", "f1"],
                    caption: String(localized: "White has castled: king tucked in, rook joining the game.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Trade with a purpose"),
                text: String(localized: """
                    Every capture changes the balance. Count before you take: if \
                    the material after the whole exchange is in your favour, take; \
                    if not, do not. When you are ahead, trading pieces makes your \
                    lead bigger and the position simpler.
                    """),
                bullets: [
                    String(localized: "Ahead in material: trade pieces, head for the endgame."),
                    String(localized: "Behind in material: keep pieces on and make things complicated."),
                    String(localized: "Before a capture, count every attacker and every defender of that square.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "Give your pieces work"),
                text: String(localized: """
                    Good moves usually improve a piece: a rook onto an open file, \
                    a knight to a square no pawn can chase it from, a bishop onto \
                    a long clear diagonal. If you have no plan, find your worst \
                    piece and make it better.
                    """),
                bullets: [
                    String(localized: "Rooks belong on open files and behind your own passed pawns."),
                    String(localized: "Knights need a safe square in or near the centre."),
                    String(localized: "Bishops want long diagonals — do not bury them behind your own pawns."),
                    String(localized: "Pawns cannot go back: think twice before you push one.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "The endgame"),
                text: String(localized: """
                    With few pieces left the rules of thumb change. Pawns become \
                    precious, because one that gets through becomes a queen, and \
                    the king turns into a strong piece that should march towards \
                    the action instead of hiding.
                    """),
                bullets: [
                    String(localized: "Push the pawn your king can support, and blockade your opponent's."),
                    String(localized: "To mate, drive the enemy king to the edge and bring your own king up to help."),
                    String(localized: "A lone queen or rook plus king is enough to mate; a lone bishop or knight is not.")
                ],
                diagram: TutorialDiagram(
                    fen: "5k2/5Q2/5K2/8/8/8/8/8 b - - 0 1",
                    focus: "f8",
                    caption: String(localized: "Queen and king mate at the edge: the queen checks, the king guards her.")
                )
            )
        ]
    )

    // MARK: 8 · Notation

    private static let notation = TutorialChapter(
        id: "notation",
        title: String(localized: "Reading the Moves"),
        summary: String(localized: "What Nf3 and O-O mean"),
        icon: .symbol("text.book.closed.fill"),
        pages: [
            TutorialPage(
                heading: String(localized: "Piece plus square"),
                text: String(localized: """
                    A move is written as the letter of the piece and the square \
                    it goes to: Nf3 is a knight to f3, Qd8 a queen to d8. Pawns \
                    have no letter, so e4 simply means a pawn moved to e4. The \
                    knight is N, because K is taken by the king.
                    """),
                bullets: [
                    String(localized: "K king · Q queen · R rook · B bishop · N knight · pawns: nothing"),
                    String(localized: "x is a capture: Bxc6, or exd5 for a pawn taking on d5."),
                    String(localized: "+ is check, # is checkmate: Qh5#."),
                    String(localized: "O-O is castling towards the h-file, O-O-O towards the a-file."),
                    String(localized: "=Q is a promotion: e8=Q. A file letter is added when two pieces could reach the square: Nbd2.")
                ],
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 1",
                    arrows: [.move("g1", "f3")],
                    caption: String(localized: "1.e4 e5 2.Nf3 — the moves that reached this position.")
                )
            ),
            TutorialPage(
                heading: String(localized: "Move numbers"),
                text: String(localized: """
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
        title: String(localized: "Playing in This App"),
        summary: String(localized: "Moving pieces, hints and the game review"),
        icon: .symbol("hand.tap.fill"),
        pages: [
            TutorialPage(
                heading: String(localized: "Making a move"),
                text: String(localized: """
                    Tap a piece and the dots show every square it may legally go \
                    to; tap one of them to play the move. Dragging the piece works \
                    too, and tapping it a second time puts it back down. Illegal \
                    moves are simply not offered, so you cannot go wrong.
                    """),
                diagram: TutorialDiagram(
                    fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                    focus: "e2",
                    caption: String(localized: "Tap e4 to open the game.")
                )
            ),
            TutorialPage(
                heading: String(localized: "The buttons"),
                text: String(localized: """
                    Under the board are the three controls you need during a \
                    game, and the top row takes you back to the menu or spins the \
                    board around.
                    """),
                bullets: [
                    String(localized: "Undo takes back your move — and the computer's reply with it."),
                    String(localized: "Hint asks the engine for the move it would play, in games against the computer; with two players that button offers a draw instead."),
                    String(localized: "Resign ends a hopeless game."),
                    String(localized: "Top right, the gear opens the settings and the arrows flip the board; the chevron at the top left returns to the menu, keeping the game so you can continue it later.")
                ]
            ),
            TutorialPage(
                heading: String(localized: "The game review"),
                text: String(localized: """
                    When a game is over, Game Review plays it back and has the \
                    engine grade every single move, with an accuracy score for \
                    each player and a graph of who was winning when. It is the \
                    fastest way to find out what actually went wrong.
                    """),
                bullets: [
                    String(localized: "Swipe the board, or tap a move in the strip, to walk through the game."),
                    String(localized: "A green arrow shows the move the engine would have preferred."),
                    String(localized: "The last finished game stays on the menu, so you can review it again later.")
                ],
                extra: .moveGrades
            ),
            TutorialPage(
                heading: String(localized: "Settings"),
                text: String(localized: """
                    The gear — in the menu, and in the top row of a game — \
                    holds five board themes, sounds and haptics, and the two \
                    helpers you may want to switch off as you improve: the \
                    legal-move dots and the coordinates around the board.
                    """),
                bullets: [
                    String(localized: "Flip board (two players) turns the board towards whoever is on the move."),
                    String(localized: "Five difficulty levels wait under Play vs Computer — the lowest ones play like a beginner on purpose.")
                ]
            )
        ]
    )
}
