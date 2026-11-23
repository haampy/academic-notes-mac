import Foundation
import os

enum Notes {
    static let directory = URL.applicationSupportDirectory.appending(path: "AcademicNotes/Notes", directoryHint: .isDirectory)
    private static let recording = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private static let uploader = Feishu()

    static func start() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "学术笔记 \(date.string(from: Date())) \(UUID().uuidString.prefix(6)).txt"
        let url = directory.appendingPathComponent(name)
        try recording.withLock { current in
            try Data().write(to: url, options: .withoutOverwriting)
            current = url
        }
        return url
    }

    // The original filename identifies the session, even after its display name changes.
    private static func sessionName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.components(separatedBy: " — ").last ?? name
    }

    private static func contents(of url: URL) throws -> (title: String, body: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("# "), let end = text.range(of: "\n\n") {
            return (String(text[text.startIndex..<end.lowerBound].dropFirst(2)), String(text[end.upperBound...]))
        }
        return (sessionName(url), text)
    }

    static func title(for url: URL) throws -> String { try contents(of: url).title }

    static func rename(_ value: String, for url: URL) throws -> URL {
        let id = sessionName(url)
        let cleaned = value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.isEmpty ? id : cleaned
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
            let filename = title == id ? id : "\(prefix) — \(id)"
            let target = directory.appendingPathComponent(filename + ".txt")
            if note.title == title && target == url { return url }
            let header = title == id ? "" : "# \(title)\n\n"
            try (header + note.body).write(to: url, atomically: true, encoding: .utf8)
            if target != url {
                do { try FileManager.default.moveItem(at: url, to: target) }
                catch {
                    let oldHeader = note.title == id ? "" : "# \(note.title)\n\n"
                    try? (oldHeader + note.body).write(to: url, atomically: true, encoding: .utf8)
                    throw error
                }
            }
            if current == url { current = target }
            return target
        }
    }

    static func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((text + "\n").utf8))
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
        await uploader.sync(excluding: current)
    }

    private struct Receipt: Codable {
        var folder: String
        var link: URL?
        var stagingTitle: String?
        var documentID: String?
    }

    private actor Feishu {
        func sync(excluding excluded: URL?) -> (URL?, Bool) {
            var last: URL?
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: directory.path) else { return (nil, false) }
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for note in files.sorted(by: { sessionName($0) < sessionName($1) }) where note.pathExtension == "txt" {
                    let id = sessionName(note)
                    if note == excluded || recording.withLock({ $0.map(sessionName) == id }) { continue }
                    guard fm.fileExists(atPath: note.path) else { continue }
                    let marker = directory.appendingPathComponent("." + id + ".txt.json")
                    let retry = fm.fileExists(atPath: marker.path)
                    var receipt = retry ? try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: marker))
                                        : Receipt(folder: UserDefaults.standard.string(forKey: "feishuFolderToken") ?? "",
                                                  stagingTitle: "AcademicNotes-" + UUID().uuidString)
                    if let link = receipt.link, receipt.stagingTitle == nil { last = link; continue }
                    let (title, text) = try contents(of: note)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if receipt.link == nil {
                        // Recover by a private session key, never by a user's possibly repeated title.
                        if title != id && receipt.stagingTitle == nil {
                            receipt.stagingTitle = id // An unfinished upload from the previous format used its filename.
                        }
                        let key = receipt.stagingTitle ?? id
                        let recovered = retry ? try existing(key, folder: receipt.folder) : nil
                        if let recovered {
                            receipt.link = recovered.url
                            receipt.documentID = recovered.token
                        } else {
                            try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                            let paragraphs = text.split(whereSeparator: \.isNewline).map { line in
                                let escaped = String(line).replacingOccurrences(of: "&", with: "&amp;")
                                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                                return "<p>\(escaped)</p>"
                            }.joined()
                            var args = ["docs", "+create", "--content", "-"]
                            if !receipt.folder.isEmpty { args += ["--parent-token", receipt.folder] }
                            let result = try cli(args, input: Data(("<title>\(key)</title>" + paragraphs).utf8))
                            guard let doc = result["document"] as? [String: Any], let link = doc["url"] as? String,
                                  let url = URL(string: link), url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
                            receipt.link = url
                            receipt.documentID = doc["document_id"] as? String
                        }
                        // Save the remote identity before renaming. Repeating a rename is safe after a crash.
                        try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                    }
                    if receipt.stagingTitle != nil {
                        guard let token = receipt.documentID, !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                        let payload = try JSONEncoder().encode(["new_title": title])
                        _ = try cli(["drive", "files", "patch", "--file-token", token, "--type", "docx", "--data", "-"], input: payload)
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

        // A lost create response can still mean the document exists. Look in its original folder first.
        private func existing(_ title: String, folder: String) throws -> (url: URL, token: String?)? {
            var args = ["drive", "files", "list"]
            if !folder.isEmpty { args += ["--folder-token", folder] }
            var page: [String] = []
            var match: (URL, String?)?
            repeat {
                let data = try cli(args + page)
                guard let files = data["files"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
                for file in files where file["name"] as? String == title && file["type"] as? String == "docx" {
                    guard match == nil, let link = file["url"] as? String, let url = URL(string: link),
                          url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
                    match = (url, file["token"] as? String)
                }
                guard data["has_more"] as? Bool == true else { return match }
                guard let token = data["next_page_token"] as? String, !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
                page = ["--page-token", token]
            } while true
        }

        private func cli(_ args: [String], input: Data? = nil) throws -> [String: Any] {
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
