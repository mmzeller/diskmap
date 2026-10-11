import Foundation

/// One item in the scanned tree: a folder, a file of 1 MB or more, or a group of smaller files.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    enum Kind: UInt8 {
        case directory
        case file
        case smallFiles
    }

    let name: String
    let kind: Kind
    weak var parent: FileNode?
    var children: [FileNode] = []

    /// Space actually used on disk, in bytes.
    var size: Int64 = 0
    /// Length of the file's contents, in bytes (files only). Used to match duplicates.
    var logicalSize: Int64 = 0
    /// Number of files inside (folders), 1 for a file, or how many files a small-files group stands for.
    var itemCount: Int = 0
    var modified: Date?
    var isPackage = false
    var insidePackage = false
    var unreadable = false
    /// Set only on the root of a scan.
    var rootPath: String?

    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    var isDirectory: Bool { kind == .directory }

    var path: String {
        guard let parent = parent else { return rootPath ?? name }
        let base = parent.path
        if kind == .smallFiles { return base }
        return base == "/" ? "/" + name : base + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// The chain from the scan root down to this node.
    var ancestors: [FileNode] {
        var list: [FileNode] = []
        var current: FileNode? = self
        while let node = current {
            list.append(node)
            current = node.parent
        }
        return list.reversed()
    }

    /// True when this node is `other` or sits somewhere inside it.
    func isDescendant(of other: FileNode) -> Bool {
        var current: FileNode? = self
        while let node = current {
            if node === other { return true }
            current = node.parent
        }
        return false
    }

    /// Takes this node out of the tree and subtracts its size from every folder above it.
    /// The parent link is kept so the old path can still be shown.
    func detach() {
        guard let parent = parent else { return }
        parent.children.removeAll { $0 === self }
        var current: FileNode? = parent
        while let node = current {
            node.size -= size
            node.itemCount -= itemCount
            current = node.parent
        }
    }
}
