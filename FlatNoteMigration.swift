import Darwin
import Foundation

extension FlatNoteStore {
    private struct LegacyNote {
        var texts: [URL] = []
        var receipt: URL?
    }

    // The caller serializes migration with new-note allocation and finishes it before sync.
    static func migrate(in root: URL, index: inout Index) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = FileManager.default
        let top = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
        let documents = Set(top.filter { $0.pathExtension == "txt" }.compactMap(fileID))
        let receipts = Set(top.filter { $0.pathExtension == "json" }.compactMap(fileID))
        let occupied = documents.union(receipts)
        for folder in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = folder.lastPathComponent
            guard name.wholeMatch(of: #/[0-9]{4}/#) != nil, let year = Int(name) else { continue }
            let folderType = try folder.resourceValues(forKeys: keys)
            guard folderType.isDirectory == true, folderType.isSymbolicLink != true else { continue }

            let entries = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            var groups: [String: LegacyNote] = [:]
            var counters: [URL] = []
            for source in entries {
                let type = try source.resourceValues(forKeys: keys)
                guard type.isRegularFile == true, type.isSymbolicLink != true else { continue }
                let name = source.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".sequence") {
                    let day = String(name.dropFirst().dropLast(".sequence".count))
                    guard dailyParts(day + "，笔记1") != nil else { continue }
                    let raw = try String(contentsOf: source, encoding: .utf8)
                    guard let number = Int(raw), number >= 0 else { continue }
                    index.include(number: number, day: day, year: year)
                    counters.append(source)
                    continue
                }
                let isReceipt = name.hasPrefix(".") && name.hasSuffix(".txt.json")
                guard isReceipt || (!name.hasPrefix(".") && source.pathExtension == "txt") else { continue }
                let title = isReceipt ? String(name.dropFirst().dropLast(".txt.json".count)) : Notes.sessionName(source)
                guard dailyParts(title) != nil else { continue }
                if isReceipt {
                    groups[title, default: LegacyNote()].receipt = source
                } else {
                    groups[title, default: LegacyNote()].texts.append(source)
                }
            }
            guard !groups.isEmpty || !counters.isEmpty else { continue }
            var moves: [(source: URL, target: URL)] = []
            var links: [(source: URL, target: URL)] = []
            for (title, group) in groups {
                var id = index.migrationID(for: title, year: year)
                if let planned = id {
                    let target = root.appendingPathComponent("." + planned + ".txt.json")
                    let published = group.receipt.map { sameInode($0, target) } ?? false
                    // Our receipt can already be linked on retry. A still-present source text
                    // and an occupied target identity, however, represent distinct documents.
                    let textConflict = documents.contains(planned) && (!group.texts.isEmpty || !published)
                    if textConflict && published { try files.removeItem(at: target) }
                    if textConflict || (receipts.contains(planned) && !published) { id = nil }
                }
                let destination = try id ?? index.reserveID(for: title, year: year, occupied: occupied)
                index.recordMigration(destination, for: title, year: year)
                if let receipt = group.receipt {
                    links.append((receipt, root.appendingPathComponent("." + destination + ".txt.json")))
                }
                for source in group.texts {
                    let prefix = source.deletingPathExtension().lastPathComponent.dropLast(title.count)
                    moves.append((source, root.appendingPathComponent(String(prefix) + destination + ".txt")))
                }
            }
            try index.save(in: root)

            // Publish receipts first, keeping the original alongside its note until the move
            // succeeds. A crash can then be retried from either layout without a new upload.
            for (source, target) in links {
                if link(source.path, target.path) == -1 {
                    let error = errno
                    guard error == EEXIST && sameInode(source, target) else { throw posixFailure(error) }
                }
            }
            for (source, target) in moves {
                if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == -1 { throw posixFailure(errno) }
            }
            for source in links.map(\.source) + counters { try files.removeItem(at: source) }
            if rmdir(folder.path) == -1, errno != ENOTEMPTY { throw posixFailure(errno) }
        }
    }

    private static func sameInode(_ lhs: URL, _ rhs: URL) -> Bool {
        var a = stat(), b = stat()
        return lstat(lhs.path, &a) == 0 && lstat(rhs.path, &b) == 0 &&
            a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func posixFailure(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
