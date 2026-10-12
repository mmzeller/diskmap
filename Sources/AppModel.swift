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
        case categories = "Categories"
        case find = "Find"
        case quickClean = "Quick Clean"
        case ideas = "Cleanup Ideas"
        case growth = "What Grew"
        case untouched = "Big & Untouched"
        case duplicates = "Duplicates"
        case apps = "Uninstall Apps"
        case basket = "Cleanup Basket"
        case removed = "Recently Removed"

        var id: String { rawValue }
    }

    enum DuplicateState {
        case notStarted
        case running
        case finished
    }

    enum MapStyle: String {
        case rings
        case treemap
    }

    @Published var phase: Phase = .welcome
    @Published var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "mapStyle") ?? "") ?? .rings {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "mapStyle") }
    }
    /// The file shown in Quick Look; nil when the preview is closed.
    @Published var previewURL: URL?
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

    // Categories
    @Published private(set) var categories: [CategoryTotal] = []
    @Published private(set) var categoriesBusy = false
    private var categoriesGeneration = 0

    // System & hidden breakdown (whole-disk scans)
    @Published private(set) var hiddenSpace: HiddenSpace?
    @Published private(set) var hiddenBusy = false
    @Published var showHiddenSheet = false
    @Published var showRemoveSnapshotsConfirm = false

    // Find
    @Published var findText = "" { didSet { scheduleSearch() } }
    @Published var findKind: FileKind = .any { didSet { scheduleSearch() } }
    @Published var findMinSize: Int64 = 10_000_000 { didSet { scheduleSearch() } }
    @Published var findIncludeSystem = false { didSet { scheduleSearch() } }
    @Published private(set) var findResults: [FileNode] = []
    @Published private(set) var findBusy = false
    private var searchTask: Task<Void, Never>?

    // Recently removed, newest first, for Put Back.
    @Published private(set) var removals: [RemovalRecord] = Removals.load()

    // Quick Clean
    @Published private(set) var cleanItems: [CleanItem] = []
    @Published private(set) var cleanChosen: Set<String> = []
    /// Individual entries you unticked inside a cleanup line.
    @Published private(set) var cleanExcluded: Set<String> = []
    @Published private(set) var cleanBusy = false
    @Published var cleanEmptyTrash = false
    @Published private(set) var trashBytes: Int64 = 0
    @Published var showCleanConfirm = false
    private var cleanLoaded = false
    private var cleanKnown: Set<String> = []

    // Uninstall apps
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var appsBusy = false
    private var appsLoaded = false
    /// The app in the uninstall sheet; setting it to nil closes the sheet.
    @Published var uninstallTarget: InstalledApp?
    @Published private(set) var uninstallLeftovers: [Leftover] = []
    @Published private(set) var uninstallChosen: Set<String> = []
    @Published private(set) var uninstallSearching = false
    @Published private(set) var uninstallAppRunning = false
    @Published private(set) var uninstallNote: String?

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
    private var keyMonitor: Any?
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
        installKeyMonitor()

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
        case .map, .categories, .find, .apps, .removed: return 0
        case .quickClean: return 0
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
        hiddenSpace = nil
        refreshUntouched()
        refreshCategories()
        scheduleSearch()
    }

    // MARK: - Categories

    func refreshCategories() {
        guard let current = root else {
            categories = []
            return
        }
        categoriesGeneration += 1
        let generation = categoriesGeneration
        let homePath = home
        categoriesBusy = true
        Task { [weak self] in
            let totals = await Task.detached(priority: .utility) { () -> [CategoryTotal] in
                CategoryCounter.compute(root: current, home: homePath)
            }.value
            guard let self = self, generation == self.categoriesGeneration else { return }
            self.categories = totals
            self.categoriesBusy = false
        }
    }

    // MARK: - System & hidden

    /// Space a whole-disk scan can't see as files; nil for other scans.
    var hiddenBytes: Int64? {
        guard scannedRootPath == "/", let current = root, let disk = volume else { return nil }
        return max(0, disk.used - current.size)
    }

    func refreshHiddenSpace() {
        guard scannedRootPath == "/", let current = root, let disk = volume, !hiddenBusy else { return }
        hiddenBusy = true
        let scanned = current.size
        let unreadable = unreadableCount
        Task { [weak self] in
            let analysis = await Task.detached(priority: .userInitiated) { () -> HiddenSpace in
                HiddenSpaceAnalyzer.analyze(scanned: scanned, volume: disk, unreadableFolders: unreadable)
            }.value
            self?.hiddenSpace = analysis
            self?.hiddenBusy = false
        }
    }

    func openHiddenSpace() {
        showHiddenSheet = true
        if hiddenSpace == nil { refreshHiddenSpace() }
    }

    func removeLocalSnapshots() {
        hiddenBusy = true
        Task { [weak self] in
            let problem = await Task.detached(priority: .userInitiated) { () -> String? in
                HiddenSpaceAnalyzer.removeLocalSnapshots()
            }.value
            guard let self = self else { return }
            self.hiddenBusy = false
            if let problem = problem {
                if !problem.isEmpty { self.alertMessage = problem }
                return
            }
            self.volume = VolumeInfo.forPath(self.scannedRootPath)
            self.startupVolume = VolumeInfo.forPath("/")
            self.hiddenSpace = nil
            self.refreshHiddenSpace()
            self.showStatus("Removed the local Time Machine snapshots. macOS may take a minute to show the freed space.")
        }
    }

    // MARK: - Find

    func scheduleSearch() {
        searchTask?.cancel()
        guard let current = root else {
            findResults = []
            findBusy = false
            return
        }
        let query = SearchQuery(text: findText, kind: findKind, minSize: findMinSize, includeSystem: findIncludeSystem)
        findBusy = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let results = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
                FileSearch.run(root: current, query: query)
            }.value
            if Task.isCancelled { return }
            self?.findResults = results
            self?.findBusy = false
        }
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
        reveal(path: node.path, name: node.name, opensFolder: node.kind == .smallFiles)
    }

    func reveal(path: String, name: String, opensFolder: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else {
            alertMessage = "“\(name)” isn't there anymore. It may have been moved or deleted since the scan. Rescan to update the map."
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
                showStatus("Showing “\(name)” in Finder.")
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
                showStatus("Showing “\(name)” in Finder.")
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
            showStatus("Showing “\(name)” in Finder.")
            return
        }
        problems.append("NSWorkspace refused")

        alertMessage = "Finder couldn't show “\(name)”.\n\nLocation: \(path)\n\nDetails for Claude:\n" + problems.joined(separator: "\n")
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
        // Pieces of an app or a library (like a Photos library) must go with the whole thing.
        if node.insidePackage { return false }
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

    /// An app in Applications, which DiskMap removes with the uninstaller.
    func isInstalledApp(_ node: FileNode) -> Bool {
        node.isPackage && AppCatalog.isInstalledLocation(node.path, home: home)
    }

    func requestTrash(_ nodes: [FileNode]) {
        let allowed = nodes.filter { canTrash($0) }
        guard !allowed.isEmpty else { return }
        // A single installed app goes through the uninstaller, so its leftovers can go too.
        if allowed.count == 1, let node = allowed.first, isInstalledApp(node),
           let app = AppCatalog.describe(path: node.path, bytes: node.size) {
            beginUninstall(app)
            return
        }
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
        let targets = nodes.map { RemovalTarget(path: $0.path, name: $0.name, bytes: $0.size) }
        let outcome = remove(targets, reason: "Moved to Trash")
        if !outcome.failures.isEmpty {
            alertMessage = "Some items couldn't be moved to the Trash.\n\n" + outcome.failures.prefix(5).joined(separator: "\n")
                + "\n\nItems in system folders may need an administrator to remove."
        } else if outcome.moved > 0 {
            showStatus("Moved \(Fmt.bytes(outcome.moved)) to the Trash. You can put it back from Recently Removed.")
        }
    }

    /// The one way DiskMap removes things: move each to the Trash, remember it for Put Back,
    /// take it out of the tree and every list, and keep the saved scan in step.
    @discardableResult
    func remove(_ targets: [RemovalTarget], reason: String) -> (moved: Int64, failures: [String]) {
        var moved: Int64 = 0
        var failures: [String] = []
        var removedPaths: [String] = []
        var records: [RemovalRecord] = []
        let batch = UUID()
        for target in targets {
            do {
                let record = try Removals.trash(target, reason: reason, batch: batch)
                records.append(record)
                moved += target.bytes
                removedPaths.append(target.path)
                if let current = root, let node = ScanCache.find(target.path, in: current), node !== current {
                    node.detach()
                    forget(node)
                }
            } catch {
                failures.append("\(target.name): \(error.localizedDescription)")
            }
        }
        if !records.isEmpty {
            removals = Array(records.reversed()) + removals
            Removals.save(removals)
        }
        if showingSavedScan {
            ScanCache.recordRemoval(removedPaths)
        }
        if moved > 0 {
            treeVersion += 1
            rebuildChart()
            refreshCategories()
            hiddenSpace = nil
        }
        return (moved, failures)
    }

    // MARK: - Quick Look

    func preview(_ node: FileNode) {
        preview(path: node.path)
    }

    func preview(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            alertMessage = "“\((path as NSString).lastPathComponent)” isn't there anymore. Rescan to update the map."
            return
        }
        previewURL = URL(fileURLWithPath: path)
    }

    /// ⌘Y and Space: preview the selected item, or close the preview if it's open.
    func previewSelection() {
        if previewURL != nil {
            previewURL = nil
        } else if let node = selection {
            preview(node)
        }
    }

    /// Space previews the selection, as in Finder, except while typing in a text field.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Key events arrive on the main thread; newer compilers want that stated.
            #if compiler(>=5.9)
            let handled = MainActor.assumeIsolated { self?.handleSpace(event) ?? false }
            #else
            let handled = self?.handleSpace(event) ?? false
            #endif
            return handled ? nil : event
        }
    }

    private func handleSpace(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        if previewURL != nil {
            previewURL = nil
            return true
        }
        guard phase == .results, tab == .map, selection != nil,
              let window = NSApp.keyWindow, window.attachedSheet == nil, window.isVisible else { return false }
        // Typing a space in a search field or text box stays a space.
        if window.firstResponder is NSText { return false }
        previewSelection()
        return true
    }

    // MARK: - Quick Clean

    func loadCleanIfNeeded() {
        if !cleanLoaded { surveyClean() }
    }

    func surveyClean() {
        guard !cleanBusy else { return }
        cleanBusy = true
        cleanLoaded = true
        let homePath = home
        let running = RunningSnapshot.now()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> CleanSurvey in
                CleanSurvey(items: QuickClean.survey(home: homePath, running: running),
                            trash: Removals.diskUsage(of: homePath + "/.Trash"))
            }.value
            guard let self = self else { return }
            // Keep your ticks across checks; anything new starts at its default.
            let known = self.cleanKnown
            var chosen = self.cleanChosen
            for item in result.items where !known.contains(item.id) && item.defaultOn {
                chosen.insert(item.id)
            }
            self.cleanKnown = known.union(result.items.map { $0.id })
            self.cleanItems = result.items
            self.cleanChosen = chosen
            let paths = Set(result.items.flatMap { $0.entries.map { $0.path } })
            self.cleanExcluded = self.cleanExcluded.intersection(paths)
            self.trashBytes = result.trash
            self.cleanBusy = false
        }
    }

    func toggleClean(_ id: String) {
        if cleanChosen.contains(id) {
            cleanChosen.remove(id)
        } else {
            cleanChosen.insert(id)
        }
    }

    func toggleCleanEntry(_ entry: CleanEntry) {
        if cleanExcluded.contains(entry.path) {
            cleanExcluded.remove(entry.path)
        } else {
            cleanExcluded.insert(entry.path)
        }
    }

    /// What a cleanup line would remove, leaving out anything you unticked.
    func cleanEntries(_ item: CleanItem) -> [CleanEntry] {
        item.entries.filter { !cleanExcluded.contains($0.path) }
    }

    func cleanBytes(_ item: CleanItem) -> Int64 {
        var total: Int64 = 0
        for entry in cleanEntries(item) { total += entry.bytes }
        return total
    }

    var cleanTotal: Int64 {
        var total: Int64 = 0
        for item in cleanItems where cleanChosen.contains(item.id) {
            total += cleanBytes(item)
        }
        return total
    }

    var cleanSummary: String {
        let total = Fmt.bytes(cleanTotal)
        if cleanEmptyTrash {
            return "\(total) will be moved to the Trash, and then the Trash will be emptied. That can't be undone."
        }
        return "\(total) will be moved to the Trash. Recently Removed can put any of it back until you empty the Trash."
    }

    func runQuickClean() {
        var targets: [RemovalTarget] = []
        for item in cleanItems where cleanChosen.contains(item.id) {
            for entry in cleanEntries(item) {
                targets.append(RemovalTarget(path: entry.path, name: entry.name, bytes: entry.bytes))
            }
        }
        let outcome = remove(targets, reason: "Quick Clean")
        if cleanEmptyTrash {
            emptyTrash()
        }
        if !outcome.failures.isEmpty {
            alertMessage = "Some items couldn't be moved to the Trash, usually because an app was using them.\n\n"
                + outcome.failures.prefix(6).joined(separator: "\n")
        } else if outcome.moved > 0 {
            showStatus(cleanEmptyTrash
                       ? "Cleaned up \(Fmt.bytes(outcome.moved)) and emptied the Trash."
                       : "Moved \(Fmt.bytes(outcome.moved)) to the Trash. Empty the Trash to free the space.")
        }
        surveyClean()
    }

    // MARK: - Uninstall apps

    func loadAppsIfNeeded() {
        if !appsLoaded { refreshApps() }
    }

    func refreshApps() {
        guard !appsBusy else { return }
        appsBusy = true
        appsLoaded = true
        let homePath = home
        let current = root
        Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { () -> [InstalledApp] in
                AppCatalog.list(home: homePath) { path in
                    guard let tree = current, let node = ScanCache.find(path, in: tree) else { return nil }
                    return node.size
                }
            }.value
            guard let self = self else { return }
            self.apps = listed
            let unmeasured = listed.filter { !$0.isMeasured }.map { $0.path }
            if !unmeasured.isEmpty {
                let sizes = await Task.detached(priority: .utility) { () -> [String: Int64] in
                    Removals.diskUsage(ofEach: unmeasured)
                }.value
                for index in self.apps.indices {
                    if let size = sizes[self.apps[index].path] {
                        self.apps[index].bytes = size
                    }
                }
            }
            self.appsBusy = false
        }
    }

    /// Opens the uninstall sheet and looks for what the app left behind.
    func beginUninstall(_ app: InstalledApp) {
        guard !app.isProtected else {
            alertMessage = "\(app.name) comes with macOS, so it can't be removed."
            return
        }
        uninstallTarget = app
        uninstallLeftovers = []
        uninstallChosen = []
        uninstallNote = nil
        uninstallSearching = true
        uninstallAppRunning = RunningApps.isRunning(app)
        let homePath = home
        let known = apps
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> UninstallSearch in
                var target = app
                if !target.isMeasured {
                    target.bytes = Removals.diskUsage(of: app.path)
                }
                let everyApp = known.isEmpty ? AppCatalog.list(home: homePath, sizeFromScan: { _ in 0 }) : known
                let others = everyApp.filter { $0.path != app.path }
                var note: String?
                if app.bundleID == nil {
                    note = "This app doesn't say who it is, so DiskMap can only remove the app itself."
                } else if others.contains(where: { $0.bundleID?.lowercased() == app.bundleID?.lowercased() }) {
                    note = "Another copy of \(app.name) is installed, so its settings and data are kept."
                }
                var leftovers = LeftoverFinder.find(for: app, others: others, home: homePath)
                for index in leftovers.indices {
                    leftovers[index].bytes = Removals.diskUsage(of: leftovers[index].path)
                }
                leftovers.sort { $0.bytes > $1.bytes }
                return UninstallSearch(app: target, leftovers: leftovers, note: note)
            }.value
            guard let self = self, self.uninstallTarget?.path == app.path else { return }
            self.uninstallTarget = result.app
            self.uninstallLeftovers = result.leftovers
            self.uninstallChosen = Set(result.leftovers.filter { !$0.systemWide }.map { $0.path })
            self.uninstallNote = result.note
            self.uninstallSearching = false
        }
    }

    func toggleLeftover(_ leftover: Leftover) {
        if uninstallChosen.contains(leftover.path) {
            uninstallChosen.remove(leftover.path)
        } else {
            uninstallChosen.insert(leftover.path)
        }
    }

    var uninstallTotal: Int64 {
        var total = max(uninstallTarget?.bytes ?? 0, 0)
        for leftover in uninstallLeftovers where uninstallChosen.contains(leftover.path) {
            total += max(leftover.bytes, 0)
        }
        return total
    }

    func quitAppForUninstall() {
        guard let app = uninstallTarget else { return }
        RunningApps.quit(app)
        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !RunningApps.isRunning(app) { break }
            }
            self?.uninstallAppRunning = RunningApps.isRunning(app)
        }
    }

    func cancelUninstall() {
        uninstallTarget = nil
    }

    func confirmUninstall() {
        guard let app = uninstallTarget else { return }
        if RunningApps.isRunning(app) {
            uninstallAppRunning = true
            return
        }
        var targets = [RemovalTarget(path: app.path, name: (app.path as NSString).lastPathComponent, bytes: max(app.bytes, 0))]
        for leftover in uninstallLeftovers where uninstallChosen.contains(leftover.path) {
            targets.append(RemovalTarget(path: leftover.path, name: leftover.name, bytes: max(leftover.bytes, 0)))
        }
        uninstallTarget = nil
        let outcome = remove(targets, reason: "Uninstalled \(app.name)")
        if !FileManager.default.fileExists(atPath: app.path) {
            apps.removeAll { $0.path == app.path }
        }
        if !outcome.failures.isEmpty {
            let message = "Some of \(app.name)'s files couldn't be moved to the Trash.\n\n"
                + outcome.failures.prefix(6).joined(separator: "\n")
                + "\n\nSystem-wide items usually need an administrator. You can remove them in Finder, which will ask for your password."
            // Let the sheet close before the alert appears.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.alertMessage = message
            }
        } else if outcome.moved > 0 {
            showStatus("Uninstalled \(app.name), freeing \(Fmt.bytes(outcome.moved)). Recently Removed can put it back.")
        }
    }

    // MARK: - Put Back

    /// Moves an item back from the Trash and adds it to the map again.
    func putBack(_ record: RemovalRecord) {
        putBack([record])
    }

    /// Moves items back from the Trash to where they were and adds them to the map again.
    func putBack(_ records: [RemovalRecord]) {
        var problems: [String] = []
        var restored: [RemovalRecord] = []
        for record in records where record.canPutBack {
            if let problem = Removals.putBack(record) {
                problems.append(problem)
                continue
            }
            if let index = removals.firstIndex(where: { $0.id == record.id }) {
                removals[index].restored = true
            }
            restored.append(record)
        }
        if !restored.isEmpty {
            Removals.save(removals)
            let paths = restored.map { $0.originalPath }
            ScanCache.unrecordRemovals(paths)
            restoreInMap(paths)
            // Lists that read the disk directly look again next time they're opened.
            appsLoaded = false
            cleanLoaded = false
            if tab == .apps { refreshApps() }
            if tab == .quickClean { surveyClean() }
            if restored.count == 1, let only = restored.first {
                showStatus("Put “\(only.name)” back where it was.")
            } else {
                showStatus("Put \(restored.count) items back where they were.")
            }
        }
        if !problems.isEmpty {
            alertMessage = problems.prefix(6).joined(separator: "\n\n")
        }
    }

    /// Adds things that are back on disk to the map without a full rescan.
    /// Folders are measured off the main thread; files are picked up by re-listing their folder.
    private func restoreInMap(_ paths: [String]) {
        guard let current = root else { return }
        var folderJobs: [(parent: FileNode, path: String, name: String)] = []
        var fileParents: [FileNode] = []
        let fm = FileManager.default

        for restoredPath in paths {
            // The deepest folder still in the map above the item's location.
            var folderPath = (restoredPath as NSString).deletingLastPathComponent
            var folder = ScanCache.find(folderPath, in: current)
            while folder == nil && folderPath.count > 1 {
                folderPath = (folderPath as NSString).deletingLastPathComponent
                folder = ScanCache.find(folderPath, in: current)
            }
            guard let parent = folder, parent.isDirectory else { continue }

            // The item itself, or the folder that holds it if its folder was removed too.
            let base = parent.path
            let remainder = restoredPath.dropFirst(base == "/" ? 1 : base.count + 1)
            guard let first = remainder.split(separator: "/").first else { continue }
            let childName = String(first)
            let childPath = base == "/" ? "/" + childName : base + "/" + childName
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: childPath, isDirectory: &isFolder) else { continue }
            if parent.children.contains(where: { $0.kind != .smallFiles && $0.name == childName }) { continue }

            if isFolder.boolValue {
                if !folderJobs.contains(where: { $0.path == childPath }) {
                    folderJobs.append((parent: parent, path: childPath, name: childName))
                }
            } else if !fileParents.contains(where: { $0 === parent }) {
                fileParents.append(parent)
            }
        }
        guard !folderJobs.isEmpty || !fileParents.isEmpty else { return }

        let jobs = folderJobs.map { [$0.path, $0.name] }
        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) { () -> [LoadedScan] in
                jobs.map { job in
                    let node = DiskScanner().scan(rootPath: job[0], displayName: job[1])
                    node.rootPath = nil
                    return LoadedScan(root: node, previous: nil)
                }
            }.value
            guard let self = self, self.root === current else { return }
            for (index, job) in folderJobs.enumerated() {
                let parent = job.parent
                if parent.children.contains(where: { $0.kind == .directory && $0.name == job.name }) { continue }
                let fresh = scanned[index].root
                fresh.parent = parent
                parent.children.append(fresh)
                var ancestor: FileNode? = parent
                while let node = ancestor {
                    node.size += fresh.size
                    node.itemCount += fresh.itemCount
                    node.children.sort { $0.size > $1.size }
                    ancestor = node.parent
                }
            }
            // Files last, so the folders just added are kept rather than read again.
            for parent in fileParents {
                DiskScanner().refresh(parent, deep: false)
            }
            self.afterTreeChange()
        }
    }

    /// Refreshes everything that's computed from the tree.
    private func afterTreeChange() {
        treeVersion += 1
        rebuildChart()
        refreshCategories()
        hiddenSpace = nil
        if let top = root {
            ideas = IdeaFinder.find(root: top, explainer: explainer)
        }
    }

    func clearRemovalHistory() {
        removals = []
        Removals.save([])
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
        findResults.removeAll { $0.isDescendant(of: node) }
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
        trashBytes = 0
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
            refreshCategories()
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
