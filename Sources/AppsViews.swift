import SwiftUI

// MARK: - Uninstall Apps

struct AppsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var sort: AppSort = .size
    @State private var filter = ""

    enum AppSort: String, CaseIterable, Identifiable {
        case size = "Size"
        case lastOpened = "Last Opened"
        case name = "Name"

        var id: String { rawValue }
    }

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .apps, title: title,
                       summary: "Removes an app along with the settings, caches and data it keeps in your Library. Everything goes to the Trash, and Recently Removed can put it back.") {
                Button {
                    model.refreshApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.appsBusy)
            }

            HStack(spacing: 12) {
                TextField("Filter apps", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                if model.appsBusy && !model.apps.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Sort by", selection: $sort) {
                    ForEach(AppSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }

            if model.apps.isEmpty && model.appsBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking at your apps…")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            } else if visible.isEmpty {
                Text(filter.isEmpty ? "No apps found in Applications." : "No apps match “\(filter)”.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            } else {
                CardList {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        AppRow(app: app)
                    }
                }
                Text("Apps that come with macOS are shown dimmed; macOS needs them and would put them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.loadAppsIfNeeded() }
    }

    private var title: String {
        let removable = model.apps.filter { !$0.isProtected }
        guard !removable.isEmpty else { return "Uninstall Apps" }
        var total: Int64 = 0
        for app in removable where app.isMeasured { total += app.bytes }
        return "\(removable.count) apps using \(Fmt.bytes(total))"
    }

    private var visible: [InstalledApp] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var list = model.apps
        if !query.isEmpty {
            list = list.filter { $0.name.lowercased().contains(query) || ($0.bundleID?.lowercased().contains(query) ?? false) }
        }
        switch sort {
        case .size:
            list.sort { $0.bytes > $1.bytes }
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastOpened:
            // Longest unused first; apps with no record of being opened come first of all.
            list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
        // Apps that come with macOS go last whatever the order.
        return list.filter { !$0.isProtected } + list.filter { $0.isProtected }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            PathIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let version = app.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if app.fromAppStore {
                        Text("App Store")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundColor(Palette.blue[1])
                            .background(Capsule().fill(Palette.blue[1].opacity(0.13)))
                    }
                }
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if app.isMeasured {
                Text(Fmt.bytes(app.bytes))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Uninstall…") {
                model.beginUninstall(app)
            }
            .disabled(app.isProtected)
            .help(app.isProtected ? "Comes with macOS" : "Remove \(app.name) and the files it left behind")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(app.isProtected ? 0.5 : 1)
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(path: app.path, name: app.name) }
            Button("Quick Look") { model.preview(path: app.path) }
            if !app.isProtected {
                Divider()
                Button("Uninstall…") { model.beginUninstall(app) }
            }
        }
    }

    private var usage: String {
        if app.isProtected { return "Comes with macOS" }
        if let date = app.lastUsed { return "Last opened \(Fmt.relative(date))" }
        return "No record of being opened"
    }
}

// MARK: - Uninstall sheet

struct UninstallSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let app = model.uninstallTarget {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    PathIcon(path: app.path, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Uninstall \(app.name)")
                            .font(.title2.weight(.semibold))
                        Text("The app and the files it keeps in your Library go to the Trash. Recently Removed can put them back.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.uninstallAppRunning {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("\(app.name) is open. Quit it first so it doesn't write its files again.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Quit \(app.name)") { model.quitAppForUninstall() }
                    }
                    .font(.callout)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
                }

                if let note = model.uninstallNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    CardList {
                        UninstallItemRow(path: app.path, title: app.name, detail: "The app itself",
                                         bytes: app.bytes, checked: true, locked: true, note: nil) {}
                        if model.uninstallSearching {
                            Divider().padding(.leading, 76)
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Looking for files it left behind…")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(12)
                        } else if model.uninstallLeftovers.isEmpty && model.uninstallNote == nil {
                            Divider().padding(.leading, 76)
                            Text("Nothing else found in your Library for this app.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        ForEach(model.uninstallLeftovers) { leftover in
                            Divider().padding(.leading, 76)
                            UninstallItemRow(path: leftover.path, title: leftover.name,
                                             detail: leftover.kind + " · " + model.explainer.relative(leftover.path),
                                             bytes: leftover.bytes,
                                             checked: model.uninstallChosen.contains(leftover.path),
                                             locked: false, note: note(for: leftover)) {
                                model.toggleLeftover(leftover)
                            }
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 340)

                HStack(spacing: 10) {
                    Text("\(Fmt.bytes(model.uninstallTotal)) will go to the Trash")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Cancel") { model.cancelUninstall() }
                        .keyboardShortcut(.cancelAction)
                    Button("Uninstall") { model.confirmUninstall() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.uninstallSearching || model.uninstallAppRunning)
                }
            }
            .padding(22)
            .frame(width: 620)
        }
    }

    private func note(for leftover: Leftover) -> String? {
        if leftover.systemWide { return "Shared by all users; may need an administrator" }
        if leftover.byNameOnly { return "Matched by name, so check it's this app's" }
        return nil
    }
}

struct UninstallItemRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let title: String
    let detail: String
    let bytes: Int64
    let checked: Bool
    let locked: Bool
    let note: String?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckButton(checked: checked, disabled: locked, action: toggle)
            PathIcon(path: path, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            Spacer(minLength: 8)
            Text(bytes >= 0 ? Fmt.bytes(bytes) : "—")
                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
            Button {
                model.reveal(path: path, name: title)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !locked { toggle() }
        }
    }
}
