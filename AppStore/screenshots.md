# Screenshots and App Preview

The media is **not made by hand and is not in git** — the script below produces
it. Uploading is manual: in App Store Connect drag the files into the *App
Preview and Screenshots* section (language switch at the top, one locale at a
time).

```bash
Tools/appstore_media.sh              # screenshots and previews (~12 min)
Tools/appstore_media.sh screenshots  # screenshots only (~5 min)
Tools/appstore_media.sh video        # previews only (~7 min)
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
| iPhone 6.5" screenshots | `screenshots/<locale>/iphone-6.5/` | 1242 × 2688 | 8 |
| iPad 13" screenshots | `screenshots/<locale>/ipad-13/` | 2064 × 2752 | 8 |
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

There are no captions, and the sister projects both have them. Theirs exist to
say "no ads, no purchases" out loud over a screen that cannot say it itself;
here `03-report` carries the same argument by showing a full paid-tier feature
running for free. If conversion says otherwise,
`Tools/appstore_captions.sh` in the solitaire repository paints a band at the top
of a finished shot and takes its text from two shell variables — it ports in an
afternoon.

## How the poses work

Nothing here is mocked up. Every shot and both clips are driven by the `#if DEBUG`
launch arguments the app already carries —
[`ContentView.swift`](../chess/ContentView.swift) for the board (`--auto-game-ai=`,
`--auto-game-2p`, `--fen=`, `--script=`, `--script-interval=`,
`--review-script=`, `--reset-analysis-cache`),
[`MenuView.swift`](../chess/UI/MenuView.swift) for the menu
(`--show-settings`, `--menu-ai-setup`, `--tutorial`),
[`TutorialView.swift`](../chess/UI/TutorialView.swift) for the guide
(`--tutorial-chapter=`, `--tutorial-page=`, `--tutorial-tap=`) and
[`GameReviewView.swift`](../chess/UI/GameReviewView.swift) for the review
(`--review-ply=`, `--review-report`, `--review-replay`). None of it reaches an
App Store build.

That is a deliberate trade. A mocked-up board would be quicker to write and
would quietly drift away from the game as the game changed; a board reached by
legal moves either still plays or stops rendering. The graded blunder, the two
accuracy figures and the mate in the set are the ones a real game earned, and
the review's verdicts are the engine's own.

Two of the poses are worth spelling out:

- **`--script` plays moves, it does not force them.** Each move is played only
  if it is legal in the position that actually exists, and the script stops at
  the first that is not. Against the engine that means only the first move is
  guaranteed — hence `04-game` scripts nothing but plain developing moves, and
  hence the trailer's game is *two-player*, where every move of a written-down
  game is legal by construction.
- **The review cannot be hurried.** It runs the engine over every ply before it
  can grade anything: about twenty seconds for the seven-move game the script
  uses, longer for a real one and longer again on a slower machine. So the app
  drops a marker file when the analysis lands
  ([`ShotMarker.swift`](../chess/Support/ShotMarker.swift), `#if DEBUG`) and the
  three poses that need it wait for the file rather than for a guessed number of
  seconds. Every other pose is drawn on the first frame and a fixed second or
  two covers it.

## The eight shots, in order

The order matters more than the count: most people never scroll past the second
one, so the first two have to carry the app on their own.

| # | Shot | What it shows |
|---|---|---|
| 1 | `01-menu` | The hero. Continue, Play vs Computer, Two Players, How to Play — the whole app on one screen, and the only shot that says what it is without being read. |
| 2 | `02-review` | The differentiator. Scholar's mate reviewed: 3…Nf6 flagged **Blunder**, an arrow on the move the engine wanted, 95.9 % against 44.0 % accuracy and the evaluation graph above the board. |
| 3 | `03-report` | "You win by checkmate!", both accuracy dials, the move breakdown and the key moment — the review's summary card, and the place a "free, no daily limit" caption would go. |
| 4 | `04-game` | A live game against Grandmaster with the move list and the Undo / Hint / Resign row. |
| 5 | `05-mate` | The checkmate overlay and the confetti, reached by a real Qxf7# from a FEN rather than drawn. |
| 6 | `06-twoplayer` | Two Players on one device — note the middle button under the board is *Draw* here rather than *Hint*. |
| 7 | `07-lesson` | How to Play, chapter 2 page 4: the bishop, with the legal-move dots on a diagram that is actually playable. |
| 8 | `08-settings` | All five board themes, the toggles, and the piece-artwork credit. |

Between them the set shows the menu, both game modes, both halves of the review,
the guide and the settings, and it shows all five themes without spending a shot
on them.

Two more poses exist and are not in the set: `--tutorial` opens the nine-chapter
contents, and `--menu-ai-setup` opens the difficulty picker with all five levels
and the White / Random / Black choice. Either would replace `04-game` if the
levels turn out to matter more than a live board.

## App Preview

Two recordings, cut into one 24.7-second preview per device.

- **`p1-game`** — the **Opera Game** (Morphy–Duke of Brunswick, Paris 1858)
  played to itself in two-player mode at 0.45 s a move. It is the shortest
  famous game that still *looks* like chess played well: an exchange on move
  four, both sides castling into trouble, a queen given up on sixteen and mate
  on seventeen. Seventeen moves at that pace finish inside the recording, which
  is the whole reason for the pace. Three windows come out of it.
- **`p2-review`** — the same board being *graded*. This one cannot be recorded
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
- **The last window runs past the mate on purpose.** The confetti flies for about
  two seconds and the result panel behind it is worth reading — 17 moves, 12
  captures, 4 checks — so the window holds it for three rather than cutting on
  the last piece to land. Half a second a move was tried first and left the mate
  barely two seconds before the ceiling above.

Nothing fails loudly if a window drifts — it just goes still. So after any change
to the pacing, the poses, the engine's timings or the animations, look at the
frames either side of each cut before uploading:

```bash
swift Tools/appstore_frames.swift AppStore/preview/en-US/iphone-6.5.mp4 \
    /tmp/frames 0.1 5.5 5.7 10.9 11.1 16.7 16.9 24.6
magick /tmp/frames/*.png -resize 190x +append /tmp/sheet.png
```

Those are the frames either side of the three joins. The first six should be six
different positions of the same game, moving forward; the seventh is the review
opening on the first move, and the eighth its mate. A frame that repeats the one
before it is a window that has drifted past the action.

**The music is synthesised, because it has to be.** App Store Connect *requires*
stereo AAC at 256 kbps on a preview, and silence does not satisfy it: AAC
compresses digital silence to about 2 kbps and Connect reports a file with no
usable audio as an unsupported audio configuration. The app ships no audio at
all — its move sounds are built at launch — so
[`Tools/gen_preview_music.py`](../Tools/gen_preview_music.py) writes the bed:
i-VI-III-VII in A minor at 54 BPM, felt-piano notes over a held open fifth, no
percussion. `PREVIEW_GAIN=…` changes how loud it sits, `PREVIEW_MUSIC=path.wav`
replaces it with something else.
