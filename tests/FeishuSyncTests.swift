import Foundation

@main
struct FeishuSyncTests {
    static let rootList = ["drive", "files", "list"]
    static let createFolder = ["drive", "+create-folder", "--name", "Purrk"]
    static let link = "https://example.invalid/docx/sample"

    static func create(in folder: String) -> [String] {
        ["docs", "+create", "--content", "-", "--parent-token", folder]
    }

    static func rename(_ id: String) -> [String] {
        ["drive", "files", "patch", "--file-token", id, "--type", "docx", "--data", "-"]
    }

    // Each scripted response is consumed exactly once. A nil response models a lost reply.
    struct Step {
        let command: [String]
        let response: [String: Any]?
        init(_ command: [String], _ response: [String: Any]? = [:]) {
            self.command = command
            self.response = response
        }
    }

    @discardableResult
    static func sync(_ directory: URL, customFolder: String = "", excluding: URL? = nil,
                     expectFailure: Bool = false, _ steps: [Step]) async -> URL? {
        var remaining = steps[...]
        let uploader = Notes.Feishu { command, input in
            guard let step = remaining.popFirst() else { preconditionFailure("Unexpected \(command)") }
            precondition(command == step.command, "Expected \(step.command), got \(command)")
            if command.starts(with: ["docs", "+create"]) {
                let xml = String(decoding: input!, as: UTF8.self)
                precondition(xml.hasPrefix("<title>") && xml.contains("<p>[00:01] 你好。</p>"))
            }
            if command.starts(with: ["drive", "files", "patch"]) {
                let data = try JSONDecoder().decode([String: String].self, from: input!)
                precondition(data["new_title"] == "11月23日，笔记1")
            }
            guard let result = step.response else { throw CocoaError(.fileWriteUnknown) }
            return result
        }
        let (last, failed) = await uploader.sync(in: directory, folderToken: customFolder, excluding: excluding)
        precondition(failed == expectFailure && remaining.isEmpty)
        return last
    }

    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func note(_ subfolder: String) throws -> URL {
            let directory = base.appendingPathComponent(subfolder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "# 11月23日，笔记1\n\n[00:01] 你好。\n".write(to: directory.appendingPathComponent("session.txt"),
                                                           atomically: true, encoding: .utf8)
            return directory
        }

        let noFiles: [String: Any] = ["files": [], "has_more": false]
        let folderFiles = ["files": [["type": "docx", "name": "Purrk", "token": "unrelated"],
                                     ["type": "folder", "name": "Purrk", "token": "purrk"]]]
        let document = ["document": ["document_id": "doc", "url": link]]
        let new = try note("new")
        await sync(new, excluding: new.appendingPathComponent("session.txt"), [])
        await sync(new, [Step(rootList, noFiles), Step(createFolder, ["folder_token": "created"]),
                         Step(create(in: "created"), document), Step(rename("doc"))])
        await sync(new, []) // Already synced.

        let custom = try note("custom")
        await sync(custom, customFolder: "  designated  ",
                   [Step(create(in: "designated"), document), Step(rename("doc"))])

        let retry = try note("retry")
        await sync(retry, expectFailure: true, [Step(rootList, noFiles), Step(createFolder, nil)])
        await sync(retry, expectFailure: true, [Step(rootList, folderFiles), Step(create(in: "purrk"), nil)])
        let marker = retry.appendingPathComponent(".session.txt.json")
        let receipt = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: marker))
        let staged = ["files": [["type": "docx", "name": receipt["stagingTitle"]!, "token": "doc", "url": link]]]
        let listing = rootList + ["--folder-token", "purrk"]
        await sync(retry, customFolder: "changed",
                   [Step(listing, ["files": [], "has_more": true, "next_page_token": "next"]),
                    Step(listing + ["--page-token", "next"], staged), Step(rename("doc"))])

        let previous = try note("legacy")
        let oldReceipt = ["folder": "", "stagingTitle": "Purrk-old-stage"]
        let oldMarker = previous.appendingPathComponent(".session.txt.json")
        try JSONEncoder().encode(oldReceipt).write(to: oldMarker)
        let oldDoc = ["files": [["type": "docx", "name": "Purrk-old-stage", "token": "old", "url": link]]]
        await sync(previous, [Step(rootList, oldDoc), Step(rename("old"))])

        // If the old root attempt never created a document, the replacement goes to Purrk.
        try JSONEncoder().encode(oldReceipt).write(to: oldMarker)
        await sync(previous, [Step(rootList, noFiles), Step(rootList, folderFiles),
                              Step(create(in: "purrk"), document), Step(rename("doc"))])
        try await checkFlatNotes(in: base.appendingPathComponent("notes"))
        print("Feishu sync tests passed")
    }

    static func checkFlatNotes(in root: URL) async throws {
        let fm = FileManager.default
        let title = "11月23日，笔记1"
        let text = Data("[00:01] 你好。\n".utf8)

        func completed(_ id: String, in folder: URL, link: String) throws {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent(id + ".txt"))
            let marker = folder.appendingPathComponent("." + id + ".txt.json")
            try JSONEncoder().encode(["folder": "", "link": link]).write(to: marker)
        }

        // One flat note is finished. An unfinished year-folder upload shares its displayed title.
        let calendar = Calendar(identifier: .gregorian)
        let before = calendar.date(from: DateComponents(year: 2025, month: 11, day: 23, hour: 12))!
        let older = try Notes.start(in: root, at: before)
        precondition(older.deletingLastPathComponent().path == root.path)
        precondition(older.lastPathComponent == title + ".txt")
        try Notes.replaceTail("", with: String(decoding: text, as: UTF8.self), in: older)
        Notes.finish(older)
        let document = ["document": ["document_id": "old", "url": link]]
        await sync(root, customFolder: "designated", [Step(create(in: "designated"), document), Step(rename("old"))])

        let year = root.appendingPathComponent("2026")
        try fm.createDirectory(at: year, withIntermediateDirectories: true)
        let previous = year.appendingPathComponent(title + ".txt")
        try text.write(to: previous)
        let receipt = ["folder": "purrk", "stagingTitle": "Purrk-pending"]
        try JSONEncoder().encode(receipt).write(to: year.appendingPathComponent("." + title + ".txt.json"))
        let unrelated = year.appendingPathComponent("unrelated.txt")
        try Data("other file".utf8).write(to: unrelated)

        let legacyLink = "https://example.invalid/docx/legacy"
        try completed("学术笔记 2026-11-23 17.41.30 354405", in: root, link: legacyLink)
        let excludingOldPath = await sync(root, excluding: previous, [])
        precondition(excludingOldPath?.absoluteString == legacyLink)
        precondition(fm.fileExists(atPath: unrelated.path))
        precondition(!fm.fileExists(atPath: previous.path))
        let migratedID = title + "（2026）"
        precondition(fm.fileExists(atPath: root.appendingPathComponent(migratedID + ".txt").path))
        let migratedReceipt = root.appendingPathComponent("." + migratedID + ".txt.json")
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: migratedReceipt))
        precondition(saved == receipt)

        let recoveredLink = "https://example.invalid/docx/recovered"
        let staged = ["files": [["type": "docx", "name": "Purrk-pending", "token": "recovered", "url": recoveredLink]]]
        let recovered = await sync(root, [Step(rootList + ["--folder-token", "purrk"], staged), Step(rename("recovered"))])
        precondition(recovered?.absoluteString == recoveredLink)

        let after = calendar.date(from: DateComponents(year: 2027, month: 11, day: 23, hour: 12))!
        let active = try Notes.start(in: root, at: after)
        try Notes.replaceTail("", with: String(decoding: text, as: UTF8.self), in: active)
        let whileRecording = await sync(root, [])
        precondition(whileRecording?.absoluteString == recoveredLink)
        Notes.finish(active)
        let newLink = "https://example.invalid/docx/new"
        let newDoc = ["document": ["document_id": "new", "url": newLink]]
        let finished = await sync(root, customFolder: "designated", [Step(create(in: "designated"), newDoc), Step(rename("new"))])
        precondition(finished?.absoluteString == newLink)

        // Sorting uses the calendar date and numeric note number after migrating old receipts.
        let ordered = root.appendingPathComponent("2027")
        let tenth = "https://example.invalid/docx/tenth"
        try completed("9月30日，笔记98", in: ordered, link: link)
        try completed("11月9日，笔记98", in: ordered, link: link)
        try completed("11月23日，笔记9", in: ordered, link: link)
        try completed("11月23日，笔记10", in: ordered, link: tenth)
        let newest = await sync(root, [])
        precondition(newest?.absoluteString == tenth)
    }
}
