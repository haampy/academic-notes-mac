import Foundation

@main
struct TranscriptTailTests {
    static func main() {
        var tail = TranscriptTail()
        precondition(tail.accept("根据这次实验，", at: 4).isEmpty)
        precondition(tail.mark(at: 6).isEmpty)

        // A live hypothesis can be revised or withdrawn without duplicating confirmed words.
        var preview = tail
        _ = preview.accept("可能有偏差", at: 8)
        precondition(preview.lines.first?.text == "根据这次实验，可能有偏差")
        precondition(tail.lines.first?.text == "根据这次实验，")
        let closed = tail.accept("我们发现了差异。还要继续吗？需要。", at: 10)
        precondition((closed + tail.lines).map(\.noteLine) == [
            "[00:04] 根据这次实验，我们发现了差异。\n", "[00:06] ★ 重点\n",
            "[00:10] 还要继续吗？\n", "[00:10] 需要。\n"
        ])
        precondition(tail.finish().count == 1 && tail.finish().isEmpty)

        let windows: [(String, String, [String])] = [
            ("We used Dr.", "Chen's estimate of 3.14.", ["We used Dr. Chen's estimate of 3.14."]),
            ("We used a.", "smaller sample.", ["We used a smaller sample."]),
            ("结果取决于。", "第二组的反应。", ["结果取决于第二组的反应。"]),
            ("The first trial worked.", "The second trial failed.", ["The first trial worked.", "The second trial failed."]),
            ("第一组有效。", "第二组无效。", ["第一组有效。", "第二组无效。"])
        ]
        for (first, second, expected) in windows {
            _ = tail.accept(first, at: 1, continues: true)
            let rows = tail.accept(second, at: 2) + tail.finish()
            precondition(rows.map(\.text) == expected, "\(first) + \(second) → \(rows.map(\.text))")
        }

        _ = tail.accept("如果样本量足够，", at: 5, continues: true)
        precondition(tail.pause(forUnpunctuatedSpeech: false).isEmpty)
        _ = tail.accept("就继续实验", at: 8)
        precondition(tail.finish() == [TranscriptLine(seconds: 5, text: "如果样本量足够，就继续实验")])

        _ = tail.accept("先看", at: 1, continues: true)
        _ = tail.accept("第一组", at: 3)
        precondition(tail.pause(forUnpunctuatedSpeech: true).map(\.text) == ["先看第一组"])
        _ = tail.accept("接下来", at: 6)
        precondition(tail.finish().map(\.text) == ["接下来"])
    }
}
