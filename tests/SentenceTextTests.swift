import Foundation

@main
struct SentenceTextTests {
    static func main() {
        let examples: [(String, [String])] = [
            ("  \n  ", []),
            ("第一句，虽然有停顿，但还在继续。第二句呢？第三句没说完",
             ["第一句，虽然有停顿，但还在继续。", "第二句呢？", "第三句没说完"]),
            ("他说：“可以吗？！”大家点头。", ["他说：“可以吗？！”", "大家点头。"]),
            ("结束了！“下一步呢？”", ["结束了！", "“下一步呢？”"]),
            ("他问“可以吗？”，接着看向大家。好。", ["他问“可以吗？”，接着看向大家。", "好。"]),
            ("“Are you sure?” she asked. I nodded.", ["“Are you sure?” she asked.", "I nodded."]),
            ("We tried it (really!), and it worked.", ["We tried it (really!), and it worked."]),
            ("模型……可能需要调整。再试一次。", ["模型……可能需要调整。", "再试一次。"]),
            ("\"Really?\"\"Yes.\"", ["\"Really?\"", "\"Yes.\""]),
            ("Alright.\"Let's go!\" Next.", ["Alright.", "\"Let's go!\"", "Next."]),
            ("He said, 'Really?' she recalled. Then she left.", ["He said, 'Really?' she recalled.", "Then she left."]),
            ("Dr. Wu cites Fig. 2, e.g. the mean of 3.14. We agree.",
             ["Dr. Wu cites Fig. 2, e.g. the mean of 3.14.", "We agree."]),
            ("It worked.Next trial? Yes.That helped.", ["It worked.", "Next trial?", "Yes.", "That helped."]),
            ("A Ph.D. student visits www.Example.COM, e.g. for papers.Next step.",
             ["A Ph.D. student visits www.Example.COM, e.g. for papers.", "Next step."]),
            ("See www.Example.ORG.Next trial?", ["See www.Example.ORG.", "Next trial?"]),
            ("J. R. Lee tested example.org in the U.S. It worked.",
             ["J. R. Lee tested example.org in the U.S.", "It worked."]),
            ("研究者使用v2.1，再比较 A.I. models。Next? Yes!",
             ["研究者使用v2.1，再比较 A.I. models。", "Next?", "Yes!"]),
            ("It was... almost ready. “Really?!” Yes.", ["It was... almost ready.", "“Really?!”", "Yes."]),
            ("好。\n 我们明天再\n 看。", ["好。", "我们明天再看。"])
        ]
        for (input, expected) in examples {
            let actual = SentenceText.paragraphs(in: input)
            precondition(actual == expected, "\(input) → \(actual), expected \(expected)")
        }

        let joins = [
            ("  第一个片段，\n", "接着讲。", "第一个片段，接着讲。"),
            (" This is ", " one sentence. ", "This is one sentence."),
            ("This includes", "Dr. Lee.", "This includes Dr. Lee."),
            ("The value is 3.", "14", "The value is 3.14"),
            ("a state-", "of-the-art model", "a state-of-the-art model"),
            ("We don", "'t know.", "We don't know."),
            ("He asked,", "\"Are you sure?\"", "He asked, \"Are you sure?\""),
            ("He asked, \"", "Are you sure?\"", "He asked, \"Are you sure?\""),
            ("\"Are you sure?", "\" she asked.", "\"Are you sure?\" she asked."),
            ("\"Are you sure?", "\"Next.", "\"Are you sure?\"Next."),
            ("\"Sure?\"", "\"Yes.\"", "\"Sure?\" \"Yes.\""),
            ("He asked,", "'Really?'", "He asked, 'Really?'"),
            ("使用GPU", "加速", "使用GPU加速"),
            ("结果", "。下一句。", "结果。下一句。"),
            ("", "two\nwrapped\nlines", "two wrapped lines")
        ]
        for (left, right, expected) in joins {
            let actual = SentenceText.joining(left, right)
            precondition(actual == expected, "\(left) + \(right) → \(actual), expected \(expected)")
        }
    }
}
