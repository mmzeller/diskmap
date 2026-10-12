import SwiftUI
import AppKit
import QuickLook

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                phaseView
                    .alert("Move to Trash?", isPresented: $model.showTrashConfirm) {
                        Button("Move to Trash", role: .destructive) { model.confirmTrash() }
                        Button("Cancel", role: .cancel) { model.pendingTrash = [] }
                    } message: {
                        Text(model.pendingTrashSummary)
                    }
            }
            .alert("Empty the Trash?", isPresented: $model.showEmptyTrashConfirm) {
                Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything in the Trash will be permanently deleted. This can't be undone.")
            }
        }
        .alert("DiskMap", isPresented: $model.showAlert) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: $updater.showSheet) {
            UpdateSheet()
                .environmentObject(updater)
        }
        .frame(minWidth: 1060, minHeight: 680)
    }

    @ViewBuilder
    private var phaseView: some View {
        switch model.phase {
        case .welcome:
            WelcomeView()
        case .loading:
            LoadingView()
        case .scanning:
            ScanningView()
        case .results:
            MainView()
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
        } detail: {
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sheet(item: $model.uninstallTarget) { _ in
                    UninstallSheet()
                        .environmentObject(model)
                }
                .navigationTitle(model.root?.name ?? "DiskMap")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let release = updater.available {
                            Button {
                                updater.showAvailable()
                            } label: {
                                Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
                                    .labelStyle(.titleAndIcon)
                            }
                            .help("A new version of DiskMap is available")
                        }
                        Menu {
                            Button("Scan \(model.diskName)") { model.scanDisk() }
                            Button("Scan Home Folder") { model.scanHome() }
                            Button("Choose Folder…") { model.chooseFolder() }
                            Divider()
                            Button("Full Rescan (read every folder)") { model.fullRescan() }
                            Button("Back to Start") { model.backToStart() }
                        } label: {
                            Label("New Scan", systemImage: "internaldrive")
                        }
                        .help("Scan something else")

                        Button {
                            model.rescan()
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .help("Update the scan; only folders that changed are read again")
                    }
                }
        }
        .sheet(isPresented: $model.showHiddenSheet) {
            HiddenSpaceSheet()
                .environmentObject(model)
        }
        .overlay(alignment: .bottom) {
            if let message = model.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(message)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var subtitle: String {
        guard let date = model.scanDate else { return "" }
        if model.scanIsAutomatic {
            return "Updated by the automatic check \(Fmt.relative(date))"
        }
        return "Scanned \(Fmt.relative(date)), took \(Fmt.duration(model.scanDuration))"
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .map:
            MapTab()
        case .categories:
            CategoriesTab()
        case .find:
            FindTab()
        case .quickClean:
            QuickCleanTab()
        case .ideas:
            IdeasTab()
        case .growth:
            GrowthTab()
        case .untouched:
            UntouchedTab()
        case .duplicates:
            DuplicatesTab()
        case .apps:
            AppsTab()
        case .basket:
            BasketTab()
        case .removed:
            RemovedTab()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedTab) {
            Section("Explore") {
                row(.map)
                row(.categories)
                row(.find)
            }
            Section("Clean Up") {
                row(.quickClean)
                row(.ideas)
                row(.growth)
                row(.untouched)
                row(.duplicates)
            }
            Section("Remove") {
                row(.apps)
                row(.basket)
                row(.removed)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStorage()
                .padding(12)
        }
    }

    private func row(_ tab: AppModel.Tab) -> some View {
        Label {
            Text(tab.rawValue)
        } icon: {
            IconTile(symbol: tab.symbol, colors: tab.colors, size: 20)
        }
        .badge(model.badgeCount(for: tab))
        // Only the basket row accepts items dragged from the lists.
        .dropDestination(for: String.self) { paths, _ in
            guard tab == .basket else { return false }
            model.addToBasket(paths: paths)
            return true
        }
        .tag(tab)
    }
}

/// Disk usage summary pinned to the bottom of the sidebar.
struct SidebarStorage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let volume = model.startupVolume {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconTile(symbol: "internaldrive.fill", colors: Palette.graphite, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(volume.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("\(Fmt.bytes(volume.available)) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                StorageMeter(
                    segments: [MeterSegment(label: "Used", value: volume.used, colors: usedColors(volume))],
                    total: volume.total,
                    height: 6,
                    showLegend: false
                )
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private func usedColors(_ volume: VolumeInfo) -> [Color] {
        let freeShare = Double(volume.available) / Double(max(volume.total, 1))
        return freeShare < 0.1 ? Palette.orange : Palette.blue
    }
}
