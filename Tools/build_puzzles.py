#!/usr/bin/env python3
r"""Builds the bundled puzzle set, chess/Puzzles/puzzles.csv.

    Tools/build_puzzles.py --input sample.csv [--output chess/Puzzles/puzzles.csv]
                           [--swift-validator ./validator] [--exclude ids.txt]
                           [--seed 20261019] [--target 4000]

Source and licence
------------------
The Lichess puzzle database, https://database.lichess.org/#puzzles
(file https://database.lichess.org/lichess_db_puzzle.csv.zst). The page says:
"Database exports are released under the Creative Commons CC0 license. Use
them for research, commercial purpose, publication, anything you like. You can
download, modify and redistribute them, without asking for permission."
No attribution is required; the app credits Lichess anyway.

The whole file is ~300 MB compressed and ~6M rows. It is not needed whole: rows
are in PuzzleId order, which is effectively random, so the head is a fair
sample. Stream it and stop early (curl gets SIGPIPE once head has its rows):

    mkdir -p dl && curl -s https://database.lichess.org/lichess_db_puzzle.csv.zst \
        | zstd -dc | head -n 1200000 > dl/sample.csv

Columns: PuzzleId,FEN,Moves,Rating,RatingDeviation,Popularity,NbPlays,Themes,
GameUrl,OpeningTags[,DailyDate]. FEN is the position BEFORE the opponent's
move; Moves[0] is that opponent move (the app animates it) and the rest is the
solution, alternating player/opponent and always ending on a player move.

Output format
-------------
No header. One puzzle per line, exactly five comma-separated fields:

    id,fen,moves,rating,themes

`moves` is the space-separated UCI list including the opponent's first move,
`themes` the puzzle's complete space-separated Lichess theme list. Lines are
sorted by rating, then id. UTF-8, "\n" line endings, trailing newline.

Selection
---------
1. Quality filter: Popularity >= 85, NbPlays >= 800, RatingDeviation <= 85,
   500 <= Rating <= 2800.
2. Validation with python-chess (below); with --swift-validator / --exclude
   also with the app's own engine. Only puzzles passing both are eligible,
   and of those at most one per source game: the one with the lowest
   PuzzleId. The rule is applied after validation, so a game whose first
   puzzle fails still contributes its next valid one, and by id rather than
   by position in the file, so which one survives does not depend on row
   order. (The shipped file predates this: it kept the first row of each game
   in file order, before validation. A rerun on the same sample can pick
   another puzzle from some games, so regenerating changes the bundled set
   and every day's puzzle.)
3. Every puzzle gets a deterministic priority from sha256(seed:PuzzleId) via
   weighted sampling (key = u ** (1 / weight)). The weight prefers shorter
   solutions slightly (2 and 4 plies 1.0, 6 plies 0.8, 8 plies 0.6, then
   falling) and more popular puzzles slightly (x1.0 at 85 up to x1.5 at 100).
   The priority depends on the id alone, so the result does not depend on row
   order, and rerunning on the same sample reproduces the file byte for byte.
4. Theme quotas first: for each curated theme (THEMES below, scarcest first)
   puzzles are added until QUOTA (120) carry it, or the pool runs out. Each pick
   goes to the rating bucket furthest below its target, so quota puzzles follow
   the rating curve instead of piling up where a theme is common.
5. Then each 100-point bucket is filled up to BUCKET_TARGETS (flat 220 from
   800 to 2200, tapering to 30 at 500 and 25 at 2700-2800). Any shortfall is
   topped up across the 800-2200 buckets until the total reaches --target.
   --target is a floor, not a cap: the bucket targets alone add up to 4005,
   and a theme quota can carry a bucket past its own target, so a full sample
   yields a little more than 4000 (the shipped file has 4005 puzzles). It is
   left that way because the file is reproduced byte for byte, and the daily
   puzzle is picked by position in it — trimming would change every day's.

Validation
----------
python-chess (done here, always): every FEN parses into a valid position;
every move in Moves is legal in sequence; the list has even length (ends on a
player move); and what the themes claim holds: mateInN / mate / *Mate themes
end in checkmate (with N player moves for mateInN, N>=5 for mateIn5); oneMove/
short/long/veryLong match the length; promotion, underPromotion, castling,
enPassant and doubleCheck are done by a player move; smotheredMate is mate by a
knight; backRankMate mates a king on its back rank.

The app's engine (separate step, Swift): compile the validator below against
chess/Engine and pass it with --swift-validator; the script runs it over the
whole candidate pool, drops every puzzle it reports, and runs it again over the
final file (which must then pass completely). To recreate and build it:

    Tools/build_puzzles.py --write-swift-validator work/validator.swift
    swiftc -O -parse-as-library chess/Engine/*.swift work/validator.swift -o work/validator
    work/validator chess/Puzzles/puzzles.csv

It checks that Board(fen:) accepts the FEN (the app's parser is strict), that
the board's own `fen` round-trips placement, side and castling, that each UCI
move matches exactly one of generateLegalMoves() by `uci`, applied with
`make`, and that mate themes end in checkmate. It also counts FENs whose en
passant square the app silently drops (informational, not a failure).

Full run as used for the shipped file (Python reading downloaded data with -I):

    python -I Tools/build_puzzles.py --input dl/sample.csv \
        --swift-validator work/validator --output chess/Puzzles/puzzles.csv

Requires the standard library and python-chess (tested with 1.11).

----- BEGIN validator.swift -----
// Validates puzzles.csv lines (id,fen,moves,rating,themes) against the app's
// own engine. Prints "FAIL <id> <reason>" per rejected puzzle and a summary.
// Exit status 0 when every puzzle passes, 1 otherwise.
import Foundation

@main
struct PuzzleValidator {
    static func check(fen: String, moves: [String], themes: Set<String>) -> String? {
        guard var board = Board(fen: fen) else { return "Board(fen:) returned nil" }
        let inFields = fen.split(separator: " ").map(String.init)
        let outFields = board.fen.split(separator: " ").map(String.init)
        for i in 0..<3 where inFields[i] != outFields[i] {
            return "fen round-trip mismatch in field \(i): \(inFields[i]) -> \(outFields[i])"
        }
        guard moves.count >= 2, moves.count % 2 == 0 else { return "odd/short move list (\(moves.count))" }
        for (ply, uci) in moves.enumerated() {
            let matches = board.generateLegalMoves().filter { $0.uci == uci }
            guard matches.count == 1 else {
                return "ply \(ply) \(uci): \(matches.count) matching legal moves in \(board.fen)"
            }
            board.make(matches[0])
        }
        if themes.contains(where: { $0.hasPrefix("mateIn") }) || themes.contains("mate") {
            guard board.isInCheck, board.generateLegalMoves().isEmpty else {
                return "mate theme but final position is not checkmate: \(board.fen)"
            }
        }
        return nil
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
            print("usage: validator puzzles.csv"); exit(2)
        }
        var total = 0, failed = 0, epDropped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            total += 1
            guard f.count == 5 else { print("FAIL ? malformed line: \(line)"); failed += 1; continue }
            let fen = f[1]
            if let b = Board(fen: fen), fen.split(separator: " ")[3] != "-", b.enPassantSquare < 0 { epDropped += 1 }
            let themes = Set(f[4].split(separator: " ").map(String.init))
            if let reason = check(fen: fen, moves: f[2].split(separator: " ").map(String.init), themes: themes) {
                print("FAIL \(f[0]) \(reason)"); failed += 1
            }
        }
        print("checked \(total), passed \(total - failed), failed \(failed), ep-square silently dropped \(epDropped)")
        exit(failed == 0 ? 0 : 1)
    }
}
----- END validator.swift -----
"""

from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import os
import re
import subprocess
import sys
import tempfile

import chess

DEFAULT_SEED = 20261019
DEFAULT_TARGET = 4000

MIN_POPULARITY = 85
MIN_PLAYS = 800
MAX_RATING_DEVIATION = 85
MIN_RATING, MAX_RATING = 500, 2800

QUOTA = 120
THEMES = (
    "mateIn1 mateIn2 mateIn3 fork pin skewer discoveredAttack hangingPiece "
    "backRankMate sacrifice deflection attraction promotion defensiveMove "
    "trappedPiece endgame rookEndgame pawnEndgame opening middlegame "
    "smotheredMate doubleCheck quietMove intermezzo xRayAttack capturingDefender "
    "clearance interference exposedKing kingsideAttack advancedPawn zugzwang"
).split()

# Puzzles wanted per 100-point bucket (key = lower bound; 2700 covers 2700-2800).
BUCKET_TARGETS = {
    500: 30, 600: 80, 700: 140,
    **{b: 220 for b in range(800, 2300, 100)},
    2300: 180, 2400: 120, 2500: 80, 2600: 50, 2700: 25,
}
TOP_UP_BUCKETS = range(800, 2300, 100)

LENGTH_WEIGHTS = {2: 1.0, 4: 1.0, 6: 0.8, 8: 0.6, 10: 0.35, 12: 0.2}
LONG_WEIGHT = 0.1

LENGTH_THEMES = {"oneMove": lambda n: n == 2, "short": lambda n: n == 4,
                 "long": lambda n: n == 6, "veryLong": lambda n: n >= 8}
PLAYER_MOVE_CLAIMS = ("promotion", "underPromotion", "castling", "enPassant", "doubleCheck")

ID_RE = re.compile(r"^[0-9A-Za-z]+$")


def bucket_of(rating: int) -> int:
    return min(rating // 100 * 100, 2700)


def claims_mate(themes: set[str]) -> bool:
    return any(t == "mate" or t.startswith("mateIn") or t.endswith("Mate") for t in themes)


def validate(fen: str, moves: list[str], themes: set[str]) -> str | None:
    """python-chess check; returns a short reason on failure, None if the puzzle is sound."""
    try:
        board = chess.Board(fen)
    except ValueError as error:
        return f"FEN does not parse: {error}"
    if board.status() != chess.STATUS_VALID:
        return f"invalid position: {board.status()!r}"
    if len(moves) < 2 or len(moves) % 2:
        return f"move list of {len(moves)} plies does not end on a player move"

    done = set()
    for ply, uci in enumerate(moves):
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            return f"ply {ply}: unparsable UCI {uci}"
        if not board.is_legal(move):
            return f"ply {ply}: illegal move {uci}"
        player = ply % 2 == 1
        if player:
            if move.promotion:
                done.add("promotion")
                if move.promotion != chess.QUEEN:
                    done.add("underPromotion")
            if board.is_castling(move):
                done.add("castling")
            if board.is_en_passant(move):
                done.add("enPassant")
        board.push(move)
        if player and len(board.checkers()) >= 2:
            done.add("doubleCheck")

    plies = len(moves)
    if claims_mate(themes) and not board.is_checkmate():
        return "mate theme but final position is not checkmate"
    for theme in themes:
        if theme.startswith("mateIn") and theme[6:].isdigit():
            n = int(theme[6:])
            if (plies < 10) if n >= 5 else (plies != 2 * n):
                return f"{theme} but solution has {plies // 2} player moves"
        if theme in LENGTH_THEMES and not LENGTH_THEMES[theme](plies):
            return f"{theme} but {plies} plies"
        if theme in PLAYER_MOVE_CLAIMS and theme not in done:
            return f"{theme} but no player move does it"
    if "smotheredMate" in themes:
        mater = board.piece_at(board.peek().to_square)
        if mater is None or mater.piece_type != chess.KNIGHT:
            return "smotheredMate but the mating piece is not a knight"
    if "backRankMate" in themes:
        king = board.king(board.turn)
        if king is None or chess.square_rank(king) != (0 if board.turn == chess.WHITE else 7):
            return "backRankMate but the mated king is not on its back rank"
    return None


def category(reason: str) -> str:
    """Groups failure reasons: drops ply numbers, moves, FENs and other details."""
    reason = re.sub(r"^ply \d+( [a-h][1-8][a-h][1-8][qrbn]?)?:? ?", "", reason)
    reason = re.sub(r" in \S+/\S+.*$", "", reason).split(": ")[0]
    return re.sub(r" [a-h][1-8][a-h][1-8][qrbn]?$", "", reason)


def priority(seed: int, puzzle_id: str, plies: int, popularity: int) -> float:
    digest = hashlib.sha256(f"{seed}:{puzzle_id}".encode()).digest()
    u = (int.from_bytes(digest[:8], "big") + 1) / (2**64 + 1)  # in (0, 1)
    weight = LENGTH_WEIGHTS.get(plies, LONG_WEIGHT) * (1.0 + (popularity - MIN_POPULARITY) / 30.0)
    return u ** (1.0 / weight)


def read_pool(path: str):
    """Rows passing the quality filter, as dicts. Every puzzle of a game is
    kept here; `one_per_game` chooses among the ones that validate."""
    pool, read = [], 0
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            read += 1
            try:
                rating = int(row["Rating"])
                if not (int(row["Popularity"]) >= MIN_POPULARITY and int(row["NbPlays"]) >= MIN_PLAYS
                        and int(row["RatingDeviation"]) <= MAX_RATING_DEVIATION
                        and MIN_RATING <= rating <= MAX_RATING):
                    continue
            except (TypeError, ValueError):
                continue
            url = (row.get("GameUrl") or "").split("#")[0].split("/")
            pool.append({
                "id": row["PuzzleId"], "fen": row["FEN"].strip(), "moves": row["Moves"].split(),
                "rating": rating, "themes": row["Themes"].split(),
                "popularity": int(row["Popularity"]),
                "game": url[3] if len(url) > 3 else row["PuzzleId"],
            })
    return read, pool


def one_per_game(puzzles):
    """At most one puzzle per source game: the lowest PuzzleId among the ones
    given, which are the valid ones. Sorted by id, so the result is the same
    whatever order the rows came in."""
    kept = {}
    for p in puzzles:
        if p["game"] not in kept or p["id"] < kept[p["game"]]["id"]:
            kept[p["game"]] = p
    return sorted(kept.values(), key=lambda p: p["id"])


def line_of(p) -> str:
    return f"{p['id']},{p['fen']},{' '.join(p['moves'])},{p['rating']},{' '.join(p['themes'])}"


def run_swift_validator(binary: str, puzzles, work_dir: str, name: str):
    """Runs the Swift validator over `puzzles`; returns ({id: reason}, summary line)."""
    path = os.path.join(work_dir, name)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.writelines(line_of(p) + "\n" for p in puzzles)
    result = subprocess.run([binary, path], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        sys.exit(f"swift validator failed to run ({result.returncode}): {result.stdout}{result.stderr}")
    failures, summary = {}, ""
    for out in result.stdout.splitlines():
        if out.startswith("FAIL "):
            _, puzzle_id, reason = out.split(" ", 2)
            failures[puzzle_id] = reason
        elif out.startswith("checked "):
            summary = out
    return failures, summary


def select(pool, seed: int, target: int):
    for p in pool:
        p["key"] = priority(seed, p["id"], len(p["moves"]), p["popularity"])
        p["bucket"] = bucket_of(p["rating"])
    ranked = sorted(pool, key=lambda p: (-p["key"], p["id"]))

    chosen, chosen_ids = [], set()
    per_bucket = collections.Counter()
    per_theme = collections.Counter()

    def take(p):
        chosen.append(p)
        chosen_ids.add(p["id"])
        per_bucket[p["bucket"]] += 1
        per_theme.update(set(p["themes"]))

    # 1. Theme quotas, scarcest theme first, each pick into the bucket most below target.
    available = collections.Counter(t for p in pool for t in set(p["themes"]))
    for theme in sorted(THEMES, key=lambda t: (available[t], t)):
        by_bucket = collections.defaultdict(list)
        for p in ranked:
            if theme in p["themes"]:
                by_bucket[p["bucket"]].append(p)
        cursor = collections.Counter()
        while per_theme[theme] < QUOTA:
            best, best_score = None, None
            for b, candidates in by_bucket.items():
                while cursor[b] < len(candidates) and candidates[cursor[b]]["id"] in chosen_ids:
                    cursor[b] += 1
                if cursor[b] == len(candidates):
                    continue
                goal = BUCKET_TARGETS.get(b, 1)
                score = ((goal - per_bucket[b]) / goal, candidates[cursor[b]]["key"])
                if best_score is None or score > best_score:
                    best, best_score = b, score
            if best is None:
                break
            take(by_bucket[best][cursor[best]])

    # 2. Fill each bucket to its target in priority order.
    for p in ranked:
        if p["id"] not in chosen_ids and per_bucket[p["bucket"]] < BUCKET_TARGETS[p["bucket"]]:
            take(p)

    # 3. Top up shortfalls across the flat middle, one puzzle per bucket per round.
    rest = collections.defaultdict(list)
    for p in reversed(ranked):
        if p["id"] not in chosen_ids and p["bucket"] in TOP_UP_BUCKETS:
            rest[p["bucket"]].append(p)
    while len(chosen) < target and any(rest.values()):
        for b in TOP_UP_BUCKETS:
            if rest[b] and len(chosen) < target:
                take(rest[b].pop())

    chosen.sort(key=lambda p: (p["rating"], p["id"]))
    return chosen


def main():
    parser = argparse.ArgumentParser(description="Build chess/Puzzles/puzzles.csv from the Lichess puzzle CSV.")
    parser.add_argument("--input", help="Lichess puzzle CSV (with header), e.g. the streamed sample")
    parser.add_argument("--output", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                         "..", "chess", "Puzzles", "puzzles.csv"))
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--target", type=int, default=DEFAULT_TARGET)
    parser.add_argument("--swift-validator", help="compiled app-engine validator (see docstring)")
    parser.add_argument("--exclude", help="file of puzzle ids to drop (bare ids or validator 'FAIL id ...' lines)")
    parser.add_argument("--work-dir", help="where intermediate files go (default: a fresh temp dir)")
    parser.add_argument("--write-swift-validator", metavar="PATH",
                        help="write the Swift validator source from this docstring to PATH and exit")
    args = parser.parse_args()

    if args.write_swift_validator:
        source = __doc__.split("----- BEGIN validator.swift -----\n")[1].split("----- END validator.swift -----")[0]
        with open(args.write_swift_validator, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(source)
        print(f"wrote {args.write_swift_validator}")
        return
    if not args.input:
        parser.error("--input is required")

    read, pool = read_pool(args.input)
    print(f"read {read} rows; {len(pool)} pass the quality filter")

    ok_ids = {p["id"] for p in pool if ID_RE.match(p["id"])}
    drops = collections.defaultdict(list)
    valid = []
    for p in pool:
        reason = "bad id" if p["id"] not in ok_ids else validate(p["fen"], p["moves"], set(p["themes"]))
        if reason:
            drops[category(reason)].append((p["id"], reason))
        else:
            valid.append(p)
    dropped = sum(len(v) for v in drops.values())
    print(f"python-chess validator: dropped {dropped} of {len(pool)}")
    for reason, items in sorted(drops.items(), key=lambda kv: -len(kv[1])):
        print(f"    {len(items):6d}  {reason}   e.g. {items[0][0]}: {items[0][1]}")

    excluded = set()
    if args.exclude:
        with open(args.exclude, encoding="utf-8") as handle:
            for raw in handle:
                parts = raw.split()
                if parts:
                    excluded.add(parts[1] if parts[0] == "FAIL" and len(parts) > 1 else parts[0])
    work_dir = args.work_dir or tempfile.mkdtemp(prefix="build_puzzles_")
    os.makedirs(work_dir, exist_ok=True)
    if args.swift_validator:
        failures, summary = run_swift_validator(args.swift_validator, valid, work_dir, "candidates.csv")
        print(f"swift validator over candidates: {summary}")
        by_reason = collections.defaultdict(list)
        for puzzle_id, reason in failures.items():
            by_reason[category(reason)].append((puzzle_id, reason))
        for reason, items in sorted(by_reason.items(), key=lambda kv: -len(kv[1])):
            print(f"    {len(items):6d}  {reason}   e.g. {items[0][0]}: {items[0][1]}")
        excluded |= set(failures)
    if excluded:
        before = len(valid)
        valid = [p for p in valid if p["id"] not in excluded]
        print(f"excluded {before - len(valid)} candidates rejected by the app's engine / --exclude")
    before = len(valid)
    valid = one_per_game(valid)
    print(f"one per source game: {len(valid)} of {before} valid candidates")

    chosen = select(valid, args.seed, args.target)

    output = os.path.normpath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w", encoding="utf-8", newline="\n") as handle:
        handle.writelines(line_of(p) + "\n" for p in chosen)
    print(f"\nwrote {len(chosen)} puzzles to {output} ({os.path.getsize(output) / 1024:.1f} KB)")

    histogram = collections.Counter(p["bucket"] for p in chosen)
    print("rating histogram:")
    for b in sorted(BUCKET_TARGETS):
        print(f"    {b}-{b + 99 if b < 2700 else 2800}: {histogram[b]:4d} (target {BUCKET_TARGETS[b]})")
    themes = collections.Counter(t for p in chosen for t in p["themes"])
    print("curated themes:")
    for t in THEMES:
        print(f"    {t:18s} {themes[t]:5d}")
    lengths = collections.Counter(len(p["moves"]) for p in chosen)
    print("plies (incl. opponent's first move): " + ", ".join(f"{k}: {lengths[k]}" for k in sorted(lengths)))

    if args.swift_validator:
        failures, summary = run_swift_validator(args.swift_validator, chosen, work_dir, "final.csv")
        print(f"swift validator over final file: {summary}")
        if failures:
            sys.exit(f"final file has {len(failures)} puzzles the app rejects: {list(failures.items())[:5]}")


if __name__ == "__main__":
    main()
