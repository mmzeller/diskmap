import Foundation
import AppKit
import UserNotifications

// MARK: - Settings

enum WatchFrequency: String, CaseIterable, Identifiable {
    case off
    case daily
    case weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        }
    }
}

/// UserDefaults keys shared by the app and the background check (same app, same settings).
enum WatchKeys {
    static let frequency = "watchFrequency"
    static let thresholdGB = "watchThresholdGB"
    static let lowSpace = "watchLowSpace"
    static let menuBar = "showMenuBar"
    static let lastCheck = "watchLastCheck"
    static let lastSummary = "watchLastSummary"
    static let notifiedBaseline = "watchNotifiedBaseline"
    static let notifiedLevel = "watchNotifiedLevel"
    static let lastLowSpaceNotice = "watchLastLowSpaceNotice"
}

struct WatchSettings {
    var frequency: WatchFrequency
    var thresholdGB: Int
    var lowSpace: Bool

    static var current: WatchSettings {
        let defaults = UserDefaults.standard
        let frequency = WatchFrequency(rawValue: defaults.string(forKey: WatchKeys.frequency) ?? "") ?? .off
        let threshold = defaults.object(forKey: WatchKeys.thresholdGB) as? Int ?? 5
        let lowSpace = defaults.object(forKey: WatchKeys.lowSpace) as? Bool ?? true
        return WatchSettings(frequency: frequency, thresholdGB: max(1, threshold), lowSpace: lowSpace)
    }

    static func recordCheck(_ summary: String) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: WatchKeys.lastCheck)
        defaults.set(summary, forKey: WatchKeys.lastSummary)
        defaults.synchronize()
    }
}

// MARK: - Schedule

/// Runs DiskMap's background check on a schedule, through a LaunchAgent in ~/Library/LaunchAgents.
enum WatchAgent {
    static let label = "io.github.mmzeller.DiskMap.watch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Returns an explanation if something went wrong, or nil on success.
    static func install(frequency: WatchFrequency) -> String? {
        guard let executable = Bundle.main.executablePath else {
            return "DiskMap couldn't find its own program file."
        }
        // Around 12:40 pm, when most Macs are awake. If the Mac is asleep, macOS runs it after it wakes.
        var when: [String: Int] = ["Hour": 12, "Minute": 41]
        if frequency == .weekly {
            when["Weekday"] = 1
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--background-check"],
            "StartCalendarInterval": when,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "Couldn't save the schedule: \(error.localizedDescription)"
        }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return status == 0 ? nil : "macOS didn't accept the schedule (launchctl error \(status))."
    }

    static func remove() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// If checks are on but the schedule points at another copy of DiskMap (or is missing), fix it.
    static func ensureCurrent() {
        let frequency = WatchSettings.current.frequency
        guard frequency != .off, let executable = Bundle.main.executablePath else { return }
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let arguments = plist["ProgramArguments"] as? [String],
           arguments.first == executable {
            return
        }
        _ = install(frequency: frequency)
    }

    /// Starts a check right away, in the background, exactly as the schedule would.
    @discardableResult
    static func runNow() -> Bool {
        launchctl(["kickstart", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    /// Posts a notification and waits until macOS has accepted it, so a background run can exit safely.
    static func postAndWait(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "diskmap-\(UUID().uuidString)", content: content, trigger: nil)
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 15)
    }
}

extension Notification.Name {
    static let diskMapShowGrowth = Notification.Name("DiskMapShowGrowth")
}

/// Handles clicks on DiskMap's notifications: open the app on What Grew.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    private static let lock = NSLock()
    private static var pendingGrowth = false

    /// True once if a notification click asked for What Grew before the scan was on screen.
    static func takePendingGrowth() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = pendingGrowth
        pendingGrowth = false
        return pending
    }

    private static func requestGrowth() {
        lock.lock()
        pendingGrowth = true
        lock.unlock()
        NotificationCenter.default.post(name: .diskMapShowGrowth, object: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        NotificationHandler.requestGrowth()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - The check itself

/// What runs when macOS starts DiskMap with --background-check: update the saved scan,
/// compare it with your last scan, and notify if growth crossed your limit or the disk is nearly full.
enum BackgroundCheck {
    static func run() -> Int32 {
        let settings = WatchSettings.current
        guard settings.frequency != .off else { return 0 }
        guard let info = ScanCache.loadInfo(), let saved = try? ScanCache.loadTree(info: info) else {
            WatchSettings.recordCheck("No saved scan yet. Open DiskMap and scan once.")
            return 0
        }

        let path = info.rootPath
        let started = Date()
        let scanner = DiskScanner()
        let newEventID = ChangeTracker.currentEventID()
        let database = ChangeTracker.databaseID(for: path)

        var tree = saved
        var unreadable = info.unreadable
        var updated = false
        if let eventID = info.eventID, let savedDatabase = info.eventDatabase, savedDatabase == database,
           let changes = ChangeTracker.changes(under: path, since: eventID),
           Rescanner.update(root: saved, rootPath: path, changes: changes, scanner: scanner) {
            updated = true
        }
        if !updated {
            tree = scanner.scan(rootPath: path, displayName: info.displayName)
            unreadable = scanner.unreadable
        }

        // Keep your last scan as the comparison point; only the saved tree is refreshed.
        let baseline = Scanning.finishAutomatic(root: tree, path: path, name: info.displayName, started: started,
                                                unreadable: unreadable, eventID: newEventID, database: database)

        var summary = "Checked \(Fmt.dateTime(Date())). "
        var notified = false
        let limit = Int64(settings.thresholdGB) * 1_000_000_000

        if let baseline = baseline {
            let growth = tree.size - baseline.total
            summary += "\(Fmt.signedBytes(growth)) since your scan \(Fmt.relative(baseline.date))."

            // Alert once per limit crossed (5 GB, then 10 GB, …) until you scan again yourself.
            let defaults = UserDefaults.standard
            let baselineKey = baseline.date.timeIntervalSince1970
            var level = defaults.integer(forKey: WatchKeys.notifiedLevel)
            if defaults.double(forKey: WatchKeys.notifiedBaseline) != baselineKey {
                level = 0
            }
            let newLevel = growth > 0 ? Int(growth / limit) : 0
            if newLevel > level {
                let explainer = Explainer()
                let report = History.compare(old: baseline, root: tree) { node in
                    if node.isPackage { return true }
                    if let explanation = explainer.explain(node) { return !explanation.isGroup }
                    return false
                }
                var body = "Since your scan \(Fmt.relative(baseline.date))."
                if let top = report.items.first {
                    let name = explainer.explain(top.node)?.title ?? top.node.name
                    body += " Biggest change: \(name) (\(Fmt.signedBytes(top.delta)))."
                }
                body += " Click to see what grew."
                Notifier.postAndWait(title: "Your disk usage grew by \(Fmt.bytes(growth))", body: body)
                defaults.set(newLevel, forKey: WatchKeys.notifiedLevel)
                defaults.set(baselineKey, forKey: WatchKeys.notifiedBaseline)
                notified = true
            } else if growth < limit {
                summary += " Nothing over your \(settings.thresholdGB) GB limit."
            }
        } else {
            summary += "Saved this as the starting point for future checks."
        }

        if settings.lowSpace, let volume = VolumeInfo.forPath(path), volume.total > 0 {
            let freeShare = Double(volume.availableForImportantUsage) / Double(volume.total)
            let defaults = UserDefaults.standard
            let lastNotice = defaults.double(forKey: WatchKeys.lastLowSpaceNotice)
            let threeDays: TimeInterval = 3 * 24 * 3600
            if freeShare < 0.10 && Date().timeIntervalSince1970 - lastNotice > threeDays {
                Notifier.postAndWait(title: "\(volume.name) is almost full",
                                     body: "Only \(Fmt.bytes(volume.availableForImportantUsage)) free. DiskMap's Cleanup Ideas can help make room.")
                defaults.set(Date().timeIntervalSince1970, forKey: WatchKeys.lastLowSpaceNotice)
                notified = true
            }
        }

        if notified { summary += " Sent a notification." }
        WatchSettings.recordCheck(summary)
        return 0
    }
}
