import Foundation

struct TranscriptLine: Equatable {
    let seconds: Int
    let text: String

    var time: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    var noteLine: String { "[\(time)] \(text)\n" }
}

// Only the last sentence can grow. Bookmarks made during it keep their own time and line.
struct TranscriptTail {
    private var sentence: TranscriptLine?
    private var bookmarks: [TranscriptLine] = []
    private var atWindowLimit = false

    var lines: [TranscriptLine] { sentence.map { [$0] + bookmarks } ?? [] }

    mutating func accept(_ text: String, at seconds: Int, continues: Bool = false) -> [TranscriptLine] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var prefix = sentence?.text ?? ""
        var joined = SentenceText.joining(prefix, text)
        // A bounded decode can supply a full stop after an unfinished phrase. Only
        // revise it when the next fragment or the dangling word supports a continuation.
        if atWindowLimit, prefix.last == "。" || prefix.last == ".",
           !prefix.hasSuffix(".."), Self.looksUnfinished(prefix, before: text),
           SentenceText.paragraphs(in: joined).first == prefix {
            prefix.removeLast()
            joined = SentenceText.joining(prefix, text)
        }
        let parts = SentenceText.paragraphs(in: joined)
        guard let last = parts.last else { return [] }
        let firstTime = sentence?.seconds ?? seconds
        var closed: [TranscriptLine] = []
        for (index, part) in parts.dropLast().enumerated() {
            closed.append(TranscriptLine(seconds: index == 0 ? firstTime : seconds, text: part))
            if index == 0 {
                closed += bookmarks
                bookmarks.removeAll()
            }
        }
        sentence = TranscriptLine(seconds: parts.count == 1 ? firstTime : seconds, text: last)
        atWindowLimit = continues
        return closed
    }

    private static func looksUnfinished(_ prefix: String, before text: String) -> Bool {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = next.first else { return false }
        if first.isLowercase || "，、；：,;:".contains(first) { return true }
        let phrase = prefix.dropLast()
        if prefix.last == "." {
            let word = phrase.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
            return ["a", "an", "the", "to", "of", "with", "and", "because"].contains(word)
        }
        return ["因为", "关于", "对于", "以及", "通过", "取决于", "分成", "的是", "把"].contains(where: phrase.hasSuffix)
    }

    mutating func pause(forUnpunctuatedSpeech: Bool) -> [TranscriptLine] {
        atWindowLimit = false
        return forUnpunctuatedSpeech ? finish() : []
    }

    mutating func mark(at seconds: Int) -> [TranscriptLine] {
        let mark = TranscriptLine(seconds: seconds, text: "★ 重点")
        guard sentence != nil else { return [mark] }
        bookmarks.append(mark)
        return []
    }

    mutating func finish() -> [TranscriptLine] {
        let closed = lines
        self = TranscriptTail()
        return closed
    }
}
