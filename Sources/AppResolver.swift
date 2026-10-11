import Foundation
import AppKit

/// Turns bundle identifiers like "com.spotify.client" into app names like "Spotify".
final class AppResolver {
    static let shared = AppResolver()

    /// Developer team prefixes seen on shared app folders.
    static let knownTeams: [String: String] = [
        "UBF8T346G9": "Microsoft Office",
        "EQHXZ8M8AV": "Google",
    ]

    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var misses: Set<String> = []
    private var installed: [String: String]?

    /// Lowercased bundle ID → app name for apps in the usual Applications folders.
    func installedApps() -> [String: String] {
        lock.lock()
        if let ready = installed {
            lock.unlock()
            return ready
        }
        lock.unlock()

        var found: [String: String] = [:]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", home + "/Applications"]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    add(appAt: path, into: &found)
                } else if let inner = try? fm.contentsOfDirectory(atPath: path) {
                    // One level of app folders, like "Utilities" or "Microsoft Office".
                    for innerName in inner where innerName.hasSuffix(".app") {
                        add(appAt: path + "/" + innerName, into: &found)
                    }
                }
            }
        }

        lock.lock()
        installed = found
        lock.unlock()
        return found
    }

    private func add(appAt path: String, into map: inout [String: String]) {
        guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { return }
        let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let short = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        map[identifier.lowercased()] = display ?? short ?? fallback
    }

    func appName(bundleID: String) -> String? {
        let key = bundleID.lowercased()
        if let name = installedApps()[key] { return name }

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        if misses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var found: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let short = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            found = display ?? short ?? url.deletingPathExtension().lastPathComponent
        }

        lock.lock()
        if let name = found {
            cache[key] = name
        } else {
            misses.insert(key)
        }
        lock.unlock()
        return found
    }

    /// The installed app an identifier belongs to. Shorter prefixes are tried so that
    /// extensions and helpers ("com.apple.Safari.SafeBrowsing") map to their app.
    func owner(of identifier: String) -> (name: String, exact: Bool)? {
        var parts = identifier.split(separator: ".").map(String.init)
        if parts.first?.lowercased() == "group" { parts.removeFirst() }
        if let first = parts.first, AppResolver.isTeamID(first) { parts.removeFirst() }
        var exact = true
        while parts.count >= 2 {
            if let name = appName(bundleID: parts.joined(separator: ".")) {
                return (name, exact)
            }
            parts.removeLast()
            exact = false
        }
        return nil
    }

    /// An installed app from the same developer (same first two parts of the identifier).
    func sameVendorApp(as identifier: String) -> String? {
        var parts = identifier.lowercased().split(separator: ".").map(String.init)
        if parts.first == "group" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        let vendor = parts[0] + "." + parts[1] + "."
        if vendor == "com.apple." { return nil }
        for (bundleID, name) in installedApps() where bundleID.hasPrefix(vendor) {
            return name
        }
        return nil
    }

    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ($0.isLetter && $0.isUppercase) || $0.isNumber }
    }
}

/// Reads WebKit's per-site "origin" files to find which website a hashed folder belongs to.
enum WebsiteOrigins {
    static func sites(in folder: URL) -> (site: String, embedded: [String])? {
        let fm = FileManager.default
        var originFiles: [URL] = [folder.appendingPathComponent("origin")]
        if let subfolders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) {
            for subfolder in subfolders {
                originFiles.append(subfolder.appendingPathComponent("origin"))
            }
        }

        var order: [String] = []
        var firstHostCounts: [String: Int] = [:]
        for file in originFiles {
            guard let data = try? Data(contentsOf: file), data.count < 16_384 else { continue }
            let hosts = extractHosts(from: data)
            guard let first = hosts.first else { continue }
            firstHostCounts[first, default: 0] += 1
            for host in hosts where !order.contains(host) {
                order.append(host)
            }
        }

        guard let top = firstHostCounts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (top, order.filter { $0 != top })
    }

    /// Older WebKit folders are named like "https_www.example.com_0".
    static func hostFromLegacyName(_ name: String) -> String? {
        let parts = name.split(separator: "_").map(String.init)
        guard parts.count >= 2, parts[0] == "http" || parts[0] == "https" else { return nil }
        let host = parts[1].lowercased()
        return isHost(host) ? host : nil
    }

    static func extractHosts(from data: Data) -> [String] {
        var hosts: [String] = []
        var current: [UInt8] = []

        func flush() {
            if current.count >= 3, let text = String(bytes: current, encoding: .ascii) {
                let lower = text.lowercased()
                if isHost(lower) && !hosts.contains(lower) {
                    hosts.append(lower)
                }
            }
            current.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if byte >= 0x21 && byte <= 0x7E {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()
        return hosts
    }

    static func isHost(_ text: String) -> Bool {
        if text == "localhost" { return true }
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.hasPrefix("-") else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard text.allSatisfy({ allowed.contains($0) }) else { return false }
        let tld = text.split(separator: ".").last.map(String.init) ?? ""
        return tld.count >= 2
    }

    static func pretty(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
