import Foundation
import AppKit

/// A version of DiskMap published on GitHub.
struct ReleaseInfo: Equatable {
    let version: String
    /// The "What's new" lines from the release notes.
    let notes: [String]
    let downloadURL: URL
    let pageURL: URL
}

/// Keeps DiskMap up to date from its GitHub releases.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
        /// Shown once after DiskMap restarts on a new version.
        case updated(version: String, notes: [String])
    }

    @Published private(set) var phase: Phase = .idle
    @Published var showSheet = false
    /// What the installer is doing right now, shown under "Updating DiskMap".
    @Published private(set) var installStep = ""
    /// A newer version, once a check has found one.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var lastChecked: Date?
    @Published var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic)
            if checksAutomatically { checkIfDue() }
        }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let releasesPage = URL(string: "https://github.com/mmzeller/diskmap/releases/latest")!

    private enum Keys {
        static let automatic = "updateChecksAutomatically"
        static let lastChecked = "updateLastChecked"
        static let updatedFrom = "updateInstalledFrom"
        static let notes = "updateNotes"
    }

    /// How often the automatic check runs.
    private static let interval: TimeInterval = 20 * 3600

    init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date

        // Just restarted after an update: say so, with what's new.
        if let from = defaults.string(forKey: Keys.updatedFrom) {
            let notes = defaults.stringArray(forKey: Keys.notes) ?? []
            defaults.removeObject(forKey: Keys.updatedFrom)
            defaults.removeObject(forKey: Keys.notes)
            if from != currentVersion {
                phase = .updated(version: currentVersion, notes: notes)
                showSheet = true
            }
        }

        // Check a few seconds after launch, then keep checking while DiskMap stays open.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(nanoseconds: 3 * 3600 * 1_000_000_000)
            }
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// DiskMap → Check for Updates… Settings checks without opening the update window.
    func checkNow(showWindow: Bool = true) {
        if showWindow { showSheet = true }
        if isBusy { return }
        Task { await check(userInitiated: true) }
    }

    private func checkIfDue() {
        guard checksAutomatically, !isBusy else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Updater.interval { return }
        Task { await check(userInitiated: false) }
    }

    private func check(userInitiated: Bool) async {
        if userInitiated { phase = .checking }
        do {
            let release = try await ReleaseFeed.latest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            if ReleaseFeed.isNewer(release.version, than: currentVersion) {
                available = release
                if userInitiated || !showSheet { phase = .available(release) }
            } else {
                available = nil
                if userInitiated { phase = .upToDate }
            }
        } catch {
            // Automatic checks fail quietly (no internet, for example) and try again later.
            if userInitiated { phase = .failed(error.localizedDescription) }
        }
    }

    func dismiss() {
        showSheet = false
        switch phase {
        case .downloading, .installing:
            break
        default:
            phase = available.map { .available($0) } ?? .idle
        }
    }

    func showAvailable() {
        if let release = available, !isBusy { phase = .available(release) }
        showSheet = true
    }

    /// Downloads the new version, swaps it in for this copy of DiskMap and reopens it.
    func install() {
        guard let release = available, !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            phase = .failed("macOS is running DiskMap from a temporary, read-only copy. Drag DiskMap into your Applications folder, open it from there and try again.")
            return
        }
        phase = .downloading(0)
        let from = currentVersion
        // The updater lives as long as the app, so holding on to it here is fine.
        let updater = self
        Task {
            do {
                let folder = try UpdateInstaller.workFolder(near: appURL)
                let downloader = Downloader(destination: folder.appendingPathComponent("DiskMap.zip")) { fraction in
                    Task { @MainActor in
                        updater.reportProgress(fraction)
                    }
                }
                let zip = try await downloader.download(release.downloadURL)
                updater.installStep = "Unpacking…"
                updater.phase = .installing
                updater.startWatchdog()
                let installed = try await Task.detached(priority: .userInitiated) { () -> URL in
                    try UpdateInstaller.install(zip: zip, in: folder, version: release.version, replacing: appURL) { step in
                        Task { @MainActor in updater.installStep = step }
                    }
                }.value
                // Even if the watchdog gave up, the new version is in place now, so reopen on it.
                UserDefaults.standard.set(from, forKey: Keys.updatedFrom)
                UserDefaults.standard.set(release.notes, forKey: Keys.notes)
                updater.installStep = "Reopening…"
                UpdateInstaller.relaunch(installed)
            } catch {
                UpdateLog.write("Failed: \(error.localizedDescription)")
                if case .installing = updater.phase {} else if case .downloading = updater.phase {} else { return }
                updater.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// If installing ever takes far longer than it should, give the window back with a way out.
    private func startWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            guard let self = self, case .installing = self.phase else { return }
            UpdateLog.write("Gave up waiting at step: \(self.installStep)")
            self.phase = .failed("Installing took too long (it stopped at “\(self.installStep)”). Your current version is still there. Use Open Download Page to install the new one by hand.")
        }
    }

    private func reportProgress(_ fraction: Double) {
        if case .downloading = phase {
            phase = .downloading(fraction)
        }
    }

    func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([UpdateLog.url])
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(available?.pageURL ?? Updater.releasesPage)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Reads the latest release from GitHub.
enum ReleaseFeed {
    static let endpoint = URL(string: "https://api.github.com/repos/mmzeller/diskmap/releases/latest")!

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let htmlUrl: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }

    static func latest() async throws -> ReleaseInfo {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 404:
            throw Problem(message: "No versions of DiskMap have been published yet.")
        case 403, 429:
            throw Problem(message: "GitHub is limiting how often it can be asked. Try again in an hour.")
        default:
            throw Problem(message: "GitHub answered with an error (\(status)). Try again later.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == "DiskMap.zip" }),
              let download = URL(string: asset.browserDownloadUrl),
              let page = URL(string: release.htmlUrl) else {
            throw Problem(message: "The latest version on GitHub doesn't have a download yet. Try again in a few minutes.")
        }
        var version = release.tagName
        if version.hasPrefix("v") { version.removeFirst() }
        return ReleaseInfo(version: version, notes: whatsNew(release.body ?? ""), downloadURL: download, pageURL: page)
    }

    /// The bullet points under "What's new" in the release notes.
    static func whatsNew(_ body: String) -> [String] {
        var lines: [String] = []
        var inSection = false
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSection = line.lowercased().contains("what's new") || line.lowercased().contains("what’s new")
                continue
            }
            guard inSection, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            lines.append(String(line.dropFirst(2)))
        }
        return lines
    }

    /// Compares versions like "2.10" and "2.9.1" number by number.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Downloads one file, reporting progress.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(ReleaseFeed.Problem(message: "The download failed (GitHub answered \(status)). Try again later.")))
            return
        }
        // The file at `location` is deleted when this method returns, so move it now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            finish(.failure(error))
        }
    }
}

/// A running record of each update, for working out what went wrong.
enum UpdateLog {
    static var url: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiskMap", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Updates.log")
    }

    static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Unpacks, checks and installs a downloaded copy of DiskMap.
enum UpdateInstaller {
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A scratch folder on the same disk as the app, so the final swap is a quick rename.
    static func workFolder(near app: URL) throws -> URL {
        let fm = FileManager.default
        if let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true) {
            return folder
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("DiskMap-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Returns where the new version now is (the same place as the old one).
    /// Every step either finishes quickly or fails with a message; none of them can wait on a dialog.
    static func install(zip: URL, in folder: URL, version: String, replacing current: URL,
                        step: @escaping @Sendable (String) -> Void) throws -> URL {
        let fm = FileManager.default
        func report(_ text: String) {
            UpdateLog.write(text)
            step(text)
        }
        UpdateLog.write("Installing \(version) over \(current.path)")

        report("Unpacking…")
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: unpacked)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120) == 0 else {
            throw Problem(message: "The download couldn't be unpacked. Nothing was changed.")
        }

        // Make sure it's really the version we expect, and undamaged.
        report("Checking the download…")
        let newApp = unpacked.appendingPathComponent("DiskMap.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Problem(message: "The download doesn't contain DiskMap. Nothing was changed.")
        }
        let downloaded = info["CFBundleShortVersionString"] as? String ?? "?"
        guard downloaded == version else {
            throw Problem(message: "The download is version \(downloaded) instead of \(version). Nothing was changed.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60) == 0 else {
            throw Problem(message: "The download is damaged (its signature doesn't match its contents). Nothing was changed.")
        }
        // Once DiskMap is signed with its own key, only accept updates signed with that same key.
        let running = Bundle.main.bundleURL
        if CodeSigning.hasStableIdentity(running), let requirement = CodeSigning.requirement(of: running) {
            guard CodeSigning.satisfies(newApp, requirement) else {
                throw Problem(message: "The download isn't signed with DiskMap's signing key, so it wasn't installed. Nothing was changed.")
            }
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], timeout: 30)

        report("Putting the new version in place…")
        try swap(current, with: newApp)
        let installed = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        guard installed?["CFBundleShortVersionString"] as? String == version else {
            throw Problem(message: "The new version couldn't be put in place. Use Open Download Page to install it by hand.")
        }
        try? fm.removeItem(at: folder)
        report("Installed \(version)")
        return current
    }

    /// Replaces the app with plain renames in its own folder: the new version goes next to the old
    /// one, the old one steps aside, the new one takes its name. If anything fails, the old one is
    /// put back.
    private static func swap(_ current: URL, with newApp: URL) throws {
        let fm = FileManager.default
        let folder = current.deletingLastPathComponent()
        let tag = String(UUID().uuidString.prefix(8))
        let incoming = folder.appendingPathComponent(".DiskMap-incoming-\(tag).app", isDirectory: true)
        let outgoing = folder.appendingPathComponent(".DiskMap-previous-\(tag).app", isDirectory: true)
        let notAllowed = "macOS didn't let DiskMap change \(folder.path). Use Open Download Page and drag the new DiskMap into Applications yourself."

        do {
            try fm.moveItem(at: newApp, to: incoming)
        } catch {
            UpdateLog.write("Move next to the app failed: \(error)")
            throw Problem(message: notAllowed)
        }
        do {
            try fm.moveItem(at: current, to: outgoing)
        } catch {
            UpdateLog.write("Moving the old version aside failed: \(error)")
            try? fm.removeItem(at: incoming)
            throw Problem(message: notAllowed)
        }
        do {
            try fm.moveItem(at: incoming, to: current)
        } catch {
            UpdateLog.write("Moving the new version in failed: \(error)")
            try? fm.moveItem(at: outgoing, to: current)
            try? fm.removeItem(at: incoming)
            throw Problem(message: notAllowed)
        }
        // The old version goes to the Trash, out of sight (its name starts with a dot).
        do {
            try fm.trashItem(at: outgoing, resultingItemURL: nil)
        } catch {
            try? fm.removeItem(at: outgoing)
        }
    }

    /// Waits for this copy of DiskMap to quit, then opens the new one.
    @MainActor
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /bin/sleep 0.5; /usr/bin/open \"$2\"",
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path,
        ]
        do {
            try process.run()
        } catch {
            UpdateLog.write("Couldn't start the reopen helper: \(error)")
        }
        UserDefaults.standard.synchronize()
        UpdateLog.write("Quitting to reopen \(app.path)")
        NSApp.terminate(nil)
        // If something keeps the app from quitting (an open window or sheet, for example), quit anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateLog.write("Quit didn't finish; exiting")
            exit(0)
        }
    }

    /// Runs a command-line tool, giving up after `timeout` seconds so nothing can hang the update.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            UpdateLog.write("\(tool) couldn't start: \(error)")
            return -1
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                UpdateLog.write("\(tool) took longer than \(Int(timeout)) seconds and was stopped")
                return -2
            }
            usleep(50_000)
        }
        if process.terminationStatus != 0 {
            UpdateLog.write("\(tool) exited with \(process.terminationStatus)")
        }
        return process.terminationStatus
    }
}

/// Lets the automated tests run the real installer against a copy of DiskMap that's replacing itself.
enum UpdateSelfTest {
    static func run(zip: String, version: String) -> Int32 {
        let app = Bundle.main.bundleURL
        do {
            let folder = try UpdateInstaller.workFolder(near: app)
            let copy = folder.appendingPathComponent("DiskMap.zip")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: zip), to: copy)
            let installed = try UpdateInstaller.install(zip: copy, in: folder, version: version, replacing: app) { step in
                print("step: \(step)")
            }
            print("installed: \(installed.path)")
            return 0
        } catch {
            print("refused or failed: \(error.localizedDescription)")
            return 1
        }
    }
}
