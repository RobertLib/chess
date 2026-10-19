# Chess

An offline chess app for iPhone and iPad, written in SwiftUI with its own
engine — no packages, no network, no accounts.

| | |
|---|---|
| **Platform** | iOS 18.0+, iPhone and iPad |
| **Language** | Swift 6, SwiftUI |
| **Languages** | English, Czech (follows the system language) |
| **Dependencies** | none — Apple frameworks only |

## Features

* **Play against the computer** at five levels, from Beginner to Grandmaster,
  or against an **adaptive opponent** that slides between them — a little
  stronger after every win, a little weaker after every loss. The two strongest
  levels open out of a book of more than 80 named lines, so they do not replay
  one game; the three below them vary their own openings by picking softly
  among the moves they searched. Premoves can be queued while the computer
  thinks.
* **Two players on one device**, with an optional board flip between turns, a
  face-to-face layout for a device lying flat between them, and a draw by
  agreement.
* **Time controls** — bullet, blitz, rapid and classical presets, or one made
  to measure — for both kinds of game. The clock starts after the first move,
  pauses by itself when the app goes to the background, warns when time runs
  short, and a flag that falls against a side with nothing left to mate with is
  a draw, as FIDE has it. On the clock the computer budgets its own time.
* **Chess960, variants and odds**: Fischer Random from any of its 960
  positions, King of the Hill and Three-check — which the engine plays for
  their own wins — and the classical pawn, knight, rook and queen odds.
* **Chess clock** for a game on a real board: Fischer increment, simple delay
  or Bronstein, and different times per side for time odds.
* **Puzzles** — about 4,000 tactics from the Lichess database (CC0), bundled:
  rated puzzles with a rating of your own, 32 themes, a daily puzzle with a
  streak, Race the Clock (3 minutes, 5 minutes or survival) and **your own
  mistakes** from reviewed games, served back as puzzles to fix. A home-screen
  widget shows the daily puzzle.
* **Training**: an opening trainer over the book's lines, an analysis board
  with a live engine evaluation, a position editor, and pasting in a PGN or
  FEN.
* **Game review** in the style of chess.com: every move graded from brilliant
  to blunder, an accuracy score per player, an evaluation graph, time spent per
  move and the engine's preferred move drawn on the board.
* **My Games**: the last 300 finished games kept on the device, statistics by
  level, colour and time control, a rough strength estimate, 31 achievements,
  and PGN export through the share sheet and import from the Files app.
* **How to Play** — a 9-chapter guide: 38 pages carrying 27 board diagrams,
  15 of which are playable; the dots are real legal moves asked from the
  engine, and tapping one plays it.
* Hints, undo, five board themes, synthesized sounds and haptics.

## Layout

```
chess/
├── Engine/          Pure Swift, no UI. Reusable and unit-tested.
│   ├── ChessTypes   Board squares, pieces, moves, outcomes
│   ├── Board        64-byte position, make/unmake, FEN, Zobrist hashing
│   ├── MoveGenerator Legal move generation and attack detection
│   ├── Chess960     Fischer Random start positions (Scharnagl numbering)
│   ├── Game         Move history, SAN, draw and mate detection
│   ├── ChessClock   Time controls, the clock, flag-fall rules, time budget
│   ├── ChessAI      Negamax + alpha-beta, TT, quiescence, null-move
│   ├── GameAnalyzer Post-game grading and accuracy
│   ├── StaticExchange SEE — tells a sacrifice from a blunder
│   ├── OpeningBook  Opening theory: what the top levels play, and the
│   │                 names the review gives a game
│   ├── Puzzle       Puzzles, judging an attempt, the bundled library
│   └── PGN          Writing and reading Portable Game Notation
├── Puzzles/         puzzles.csv — the bundled Lichess selection
├── UI/              SwiftUI views
├── Support/         Settings, options, archive, statistics, achievements,
│                     puzzle progress, sounds, haptics, notation
└── *.xcstrings      String catalogs (English source, Czech translation)

ChessWidget/         The daily-puzzle widget (shares the engine and the
                     puzzle file with the app)
chessTests/          Swift Testing suites for the engine and view models
chessUITests/        XCUITests: VoiceOver, Dynamic Type, board input
AppStore/            Listing texts, ASO reasoning, reviewer notes, privacy policy
Tools/               App Store media, and build_puzzles.py for the puzzle set
```

The engine is deliberately free of SwiftUI imports, which is what lets the
test target, the tutorial and the widget exercise it directly.

## Building

Open `chess.xcodeproj` and run. The project uses Xcode's synchronized file
groups, so new files under `chess/` and `chessTests/` are picked up
automatically — no project file editing.

## Tests

```sh
xcodebuild test -project chess.xcodeproj -scheme chess \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Two targets run under that one command.

`chessTests` (Swift Testing) covers perft against the Chess Programming Wiki
reference counts — and, for Chess960, against python-chess — Zobrist
incrementality, make/unmake symmetry, FEN parsing (Shredder and X-FEN too),
every draw and mate rule, SAN including disambiguation, static exchange
evaluation, search cancellation, the analyzer's grading thresholds, the
opening book, the render models behind the game and review boards, and the
undo and save/restore logic of `Game`. Around the games themselves it covers
the clock (increment, delay, Bronstein, pauses, storage), the FIDE flag-fall
rule, King of the Hill and Three-check (their wins, the check count in the
hash, the engine going for them), the computer's time budget, timed games and premoves in the view model,
PGN in and out, every bundled puzzle setting up, puzzle judging and rating,
the archive, the statistics, the achievements, the opening trainer and the
analysis board.

`chessUITests` (XCUITest) covers what only the running app can show: the
board's per-square VoiceOver labels, `performAccessibilityAudit` on the menu,
the new-game setup, game, lesson, contents and review screens, that the game's
icon-only controls name themselves, tap-to-move and drag-to-move, that starting
a new game over an unfinished one asks first, which control the mode puts in the
middle of the row under the board (Hint against the computer, Draw between two
players), and — by launching with
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL` —
that no screen, the result card and the new-game setup included, overflows or
clips its text at the largest text size, and that a button is at least as tall
as one line of its own label. These are worth keeping: tap-to-move was broken for a while
and no amount of reading the code found it, because the `--script` debug
argument bypasses the gesture.

## App Store

Everything the submission needs is in [`AppStore/`](AppStore/): the listing texts
for `cs`, `en-US` and `en-GB`, the note for the reviewer, the privacy policy in
both languages, and [`AppStore/README.md`](AppStore/README.md) for which field
goes where and what to answer in the questionnaires.
[`AppStore/alternatives.md`](AppStore/alternatives.md) carries the ASO reasoning
— the competition on both storefronts, the keyword arithmetic and the
alternatives, so a later change to the name or the keywords starts from what was
already tried.

The media is not in git — the scripts produce it:

```sh
Tools/appstore_media.sh              # 8 screenshots and a preview, per locale
Tools/appstore_media.sh screenshots  # screenshots only
Tools/appstore_media.sh video        # previews only
```

Nothing in the set is mocked up. Every shot and both video clips are driven by
the `#if DEBUG` launch arguments the app already carries — `--auto-game-2p`,
`--script=`, `--fen=`, `--review-script=`, `--review-replay`,
`--tutorial-chapter=` and the rest — so the graded blunder, the two accuracy
figures and the mate are the ones a real game earned, and the trailer's
seventeen moves are Morphy's. The review is the one screen whose settling cannot
be guessed, so the app drops a marker file when its analysis lands
([`ShotMarker.swift`](chess/Support/ShotMarker.swift), `#if DEBUG`) and the
script waits for that rather than for a number. A second run of the same shot
finds that analysis already stored and lands the marker at once
([`AnalysisCache.swift`](chess/Support/AnalysisCache.swift));
`--reset-analysis-cache` is there for the runs that want to watch it work.

The iPhone slot is **6.5"**, 1242 × 2688, and the preview 886 × 1920 — see
[`AppStore/screenshots.md`](AppStore/screenshots.md).

## The puzzles

`chess/Puzzles/puzzles.csv` is a selection of about four thousand puzzles from
the [Lichess puzzle database](https://database.lichess.org/#puzzles), which
Lichess releases under CC0. [`Tools/build_puzzles.py`](Tools/build_puzzles.py)
rebuilds it: it streams the head of the database, filters for popular,
well-rated puzzles, fills quotas per theme and per rating band, and checks
every puzzle with python-chess and with this app's own engine. The app never
downloads anything; the file is part of the bundle, and the widget reads the
same file to show the same daily puzzle.

## Notation is localized, storage is not

Moves are shown in the reader's language — `Nf3` reads `Jf3` in Czech — but
the SAN the engine, the opening book and saved games work with stays English.
The mapping happens at display time only, in `Support/Localization.swift`.

## Licence

This project's own source is under the MIT licence; see [LICENSE](LICENSE).

Three things in it are third-party and keep their own terms: the chess piece
artwork (BSD), the evaluation's piece-square tables (CC BY-SA 3.0) and the
puzzles (CC0). See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for their
attribution and licences.
