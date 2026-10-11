import Foundation

/// Sizes of every folder and file of 5 MB or more from one scan, saved so the next scan can compare.
struct Snapshot: Codable {
    var rootPath: String
    var date: Date
    var total: Int64
    var sizes: [String: Int64]
}

struct HistoryPoint: Codable, Identifiable {
    var rootPath: String
    var date: Date
    var total: Int64
    var id: Date { date }
}

struct GrowthItem: Identifiable {
    let id = UUID()
    let node: FileNode
    let oldSize: Int64
    let newSize: Int64
    let isNew: Bool
    var delta: Int64 { newSize - oldSize }
}

struct GrowthReport {
    let previousDate: Date
    let previousTotal: Int64
    let currentTotal: Int64
    var items: [GrowthItem]
}

enum History {
    static let minRecordedSize: Int64 = 5_000_000
    static let minReportedGrowth: Int64 = 100_000_000

    static var folder: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskMap", isDirectory: true)
    }

    private static func fileKey(_ rootPath: String) -> String {
        if rootPath == "/" { return "disk" }
        return String(rootPath.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "_"
        })
    }

    private static func snapshotURL(_ rootPath: String) -> URL {
        folder.appendingPathComponent("snapshot-\(fileKey(rootPath)).json")
    }

    private static var historyURL: URL {
        folder.appendingPathComponent("history.json")
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

    static func makeSnapshot(root: FileNode, rootPath: String, date: Date) -> Snapshot {
        var sizes: [String: Int64] = [:]

        func walk(_ node: FileNode, _ relativePath: String) {
            sizes[relativePath] = node.size
            for child in node.children {
                if child.size < minRecordedSize { break }
                if child.kind == .smallFiles { continue }
                walk(child, relativePath.isEmpty ? child.name : relativePath + "/" + child.name)
            }
        }

        walk(root, "")
        return Snapshot(rootPath: rootPath, date: date, total: root.size, sizes: sizes)
    }

    static func load(_ rootPath: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(rootPath)) else { return nil }
        return try? decoder().decode(Snapshot.self, from: data)
    }

    private static func previousURL(_ rootPath: String) -> URL {
        folder.appendingPathComponent("snapshot-\(fileKey(rootPath))-previous.json")
    }

    /// Saves the new snapshot and keeps the one before it, so a reopened scan can still show what grew.
    static func save(_ snapshot: Snapshot) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let current = snapshotURL(snapshot.rootPath)
            if fm.fileExists(atPath: current.path) {
                let previous = previousURL(snapshot.rootPath)
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: current, to: previous)
            }
            let data = try encoder().encode(snapshot)
            try data.write(to: current, options: .atomic)
        } catch {
            // History is a nice-to-have; a failed save shouldn't interrupt anything.
        }
    }

    /// The snapshot from the scan before the latest one.
    static func loadPrevious(_ rootPath: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: previousURL(rootPath)) else { return nil }
        return try? decoder().decode(Snapshot.self, from: data)
    }

    static func loadPoints() -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? decoder().decode([HistoryPoint].self, from: data)) ?? []
    }

    static func record(_ point: HistoryPoint) {
        var points = loadPoints()
        points.append(point)
        if points.count > 500 { points.removeFirst(points.count - 500) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder().encode(points)
            try data.write(to: historyURL, options: .atomic)
        } catch {
        }
    }

    static func points(for rootPath: String) -> [HistoryPoint] {
        loadPoints().filter { $0.rootPath == rootPath }
    }

    /// Finds what grew since the old snapshot, pointing at the most specific folders or files responsible.
    /// `isUnit` marks items to report as a whole without looking inside (a website's data, an app, a cache).
    static func compare(old: Snapshot, root: FileNode, isUnit: (FileNode) -> Bool) -> GrowthReport {
        var items: [GrowthItem] = []

        // Returns how much growth inside this subtree has already been reported.
        func visit(_ node: FileNode, _ relativePath: String, isRoot: Bool) -> Int64 {
            if !isRoot && isUnit(node) {
                let previous = old.sizes[relativePath]
                let growth = node.size - (previous ?? 0)
                guard growth >= minReportedGrowth else { return 0 }
                items.append(GrowthItem(node: node, oldSize: previous ?? 0, newSize: node.size, isNew: previous == nil))
                return growth
            }
            let mark = items.count
            var reportedBelow: Int64 = 0
            for child in node.children {
                if child.size < minReportedGrowth { break }
                if child.kind == .smallFiles { continue }
                let childPath = relativePath.isEmpty ? child.name : relativePath + "/" + child.name
                reportedBelow += visit(child, childPath, isRoot: false)
            }
            let previous = old.sizes[relativePath]
            let growth = node.size - (previous ?? 0)
            if !isRoot && growth >= minReportedGrowth && Double(reportedBelow) < Double(growth) * 0.7 {
                // The children don't explain most of this growth, so report this item as a whole.
                items.removeSubrange(mark..<items.count)
                items.append(GrowthItem(node: node, oldSize: previous ?? 0, newSize: node.size, isNew: previous == nil))
                return growth
            }
            return reportedBelow
        }

        _ = visit(root, "", isRoot: true)
        items.sort { $0.delta > $1.delta }
        return GrowthReport(previousDate: old.date, previousTotal: old.total, currentTotal: root.size, items: Array(items.prefix(60)))
    }
}
