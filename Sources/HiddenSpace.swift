import Foundation

/// One piece of the "System & hidden" space.
struct HiddenPart: Identifiable {
    enum Kind {
        case swap
        case startup
        case snapshotsAndProtected
        case unknown
    }

    let kind: Kind
    let title: String
    let detail: String
    let bytes: Int64
    var id: String { title }
}

/// Space on the disk that a scan can't see as files, split into the parts macOS can report.
struct HiddenSpace {
    var total: Int64
    var parts: [HiddenPart]
    /// Dates of the local Time Machine snapshots on the startup disk, newest first.
    var snapshotDates: [Date]
    /// Space macOS can free on its own when it needs room.
    var purgeable: Int64
}

enum HiddenSpaceAnalyzer {
    /// Runs the macOS tools (diskutil, tmutil) that describe the disk. Takes a second or two.
    static func analyze(scanned: Int64, volume: VolumeInfo, unreadableFolders: Int) -> HiddenSpace {
        let total = max(0, volume.used - scanned)
        let snapshots = localSnapshotDates()
        var parts: [HiddenPart] = []

        if let roles = volumeRoles() {
            let swap = roles["VM"] ?? 0
            let startup = (roles["Preboot"] ?? 0) + (roles["Recovery"] ?? 0) + (roles["Update"] ?? 0)
            if swap > 0 {
                parts.append(HiddenPart(kind: .swap, title: "Swap and sleep image",
                                        detail: "Memory macOS moves to the disk when RAM fills up, plus the copy of memory it keeps for sleep. It shrinks after a restart.",
                                        bytes: swap))
            }
            if startup > 0 {
                parts.append(HiddenPart(kind: .startup, title: "Startup and recovery",
                                        detail: "Files macOS needs to start up, install updates and reinstall itself. macOS manages these.",
                                        bytes: startup))
            }
            let rest = max(0, total - swap - startup)
            parts.append(HiddenPart(kind: .snapshotsAndProtected,
                                    title: "Snapshots, protected folders and system data",
                                    detail: restDetail(snapshots: snapshots.count, unreadable: unreadableFolders),
                                    bytes: rest))
        } else {
            parts.append(HiddenPart(kind: .unknown, title: "System and hidden data",
                                    detail: "macOS didn't report how this space splits up. It includes swap, startup files, local Time Machine snapshots and folders DiskMap isn't allowed to read.",
                                    bytes: total))
        }

        parts.sort { $0.bytes > $1.bytes }
        return HiddenSpace(total: total, parts: parts, snapshotDates: snapshots, purgeable: volume.purgeable)
    }

    private static func restDetail(snapshots: Int, unreadable: Int) -> String {
        var pieces: [String] = []
        if snapshots > 0 {
            pieces.append("\(snapshots) local Time Machine \(snapshots == 1 ? "snapshot" : "snapshots"), which keep deleted and changed files until macOS needs the space")
        } else {
            pieces.append("snapshots macOS takes before updates")
        }
        if unreadable > 0 {
            pieces.append("\(Fmt.count(unreadable)) \(unreadable == 1 ? "folder" : "folders") DiskMap isn't allowed to read")
        }
        pieces.append("space the file system keeps for its own records")
        return "Includes " + pieces.joined(separator: ", ") + "."
    }

    // MARK: diskutil

    /// Space used by each kind of volume ("System", "Data", "VM", "Preboot"…) in the startup disk's container.
    static func volumeRoles() -> [String: Int64]? {
        guard let infoData = run("/usr/sbin/diskutil", ["info", "-plist", "/"]),
              let info = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let container = info["APFSContainerReference"] as? String,
              let listData = run("/usr/sbin/diskutil", ["apfs", "list", "-plist", container]),
              let list = try? PropertyListSerialization.propertyList(from: listData, options: [], format: nil) as? [String: Any],
              let containers = list["Containers"] as? [[String: Any]],
              let match = containers.first(where: { ($0["ContainerReference"] as? String) == container }) ?? containers.first,
              let volumes = match["Volumes"] as? [[String: Any]] else { return nil }

        var roles: [String: Int64] = [:]
        for volume in volumes {
            let inUse = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            let role = (volume["Roles"] as? [String])?.first ?? "None"
            roles[role, default: 0] += inUse
        }
        return roles
    }

    // MARK: Time Machine

    /// Local snapshots look like "com.apple.TimeMachine.2026-10-11-101530.local".
    static func localSnapshotDates() -> [Date] {
        guard let data = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        var dates: [Date] = []
        for line in text.split(separator: "\n") {
            guard line.contains("com.apple.TimeMachine.") else { continue }
            let parts = line.components(separatedBy: "com.apple.TimeMachine.")
            guard parts.count > 1 else { continue }
            let stamp = String(parts[1].prefix(17))
            if let date = formatter.date(from: stamp) {
                dates.append(date)
            }
        }
        return dates.sorted(by: >)
    }

    /// Removes every local Time Machine snapshot on the startup disk. macOS asks for an administrator password.
    /// Backups on a Time Machine disk aren't touched. Returns an explanation if it didn't work.
    static func removeLocalSnapshots() -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "do shell script \"/usr/bin/tmutil deletelocalsnapshots /\" with administrator privileges")
        _ = script?.executeAndReturnError(&error)
        guard let error = error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -128 { return "" }
        let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
        return "The snapshots couldn't be removed: \(message)"
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
