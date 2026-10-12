import Foundation
import AppKit

/// One thing a cleanup would move to the Trash.
struct CleanEntry: Hashable {
    let path: String
    let name: String
    let bytes: Int64
}

/// One line in Quick Clean: a kind of routine cleanup and everything it covers.
struct CleanItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var entries: [CleanEntry]
    /// Ticked unless you untick it. Off for things that need a moment's thought.
    let defaultOn: Bool
    var note: String?

    var bytes: Int64 {
        var total: Int64 = 0
        for entry in entries { total += entry.bytes }
        return total
    }
}

struct CleanSurvey {
    let items: [CleanItem]
    let trash: Int64
}

/// Apps open right now, so their caches are left alone.
struct RunningSnapshot {
    let ids: [String]
    let names: Set<String>

    @MainActor
    static func now() -> RunningSnapshot {
        var ids: [String] = []
        var names: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier?.lowercased() {
                ids.append(id)
                let parts = id.split(separator: ".")
                if parts.count >= 2 { names.insert(String(parts[1])) }
            }
            if let name = app.localizedName?.lowercased() { names.insert(name) }
        }
        return RunningSnapshot(ids: ids, names: names)
    }

    func isRunning(_ entry: String) -> Bool {
        let lower = entry.lowercased()
        if names.contains(lower) { return true }
        return ids.contains { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
    }
}

enum QuickClean {
    /// Caches that belong to macOS itself or are handled by their own line.
    private static let keepCaches: Set<String> = [
        "cloudkit", "familycircle", "geoservices", "metadata", "passkit", "siritts", "colorsync",
        "homebrew", "storeassetd", "familycircled", "nsurlsessiond", "akd", "ctkd", "com.crashlytics",
    ]

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// Looks at every cleanup and measures it. Runs off the main thread.
    static func survey(home: String, running: RunningSnapshot) -> [CleanItem] {
        let library = home + "/Library"
        var items: [CleanItem] = []

        // App caches
        let caches = children(of: library + "/Caches") { name in
            let lower = name.lowercased()
            if lower.hasPrefix("com.apple.") || lower.hasPrefix(".") || keepCaches.contains(lower) { return false }
            return !running.isRunning(name)
        }
        items.append(CleanItem(id: "caches", title: "App caches",
                               detail: "Temporary files apps keep to load faster. They rebuild them as needed. Apps that are open are skipped.",
                               symbol: "shippingbox.fill", entries: caches, defaultOn: true))

        // Logs
        items.append(CleanItem(id: "logs", title: "Logs and crash reports",
                               detail: "Records apps write about what they did. Only useful when troubleshooting.",
                               symbol: "doc.text.fill", entries: children(of: library + "/Logs"), defaultOn: true))

        // Homebrew downloads
        let brew = library + "/Caches/Homebrew"
        items.append(CleanItem(id: "homebrew", title: "Homebrew downloads",
                               detail: "Installers Homebrew saved after installing. It downloads again if it needs one.",
                               symbol: "mug.fill", entries: whole(brew, name: "Homebrew downloads"), defaultOn: true))

        // Developer caches
        var developer: [CleanEntry] = []
        developer += whole(home + "/.npm/_cacache", name: "npm cache")
        developer += whole(home + "/.gradle/caches", name: "Gradle caches")
        developer += whole(home + "/.cargo/registry/cache", name: "Cargo downloads")
        items.append(CleanItem(id: "devcaches", title: "Developer tool caches",
                               detail: "Package downloads kept by npm, Gradle and Cargo. They fetch them again when needed.",
                               symbol: "hammer.fill", entries: developer, defaultOn: true))

        // Xcode
        let xcodeOpen = running.ids.contains("com.apple.dt.xcode")
        items.append(CleanItem(id: "xcode", title: "Xcode build data",
                               detail: "DerivedData: intermediate build files. Projects take longer to build the first time afterwards.",
                               symbol: "hammer.circle.fill", entries: children(of: library + "/Developer/Xcode/DerivedData"),
                               defaultOn: true, note: xcodeOpen ? "Xcode is open. Quit it first for the best result." : nil))
        items.append(CleanItem(id: "simulator", title: "Simulator caches",
                               detail: "Caches the iOS Simulator rebuilds when it next starts.",
                               symbol: "iphone", entries: whole(library + "/Developer/CoreSimulator/Caches", name: "Simulator caches"),
                               defaultOn: true))
        var support: [CleanEntry] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            support += children(of: library + "/Developer/Xcode/\(platform) DeviceSupport")
        }
        items.append(CleanItem(id: "devicesupport", title: "Device support files",
                               detail: "Debugging files Xcode copies from each device and OS version you've connected. Xcode copies them again if needed.",
                               symbol: "cable.connector", entries: support, defaultOn: false))

        // Mail
        items.append(CleanItem(id: "mail", title: "Opened Mail attachments",
                               detail: "Copies Mail makes when you open an attachment. The originals stay in your email.",
                               symbol: "paperclip",
                               entries: children(of: library + "/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                               defaultOn: true))

        // Device backups
        items.append(CleanItem(id: "backups", title: "iPhone and iPad backups",
                               detail: "Backups saved by Finder. Remove only ones you don't need, for example if the device backs up to iCloud.",
                               symbol: "iphone.and.arrow.forward", entries: deviceBackups(library: library), defaultOn: false))

        // Installers in Downloads
        let installers = children(of: home + "/Downloads") { name in
            installerExtensions.contains((name as NSString).pathExtension.lowercased())
        }
        items.append(CleanItem(id: "installers", title: "Installers in Downloads",
                               detail: "Disk images and installer packages. The apps they installed stay put.",
                               symbol: "arrow.down.app.fill", entries: installers, defaultOn: false))

        // Leftovers from apps that are gone
        items.append(CleanItem(id: "orphans", title: "Data from deleted apps",
                               detail: "Sandbox folders of apps that aren't installed anymore. Check the list in case you plan to reinstall one.",
                               symbol: "questionmark.folder.fill", entries: orphanContainers(library: library), defaultOn: false))

        return items.filter { $0.bytes > 0 }
    }

    /// Everything inside a folder, each measured, biggest first.
    private static func children(of folder: String, include: (String) -> Bool = { _ in true }) -> [CleanEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let paths = names.filter { $0 != ".DS_Store" && $0 != ".localized" && include($0) }.map { folder + "/" + $0 }
        let sizes = Removals.diskUsage(ofEach: paths)
        return paths.compactMap { path in
            let bytes = sizes[path] ?? 0
            guard bytes > 0 else { return nil }
            return CleanEntry(path: path, name: (path as NSString).lastPathComponent, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// A whole folder as one entry.
    private static func whole(_ path: String, name: String) -> [CleanEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let bytes = Removals.diskUsage(of: path)
        return bytes > 0 ? [CleanEntry(path: path, name: name, bytes: bytes)] : []
    }

    private static func deviceBackups(library: String) -> [CleanEntry] {
        let folder = library + "/Application Support/MobileSync/Backup"
        return children(of: folder).map { entry in
            guard let info = NSDictionary(contentsOfFile: entry.path + "/Info.plist") else { return entry }
            var label = info["Device Name"] as? String ?? info["Display Name"] as? String ?? entry.name
            if let date = info["Last Backup Date"] as? Date {
                label += ", backed up \(Fmt.date(date))"
            }
            return CleanEntry(path: entry.path, name: label, bytes: entry.bytes)
        }
    }

    /// Sandbox folders whose app isn't installed anymore.
    private static func orphanContainers(library: String) -> [CleanEntry] {
        children(of: library + "/Containers") { name in
            let lower = name.lowercased()
            guard lower.contains("."), !lower.hasPrefix("com.apple."), !looksLikeUUID(name) else { return false }
            return AppResolver.shared.owner(of: name) == nil
        }
    }

    private static func looksLikeUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }
}
