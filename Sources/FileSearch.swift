import Foundation

enum FileKind: String, CaseIterable, Identifiable {
    case any
    case folders
    case videos
    case images
    case audio
    case archives
    case installers
    case documents
    case apps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Anything"
        case .folders: return "Folders"
        case .videos: return "Videos"
        case .images: return "Images"
        case .audio: return "Audio"
        case .archives: return "Archives"
        case .installers: return "Installers & disk images"
        case .documents: return "Documents"
        case .apps: return "Apps"
        }
    }

    var extensions: Set<String> {
        switch self {
        case .videos: return ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "webm", "mpg", "mpeg", "mts", "m2ts", "3gp", "flv", "braw", "r3d"]
        case .images: return ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "psd", "psb", "webp", "bmp", "svg", "ai"]
        case .audio: return ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "ogg", "caf", "logicx", "band"]
        case .archives: return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "sit", "sitx"]
        case .installers: return ["dmg", "pkg", "mpkg", "iso", "img", "xip", "ipsw", "sparseimage", "sparsebundle"]
        case .documents: return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "csv", "md", "epub"]
        case .any, .folders, .apps: return []
        }
    }
}

struct SearchQuery {
    var text: String
    var kind: FileKind
    var minSize: Int64
    /// Also look inside macOS's own folders and inside apps and libraries.
    var includeSystem: Bool
}

/// Searches the scanned tree. Only files of 1 MB or more are known individually; smaller ones are grouped.
enum FileSearch {
    static let limit = 300

    private static let systemTopLevel: Set<String> = ["System", "usr", "bin", "sbin", "private", "cores", "opt"]

    static func run(root: FileNode, query: SearchQuery) -> [FileNode] {
        let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let extensions = query.kind.extensions
        let rootIsDisk = root.path == "/"
        var matches: [FileNode] = []

        func accepts(_ node: FileNode) -> Bool {
            switch query.kind {
            case .any:
                // With no search text, "anything" means the largest files.
                if needle.isEmpty && node.kind != .file { return false }
            case .folders:
                if !node.isDirectory { return false }
            case .apps:
                guard node.isDirectory, node.isPackage, node.name.lowercased().hasSuffix(".app") else { return false }
            default:
                guard node.kind == .file else { return false }
                let ext = (node.name as NSString).pathExtension.lowercased()
                // Some "files" like .sparsebundle are really folders macOS shows as one item.
                if !extensions.contains(ext) { return false }
            }
            if !needle.isEmpty && !node.name.lowercased().contains(needle) { return false }
            return true
        }

        func walk(_ node: FileNode, atTop: Bool) {
            for child in node.children {
                // Children are sorted biggest first, so nothing after this can be big enough.
                if child.size < query.minSize { break }
                if child.kind == .smallFiles { continue }
                if atTop && rootIsDisk && !query.includeSystem && systemTopLevel.contains(child.name) { continue }

                let packageItem = child.isDirectory && child.isPackage
                if accepts(child) || (packageItem && query.kind == .installers && FileSearch.packageMatches(child, extensions: extensions, needle: needle)) {
                    matches.append(child)
                }
                if child.isDirectory && (!child.isPackage || query.includeSystem) {
                    walk(child, atTop: false)
                }
            }
        }

        walk(root, atTop: true)
        matches.sort { $0.size > $1.size }
        return Array(matches.prefix(limit))
    }

    /// Lets package folders such as .sparsebundle count as installers and disk images.
    private static func packageMatches(_ node: FileNode, extensions: Set<String>, needle: String) -> Bool {
        let ext = (node.name as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return false }
        return needle.isEmpty || node.name.lowercased().contains(needle)
    }
}
