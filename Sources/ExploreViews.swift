import SwiftUI
import AppKit

extension StorageCategory {
    var colors: [Color] {
        switch self {
        case .apps: return Palette.blue
        case .documents: return Palette.cyan
        case .downloads: return Palette.teal
        case .photos: return Palette.amber
        case .media: return Palette.pink
        case .icloud: return [Color(red: 0.55, green: 0.80, blue: 1.0), Color(red: 0.30, green: 0.62, blue: 0.95)]
        case .mail: return Palette.indigo
        case .developer: return Palette.purple
        case .caches: return Palette.green
        case .backups: return Palette.orange
        case .appData: return Palette.brown
        case .trash: return Palette.red
        case .otherUsers: return [Color(red: 0.70, green: 0.70, blue: 0.80), Color(red: 0.50, green: 0.50, blue: 0.62)]
        case .macOS: return Palette.graphite
        case .other: return [Color(red: 0.80, green: 0.80, blue: 0.80), Color(red: 0.62, green: 0.62, blue: 0.62)]
        }
    }
}

// MARK: - Categories

struct CategoriesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .categories, title: title, summary: summary) {
                if model.categoriesBusy {
                    ProgressView().controlSize(.small)
                }
            }

            StorageMeter(segments: meterSegments, total: meterTotal, height: 16, showLegend: false)

            if model.categories.isEmpty && !model.categoriesBusy {
                EmptyState(symbol: "square.stack.3d.up", title: "Nothing to sort yet", message: "Scan your disk or home folder to see it by category.")
                    .frame(height: 260)
            } else {
                CardList {
                    ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, total in
                        if index > 0 {
                            Divider().padding(.leading, 58)
                        }
                        CategoryRow(total: total, share: share(total.bytes))
                    }
                    if let hidden = model.hiddenBytes, hidden > 0 {
                        Divider().padding(.leading, 58)
                        HiddenCategoryRow(bytes: hidden, share: share(hidden))
                    }
                }
            }
        }
    }

    private var usedTotal: Int64 {
        var sum: Int64 = model.hiddenBytes ?? 0
        for total in model.categories { sum += total.bytes }
        return max(sum, 1)
    }

    private func share(_ bytes: Int64) -> Double {
        Double(bytes) / Double(usedTotal)
    }

    private var title: String {
        if model.scannedRootPath == "/", let disk = model.volume {
            return "\(Fmt.bytes(disk.used)) used of \(Fmt.bytes(disk.total))"
        }
        return "\(Fmt.bytes(model.root?.size ?? 0)) in \(model.root?.name ?? "this folder")"
    }

    private var summary: String {
        "Like the Storage page in System Settings, but counted from this scan. Click a category to see its biggest items."
    }

    private var meterTotal: Int64 {
        if model.scannedRootPath == "/", let disk = model.volume { return max(disk.total, 1) }
        return usedTotal
    }

    private var meterSegments: [MeterSegment] {
        var segments = model.categories.map { MeterSegment(label: $0.category.title, value: $0.bytes, colors: $0.category.colors) }
        if let hidden = model.hiddenBytes, hidden > 0 {
            segments.append(MeterSegment(label: "System & hidden", value: hidden, colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.45)]))
        }
        return segments
    }
}

struct CategoryRow: View {
    @EnvironmentObject var model: AppModel
    let total: CategoryTotal
    let share: Double
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: total.category.symbol, colors: total.category.colors, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(total.category.title)
                            .font(.body.weight(.medium))
                        Text(total.category.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Fmt.bytes(total.bytes))
                            .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        SizeBar(fraction: share, colors: total.category.colors)
                            .frame(width: 90, height: 4)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(total.items.prefix(15)) { item in
                        Divider().padding(.leading, 58)
                        HStack(spacing: 10) {
                            FileIcon(node: item.node, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.node.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(model.shortPath(item.node))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(Fmt.bytes(item.bytes))
                                .font(.system(.callout, design: .rounded).monospacedDigit())
                            ItemActions(node: item.node)
                        }
                        .padding(.leading, 58)
                        .padding(.trailing, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .draggable(item.node.path)
                    }
                    if total.items.count > 15 {
                        Divider().padding(.leading, 58)
                        Text("Showing the 15 biggest. Use the Map or Find to see the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 58)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

struct HiddenCategoryRow: View {
    @EnvironmentObject var model: AppModel
    let bytes: Int64
    let share: Double

    var body: some View {
        Button {
            model.openHiddenSpace()
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "eye.slash.fill", colors: Palette.graphite, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System & hidden")
                        .font(.body.weight(.medium))
                    Text("Swap, startup files, snapshots and folders DiskMap can't read. Click for the breakdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Fmt.bytes(bytes))
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    SizeBar(fraction: share, colors: Palette.graphite)
                        .frame(width: 90, height: 4)
                }
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System & hidden

struct HiddenSpaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "eye.slash.fill", colors: Palette.graphite, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's in System & hidden")
                        .font(.title2.weight(.semibold))
                    Text("Space on \(model.diskName) that a scan can't see as files.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let hidden = model.hiddenSpace {
                StorageMeter(
                    segments: hidden.parts.map { MeterSegment(label: $0.title, value: $0.bytes, colors: colors(for: $0.kind)) },
                    total: max(hidden.total, 1),
                    height: 12,
                    showLegend: false
                )
                CardList {
                    ForEach(Array(hidden.parts.enumerated()), id: \.element.id) { index, part in
                        if index > 0 {
                            Divider().padding(.leading, 54)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(symbol: symbol(for: part.kind), colors: colors(for: part.kind), size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(part.title)
                                    .font(.body.weight(.medium))
                                Text(part.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(Fmt.bytes(part.bytes))
                                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        }
                        .padding(12)
                    }
                }

                if hidden.purgeable > 0 {
                    Label("macOS can free about \(Fmt.bytes(hidden.purgeable)) of the disk on its own when it needs room (cached iCloud files, old snapshots and the like).",
                          systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let newest = hidden.snapshotDates.first, let oldest = hidden.snapshotDates.last {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshotText(count: hidden.snapshotDates.count, newest: newest, oldest: oldest))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Remove Local Snapshots…") { model.showRemoveSnapshotsConfirm = true }
                                .disabled(model.hiddenBusy)
                            Text("Backups on your Time Machine disk aren't affected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking macOS how this space is used…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }

            HStack {
                if model.hiddenBusy && model.hiddenSpace != nil {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
        .alert("Remove local snapshots?", isPresented: $model.showRemoveSnapshotsConfirm) {
            Button("Remove", role: .destructive) { model.removeLocalSnapshots() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the copies Time Machine keeps on this Mac between backups. Backups on your Time Machine disk aren't affected. macOS will ask for your password.")
        }
    }

    private func snapshotText(count: Int, newest: Date, oldest: Date) -> String {
        if count == 1 {
            return "There's 1 local Time Machine snapshot, from \(Fmt.dateTime(newest)). It keeps files you've since deleted or changed until macOS needs the space."
        }
        return "There are \(count) local Time Machine snapshots, from \(Fmt.dateTime(oldest)) to \(Fmt.dateTime(newest)). They keep files you've since deleted or changed until macOS needs the space."
    }

    private func symbol(for kind: HiddenPart.Kind) -> String {
        switch kind {
        case .swap: return "memorychip"
        case .startup: return "power"
        case .snapshotsAndProtected: return "clock.arrow.circlepath"
        case .unknown: return "questionmark"
        }
    }

    private func colors(for kind: HiddenPart.Kind) -> [Color] {
        switch kind {
        case .swap: return Palette.purple
        case .startup: return Palette.blue
        case .snapshotsAndProtected: return Palette.graphite
        case .unknown: return Palette.graphite
        }
    }
}

// MARK: - Find

struct FindTab: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .find, title: title, summary: summary) {
                if model.findBusy {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by name", text: $model.findText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !model.findText.isEmpty {
                        Button {
                            model.findText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))

                Picker("Kind", selection: $model.findKind) {
                    ForEach(FileKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Picker("Size", selection: $model.findMinSize) {
                    Text("Any size").tag(Int64(0))
                    Text("10 MB or more").tag(Int64(10_000_000))
                    Text("100 MB or more").tag(Int64(100_000_000))
                    Text("1 GB or more").tag(Int64(1_000_000_000))
                }
                .labelsHidden()
                .fixedSize()
            }

            Toggle("Include macOS and the insides of apps and libraries", isOn: $model.findIncludeSystem)
                .font(.callout)

            if model.findResults.isEmpty && !model.findBusy {
                EmptyState(symbol: "magnifyingglass",
                           title: "No matches",
                           message: "Try fewer letters, another kind or a smaller size. Files under 1 MB aren't listed one by one, since DiskMap groups them per folder.")
                    .frame(height: 260)
            } else {
                CardList {
                    ForEach(Array(model.findResults.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        FindRow(node: node, largest: model.findResults.first?.size ?? 1)
                            .draggable(node.path)
                    }
                }
            }
        }
        .onAppear { searchFocused = true }
    }

    private var title: String {
        let searching = !model.findText.trimmingCharacters(in: .whitespaces).isEmpty || model.findKind != .any
        if !searching { return "Largest files" }
        if model.findResults.isEmpty { return "Find" }
        var total: Int64 = 0
        for node in model.findResults { total += node.size }
        let count = model.findResults.count
        let capped = count >= FileSearch.limit ? "Top \(count)" : "\(count)"
        return "\(capped) \(count == 1 ? "match" : "matches"), \(Fmt.bytes(total))"
    }

    private var summary: String {
        "Search the whole scan by name, or pick a kind to list the biggest videos, installers, archives and more."
    }
}

struct FindRow: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let largest: Int64

    var body: some View {
        let explanation = model.explainer.explain(node)
        HStack(spacing: 12) {
            FileIcon(node: node, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let explanation = explanation, node.kind != .smallFiles {
                    HStack(spacing: 4) {
                        Image(systemName: explanation.safety.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(explanation.safety.color)
                        Text(explanation.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(model.shortPath(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(node.size))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                SizeBar(fraction: Double(node.size) / Double(max(largest, 1)), colors: Palette.amber)
                    .frame(width: 90, height: 4)
                if let modified = node.modified {
                    Text("Changed \(Fmt.relative(modified))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ItemActions(node: node)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
