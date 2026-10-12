import Foundation
import AppKit
import CoreServices

/// An app in one of the Applications folders.
struct InstalledApp: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    /// Other names the app's files might use: its bundle name and the program inside it.
    let altNames: [String]
    /// Space on disk; -1 while it's still being measured.
    var bytes: Int64
    let lastUsed: Date?
    /// Part of macOS (Safari, Mail…). These can't be removed and macOS would put them back.
    let isProtected: Bool
    let fromAppStore: Bool

    var isMeasured: Bool { bytes >= 0 }
}

/// Something an app left in your Library.
struct Leftover: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// What it is, in plain words: "Settings", "Caches", "App data"…
    let kind: String
    var bytes: Int64
    /// Matched by the app's name rather than its identifier, so worth a second look.
    let byNameOnly: Bool
    /// Outside your home folder. Removing it may need an administrator.
    let systemWide: Bool

    var name: String { (path as NSString).lastPathComponent }
}

/// What the uninstaller found for one app.
struct UninstallSearch {
    let app: InstalledApp
    let leftovers: [Leftover]
    let note: String?
}

enum AppCatalog {
    /// Apps in /Applications and ~/Applications, plus one level of folders inside them.
    static func appPaths(home: String) -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if let inner = try? fm.contentsOfDirectory(atPath: path) {
                    for innerName in inner.sorted() where innerName.hasSuffix(".app") {
                        paths.append(path + "/" + innerName)
                    }
                }
            }
        }
        return paths
    }

    /// True for an app inside /Applications or ~/Applications (directly or one folder down).
    static func isInstalledLocation(_ path: String, home: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        for root in ["/Applications/", home + "/Applications/"] where path.hasPrefix(root) {
            let rest = path.dropFirst(root.count)
            return rest.split(separator: "/").count <= 2
        }
        return false
    }

    private static func volumeID(_ path: String) -> NSObject? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey])
        return values?.volumeIdentifier as? NSObject
    }

    private static let systemVolume: NSObject? = volumeID("/System/Applications")

    /// Reads an app's details. `bytes` is the size if already known, otherwise -1.
    static func describe(path: String, bytes: Int64) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let bundleID = bundle.bundleIdentifier
        let display = info["CFBundleDisplayName"] as? String
        let short = info["CFBundleName"] as? String
        let fileName = (url.lastPathComponent as NSString).deletingPathExtension
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        var altNames: [String] = []
        for candidate in [fileName, display, short, info["CFBundleExecutable"] as? String] {
            if let candidate = candidate, !candidate.isEmpty, !altNames.contains(candidate) {
                altNames.append(candidate)
            }
        }
        let fromAppStore = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        let isApple = bundleID?.lowercased().hasPrefix("com.apple.") ?? false
        var onSystemVolume = false
        if let system = systemVolume, let identifier = volumeID(path) {
            onSystemVolume = identifier.isEqual(system)
        }
        // Apple's own apps that come with macOS. App Store ones (Pages, GarageBand, Xcode…) can go.
        let isDeveloperTool = bundleID?.lowercased().hasPrefix("com.apple.dt.") ?? false
        let isProtected = onSystemVolume || (isApple && !fromAppStore && !isDeveloperTool)

        return InstalledApp(path: path, name: name.isEmpty ? fileName : name, bundleID: bundleID,
                            version: info["CFBundleShortVersionString"] as? String, altNames: altNames,
                            bytes: bytes, lastUsed: lastUsed(path), isProtected: isProtected, fromAppStore: fromAppStore)
    }

    /// When the app was last opened, as recorded by Spotlight.
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Every installed app. Sizes come from the scan when it covers the app; the rest are measured after.
    static func list(home: String, sizeFromScan: (String) -> Int64?) -> [InstalledApp] {
        appPaths(home: home).compactMap { path in
            describe(path: path, bytes: sizeFromScan(path) ?? -1)
        }
    }
}

enum LeftoverFinder {
    /// Names too general to match on their own.
    private static let genericNames: Set<String> = [
        "app", "apps", "helper", "launcher", "updater", "update", "setup", "installer", "electron",
        "google", "microsoft", "adobe", "apple", "mozilla", "java", "python", "node", "data", "cache",
        "caches", "logs", "support", "default", "common", "shared", "plugins", "user",
    ]

    private struct Place {
        let folder: String
        let kind: String
        let systemWide: Bool
        /// Folder or file named after the bundle identifier (or starting with it).
        var byID = true
        /// Preference-style files: "<id>.plist" or "<id>.something.plist".
        var plists = false
        /// Folder named after the app.
        var byName = false
        /// Shared group folders, which put a team prefix in front of the identifier.
        var groups = false
        /// Files named "<id>.savedState", "<id>.binarycookies".
        var suffixes: [String] = []
    }

    /// Finds what an app keeps in the Library folders. `others` are the other installed apps,
    /// so a file that belongs to a different app (even one from the same developer) is never matched.
    static func find(for app: InstalledApp, others: [InstalledApp], home: String) -> [Leftover] {
        guard let rawID = app.bundleID, !app.isProtected else { return [] }
        let id = rawID.lowercased()
        // Another copy of the same app is installed: its data is still in use.
        if others.contains(where: { $0.bundleID?.lowercased() == id }) { return [] }

        let otherIDs = others.compactMap { $0.bundleID?.lowercased() }.filter { $0 != id }
        let otherNames = Set(others.flatMap { [$0.name] + $0.altNames }.map { $0.lowercased() })
        let names = Set(([app.name] + app.altNames).map { $0.lowercased() })
            .filter { $0.count >= 3 && !genericNames.contains($0) && !otherNames.contains($0) }
        // A short identifier like "com.foo" would match too much by prefix.
        let allowPrefix = id.split(separator: ".").count >= 3

        let library = home + "/Library"
        let places: [Place] = [
            Place(folder: library + "/Containers", kind: "App data", systemWide: false),
            Place(folder: library + "/Group Containers", kind: "Shared app data", systemWide: false, byID: false, groups: true),
            Place(folder: library + "/Application Support", kind: "App data", systemWide: false, byName: true),
            Place(folder: library + "/Caches", kind: "Caches", systemWide: false, byName: true),
            Place(folder: library + "/Preferences", kind: "Settings", systemWide: false, byID: false, plists: true),
            Place(folder: library + "/Preferences/ByHost", kind: "Settings", systemWide: false, byID: false, plists: true),
            Place(folder: library + "/Saved Application State", kind: "Window state", systemWide: false, byID: false, suffixes: [".savedstate"]),
            Place(folder: library + "/HTTPStorages", kind: "Web data", systemWide: false, suffixes: [".binarycookies"]),
            Place(folder: library + "/WebKit", kind: "Web data", systemWide: false),
            Place(folder: library + "/Cookies", kind: "Cookies", systemWide: false, byID: false, suffixes: [".binarycookies"]),
            Place(folder: library + "/Logs", kind: "Logs", systemWide: false, byName: true),
            Place(folder: library + "/LaunchAgents", kind: "Starts at login", systemWide: false, byID: false, plists: true),
            Place(folder: library + "/Application Scripts", kind: "Scripts", systemWide: false),
            Place(folder: "/Library/Application Support", kind: "App data", systemWide: true, byName: true),
            Place(folder: "/Library/Caches", kind: "Caches", systemWide: true),
            Place(folder: "/Library/Preferences", kind: "Settings", systemWide: true, byID: false, plists: true),
            Place(folder: "/Library/LaunchAgents", kind: "Starts at login", systemWide: true, byID: false, plists: true),
            Place(folder: "/Library/LaunchDaemons", kind: "Background service", systemWide: true, byID: false, plists: true),
            Place(folder: "/Library/PrivilegedHelperTools", kind: "Helper tool", systemWide: true),
        ]

        let fm = FileManager.default
        var found: [Leftover] = []
        var seen: Set<String> = []
        for place in places {
            guard let entries = try? fm.contentsOfDirectory(atPath: place.folder) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                guard let match = matches(lower, place: place, id: id, names: names, allowPrefix: allowPrefix),
                      !belongsToOther(lower, id: id, otherIDs: otherIDs) else { continue }
                let path = place.folder + "/" + entry
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                found.append(Leftover(path: path, kind: place.kind, bytes: -1, byNameOnly: match == .name,
                                      systemWide: place.systemWide))
            }
        }
        return found
    }

    private enum Match { case id, name }

    private static func matches(_ entry: String, place: Place, id: String, names: Set<String>, allowPrefix: Bool) -> Match? {
        if place.byID {
            if entry == id { return .id }
            if allowPrefix && entry.hasPrefix(id + ".") { return .id }
        }
        if place.plists {
            if entry == id + ".plist" { return .id }
            if allowPrefix && entry.hasPrefix(id + ".") && entry.hasSuffix(".plist") { return .id }
        }
        for suffix in place.suffixes where entry == id + suffix {
            return .id
        }
        if place.groups {
            // "TEAMID.com.foo.app", "group.com.foo.app", "com.foo.app.shared"
            if entry == id || entry.hasSuffix("." + id) { return .id }
            if allowPrefix && (entry.hasPrefix(id + ".") || entry.contains("." + id + ".")) { return .id }
        }
        if place.byName && names.contains(entry) { return .name }
        return nil
    }

    /// True when the entry is named after a different installed app with a longer, more specific identifier
    /// (so "com.foo.app.pro" data isn't taken when removing "com.foo.app").
    private static func belongsToOther(_ entry: String, id: String, otherIDs: [String]) -> Bool {
        for other in otherIDs where other.count > id.count && other.hasPrefix(id + ".") {
            if entry == other || entry.hasPrefix(other + ".") || entry.hasSuffix("." + other)
                || entry.contains("." + other + ".") {
                return true
            }
        }
        return false
    }
}

enum RunningApps {
    static func isRunning(_ app: InstalledApp) -> Bool {
        !instances(of: app).isEmpty
    }

    static func instances(of app: InstalledApp) -> [NSRunningApplication] {
        guard let id = app.bundleID else { return [] }
        let appURL = URL(fileURLWithPath: app.path).standardizedFileURL
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { running in
            guard let url = running.bundleURL?.standardizedFileURL else { return true }
            return url == appURL
        }
    }

    static func quit(_ app: InstalledApp) {
        for instance in instances(of: app) {
            instance.terminate()
        }
    }
}
