# ASO: the reasoning, the competition, and the alternatives

Numbers in brackets are character counts. The limits are 30 for the name, 30 for
the subtitle and 100 for keywords.

## What we are up against

Every one of these was looked at on the store before the copy in this directory
was written. Ratings are the US storefront, read in September 2026.

| App | Subtitle | Developer | Ratings | Rating | Money |
|---|---|---|---|---|---|
| Chess.com - Play and Learn | Online Lessons and Puzzles | Chess.com | 819 782 | 4+ | Free + IAP to $119.99 |
| Chess ∙ | *(none)* | Optime Software | 205 787 | 4+ | Free + ads + IAP |
| Real Chess 3D | Ultimate 3D Chess Game | Sailendu Behera | 160 346 | 4+ | Free + ads, $3.99 to remove |
| Chess for Kids: Learn to Play | — | Chess.com | 100 260 | 4+ | Free + IAP |
| Chess - Offline Board Game | The ultimate Chess board game | GamoVation | 66 682 | 4+ | Free + IAP, hints to $26.99 |
| Chess Prime 3D | Play online and solve puzzles | Vinta Games | 62 216 | 4+ | Free + IAP |
| Chess | Play Chess and Solve Puzzles | Vintolo | 39 002 | 4+ | Free + IAP |
| **Chess without ads** | Learn, play, improve! | Christophe Théron | 38 375 | 4+ | Free + **IAP $0.49–8.99** |
| Chess Online - Clash of Kings | — | CC Games | 28 717 | 4+ | Free + IAP |
| Learn Chess with Dr. Wolf | — | Chess.com | 26 832 | 4+ | Free + IAP |
| Chess Online + | — | Entertainment 4Media | 26 661 | 17+ | Free + IAP |
| Chess Tiger Pro | — | Christophe Théron | 23 606 | 4+ | **$3.99** |
| Chess Royale | — | SayGames | 19 980 | 4+ | Free + IAP |
| Pocket Chess | Chess Puzzles | Lessmore | 14 639 | 4+ | Free + IAP |
| Chess: 2 Players! | Play together! | Marina Anisovich | 3 214 | 4+ | Free + IAP $1.99 |
| Chess Clash: Online & Offline | — | Miniclip | 3 168 | 4+ | Free + IAP |
| Lichess | — | lichess.org | 573 | 4+ | Free, genuinely |

Five things follow from that table.

**We cannot win the head term.** "chess" is a volume-60 keyword at difficulty 82
(ASOTools, Google Play, which tracks the same demand curve). Chess.com sits on it
with 820 000 ratings and 150 million accounts, and the next four apps have six
figures each. A new app with no ratings does not rank on the bare word, whatever
it puts in its name. Chasing it is how you end up with no traffic at all.

**The whole category is monetised, including the apps whose names promise it is
not.** *Chess without ads* — the fourth-largest independent app in the category
— carries in-app purchases from $0.49 to $8.99. *Chess - Offline Board Game*
sells hint packs up to $26.99 and takes $2.99 to remove the ads it shows an app
whose name says "offline". Chess.com's own free tier gives **one Game Review per
day** and puts unlimited review behind a membership that runs to about $100 a
year. The honest version of all three promises is the differentiator, and it is
not a small one: no ads, no purchases, no account, no daily limit, and no
networking code in the binary at all.

**The long tail is winnable and it is where the intent is.** Someone typing
*chess offline*, *chess no ads*, *chess two players* or *chess vs computer* knows
exactly what they want, and it is exactly this app. *learn chess* is a
volume-21 keyword at difficulty **10** — the easiest relevant target found
anywhere — and the nine-chapter guide is an honest claim to it. The keyword sets
here are built for those rather than for volume.

**"Two players" is a real niche with almost nobody in it.** *Chess: 2 Players!*
has 3 214 ratings against the category's hundreds of thousands, and it charges
$1.99 for a Pro version. Every large app in the table is built around online
play against strangers; passing the phone across the table is a genuinely
under-served way to want to play chess, and it is the one this app does without
an account.

**The game review is the feature no competitor can copy from their own
listing.** Grading every move from brilliant to blunder, an accuracy score per
player and an evaluation graph is chess.com's flagship paid feature. Offering
the same thing free, unlimited and offline is worth the middle of the
description and the second screenshot. It is a conversion lever as much as a
keyword.

## The Czech storefront is small, and that is the opportunity

Unlike the sister projects, chess **is** localised into Czech by several
competitors — the term is too big to ignore. But the numbers are tiny:

| CZ name | CZ subtitle | Developer | CZ ratings |
|---|---|---|---|
| Šachy – Hrajte a učte se | Partie, úlohy a přátelé | Chess.com | 11 360 |
| Šachy Online + | Nejlepší online šachová hra! | Entertainment 4Media | 827 (18+) |
| Šachy – offline desková hra | Nejlepší šachová hra | GamoVation | 606 |
| Šachy + | — | Entertainment 4Media | 405 |
| ChessKid – Šachy pro děti | — | Chess.com | 292 |
| Šachy - klasická stolní hra | — | Aged Studio | 24 |
| Šachová hra | — | PlayByEars | 22 |
| Šachy - Uč se, Hraj & Vítěz | — | WOOIKO | 8 |
| Šachy 3D - Desková hra offline | — | Maxim Melnik | 1 |
| Klasické šachy - desková hra | — | Rodrigo Belloso | 1 |

Below Chess.com the entire Czech market tops out in the hundreds, and past the
third row in the *tens*. This is the storefront where a good listing actually
moves the ranking, and it costs one translation the app already has.

Three findings shaped `cs/`:

- **`Šachy` has to lead the name.** The home-screen name is localised to *Šachy*
  (`InfoPlist.xcstrings`), and the store name must not differ from it in meaning.
  Every localised competitor does the same, which also means the word alone is
  worthless as a differentiator — what follows it is the whole game.
- **Czech search really is Czech here.** Searching *šachy*, *šachová hra*,
  *šachy offline* and *šachy zdarma* on the Czech store returns Czech-named apps
  at the top, not the English ones. That is the opposite of what the Czech
  solitaire market does, and it means the Czech keyword field is worth writing
  properly rather than stuffing with English spellings.
- **Apple's Czech stemming cannot be trusted.** *šachy* and *šachová* are not
  linked, nor *hráč* and *hráči*, so both spellings earn their characters. That
  is why `šachová` sits in the keyword list even though the name starts with
  *Šachy*, and it is not the breach it looks like.

## What is in use

```
en-US   Chess Offline: Play & Review  (28)   Two players, computer, no ads  (29)
en-GB   Chess Offline: Play & Review  (28)   One or two players, no ads     (26)
cs      Šachy offline: hra pro dva    (26)   Proti počítači, bez reklam     (26)
```

Between the name and the subtitle, `en-US` indexes *chess, offline, play,
review, two, players, computer, no, ads* — and because Apple combines terms
within a locale, and combines them **across** the name, subtitle and keyword
field alike, that assembles *chess offline*, *offline chess*, *play chess*,
*chess review*, *chess two players*, *two player chess*, *chess computer*,
*chess no ads*, *offline chess no ads* and so on without spending a single
keyword character on any of them.

Note the word order: `Chess Offline`, not `Offline Chess`. Apple combines terms
in any order, so both phrases are covered either way — but the name reads left
to right, and leading with the head term is worth more than matching the phrase
people happen to type more often.

Note also **`2` is not `two`.** Apple pairs an English singular with its plural;
it does not pair a numeral with the word for it. The subtitle spells *Two* and
the `en-US` keyword list buys the numeral back for two characters.

## App name

| Czech | | English | |
|---|---|---|---|
| Šachy offline: hra pro dva | (26) | Chess Offline: Play & Review | (28) |
| Šachy: hra pro dva i proti PC | (29) | Chess Offline: Two Players | (26) |
| Šachy offline: rozbor partie | (28) | Chess: Offline Board Game | (25) |
| Šachy: desková hra offline | (26) | Chess Offline: Learn & Play | (27) |
| Šachy offline bez reklam | (24) | Chess Offline: Engine & Review | (30) |

Recommendation: keep *offline* in the name. It is the one head-ish term this app
can compete on, because most of the apps that rank for it are lying — they need
a connection for their ad server — and it is the word the target player actually
types.

`Chess: Offline Board Game` is deliberately **not** the choice even though it
reads best of the five: GamoVation's 66 000-rating app is called *Chess -
Offline Board Game*, and standing in its shadow with a near-identical name buys
their traffic's leftovers while making the listing look like a clone. *board* and
*game* are in the keyword field instead, where they combine into the same phrase
for four characters and no confusion.

If the name ever needs to change, `Chess Offline: Two Players` is the straight
swap: it trades *play* and *review* for the niche with the least competition in
it, and the subtitle then picks up the review in their place.

There is no brand name here on purpose. *Ace High* and *Mini Golf 3D: 108 Holes*
both had something to be a brand about; this app is called Chess on the home
screen and plays chess. In a category where the top ten names are all the word
plus a qualifier, a made-up brand would cost ranking and buy nothing. If a brand
is ever wanted anyway, put it *after* the head terms — never in front of them.

## Subtitle

| Czech | | English | |
|---|---|---|---|
| Proti počítači, bez reklam | (26) | Two players, computer, no ads | (29) |
| Rozbor partie, bez reklam | (25) | One or two players, no ads | (26) |
| Dva hráči i počítač, bez reklam | (31 ✗) | Play a friend or the engine | (27) |
| Naučte se hrát, bez reklam | (26) | Learn, play, no ads, no wifi | (28) |
| Bez reklam a bez internetu | (26) | Board game for one or two | (25) |

`en-GB` deliberately overlaps `en-US` rather than filling in its gaps. It is the
second index in the Czech storefront, but it is the *only* index in the UK,
Ireland, Australia and New Zealand — and those are worth far more than Czechia's
second slot, so it gets the strong set rather than the leftovers. Unlike
solitaire, chess has no US/UK vocabulary split to exploit — nobody calls it
anything else — so what `en-GB` changes is small: *One or two* in place of *Two*,
which frees *computer* into the keyword field and buys *one* into the index.

**No price in the subtitle, in any language.** Guideline 2.3.7 covers the name
and the subtitle alike, and *zdarma* / *free* is the wording that gets metadata
rejected; the sister project lost a Czech subtitle's last two words to it.
"No ads" / "bez reklam" is not a price and is fine. Free-to-download is already
stated by the price on the product page.

## Keywords

In use:

```
en-US  board,game,ai,engine,analysis,accuracy,blunder,learn,beginners,hints,undo,wifi,internet,2,friend  (96)
en-GB  board,game,computer,ai,engine,analysis,accuracy,blunder,learn,beginners,hints,undo,wifi,internet  (96)
cs     šachová,desková,rozbor,partie,analýza,přesnost,hráči,naučit,začátečníky,nápověda,internetu,pravidla  (99)
```

`en-GB` takes *computer* into the keyword field, because its subtitle spent the
characters on *One or* instead; the `en-US` list has the numeral *2* and *friend*
in that space.

The four characters left over in the English sets are deliberately unspent.
*elo*, *puzzles*, *openings* and *master* all fit and all were rejected: the app
has no rating system, no puzzle trainer and no openings course, and an
off-relevance term buys a visitor who bounces. *openings* is the tempting one —
the engine really does carry a 90-line book and the review really does name the
opening — but someone searching it wants a repertoire trainer, and the listing
would be a disappointment at the top of the funnel and a bad review at the
bottom.

Alternative sets, if you end up tuning by performance:

```
# EN, no-freemium angle (leans hardest on the differentiator)
free,noads,nowifi,nointernet,purchases,premium,paid,board,game,engine,ai,solo,single,friend  (94)

# EN, learn-to-play angle (pairs with a "Learn chess, no ads" subtitle)
rules,lessons,guide,beginners,kids,tutorial,notation,checkmate,tactics,openings,board,game   (93)

# EN, analysis angle (pairs with a "Two players, review, no ads" subtitle)
analysis,accuracy,blunder,engine,evaluation,graph,report,coach,improve,board,game,ai,undo    (92)

# CZ, naučit se hrát angle
pravidla,naučit,začátečníky,výuka,kapitoly,notace,mat,taktika,šachová,desková,nápověda,tahy  (95)

# CZ, rozbor a přesnost angle
rozbor,analýza,přesnost,hrubka,hodnocení,graf,engine,zlepšit,šachová,desková,partie,tahy     (93)
```

Rules, so that editing does not break it:

- Separate with a comma and **no space after the comma** — a space counts towards
  the limit of 100.
- Do not repeat words from the name or the subtitle, Apple indexes those
  separately. **This applies between the name and the subtitle too.** That is why
  *chess*, *offline*, *play*, *review*, *two*, *players*, *no* and *ads* are
  absent from the English lists, and *šachy*, *offline*, *hra*, *pro*, *dva*,
  *proti*, *počítači*, *bez* and *reklam* from the Czech one.
- Do not put a plural next to its singular ("player" and "players"), Apple pairs
  them itself. The Czech set does not get that service — see *šachová* above.
- **Do not name competing games or apps** — grounds for rejection, and the
  temptation here is unusually strong. *lichess*, *chesscom*, *chess.com*,
  *stockfish*, *magnus* and *fritz* are all other people's names or trademarks,
  and *stockfish* would be a lie as well: this engine is the app's own.
- Do not reach for a word just because it fits. See the four unspent characters
  above.
- *free* / *zdarma* is allowed in the keyword field, unlike in the name and
  subtitle. It is just rarely worth its characters, because the product page
  already says the app is free.

## Shorter description, if you decide on a terser version

Each paragraph is one long line on purpose. App Store Connect keeps newlines
exactly as pasted, so a paragraph wrapped at 80 columns here comes out ragged on
the device while every other paragraph reflows — paste these as they are.

**EN**

```
Chess for one or two players, with its own engine. Five levels from Beginner to Grandmaster, as White or as Black, and the top two open out of a book of 90 named lines so they do not replay one game.

Pass the phone across the table for two players, with the board turning towards whoever is on the move. Hint asks the engine what it would play; Undo takes back your move and the computer's reply with it.

When a game ends, Game Review grades every move from brilliant to blunder, scores each player's accuracy, graphs who was winning when and draws the move the engine would rather have played. No daily limit and nothing to unlock.

New to chess? Nine chapters and 38 pages, with 27 board diagrams — 15 of them playable, on real legal moves asked from the engine.

No ads. No purchases. No account. No internet.
```

**CZ**

```
Šachy pro jednoho i pro dva hráče, s vlastním enginem. Pět úrovní od začátečnické po velmistrovskou, za bílého i za černého, a dvě nejvyšší zahajují z knihy 90 pojmenovaných variant, takže nehrají pořád jednu partii.

Pro dva hráče podejte telefon přes stůl — šachovnice se otočí k tomu, kdo je na tahu. Nápověda se zeptá enginu, jaký tah by zahrál on; Zpět vezme váš tah nazpět a s ním i odpověď počítače.

Když partie skončí, Rozbor partie ohodnotí každý tah od brilantního po hrubku, spočítá přesnost každého hráče, nakreslí graf, kdo kdy stál lépe, a ukáže tah, který by engine zahrál radši. Žádný denní limit, nic se neodemyká.

Začínáte? Devět kapitol a 38 stránek, s 27 diagramy — z toho 15 hratelných, na opravdových možných tazích, na které se aplikace zeptala enginu.

Bez reklam. Bez nákupů. Bez účtu. Bez internetu.
```
