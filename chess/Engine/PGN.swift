//
//  PGN.swift
//  chess
//
//  Portable Game Notation: writing a game out so any other chess program can
//  read it, and reading games back in. Files go in and out through the
//  system's share sheet and document picker — nothing here touches a network.
//

import Foundation

nonisolated enum PGN {

    // MARK: Writing

    /// One game as PGN. The seven tags the standard requires come first, in
    /// the order it gives them — Event, Site, Date, Round, White, Black,
    /// Result — whatever order `tags` has them in, and filled in where it
    /// has not; the rest of `tags` follow as given, and a game that did not
    /// start from the initial position says where it did.
    ///
    /// The order is the standard's own rule for export format, not a nicety:
    /// an imported game's tags are kept in a dictionary and handed back
    /// sorted, and its file used to open with `[Black …]`.
    ///
    /// The Result tag is not copied from `tags` but written from the same
    /// result the moves end with (see `result(of:recorded:)`): an imported
    /// game whose tag said "*" and whose moves ended in mate went out with
    /// `[Result "*"]` above `Qh4# 0-1`.
    ///
    /// `clockAfterMove` holds a face for every move, or it is not written
    /// at all. Faces that do not match the moves one for one cannot say
    /// which move each belongs to: handed out in order, they went to the
    /// wrong moves, and a reader replayed the game with clocks it never had.
    static func export(
        game: Game,
        tags: [(String, String)] = [],
        clockAfterMove: [TimeInterval]? = nil
    ) -> String {
        let result = Self.result(of: game, recorded: tags.first { $0.0 == "Result" }?.1)
        let roster: [(String, String)] = [
            ("Event", "Casual game"), ("Site", "Chess (offline)"),
            ("Date", "????.??.??"), ("Round", "-"),
            ("White", "?"), ("Black", "?"),
        ]
        var all = roster.map { key, fallback in (key, tags.first { $0.0 == key }?.1 ?? fallback) }
        all.append(("Result", result))
        all += tags.filter { tag in tag.0 != "Result" && !roster.contains { $0.0 == tag.0 } }
        func has(_ key: String) -> Bool { all.contains { $0.0 == key } }
        // The variant's name as Lichess writes it, so the file opens there
        // under the right rules.
        if game.variant != .standard, !has("Variant") {
            all.append(("Variant", game.variant == .kingOfTheHill ? "King of the Hill" : "Three-check"))
        }
        if game.initialFEN != Board.startFEN {
            if game.board.isChess960 || Board(fen: game.initialFEN)?.isChess960 == true, !has("Variant") {
                all.append(("Variant", "Chess960"))
            }
            if !has("SetUp") { all.append(("SetUp", "1")) }
            if !has("FEN") { all.append(("FEN", game.initialFEN)) }
        }
        // A game that is still going on the board but carries a result has
        // ended in a way the moves cannot show, and this app does not know
        // which: it says nothing rather than "unterminated".
        if !has("Termination"), game.outcome.isGameOver || result == "*",
           let termination = termination(of: game.outcome) {
            all.append(("Termination", termination))
        }

        var text = all.map { "[\($0.0) \"\(escape($0.1))\"]" }.joined(separator: "\n")
        text += "\n\n"

        var tokens: [String] = []
        let clocks = clockAfterMove.flatMap { $0.count == game.history.count ? $0 : nil }
        // A Black move carries its number too where it does not follow White's
        // directly — first in the game, or after a comment, where the
        // standard's export format asks for "12..." again.
        var numberBlack = true
        for (index, played) in game.history.enumerated() {
            if played.color == .white {
                tokens.append("\(played.moveNumber).")
            } else if numberBlack {
                tokens.append("\(played.moveNumber)...")
            }
            tokens.append(played.san)
            numberBlack = false
            if let clocks {
                tokens.append("{[%clk \(clockText(clocks[index]))]}")
                numberBlack = true
            }
        }
        tokens.append(result)
        text += wrap(tokens, width: 79)
        return text + "\n"
    }

    /// The one result a game is written out with, in its Result tag and
    /// after its last move alike. A reader that finds the two disagreeing
    /// has to pick one, and the standard asks for them to be the same.
    ///
    /// A game that has ended says how itself, and `game.outcome` is taken
    /// first: a mate or a draw on the board is a fact the moves prove, and
    /// a resignation, a flag or a draw agreed is what the game was ended
    /// with, here or by the import that read the game in. A tag that says
    /// otherwise is out of date — "*" left on a game whose moves end in mate.
    /// Only while the game is still going on the board does the `recorded`
    /// result count, the Result tag the game came with: it is all there is
    /// to say how a game the moves do not finish was finished. Anything
    /// that is not a result is "*".
    private static func result(of game: Game, recorded: String?) -> String {
        if game.outcome.isGameOver { return result(of: game.outcome) }
        switch recorded.map(withPlainDashes)?.trimmingCharacters(in: .whitespaces) {
        case "1-0": return "1-0"
        case "0-1": return "0-1"
        case "1/2-1/2", "½-½", "1/2": return "1/2-1/2"
        default: return "*"
        }
    }

    /// Several games, one after another, as a PGN file holds them.
    static func export(_ games: [String]) -> String {
        games.joined(separator: "\n")
    }

    static func result(of outcome: GameOutcome) -> String {
        if let winner = outcome.winner { return winner == .white ? "1-0" : "0-1" }
        return outcome.isDraw ? "1/2-1/2" : "*"
    }

    private static func termination(of outcome: GameOutcome) -> String? {
        switch outcome {
        case .timeForfeit, .drawTimeoutInsufficientMaterial: return "time forfeit"
        case .ongoing: return "unterminated"
        default: return "normal"
        }
    }

    /// "1:02:03" for the `%clk` comment the big servers write and read.
    ///
    /// Bounded before it is made a whole number: `Int(_:)` traps on NaN, on
    /// infinity and on anything past `Int.max`, and the faces are worked out
    /// from stored move times and time controls that nothing else vets. A
    /// face that is not a number reads as an empty clock.
    private static func clockText(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(seconds, 0), 1_000_000_000) : 0
        let total = Int(bounded.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// A tag value as it may stand between the quotes. A line break is made
    /// a space: a tag is one line, and a value that broke it ended the tag
    /// section there, so the file read back as two games.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// The tokens on lines of at most `width` characters, broken only between
    /// tokens. The standard's export format asks for movetext lines of fewer
    /// than eighty characters (8.2.6), so `export` asks for 79: it used to
    /// ask for 80, and a line that came out exactly that long broke the rule.
    private static func wrap(_ tokens: [String], width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for token in tokens {
            if line.isEmpty {
                line = token
            } else if line.count + 1 + token.count > width {
                lines.append(line)
                line = token
            } else {
                line += " " + token
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    /// Clock faces after each move, rebuilt from the time each move took —
    /// what a game recorded in the app knows about its clock. The first move
    /// is not charged, the same rule `GameViewModel` plays by, and the bonus
    /// is added to what was left after the move, never less than nothing, the
    /// way `ChessClock.press` adds it.
    ///
    /// There is one face for each time given, whatever the game's moves come
    /// to. Times kept for fewer moves than the game has, or for more, are no
    /// clock for it, and `export` writes no faces for them at all.
    ///
    /// `firstMover` is the side whose move the first time is: Black's, in a
    /// game set up with Black to move. Taken to be White's, every time was
    /// charged to the side that did not spend it.
    static func clockFaces(
        control: TimeControl, moveTimes: [TimeInterval], firstMover: PieceColor = .white
    ) -> [TimeInterval] {
        var remaining = [control.initialTime(for: .white), control.initialTime(for: .black)]
        var faces: [TimeInterval] = []
        let offset = firstMover == .white ? 0 : 1
        for (ply, spent) in moveTimes.enumerated() {
            let side = (ply + offset) % 2
            if ply > 0 {
                switch control.bonusKind {
                case .increment: remaining[side] = max(0, remaining[side] - spent) + control.bonus
                case .bronstein: remaining[side] = max(0, remaining[side] - spent) + min(spent, control.bonus)
                case .delay: remaining[side] = max(0, remaining[side] - max(0, spent - control.bonus))
                }
            }
            faces.append(remaining[side])
        }
        return faces
    }

    // MARK: Reading

    struct ParsedGame: Sendable {
        var tags: [String: String]
        var game: Game
        /// The token reading stopped at, nil when it reached the end of the
        /// game. What came before it is still a game; what came after is
        /// lost, and this is how a reader of the file is told so.
        ///
        /// Most often a move that is not legal or does not read. It is also
        /// a move played after the game had already ended by itself — after
        /// a mate, or after one of FIDE's automatic draws, the fifth
        /// repetition and seventy-five moves (see `Game.settlesClaimableDraws`)
        /// — which no legal move can match; and the opening bracket of a
        /// variation or a comment that was never closed, "(" or "{", which
        /// took every move after it along with it (see `tokens(of:)`).
        ///
        /// It may be the game's very first move, and the game then has no
        /// moves at all. It is kept all the same, so that the token is told —
        /// in text without tags too, as long as the token is written the way
        /// a move is (see `contents(of:)`).
        var unreadMove: String?
    }

    /// What a PGN text holds: every game in it that could be read, and how
    /// many more there were that could not be read at all.
    struct Contents: Sendable {
        var games: [ParsedGame]
        /// Games left out because they could not be set up: a FEN tag that
        /// is no position, or none the game's variant can be played from.
        /// Such a game used to drop out of its file without a word, and a
        /// file of nothing else read as no PGN at all.
        var unreadableGames: Int
        /// Whether reading stopped at `maxGames` with more of the text left.
        var stoppedAtLimit = false
    }

    enum ParseError: Error, Equatable {
        case noGames
    }

    /// Every game in a PGN text that could be read; throws when there is
    /// none. `contents(of:)` says, as well, how many could not be.
    static func parse(_ text: String) throws -> [ParsedGame] {
        let games = try contents(of: text).games
        if games.isEmpty { throw ParseError.noGames }
        return games
    }

    /// Every game in a PGN text, and how many it held that could not be
    /// read. A game whose moves stop making sense is kept up to the last
    /// move that did, with the offending token noted. Throws only when the
    /// text holds no game at all, whether it can be read or not.
    ///
    /// For a reader that files only games with moves — the import — `played`
    /// leaves out the ones without, and `maxGames` stops reading after that
    /// many. Each game read is a whole `Game`, held until the reading is
    /// done, and a file inside the import's limit written to be read as
    /// games and little else — a tag a line, a move a game — came to over a
    /// million of them: a gigabyte, more than a phone lets the app have.
    static func contents(of text: String, played: Bool = false, maxGames: Int = .max) throws -> Contents {
        var games: [ParsedGame] = []
        var unreadable = 0
        var stoppedAtLimit = false
        var tags: [String: String] = [:]
        var movetext = ""
        // Whether `movetext` holds anything but white space, kept as it grows
        // rather than asked of it at every tag line: asked, the whole of it
        // was trimmed each time, and a file of blank lines between new tags
        // took hours to read inside the import limit.
        var movetextHasContent = false
        func appendToMovetext(_ line: String) {
            movetext += line + "\n"
            if !movetextHasContent, line.contains(where: { !$0.isWhitespace }) { movetextHasContent = true }
        }

        // Text with no tags is a game only if it holds a move. What a file
        // carries before its first tag — a title, "Game 1", an annotator's
        // comment — was read as a game with nothing in it, ahead of the real
        // ones, and whoever took the first game of the file took that.
        //
        // A move that does not read counts, as long as it is written the way
        // a move is: "Nf6 e4", a game whose first move is not one White can
        // play, threw "no games" as though nothing had been there, rather
        // than saying which move it was. Words are not written that way.
        //
        // A result ends a game, and moves after it are the next game's (see
        // `movetextOfGames(in:)`). Text with no tags holding several games —
        // games pasted one after another — was read as its first game, and
        // the rest were dropped without a word. Only the first of them has
        // the tags; the others never had any to lose.
        //
        // A game that is tags alone, from the standard position, is not set
        // up at all when only played games are wanted: there is nothing in it
        // to keep, nor anything to count as unread.
        func flush() {
            guard movetextHasContent || !tags.isEmpty else { return }
            let body = movetext.trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, tokens) in movetextOfGames(in: body).enumerated() {
                let gameTags = index == 0 ? tags : [:]
                if played, tokens.isEmpty, gameTags["FEN"] == nil { continue }
                guard games.count < maxGames else {
                    stoppedAtLimit = true
                    break
                }
                guard let parsed = parseGame(tags: gameTags, tokens: tokens) else {
                    unreadable += 1
                    continue
                }
                if played, parsed.game.history.isEmpty, parsed.unreadMove == nil { continue }
                if !gameTags.isEmpty || !parsed.game.history.isEmpty
                    || parsed.unreadMove.map(isWrittenAsMove) == true {
                    games.append(parsed)
                }
            }
            tags = [:]
            movetext = ""
            movetextHasContent = false
        }

        // A brace comment may run over several lines, and whatever they hold
        // is comment — a line inside one that looks like a tag included.
        //
        // But not past a blank line and a tag after it, which is where the
        // next game begins: a comment left open — "1. e4 {oops e5 1-0" —
        // read every game after it as part of itself, and a database of
        // hundreds came in as the one game that ended early. The game with
        // the open comment stops at its "{" (see `tokens(of:)`), as it did.
        // Only a tag written out in full counts, `[Name "value"]`: not a
        // command inside a comment, "[%clk 0:01:00]", nor a remark in
        // brackets. A Windows line break is one break, not a line break and
        // a blank line after it.
        var inComment = false
        var afterBlankLine = false
        let lines = withoutByteOrderMarks(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        for rawLine in lines {
            if stoppedAtLimit { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inComment, afterBlankLine, opensWithTag(line) { inComment = false }
            afterBlankLine = line.isEmpty
            if !inComment {
                if line.hasPrefix("%") { continue } // escape lines are ignored by the standard
                // Movetext has no "[" outside a comment, so a line opening
                // with one is tags, however badly written. One that does not
                // read at all is passed over: kept as movetext it was the
                // game's first move, and the game stopped before it began.
                if line.hasPrefix("[") {
                    let (lineTags, rest) = parseTags(line)
                    // A tag after movetext starts the next game, and so does
                    // one this game already has: a game that ended at its
                    // tags, with no moves, is a game of its own rather than
                    // the first half of the next one.
                    if lineTags.contains(where: { tags[$0.0] != nil }) || movetextHasContent {
                        flush()
                    }
                    for (key, value) in lineTags { tags[key] = value }
                    // Moves on the line of the last tag are the game's: a
                    // game whose line breaks were lost on the way, pasted
                    // as one line, was read as tags and nothing else.
                    if let rest, opensMovetext(rest), !isInComment(after: rest, startingInComment: false) {
                        appendToMovetext(rest)
                    }
                    continue
                }
            }
            appendToMovetext(rawLine)
            inComment = isInComment(after: rawLine, startingInComment: inComment)
        }
        if !stoppedAtLimit { flush() }
        if games.isEmpty, unreadable == 0 { throw ParseError.noGames }
        return Contents(games: games, unreadableGames: unreadable, stoppedAtLimit: stoppedAtLimit)
    }

    /// The text without the byte-order mark a Windows tool puts in front of
    /// a file, or in front of each of several files run together. Left in,
    /// it hid the opening "[" of the first tag, and the file read as one
    /// unreadable move. The file importer drops it as it decodes the bytes;
    /// a pasted text or any other caller is not so careful.
    private static func withoutByteOrderMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{FEFF}") else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FEFF}" }))
    }

    /// Whether the text after a line's tags opens the way a game's movetext
    /// does: with a move number, "1." or "12...", with a move written without
    /// one, "e4", or with the result of a game that has no moves — once any
    /// comment or glyph in front of it is looked past, "{Opening} 1. e4". A
    /// game pasted as one line may open any of these ways, and its moves were
    /// lost without a word unless they opened with a number or a result.
    /// Whatever else follows a tag is passed over, as it always was — a
    /// "; comment", a comment alone, or the debris of a tag that did not read
    /// the way it was meant to, a stray "7" or "2[Result". Read as movetext,
    /// any of it was the game's first move, which did not read, so the game
    /// stopped before it began; and the next tag line parted the game's tags
    /// from its moves. A brace comment left open is not taken either (see
    /// `contents(of:)`): it would read every tag after it as comment.
    private static func opensMovetext(_ text: String) -> Bool {
        var text = Substring(text).drop(while: \.isWhitespace)
        while let first = text.first, first == "{" || first == "$" {
            if first == "{" {
                guard let close = text.firstIndex(of: "}") else { return false }
                text = text[text.index(after: close)...]
            } else {
                text = text.dropFirst().drop(while: \.isNumber)
            }
            text = text.drop(while: \.isWhitespace)
        }
        let number = text.prefix { $0.isASCII && $0.isNumber }
        if !number.isEmpty, let after = text.dropFirst(number.count).first, after == "." || after == "…" {
            return true
        }
        let plain = withPlainDashes(text)
        if resultsLongestFirst.contains(where: { plain.hasPrefix($0) }) { return true }
        return tokens(of: String(text)).first.map(isWrittenAsMove) ?? false
    }

    /// Whether a line opens with a tag the way the standard writes one: a
    /// name of letters, digits and underscores, a space, and a quoted value.
    private static func opensWithTag(_ line: String) -> Bool {
        guard line.first == "[" else { return false }
        let rest = line.dropFirst()
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return false }
        let afterName = rest.dropFirst(name.count)
        let gap = afterName.prefix(while: \.isWhitespace)
        return !gap.isEmpty && afterName.dropFirst(gap.count).first == "\""
    }

    /// The tokens of one movetext, split into games where a result ends one.
    /// There is always at least one, empty for a game that is tags alone.
    /// What follows a result without a move in it — a second result, or
    /// debris — is no game: `contents(of:)` keeps a game without tags only
    /// when a move of it was read, or written the way a move is.
    private static func movetextOfGames(in movetext: String) -> [[String]] {
        var games: [[String]] = [[]]
        for token in tokens(of: movetext) {
            games[games.count - 1].append(token)
            if results.contains(token) { games.append([]) }
        }
        if games.count > 1, games[games.count - 1].isEmpty { games.removeLast() }
        return games
    }

    /// Whether a brace comment is still open at the end of a movetext line,
    /// given whether one was open at its start. Read the way `tokens(of:)`
    /// reads it: a brace comment ends at the first closing brace, and a
    /// semicolon outside one comments out the rest of the line, braces and
    /// all.
    private static func isInComment(after line: String, startingInComment: Bool) -> Bool {
        var inComment = startingInComment
        for character in line {
            if inComment {
                if character == "}" { inComment = false }
            } else if character == "{" {
                inComment = true
            } else if character == ";" {
                break
            }
        }
        return inComment
    }

    /// The tags on one line, read leniently: the name and the value may be
    /// parted by any whitespace or by none, the value need not be quoted nor
    /// a quote inside it escaped, and several tags may share the line.
    /// Whatever follows the last of them — moves, a "; comment" — is handed
    /// back as `rest`, for the caller to decide what to make of. A tag that
    /// does not read is dropped, and so is the rest of its line: nothing
    /// after a broken tag can be told apart from the tag's own text.
    private static func parseTags(_ line: String) -> (tags: [(String, String)], rest: String?) {
        var tags: [(String, String)] = []
        var rest = Substring(line)
        while rest.first == "[" {
            rest.removeFirst()
            let name = rest.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "]" }
            rest = rest[name.endIndex...].drop(while: \.isWhitespace)
            var value = ""
            if rest.first == "\"" {
                rest.removeFirst()
                // A quote closes the value only where the bracket follows it,
                // so "The "Big" Game" keeps its inner quotes.
                var closed = false
                while let character = rest.popFirst() {
                    if character == "\\", let next = rest.first, next == "\"" || next == "\\" {
                        value.append(next)
                        rest.removeFirst()
                    } else if character == "\"", rest.drop(while: \.isWhitespace).first == "]" {
                        closed = true
                        break
                    } else {
                        value.append(character)
                    }
                }
                guard closed else { return (tags, nil) }
                rest = rest.drop(while: \.isWhitespace)
            } else {
                let raw = rest.prefix { $0 != "]" }
                guard raw.endIndex < rest.endIndex else { return (tags, nil) }
                value = raw.trimmingCharacters(in: .whitespaces)
                rest = rest[raw.endIndex...]
            }
            rest.removeFirst()
            if !name.isEmpty { tags.append((String(name), value)) }
            rest = rest.drop(while: \.isWhitespace)
        }
        return (tags, rest.isEmpty ? nil : String(rest))
    }

    /// Every way a movetext writes a result, longest first, so that a result
    /// glued to a move is told by the longest that fits — "1/2-1/2" before
    /// the "1/2" it ends with, which is the shorthand some programs write a
    /// draw in, and was read as a move that did not exist.
    private static let resultsLongestFirst = ["1/2-1/2", "1-0", "0-1", "½-½", "1/2", "*"]
    private static let results = Set(resultsLongestFirst)

    /// The text with the en and em dashes a word processor makes of hyphens
    /// turned back into hyphens: "1–0", "½–½", "O–O", "+–". A result written
    /// so was read as a move that did not exist — the game "ended early" on
    /// its own result, a draw came in as a game unfinished, and in pasted
    /// text the games after it were lost.
    private static func withPlainDashes(_ text: some StringProtocol) -> String {
        String(text.map { $0 == "–" || $0 == "—" ? "-" : $0 })
    }

    private static func parseGame(tags: [String: String], tokens: [String]) -> ParsedGame? {
        var fen = tags["FEN"] ?? Board.startFEN
        let variant = variant(named: tags["Variant"])
        // "KQkq" need not show that a game is Chess960 — the standard array
        // never does — so a Variant tag that says so is taken at its word,
        // and the FEN written over in Shredder-FEN, which carries it.
        if isChess960(variantNamed: tags["Variant"]), let board = Board(fen: fen, chess960: true) {
            fen = board.fen
        }
        guard Board(fen: fen, variant: variant) != nil else { return nil }
        // Read under FIDE's draw rules rather than the app's: a repetition
        // nobody claimed did not end the game, and the moves after it are
        // part of it (see `Game.settlesClaimableDraws`).
        var game = Game(fen: fen, variant: variant, settlesClaimableDraws: false)
        var unread: String?
        var movetextResult: String?

        // A game that has ended by itself — mated, or drawn by the fifth
        // repetition or the seventy-fifth move — has no legal moves left, so
        // a move written after its end is unread like any other move that
        // cannot be played, and the game is kept to where it ended. Reading
        // used to stop at the end without a word, and a file whose players
        // had played on past a fivefold repetition lost the rest of its
        // moves unnoticed.
        for token in tokens {
            if results.contains(token) {
                movetextResult = token
                break
            }
            guard let move = move(for: token, in: game) else {
                unread = token
                break
            }
            game.play(move)
        }

        // The result says how a game ended that the moves alone do not: a
        // resignation, a claimed or an agreed draw, a flag. The tag says it
        // first; a game without one, or with one that says nothing — "*",
        // "?" — goes by the result its moves end with, when they are read to
        // it.
        var result = tags["Result"].map(withPlainDashes)?.trimmingCharacters(in: .whitespaces) ?? ""
        if ["", "*", "?"].contains(result) { result = movetextResult ?? result }
        if !game.outcome.isGameOver {
            let termination = tags["Termination"]?.lowercased() ?? ""
            switch result {
            case "1-0":
                if termination.contains("time"), game.sideToMove == .black { game.recordTimeForfeit() } else { game.resign(.black) }
            case "0-1":
                if termination.contains("time"), game.sideToMove == .white { game.recordTimeForfeit() } else { game.resign(.white) }
            case "1/2-1/2", "½-½", "1/2":
                // Drawn on time is a flag that fell against a side with
                // nothing to mate with — the way this app writes that draw.
                if termination.contains("time"), !game.board.hasMatingMaterial(game.sideToMove.opponent) {
                    game.timeOut()
                } else if !game.claimDraw() {
                    game.agreeToDraw()
                }
            default:
                break
            }
        }
        return ParsedGame(tags: tags, game: game, unreadMove: unread)
    }

    /// The rules a `Variant` tag names. Anything the app does not play reads
    /// as standard chess, which is what such a game's moves will be checked
    /// against — and refused at the first one that breaks the rules.
    static func variant(named tag: String?) -> ChessVariant {
        let name = (tag ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch name {
        case "kingofthehill", "koth": return .kingOfTheHill
        case "threecheck", "3check": return .threeCheck
        default: return .standard
        }
    }

    /// Whether a `Variant` tag names Chess960, under any of the names it goes
    /// by. The variant lives on the board rather than in `ChessVariant`, so
    /// this is asked separately.
    private static func isChess960(variantNamed tag: String?) -> Bool {
        let name = (tag ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        return ["chess960", "960", "fischerandom", "fischerrandom"].contains(name)
    }

    /// The SAN tokens of a movetext, with comments, variations, move numbers
    /// and annotation glyphs taken out, and its results among them.
    ///
    /// A variation or a brace comment that is never closed runs to the end
    /// of the text, and takes every move after its opening bracket with it.
    /// That bracket is then the last token: no move matches it, so reading
    /// stops there, with the bracket as the move it could not read. The game
    /// used to stop at the same place as though its moves had simply run
    /// out, and nobody was told what had been left out. Where the variation
    /// was meant to close nothing can tell, so the moves after the bracket
    /// are not guessed at.
    static func tokens(of movetext: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var braceDepth = 0
        var variationDepth = 0
        var inLineComment = false

        func emit() {
            defer { current = "" }
            // A dash standing alone is what a word processor makes of "--",
            // the null move, and stays one (see below): turned into a hyphen
            // it was an annotation, passed over, and every move after it
            // went to the wrong side.
            var token = current == "–" || current == "—" ? "--" : withPlainDashes(current)
            guard !token.isEmpty else { return }
            // "12." or "12..." alone, or glued to the move: "12.e4" — and
            // "12…", the one-character ellipsis a word processor makes of the
            // three dots.
            func isDots(_ character: Character) -> Bool { character == "." || character == "…" }
            if let dot = token.lastIndex(where: isDots), token[..<dot].allSatisfy({ $0.isNumber || isDots($0) }) {
                token = String(token[token.index(after: dot)...])
            }
            // A result glued to the last move, "Qxf7#1-0", is a token of its
            // own. Read as part of the move, it made the mating move
            // unreadable, and the game ended one move short with its result
            // unread. Nothing a move is written with ends the way a result
            // does: its only hyphens are castling's, "0-0" never "1-0" or
            // "0-1", and its only slash an evaluation's, "+/=".
            var result: String?
            if let glued = resultsLongestFirst.first(where: token.hasSuffix), glued != token {
                result = glued
                token.removeLast(glued.count)
            }
            defer { if let result { tokens.append(result) } }
            guard !token.isEmpty, !token.hasPrefix("$") else { return }
            // An annotation or an "e.p." standing apart from its move — "!?",
            // "+-", "+/=", "=/∞", "e.p." — says something about the move
            // before it and is not a move of its own. "--" is kept: it is a
            // null move, which the app cannot play, and skipping it would
            // hand every later move to the wrong side.
            if token == "e.p." || (token != "--" && token.allSatisfy({ annotationSigns.contains($0) })) { return }
            tokens.append(token)
        }

        for character in movetext {
            if inLineComment {
                if character == "\n" { inLineComment = false }
                continue
            }
            if braceDepth > 0 {
                if character == "}" { braceDepth -= 1 }
                continue
            }
            switch character {
            case "{": emit(); braceDepth += 1
            case ";": emit(); inLineComment = true
            case "(": emit(); variationDepth += 1
            case ")": emit(); variationDepth = max(0, variationDepth - 1)
            default:
                guard variationDepth == 0 else { continue }
                if character.isWhitespace {
                    emit()
                    continue
                }
                // A glyph glued to its move, "e4$1", is a token of its own:
                // "$" begins one, and a glyph is nothing but digits after it.
                // Read as part of the move, it stopped the game there.
                if character == "$" || (current.hasPrefix("$") && !character.isNumber) { emit() }
                current.append(character)
            }
        }
        emit()
        // Nothing reaches the main line inside a comment, so a variation
        // still open is the outer of the two.
        if variationDepth > 0 {
            tokens.append("(")
        } else if braceDepth > 0 {
            tokens.append("{")
        }
        return tokens
    }

    /// Every sign an annotation or an evaluation is written with — "!?",
    /// "+-", "+/=", "=/∞", "±", "□", "‼" — standing apart from its move or
    /// glued to it.
    private static let annotationSigns: Set<Character> = [
        "!", "?", "+", "-", "=", "/", "∓", "±", "⩲", "⩱", "∞", "□", "‼", "⁇", "⁉", "⁈",
    ]

    /// The legal move a SAN token names, read leniently: check marks and
    /// annotations are ignored, castling may be written with zeros, a
    /// lowercase o or a word processor's dashes, or as the king taking its
    /// own rook, the capture sign may be missing, pieces may be figurines, a
    /// promotion piece may be lowercase and need not follow "=", and a move
    /// may be disambiguated more than it needs to be, down to the whole
    /// square it came from, in long algebraic: "Ng1f3", "Ng1-f3", "e7xd8=Q".
    /// Anything else in front of the target square is refused rather than
    /// skipped over: "Zf3" or "nf3" used to read as the pawn move f2–f3.
    static func move(for token: String, in game: Game) -> Move? {
        guard let written = written(token) else { return nil }
        let legal = game.legalMoves
        switch written {
        case .castle(let kingside):
            return legal.first { kingside ? $0.isCastleKingside : $0.isCastleQueenside }
        case .move(let pieceKind, let target, let fileHint, let rankHint, let promotion):
            // A castle written as the king taking its own rook, "Kxa1" — the
            // way Chess960 programs write it, and UCI_Chess960 — is that
            // castle: no other move lands on a square the mover's own piece
            // holds, so nothing else can be meant. It used to be refused while
            // "O-O-O" read. The king's landing square is not taken for the
            // castle, as some write it, "Kc1": in Chess960 an ordinary step of
            // the king may land there too.
            let board = game.board
            let matches = legal.filter { move in
                let lands = move.isCastle ? board.castlingSquares(for: move)?.rookFrom : move.to
                return move.piece.kind == pieceKind && lands == target
                    && move.promotion == promotion
                    && (fileHint == nil || move.from.file == fileHint)
                    && (rankHint == nil || move.from.rank == rankHint)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    /// A move as a token writes it, before it is looked for among the legal
    /// moves: a castle, or a piece going to a square, with whatever the
    /// token says about where the piece came from and what it promotes to.
    private enum WrittenMove {
        case castle(kingside: Bool)
        case move(piece: PieceKind, to: Square, file: Int?, rank: Int?, promotion: PieceKind?)
    }

    /// Whether a token is written the way a move is, legal anywhere or not:
    /// "e4", "Nxf3+", "e7-e8=Q", "O-O". It tells a move that cannot be
    /// played, which is worth reporting, from a word in front of a file's
    /// first game — "Game", "Annotated" — which is not.
    private static func isWrittenAsMove(_ token: String) -> Bool {
        written(token) != nil
    }

    /// What a token says as a move, read the lenient way `move(for:in:)`
    /// reads it, or nil when it is no move at all, whatever the position.
    private static func written(_ token: String) -> WrittenMove? {
        var san = String(token.filter { !"+#!?".contains($0) }.map(letter(forFigurine:)))
        // A move ends in a digit, a promotion piece or a castle's O, so an
        // evaluation glued on after it — "Nf3+-", "Nf3=", "e4+/-", "d5±" —
        // comes off the end and leaves the move whole.
        func dropAnnotation() {
            while let last = san.last, annotationSigns.contains(last) { san.removeLast() }
        }
        dropAnnotation()
        if san.hasSuffix("e.p.") {
            san = String(san.dropLast(4))
            dropAnnotation()
        }
        // "O-O", "0-0", "o-o", and the en and em dashes a word processor
        // makes of the hyphens, "O–O" and "O—O". Refused, any of them
        // stopped the game at the castle.
        let castle = String(san.map { character -> Character in
            switch character {
            case "0", "o": return "O"
            case "–", "—": return "-"
            default: return character
            }
        })
        if castle == "O-O" { return .castle(kingside: true) }
        if castle == "O-O-O" { return .castle(kingside: false) }

        // Promotion: "e8=Q" or "e8Q" — or, lowercase, "e8=q" and "e8q", as
        // engines and some programs write it. A move never ends in a file,
        // so a lowercase letter after the rank can only be the piece: "b8b"
        // is a b-pawn promoting to a bishop, and "exb8b" an e-pawn doing so
        // as it takes on b8. In front of the square a "b" is still a file.
        var promotion: PieceKind?
        if let last = san.last, san.count >= 3, let before = san.dropLast().last,
           "QRBNqrbn".contains(last), before.isNumber || before == "=" {
            promotion = kind(for: Character(last.uppercased()))
            san.removeLast()
            if san.last == "=" { san.removeLast() }
        }
        guard san.count >= 2 else { return nil }
        let targetText = String(san.suffix(2))
        guard let target = Square(algebraic: targetText) else { return nil }
        var prefix = String(san.dropLast(2)).replacingOccurrences(of: "x", with: "")
            .replacingOccurrences(of: ":", with: "")

        var pieceKind = PieceKind.pawn
        if let first = prefix.first, first.isUppercase {
            guard let kind = kind(for: first) else { return nil }
            pieceKind = kind
            prefix.removeFirst()
        }
        // Long algebraic parts the two squares with a hyphen, "e2-e4" or
        // "Ng1-f3", which stopped the game at its first move. It is taken
        // only after the whole square the piece came from, where it can mean
        // nothing else; the square then says which piece, as it does when
        // written without the hyphen.
        if let last = prefix.last, "-–—".contains(last) {
            prefix.removeLast()
            guard prefix.count == 2, Square(algebraic: prefix) != nil else { return nil }
        }
        // What is left can only tell two pieces apart: a file, a rank, or both.
        guard prefix.count <= 2,
              prefix.allSatisfy({ "abcdefgh".contains($0) || "12345678".contains($0) })
        else { return nil }
        let fileHint = prefix.first(where: { ("a"..."h").contains($0) }).flatMap { "abcdefgh".firstIndex(of: $0) }
            .map { "abcdefgh".distance(from: "abcdefgh".startIndex, to: $0) }
        let rankHint = prefix.first(where: { $0.isNumber }).flatMap { $0.wholeNumberValue }.map { $0 - 1 }
        return .move(piece: pieceKind, to: target, file: fileHint, rank: rankHint, promotion: promotion)
    }

    /// The SAN letter a figurine stands for — "♘f3" is "Nf3" — whichever
    /// colour it is drawn in. Any other character is handed back as it is.
    private static func letter(forFigurine character: Character) -> Character {
        switch character {
        case "♔", "♚": return "K"
        case "♕", "♛": return "Q"
        case "♖", "♜": return "R"
        case "♗", "♝": return "B"
        case "♘", "♞": return "N"
        case "♙", "♟": return "P"
        default: return character
        }
    }

    private static func kind(for letter: Character) -> PieceKind? {
        switch letter {
        case "K": return .king
        case "Q": return .queen
        case "R": return .rook
        case "B": return .bishop
        case "N": return .knight
        case "P": return .pawn
        default: return nil
        }
    }
}
