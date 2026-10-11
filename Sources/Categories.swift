import Foundation

/// Storage categories, similar to Apple's Storage settings but counted from the actual scan.
enum StorageCategory: String, CaseIterable, Identifiable {
    case apps
    case documents
    case downloads
    case photos
    case media
    case icloud
    case mail
    case developer
    case caches
    case backups
    case appData
    case trash
    case otherUsers
    case macOS
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "Applications"
        case .documents: return "Documents & Desktop"
        case .downloads: return "Downloads"
        case .photos: return "Photos & Pictures"
        case .media: return "Music & Movies"
        case .icloud: return "iCloud Drive"
        case .mail: return "Mail & Messages"
        case .developer: return "Developer"
        case .caches: return "Caches & Website Data"
        case .backups: return "iPhone & iPad Backups"
        case .appData: return "App Data"
        case .trash: return "Trash"
        case .otherUsers: return "Other Users & Shared"
        case .macOS: return "macOS"
        case .other: return "Other"
        }
    }

    var detail: String {
        switch self {
        case .apps: return "Apps in your Applications folders."
        case .documents: return "Your Documents and Desktop folders and other files in your home folder."
        case .downloads: return "Everything in your Downloads folder."
        case .photos: return "Your Photos library and the rest of the Pictures folder."
        case .media: return "Your Music and Movies folders, including Music and TV libraries."
        case .icloud: return "Copies of iCloud Drive files kept on this Mac."
        case .mail: return "Email, attachments and Messages history."
        case .developer: return "Xcode data, Homebrew, project packages like node_modules, Docker and similar tools."
        case .caches: return "Temporary files apps and websites keep to run faster. Usually safe to clear."
        case .backups: return "Local backups of your devices, made by Finder."
        case .appData: return "Settings, databases and other files apps keep in Library folders."
        case .trash: return "Files you've deleted but not emptied from the Trash."
        case .otherUsers: return "Home folders of other people on this Mac, and the Shared folder."
        case .macOS: return "The operating system and the files it uses behind the scenes."
        case .other: return "Everything that doesn't fit another category."
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2.fill"
        case .documents: return "doc.text.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .photos: return "photo.fill"
        case .media: return "music.note"
        case .icloud: return "icloud.fill"
        case .mail: return "envelope.fill"
        case .developer: return "hammer.fill"
        case .caches: return "tray.2.fill"
        case .backups: return "iphone"
        case .appData: return "folder.fill"
        case .trash: return "trash.fill"
        case .otherUsers: return "person.2.fill"
        case .macOS: return "gearshape.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

/// A folder or file that counts toward a category, with how many of its bytes do.
/// (A Documents folder's node_modules count toward Developer, so `bytes` can be less than the item's size.)
struct CategoryItem: Identifiable {
    let node: FileNode
    let bytes: Int64
    var id: ObjectIdentifier { node.id }
}

struct CategoryTotal: Identifiable {
    let category: StorageCategory
    let bytes: Int64
    /// The biggest items in this category, largest first.
    let items: [CategoryItem]
    var id: String { category.rawValue }
}

enum CategoryCounter {
    private final class Bucket {
        let node: FileNode
        let category: StorageCategory
        var bytes: Int64 = 0

        init(node: FileNode, category: StorageCategory) {
            self.node = node
            self.category = category
        }
    }

    private static let developerDotFolders: Set<String> = [".npm", ".cache", ".gradle", ".cargo", ".rustup", ".m2", ".pub-cache", ".nuget", ".docker", ".pyenv", ".nvm", ".bun", ".yarn"]

    /// Walks the tree once. Some places claim everything inside them (an app, a cache);
    /// others set a category but let those claims inside win (node_modules inside Documents).
    static func compute(root: FileNode, home: String) -> [CategoryTotal] {
        var buckets: [Bucket] = []
        let rootPath = root.path

        func count(_ node: FileNode, path: String, into bucket: Bucket) {
            for child in node.children {
                if child.kind == .smallFiles {
                    bucket.bytes += child.size
                    continue
                }
                let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
                if let claim = claimingCategory(child, path: childPath, home: home) {
                    let claimed = Bucket(node: child, category: claim)
                    claimed.bytes = child.size
                    buckets.append(claimed)
                    continue
                }
                if child.isDirectory, let area = areaCategory(path: childPath, home: home) {
                    let areaBucket = Bucket(node: child, category: area)
                    buckets.append(areaBucket)
                    count(child, path: childPath, into: areaBucket)
                    continue
                }
                if child.isDirectory && !child.isPackage {
                    count(child, path: childPath, into: bucket)
                } else {
                    bucket.bytes += child.size
                }
            }
        }

        if let claim = claimingCategory(root, path: rootPath, home: home) {
            let only = Bucket(node: root, category: claim)
            only.bytes = root.size
            buckets.append(only)
        } else {
            let start = Bucket(node: root, category: areaCategory(path: rootPath, home: home) ?? .other)
            buckets.append(start)
            count(root, path: rootPath, into: start)
        }

        var totals: [StorageCategory: Int64] = [:]
        var items: [StorageCategory: [CategoryItem]] = [:]
        for bucket in buckets where bucket.bytes > 0 {
            totals[bucket.category, default: 0] += bucket.bytes
            items[bucket.category, default: []].append(CategoryItem(node: bucket.node, bytes: bucket.bytes))
        }

        var result: [CategoryTotal] = []
        for (category, bytes) in totals {
            let sorted = (items[category] ?? []).sorted { $0.bytes > $1.bytes }
            result.append(CategoryTotal(category: category, bytes: bytes, items: Array(sorted.prefix(30))))
        }
        result.sort { $0.bytes > $1.bytes }
        return result
    }

    /// Places that belong to one category entirely, wherever they are.
    private static func claimingCategory(_ node: FileNode, path: String, home: String) -> StorageCategory? {
        switch path {
        case "/System", "/bin", "/sbin", "/private", "/cores", "/.DocumentRevisions-V100", "/.Spotlight-V100", "/.fseventsd":
            return .macOS
        case "/usr/local", "/opt/homebrew", "/opt/local":
            return .developer
        case "/Library/Caches":
            return .caches
        default:
            break
        }
        if path == home + "/.Trash" { return .trash }
        if path == home + "/Library/Caches" { return .caches }
        if path == home + "/Library/Developer" { return .developer }
        if path == home + "/Library/Mobile Documents" { return .icloud }
        if path == home + "/Library/Mail" || path == home + "/Library/Messages"
            || path == home + "/Library/Containers/com.apple.mail" { return .mail }
        if path == home + "/Library/Application Support/MobileSync/Backup" { return .backups }
        if path == home + "/Library/Containers/com.docker.docker" { return .developer }
        if path == home + "/" + node.name && developerDotFolders.contains(node.name) { return .developer }

        guard node.isDirectory else { return nil }
        let lower = node.name.lowercased()
        let ext = (node.name as NSString).pathExtension.lowercased()
        if node.isPackage && ext == "app" { return .apps }
        if ext == "photoslibrary" { return .photos }
        if lower == "node_modules" || lower == "deriveddata" { return .developer }
        if lower == "websitedata" { return .caches }
        if !node.insidePackage && Explainer.cacheNames.contains(lower) { return .caches }
        return nil
    }

    /// Places that set the category for what's inside, unless something inside claims itself.
    private static func areaCategory(path: String, home: String) -> StorageCategory? {
        if path == home || path == home + "/Documents" || path == home + "/Desktop" { return .documents }
        if path == home + "/Library" { return .appData }
        if path == home + "/Pictures" { return .photos }
        if path == home + "/Music" || path == home + "/Movies" { return .media }
        if path == home + "/Downloads" { return .downloads }
        switch path {
        case "/Applications": return .apps
        case "/Library": return .appData
        case "/usr": return .macOS
        case "/Users/Shared": return .otherUsers
        case "/": return .other
        default: break
        }
        // Another person's home folder: /Users/name
        let parts = path.split(separator: "/")
        if parts.count == 2 && parts[0] == "Users" && path != home { return .otherUsers }
        return nil
    }
}
