# Screenshots and App Preview

The media is **not made by hand and is not in git** — the script below produces
it. Uploading is manual: in App Store Connect drag the files into the *App
Preview and Screenshots* section (language switch at the top, one locale at a
time).

```bash
Tools/appstore_media.sh              # screenshots and previews (~20 min)
Tools/appstore_media.sh screenshots  # screenshots only (~11 min)
Tools/appstore_media.sh video        # previews only (~9 min)
```

Run it from the repository root. It needs Xcode, the two simulators named in it
and ImageMagick (`brew install imagemagick`) for the lossless PNG squeeze;
Python 3 for the preview's music bed comes with macOS. `OUT_ROOT=…` puts the
output somewhere else, which is how to try a change without touching the set you
are about to upload.

The `swift` tools print a page of AVFoundation deprecation warnings on macOS 26
every run. They are expected — the replacements landed in 26.0 and the old API
still does exactly this job — and the line that matters is the last one, which
reports what the finished file actually holds.

## What the script produces

| What | Where | Resolution | Count |
|---|---|---|---|
| iPhone 6.5" screenshots | `screenshots/<locale>/iphone-6.5/` | 1242 × 2688 | 10 |
| iPad 13" screenshots | `screenshots/<locale>/ipad-13/` | 2064 × 2752 | 10 |
| iPhone App Preview | `preview/<locale>/iphone-6.5.mp4` | 886 × 1920, 30 fps, AAC | 1 |
| iPad 13" App Preview | `preview/<locale>/ipad-13.mp4` | 1200 × 1600, 30 fps, AAC | 1 |

Both simulators are their slot size natively, so no screenshot is scaled or
cropped — `simctl io screenshot` writes the slot size straight out, and the
script fails rather than continuing if it does not.

**iPhone 6.5" is the slot this listing uses**, not 6.9". Apple derives every
*smaller* size from the file you upload, but only within a slot: the slot is
picked per upload in Connect, and a listing sitting on the 6.5" slot refuses a
6.9" file outright. Shooting one iPhone size rather than two halves the run. If
the 6.9" slot is ever wanted as well, add *iPhone 17 Pro Max* at 1320 × 2868
alongside the 6.5" device in `appstore_media.sh`; `shoot` already takes the
device and its expected size as arguments.

The App Preview has no such split: the one 886 × 1920 file is what Apple lists
for the 6.9", 6.5", 6.3" and 6.1" displays alike, so `iphone-6.5.mp4` is the
video for every iPhone slot. Note that neither preview size is a device
resolution — 886 × 1920 and 1200 × 1600 are the only two Connect takes for these
devices, and a preview at the device's own size comes out as H.264 Level 5.0 and
is refused.

The locales are `cs` and `en-US`, everything portrait — the iPhone is
portrait-only (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`) and the
iPad set is shot portrait to match. `en-GB` gets no media of its own; upload the
`en-US` set into it.

Each locale is shot in a simulator switched to that language, not just in an
app launched in it: the status bar belongs to the system, and on the iPad it
carries the date and the app's name, which a Czech simulator printed as
"út 20.10. Šachy" across the English set. Switching takes a reboot per device
and locale, and when the script ends it puts each simulator back as it found it:
its languages, its status bar, and running or shut down.

A reboot makes the next launch the slow one, and the previews are recorded from
the moment of launch: with the cut points fixed, the English iPad preview opened
on half a second of black. So each device launches the app to the menu once
after its reboot and install, and only the second launch is shot or recorded.
That makes the launch quicker but not steady — it still lands half a second
earlier or later from run to run — so the game's first window starts two
seconds into the recording, by when every run so far has had the board up.

The date on the iPad's status bar is the real one. `simctl status_bar --time`
does take an ISO date, but the runtime printed "Sun 9 1" for Tuesday 9 January
on a Czech device: the wrong day, and in neither language's format.

There are no captions, and the sister projects both have them. Theirs exist to
say "no ads, no purchases" out loud over a screen that cannot say it itself;
here `05-report` carries the same argument by showing a full paid-tier feature
running for free. If conversion says otherwise,
`Tools/appstore_captions.sh` in the solitaire repository paints a band at the top
of a finished shot and takes its text from two shell variables — it ports in an
afternoon.

## How the poses work

Nothing here is mocked up. Every shot and every clip is driven by the `#if DEBUG`
launch arguments the app already carries —
[`ContentView.swift`](../chess/ContentView.swift) for the board (`--auto-game-ai=`,
`--auto-game-2p`, `--fen=`, `--script=`, `--script-interval=`,
`--review-script=`, `--reset-analysis-cache`, and for the game's options
`--time=`, `--start=`, `--variant=`, `--tabletop`),
[`MenuView.swift`](../chess/UI/MenuView.swift) for the menu and the pages it
opens (`--show-settings`, `--menu-ai-setup`, `--menu-2p-setup`, `--tutorial`,
`--puzzles`, `--training`, `--chess-clock`, `--my-games`),
[`TutorialView.swift`](../chess/UI/TutorialView.swift) for the guide
(`--tutorial-chapter=`, `--tutorial-page=`, `--tutorial-tap=`),
[`GameReviewView.swift`](../chess/UI/GameReviewView.swift) for the review
(`--review-ply=`, `--review-report`, `--review-replay`),
[`PuzzleViews.swift`](../chess/UI/PuzzleViews.swift) for the puzzles
(`--puzzle-rated`, `--puzzle-daily`, `--puzzle-rush`, `--puzzle-autosolve=`),
[`ChessClockView.swift`](../chess/UI/ChessClockView.swift) for the chess clock
(`--chess-clock-running`) and
[`AchievementPresenter.swift`](../chess/UI/AchievementPresenter.swift) for how
long an achievement banner stays up (`--banner-seconds=`). None of it reaches an
App Store build.

That is a deliberate trade. A mocked-up board would be quicker to write and
would quietly drift away from the game as the game changed; a board reached by
legal moves either still plays or stops rendering. The graded blunder, the two
accuracy figures and the mate in the set are the ones a real game earned, and
the review's verdicts are the engine's own.

Two of the poses are worth spelling out:

- **`--script` plays moves, it does not force them.** Each move is played only
  if it is legal in the position that actually exists, and the script stops at
  the first that is not. Against the engine it waits for each reply, but the
  reply is the opening book's random pick, so no written-down move after the
  first is guaranteed even to be legal, let alone sound. Hence the word
  `engine` in place of a move, which plays what Hard would play there: `04-clock`
  is 1.d4 and four of those, and comes out a sound, level opening whatever
  Grandmaster answers. And hence the trailer's game is *two-player*, where every
  move of a written-down game is legal by construction. `07-chess960` is
  two-player for the same reason, from a start chosen so that its knights' moves
  are known in advance.
- **The review cannot be hurried.** It runs the engine over every ply before it
  can grade anything: about twenty seconds for the seven-move game the script
  uses, longer for a real one and longer again on a slower machine. So the app
  drops a marker file when the analysis lands
  ([`ShotMarker.swift`](../chess/Support/ShotMarker.swift), `#if DEBUG`) and the
  three poses that need it wait for the file rather than for a guessed number of
  seconds. Every other pose settles in a known time: the ones that play moves
  first (`04-clock`, `07-chess960`, `08-mate`) wait for those to be played, and
  the rest are drawn on the first frame and a fixed few seconds cover them.

## The ten shots, in order

The order matters more than the count: most people never scroll past the second
one, and search results show the first three, so those three have to carry the
app on their own — the whole menu, the review and the puzzles.

| # | Shot | What it shows |
|---|---|---|
| 1 | `01-menu` | The hero. Play vs Computer, Two Players, Puzzles, Training, Chess Clock, My Games, How to Play — the whole app on one screen, and the only shot that says what it is without being read. |
| 2 | `02-review` | The differentiator. Scholar's mate reviewed: 3…Nf6 flagged **Blunder**, an arrow on the move the engine wanted, 95.9 % against 44.0 % accuracy and the evaluation graph above the board. |
| 3 | `03-puzzle` | A rated puzzle on the board — "Find the best move for …", the puzzle's rating against the player's, Hint / Solution / Retry / Next. The puzzle is drawn at random near 1200, so it differs from run to run. |
| 4 | `04-clock` | A live blitz game (5 + 3) against Grandmaster, five moves in: both clocks, the move list, and Pause / Resign in place of Undo / Hint, which a timed game does not have. Grandmaster's replies come from the book at random, so the opening differs from run to run. |
| 5 | `05-report` | "You win by checkmate!", both accuracy dials, the move breakdown and the key moment — the review's summary card, and the place a "free, no daily limit" caption would go. |
| 6 | `06-puzzles` | The puzzle hub: the puzzle rating, the daily puzzle, the three races against the clock, Fix Your Mistakes and the themes. A clean install, so the counters stand at zero. |
| 7 | `07-chess960` | Two players face to face (`--tabletop`, Black's pieces and clock turned towards the far side of the table), Chess960 #412 on a 10 + 5 clock, four moves in. Three of the new options in one picture. |
| 8 | `08-mate` | The checkmate overlay and the confetti, reached by playing Scholar's mate out on the board to its real Qxf7# rather than drawn — and, being the install's first finished game, the *First Game* achievement banner over it. `--banner-seconds=30` holds the banner, which would otherwise be leaving at the moment of the shot. |
| 9 | `09-chess-clock` | The chess clock for a game on a real board, running: Black has pressed, White's five minutes are going. |
| 10 | `10-lesson` | How to Play, chapter 2 page 4: the bishop, with the legal-move dots on a diagram that is actually playable. |

Between them the set shows the menu, the computer on the clock, two players,
Chess960, both halves of the review, the puzzles, the chess clock and the guide.

Poses that exist and are not in the set: `--show-settings` (the board themes and
the credits — `08-settings` in the 1.0 set), `--menu-ai-setup` (the difficulty
picker with all six levels, the side and the time control), `--training` and its
`--training-analysis`, `--training-editor` and `--training-openings`,
`--puzzle-daily`, `--puzzle-rush`, `--tutorial` (the nine-chapter contents) and
`--my-games`. The last is empty on a clean install — every pose starts from
one — so My Games, its statistics and the achievements have no shot until
something fills the archive first.

## App Preview

Three recordings, cut into one 25.3-second preview per device: the game, the
puzzles, the review.

- **`p1-game`** — the **Opera Game** (Morphy–Duke of Brunswick, Paris 1858)
  played to itself in two-player mode at 0.45 s a move, on a 3-minute blitz
  clock so that both clocks are in the picture counting down. It is the
  shortest famous game that still *looks* like chess played well: an exchange
  on move four, both sides castling into trouble, a queen given up on sixteen
  and mate on seventeen. Seventeen moves at that pace finish inside the
  recording, which is the whole reason for the pace. Two windows come out of
  it — the opening, and the last few moves into the mate, the confetti and the
  *First Game* achievement — where 1.0 took three back to back; the middle one
  made room for the rush. The clock has no increment because at this pace an
  increment makes the clocks climb rather than fall.
- **`p2-rush`** — Race the Clock solving itself. `--puzzle-autosolve=0.7` plays
  each of the player's moves 0.7 s after the board is handed over, selecting the
  piece first as a tap would, so the window shows puzzle after puzzle falling,
  the counter going up and the three minutes going down. The rush draws its
  puzzles at random, so this is the one clip that differs between runs, but
  from three seconds in, once the first puzzle is up, it is never still.
- **`p3-review`** — a board being *graded*. This one cannot be recorded
  the way the other is: twenty seconds of progress bar would reach the trailer.
  So the script waits for the analysis marker, starts recording, and three
  seconds later — enough for the recorder to come up — `--review-replay` walks
  the board through the game from the first move, badge by badge, with the graph
  cursor following. That fixed delay is the point: the first cut of this clip
  caught the replay at whatever point it had reached and ended in the middle of
  a pass, where now the window ends on the mate. The replay loops afterwards, as
  insurance rather than as the plan, and the script polls for the marker five
  times a second so the delay it is measuring from is known to a fifth of a
  second.

Every cut window is chosen to hold something *moving* from its first frame to
its last: a piece travelling, a grade badge changing, the graph cursor sliding,
the confetti. Two things bound them, and both were learned the hard way on the
sister projects:

- **Nothing may reach past about 21 s into a recording.** The files report their
  full length but the tail is not reliably decodable — a range that crosses it is
  clamped and the finished preview holds one frame for the difference, while
  every step reports success.
- **The game's second window runs past the mate on purpose.** The confetti flies
  for about two seconds and the result panel behind it is worth reading — 17
  moves, 12 captures, 4 checks and both clocks — so the window holds it for
  three rather than cutting on the last piece to land. Half a second a move was
  tried first and left the mate barely two seconds before the ceiling above.

Nothing fails loudly if a window drifts — it just goes still. So after any change
to the pacing, the poses, the engine's timings or the animations, look at the
frames either side of each cut before uploading:

```bash
swift Tools/appstore_frames.swift AppStore/preview/en-US/iphone-6.5.mp4 \
    /tmp/frames 0.1 5.5 5.7 11.3 11.5 17.3 17.5 25.2
magick /tmp/frames/*.png -resize 190x +append /tmp/sheet.png
```

Those are the frames either side of the three joins. The first two are the
opening of the game moving forward, the third is the same game a dozen moves on
and the fourth its mate under the confetti; the fifth is a rush with its first
puzzle up and the sixth the same rush a few puzzles later; the seventh is the
review opening on the first move, and the eighth its mate. A frame that repeats
the one before it is a window that has drifted past the action.

**The music is synthesised, because it has to be.** App Store Connect *requires*
stereo AAC at 256 kbps on a preview, and silence does not satisfy it: AAC
compresses digital silence to about 2 kbps and Connect reports a file with no
usable audio as an unsupported audio configuration. The app ships no audio at
all — its move sounds are built at launch — so
[`Tools/gen_preview_music.py`](../Tools/gen_preview_music.py) writes the bed:
i-VI-III-VII in A minor at 54 BPM, felt-piano notes over a held open fifth, no
percussion. `PREVIEW_GAIN=…` changes how loud it sits, `PREVIEW_MUSIC=path.wav`
replaces it with something else.
