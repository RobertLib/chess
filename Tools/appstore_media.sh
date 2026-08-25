#!/bin/bash
#
# appstore_media.sh — regenerates every screenshot and App Preview in AppStore/.
#
#     Tools/appstore_media.sh                 # screenshots + previews
#     Tools/appstore_media.sh screenshots     # screenshots only
#     Tools/appstore_media.sh video           # previews only
#
# Needs Xcode, the simulators named below and ImageMagick (`brew install
# imagemagick`) for the lossless PNG squeeze. Everything is driven by the
# `#if DEBUG` launch arguments in chess/ContentView.swift, chess/UI/MenuView.swift,
# chess/UI/TutorialView.swift and chess/UI/GameReviewView.swift — so this builds
# Debug, and none of it exists in the build that goes to the App Store.
#
# Output goes to AppStore/screenshots/<locale>/<device>/ and
# AppStore/preview/<locale>/<device>.mp4, where <device> is iphone-6.5 or
# ipad-13. Override the root with OUT_ROOT=… to try things out without touching
# the set you are about to upload.
#
set -euo pipefail

MODE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$ROOT/AppStore}"
WORK="${WORK:-$(mktemp -d -t chess-appstore)}"
BID=cz.rob.chess

# Both devices record their App Store slot size natively, so nothing here is
# scaled or cropped:
#   iPhone 11 Pro Max → 1242 × 2688, one of the two sizes Connect takes for 6.5"
#   iPad Pro 13" (M5) → 2064 × 2752, one of the two it takes for iPad 13"
#
# **6.5" is the iPhone slot this listing uses.** Apple derives every smaller
# size from the one you upload, but only within a slot: a listing sitting on the
# 6.5" slot refuses a 6.9" file outright, and the other way round. Shooting one
# iPhone size rather than two halves the run; if the 6.9" slot is ever wanted as
# well, add "iPhone 17 Pro Max" 1320 × 2868 back alongside this one — the shoot
# function already takes the device and the expected size as arguments.
IPHONE_NAME="iPhone 11 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M5)"
IPHONE_SHOT_SIZE=(1242 2688)
IPAD_SHOT_SIZE=(2064 2752)

# Xcode ships the iPhone 11 Pro Max device *type* but does not always leave a
# ready-made device for it, so the 6.5" one is created on demand (see
# ensure_device). iOS 26 still runs on that hardware, which is why the current
# runtime pairs with it at all.
IPHONE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max

# App Preview render sizes — the only two App Store Connect takes for these
# devices, and *not* the devices' own resolutions. See AppStore/screenshots.md
# before changing either.
IPHONE_VIDEO_SIZE=(886 1920)
IPAD_VIDEO_SIZE=(1200 1600)

# Previews must carry stereo AAC at 256 kbps and silence does not satisfy the
# check, so a bed is synthesised — the app itself ships no audio at all.
PREVIEW_MUSIC="${PREVIEW_MUSIC-$WORK/bed.wav}"
PREVIEW_GAIN="${PREVIEW_GAIN:-0.5}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

udid_for() {
    # Device lines are indented four spaces and read "<name> (<udid>) (<state>)".
    # Matched as a fixed string, because names like "iPad Pro 13-inch (M5)" carry
    # brackets of their own; the trailing " (" keeps "iPhone 11" from matching
    # "iPhone 11 Pro Max".
    xcrun simctl list devices available \
        | grep -F "    $1 (" \
        | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' \
        | head -n 1 || true
}

ensure_device() { # ensure_device <name> <device-type-id> -> udid on stdout
    local udid; udid="$(udid_for "$1")"
    if [ -z "$udid" ]; then
        # Newest installed runtime. simctl refuses a pairing the runtime does
        # not support, so a device type that has aged out fails here rather than
        # producing something that never boots. Messages go to stderr, because
        # the caller reads this function's stdout.
        local rt
        rt="$(xcrun simctl list runtimes available \
              | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' \
              | tail -n 1)"
        [ -n "$rt" ] || { echo "no iOS simulator runtime installed" >&2; return 1; }
        echo "  creating simulator '$1' on ${rt##*.}" >&2
        xcrun simctl create "$1" "$2" "$rt" >/dev/null || return 1
        udid="$(udid_for "$1")"
    fi
    printf '%s' "$udid"
}

boot_and_install() {
    local udid="$1"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    # A pose writes settings and a saved game like any other play would, so each
    # run starts from a clean install rather than from whatever the last one left
    # behind — the menu's Continue row is the visible half of that.
    xcrun simctl uninstall "$udid" "$BID" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$APP"
    # A real battery percentage and a real clock are the two things that date a
    # screenshot. 9:41 is the time Apple puts on its own.
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --batteryState charged --batteryLevel 100 --wifiMode active --wifiBars 3 >/dev/null 2>&1 || true
}

locale_args() {
    case "$1" in
        cs)    printf '%s\0%s\0%s\0%s\0' -AppleLanguages "(cs)" -AppleLocale cs_CZ ;;
        en-US) printf '%s\0%s\0%s\0%s\0' -AppleLanguages "(en-US)" -AppleLocale en_US ;;
    esac
}

launch() { # launch <udid> <locale> <args...>
    local udid="$1" loc="$2"; shift 2
    local largs=()
    while IFS= read -r -d '' a; do largs+=("$a"); done < <(locale_args "$loc")
    xcrun simctl terminate "$udid" "$BID" >/dev/null 2>&1 || true
    # After the terminate, not before: the pose that has just been photographed
    # may still be finishing an analysis, and clearing first would let it write
    # the marker back in the gap.
    clear_ready "$udid"
    xcrun simctl launch "$udid" "$BID" "${largs[@]}" "$@" >/dev/null
}

# The game review is the one screen whose settling time cannot be guessed: it
# runs the engine over every ply before it can grade anything — around twenty
# seconds for the seven-move game below, and longer on a slower machine. So the
# app drops a marker when the analysis lands (ShotMarker in the review's
# `#if DEBUG` block) and the poses that need it wait for the file rather than for
# a number. Every other pose is drawn on the first frame.
container_for() { xcrun simctl get_app_container "$1" "$BID" data; }

clear_ready() { rm -f "$(container_for "$1")/Documents/shot-ready" 2>/dev/null || true; }

wait_ready() { # wait_ready <udid> <timeout-seconds> -> seconds waited on stdout
    local marker="$(container_for "$1")/Documents/shot-ready"
    # Five times a second, not once. The preview's review clip starts recording
    # the moment this returns and the replay behind it begins on a fixed delay
    # from the marker, so a whole second of polling slack would move the cut
    # window by a whole second — which is a move and a half of the game.
    local ticks=0 limit=$(( $2 * 5 ))
    while [ ! -f "$marker" ] && [ "$ticks" -lt "$limit" ]; do
        sleep 0.2
        ticks=$((ticks + 1))
    done
    # stderr, because the caller reads this function's stdout.
    [ -f "$marker" ] || { echo "  !! analysis never landed (${2}s)" >&2; return 1; }
    printf '%s' "$(( ticks / 5 ))"
}

# ---------------------------------------------------------------- games

# Morphy–Duke of Brunswick & Count Isouard, Paris 1858 — the Opera Game. Chosen
# for the trailer because it is the shortest famous game that still *looks* like
# chess being played well: seventeen moves, an exchange on move four, both sides
# castling into trouble, a queen given up on move sixteen and mate on the board
# on seventeen. Long enough to fill the clip, short enough to finish inside it.
#
# In two-player mode every one of these is legal by construction, which is why
# the trailer's game is that mode rather than one against the engine: a scripted
# move is only *attempted*, and against a real opponent the line stops at the
# first reply the engine declined to make.
OPERA=e2e4,e7e5,g1f3,d7d6,d2d4,c8g4,d4e5,g4f3,d1f3,d6e5,f1c4,g8f6,f3b3,d8e7,b1c3,c7c6,c1g5,b7b5,c3b5,c6b5,c4b5,b8d7,e1c1,a8d8,d1d7,d8d7,h1d1,e7e6,b5d7,f6d7,b3b8,d7b8,d1d8

# Scholar's mate. Seven plies is the shortest game that gives the review
# something to say — a book move each, a best move, a blunder with a better move
# to draw on the board, and a mate to finish on — and seven plies is also all
# the analysis that fits in a sensible wait.
SCHOLAR=e2e4,e7e5,f1c4,b8c6,d1h5,g8f6,h5f7

# The position before Qxf7#, so the mate is played rather than set up.
MATE_FEN='r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4'

# ---------------------------------------------------------------- build

say "Building Debug for the simulator"
xcodebuild -project "$ROOT/chess.xcodeproj" -scheme chess \
    -configuration Debug -sdk iphonesimulator \
    -destination "platform=iOS Simulator,name=$IPAD_NAME" \
    -derivedDataPath "$WORK/dd" build >/dev/null
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/chess.app"

IPHONE_UDID="$(ensure_device "$IPHONE_NAME" "$IPHONE_TYPE" || true)"
IPAD_UDID="$(udid_for "$IPAD_NAME")"
[ -n "$IPHONE_UDID" ] \
    || { echo "no simulator named '$IPHONE_NAME', and creating one failed"; exit 1; }
[ -n "$IPAD_UDID" ] || { echo "no simulator named '$IPAD_NAME'"; exit 1; }

# ---------------------------------------------------------------- screenshots

# name|settle|launch arguments. The settle is either a number of seconds or the
# word `ready`, which waits for the analysis marker instead. The order is the
# order they are uploaded in and it matters more than the count: most people
# never scroll past the second one.
SHOTS=(
    "01-menu|3|"
    "02-review|ready|--review-script=$SCHOLAR --review-ply=6"
    "03-report|ready|--review-script=$SCHOLAR --review-report"
    "04-game|58|--auto-game-ai=expert:white --script=e2e4,g1f3,f1b5,e1g1,d2d4"
    "05-mate|4|--fen=$MATE_FEN --script=f3f7"
    "06-twoplayer|12|--auto-game-2p --script=d2d4,d7d5,c2c4,e7e6,b1c3"
    "07-lesson|4|--tutorial-chapter=pieces --tutorial-page=4"
    "08-settings|4|--show-settings"
)

shoot() { # shoot <udid> <locale> <device-dir> <W> <H>
    local udid="$1" loc="$2" dev="$3" w="$4" h="$5"
    local dir="$OUT_ROOT/screenshots/$loc/$dev"
    mkdir -p "$dir"
    for entry in "${SHOTS[@]}"; do
        IFS='|' read -r name settle args <<<"$entry"
        # shellcheck disable=SC2086
        launch "$udid" "$loc" $args
        local note
        if [ "$settle" = ready ]; then
            local waited
            waited="$(wait_ready "$udid" 120)" || exit 1
            # The report sheet and the ply jump both animate after the analysis
            # replaces the progress bar with the accuracy cards.
            sleep 2
            note="analysis in ${waited}s"
        else
            sleep "$settle"
            note="${settle}s"
        fi
        xcrun simctl io "$udid" screenshot "$dir/$name.png" >/dev/null 2>&1
        local size
        size="$(magick identify -format '%wx%h' "$dir/$name.png")"
        printf '  %-14s %-10s %s\n' "$name" "$size" "$note"
        # Both devices record their slot size, so a mismatch means the simulator
        # is not the one this script expects rather than something to paper over.
        if [ "$size" != "${w}x${h}" ]; then
            echo "     !! expected ${w}x${h} — wrong simulator or a changed runtime"
            exit 1
        fi
    done
    xcrun simctl terminate "$udid" "$BID" >/dev/null 2>&1 || true
}

if [ "$MODE" = all ] || [ "$MODE" = screenshots ]; then
    command -v magick >/dev/null \
        || { echo "needs ImageMagick (brew install imagemagick)"; exit 1; }
    boot_and_install "$IPHONE_UDID"
    boot_and_install "$IPAD_UDID"
    for loc in cs en-US; do
        say "Screenshots — iPhone 6.5\" / $loc"
        shoot "$IPHONE_UDID" "$loc" iphone-6.5 "${IPHONE_SHOT_SIZE[@]}"
        say "Screenshots — iPad 13\" / $loc"
        shoot "$IPAD_UDID" "$loc" ipad-13 "${IPAD_SHOT_SIZE[@]}"
    done

    # The simulator writes RGBA even though every pixel is opaque, and App Store
    # Connect wants screenshots without transparency. Dropping the channel leaves
    # the picture untouched and saves about a third of the size — verified rather
    # than assumed, and anything that is not identical is left alone.
    say "Squeezing PNGs (lossless)"
    while IFS= read -r f; do
        magick "$f" -alpha off -depth 8 -strip \
                    -define png:compression-level=9 \
                    -define png:compression-filter=5 "$f.opt"
        if [ "$(magick compare -metric AE "$f" "$f.opt" null: 2>&1 | awk '{print $1}')" = "0" ]; then
            mv "$f.opt" "$f"
        else
            rm -f "$f.opt"
            echo "  left as-is (not identical): $f"
        fi
    done < <(find "$OUT_ROOT/screenshots" -name '*.png')
    du -sh "$OUT_ROOT/screenshots"
fi

# ---------------------------------------------------------------- previews

# name|hold|seconds|launch arguments.
#
# `p1-game` plays the Opera Game to itself at half a second a move, so the whole
# seventeen moves and the mate land inside the recording. Recording starts the
# moment the app is launched, so the clip covers the app's own launch animation
# too and the cut points below are measured from there.
#
# `p2-review` is the other half of the app and it cannot be recorded the same
# way: the engine has to grade the game first, which takes twenty seconds of
# progress bar that must not reach the trailer. So this one *waits*. The marker
# lands, recording starts, and three seconds later — enough for the recorder to
# come up — `--review-replay` walks the board through the game from the first
# move. That fixed delay is what lets the window end on the mate: without it the
# recording caught the replay at whatever point it had got to, and the clip
# finished in the middle of a pass. The replay still loops afterwards, as
# insurance rather than as the plan.
#
# `--review-ply=0` is not decoration. The review opens on the *final* position,
# which is right for a player and wrong here: the window would have opened on
# the mate and then jumped backwards to move one. Parking it at the start means
# the clip opens on the game about to be replayed and only ever moves forward.
CLIPS=(
    "p1-game|0|21|--auto-game-2p --script=$OPERA --script-interval=0.45"
    "p2-review|ready|12|--review-script=$SCHOLAR --review-ply=0 --review-replay"
)

# Cut points, in seconds into each recording. Every window is chosen to hold
# something *moving* from its first frame to its last: a piece travelling, a
# badge changing, the graph cursor sliding, the confetti.
#
# Two things bound the windows, and both were learned the hard way on the sister
# projects:
#
#   * Nothing may reach past about 21 s into a recording. The files report their
#     full length but the tail is not reliably decodable — a range that crosses
#     it is clamped and the finished preview holds one frame for the difference,
#     while every step reports success. That is the whole reason the game is
#     played at half a second a move rather than at one.
#   * The last window runs past the mate on purpose. The confetti flies for
#     about two seconds and the result panel behind it is worth reading — 17
#     moves, 12 captures, 4 checks — so the window holds it for three rather
#     than cutting on the last piece to land. Half a second a move was tried
#     first and gave the mate barely two seconds before the ceiling above; 0.45
#     buys the difference without the game looking hurried.
#
# The game is scripted and the review is deterministic, so the timeline is the
# same on every run — but the iPad reaches each state a little sooner than the
# iPhone, which is why the two have their own points.
#
# After any change to the pacing, the poses or the animations, look at the frames
# either side of each cut before uploading — Tools/appstore_frames.swift pulls
# them out. Nothing here fails loudly: a stale window just goes still.
IPHONE_CUTS=(p1-game:1.0:6.6 p1-game:7.4:12.8 p1-game:13.2:19.0
             p2-review:2.4:10.3)
IPAD_CUTS=(p1-game:0.8:6.4 p1-game:7.2:12.6 p1-game:13.0:18.8
           p2-review:2.3:10.2)

record() { # record <udid> <locale> <clipdir>
    local udid="$1" loc="$2" dir="$3"
    mkdir -p "$dir"
    for entry in "${CLIPS[@]}"; do
        IFS='|' read -r name hold secs args <<<"$entry"
        # shellcheck disable=SC2086
        launch "$udid" "$loc" $args
        local note=""
        # `hold`, not `wait` — the builtin is needed a few lines down.
        if [ "$hold" = ready ]; then
            local waited
            waited="$(wait_ready "$udid" 120)" || exit 1
            note=" (analysis in ${waited}s)"
        fi
        xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/$name.mp4" >/dev/null 2>&1 &
        local pid=$!
        sleep "$secs"
        kill -INT $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        sleep 1
        printf '  %-10s %s%s\n' "$name" \
            "$(avmediainfo "$dir/$name.mp4" | awk '/^Duration:/{print $2 "s"}')" "$note"
    done
    xcrun simctl terminate "$udid" "$BID" >/dev/null 2>&1 || true
}

assemble() { # assemble <clipdir> <out.mp4> <W> <H> <cut...>
    local dir="$1" out="$2" w="$3" h="$4"; shift 4
    mkdir -p "$(dirname "$out")"
    local specs=()
    for cut in "$@"; do specs+=("$dir/${cut%%:*}.mp4:${cut#*:}"); done
    swift "$ROOT/Tools/appstore_video.swift" "$out" "$w" "$h" "${specs[@]}"
    # What comes out of the cut is the right size and the wrong everything else
    # for App Store Connect — too high a profile, too fast a bit rate and no
    # audio at all. This pins the lot to Apple's table.
    swift "$ROOT/Tools/appstore_conform.swift" "$out" "$w" "$h" \
        ${PREVIEW_MUSIC:+"$PREVIEW_MUSIC"} "$PREVIEW_GAIN"
}

if [ "$MODE" = all ] || [ "$MODE" = video ]; then
    boot_and_install "$IPHONE_UDID"
    boot_and_install "$IPAD_UDID"
    if [ -n "$PREVIEW_MUSIC" ] && [ ! -f "$PREVIEW_MUSIC" ]; then
        say "Synthesising the music bed"
        python3 "$ROOT/Tools/gen_preview_music.py" "$PREVIEW_MUSIC" 30
    fi
    for loc in cs en-US; do
        say "Preview — iPhone 6.5\" / $loc"
        record "$IPHONE_UDID" "$loc" "$WORK/clips/iphone-$loc"
        assemble "$WORK/clips/iphone-$loc" "$OUT_ROOT/preview/$loc/iphone-6.5.mp4" \
            "${IPHONE_VIDEO_SIZE[@]}" "${IPHONE_CUTS[@]}"

        say "Preview — iPad 13\" / $loc"
        record "$IPAD_UDID" "$loc" "$WORK/clips/ipad-$loc"
        assemble "$WORK/clips/ipad-$loc" "$OUT_ROOT/preview/$loc/ipad-13.mp4" \
            "${IPAD_VIDEO_SIZE[@]}" "${IPAD_CUTS[@]}"
    done
fi

say "Done. Working files in $WORK"
