import Foundation
import CoreServices

/// Folders macOS's file system change log says were touched since a given point.
/// The value is true when everything inside the folder must be rescanned, not just the folder itself.
struct ChangeSet {
    var folders: [String: Bool]
}

/// Gathers events delivered by FSEvents on a background queue.
private final class ChangeCollector {
    let lock = NSLock()
    var folders: [String: Bool] = [:]
    var historyDone = false
    var unusable = false
    let finished = DispatchSemaphore(value: 0)
}

/// Reads the change log macOS keeps for every disk (the same one Time Machine and Spotlight use).
enum ChangeTracker {
    /// A position in the change log. Saved with each scan so the next rescan can ask "what changed since?".
    static func currentEventID() -> UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }

    /// Identifies the change log of the disk holding `path`. If it no longer matches the one saved
    /// with a scan, the log was reset and the saved position means nothing.
    static func databaseID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let device: CFUUID? = FSEventsCopyUUIDForDevice(info.st_dev)
        guard let uuid = device else { return nil }
        let text: CFString? = CFUUIDCreateString(kCFAllocatorDefault, uuid)
        guard let string = text else { return nil }
        return string as String
    }

    /// Replays the change log for `rootPath` since `eventID`. Returns nil when the log can't answer
    /// reliably (reset, wrapped, or too slow), in which case a full scan is the safe choice.
    static func changes(under rootPath: String, since eventID: UInt64, timeout: TimeInterval = 120) -> ChangeSet? {
        guard eventID > 0, eventID <= currentEventID() else { return nil }

        let collector = ChangeCollector()
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let collector = Unmanaged<ChangeCollector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            let historyDoneFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            let unusableFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
            let deepFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

            collector.lock.lock()
            defer { collector.lock.unlock() }
            for index in 0..<count {
                let flags = eventFlags[index]
                if flags & historyDoneFlag != 0 {
                    if !collector.historyDone {
                        collector.historyDone = true
                        collector.finished.signal()
                    }
                    continue
                }
                // Only the replayed history matters; ignore anything that arrives live afterwards.
                if collector.historyDone { continue }
                if flags & unusableFlags != 0 {
                    collector.unusable = true
                }
                guard index < paths.count, let path = paths[index] as? String else { continue }
                let deep = flags & deepFlag != 0
                let already = collector.folders[path] ?? false
                collector.folders[path] = already || deep
            }
        }

        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [rootPath] as CFArray,
                                               FSEventStreamEventId(eventID), 0.2, createFlags) else {
            return nil
        }
        let queue = DispatchQueue(label: "DiskMap.changes")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        let waited = collector.finished.wait(timeout: .now() + timeout)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        collector.lock.lock()
        defer { collector.lock.unlock() }
        guard waited == .success, collector.historyDone, !collector.unusable else { return nil }
        return ChangeSet(folders: collector.folders)
    }

    /// Change log paths can end in a slash, and changes on the data volume may be reported
    /// under /System/Volumes/Data. Both are mapped to the paths the scan uses.
    static func normalize(_ raw: String) -> String {
        var path = raw
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let dataVolume = "/System/Volumes/Data"
        if path == dataVolume { return "/" }
        if path.hasPrefix(dataVolume + "/") {
            path = String(path.dropFirst(dataVolume.count))
        }
        return path
    }
}

/// Brings a saved scan up to date by rechecking only the folders the change log reports.
enum Rescanner {
    /// Past this many changed folders, a full scan is about as fast and simpler.
    static let maxFolders = 60_000

    /// Updates `root` in place. Returns false when a full scan is needed instead.
    static func update(root: FileNode, rootPath: String, changes: ChangeSet, scanner: DiskScanner) -> Bool {
        var folders: [String: Bool] = [:]
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        for (raw, deep) in changes.folders {
            let path = normalize(raw)
            guard path == rootPath || path.hasPrefix(prefix) else { continue }
            if isSkipped(path) { continue }
            folders[path] = (folders[path] ?? false) || deep
        }

        if folders.count > maxFolders { return false }
        if folders[rootPath] == true { return false }

        // Folders inside one that's being rescanned in full don't need their own pass.
        let deepFolders = folders.filter { $0.value }.map { $0.key }
        func coveredByDeep(_ path: String) -> Bool {
            for deep in deepFolders where path != deep && path.hasPrefix(deep == "/" ? "/" : deep + "/") {
                return true
            }
            return false
        }

        // Shallow folders first, so a new subfolder is scanned once by its parent.
        let ordered = folders.keys.filter { !coveredByDeep($0) }.sorted { $0.count < $1.count }
        scanner.progress.setSteps(total: ordered.count,
                                  note: "Rechecking \(Fmt.count(ordered.count)) changed \(ordered.count == 1 ? "folder" : "folders")")
        for path in ordered {
            if scanner.progress.isCancelled { return false }
            guard let node = ScanCache.find(path, in: root), node.isDirectory else {
                // Gone, or new and inside a folder that's being rechecked anyway.
                scanner.progress.advanceStep()
                continue
            }
            scanner.refresh(node, deep: folders[path] ?? false)
        }
        return true
    }

    private static func normalize(_ raw: String) -> String {
        ChangeTracker.normalize(raw)
    }

    private static func isSkipped(_ path: String) -> Bool {
        for skipped in DiskScanner.skipPaths where path == skipped || path.hasPrefix(skipped + "/") {
            return true
        }
        return false
    }
}
