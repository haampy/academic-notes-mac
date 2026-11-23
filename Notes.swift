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

    static func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((text + "\n").utf8))
    }

    static func finish(_ url: URL) {
        recording.withLock { current in if current == url { current = nil } }
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func syncPending(excluding current: URL? = nil) async -> (url: URL?, failed: Bool) {
        await uploader.sync(excluding: current)
    }

    private struct Receipt: Codable {
        var folder: String
        var link: URL?
    }

    private actor Feishu {
        func sync(excluding excluded: URL?) -> (URL?, Bool) {
            var last: URL?
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: directory.path) else { return (nil, false) }
                let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for note in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where note.pathExtension == "txt" {
                    if note == excluded || recording.withLock({ $0 == note }) { continue }
                    let marker = directory.appendingPathComponent("." + note.lastPathComponent + ".json")
                    let retry = fm.fileExists(atPath: marker.path)
                    var receipt = retry ? try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: marker))
                                        : Receipt(folder: UserDefaults.standard.string(forKey: "feishuFolderToken") ?? "")
                    if let link = receipt.link { last = link; continue }
                    let text = try String(contentsOf: note, encoding: .utf8)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let title = note.deletingPathExtension().lastPathComponent
                    if retry { receipt.link = try existing(title, folder: receipt.folder) }
                    if receipt.link == nil {
                        try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                        let paragraphs = text.split(whereSeparator: \.isNewline).map { line in
                            let escaped = String(line).replacingOccurrences(of: "&", with: "&amp;")
                                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                            return "<p>\(escaped)</p>"
                        }.joined()
                        var args = ["docs", "+create", "--content", "-"]
                        if !receipt.folder.isEmpty { args += ["--parent-token", receipt.folder] }
                        let result = try cli(args, input: Data(("<title>\(title)</title>" + paragraphs).utf8))
                        guard let doc = result["document"] as? [String: Any], let link = doc["url"] as? String,
                              let url = URL(string: link), url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
                        receipt.link = url
                    }
                    try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
                    last = receipt.link
                }
                return (last, false)
            } catch {
                return (last, true)
            }
        }

        // A lost create response can still mean the document exists. Look in its original folder first.
        private func existing(_ title: String, folder: String) throws -> URL? {
            var args = ["drive", "files", "list"]
            if !folder.isEmpty { args += ["--folder-token", folder] }
            var page: [String] = []
            repeat {
                let data = try cli(args + page)
                guard let files = data["files"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
                if let file = files.first(where: { $0["name"] as? String == title && $0["type"] as? String == "docx" }) {
                    guard let link = file["url"] as? String, let url = URL(string: link), url.scheme == "https" else { throw CocoaError(.coderReadCorrupt) }
                    return url
                }
                guard data["has_more"] as? Bool == true else { return nil }
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
                  json["ok"] as? Bool == true, let data = json["data"] as? [String: Any] else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }
}
