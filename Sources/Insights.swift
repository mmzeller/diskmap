import Foundation
import CryptoKit

// MARK: - Cleanup ideas

struct Idea: Identifiable {
    let node: FileNode
    let explanation: Explanation
    var id: ObjectIdentifier { node.id }
}

enum IdeaFinder {
    static let minSize: Int64 = 50_000_000

    /// Walks the biggest parts of the tree and collects items the explainer marks as worth removing.
    static func find(root: FileNode, explainer: Explainer) -> [Idea] {
        var ideas: [Idea] = []

        func walk(_ node: FileNode) {
            for child in node.children {
                if child.size < minSize { break }
                if child.kind == .smallFiles { continue }
                if let explanation = explainer.explain(child) {
                    if explanation.suggest {
                        ideas.append(Idea(node: child, explanation: explanation))
                    } else if explanation.isGroup {
                        walk(child)
                    }
                    continue
                }
                if child.isDirectory && !child.isPackage {
                    walk(child)
                }
            }
        }

        if let explanation = explainer.explain(root), explanation.suggest {
            return [Idea(node: root, explanation: explanation)]
        }
        walk(root)
        ideas.sort { $0.node.size > $1.node.size }
        return ideas
    }
}

// MARK: - Big files you haven't opened

struct UntouchedFile: Identifiable {
    let node: FileNode
    let lastUsed: Date
    /// True when the date is when the file was last opened; false when it's the last change.
    let isLastOpened: Bool
    var id: ObjectIdentifier { node.id }
}

enum Untouched {
    /// System folders and app data are left out: the point is to surface your own forgotten files.
    static func isExcluded(_ path: String, home: String) -> Bool {
        let blocked = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/opt", "/Applications", "/cores",
                       home + "/Library", home + "/.Trash"]
        for prefix in blocked where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    static func find(root: FileNode, minSize: Int64, cutoff: Date, home: String) -> [UntouchedFile] {
        var candidates: [FileNode] = []

        func walk(_ node: FileNode) {
            for child in node.children {
                if child.size < minSize { break }
                switch child.kind {
                case .file:
                    if !child.insidePackage { candidates.append(child) }
                case .directory:
                    if child.isPackage || isExcluded(child.path, home: home) { continue }
                    walk(child)
                case .smallFiles:
                    continue
                }
            }
        }

        walk(root)

        var results: [UntouchedFile] = []
        for file in candidates {
            let used = lastUsed(file)
            if used.date < cutoff {
                results.append(UntouchedFile(node: file, lastUsed: used.date, isLastOpened: used.opened))
            }
        }
        results.sort { $0.node.size > $1.node.size }
        return results
    }

    /// Spotlight's "last opened" date when it has one, otherwise the last change.
    static func lastUsed(_ node: FileNode) -> (date: Date, opened: Bool) {
        let modified = node.modified ?? Date.distantPast
        if let item = NSMetadataItem(url: node.url),
           let opened = item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
           opened > modified {
            return (opened, true)
        }
        return (modified, false)
    }
}

// MARK: - Duplicates

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileSize: Int64
    var files: [FileNode]

    /// Space you'd get back by keeping just one copy.
    var wasted: Int64 {
        guard let first = files.first, files.count > 1 else { return 0 }
        return first.size * Int64(files.count - 1)
    }
}

final class DuplicateProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = "Looking for files with the same size"
    private var done: Int64 = 0
    private var total: Int64 = 0
    private var cancelled = false

    func setPhase(_ newPhase: String, total newTotal: Int64) {
        lock.lock()
        phase = newPhase
        done = 0
        total = newTotal
        lock.unlock()
    }

    func advance(_ amount: Int64) {
        lock.lock()
        done += amount
        lock.unlock()
    }

    func read() -> (phase: String, fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
        return (phase, fraction)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum DuplicateFinder {
    /// Same size → same first and last 64 KB → same full contents. Each step only reads what's still in doubt.
    static func find(root: FileNode, minSize: Int64, home: String, progress: DuplicateProgress) -> [DuplicateGroup] {
        var bySize: [Int64: [FileNode]] = [:]

        func walk(_ node: FileNode) {
            for child in node.children {
                if child.size < minSize { break }
                switch child.kind {
                case .file:
                    if !child.insidePackage && child.logicalSize >= minSize {
                        bySize[child.logicalSize, default: []].append(child)
                    }
                case .directory:
                    if child.isPackage || Untouched.isExcluded(child.path, home: home) { continue }
                    walk(child)
                case .smallFiles:
                    continue
                }
            }
        }

        walk(root)

        let sameSize = bySize.values.filter { $0.count > 1 }
        var sampleCount: Int64 = 0
        for group in sameSize { sampleCount += Int64(group.count) }
        progress.setPhase("Comparing the start and end of each file", total: sampleCount)

        var candidates: [[FileNode]] = []
        for group in sameSize {
            if progress.isCancelled { return [] }
            var buckets: [Data: [FileNode]] = [:]
            for file in group {
                if let hash = sampleHash(file) {
                    buckets[hash, default: []].append(file)
                }
                progress.advance(1)
            }
            for bucket in buckets.values where bucket.count > 1 {
                candidates.append(bucket)
            }
        }

        var bytesToRead: Int64 = 0
        for group in candidates {
            for file in group { bytesToRead += file.logicalSize }
        }
        progress.setPhase("Checking full contents", total: bytesToRead)

        var groups: [DuplicateGroup] = []
        for group in candidates {
            if progress.isCancelled { return [] }
            var buckets: [Data: [FileNode]] = [:]
            for file in group {
                if let hash = fullHash(file, progress: progress) {
                    buckets[hash, default: []].append(file)
                }
            }
            for bucket in buckets.values where bucket.count > 1 {
                let unique = removeHardLinks(bucket)
                if unique.count > 1 {
                    let ordered = unique.sorted { ($0.modified ?? Date.distantPast) < ($1.modified ?? Date.distantPast) }
                    groups.append(DuplicateGroup(fileSize: ordered[0].logicalSize, files: ordered))
                }
            }
        }
        if progress.isCancelled { return [] }
        groups.sort { $0.wasted > $1.wasted }
        return groups
    }

    private static func sampleHash(_ file: FileNode) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 65_536
        do {
            if let head = try handle.read(upToCount: chunk) {
                hasher.update(data: head)
            }
            if file.logicalSize > Int64(chunk * 2) {
                try handle.seek(toOffset: UInt64(file.logicalSize - Int64(chunk)))
                if let tail = try handle.read(upToCount: chunk) {
                    hasher.update(data: tail)
                }
            }
        } catch {
            return nil
        }
        return Data(hasher.finalize())
    }

    private static func fullHash(_ file: FileNode, progress: DuplicateProgress) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if progress.isCancelled { return nil }
            var finished = false
            var failed = false
            autoreleasepool {
                do {
                    if let data = try handle.read(upToCount: 8 * 1_048_576), !data.isEmpty {
                        hasher.update(data: data)
                        progress.advance(Int64(data.count))
                    } else {
                        finished = true
                    }
                } catch {
                    failed = true
                }
            }
            if failed { return nil }
            if finished { break }
        }
        return Data(hasher.finalize())
    }

    /// Two paths that point at the same file on disk (hard links) aren't duplicates.
    private static func removeHardLinks(_ files: [FileNode]) -> [FileNode] {
        var seen = Set<UInt64>()
        var unique: [FileNode] = []
        for file in files {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value {
                if seen.contains(inode) { continue }
                seen.insert(inode)
            }
            unique.append(file)
        }
        return unique
    }
}
