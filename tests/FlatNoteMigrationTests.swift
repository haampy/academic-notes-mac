import Foundation

@main
struct FlatNoteMigrationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("2025")
        let second = root.appendingPathComponent("2026")
        for folder in [first, second] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let title = "11月23日，笔记1"
        let id2026 = title + "（2026）"
        let receiptName = "." + title + ".txt.json"
        let receipt = Data(#"{"folder":"example","link":"https://example.invalid/a"}"#.utf8)
        try Data("first".utf8).write(to: first.appendingPathComponent(title + ".txt"))
        try receipt.write(to: first.appendingPathComponent(receiptName))
        try Data("7".utf8).write(to: first.appendingPathComponent(".11月23日.sequence"))
        try Data("# 课堂\n\nsecond".utf8).write(to: second.appendingPathComponent("课堂 — " + title + ".txt"))
        let pending = Data(#"{"folder":"","stagingTitle":"private-session"}"#.utf8)
        try pending.write(to: second.appendingPathComponent(receiptName))
        let orphan = ".11月23日，笔记3.txt.json"
        try pending.write(to: second.appendingPathComponent(orphan))
        try Data("other".utf8).write(to: second.appendingPathComponent("个人资料.txt"))
        let link = second.appendingPathComponent("11月24日，笔记1.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: second.appendingPathComponent("个人资料.txt"))
        let index = try FlatNoteStore.prepare(in: root)
        precondition(index.counters["2025-11月23日"] == 7 && index.counters["2026-11月23日"] == 3)
        precondition(!fm.fileExists(atPath: first.path))
        let remaining = try fm.contentsOfDirectory(atPath: second.path)
        precondition(Set(remaining) == ["个人资料.txt", link.lastPathComponent])
        try check("first", at: root.appendingPathComponent(title + ".txt"))
        try check("# 课堂\n\nsecond", at: root.appendingPathComponent("课堂 — " + id2026 + ".txt"))
        for (name, expected) in [(receiptName, receipt), ("." + id2026 + ".txt.json", pending), (orphan, pending)] {
            let actual = try Data(contentsOf: root.appendingPathComponent(name))
            precondition(actual == expected)
        }

        // A renamed root note and an orphaned root receipt both reserve their storage IDs.
        let retry = root.appendingPathComponent("retry")
        let year = retry.appendingPathComponent("2027")
        try fm.createDirectory(at: year, withIntermediateDirectories: true)
        var reservation = FlatNoteStore.Index()
        _ = try reservation.storageID(for: title, year: 2027, in: retry)
        try reservation.save(in: retry)
        let target = retry.appendingPathComponent("已有笔记 — " + title + ".txt")
        let source = year.appendingPathComponent(title + ".txt")
        try Data("original".utf8).write(to: source)
        try Data("collision".utf8).write(to: target)
        let occupied = retry.appendingPathComponent("." + title + "（2027）.txt.json")
        try pending.write(to: occupied)
        try receipt.write(to: year.appendingPathComponent(receiptName))
        let migrated = try FlatNoteStore.prepare(in: retry)
        let disambiguated = title + "（2027-2）"
        precondition(migrated.migrationID(for: title, year: 2027) == disambiguated)
        try check("original", at: retry.appendingPathComponent(disambiguated + ".txt"))
        let migratedReceipt = try Data(contentsOf: retry.appendingPathComponent("." + disambiguated + ".txt.json"))
        precondition(migratedReceipt == receipt)
        try check("collision", at: target)
        let stillOccupied = try Data(contentsOf: occupied)
        precondition(stillOccupied == pending && !fm.fileExists(atPath: retry.appendingPathComponent(receiptName).path))
        _ = try FlatNoteStore.prepare(in: retry)
        precondition(!fm.fileExists(atPath: year.path))

        // Simulate interruption after linking the receipt, both with and without a note
        // appearing at the reserved target before the next launch.
        for conflict in [false, true] {
            try resumePublishedReceipt(in: root.appendingPathComponent("resume-\(conflict)"), conflict: conflict)
        }
        print("Flat note migration tests passed")
    }

    static func resumePublishedReceipt(in root: URL, conflict: Bool) throws {
        let fm = FileManager.default
        let year = root.appendingPathComponent("2027")
        try fm.createDirectory(at: year, withIntermediateDirectories: true)
        let title = "1月1日，笔记1"
        var index = FlatNoteStore.Index()
        let planned = try index.storageID(for: title, year: 2027, in: root)
        index.recordMigration(planned, for: title, year: 2027)
        try index.save(in: root)
        let source = year.appendingPathComponent(title + ".txt")
        let target = root.appendingPathComponent(planned + ".txt")
        let name = "." + title + ".txt.json"
        let sourceReceipt = year.appendingPathComponent(name)
        let targetReceipt = root.appendingPathComponent(name)
        try Data("migration".utf8).write(to: source)
        try Data("receipt".utf8).write(to: sourceReceipt)
        try fm.linkItem(at: sourceReceipt, to: targetReceipt)
        if conflict { try Data("external".utf8).write(to: target) }
        let finished = try FlatNoteStore.prepare(in: root)
        guard let actual = finished.migrationID(for: title, year: 2027) else { preconditionFailure("Missing migration identity") }
        precondition(conflict == (actual != planned))
        try check("migration", at: root.appendingPathComponent(actual + ".txt"))
        try check("receipt", at: root.appendingPathComponent("." + actual + ".txt.json"))
        if conflict {
            try check("external", at: target)
            precondition(!fm.fileExists(atPath: targetReceipt.path))
        }
    }
    static func check(_ expected: String, at url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        precondition(text == expected)
    }
}
