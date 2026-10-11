import Foundation

/// Thread-safe progress counters the interface polls while a scan runs.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var items = 0
    private var bytes: Int64 = 0
    private var currentPath = ""
    private var cancelled = false

    func record(items newItems: Int, bytes newBytes: Int64, path: String) {
        lock.lock()
        items += newItems
        bytes += newBytes
        currentPath = path
        lock.unlock()
    }

    func read() -> (items: Int, bytes: Int64, path: String) {
        lock.lock()
        defer { lock.unlock() }
        return (items, bytes, currentPath)
    }

    // Steps and a note are used by quick rescans, which know how many folders they'll recheck.
    private var stepsDone = 0
    private var stepsTotal = 0
    private var note = ""

    func setSteps(total: Int, note newNote: String) {
        lock.lock()
        stepsDone = 0
        stepsTotal = total
        note = newNote
        lock.unlock()
    }

    func setNote(_ newNote: String) {
        lock.lock()
        note = newNote
        stepsTotal = 0
        stepsDone = 0
        lock.unlock()
    }

    func advanceStep() {
        lock.lock()
        stepsDone += 1
        lock.unlock()
    }

    func readSteps() -> (done: Int, total: Int, note: String) {
        lock.lock()
        defer { lock.unlock() }
        return (stepsDone, stepsTotal, note)
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

/// Walks a folder tree in parallel and builds a size tree of FileNodes.
final class DiskScanner: @unchecked Sendable {
    /// Files at least this big get their own node; smaller ones are grouped per folder.
    static let individualFileThreshold: Int64 = 1_000_000

    let progress = ScanProgress()

    private let keys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isVolumeKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]
    private let keySet: Set<URLResourceKey>

    /// Mount points and virtual folders that would double-count or never finish.
    /// /.nofollow and /.resolve are macOS "magic" entries that present the whole disk again under
    /// another path; /.vol is the older version of the same idea.
    static let skipPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/Network",
                                         "/.nofollow", "/.resolve", "/.vol"]
    private var skipPaths: Set<String> { DiskScanner.skipPaths }

    /// Folders this many levels deep or shallower scan their subfolders in parallel.
    private let parallelDepth = 3

    private let counterLock = NSLock()
    private var unreadableCount = 0

    init() {
        keySet = Set(keys)
    }

    var unreadable: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return unreadableCount
    }

    func scan(rootPath: String, displayName: String) -> FileNode {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        let root = scanDirectory(url: url, name: displayName, depth: 0, insidePackage: false, isPackage: values?.isPackage ?? false)
        root.rootPath = rootPath
        return root
    }

    private func markUnreadable() {
        counterLock.lock()
        unreadableCount += 1
        counterLock.unlock()
    }

    private struct PendingDirectory {
        let url: URL
        let name: String
        let isPackage: Bool
    }

    /// Collects results from parallel workers.
    private final class ResultSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [FileNode?]

        init(count: Int) {
            slots = Array(repeating: nil, count: count)
        }

        func set(_ index: Int, _ node: FileNode) {
            lock.lock()
            slots[index] = node
            lock.unlock()
        }

        var nodes: [FileNode] {
            lock.lock()
            defer { lock.unlock() }
            return slots.compactMap { $0 }
        }
    }

    private func scanDirectory(url: URL, name: String, depth: Int, insidePackage: Bool, isPackage: Bool) -> FileNode {
        let node = FileNode(name: name, kind: .directory)
        node.isPackage = isPackage
        node.insidePackage = insidePackage
        fill(node, url: url, depth: depth, keep: [:])
        return node
    }

    /// Re-reads one folder of an existing tree and applies the size change to every folder above it.
    /// With `deep`, everything inside is scanned again. Otherwise subfolders that are still there are
    /// kept as they are, because the change log reports changes inside them separately.
    func refresh(_ node: FileNode, deep: Bool) {
        guard node.isDirectory else { return }
        let oldSize = node.size
        let oldCount = node.itemCount
        var keep: [String: FileNode] = [:]
        if !deep {
            for child in node.children where child.kind == .directory {
                keep[child.name] = child
            }
        }
        fill(node, url: URL(fileURLWithPath: node.path, isDirectory: true), depth: 1, keep: keep)
        progress.advanceStep()

        let sizeChange = node.size - oldSize
        let countChange = node.itemCount - oldCount
        var current = node.parent
        while let ancestor = current {
            ancestor.size += sizeChange
            ancestor.itemCount += countChange
            ancestor.children.sort { $0.size > $1.size }
            current = ancestor.parent
        }
    }

    /// Lists a folder and rebuilds `node`'s contents. Subfolders found in `keep` are reused instead of rescanned.
    private func fill(_ node: FileNode, url: URL, depth: Int, keep: [String: FileNode]) {
        if progress.isCancelled { return }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            node.unreadable = true
            node.children = []
            node.size = 0
            node.itemCount = 0
            markUnreadable()
            return
        }
        node.unreadable = false

        let childInsidePackage = node.insidePackage || node.isPackage
        var reused: [FileNode] = []
        var pending: [PendingDirectory] = []
        var files: [FileNode] = []
        var smallCount = 0
        var smallBytes: Int64 = 0
        var fileBytes: Int64 = 0
        var fileCount = 0

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
            let isLink = values.isSymbolicLink ?? false
            if (values.isDirectory ?? false) && !isLink {
                // Another disk, or one of macOS's own system volumes: skip so nothing is counted twice.
                if values.isVolume ?? false { continue }
                if skipPaths.contains(entry.path) { continue }
                if let existing = keep[entry.lastPathComponent] {
                    reused.append(existing)
                } else {
                    pending.append(PendingDirectory(url: entry, name: entry.lastPathComponent, isPackage: values.isPackage ?? false))
                }
                continue
            }

            let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            let logical = Int64(values.fileSize ?? 0)
            fileBytes += allocated
            fileCount += 1

            if allocated >= DiskScanner.individualFileThreshold || logical >= DiskScanner.individualFileThreshold {
                let file = FileNode(name: entry.lastPathComponent, kind: .file)
                file.size = allocated
                file.logicalSize = logical
                file.itemCount = 1
                file.modified = values.contentModificationDate
                file.insidePackage = childInsidePackage
                files.append(file)
            } else {
                smallCount += 1
                smallBytes += allocated
            }
        }

        progress.record(items: fileCount + pending.count, bytes: fileBytes, path: url.path)

        let subdirectories = pending
        var folders: [FileNode]
        if depth < parallelDepth && subdirectories.count > 1 {
            let slots = ResultSlots(count: subdirectories.count)
            DispatchQueue.concurrentPerform(iterations: subdirectories.count) { index in
                let item = subdirectories[index]
                let child = self.scanDirectory(url: item.url, name: item.name, depth: depth + 1, insidePackage: childInsidePackage, isPackage: item.isPackage)
                slots.set(index, child)
            }
            folders = slots.nodes
        } else {
            folders = []
            folders.reserveCapacity(subdirectories.count)
            for item in subdirectories {
                folders.append(self.scanDirectory(url: item.url, name: item.name, depth: depth + 1, insidePackage: childInsidePackage, isPackage: item.isPackage))
            }
        }

        var children = folders
        children.append(contentsOf: reused)
        children.append(contentsOf: files)
        if smallCount > 0 {
            let group = FileNode(name: smallCount == 1 ? "1 small file" : "\(smallCount) small files", kind: .smallFiles)
            group.size = smallBytes
            group.itemCount = smallCount
            group.insidePackage = childInsidePackage
            children.append(group)
        }

        var total: Int64 = 0
        var count = 0
        for child in children {
            child.parent = node
            total += child.size
            count += child.itemCount
        }
        children.sort { $0.size > $1.size }
        node.children = children
        node.size = total
        node.itemCount = count
    }
}
