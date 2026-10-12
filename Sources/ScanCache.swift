import Foundation

/// What's known about the saved scan without opening the (larger) tree file.
struct ScanCacheInfo: Codable {
    var formatVersion: Int
    var rootPath: String
    var displayName: String
    var date: Date
    var duration: TimeInterval
    var unreadable: Int
    var total: Int64
    /// Position in macOS's change log when the scan started, for quick rescans. Missing in older saves.
    var eventID: UInt64?
    /// Which change log that position belongs to.
    var eventDatabase: String?
    /// True when the background check, not you, last updated this scan.
    var automatic: Bool?
}

/// Saves the most recent scan to disk so DiskMap can reopen it at launch.
/// Lives in ~/Library/Application Support/DiskMap, so rebuilding or reinstalling the app keeps it.
enum ScanCache {
    static let formatVersion = 1

    private static var infoURL: URL { History.folder.appendingPathComponent("last-scan.json") }
    private static var treeURL: URL { History.folder.appendingPathComponent("last-scan.tree") }
    /// Items moved to the Trash since the scan, applied when the tree is reopened.
    private static var removedURL: URL { History.folder.appendingPathComponent("last-scan-removed.json") }

    enum CacheError: Error {
        case truncated
        case corrupt
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

    // MARK: Info

    static func loadInfo() -> ScanCacheInfo? {
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? decoder().decode(ScanCacheInfo.self, from: data),
              info.formatVersion == formatVersion,
              FileManager.default.fileExists(atPath: treeURL.path) else { return nil }
        return info
    }

    // MARK: Saving

    static func save(root: FileNode, info: ScanCacheInfo) {
        do {
            try FileManager.default.createDirectory(at: History.folder, withIntermediateDirectories: true)
            var data = Data()
            data.reserveCapacity(8 << 20)
            write(root, into: &data)
            let compressed = try (data as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: treeURL, options: .atomic)
            try? FileManager.default.removeItem(at: removedURL)
            try encoder().encode(info).write(to: infoURL, options: .atomic)
        } catch {
            // Without a complete save, don't offer a half-written one next time.
            try? FileManager.default.removeItem(at: infoURL)
        }
    }

    /// Each node: kind, flags, size, logical size, item count, [modified], name, child count, then its children.
    private static func write(_ node: FileNode, into data: inout Data) {
        data.append(node.kind.rawValue)
        var flags: UInt8 = 0
        if node.isPackage { flags |= 1 }
        if node.insidePackage { flags |= 2 }
        if node.unreadable { flags |= 4 }
        if node.modified != nil { flags |= 8 }
        data.append(flags)
        append(UInt64(bitPattern: node.size), to: &data)
        append(UInt64(bitPattern: node.logicalSize), to: &data)
        append(UInt64(bitPattern: Int64(node.itemCount)), to: &data)
        if let modified = node.modified {
            append(modified.timeIntervalSince1970.bitPattern, to: &data)
        }
        let name = Array(node.name.utf8)
        append(UInt32(name.count), to: &data)
        data.append(contentsOf: name)
        append(UInt32(node.children.count), to: &data)
        for child in node.children {
            write(child, into: &data)
        }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in data.append(contentsOf: bytes) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in data.append(contentsOf: bytes) }
    }

    // MARK: Loading

    static func loadTree(info: ScanCacheInfo) throws -> FileNode {
        let compressed = try Data(contentsOf: treeURL)
        let data = try (compressed as NSData).decompressed(using: .lzfse) as Data
        let root = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> FileNode in
            var reader = ByteReader(bytes: raw)
            return try readNode(&reader)
        }
        root.rootPath = info.rootPath
        // Scans saved by version 1.3 could include /.nofollow and friends; drop them on the way in.
        if info.rootPath == "/" {
            for child in root.children where DiskScanner.skipPaths.contains("/" + child.name) {
                child.detach()
            }
        }
        for path in removedPaths() {
            if path.hasSuffix("/*") {
                // Everything inside a folder was removed (an emptied Trash).
                if let folder = find(String(path.dropLast(2)), in: root) {
                    for child in folder.children { child.detach() }
                }
            } else if let node = find(path, in: root), node !== root {
                node.detach()
            }
        }
        return root
    }

    private struct ByteReader {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        mutating func u8() throws -> UInt8 {
            guard offset + 1 <= bytes.count else { throw CacheError.truncated }
            let value = bytes[offset]
            offset += 1
            return value
        }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw CacheError.truncated }
            var value: UInt32 = 0
            for index in 0..<4 {
                value |= UInt32(bytes[offset + index]) << (8 * index)
            }
            offset += 4
            return value
        }

        mutating func u64() throws -> UInt64 {
            guard offset + 8 <= bytes.count else { throw CacheError.truncated }
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(bytes[offset + index]) << (8 * index)
            }
            offset += 8
            return value
        }

        mutating func string(count: Int) throws -> String {
            guard count >= 0, offset + count <= bytes.count else { throw CacheError.truncated }
            let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
            offset += count
            return String(decoding: slice, as: UTF8.self)
        }
    }

    private static func readNode(_ reader: inout ByteReader) throws -> FileNode {
        let kindValue = try reader.u8()
        guard let kind = FileNode.Kind(rawValue: kindValue) else { throw CacheError.corrupt }
        let flags = try reader.u8()
        let size = try Int64(bitPattern: reader.u64())
        let logicalSize = try Int64(bitPattern: reader.u64())
        let itemCount = try Int64(bitPattern: reader.u64())
        var modified: Date?
        if flags & 8 != 0 {
            modified = try Date(timeIntervalSince1970: Double(bitPattern: reader.u64()))
        }
        let nameLength = try Int(reader.u32())
        let name = try reader.string(count: nameLength)

        let node = FileNode(name: name, kind: kind)
        node.size = size
        node.logicalSize = logicalSize
        node.itemCount = Int(itemCount)
        node.modified = modified
        node.isPackage = flags & 1 != 0
        node.insidePackage = flags & 2 != 0
        node.unreadable = flags & 4 != 0

        let childCount = try Int(reader.u32())
        guard childCount <= reader.bytes.count else { throw CacheError.corrupt }
        var children: [FileNode] = []
        children.reserveCapacity(childCount)
        for _ in 0..<childCount {
            let child = try readNode(&reader)
            child.parent = node
            children.append(child)
        }
        node.children = children
        return node
    }

    // MARK: Removals

    static func recordRemoval(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var list = removedPaths()
        list.append(contentsOf: paths)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: removedURL, options: .atomic)
        }
    }

    /// Forgets removals, after the items were put back.
    static func unrecordRemovals(_ paths: [String]) {
        let restored = Set(paths)
        let list = removedPaths().filter { !restored.contains($0) }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: removedURL, options: .atomic)
        }
    }

    private static func removedPaths() -> [String] {
        guard let data = try? Data(contentsOf: removedURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Finds a node by its full path, walking down from the root by name.
    static func find(_ path: String, in root: FileNode) -> FileNode? {
        let rootPath = root.rootPath ?? root.path
        if path == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.kind != .smallFiles && $0.name == component }) else {
                return nil
            }
            node = next
        }
        return node
    }
}
