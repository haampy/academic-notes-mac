import Darwin
import Foundation

enum FlatNoteStore {
    // Titles omit the year. Keep the recording year and counters separately so that
    // renames, empty recordings and old cloud receipts can't recycle a note's identity.
    struct Index: Codable, Equatable {
        var years: [String: Int] = [:]
        var counters: [String: Int] = [:]
        var migrations: [String: String]?

        func migrationID(for title: String, year: Int) -> String? { migrations?["\(year)/\(title)"] }

        mutating func recordMigration(_ id: String, for title: String, year: Int) {
            if migrations == nil { migrations = [:] }
            migrations?["\(year)/\(title)"] = id
        }

        mutating func include(number: Int, day: String, year: Int) {
            let key = "\(year)-\(day)"
            counters[key] = max(counters[key] ?? 0, number)
        }

        mutating func storageID(for title: String, year: Int, in root: URL) throws -> String {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return try reserveID(for: title, year: year, occupied: Set(entries.compactMap(FlatNoteStore.fileID)))
        }

        mutating func reserveID(for title: String, year: Int, occupied: Set<String>) throws -> String {
            guard let parts = FlatNoteStore.dailyParts(title) else { throw CocoaError(.fileReadCorruptFile) }
            var id = title
            var suffix = 1
            while years[id] != nil || occupied.contains(id) {
                id = suffix == 1 ? "\(title)（\(year)）" : "\(title)（\(year)-\(suffix)）"
                suffix += 1
            }
            years[id] = year
            include(number: parts.number, day: "\(parts.month)月\(parts.day)日", year: year)
            return id
        }

        func save(in root: URL) throws {
            try JSONEncoder().encode(self).write(to: root.appendingPathComponent(".purrk-index.json"), options: .atomic)
        }
    }

    private static func parsed(_ id: String) -> (title: String, month: Int, day: Int, number: Int, year: Int?)? {
        guard let match = id.wholeMatch(of: #/(([0-9]{1,2})月([0-9]{1,2})日，笔记([1-9][0-9]*))(?:（([0-9]{4})(?:-[1-9][0-9]*)?）)?/#),
              let month = Int(match.2), (1...12).contains(month),
              let day = Int(match.3), (1...31).contains(day), let number = Int(match.4)
        else { return nil }
        return (String(match.1), month, day, number, match.5.flatMap { Int($0) })
    }

    static func defaultTitle(for id: String) -> String { parsed(id)?.title ?? id }

    static func dailyParts(_ title: String) -> (month: Int, day: Int, number: Int)? {
        guard let note = parsed(title), note.year == nil else { return nil }
        return (note.month, note.day, note.number)
    }

    static func fileID(_ file: URL) -> String? {
        let name = file.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".txt.json") {
            return String(name.dropFirst().dropLast(".txt.json".count))
        }
        return file.pathExtension == "txt" ? Notes.sessionName(file) : nil
    }

    private static func load(in root: URL) throws -> Index {
        do {
            return try JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent(".purrk-index.json")))
        } catch CocoaError.fileReadNoSuchFile {
            // A folder copied without its hidden index may already contain flat notes.
            var index = Index()
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            for file in files {
                guard let id = fileID(file), let note = parsed(id) else { continue }
                let created = try file.resourceValues(forKeys: [.creationDateKey]).creationDate
                let year = note.year ?? created.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
                guard let year else { continue }
                // Prefer the note's creation date over the later creation date of its receipt.
                if file.pathExtension == "txt" || index.years[id] == nil { index.years[id] = year }
            }
            for (id, year) in index.years {
                if let note = parsed(id) { index.include(number: note.number, day: "\(note.month)月\(note.day)日", year: year) }
            }
            if !index.years.isEmpty { try index.save(in: root) }
            return index
        }
    }

    private static func withIndex<T>(in root: URL, _ action: (inout Index) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The directory inode stays stable when the index is replaced atomically.
        let lock = open(root.path, O_RDONLY | O_DIRECTORY | O_EXLOCK | O_CLOEXEC)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        var index = try load(in: root)
        try migrate(in: root, index: &index)
        return try action(&index)
    }

    static func prepare(in root: URL) throws -> Index {
        try withIndex(in: root) { $0 }
    }

    static func create(in root: URL, at date: Date) throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let day = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        return try withIndex(in: root) { index in
            let last = index.counters["\(year)-\(day)"] ?? 0
            guard last >= 0, last < Int.max else { throw CocoaError(.fileReadCorruptFile) }
            let id = try index.storageID(for: "\(day)，笔记\(last + 1)", year: year, in: root)
            try index.save(in: root)
            let url = root.appendingPathComponent(id + ".txt")
            try Data().write(to: url, options: .withoutOverwriting)
            return url
        }
    }
}
