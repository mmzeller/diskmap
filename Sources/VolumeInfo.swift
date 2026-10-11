import Foundation

/// Capacity numbers for the disk a path lives on.
struct VolumeInfo {
    let name: String
    let total: Int64
    let available: Int64
    let availableForImportantUsage: Int64

    var used: Int64 { max(0, total - available) }

    /// Space macOS can free on its own (cached iCloud files, old snapshots and so on).
    var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else {
            return nil
        }
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        return VolumeInfo(
            name: values.volumeLocalizedName ?? "Disk",
            total: Int64(total),
            available: available,
            availableForImportantUsage: max(important, available)
        )
    }
}

enum Permissions {
    /// macOS doesn't offer a direct check, so this tries to open files only Full Disk Access can read.
    static func hasFullDiskAccess() -> Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        if let handle = FileHandle(forReadingAtPath: probe) {
            try? handle.close()
            return true
        }
        let safari = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari").path
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }
}
