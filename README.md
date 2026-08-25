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
  as White or Black. The two strongest open out of a book of 90 named lines,
  so they do not replay one game; the three below them vary their own openings
  by picking softly among the moves they searched.
* **Two players on one device**, with an optional board flip between turns and
  a draw by agreement.
* **Game review** in the style of chess.com: every move graded from brilliant
  to blunder, an accuracy score per player, an evaluation graph and the
  engine's preferred move drawn on the board.
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
│   ├── Game         Move history, SAN, draw and mate detection
│   ├── ChessAI      Negamax + alpha-beta, TT, quiescence, null-move
│   ├── GameAnalyzer Post-game grading and accuracy
│   ├── StaticExchange SEE — tells a sacrifice from a blunder
│   └── OpeningBook  Opening theory: what the top levels play, and the
│                     names the review gives a game
├── UI/              SwiftUI views
├── Support/         Settings, sounds, haptics, notation localization
└── *.xcstrings      String catalogs (English source, Czech translation)

chessTests/          Swift Testing suites for the engine and view models
chessUITests/        XCUITests: VoiceOver, Dynamic Type, board input
AppStore/            Listing texts, ASO reasoning, reviewer notes, privacy policy
Tools/               App Store screenshots and App Preview, see AppStore/screenshots.md
```

The engine is deliberately free of SwiftUI imports, which is what lets the
test target and the tutorial exercise it directly.

## Building

Open `chess.xcodeproj` and run. The project uses Xcode's synchronized file
groups, so new files under `chess/` and `chessTests/` are picked up
automatically — no project file editing.

## Tests

```sh
xcodebuild test -project chess.xcodeproj -scheme chess \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Two targets run under that one command.

`chessTests` (Swift Testing) covers perft against the Chess Programming Wiki
reference counts, Zobrist incrementality, make/unmake symmetry, FEN parsing,
every draw and mate rule, SAN including disambiguation, static exchange
evaluation, search cancellation, the analyzer's grading thresholds, the
opening book, the render models behind the game and review boards, and the
undo and save/restore logic of `Game`.

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

## Notation is localized, storage is not

Moves are shown in the reader's language — `Nf3` reads `Jf3` in Czech — but
the SAN the engine, the opening book and saved games work with stays English.
The mapping happens at display time only, in `Support/Localization.swift`.

## Licence

This project's own source is under the MIT licence; see [LICENSE](LICENSE).

The chess piece artwork is third-party and carries its own terms — see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for its attribution and
licence.
