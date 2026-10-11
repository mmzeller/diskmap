import SwiftUI
import AppKit

/// Everything a finished scan hands back to the interface.
final class ScanOutput: @unchecked Sendable {
    let root: FileNode
    let unreadable: Int
    let previous: Snapshot?
    let cancelled: Bool
    let date: Date

    init(root: FileNode, unreadable: Int, previous: Snapshot?, cancelled: Bool, date: Date) {
        self.root = root
        self.unreadable = unreadable
        self.previous = previous
        self.cancelled = cancelled
        self.date = date
    }
}

/// The shared end of every scan, full or quick: save the snapshot for What Grew, the history point,
/// and the scan itself so it reopens next time. Runs off the main thread.
enum Scanning {
    static func finish(root: FileNode, path: String, name: String, started: Date, scanner: DiskScanner,
                       unreadable: Int, eventID: UInt64, database: String?) -> ScanOutput {
        let date = Date()
        if scanner.progress.isCancelled {
            return ScanOutput(root: root, unreadable: unreadable, previous: nil, cancelled: true, date: date)
        }
        let previous = History.load(path)
        History.save(History.makeSnapshot(root: root, rootPath: path, date: date))
        History.record(HistoryPoint(rootPath: path, date: date, total: root.size))
        let info = ScanCacheInfo(formatVersion: ScanCache.formatVersion, rootPath: path, displayName: name,
                                 date: date, duration: date.timeIntervalSince(started), unreadable: unreadable,
                                 total: root.size, eventID: eventID, eventDatabase: database)
        ScanCache.save(root: root, info: info)
        return ScanOutput(root: root, unreadable: unreadable, previous: previous, cancelled: false, date: date)
    }

    /// The end of a background check. Your last scan stays the comparison point (so slow growth adds up
    /// over several checks); only the saved tree and the size history are updated.
    /// Returns that comparison point, or nil if there wasn't one yet.
    static func finishAutomatic(root: FileNode, path: String, name: String, started: Date,
                                unreadable: Int, eventID: UInt64, database: String?) -> Snapshot? {
        let date = Date()
        let baseline = History.load(path)
        if baseline == nil {
            History.save(History.makeSnapshot(root: root, rootPath: path, date: date))
        }
        History.record(HistoryPoint(rootPath: path, date: date, total: root.size))
        let info = ScanCacheInfo(formatVersion: ScanCache.formatVersion, rootPath: path, displayName: name,
                                 date: date, duration: date.timeIntervalSince(started), unreadable: unreadable,
                                 total: root.size, eventID: eventID, eventDatabase: database, automatic: true)
        ScanCache.save(root: root, info: info)
        return baseline
    }
}

/// A scan read back from disk at launch.
final class LoadedScan: @unchecked Sendable {
    let root: FileNode
    let previous: Snapshot?

    init(root: FileNode, previous: Snapshot?) {
        self.root = root
        self.previous = previous
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case welcome
        case loading
        case scanning
        case results
    }

    enum Tab: String, CaseIterable, Identifiable {
        case map = "Map"
        case ideas = "Cleanup Ideas"
        case growth = "What Grew"
        case untouched = "Big & Untouched"
        case duplicates = "Duplicates"
        case basket = "Cleanup Basket"

        var id: String { rawValue }
    }

    enum DuplicateState {
        case notStarted
        case running
        case finished
    }

    @Published var phase: Phase = .welcome
    /// Sidebar selection. Optional because a sidebar list can be deselected; nil shows the map.
    @Published var selectedTab: Tab? = .map
    @Published private(set) var root: FileNode?
    @Published var focus: FileNode? {
        didSet { rebuildChart() }
    }
    @Published var selection: FileNode?
    @Published private(set) var segments: [ChartSegment] = []
    /// Chart color for each item in the innermost ring, so list rows can match the chart.
    @Published private(set) var segmentHues: [ObjectIdentifier: Double] = [:]
    @Published private(set) var treeVersion = 0

    // Scan state
    @Published private(set) var scanName = ""
    @Published private(set) var scanItems = 0
    @Published private(set) var scanBytes: Int64 = 0
    /// What the scan will probably total (last scan of the same place, or disk usage). 0 when unknown.
    @Published private(set) var scanExpectedBytes: Int64 = 0
    /// True while updating a saved scan from the change log rather than reading everything.
    @Published private(set) var isQuickRescan = false
    @Published private(set) var scanNote = ""
    /// Share of changed folders rechecked so far, during a quick rescan.
    @Published private(set) var scanStepFraction: Double?
    @Published private(set) var scanCurrentPath = ""
    @Published private(set) var scanDate: Date?
    @Published private(set) var scanDuration: TimeInterval = 0
    @Published private(set) var unreadableCount = 0
    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var startupVolume: VolumeInfo?
    @Published private(set) var hasFullDiskAccess = false
    @Published private(set) var scannedRootPath = ""
    @Published private(set) var lastScans: [HistoryPoint] = []
    /// The saved scan DiskMap can reopen, if there is one.
    @Published private(set) var cachedScan: ScanCacheInfo?
    /// True when the scan on screen was last updated by the background check.
    @Published private(set) var scanIsAutomatic = false

    // Insights
    @Published private(set) var ideas: [Idea] = []
    @Published private(set) var growth: GrowthReport?
    @Published private(set) var history: [HistoryPoint] = []

    @Published var untouchedMinSize: Int64 = 500_000_000 {
        didSet { refreshUntouched() }
    }
    @Published var untouchedMonths = 6 {
        didSet { refreshUntouched() }
    }
    @Published private(set) var untouched: [UntouchedFile] = []
    @Published private(set) var untouchedBusy = false

    @Published var duplicateMinSize: Int64 = 10_000_000
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var duplicateState: DuplicateState = .notStarted
    @Published private(set) var duplicatePhase = ""
    @Published private(set) var duplicateFraction = 0.0

    // Cleanup basket: items collected from anywhere, trashed together. Remembered by path across launches.
    @Published private(set) var basket: [FileNode] = [] {
        didSet { UserDefaults.standard.set(basket.map { $0.path }, forKey: "basketPaths") }
    }

    // Trash and messages
    @Published var pendingTrash: [FileNode] = []
    @Published var showTrashConfirm = false
    @Published var showEmptyTrashConfirm = false
    @Published var alertMessage: String? {
        didSet { showAlert = alertMessage != nil }
    }
    @Published var showAlert = false
    @Published private(set) var statusMessage: String?

    let explainer = Explainer()
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var scanner: DiskScanner?
    private var pollTask: Task<Void, Never>?
    private var duplicateProgress: DuplicateProgress?
    private var untouchedGeneration = 0

    init() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        startupVolume = VolumeInfo.forPath("/")
        lastScans = History.loadPoints()
        cachedScan = ScanCache.loadInfo()
        if cachedScan != nil {
            openLastScan()
        }

        // A click on a "your disk grew" notification: reload the freshly checked scan and show What Grew.
        _ = NotificationCenter.default.addObserver(forName: .diskMapShowGrowth, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch self.phase {
                case .results, .welcome:
                    self.openLastScan()
                case .loading, .scanning:
                    break
                }
            }
        }
    }

    /// Reopens the most recent scan from disk, without scanning again.
    func openLastScan() {
        guard phase != .scanning, phase != .loading else { return }
        guard let info = ScanCache.loadInfo() else {
            cachedScan = nil
            return
        }
        phase = .loading
        scanName = info.displayName
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedScan? in
                guard let tree = try? ScanCache.loadTree(info: info) else { return nil }
                // After a background check, compare with your last scan; otherwise with the scan before it.
                let previous = info.automatic == true ? History.load(info.rootPath) : History.loadPrevious(info.rootPath)
                return LoadedScan(root: tree, previous: previous)
            }.value
            guard let self = self else { return }
            guard let loaded = loaded else {
                // The saved scan couldn't be read; start fresh rather than showing something broken.
                self.cachedScan = nil
                self.phase = .welcome
                return
            }
            self.present(root: loaded.root, path: info.rootPath, date: info.date, duration: info.duration,
                         unreadable: info.unreadable, previous: loaded.previous)
            self.scanIsAutomatic = info.automatic == true
        }
    }

    var diskName: String { startupVolume?.name ?? "Macintosh HD" }

    var tab: Tab { selectedTab ?? .map }

    /// Rough scan progress, or nil when there's nothing to estimate from.
    var scanFraction: Double? {
        if let steps = scanStepFraction { return min(0.99, steps) }
        guard scanExpectedBytes > 0 else { return nil }
        return min(0.99, Double(scanBytes) / Double(scanExpectedBytes))
    }

    func badgeCount(for tab: Tab) -> Int {
        switch tab {
        case .map: return 0
        case .ideas: return ideas.count
        case .growth: return growth?.items.count ?? 0
        case .untouched: return untouched.count
        case .duplicates: return duplicateGroups.count
        case .basket: return basket.count
        }
    }

    func hue(for node: FileNode) -> Double? {
        segmentHues[node.id]
    }

    // MARK: - Scanning

    func scanDisk() {
        startScan(path: "/", name: diskName)
    }

    func scanHome() {
        startScan(path: home, name: FileManager.default.displayName(atPath: home))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to scan"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(path: url.path, name: FileManager.default.displayName(atPath: url.path))
        }
    }

    /// Quick when possible: rechecks only the folders macOS says changed since the last scan.
    func rescan() {
        guard let current = root, phase == .results else { return }
        if let info = cachedScan, info.rootPath == scannedRootPath, let eventID = info.eventID,
           let database = info.eventDatabase, database == ChangeTracker.databaseID(for: scannedRootPath) {
            startQuickRescan(root: current, path: scannedRootPath, since: eventID, unreadable: info.unreadable)
        } else {
            startScan(path: scannedRootPath, name: current.name)
        }
    }

    /// Always reads every folder again.
    func fullRescan() {
        guard let current = root else { return }
        startScan(path: scannedRootPath, name: current.name)
    }

    func recheckAccess() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func startScan(path: String, name: String) {
        guard phase != .scanning, phase != .loading else { return }
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        duplicateProgress?.cancel()

        let scanner = DiskScanner()
        self.scanner = scanner
        isQuickRescan = false
        scanName = name
        scanItems = 0
        scanBytes = 0
        scanNote = ""
        scanStepFraction = nil
        scanCurrentPath = path
        if let last = History.loadPoints().last(where: { $0.rootPath == path }) {
            scanExpectedBytes = last.total
        } else if path == "/", let disk = VolumeInfo.forPath("/") {
            scanExpectedBytes = disk.used
        } else {
            scanExpectedBytes = 0
        }
        phase = .scanning
        let started = Date()

        startPolling(scanner)

        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { () -> ScanOutput in
                let eventID = ChangeTracker.currentEventID()
                let database = ChangeTracker.databaseID(for: path)
                let root = scanner.scan(rootPath: path, displayName: name)
                return Scanning.finish(root: root, path: path, name: name, started: started, scanner: scanner,
                                       unreadable: scanner.unreadable, eventID: eventID, database: database)
            }.value
            self?.finishScan(output, path: path, started: started)
        }
    }

    /// Updates the scan on screen using macOS's change log, falling back to a full scan if the log can't help.
    private func startQuickRescan(root current: FileNode, path: String, since eventID: UInt64, unreadable: Int) {
        duplicateProgress?.cancel()
        let scanner = DiskScanner()
        self.scanner = scanner
        isQuickRescan = true
        let name = current.name
        scanName = name
        scanItems = 0
        scanBytes = 0
        scanExpectedBytes = 0
        scanNote = "Reading the change log…"
        scanStepFraction = nil
        scanCurrentPath = path
        scanner.progress.setNote("Reading the change log…")
        phase = .scanning
        let started = Date()
        startPolling(scanner)

        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { () -> ScanOutput in
                let newEventID = ChangeTracker.currentEventID()
                let database = ChangeTracker.databaseID(for: path)
                if let changes = ChangeTracker.changes(under: path, since: eventID),
                   Rescanner.update(root: current, rootPath: path, changes: changes, scanner: scanner) {
                    return Scanning.finish(root: current, path: path, name: name, started: started, scanner: scanner,
                                           unreadable: unreadable, eventID: newEventID, database: database)
                }
                if scanner.progress.isCancelled {
                    return ScanOutput(root: current, unreadable: unreadable, previous: nil, cancelled: true, date: Date())
                }
                scanner.progress.setNote("The change log couldn't cover everything, so this is a full scan.")
                let root = scanner.scan(rootPath: path, displayName: name)
                return Scanning.finish(root: root, path: path, name: name, started: started, scanner: scanner,
                                       unreadable: scanner.unreadable, eventID: newEventID, database: database)
            }.value
            self?.finishScan(output, path: path, started: started)
        }
    }

    private func startPolling(_ scanner: DiskScanner) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self = self else { return }
                let progress = scanner.progress.read()
                let steps = scanner.progress.readSteps()
                withAnimation(.easeOut(duration: 0.2)) {
                    self.scanItems = progress.items
                    self.scanBytes = progress.bytes
                    self.scanStepFraction = steps.total > 0 ? Double(steps.done) / Double(steps.total) : nil
                }
                self.scanCurrentPath = progress.path
                self.scanNote = steps.note
            }
        }
    }

    func cancelScan() {
        scanner?.progress.cancel()
    }

    private func finishScan(_ output: ScanOutput, path: String, started: Date) {
        pollTask?.cancel()
        pollTask = nil
        scanner = nil

        if output.cancelled {
            if root != nil {
                // A stopped quick rescan may have updated part of the tree already.
                treeVersion += 1
                rebuildChart()
            }
            phase = root == nil ? .welcome : .results
            return
        }

        cachedScan = ScanCache.loadInfo()
        present(root: output.root, path: path, date: output.date, duration: output.date.timeIntervalSince(started),
                unreadable: output.unreadable, previous: output.previous)
        scanIsAutomatic = false
    }

    /// Shows a scan, whether it just finished or was reopened from disk.
    private func present(root newRoot: FileNode, path: String, date: Date, duration: TimeInterval,
                         unreadable: Int, previous: Snapshot?) {
        explainer.reset()
        scannedRootPath = path
        scanDate = date
        scanDuration = duration
        unreadableCount = unreadable
        volume = VolumeInfo.forPath(path)
        startupVolume = VolumeInfo.forPath("/")
        if let previous = previous {
            let explainer = self.explainer
            growth = History.compare(old: previous, root: newRoot) { node in
                if node.isPackage { return true }
                if let explanation = explainer.explain(node) { return !explanation.isGroup }
                return false
            }
        } else {
            growth = nil
        }
        history = History.points(for: path)
        lastScans = History.loadPoints()
        untouched = []
        duplicateGroups = []
        duplicateState = .notStarted
        selection = nil
        root = newRoot
        focus = newRoot
        ideas = IdeaFinder.find(root: newRoot, explainer: explainer)
        restoreBasket(in: newRoot)
        selectedTab = NotificationHandler.takePendingGrowth() ? .growth : .map
        phase = .results
        refreshUntouched()
    }

    func backToStart() {
        guard phase != .scanning, phase != .loading else { return }
        lastScans = History.loadPoints()
        startupVolume = VolumeInfo.forPath("/")
        cachedScan = ScanCache.loadInfo()
        phase = .welcome
    }

    /// True when the scan on screen is the one saved on disk, so removals should be remembered there.
    private var showingSavedScan: Bool {
        guard let saved = cachedScan, let current = scanDate else { return false }
        return saved.rootPath == scannedRootPath && abs(saved.date.timeIntervalSince(current)) < 1
    }

    // MARK: - Navigation

    private func rebuildChart() {
        guard let current = focus else {
            segments = []
            segmentHues = [:]
            return
        }
        let built = ChartLayout.segments(for: current)
        var hues: [ObjectIdentifier: Double] = [:]
        for segment in built where segment.depth == 1 {
            hues[segment.node.id] = segment.hue
        }
        segments = built
        segmentHues = hues
    }

    func open(_ node: FileNode) {
        if node.isDirectory {
            focus = node
            selection = nil
        } else {
            focus = node.parent ?? node
            selection = node
        }
    }

    func goUp() {
        guard let current = focus, let parent = current.parent else { return }
        focus = parent
        selection = current
    }

    func select(_ node: FileNode) {
        selection = node
    }

    func showInMap(_ node: FileNode) {
        selectedTab = .map
        focus = node.parent ?? node
        selection = node
    }

    /// Shows the item selected in a Finder window and brings Finder to the front.
    /// Tries three ways in turn and reports what happened, so a failure is never silent.
    func reveal(_ node: FileNode) {
        let path = node.path
        let opensFolder = node.kind == .smallFiles
        guard FileManager.default.fileExists(atPath: path) else {
            alertMessage = "“\(node.name)” isn't there anymore. It may have been moved or deleted since the scan. Rescan to update the map."
            return
        }

        // Since macOS 14, an app has to hand focus over explicitly or Finder opens behind it.
        // The compiler check keeps this building with older developer tools that don't know the call.
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        }
        #endif

        var problems: [String] = []

        // 1. Ask Finder directly. It selects the item and comes to the front on its own.
        //    The first time, macOS asks whether DiskMap may control Finder.
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let verb = opensFolder ? "open" : "reveal"
        let source = """
        tell application "Finder"
            \(verb) (POSIX file "\(quoted)" as alias)
            activate
        end tell
        """
        var scriptError: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&scriptError)
            if scriptError == nil {
                showStatus("Showing “\(node.name)” in Finder.")
                return
            }
            let message = scriptError?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            let number = scriptError?[NSAppleScript.errorNumber] as? Int ?? 0
            problems.append("Finder script: \(message) (\(number))")
        }

        // 2. The same command Terminal uses: open -R.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = opensFolder ? [path] : ["-R", path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                activateFinder()
                showStatus("Showing “\(node.name)” in Finder.")
                return
            }
            problems.append("open -R exited with status \(process.terminationStatus)")
        } catch {
            problems.append("open -R: \(error.localizedDescription)")
        }

        // 3. The system's own call.
        let worked = opensFolder
            ? NSWorkspace.shared.open(URL(fileURLWithPath: path))
            : NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        if worked {
            activateFinder()
            showStatus("Showing “\(node.name)” in Finder.")
            return
        }
        problems.append("NSWorkspace refused")

        alertMessage = "Finder couldn't show “\(node.name)”.\n\nLocation: \(path)\n\nDetails for Claude:\n" + problems.joined(separator: "\n")
    }

    private func activateFinder() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
        showStatus("Copied the path.")
    }

    func shortPath(_ node: FileNode) -> String {
        explainer.relative(node.path)
    }

    // MARK: - Trash

    func isTrashFolder(_ node: FileNode) -> Bool {
        node.path == home + "/.Trash"
    }

    func canTrash(_ node: FileNode) -> Bool {
        if node.kind == .smallFiles || node.parent == nil { return false }
        let path = node.path
        if path == home { return false }
        let protected = ["/System", "/usr", "/bin", "/sbin", "/private/var/vm", "/private/var/db", home + "/.Trash"]
        for prefix in protected where path == prefix || path.hasPrefix(prefix + "/") {
            return false
        }
        if node.parent?.path == "/" { return false }
        let homeFolders = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"]
        if node.parent?.path == home && homeFolders.contains(node.name) { return false }
        return true
    }

    func requestTrash(_ nodes: [FileNode]) {
        let allowed = nodes.filter { canTrash($0) }
        guard !allowed.isEmpty else { return }
        pendingTrash = allowed
        showTrashConfirm = true
    }

    var pendingTrashSummary: String {
        var total: Int64 = 0
        for node in pendingTrash { total += node.size }
        if pendingTrash.count == 1, let node = pendingTrash.first {
            return "“\(node.name)” (\(Fmt.bytes(total))) will be moved to the Trash. You can put it back until you empty the Trash."
        }
        return "\(pendingTrash.count) items (\(Fmt.bytes(total))) will be moved to the Trash. You can put them back until you empty the Trash."
    }

    func confirmTrash() {
        let nodes = pendingTrash
        pendingTrash = []
        var moved: Int64 = 0
        var failures: [String] = []
        var removedPaths: [String] = []
        for node in nodes {
            do {
                let path = node.path
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                moved += node.size
                removedPaths.append(path)
                node.detach()
                forget(node)
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        if showingSavedScan {
            ScanCache.recordRemoval(removedPaths)
        }
        treeVersion += 1
        rebuildChart()
        if !failures.isEmpty {
            alertMessage = "Some items couldn't be moved to the Trash.\n\n" + failures.prefix(5).joined(separator: "\n")
                + "\n\nItems in system folders may need an administrator to remove."
        } else if moved > 0 {
            showStatus("Moved \(Fmt.bytes(moved)) to the Trash. Empty the Trash to get the space back.")
        }
    }

    // MARK: - Cleanup basket

    var basketTotal: Int64 {
        var total: Int64 = 0
        for node in basket { total += node.size }
        return total
    }

    /// True when the item, or a folder it's in, is already in the basket.
    func isInBasket(_ node: FileNode) -> Bool {
        basket.contains { node.isDescendant(of: $0) }
    }

    func addToBasket(_ nodes: [FileNode]) {
        var added = 0
        var list = basket
        for node in nodes where canTrash(node) && !isTrashFolder(node) {
            if list.contains(where: { node.isDescendant(of: $0) }) { continue }
            // A folder replaces anything of its own that was already in the basket.
            list.removeAll { $0.isDescendant(of: node) }
            list.append(node)
            added += 1
        }
        guard added > 0 else { return }
        list.sort { $0.size > $1.size }
        basket = list
        let total = Fmt.bytes(basketTotal)
        showStatus(added == 1 ? "Added to the Cleanup Basket (\(total) in all)." : "Added \(added) items to the Cleanup Basket (\(total) in all).")
    }

    /// Used by drag and drop, which carries paths.
    func addToBasket(paths: [String]) {
        guard let current = root else { return }
        addToBasket(paths.compactMap { ScanCache.find($0, in: current) })
    }

    func removeFromBasket(_ node: FileNode) {
        basket.removeAll { $0 === node }
    }

    func clearBasket() {
        basket = []
    }

    func trashBasket() {
        requestTrash(basket)
    }

    /// Rebuilds the basket from saved paths against the tree on screen, dropping anything that's gone.
    private func restoreBasket(in newRoot: FileNode) {
        let paths = UserDefaults.standard.stringArray(forKey: "basketPaths") ?? []
        var restored: [FileNode] = []
        for path in paths {
            if let node = ScanCache.find(path, in: newRoot), node !== newRoot, canTrash(node) {
                restored.append(node)
            }
        }
        basket = restored
    }

    /// Drops a removed item (and anything inside it) from every list.
    private func forget(_ node: FileNode) {
        basket.removeAll { $0.isDescendant(of: node) }
        ideas.removeAll { $0.node.isDescendant(of: node) }
        untouched.removeAll { $0.node.isDescendant(of: node) }
        for index in duplicateGroups.indices {
            duplicateGroups[index].files.removeAll { $0.isDescendant(of: node) }
        }
        duplicateGroups.removeAll { $0.files.count < 2 }
        if var report = growth {
            report.items.removeAll { $0.node.isDescendant(of: node) }
            growth = report
        }
        if let current = focus, current.isDescendant(of: node) {
            focus = node.parent
        }
        if let current = selection, current.isDescendant(of: node) {
            selection = nil
        }
    }

    func emptyTrash() {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        _ = script?.executeAndReturnError(&error)
        if let error = error {
            let reason = error[NSAppleScript.errorMessage] as? String ?? "macOS didn't allow it"
            alertMessage = "Couldn't empty the Trash (\(reason)). You can empty it from the Trash icon in the Dock instead."
            return
        }
        if let trash = root.flatMap({ findNode(path: home + "/.Trash", in: $0) }) {
            for child in trash.children {
                child.detach()
            }
            if showingSavedScan {
                // "/*" means everything inside, including the grouped small files.
                ScanCache.recordRemoval([trash.path + "/*"])
            }
            forget(trash)
            treeVersion += 1
            rebuildChart()
        }
        ideas.removeAll { isTrashFolder($0.node) }
        volume = VolumeInfo.forPath(scannedRootPath.isEmpty ? "/" : scannedRootPath)
        showStatus("Trash emptied.")
    }

    private func findNode(path: String, in node: FileNode) -> FileNode? {
        let rootPath = node.path
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return nil }
        if path == rootPath { return node }
        for child in node.children where child.isDirectory {
            if let found = findNode(path: path, in: child) { return found }
        }
        return nil
    }

    private func showStatus(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            statusMessage = message
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.statusMessage == message else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                self.statusMessage = nil
            }
        }
    }

    // MARK: - Big & untouched

    func refreshUntouched() {
        guard let current = root else {
            untouched = []
            return
        }
        untouchedGeneration += 1
        let generation = untouchedGeneration
        let minSize = untouchedMinSize
        let cutoff = Calendar.current.date(byAdding: .month, value: -untouchedMonths, to: Date()) ?? Date()
        let homePath = home
        untouchedBusy = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [UntouchedFile] in
                Untouched.find(root: current, minSize: minSize, cutoff: cutoff, home: homePath)
            }.value
            guard let self = self, generation == self.untouchedGeneration else { return }
            self.untouched = found
            self.untouchedBusy = false
        }
    }

    // MARK: - Duplicates

    func findDuplicates() {
        guard let current = root, duplicateState != .running else { return }
        let progress = DuplicateProgress()
        duplicateProgress = progress
        duplicateState = .running
        duplicateGroups = []
        duplicatePhase = "Looking for files with the same size"
        duplicateFraction = 0
        let minSize = duplicateMinSize
        let homePath = home

        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let state = progress.read()
                self?.duplicatePhase = state.phase
                self?.duplicateFraction = state.fraction
            }
        }

        Task { [weak self] in
            let groups = await Task.detached(priority: .userInitiated) { () -> [DuplicateGroup] in
                DuplicateFinder.find(root: current, minSize: minSize, home: homePath, progress: progress)
            }.value
            poll.cancel()
            guard let self = self else { return }
            if progress.isCancelled {
                self.duplicateState = .notStarted
                return
            }
            self.duplicateGroups = groups
            self.duplicateState = .finished
        }
    }

    func cancelDuplicates() {
        duplicateProgress?.cancel()
    }
}
