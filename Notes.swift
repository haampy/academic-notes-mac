import Foundation
import os

enum Notes {
    static let directory = URL.applicationSupportDirectory.appending(path: "AcademicNotes/Notes", directoryHint: .isDirectory)
    private static let recording = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private static let uploader = Feishu()

    static func start(in folder: URL = directory, at now: Date = Date()) throws -> URL {
        try recording.withLock { current in
            let url = try FlatNoteStore.create(in: folder, at: now)
            current = url
            return url
        }
    }

    // The original filename identifies the session, even after its display name changes.
    static func sessionName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.components(separatedBy: " — ").last ?? name
    }

    private static func contents(of url: URL) throws -> (title: String, body: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("# "), let end = text.range(of: "\n\n") {
            return (String(text[text.startIndex..<end.lowerBound].dropFirst(2)), String(text[end.upperBound...]))
        }
        return (FlatNoteStore.defaultTitle(for: sessionName(url)), text)
    }

    static func title(for url: URL) throws -> String { try contents(of: url).title }

    static func displayTitle(_ title: String, for note: URL) -> String {
        guard title == sessionName(note),
              let timestamp = title.wholeMatch(of: #/学术笔记 ([0-9]{4})-([0-9]{2})-([0-9]{2}) (?:[01][0-9]|2[0-3])\.[0-5][0-9]\.[0-5][0-9] [0-9A-F]{6}/#),
              let year = Int(timestamp.1), let month = Int(timestamp.2), let day = Int(timestamp.3),
              DateComponents(year: year, month: month, day: day).isValidDate(in: Calendar(identifier: .gregorian))
        else { return title }
        return "\(month) 月 \(day) 日的笔记"
    }

    static func rename(_ value: String, for url: URL) throws -> URL {
        let id = sessionName(url)
        let cleaned = value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTitle = FlatNoteStore.defaultTitle(for: id)
        let title = cleaned.isEmpty ? defaultTitle : cleaned
        return try recording.withLock { current in
            let note = try contents(of: url)
            let safe = title.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
            var prefix = ""
            for char in safe {
                if prefix.utf8.count + String(char).utf8.count > 140 { break }
                prefix.append(char)
            }
            // A visible stem keeps the note usable in Finder. The header retains the exact title.
            if prefix.hasPrefix(".") { prefix = "笔记 " + prefix }
            let filename = title == defaultTitle ? id : "\(prefix) — \(id)"
            let target = url.deletingLastPathComponent().appendingPathComponent(filename + ".txt")
            if note.title == title && target == url { return url }
            let header = title == defaultTitle ? "" : "# \(title)\n\n"
            try (header + note.body).write(to: url, atomically: true, encoding: .utf8)
            if target != url {
                do { try FileManager.default.moveItem(at: url, to: target) }
                catch {
                    let oldHeader = note.title == defaultTitle ? "" : "# \(note.title)\n\n"
                    try? (oldHeader + note.body).write(to: url, atomically: true, encoding: .utf8)
                    throw error
                }
            }
            if current == url { current = target }
            return target
        }
    }

    static func replaceTail(_ old: String, with new: String, in url: URL) throws {
        try recording.withLock { _ in
            if old.isEmpty {
                guard !new.isEmpty else { return }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                let end = try file.seekToEnd()
                do {
                    try file.write(contentsOf: Data(new.utf8))
                    try file.synchronize()
                } catch {
                    // A short write must not become part of the next retry.
                    try file.truncate(atOffset: end)
                    throw error
                }
                return
            }

            var contents = try Data(contentsOf: url)
            let oldBytes = old.utf8
            guard contents.suffix(oldBytes.count).elementsEqual(oldBytes) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "笔记末尾已被修改，无法续写。"
                ])
            }
            contents.replaceSubrange((contents.count - oldBytes.count)..<contents.count, with: new.utf8)
            try contents.write(to: url, options: .atomic)
        }
    }

    static func finish(_ url: URL) {
        recording.withLock { current in
            if (try? contents(of: url).body.trimmingCharacters(in: .whitespacesAndNewlines)) == "" {
                try? FileManager.default.removeItem(at: url)
            }
            if current == url { current = nil }
        }
    }

    static func syncPending(excluding current: URL? = nil) async -> (url: URL?, failed: Bool) {
        let folder = UserDefaults.standard.string(forKey: "feishuFolderToken") ?? ""
        return await uploader.sync(in: directory, folderToken: folder, excluding: current)
    }

    private struct Receipt: Codable {
        var folder: String
        var link: URL?
        var stagingTitle: String?
        var documentID: String?
    }

    actor Feishu {
        typealias Command = ([String], Data?) throws -> [String: Any]
        private let run: Command

        init(run: @escaping Command = Feishu.cli) { self.run = run }

        func sync(in directory: URL, folderToken: String, excluding excluded: URL?) -> (URL?, Bool) {
            var last: URL?
            var defaultFolder: String?
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: directory.path) else { return (nil, false) }
                let index = try FlatNoteStore.prepare(in: directory)
                let excludedID = excluded.flatMap { storageID(for: $0, in: directory, index: index) }
                for note in try notesByDate(in: directory, years: index.years) {
                    let id = sessionName(note)
                    if id == excludedID { continue }
                    if let active = recording.withLock({ $0 }),
                       storageID(for: active, in: directory, index: index) == id { continue }
                    guard fm.fileExists(atPath: note.path) else { continue }
                    let marker = directory.appendingPathComponent("." + id + ".txt.json")
                    let retry = fm.fileExists(atPath: marker.path)
                    var receipt = retry ? try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: marker))
                                        : Receipt(folder: folderToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  stagingTitle: "Purrk-" + UUID().uuidString)
                    if let link = receipt.link, receipt.stagingTitle == nil { last = link; continue }
                    let (title, text) = try contents(of: note)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if receipt.link == nil {
                        // Recover by a private session key, never by a user's possibly repeated title.
                        let originalID = FlatNoteStore.defaultTitle(for: id)
                        if title != originalID && receipt.stagingTitle == nil {
                            receipt.stagingTitle = originalID // Early uploads used the original filename.
                        }
                        let key = receipt.stagingTitle ?? originalID
                        let recovered = retry ? try existing(key, folder: receipt.folder) : nil
                        if let recovered {
                            receipt.link = recovered.url
                            receipt.documentID = recovered.token
                        } else {
                            // A legacy receipt may describe a create at the root with its response lost.
                            // Only change its destination after checking that original location above.
                            if receipt.folder.isEmpty {
                                receipt.folder = try defaultFolder ?? purrkFolder()
                                defaultFolder = receipt.folder
                            }
                            try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                            let paragraphs = text.split(whereSeparator: \.isNewline).map { line in
                                let escaped = String(line).replacingOccurrences(of: "&", with: "&amp;")
                                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                                return "<p>\(escaped)</p>"
                            }.joined()
                            let args = ["docs", "+create", "--content", "-", "--parent-token", receipt.folder]
                            let result = try run(args, Data(("<title>\(key)</title>" + paragraphs).utf8))
                            guard let doc = result["document"] as? [String: Any], let link = doc["url"] as? String,
                                  let token = doc["document_id"] as? String, !token.isEmpty,
                                  let url = URL(string: link), url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
                            receipt.link = url
                            receipt.documentID = token
                        }
                        // Save the remote identity before renaming. Repeating a rename is safe after a crash.
                        try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                    }
                    if receipt.stagingTitle != nil {
                        guard let token = receipt.documentID, !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                        let payload = try JSONEncoder().encode(["new_title": title])
                        _ = try run(["drive", "files", "patch", "--file-token", token, "--type", "docx", "--data", "-"], payload)
                        receipt.stagingTitle = nil
                        try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                    }
                    last = receipt.link
                }
                return (last, false)
            } catch {
                return (last, true)
            }
        }

        private func storageID(for note: URL, in root: URL, index: FlatNoteStore.Index) -> String? {
            let id = sessionName(note)
            let parent = note.deletingLastPathComponent()
            if parent.standardizedFileURL.path == root.standardizedFileURL.path { return id }
            // A caller can still hold a path from before its year folder was flattened.
            guard parent.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  let year = Int(parent.lastPathComponent) else { return nil }
            return index.migrationID(for: id, year: year)
        }

        private func notesByDate(in root: URL, years: [String: Int]) throws -> [URL] {
            let entries = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
            let files = try entries.filter { url in
                guard url.pathExtension == "txt" else { return false }
                return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            return files.map { (url: $0, key: order(for: $0, years: years)) }.sorted { $0.key < $1.key }.map(\.url)
        }

        // Sort by session date, not the file's timestamp, which changes on edits. On the
        // upgrade day the original timestamped sessions precede the new daily sequence.
        private func order(for url: URL, years: [String: Int]) -> (String, Int, String) {
            let id = sessionName(url)
            if let year = years[id], let day = FlatNoteStore.dailyParts(FlatNoteStore.defaultTitle(for: id)) {
                return (String(format: "%04d-%02d-%02d", year, day.month, day.day), day.number, id)
            }
            if let legacy = id.prefixMatch(of: #/学术笔记 ([0-9]{4}-[0-9]{2}-[0-9]{2}) /#) {
                return (String(legacy.1), 0, id)
            }
            return ("", 0, id)
        }

        private func purrkFolder() throws -> String {
            let folders = try matches(named: "Purrk", type: "folder", in: "")
            // Drive allows duplicate folder names. Choose consistently across launches.
            if let folder = folders.compactMap({ $0["token"] as? String }).filter({ !$0.isEmpty }).min() {
                return folder
            }
            guard folders.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            let created = try run(["drive", "+create-folder", "--name", "Purrk"], nil)
            guard let token = created["folder_token"] as? String, !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            return token
        }

        private func existing(_ title: String, folder: String) throws -> (url: URL, token: String)? {
            let files = try matches(named: title, type: "docx", in: folder)
            guard let file = files.first else { return nil }
            guard files.count == 1, let token = file["token"] as? String, !token.isEmpty,
                  let link = file["url"] as? String,
                  let url = URL(string: link), url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
            return (url, token)
        }

        private func matches(named name: String, type: String, in folder: String) throws -> [[String: Any]] {
            var args = ["drive", "files", "list"]
            if !folder.isEmpty { args += ["--folder-token", folder] }
            var page: [String] = []
            var matches: [[String: Any]] = []
            repeat {
                let data = try run(args + page, nil)
                guard let files = data["files"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
                matches += files.filter { $0["name"] as? String == name && $0["type"] as? String == type }
                guard data["has_more"] as? Bool == true else { return matches }
                guard let token = data["next_page_token"] as? String, !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                page = ["--page-token", token]
            } while true
        }

        private static func cli(_ args: [String], input: Data?) throws -> [String: Any] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["lark-cli"] + args + ["--as", "user", "--format", "json"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
            env["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
            process.environment = env
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // An input file lets the CLI consume long lectures without argument or pipe limits.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { if input != nil { try? FileManager.default.removeItem(at: tmp) } }
            if let input {
                try input.write(to: tmp, options: .atomic)
                process.standardInput = try FileHandle(forReadingFrom: tmp)
            } else { process.standardInput = FileHandle.nullDevice }
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  json["ok"] as? Bool == true else { throw CocoaError(.fileWriteUnknown) }
            return json["data"] as? [String: Any] ?? [:]
        }
    }
}
