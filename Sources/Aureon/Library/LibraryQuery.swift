import Foundation
import CoreData

// A small query language for the library:
//
//     Genre: Jazz AND Year: 1955..1965 NOT Artist: "Miles Davis"
//     composer:beethoven (tag:Classical/Symphonies OR work:sonata) -live rate:>=96k
//
//   query   := or
//   or      := and ( ("OR" | "||" | "|") and )*
//   and     := unary ( ["AND" | "&&" | "&"] unary )*          juxtaposition means AND, so "A NOT B" is "A AND NOT B"
//   unary   := ("NOT" | "!" | "-") unary | primary
//   primary := "(" or ")" | field ":" value | value
//   value   := "quoted text" (exact) | word (contains; * and ? are wildcards) | a..b | >x | >=x | <x | <=x | =x
//
// Operators are recognised in capitals only, so "rock and roll" is three words, not a Boolean. Matching ignores case and accents.
// A query compiles to one Core Data predicate (run by SQLite, never by loading the library into memory); `matches` evaluates the same
// query on a TrackDTO and is the reference the tests hold the SQL to.

enum QueryField: String, CaseIterable, Sendable {
    case any, title, artist, albumArtist, album, composer, conductor, ensemble, performer, person, genre, tag, year, work, catalog
    case codec, rate, bits, channels, liked, plays, lufs, dr, duration, path, hires

    /// Names (lower case) a person can type for each field.
    static let aliases: [String: QueryField] = [
        "title": .title, "song": .title, "track": .title, "name": .title,
        "artist": .artist, "by": .artist, "albumartist": .albumArtist, "album_artist": .albumArtist, "aa": .albumArtist,
        "album": .album, "release": .album, "composer": .composer, "conductor": .conductor, "ensemble": .ensemble, "orchestra": .ensemble,
        "performer": .performer, "soloist": .performer, "person": .person, "people": .person, "who": .person,
        "genre": .genre, "tag": .tag, "tags": .tag, "style": .tag, "year": .year, "date": .year, "work": .work, "catalog": .catalog, "opus": .catalog,
        "codec": .codec, "format": .codec, "rate": .rate, "samplerate": .rate, "khz": .rate, "bits": .bits, "bitdepth": .bits, "depth": .bits,
        "channels": .channels, "ch": .channels, "liked": .liked, "loved": .liked, "plays": .plays, "playcount": .plays, "lufs": .lufs, "loudness": .lufs,
        "dr": .dr, "duration": .duration, "length": .duration, "time": .duration, "path": .path, "folder": .path, "file": .path, "hires": .hires, "hi-res": .hires,
    ]

    var isNumeric: Bool { [.year, .rate, .bits, .channels, .plays, .lufs, .dr, .duration].contains(self) }
    var isBoolean: Bool { self == .liked || self == .hires }
}

enum QueryValue: Equatable, Sendable {
    /// `exact` = the whole value must match (quoted); otherwise it is contained. `pattern` = it had * or ? wildcards.
    case text(String, exact: Bool, pattern: Bool)
    /// Inclusive bounds; nil is open.
    case range(Double?, Double?)
    case flag(Bool)
}

struct QueryTerm: Equatable, Sendable {
    var field: QueryField
    var value: QueryValue
}

indirect enum QueryNode: Equatable, Sendable {
    case and([QueryNode]), or([QueryNode]), not(QueryNode), term(QueryTerm)
}

// MARK: writing a query back as text

extension QueryTerm {
    /// The term as a person would type it, so a chip can be taken out of a query and the rest typed back into the search field.
    var text: String {
        func num(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
        let f = field == .any ? "" : field.rawValue + ":"
        switch value {
        case .text(let v, let exact, _): return f + (exact ? "\"\(v)\"" : v)
        case .flag(let b): return f + (b ? "yes" : "no")
        case .range(let lo, let hi):
            switch (lo, hi) {
            case let (a?, b?) where a == b: return f + "=" + num(a)
            case let (a?, b?): return f + num(a) + ".." + num(b)
            case let (a?, nil): return f + ">=" + num(a)
            case let (nil, b?): return f + "<=" + num(b)
            default: return f
            }
        }
    }
}

extension QueryNode {
    /// The query as text that parses back to the same query.
    var text: String {
        switch self {
        case .term(let t): return t.text
        case .not(.term(let t)): return "-" + t.text
        case .not(let x): return "NOT (" + x.text + ")"
        case .and(let parts): return parts.map { if case .or = $0 { return "(" + $0.text + ")" }; return $0.text }.joined(separator: " ")
        case .or(let parts): return parts.map { if case .and = $0 { return "(" + $0.text + ")" }; return $0.text }.joined(separator: " OR ")
        }
    }

    /// The pieces that are shown as chips with a remove button: the parts of a top-level AND, or the whole query.
    var removableParts: [QueryNode] { if case .and(let p) = self { return p }; return [self] }

    /// The query text without the chip at `index` (empty when it was the last one).
    func text(removing index: Int) -> String {
        var parts = removableParts
        guard parts.indices.contains(index) else { return text }
        parts.remove(at: index)
        return parts.isEmpty ? "" : QueryNode.and(parts).text
    }

    /// When the whole query is one `tag:` filter: the tag's name, for the page heading.
    var singleTagName: String? {
        if case .term(let t) = self, t.field == .tag, case .text(let v, _, _) = t.value { return v.split(separator: "/").last.map(String.init) ?? v }
        return nil
    }
}

struct QueryError: Error, Equatable, CustomStringConvertible {
    var message: String
    /// Character offset in the query where the problem is.
    var position: Int
    var description: String { message }
}

struct LibraryQuery: Equatable, Sendable {
    let root: QueryNode
    let source: String

    // MARK: detection

    /// True when `text` uses the query language (a field, an operator, quotes or brackets): plain words keep the ordinary search.
    static func looksAdvanced(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.contains("\"") || t.contains("(") || t.contains("&&") || t.contains("||") { return true }
        for w in t.split(whereSeparator: { $0.isWhitespace }) {
            let s = String(w)
            if ["AND", "OR", "NOT"].contains(s) { return true }
            if s.hasPrefix("-") && s.count > 1 || s.hasPrefix("!") && s.count > 1 { return true }
            if let c = s.firstIndex(of: ":"), QueryField.aliases[s[..<c].lowercased()] != nil { return true }
        }
        return false
    }

    // MARK: tokenizer

    enum Token: Equatable {
        case word(String), quoted(String), field(QueryField), lparen, rparen, and, or, not
    }

    static func tokenize(_ s: String) throws -> [(Token, Int)] {
        var out: [(Token, Int)] = []
        let chars = Array(s)
        var i = 0
        func isBreak(_ c: Character) -> Bool { c.isWhitespace || c == "(" || c == ")" || c == "\"" || c == "\u{201C}" || c == "\u{201D}" }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            let start = i
            if c == "(" { out.append((.lparen, start)); i += 1; continue }
            if c == ")" { out.append((.rparen, start)); i += 1; continue }
            if c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" && chars[j] != "\u{201D}" && chars[j] != "\u{201C}" { text.append(chars[j]); j += 1 }
                guard j < chars.count else { throw QueryError(message: "A quote is not closed", position: start) }
                out.append((.quoted(text), start)); i = j + 1; continue
            }
            // a negation sign glued to the next token
            if (c == "-" || c == "!"), i + 1 < chars.count, !chars[i + 1].isWhitespace, chars[i + 1] != "-" {
                out.append((.not, start)); i += 1; continue
            }
            var word = ""
            while i < chars.count, !isBreak(chars[i]) { word.append(chars[i]); i += 1 }
            switch word {
            case "AND", "&&", "&": out.append((.and, start)); continue
            case "OR", "||", "|": out.append((.or, start)); continue
            case "NOT": out.append((.not, start)); continue
            default: break
            }
            if let colon = word.firstIndex(of: ":"), let f = QueryField.aliases[word[..<colon].lowercased()] {
                out.append((.field(f), start))
                let rest = String(word[word.index(after: colon)...])
                if !rest.isEmpty { out.append((.word(rest), start + word.distance(from: word.startIndex, to: colon) + 1)) }
                continue
            }
            out.append((.word(word), start))
        }
        return out
    }

    // MARK: parser

    init(parsing text: String) throws {
        source = text
        let tokens = try Self.tokenize(text)
        guard !tokens.isEmpty else { throw QueryError(message: "The query is empty", position: 0) }
        var p = 0
        func peek() -> Token? { p < tokens.count ? tokens[p].0 : nil }
        func pos() -> Int { p < tokens.count ? tokens[p].1 : text.count }

        func parseOr() throws -> QueryNode {
            var parts = [try parseAnd()]
            while peek() == .or { p += 1; parts.append(try parseAnd()) }
            return parts.count == 1 ? parts[0] : .or(parts)
        }
        func parseAnd() throws -> QueryNode {
            var parts = [try parseUnary()]
            while let t = peek(), t != .or, t != .rparen {
                if t == .and { p += 1 }
                parts.append(try parseUnary())
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        }
        func parseUnary() throws -> QueryNode {
            if peek() == .not { p += 1; return .not(try parseUnary()) }
            return try parsePrimary()
        }
        func parsePrimary() throws -> QueryNode {
            guard let t = peek() else { throw QueryError(message: "Something is missing at the end", position: pos()) }
            let at = pos()
            switch t {
            case .lparen:
                p += 1
                let inner = try parseOr()
                guard peek() == .rparen else { throw QueryError(message: "A bracket is not closed", position: at) }
                p += 1
                return inner
            case .rparen: throw QueryError(message: "Unexpected “)”", position: at)
            case .and, .or: throw QueryError(message: "An operator needs something on both sides", position: at)
            case .not: return try parseUnary()
            case .field(let f):
                p += 1
                guard let v = peek() else { throw QueryError(message: "“\(f.rawValue):” needs a value", position: at) }
                let vat = pos()
                switch v {
                case .word(let w): p += 1; return .term(try Self.term(f, w, quoted: false, at: vat))
                case .quoted(let q): p += 1; return .term(try Self.term(f, q, quoted: true, at: vat))
                default: throw QueryError(message: "“\(f.rawValue):” needs a value", position: vat)
                }
            case .word(let w): p += 1; return .term(try Self.term(.any, w, quoted: false, at: at))
            case .quoted(let q): p += 1; return .term(QueryTerm(field: .any, value: .text(q, exact: false, pattern: false)))      // a phrase anywhere
            }
        }
        root = try parseOr()
        if p < tokens.count { throw QueryError(message: "Unexpected “)”", position: tokens[p].1) }
    }

    /// Builds one term, reading numbers, ranges, comparisons and units for numeric fields.
    static func term(_ f: QueryField, _ raw: String, quoted: Bool, at: Int) throws -> QueryTerm {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if f.isBoolean {
            switch v.lowercased() {
            case "yes", "true", "1", "y", "on", "": return QueryTerm(field: f, value: .flag(true))
            case "no", "false", "0", "n", "off": return QueryTerm(field: f, value: .flag(false))
            default: throw QueryError(message: "“\(f.rawValue):” takes yes or no", position: at)
            }
        }
        if f.isNumeric {
            guard let r = numericRange(f, v) else { throw QueryError(message: "“\(v)” is not a number or range for \(f.rawValue)", position: at) }
            return QueryTerm(field: f, value: .range(r.0, r.1))
        }
        guard !v.isEmpty else { throw QueryError(message: "“\(f.rawValue):” needs a value", position: at) }
        return QueryTerm(field: f, value: .text(v, exact: quoted, pattern: !quoted && (v.contains("*") || v.contains("?"))))
    }

    /// "1955..1965", "1955-1965" (years), ">=96k", "<3:30", "24", "..1970". Returns inclusive bounds (strict comparisons nudge by a hair).
    static func numericRange(_ f: QueryField, _ s: String) -> (Double?, Double?)? {
        func num(_ t: Substring) -> Double? {
            var x = t.trimmingCharacters(in: .whitespaces).lowercased()
            guard !x.isEmpty else { return nil }
            var scale = 1.0
            switch f {
            case .rate:
                if x.hasSuffix("khz") { x.removeLast(3); scale = 1000 } else if x.hasSuffix("hz") { x.removeLast(2) } else if x.hasSuffix("k") { x.removeLast(); scale = 1000 }
                if scale == 1, let d = Double(x), d < 1000 { return d * 1000 }          // "96" means 96 kHz
            case .duration:
                let parts = x.split(separator: ":")
                if parts.count == 2 || parts.count == 3, let secs = Double(parts.last!) {
                    let mins = Double(parts[parts.count - 2]) ?? 0, hours = parts.count == 3 ? Double(parts[0]) ?? 0 : 0
                    return hours * 3600 + mins * 60 + secs
                }
                if x.hasSuffix("min") { x.removeLast(3); scale = 60 } else if x.hasSuffix("m") { x.removeLast(); scale = 60 }
                else if x.hasSuffix("h") { x.removeLast(); scale = 3600 } else if x.hasSuffix("s") { x.removeLast() }
            case .bits: if x.hasSuffix("bit") { x.removeLast(3) } else if x.hasSuffix("b") { x.removeLast() }
            case .lufs: if x.hasSuffix("lufs") { x.removeLast(4) }
            default: break
            }
            return Double(x).map { $0 * scale }
        }
        let eps = f == .lufs || f == .duration ? 1e-6 : 0.5
        if s.hasPrefix(">=") { return num(s.dropFirst(2)).map { ($0, nil) } }
        if s.hasPrefix("<=") { return num(s.dropFirst(2)).map { (nil, $0) } }
        if s.hasPrefix(">") { return num(s.dropFirst()).map { ($0 + eps, nil) } }
        if s.hasPrefix("<") { return num(s.dropFirst()).map { (nil, $0 - eps) } }
        if s.hasPrefix("=") { return num(s.dropFirst()).map { ($0, $0) } }
        if let r = s.range(of: "..") {
            let lo = s[..<r.lowerBound], hi = s[r.upperBound...]
            let a = lo.isEmpty ? nil : num(lo), b = hi.isEmpty ? nil : num(hi)
            if (!lo.isEmpty && a == nil) || (!hi.isEmpty && b == nil) || (a == nil && b == nil) { return nil }
            return (a, b)
        }
        // 1955-1965 for years
        if f == .year, s.count == 9, s.dropFirst(4).first == "-", let a = Double(s.prefix(4)), let b = Double(s.suffix(4)) { return (a, b) }
        guard let x = num(Substring(s)) else { return nil }
        if f == .lufs || f == .duration {
            // a bare value is "about": the displayed precision
            let tol = f == .lufs ? 0.05 : 0.5
            return (x - tol, x + tol)
        }
        return (x, x)
    }

    // MARK: hierarchical tags

    /// "Classical/Beethoven/Symphonies", "Classical > Beethoven" → its levels.
    static func tagPath(_ s: String) -> [String] {
        s.replacingOccurrences(of: ">", with: "/").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The spellings a stored genre can have for a tag path (the separator is a slash, or ">", with or without spaces).
    static func tagSpellings(_ path: [String]) -> [String] {
        guard path.count > 1 else { return path }
        return [path.joined(separator: "/"), path.joined(separator: " > "), path.joined(separator: ">")]
    }

    // MARK: Core Data

    static let artistRoles = [CreditRole.artist.rawValue, CreditRole.featured.rawValue, CreditRole.albumArtist.rawValue]

    private static func roles(for f: QueryField) -> [String]? {
        switch f {
        case .artist: artistRoles
        case .albumArtist: [CreditRole.albumArtist.rawValue]
        case .composer: [CreditRole.composer.rawValue]
        case .conductor: [CreditRole.conductor.rawValue]
        case .ensemble: [CreditRole.ensemble.rawValue]
        case .performer: [CreditRole.soloist.rawValue, CreditRole.performer.rawValue]
        case .person: CreditRole.allCases.map(\.rawValue)
        default: nil
        }
    }

    /// The whole query as one predicate on the Track entity.
    var predicate: NSPredicate { Self.compile(root) }

    static func compile(_ n: QueryNode) -> NSPredicate {
        switch n {
        case .and(let a): return NSCompoundPredicate(andPredicateWithSubpredicates: a.map(compile))
        case .or(let a): return NSCompoundPredicate(orPredicateWithSubpredicates: a.map(compile))
        case .not(let x): return NSCompoundPredicate(notPredicateWithSubpredicate: compile(x))
        case .term(let t): return compile(t)
        }
    }

    /// Text comparison on a plain string attribute (case/diacritic-insensitive), guarded against nil so NOT behaves.
    private static func textPredicate(_ key: String, _ v: String, exact: Bool, pattern: Bool, folded: Bool) -> NSPredicate {
        let value = folded ? LibraryStore.fold(v) : v
        let mod = folded ? "" : "[cd]"
        let op = pattern ? "LIKE\(mod)" : (exact ? "==\(mod)" : "CONTAINS\(mod)")
        return NSPredicate(format: "\(key) != nil AND \(key) \(op) %@", value)
    }

    private static func rangePredicate(_ key: String, _ lo: Double?, _ hi: Double?) -> NSPredicate {
        var parts = [NSPredicate(format: "\(key) != nil")]
        if let lo { parts.append(NSPredicate(format: "\(key) >= %@", NSNumber(value: lo))) }
        if let hi { parts.append(NSPredicate(format: "\(key) <= %@", NSNumber(value: hi))) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    static func compile(_ t: QueryTerm) -> NSPredicate {
        switch (t.field, t.value) {
        case (.any, .text(let v, let exact, let pattern)):
            let f = LibraryStore.fold(v)
            let op = pattern ? "LIKE" : (exact ? "==" : "CONTAINS")
            let opcd = pattern ? "LIKE[cd]" : (exact ? "==[cd]" : "CONTAINS[cd]")
            return NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "title != nil AND title \(opcd) %@", v),
                NSPredicate(format: "SUBQUERY(credits, $c, $c.party.key \(op) %@).@count > 0", f),
                NSPredicate(format: "work != nil AND work.key \(op) %@", f),
                NSPredicate(format: "release != nil AND release.key \(op) %@", f),
                NSPredicate(format: "SUBQUERY(genres, $g, $g.name \(opcd) %@).@count > 0", v),
            ])
        case (.title, .text(let v, let e, let p)): return textPredicate("title", v, exact: e, pattern: p, folded: false)
        case (.album, .text(let v, let e, let p)): return NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "release != nil"), textPredicate("release.key", v, exact: e, pattern: p, folded: true)])
        case (.work, .text(let v, let e, let p)): return NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "work != nil"), textPredicate("work.key", v, exact: e, pattern: p, folded: true)])
        case (.catalog, .text(let v, let e, let p)): return NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "work != nil"), textPredicate("work.catalogNumber", v, exact: e, pattern: p, folded: false)])
        case (.codec, .text(let v, let e, let p)): return textPredicate("codec", v, exact: e, pattern: p, folded: false)
        case (.path, .text(let v, let e, let p)): return textPredicate("path", v, exact: e, pattern: p, folded: false)
        case (.genre, .text(let v, let e, let p)):
            let op = p ? "LIKE[cd]" : (e ? "==[cd]" : "CONTAINS[cd]")
            return NSPredicate(format: "SUBQUERY(genres, $g, $g.name \(op) %@).@count > 0", v)
        case (.tag, .text(let v, _, _)):
            // a level of the hierarchy and everything below it, whichever separator the tag was written with
            var conditions: [String] = [], args: [Any] = []
            for s in tagSpellings(tagPath(v)) {
                conditions += ["$g.name ==[cd] %@", "$g.name BEGINSWITH[cd] %@", "$g.name BEGINSWITH[cd] %@", "$g.name BEGINSWITH[cd] %@"]
                args += [s, s + "/", s + " >", s + ">"]
            }
            guard !conditions.isEmpty else { return NSPredicate(value: false) }
            return NSPredicate(format: "SUBQUERY(genres, $g, \(conditions.joined(separator: " OR "))).@count > 0", argumentArray: args)
        case (let f, .text(let v, let e, let p)) where roles(for: f) != nil:
            let op = p ? "LIKE" : (e ? "==" : "CONTAINS")
            return NSPredicate(format: "SUBQUERY(credits, $c, $c.role IN %@ AND $c.party.key \(op) %@).@count > 0", roles(for: f)!, LibraryStore.fold(v))
        case (.year, .range(let lo, let hi)): return rangePredicate("year", lo, hi)
        case (.rate, .range(let lo, let hi)): return rangePredicate("sampleRate", lo, hi)
        case (.bits, .range(let lo, let hi)): return rangePredicate("bitDepth", lo, hi)
        case (.channels, .range(let lo, let hi)): return rangePredicate("channels", lo, hi)
        case (.lufs, .range(let lo, let hi)): return rangePredicate("lufs", lo, hi)
        case (.dr, .range(let lo, let hi)): return rangePredicate("drScore", lo, hi)
        case (.duration, .range(let lo, let hi)): return rangePredicate("duration", lo, hi)
        case (.plays, .range(let lo, let hi)):
            // never played counts as 0
            if (lo ?? 0) <= 0 { return NSCompoundPredicate(orPredicateWithSubpredicates: [NSPredicate(format: "playCount == nil"), rangePredicate("playCount", lo, hi)]) }
            return rangePredicate("playCount", lo, hi)
        case (.liked, .flag(let b)): return b ? NSPredicate(format: "liked == YES") : NSPredicate(format: "liked == nil OR liked == NO")
        case (.hires, .flag(let b)):
            let hi = NSPredicate(format: "(sampleRate != nil AND sampleRate > 48000) OR (bitDepth != nil AND bitDepth > 16)")
            return b ? hi : NSCompoundPredicate(notPredicateWithSubpredicate: hi)
        default:
            return NSPredicate(value: false)
        }
    }

    // MARK: in memory

    /// The same query evaluated on one track: the reference for the SQL version, and used for tracks that are not in the library.
    func matches(_ t: TrackDTO) -> Bool { Self.eval(root, t) }

    static func eval(_ n: QueryNode, _ t: TrackDTO) -> Bool {
        switch n {
        case .and(let a): return a.allSatisfy { eval($0, t) }
        case .or(let a): return a.contains { eval($0, t) }
        case .not(let x): return !eval(x, t)
        case .term(let q): return eval(q, t)
        }
    }

    private static func wildcard(_ pattern: String, _ s: String) -> Bool {
        // * = any run, ? = one character; whole-string match like SQL LIKE
        let p = Array(LibraryStore.fold(pattern)), x = Array(LibraryStore.fold(s))
        var dp = [Bool](repeating: false, count: x.count + 1); dp[0] = true
        for pc in p {
            var next = [Bool](repeating: false, count: x.count + 1)
            if pc == "*" { var any = false; for j in 0...x.count { any = any || dp[j]; next[j] = any } }
            else { for j in 0..<x.count where dp[j] && (pc == "?" || pc == x[j]) { next[j + 1] = true } }
            dp = next
        }
        return dp[x.count]
    }

    private static func text(_ candidates: [String], _ v: String, exact: Bool, pattern: Bool) -> Bool {
        let f = LibraryStore.fold(v)
        return candidates.contains { c in
            if pattern { return wildcard(v, c) }
            let fc = LibraryStore.fold(c)
            return exact ? fc == f : fc.contains(f)
        }
    }

    private static func inRange(_ x: Double?, _ lo: Double?, _ hi: Double?) -> Bool {
        guard let x else { return false }
        return (lo.map { x >= $0 } ?? true) && (hi.map { x <= $0 } ?? true)
    }

    static func eval(_ q: QueryTerm, _ t: TrackDTO) -> Bool {
        func names(_ roles: [String]) -> [String] { t.credits.filter { roles.contains($0.role) }.map(\.name) }
        switch (q.field, q.value) {
        case (.any, .text(let v, let e, let p)):
            return text([t.title], v, exact: e, pattern: p) || text(t.credits.map(\.name), v, exact: e, pattern: p)
                || text([t.workTitle, t.releaseTitle].compactMap { $0 }, v, exact: e, pattern: p) || text(t.genres, v, exact: e, pattern: p)
        case (.title, .text(let v, let e, let p)): return text([t.title], v, exact: e, pattern: p)
        case (.album, .text(let v, let e, let p)): return text([t.releaseTitle].compactMap { $0 }, v, exact: e, pattern: p)
        case (.work, .text(let v, let e, let p)): return text([t.workTitle].compactMap { $0 }, v, exact: e, pattern: p)
        case (.catalog, .text(let v, let e, let p)): return text([t.catalog].compactMap { $0 }, v, exact: e, pattern: p)
        case (.codec, .text(let v, let e, let p)): return text([t.codec], v, exact: e, pattern: p)
        case (.path, .text(let v, let e, let p)): return text([t.path], v, exact: e, pattern: p)
        case (.genre, .text(let v, let e, let p)): return text(t.genres, v, exact: e, pattern: p)
        case (.tag, .text(let v, _, _)):
            let want = tagPath(v).map { LibraryStore.fold($0) }
            return t.genres.contains { g in
                let have = tagPath(g).map { LibraryStore.fold($0) }
                return have.count >= want.count && Array(have.prefix(want.count)) == want && !want.isEmpty
            }
        case (let f, .text(let v, let e, let p)) where roles(for: f) != nil: return text(names(roles(for: f)!), v, exact: e, pattern: p)
        case (.year, .range(let lo, let hi)): return inRange(t.year.map(Double.init), lo, hi)
        case (.rate, .range(let lo, let hi)): return inRange(t.sampleRate > 0 ? t.sampleRate : nil, lo, hi)
        case (.bits, .range(let lo, let hi)): return inRange(t.bitDepth > 0 ? Double(t.bitDepth) : nil, lo, hi)
        case (.channels, .range(let lo, let hi)): return inRange(t.channels > 0 ? Double(t.channels) : nil, lo, hi)
        case (.lufs, .range(let lo, let hi)): return inRange(t.lufs, lo, hi)
        case (.dr, .range(let lo, let hi)): return inRange(t.dr, lo, hi)
        case (.duration, .range(let lo, let hi)): return inRange(t.duration, lo, hi)
        case (.plays, .range(let lo, let hi)): return inRange(Double(t.playCount ?? 0), lo, hi)
        case (.liked, .flag(let b)): return t.isLiked == b
        case (.hires, .flag(let b)): return (t.sampleRate > 48_000 || t.bitDepth > 16) == b
        default: return false
        }
    }
}

// MARK: - Tag tree

/// Genres arranged by their levels ("Classical/Beethoven/Symphonies"), with track counts that include everything below a level.
struct TagTreeNode: Identifiable, Hashable, Sendable {
    var name: String
    /// Levels from the top: ["Classical", "Beethoven"].
    var path: [String]
    var count: Int
    var children: [TagTreeNode]
    var id: String { path.joined(separator: "/") }
    /// What to search for to see this level and everything under it.
    var query: String { "tag:\"\(path.joined(separator: "/"))\"" }
    /// nil for a leaf (so a List / OutlineGroup shows no disclosure triangle).
    var childrenOrNil: [TagTreeNode]? { children.isEmpty ? nil : children }

    static func build(_ genres: [(name: String, count: Int)]) -> [TagTreeNode] {
        final class Box { var name: String; var path: [String]; var count = 0; var kids: [String: Box] = [:]; var order: [String] = []; init(_ n: String, _ p: [String]) { name = n; path = p } }
        let root = Box("", [])
        for (g, c) in genres {
            let levels = LibraryQuery.tagPath(g)
            guard !levels.isEmpty else { continue }
            var node = root
            node.count += c
            for (i, l) in levels.enumerated() {
                let key = LibraryStore.fold(l)
                if node.kids[key] == nil { node.kids[key] = Box(l, Array(levels.prefix(i + 1))); node.order.append(key) }
                node = node.kids[key]!
                node.count += c
            }
        }
        func freeze(_ b: Box) -> [TagTreeNode] {
            b.order.compactMap { b.kids[$0] }.map { TagTreeNode(name: $0.name, path: $0.path, count: $0.count, children: freeze($0)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return freeze(root)
    }
}
