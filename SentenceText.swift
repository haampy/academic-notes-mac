import Foundation

enum SentenceText {
    private static let endings = Set("。！？.!?…")
    private static let closingMarks = Set("”’」』】）》〉〕〗)]}\"'»")
    private static let straightQuotes = Set("\"'")
    private static let prefixes: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "fig", "figs", "eq", "eqs", "sec", "secs",
        "ref", "refs", "ch", "vol", "no", "nos", "vs", "cf", "e.g", "i.e", "approx"
    ]
    private static let domainSuffixes: Set<String> = ["com", "org", "net", "edu", "gov", "io", "ai", "cn", "tw", "uk"]

    // These can finish a sentence, as in “We tested it in the U.S. It worked.”
    private static let possibleStarts: Set<String> = [
        "a", "an", "the", "i", "we", "they", "he", "she", "it", "this", "that", "these",
        "those", "next", "then", "however", "finally", "our", "their", "in"
    ]

    private static func usesWordSpaces(_ char: Character) -> Bool {
        char.isCased || (char.isASCII && char.isNumber)
    }

    private static func hasOpenQuote(_ quote: Character, in text: String) -> Bool {
        var open = false
        for index in text.indices where text[index] == quote {
            if quote == "'", index > text.startIndex && text[text.index(before: index)].isLetter {
                let next = text.index(after: index)
                if next < text.endIndex && text[next].isLetter { continue }
                if !open { continue } // plural possessive
            }
            open.toggle()
        }
        return open
    }

    private static func needsSpace(after left: String, before right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if straightQuotes.contains(last) && hasOpenQuote(last, in: left) { return false }
        guard usesWordSpaces(last) || ".,;:!?%)]}\"'”".contains(last) else { return false }
        if straightQuotes.contains(first) {
            if hasOpenQuote(first, in: left) { return false }
            let suffix = right.dropFirst()
            if first == "'" && ["s", "t", "m", "d", "ll", "re", "ve"].contains(suffix.prefix(while: \.isLetter).lowercased()) {
                return false
            }
            if let next = suffix.first {
                return !next.isWhitespace && !closingMarks.contains(next) &&
                    !endings.contains(next) && !",;:，；：".contains(next)
            }
            return !".!?".contains(last)
        }
        guard usesWordSpaces(first) || "([{“".contains(first) else { return false }
        if last == "." && first.isNumber && left.dropLast().last?.isNumber == true { return false }
        if last == "." && first.isASCII && first.isLetter && right.dropFirst().first == "." { return false }
        return true
    }

    // ASR strips whitespace at chunk edges. Restore the space between English words,
    // while keeping Chinese text, contractions, hyphenated words and decimals together.
    static func joining(_ left: String, _ right: String) -> String {
        var joined = ""
        for text in [left, right] {
            for line in text.split(whereSeparator: \.isNewline) {
                let part = line.trimmingCharacters(in: .whitespaces)
                guard !part.isEmpty else { continue }
                if needsSpace(after: joined, before: part) { joined.append(" ") }
                joined += part
            }
        }
        return joined
    }

    private static func endsAtPeriod(_ chars: [Character], at index: Int) -> Bool {
        let next = index + 1
        guard next < chars.count else { return true }
        let following = chars[next]
        if following.isASCII && following.isNumber { return false } // decimal or version
        let preceding = chars[..<index].reversed().prefix { ($0.isASCII && $0.isLetter) || $0 == "." }
        let token = String(preceding.reversed()).lowercased()
        if following.isASCII && following.isLetter, index > 0 && usesWordSpaces(chars[index - 1]) {
            let label = chars[next...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            let anotherDot = label.endIndex < chars.count && chars[label.endIndex] == "."
            let initial = label.count == 1 && anotherDot && (token.count == 1 || token == "ph" || token.contains("."))
            let domain = token == "www" || domainSuffixes.contains(String(label).lowercased())
            if following.isLowercase || initial || domain { return false }
        }
        if prefixes.contains(token) { return false }
        let initials = token.split(separator: ".")
        let abbreviated = initials.allSatisfy { $0.count == 1 } &&
            (initials.count > 1 || (initials.count == 1 && chars[index - 1].isUppercase))
        guard abbreviated || ["al", "etc", "inc", "jr", "sr", "ph.d"].contains(token) else { return true }
        let remainder = chars[next...].drop(while: { $0.isWhitespace || closingMarks.contains($0) })
        guard let first = remainder.first, first.isUppercase else { return false }
        let word = String(remainder.prefix(while: \.isLetter)).lowercased()
        return possibleStarts.contains(word)
    }

    static func paragraphs(in text: String) -> [String] {
        let chars = Array(joining("", text))
        var sentences: [String] = []
        var openQuotes: Set<Character> = []
        var start = 0, index = 0
        while index < chars.count {
            let mark = chars[index]
            guard endings.contains(mark) else {
                let apostrophe = mark == "'" && index > 0 && index + 1 < chars.count &&
                    chars[index - 1].isLetter && chars[index + 1].isLetter
                if straightQuotes.contains(mark) && !apostrophe && openQuotes.remove(mark) == nil {
                    openQuotes.insert(mark)
                }
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count && endings.contains(chars[end]) { end += 1 }
            let punctuation = chars[index..<end]
            if mark == "." && punctuation.count == 1 && !endsAtPeriod(chars, at: index) {
                index = end
                continue
            }
            while end < chars.count && closingMarks.contains(chars[end]) {
                let closer = chars[end]
                if straightQuotes.contains(closer) && openQuotes.remove(closer) == nil,
                   end + 1 < chars.count && chars[end + 1].isLetter { break }
                end += 1
            }
            let next = chars[end...].first(where: { !$0.isWhitespace })
            let closed = end > punctuation.endIndex
            let ellipsis = (mark == "…" || punctuation.count > 1) && punctuation.allSatisfy { $0 == "." || $0 == "…" }
            // A quote or an aside can end inside the containing sentence.
            if let next {
                let hesitation = ellipsis && !closed && next.unicodeScalars.first?.properties.isIdeographic == true
                if hesitation || (closed && ",:;，、：；".contains(next)) || ((closed || ellipsis) && next.isLowercase) {
                    index = end
                    continue
                }
            }
            sentences.append(String(chars[start..<end]).trimmingCharacters(in: .whitespaces))
            start = end
            index = end
        }
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
