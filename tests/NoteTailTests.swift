import Darwin
import Foundation

@main
struct NoteTailTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try testDisplayTitle(in: folder)
        try testDailyTitles(in: folder)
        let note = folder.appendingPathComponent("note.txt")
        let prefix = "[00:01] 已经说完。\n"
        let tail = "[00:04] 山上的咖啡\n"
        try Data().write(to: note)
        try Notes.replaceTail("", with: prefix, in: note)
        try Notes.replaceTail("", with: tail, in: note)
        try expect(note, prefix + tail)

        // Renaming a note inserts a title above the existing transcript.
        let header = "# 山间记录 ☕️\n\n"
        try (header + prefix + tail).write(to: note, atomically: true, encoding: .utf8)
        let sentences = "[00:04] 山上的咖啡很香。\n[00:08] Really?\n"
        let marker = "[00:09] ★ 重点\n"
        try Notes.replaceTail(tail, with: sentences + marker, in: note)
        try expect(note, header + prefix + sentences + marker)

        let next = "[00:12] 一句话\n"
        do {
            try Notes.replaceTail(sentences, with: next, in: note)
            preconditionFailure("Stale tail accepted")
        } catch {}
        try expect(note, header + prefix + sentences + marker)

        let beforeAppend = header + prefix + sentences + marker
        limitedWrite(maximumBytes: beforeAppend.utf8.count + 4) {
            try Notes.replaceTail("", with: next, in: note)
        }
        try expect(note, beforeAppend)
        try Notes.replaceTail("", with: next, in: note)
        let complete = "[00:12] 一句话仍然只有一个段落。\n"
        limitedWrite(maximumBytes: (beforeAppend + next).utf8.count + 4) {
            try Notes.replaceTail(next, with: complete, in: note)
        }
        try expect(note, beforeAppend + next)
        try Notes.replaceTail(next, with: complete, in: note)
        try expect(note, beforeAppend + complete)
        print("Note tail tests passed")
    }

    static func expect(_ url: URL, _ expected: String) throws {
        let data = try Data(contentsOf: url)
        precondition(data.elementsEqual(expected.utf8), "Unexpected note content")
    }

    static func testDisplayTitle(in folder: URL) throws {
        let id = "学术笔记 2024-02-09 17.41.30 A2345F"
        let file = folder.appendingPathComponent(id + ".txt")
        try Data("[00:01] 一句话。\n".utf8).write(to: file)
        let title = try Notes.title(for: file)
        precondition(title == id)
        precondition(Notes.displayTitle(title, for: file) == "2 月 9 日的笔记")

        let chosen = "学术笔记 2026-11-23 17.41.30 354405"
        let renamed = try Notes.rename(chosen, for: file)
        precondition(renamed.deletingLastPathComponent().path == folder.path)
        let custom = try Notes.title(for: renamed)
        precondition(Notes.displayTitle(custom, for: renamed) == chosen)
        try expect(renamed, "# \(chosen)\n\n[00:01] 一句话。\n")

        for other in ["旧笔记", "学术笔记 2026-02-30 17.41.30 354405"] {
            let old = folder.appendingPathComponent(other + ".txt")
            precondition(Notes.displayTitle(other, for: old) == other)
        }
    }

    static func testDailyTitles(in folder: URL) throws {
        let calendar = Calendar(identifier: .gregorian)
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 2, day: 9, hour: 23, minute: 59))!
        let afterMidnight = beforeMidnight.addingTimeInterval(120)
        let first = try Notes.start(in: folder, at: beforeMidnight)
        let firstTitle = try Notes.title(for: first)
        precondition(firstTitle == "2月9日，笔记1" && first.lastPathComponent == firstTitle + ".txt")
        precondition(first.deletingLastPathComponent().path == folder.path)
        try Notes.replaceTail("", with: "[00:03] 第一句。\n", in: first)
        let renamed = try Notes.rename("自定义标题", for: first)
        precondition(renamed.lastPathComponent == "自定义标题 — 2月9日，笔记1.txt")
        let second = try Notes.start(in: folder, at: beforeMidnight)
        let secondTitle = try Notes.title(for: second)
        precondition(secondTitle == "2月9日，笔记2")
        Notes.finish(second)
        precondition(!FileManager.default.fileExists(atPath: second.path))
        let restored = try Notes.rename("", for: renamed)
        precondition(restored == first)
        try expect(restored, "[00:03] 第一句。\n")

        let newDay = try Notes.start(in: folder, at: afterMidnight)
        let newDayTitle = try Notes.title(for: newDay)
        precondition(newDayTitle == "2月10日，笔记1")
        let previousDay = try Notes.start(in: folder, at: beforeMidnight)
        let previousDayTitle = try Notes.title(for: previousDay)
        precondition(previousDayTitle == "2月9日，笔记3")

        let nextYear = calendar.date(byAdding: .year, value: 1, to: beforeMidnight)!
        let crossYear = try Notes.start(in: folder, at: nextYear)
        precondition(crossYear.deletingLastPathComponent().path == folder.path)
        precondition(crossYear.lastPathComponent == "2月9日，笔记1（2027）.txt")
        let crossYearTitle = try Notes.title(for: crossYear)
        precondition(crossYearTitle == firstTitle)
        let custom = try Notes.rename("另一年的笔记", for: crossYear)
        let reset = try Notes.rename("", for: custom)
        precondition(reset == crossYear)
        try expect(first, "[00:03] 第一句。\n")
        for year in ["2026", "2027"] {
            precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(year).path))
        }

        // A restored folder may contain notes and receipts without its hidden index.
        let indexFile = folder.appendingPathComponent(".purrk-index.json")
        try FileManager.default.removeItem(at: indexFile)
        try Data().write(to: folder.appendingPathComponent(".2月9日，笔记7（2026）.txt.json"))
        let fromReceipt = try Notes.start(in: folder, at: beforeMidnight)
        precondition(fromReceipt.lastPathComponent == "2月9日，笔记8.txt")
        let later = try Notes.rename("另一篇", for: fromReceipt)
        try FileManager.default.setAttributes([.creationDate: beforeMidnight], ofItemAtPath: later.path)
        try FileManager.default.removeItem(at: indexFile)
        let fromRenamed = try Notes.start(in: folder, at: beforeMidnight)
        precondition(fromRenamed.lastPathComponent == "2月9日，笔记9.txt")
    }

    // Exercise actual filesystem errors in this process, allowing only a partial write.
    static func limitedWrite(maximumBytes: Int, _ action: () throws -> Void) {
        var previous = rlimit()
        precondition(getrlimit(RLIMIT_FSIZE, &previous) == 0)
        let handler = signal(SIGXFSZ, SIG_IGN)
        var limit = rlimit(rlim_cur: rlim_t(maximumBytes), rlim_max: previous.rlim_max)
        precondition(setrlimit(RLIMIT_FSIZE, &limit) == 0)
        defer {
            precondition(setrlimit(RLIMIT_FSIZE, &previous) == 0)
            signal(SIGXFSZ, handler)
        }
        do {
            try action()
            preconditionFailure("Write unexpectedly succeeded")
        } catch {}
    }
}
