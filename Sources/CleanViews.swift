import SwiftUI

// MARK: - Quick Clean

struct QuickCleanTab: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .quickClean, title: title,
                       summary: "Routine cleanups in one go. Everything goes to the Trash first, so Recently Removed can put any of it back.") {
                Button {
                    model.surveyClean()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.cleanBusy)
            }

            if model.cleanItems.isEmpty {
                if model.cleanBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Measuring caches, logs and leftovers…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Nothing to clean right now")
                            .font(.title3.weight(.semibold))
                        Text("No caches, logs or leftovers worth removing were found.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                StorageMeter(segments: segments, total: max(1, everything), height: 10)

                CardList {
                    ForEach(Array(model.cleanItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.leading, 82)
                        }
                        CleanItemRow(item: item, expanded: expanded.contains(item.id)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expanded.contains(item.id) {
                                    expanded.remove(item.id)
                                } else {
                                    expanded.insert(item.id)
                                }
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    CheckButton(checked: model.cleanEmptyTrash) {
                        model.cleanEmptyTrash.toggle()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Empty the Trash when done")
                            .font(.body.weight(.medium))
                        Text(trashExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

                HStack {
                    if model.cleanBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking again…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.showCleanConfirm = true
                    } label: {
                        Label("Clean Up \(Fmt.bytes(model.cleanTotal))", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.cleanTotal == 0 || model.cleanBusy)
                }
            }
        }
        .onAppear { model.loadCleanIfNeeded() }
        .alert("Clean up now?", isPresented: $model.showCleanConfirm) {
            Button(confirmLabel, role: .destructive) {
                model.runQuickClean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.cleanSummary)
        }
    }

    private var confirmLabel: String {
        model.cleanEmptyTrash ? "Clean Up and Empty Trash" : "Move to Trash"
    }

    private var title: String {
        if model.cleanItems.isEmpty { return "Quick Clean" }
        return "\(Fmt.bytes(model.cleanTotal)) ready to clean"
    }

    private var everything: Int64 {
        var total: Int64 = 0
        for item in model.cleanItems { total += item.bytes }
        return total
    }

    private var segments: [MeterSegment] {
        model.cleanItems.filter { model.cleanChosen.contains($0.id) }.map { item in
            MeterSegment(label: item.title, value: model.cleanBytes(item), colors: CleanItemRow.colors(for: item.id))
        }
    }

    private var trashExplanation: String {
        var text = "Moving things to the Trash doesn't free space until the Trash is emptied. With this on, everything above (and whatever was already in the Trash) is deleted for good."
        if model.trashBytes > 0 {
            text += " The Trash holds \(Fmt.bytes(model.trashBytes)) now."
        }
        return text
    }
}

struct CleanItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: CleanItem
    let expanded: Bool
    let toggleExpanded: () -> Void

    static let shownEntries = 80

    static func colors(for id: String) -> [Color] {
        switch id {
        case "caches": return Palette.blue
        case "logs": return Palette.graphite
        case "homebrew": return Palette.amber
        case "devcaches": return Palette.green
        case "xcode": return Palette.cyan
        case "simulator": return Palette.teal
        case "devicesupport": return Palette.indigo
        case "mail": return Palette.brown
        case "backups": return Palette.pink
        case "installers": return Palette.orange
        case "orphans": return Palette.purple
        default: return Palette.graphite
        }
    }

    var body: some View {
        let chosen = model.cleanChosen.contains(item.id)
        let included = model.cleanEntries(item).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CheckButton(checked: chosen) { model.toggleClean(item.id) }
                    .padding(.top, 6)
                IconTile(symbol: item.symbol, colors: CleanItemRow.colors(for: item.id), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = item.note {
                        Text(note)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(model.cleanBytes(item)))
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundColor(chosen ? .primary : .secondary)
                    Text(included == item.entries.count ? countText(item.entries.count) : "\(included) of \(item.entries.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .help(expanded ? "Hide the list" : "Show what's included")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(item.entries.prefix(CleanItemRow.shownEntries), id: \.path) { entry in
                        CleanEntryRow(entry: entry, included: !model.cleanExcluded.contains(entry.path))
                    }
                    if item.entries.count > CleanItemRow.shownEntries {
                        Text("and \(item.entries.count - CleanItemRow.shownEntries) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 82)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(Fmt.count(count)) items"
    }
}

struct CleanEntryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: CleanEntry
    let included: Bool

    var body: some View {
        HStack(spacing: 8) {
            CheckButton(checked: included) { model.toggleCleanEntry(entry) }
            PathIcon(path: entry.path, size: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(included ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(Fmt.bytes(entry.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                model.preview(path: entry.path)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quick Look")
            Button {
                model.reveal(path: entry.path, name: entry.name)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

// MARK: - Recently Removed

/// Removals made together, shown as one row.
struct RemovalGroup: Identifiable {
    let id: UUID
    let records: [RemovalRecord]

    var first: RemovalRecord { records[0] }
    var bytes: Int64 {
        var total: Int64 = 0
        for record in records { total += record.bytes }
        return total
    }
    var title: String { records.count == 1 ? first.name : first.reason }

    static func make(from records: [RemovalRecord]) -> [RemovalGroup] {
        var order: [UUID] = []
        var members: [UUID: [RemovalRecord]] = [:]
        for record in records {
            let key = record.batch ?? record.id
            if members[key] == nil {
                order.append(key)
                members[key] = []
            }
            members[key]?.append(record)
        }
        return order.map { RemovalGroup(id: $0, records: members[$0] ?? []) }
    }
}

struct RemovedTab: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<UUID> = []
    @State private var confirmClear = false

    var body: some View {
        let groups = RemovalGroup.make(from: model.removals)
        PaneScroll {
            PaneHeader(tab: .removed, title: "Recently Removed",
                       summary: "Everything DiskMap moved to the Trash. While it's still in the Trash, Put Back returns it to where it was.") {
                if !model.removals.isEmpty {
                    Button("Clear History…") { confirmClear = true }
                        .help("Forget this list. Nothing in the Trash is touched.")
                }
            }

            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Nothing removed yet")
                        .font(.title3.weight(.semibold))
                    Text("When DiskMap moves something to the Trash, it's listed here so you can put it back.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else {
                CardList {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        RemovalGroupRow(group: group, expanded: expanded.contains(group.id)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expanded.contains(group.id) {
                                    expanded.remove(group.id)
                                } else {
                                    expanded.insert(group.id)
                                }
                            }
                        }
                    }
                }
                Text("Once the Trash is emptied, items can't be put back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Clear the history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearRemovalHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DiskMap forgets this list. Items stay in the Trash, and Finder's Put Back still works for them.")
        }
    }
}

struct RemovalGroupRow: View {
    @EnvironmentObject var model: AppModel
    let group: RemovalGroup
    let expanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        let returnable = group.records.filter { $0.canPutBack }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(Fmt.bytes(group.bytes))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                if !returnable.isEmpty {
                    Button(putBackLabel(returnable.count)) {
                        model.putBack(returnable)
                    }
                } else {
                    Text(status(group.records))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if group.records.count > 1 {
                    Button(action: toggleExpanded) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(expanded ? "Hide the items" : "Show the items")
                } else if let trashPath = group.first.trashPath, group.first.canPutBack {
                    Button {
                        model.reveal(path: trashPath, name: group.first.name)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show in the Trash")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.records.prefix(200)) { record in
                        RemovalRecordRow(record: record)
                    }
                    if group.records.count > 200 {
                        Text("and \(group.records.count - 200) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if group.records.count == 1, let trashPath = group.first.trashPath, group.first.canPutBack {
            PathIcon(path: trashPath, size: 32)
        } else {
            IconTile(symbol: symbol, colors: colors, size: 32)
        }
    }

    private var symbol: String {
        let reason = group.first.reason
        if reason.hasPrefix("Uninstalled") { return "square.grid.2x2.fill" }
        if reason == "Quick Clean" { return "wand.and.stars" }
        return "trash.fill"
    }

    private var colors: [Color] {
        let reason = group.first.reason
        if reason.hasPrefix("Uninstalled") { return Palette.purple }
        if reason == "Quick Clean" { return Palette.cyan }
        return Palette.graphite
    }

    private var subtitle: String {
        let when = Fmt.relative(group.first.date)
        if group.records.count == 1 {
            return "\(group.first.reason) \(when) · from \(model.explainer.relative((group.first.originalPath as NSString).deletingLastPathComponent))"
        }
        return "\(Fmt.count(group.records.count)) items · \(when)"
    }

    private func putBackLabel(_ count: Int) -> String {
        count == group.records.count ? "Put Back" : "Put Back \(count)"
    }

    private func status(_ records: [RemovalRecord]) -> String {
        if records.allSatisfy({ $0.restored }) { return "Put back" }
        if records.contains(where: { $0.restored }) { return "Partly put back" }
        return "Deleted from the Trash"
    }
}

struct RemovalRecordRow: View {
    @EnvironmentObject var model: AppModel
    let record: RemovalRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(record.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(model.explainer.relative((record.originalPath as NSString).deletingLastPathComponent))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text(Fmt.bytes(record.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if record.canPutBack {
                Button("Put Back") { model.putBack(record) }
                    .controlSize(.small)
            } else {
                Text(record.restored ? "Put back" : "Deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}
