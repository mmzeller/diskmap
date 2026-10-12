import Foundation

/// One thing DiskMap moved to the Trash, with enough detail to put it back.
struct RemovalRecord: Codable, Identifiable {
    var id: UUID
    var originalPath: String
    /// Where macOS put it in the Trash. Nil if macOS didn't say.
    var trashPath: String?
    var name: String
    var bytes: Int64
    var date: Date
    /// What the removal was part of: "Moved to Trash", "Uninstalled Slack", "Quick Clean".
    var reason: String
    var restored: Bool
    /// Items removed together share a batch, so they're listed and put back together.
    var batch: UUID?

    /// Still in the Trash, so it can be put back.
    var canPutBack: Bool {
        guard !restored, let trashPath = trashPath else { return false }
        return FileManager.default.fileExists(atPath: trashPath)
    }
}

/// Something to remove: a path plus what to call it and how big it is.
struct RemovalTarget {
    let path: String
    let name: String
    let bytes: Int64
}

/// Every removal in DiskMap goes through here, so it's recorded and can be undone.
enum Removals {
    static let keep = 1500

    private static var fileURL: URL {
        History.folder.appendingPathComponent("removals.json")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Newest first.
    static func load() -> [RemovalRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder().decode([RemovalRecord].self, from: data)) ?? []
    }

    static func save(_ records: [RemovalRecord]) {
        let trimmed = Array(records.prefix(keep))
        do {
            try FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
            try encoder().encode(trimmed).write(to: fileURL, options: .atomic)
        } catch {
            // Losing the undo list isn't worth interrupting a cleanup for.
        }
    }

    /// Moves one item to the Trash and describes where it went.
    static func trash(_ target: RemovalTarget, reason: String, batch: UUID) throws -> RemovalRecord {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: target.path), resultingItemURL: &resulting)
        let trashURL: URL? = resulting.map { $0 as URL }
        return RemovalRecord(id: UUID(), originalPath: target.path, trashPath: trashURL?.path, name: target.name,
                             bytes: target.bytes, date: Date(), reason: reason, restored: false, batch: batch)
    }

    /// Space a file or folder takes on disk, read straight from the disk.
    static func diskUsage(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return 0 }
        if !isFolder.boolValue {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        let keySet = Set(keys)
        for case let item as URL in enumerator {
            if let values = try? item.resourceValues(forKeys: keySet) {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Measures several items at once.
    static func diskUsage(ofEach paths: [String]) -> [String: Int64] {
        let results = SizeResults()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            results.set(paths[index], diskUsage(of: paths[index]))
        }
        return results.all
    }

    private final class SizeResults: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [String: Int64] = [:]

        func set(_ path: String, _ size: Int64) {
            lock.lock()
            sizes[path] = size
            lock.unlock()
        }

        var all: [String: Int64] {
            lock.lock()
            defer { lock.unlock() }
            return sizes
        }
    }

    /// Moves an item back from the Trash to where it was. Returns an explanation if it couldn't.
    static func putBack(_ record: RemovalRecord) -> String? {
        let fm = FileManager.default
        guard let trashPath = record.trashPath, fm.fileExists(atPath: trashPath) else {
            return "“\(record.name)” isn't in the Trash anymore, so it can't be put back."
        }
        if fm.fileExists(atPath: record.originalPath) {
            return "Something named “\(record.name)” is already where it used to be. Move or rename it first."
        }
        let original = URL(fileURLWithPath: record.originalPath)
        do {
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: URL(fileURLWithPath: trashPath), to: original)
            return nil
        } catch {
            return "“\(record.name)” couldn't be put back: \(error.localizedDescription)"
        }
    }
}
