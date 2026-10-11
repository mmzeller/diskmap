import Foundation

enum Safety: Int, Comparable {
    case safe = 0
    case likelySafe = 1
    case review = 2
    case keep = 3
    case system = 4

    static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .safe: return "Safe to delete"
        case .likelySafe: return "Probably safe"
        case .review: return "Check first"
        case .keep: return "Keep"
        case .system: return "Part of macOS"
        }
    }
}

/// A plain-language description of a folder or file and what to do about it.
struct Explanation {
    var title: String
    var detail: String
    var advice: String
    var safety: Safety
    /// Listed in Cleanup Ideas.
    var suggest: Bool
    /// Cleanup Ideas should look inside this folder rather than stop at it.
    var isGroup: Bool

    init(_ title: String, _ detail: String, advice: String, safety: Safety, suggest: Bool? = nil, isGroup: Bool = false) {
        self.title = title
        self.detail = detail
        self.advice = advice
        self.safety = safety
        self.suggest = suggest ?? (safety == .safe || safety == .likelySafe)
        self.isGroup = isGroup
    }
}

/// Knows what common Mac folders are. Used on the main thread only.
final class Explainer {
    let home: String
    private let apps = AppResolver.shared
    private var cache: [ObjectIdentifier: Explanation] = [:]
    private var misses: Set<ObjectIdentifier> = []

    static let cacheNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "cacheddata", "shadercache", "grshadercache",
        "graphitedawncache", "dawncache", "dawngraphitecache", "dawnwebgpucache", "media cache files",
        "media cache", "component_crx_cache", "cachedextensionvsixs", "cachedprofilesdata", "deriveddata",
        "cachestorage",
    ]

    private static let webStorage: [String: (String, String)] = [
        "IndexedDB": ("Site database", "Structured data the website keeps, often so it works offline."),
        "CacheStorage": ("Offline cache", "Copies of pages, images and media saved by the site's offline worker."),
        "LocalStorage": ("Saved site settings", "Small settings and state the website remembers."),
        "SessionStorage": ("Session data", "Temporary data for open tabs."),
        "FileSystem": ("Site file storage", "A private area where web apps can save large files."),
        "ServiceWorkers": ("Offline worker", "Code that lets the website work offline."),
    ]

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
    }

    func reset() {
        cache.removeAll()
        misses.removeAll()
    }

    func explain(_ node: FileNode) -> Explanation? {
        let key = ObjectIdentifier(node)
        if let hit = cache[key] { return hit }
        if misses.contains(key) { return nil }
        let result = compute(node)
        if let found = result {
            cache[key] = found
        } else {
            misses.insert(key)
        }
        return result
    }

    func relative(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // MARK: - Rules

    private func compute(_ node: FileNode) -> Explanation? {
        if node.kind == .smallFiles {
            return Explanation("Small files", "Files under 1 MB in this folder, grouped so the chart stays readable.",
                               advice: "Reveal the folder in Finder to see them one by one.", safety: .review, suggest: false)
        }

        let path = node.path
        let rel = relative(path)
        let parts = rel.split(separator: "/").map(String.init)
        let name = node.name
        let lower = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        let isDir = node.isDirectory
        let bundleLike = isDir && name.filter({ $0 == "." }).count == 1
        let inUserLibrary = parts.count >= 2 && parts[0] == "~" && parts[1] == "Library"

        if let found = systemRule(path) { return found }
        if let found = websiteRule(node, path: path, name: name) { return found }

        // Trash
        if rel == "~/.Trash" {
            return Explanation("Trash", "Files you've already deleted. They keep using space until the Trash is emptied.",
                               advice: "Empty the Trash to get this space back.", safety: .safe)
        }
        if rel.hasPrefix("~/.Trash/") {
            return Explanation("In the Trash", "Already deleted and waiting for the Trash to be emptied.",
                               advice: "Empty the Trash to free this space.", safety: .safe, suggest: false)
        }

        // Libraries and bundles that have their own app
        if ext == "app" && (node.isPackage || bundleLike) {
            if name.hasPrefix("Install macOS") {
                return Explanation("macOS installer", "A full macOS installer app.",
                                   advice: "Only needed to install macOS. Safe to delete afterwards.", safety: .safe)
            }
            let appName = (name as NSString).deletingPathExtension
            return Explanation("App: \(appName)", "An application.",
                               advice: "If you don't use it, move it to the Trash. Some of its data may stay in your Library.",
                               safety: .review, suggest: false)
        }
        if bundleLike || node.isPackage {
            switch ext {
            case "photoslibrary":
                return Explanation("Photos library", "Your photos and videos, managed by the Photos app.",
                                   advice: "Delete photos inside Photos. If you use iCloud Photos, turn on Optimize Mac Storage in Photos → Settings → iCloud.",
                                   safety: .keep, suggest: false)
            case "musiclibrary", "tvlibrary":
                return Explanation("Media library", "Your Music or TV library database.",
                                   advice: "Manage it in the Music or TV app.", safety: .keep, suggest: false)
            case "imovielibrary":
                return Explanation("iMovie library", "Your iMovie projects and their media.",
                                   advice: "In iMovie, choose File → Delete Generated Files to free space without losing projects.",
                                   safety: .review, suggest: true)
            case "fcpbundle":
                return Explanation("Final Cut Pro library", "Your Final Cut Pro projects, media and render files.",
                                   advice: "In Final Cut Pro, select the library and choose File → Delete Generated Library Files.",
                                   safety: .review, suggest: true)
            case "vmwarevm", "pvm", "utm", "vbox":
                return Explanation("Virtual machine", "A whole computer stored as a file, used by a virtualization app.",
                                   advice: "If you don't need it anymore, delete it from the app that runs it.",
                                   safety: .review, suggest: true)
            case "sparsebundle", "sparseimage":
                return Explanation("Disk image", "A virtual disk. It can hold backups or other files.",
                                   advice: "Open it to see what's inside before deleting.", safety: .review, suggest: false)
            default:
                break
            }
        }

        // Your home folder
        if rel == "~/Downloads" {
            return Explanation("Downloads", "Files you've downloaded.",
                               advice: "Installers (.dmg, .pkg) and archives here are usually safe to delete once used.",
                               safety: .review, suggest: false, isGroup: true)
        }
        if rel == "~/Library" {
            return Explanation("Your Library", "Settings and data your apps keep for you.",
                               advice: "Don't clear it out wholesale. The explanations inside show what's safe.",
                               safety: .review, suggest: false, isGroup: true)
        }
        if rel == "~/Library/Mobile Documents" {
            return Explanation("iCloud Drive", "Local copies of your iCloud Drive files.",
                               advice: "Don't delete here: that removes the files from iCloud on every device. To save space, turn on Optimize Mac Storage in System Settings → your name → iCloud → Drive.",
                               safety: .keep, suggest: false)
        }
        if rel == "~/Library/Mail" {
            return Explanation("Mail", "Your email and attachments, managed by the Mail app.",
                               advice: "Delete messages or old mailboxes in Mail.", safety: .keep, suggest: false)
        }
        if lower == "mail downloads" && isDir {
            return Explanation("Mail attachment copies", "Copies of attachments you opened from Mail.",
                               advice: "Safe to delete. The originals stay in your messages.", safety: .safe)
        }
        if rel == "~/Library/Messages" {
            return Explanation("Messages", "Your Messages history and attachments.",
                               advice: "Manage it in the Messages app.", safety: .keep, suggest: false, isGroup: true)
        }
        if rel == "~/Library/Messages/Attachments" {
            return Explanation("Messages attachments", "Photos, videos and files sent and received in Messages.",
                               advice: "Delete large ones in the Messages app or in System Settings → General → Storage → Messages. Deleting files here directly leaves broken attachments.",
                               safety: .review, suggest: true)
        }
        if rel == "~/Library/Metadata/CoreSpotlight" {
            return Explanation("Spotlight index", "The search index for your apps' content.",
                               advice: "macOS manages this. Leave it alone.", safety: .system, suggest: false)
        }

        // ~/Library/Caches
        if rel == "~/Library/Caches" {
            return Explanation("App caches", "Temporary files apps keep so they run faster. Apps rebuild them as needed.",
                               advice: "Each folder inside is one app's cache. Quit an app before deleting its cache.",
                               safety: .safe, suggest: false, isGroup: true)
        }
        if inUserLibrary && parts.count == 4 && parts[2] == "Caches" {
            if name == "Homebrew" {
                return Explanation("Homebrew download cache", "Old package downloads kept by Homebrew.",
                                   advice: "Run brew cleanup in Terminal, or delete it.", safety: .safe)
            }
            let owner = ownerLabel(name)
            let safety: Safety = name.lowercased().hasPrefix("com.apple.") ? .likelySafe : .safe
            return Explanation("Cache: \(owner)", "Temporary files \(owner) can rebuild.",
                               advice: "Safe to delete. Quit \(owner) first; it may be a little slower the next time it starts.",
                               safety: safety)
        }

        // Developer tools
        if inUserLibrary && parts.count >= 3 && parts[2] == "Developer" {
            if rel == "~/Library/Developer" || rel == "~/Library/Developer/Xcode" {
                return Explanation("Developer tools data", "Files used by Xcode and other developer tools.",
                                   advice: "Look inside: build files and device symbols are safe to clear.",
                                   safety: .review, suggest: false, isGroup: true)
            }
            if rel == "~/Library/Developer/Xcode/DerivedData" {
                return Explanation("Xcode build files", "Intermediate files from building apps in Xcode.",
                                   advice: "Safe to delete. Xcode rebuilds them the next time you build.", safety: .safe)
            }
            if parts.count == 5 && parts[3] == "Xcode" && parts[4].hasSuffix("DeviceSupport") {
                return Explanation("Device debugging files", "Debug symbols Xcode copied from your iPhone or other devices.",
                                   advice: "Safe to delete. Xcode copies them again when a device connects.", safety: .safe)
            }
            if rel == "~/Library/Developer/Xcode/Archives" {
                return Explanation("Xcode archives", "App builds you archived for distribution.",
                                   advice: "Delete old ones from Xcode's Organizer window.", safety: .review, suggest: true)
            }
            if rel == "~/Library/Developer/CoreSimulator" || rel == "~/Library/Developer/CoreSimulator/Devices" {
                return Explanation("iOS Simulators", "Simulated iPhones and iPads used by Xcode.",
                                   advice: "Remove ones you don't need in Xcode → Settings → Platforms, or run xcrun simctl delete unavailable in Terminal.",
                                   safety: .review, suggest: true)
            }
            if rel == "~/Library/Developer/Xcode/UserData/Previews" {
                return Explanation("SwiftUI preview data", "Files Xcode creates to show live previews.",
                                   advice: "Safe to delete.", safety: .safe)
            }
        }

        // App containers: ~/Library/Containers/<bundle id>
        if inUserLibrary && parts.count >= 3 && parts[2] == "Containers" {
            if parts.count == 3 {
                return Explanation("App containers", "Private storage for apps. Each folder inside belongs to one app.",
                                   advice: "Look inside. Leftovers from apps you've deleted are safe to remove.",
                                   safety: .review, suggest: false, isGroup: true)
            }
            if parts.count == 4 {
                return containerRule(id: name)
            }
            if lower == "vms" && rel.contains("/com.docker.docker/") {
                return Explanation("Docker disk image", "The virtual disk holding Docker's images, containers and volumes.",
                                   advice: "In Terminal, run docker system prune to remove unused data, or use Docker Desktop's Troubleshoot → Clean / Purge data.",
                                   safety: .review, suggest: true)
            }
        }

        // Shared app data: ~/Library/Group Containers/<id>
        if inUserLibrary && parts.count >= 3 && parts[2] == "Group Containers" {
            if parts.count == 3 {
                return Explanation("Shared app data", "Data apps share with their helpers and extensions.",
                                   advice: "Look inside. Caches are safe to clear.", safety: .review, suggest: false, isGroup: true)
            }
            if parts.count == 4 {
                return groupContainerRule(id: name)
            }
        }

        // ~/Library/Application Support
        if inUserLibrary && parts.count >= 3 && parts[2] == "Application Support" {
            if parts.count == 3 {
                return Explanation("App support files", "Data apps keep for themselves: settings, databases and downloads.",
                                   advice: "Look inside rather than deleting this folder.", safety: .review, suggest: false, isGroup: true)
            }
            if rel == "~/Library/Application Support/MobileSync" {
                return Explanation("iPhone & iPad sync", "Backups and sync data for your devices.",
                                   advice: "Look inside for old backups.", safety: .review, suggest: false, isGroup: true)
            }
            if rel == "~/Library/Application Support/MobileSync/Backup" {
                return Explanation("iPhone & iPad backups", "Local backups made by Finder. Each folder is one backup.",
                                   advice: "Remove old ones in Finder: select your device in the sidebar, then click Manage Backups.",
                                   safety: .review, suggest: false, isGroup: true)
            }
            if parts.count == 6 && parts[3] == "MobileSync" && parts[4] == "Backup" && isDir {
                let info = Explainer.backupInfo(node.url)
                var title = "Backup of \(info?.device ?? "an iPhone or iPad")"
                if let date = info?.date { title += " (\(Fmt.date(date)))" }
                return Explanation(title, "A full local backup made by Finder.",
                                   advice: "Delete old backups in Finder: select your device in the sidebar, then click Manage Backups. Keep your newest one unless you back up to iCloud.",
                                   safety: .review, suggest: true)
            }
            if rel == "~/Library/Application Support/Steam/steamapps" {
                return Explanation("Steam games", "Games installed through Steam.",
                                   advice: "Uninstall games you don't play from your Steam library.", safety: .review, suggest: true)
            }
            if rel == "~/Library/Application Support/CloudDocs" {
                return Explanation("iCloud Drive sync data", "Information macOS uses to keep iCloud Drive in sync.",
                                   advice: "Leave it alone.", safety: .keep, suggest: false)
            }
            if parts.count == 4 {
                let owner = ownerLabel(name)
                return Explanation("Support files: \(owner)", "Data \(owner) keeps for itself: settings, downloads and databases.",
                                   advice: "Deleting it may reset or break \(owner). Caches inside are safe to clear.",
                                   safety: .review, suggest: false, isGroup: true)
            }
        }

        // Names that mean the same thing anywhere (but never inside an app bundle)
        if !node.insidePackage {
            if lower == "node_modules" && isDir {
                return Explanation("JavaScript packages", "Downloaded packages for a code project.",
                                   advice: "Safe to delete. Run npm install in the project to get them back.", safety: .safe)
            }
            if lower == ".git" && isDir {
                return Explanation("Project history (Git)", "The full version history of a code project.",
                                   advice: "Keep it unless you're deleting the whole project.", safety: .keep, suggest: false)
            }
            if isDir && Explainer.cacheNames.contains(lower) {
                let owner = cacheOwner(parts)
                return Explanation(owner.map { "Cache: \($0)" } ?? "Cache", "Temporary files an app can rebuild.",
                                   advice: "Usually safe to delete. Quit the app that made it first.", safety: .safe)
            }
            if isDir && lower == "service worker" {
                return Explanation("Website offline data", "Offline caches websites saved in this browser.",
                                   advice: "Clear it from the browser's settings, or delete it with the browser closed.",
                                   safety: .likelySafe)
            }
            if isDir && (lower == "logs" || lower == "diagnosticreports") && rel.hasPrefix("~/") {
                return Explanation("Log files", "Records apps and macOS write while they run.",
                                   advice: "Safe to delete.", safety: .likelySafe)
            }
            if isDir && (lower == "tmp" || lower == "temp") && rel.hasPrefix("~/") {
                return Explanation("Temporary files", "Scratch files an app left behind.",
                                   advice: "Usually safe to delete when the app isn't running.", safety: .likelySafe, suggest: false)
            }
        }
        if rel == "~/.npm" {
            return Explanation("npm download cache", "Packages npm downloaded for your code projects.",
                               advice: "Run npm cache clean --force, or delete it.", safety: .safe)
        }
        if rel == "~/.cache" {
            return Explanation("Command-line tool caches", "Caches from tools like pip and other developer utilities.",
                               advice: "Usually safe to delete. Tools download what they need again.", safety: .likelySafe)
        }
        if rel == "~/.docker" {
            return Explanation("Docker settings", "Docker's configuration and some data.",
                               advice: "Manage it with Docker Desktop.", safety: .review, suggest: false)
        }

        // Files by type
        if node.kind == .file {
            if ["dmg", "pkg", "mpkg", "xip", "iso"].contains(ext) {
                return Explanation("Installer or disk image", "A file used to install software.",
                                   advice: "Usually only needed once. After installing, it can go.", safety: .likelySafe)
            }
            if ext == "ipsw" {
                return Explanation("iPhone or iPad software", "A system update Finder downloaded for a device.",
                                   advice: "Safe to delete. Finder downloads it again if needed.", safety: .safe)
            }
            if ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"].contains(ext) {
                return Explanation("Archive", "A compressed bundle of files.",
                                   advice: "If you've already extracted it, the archive can usually go.", safety: .review, suggest: false)
            }
        }
        return nil
    }

    private func systemRule(_ path: String) -> Explanation? {
        func under(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }

        if under("/usr/local") {
            return Explanation("Developer tools", "Command-line tools and packages, often installed by Homebrew on Intel Macs.",
                               advice: "Remove packages with the tool that installed them (for example, brew uninstall).",
                               safety: .review, suggest: false)
        }
        if under("/System") || under("/usr") || under("/bin") || under("/sbin") {
            return Explanation("Part of macOS", "The operating system itself. It's locked and can't be changed.",
                               advice: "Nothing to do here.", safety: .system, suggest: false)
        }
        if under("/private/var/vm") {
            return Explanation("Memory swap", "Space macOS uses as overflow memory and for sleep.",
                               advice: "macOS manages this. Restarting usually shrinks it.", safety: .system, suggest: false)
        }
        if under("/private/var/folders") {
            return Explanation("Temporary files (macOS)", "Per-app temporary files and caches that macOS manages.",
                               advice: "Don't delete these by hand. Restarting your Mac clears much of it.", safety: .system, suggest: false)
        }
        if under("/private/var/log") {
            return Explanation("System logs", "Records macOS keeps while it runs.",
                               advice: "macOS rotates these on its own.", safety: .system, suggest: false)
        }
        if under("/private") {
            return Explanation("System data", "Files macOS uses behind the scenes.",
                               advice: "Leave this to macOS.", safety: .system, suggest: false)
        }
        if under("/.DocumentRevisions-V100") {
            return Explanation("Document version history", "Earlier versions of documents saved by apps that support Versions.",
                               advice: "macOS manages this.", safety: .system, suggest: false)
        }
        if under("/.nofollow") || under("/.resolve") || under("/.vol") {
            return Explanation("Not a real folder", "A special macOS entry that shows the whole disk a second time under another path. Nothing here takes up extra space.",
                               advice: "Leave it alone. Rescan and DiskMap will skip it.", safety: .system, suggest: false)
        }
        if under("/.Spotlight-V100") || under("/.fseventsd") {
            return Explanation("Search index", "Data Spotlight and macOS use to track files.",
                               advice: "macOS manages this.", safety: .system, suggest: false)
        }
        if under("/cores") {
            return Explanation("Crash dumps", "Memory snapshots saved when an app crashed.",
                               advice: "Safe to delete, but it needs an administrator. In Terminal: sudo rm /cores/core.*",
                               safety: .safe)
        }
        if under("/Library/Updates") {
            return Explanation("Downloaded macOS updates", "Updates waiting to be installed.",
                               advice: "macOS removes these after installing.", safety: .system, suggest: false)
        }
        if under("/Library/Caches") {
            return Explanation("Shared caches", "Cache files for all users of this Mac.",
                               advice: "Deleting needs an administrator. macOS and apps rebuild them.", safety: .likelySafe, suggest: false)
        }
        if under("/Library/Logs") {
            return Explanation("Shared logs", "Log files for all users.",
                               advice: "Deleting needs an administrator.", safety: .likelySafe, suggest: false)
        }
        if path == "/Library" {
            return Explanation("Shared Library", "App and system support files for every user of this Mac.",
                               advice: "Look inside rather than deleting anything here.", safety: .review, suggest: false, isGroup: true)
        }
        if path == "/Library/Application Support" {
            return Explanation("Shared app support files", "Data apps keep for every user of this Mac.",
                               advice: "Look inside rather than deleting this folder.", safety: .review, suggest: false, isGroup: true)
        }
        if under("/opt/homebrew") {
            return Explanation("Homebrew packages", "Command-line tools installed with Homebrew.",
                               advice: "Run brew cleanup to remove old versions, or brew uninstall for tools you don't use.",
                               safety: .review, suggest: false)
        }
        if path == "/Applications" {
            return Explanation("Apps", "Applications installed on this Mac.",
                               advice: "Move apps you don't use to the Trash.", safety: .review, suggest: false, isGroup: true)
        }
        if path == "/Users/Shared" {
            return Explanation("Shared folder", "Files available to every user of this Mac.",
                               advice: "Check what's inside before deleting.", safety: .review, suggest: false, isGroup: true)
        }
        return nil
    }

    private func websiteRule(_ node: FileNode, path: String, name: String) -> Explanation? {
        guard path.contains("/WebsiteData") else { return nil }
        let browser = browserName(for: path)

        if name == "WebsiteData" || node.parent?.name == "WebsiteData" {
            return Explanation("Website data (\(browser))",
                               "Data websites saved through \(browser): offline caches, databases and settings. Each folder inside belongs to one site.",
                               advice: "Look inside to see which sites use the most, and remove just those.",
                               safety: .review, suggest: false, isGroup: true)
        }

        if node.isDirectory && node.parent?.parent?.name == "WebsiteData" {
            let decoded = WebsiteOrigins.sites(in: node.url)
            if let site = decoded?.site ?? WebsiteOrigins.hostFromLegacyName(name) {
                let pretty = WebsiteOrigins.pretty(site)
                var detail = "Everything \(pretty) has saved in \(browser): offline copies, caches and site databases."
                if let embedded = decoded?.embedded, !embedded.isEmpty {
                    let list = embedded.prefix(3).map { WebsiteOrigins.pretty($0) }.joined(separator: ", ")
                    detail += " Includes data from content embedded on that site (\(list))."
                }
                return Explanation("\(browser) data for \(pretty)", detail,
                                   advice: "Safe to remove unless \(pretty) is a web app that keeps your only copy of something in the browser. Quit \(browser) first. You may be signed out of \(pretty).",
                                   safety: .likelySafe)
            }
            return Explanation("\(browser) data for one website", "Offline copies, caches and databases saved by a single website.",
                               advice: "Usually safe to remove with \(browser) closed. You may be signed out of that site.",
                               safety: .likelySafe)
        }

        if let piece = Explainer.webStorage[name] {
            return Explanation(piece.0, piece.1, advice: "Remove the whole site folder rather than pieces of it.",
                               safety: .likelySafe, suggest: false)
        }
        return nil
    }

    private func containerRule(id: String) -> Explanation {
        if let owner = apps.owner(of: id) {
            let label = owner.exact ? owner.name : "\(owner.name) (helper)"
            return Explanation("App data: \(label)", "Everything \(owner.name) keeps privately: settings, documents and caches.",
                               advice: "Deleting this resets \(owner.name). Caches inside are safe to clear instead.",
                               safety: .review, suggest: false, isGroup: true)
        }
        if id.lowercased().hasPrefix("com.apple.") {
            return Explanation("macOS feature data", "Used by a built-in part of macOS (\(id)).",
                               advice: "Leave it unless you know exactly what it is.", safety: .keep, suggest: false, isGroup: true)
        }
        if let vendorApp = apps.sameVendorApp(as: id) {
            return Explanation("App data (\(id))", "Belongs to a component from the maker of \(vendorApp).",
                               advice: "Leave it while you still use \(vendorApp).", safety: .review, suggest: false, isGroup: true)
        }
        return Explanation("Leftover: \(id)", "Data from an app that no longer seems to be installed.",
                           advice: "Usually safe to move to the Trash. If you reinstall the app later, it starts fresh.",
                           safety: .likelySafe)
    }

    private func groupContainerRule(id: String) -> Explanation {
        if let first = id.split(separator: ".").first.map(String.init), let vendor = AppResolver.knownTeams[first] {
            return Explanation("Shared data: \(vendor)", "Data \(vendor) apps share with each other.",
                               advice: "Deleting it may reset those apps. Caches inside are safe to clear.",
                               safety: .review, suggest: false, isGroup: true)
        }
        if let owner = apps.owner(of: id) {
            return Explanation("Shared data: \(owner.name)", "Data \(owner.name) shares with its helpers and extensions.",
                               advice: "Deleting this resets \(owner.name). Caches inside are safe to clear.",
                               safety: .review, suggest: false, isGroup: true)
        }
        let lowered = id.lowercased()
        if lowered.hasPrefix("group.com.apple.") || lowered.hasPrefix("com.apple.") {
            return Explanation("macOS shared data", "Data shared between built-in parts of macOS.",
                               advice: "Leave it alone.", safety: .keep, suggest: false, isGroup: true)
        }
        return Explanation("Shared app data (\(id))", "Data shared between an app and its extensions.",
                           advice: "If you've deleted the app this belongs to, it's usually safe to remove.",
                           safety: .review, suggest: false, isGroup: true)
    }

    private func browserName(for path: String) -> String {
        if path.contains("/com.apple.Safari") || path.contains("/Library/Safari") { return "Safari" }
        let components = path.split(separator: "/").map(String.init)
        if let index = components.firstIndex(where: { $0 == "Containers" || $0 == "WebKit" }), index + 1 < components.count {
            let identifier = components[index + 1]
            if identifier != "WebsiteData", let owner = apps.owner(of: identifier) {
                return owner.name
            }
        }
        return "Web view"
    }

    /// Readable name for a folder named after an app or a bundle identifier.
    private func ownerLabel(_ name: String) -> String {
        if name.contains("."), let owner = apps.owner(of: name) { return owner.name }
        return name
    }

    /// Which app a cache folder belongs to, judged from where it sits.
    private func cacheOwner(_ parts: [String]) -> String? {
        for marker in ["Containers", "Group Containers", "Application Support", "Caches"] {
            if let index = parts.firstIndex(of: marker), index + 1 < parts.count {
                let candidate = parts[index + 1]
                if candidate == "Data" { continue }
                return ownerLabel(candidate)
            }
        }
        return nil
    }

    static func backupInfo(_ folder: URL) -> (device: String, date: Date?)? {
        let plist = folder.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        let device = (dictionary["Device Name"] as? String) ?? (dictionary["Display Name"] as? String) ?? "an iPhone or iPad"
        return (device, dictionary["Last Backup Date"] as? Date)
    }
}
