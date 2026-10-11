import SwiftUI
import Charts

/// Shared scroll container so every pane has the same margins and background.
struct PaneScroll<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A small section title above a grouped list.
struct SectionTitle: View {
    let title: String
    var detail: String = ""
    var safety: Safety?

    var body: some View {
        HStack(spacing: 6) {
            if let safety = safety {
                Image(systemName: safety.symbol)
                    .foregroundColor(safety.color)
            }
            Text(title)
                .font(.headline)
            Spacer()
            Text(detail)
                .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Cleanup Ideas

struct IdeaSection: Identifiable {
    let safety: Safety
    let title: String
    var id: Int { safety.rawValue }
}

struct IdeasTab: View {
    @EnvironmentObject var model: AppModel

    private static let sections: [IdeaSection] = [
        IdeaSection(safety: .safe, title: "Safe to delete"),
        IdeaSection(safety: .likelySafe, title: "Probably safe"),
        IdeaSection(safety: .review, title: "Worth a look"),
    ]

    var body: some View {
        if model.ideas.isEmpty {
            EmptyState(symbol: "sparkles",
                       title: "No obvious cleanup found",
                       message: "Nothing over 50 MB matched a known safe-to-remove pattern. The Map and Big & Untouched views can still help.")
        } else {
            PaneScroll {
                PaneHeader(tab: .ideas,
                           title: "About \(Fmt.bytes(total(for: [.safe, .likelySafe]))) looks safe to free",
                           summary: "Each item says what it is and what removing it means. Everything goes to the Trash first, so you can change your mind.")

                StorageMeter(
                    segments: IdeasTab.sections.map { section in
                        MeterSegment(label: section.title, value: total(for: [section.safety]), colors: colors(for: section.safety))
                    },
                    total: max(1, total(for: [.safe, .likelySafe, .review])),
                    height: 10
                )

                ForEach(IdeasTab.sections) { section in
                    let items = model.ideas.filter { $0.explanation.safety == section.safety }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(title: section.title, detail: Fmt.bytes(sum(items)), safety: section.safety)
                            CardList {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, idea in
                                    if index > 0 {
                                        Divider().padding(.leading, 56)
                                    }
                                    IdeaRow(idea: idea)
                                        .draggable(idea.node.path)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func colors(for safety: Safety) -> [Color] {
        switch safety {
        case .safe: return Palette.green
        case .likelySafe: return Palette.teal
        default: return Palette.orange
        }
    }

    private func total(for levels: [Safety]) -> Int64 {
        sum(model.ideas.filter { levels.contains($0.explanation.safety) })
    }

    private func sum(_ items: [Idea]) -> Int64 {
        var result: Int64 = 0
        for item in items { result += item.node.size }
        return result
    }
}

struct IdeaRow: View {
    @EnvironmentObject var model: AppModel
    let idea: Idea
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FileIcon(node: idea.node, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.explanation.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(model.shortPath(idea.node))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(Fmt.bytes(idea.node.size))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up.circle.fill" : "info.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .help("What is this?")
                BasketButton(node: idea.node)
                Button("Show") { model.showInMap(idea.node) }
                    .controlSize(.small)
                if model.isTrashFolder(idea.node) {
                    Button("Empty Trash…") { model.showEmptyTrashConfirm = true }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Move to Trash") { model.requestTrash([idea.node]) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!model.canTrash(idea.node))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(idea.explanation.detail)
                        .font(.callout)
                    Text(idea.explanation.advice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - What Grew

struct GrowthTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let report = model.growth {
            PaneScroll {
                PaneHeader(tab: .growth,
                           title: "Since your last scan \(Fmt.relative(report.previousDate))",
                           summary: "\(model.root?.name ?? "This location") went from \(Fmt.bytes(report.previousTotal)) to \(Fmt.bytes(report.currentTotal)). Previous scan: \(Fmt.dateTime(report.previousDate)).") {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.signedBytes(report.currentTotal - report.previousTotal))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundColor(report.currentTotal >= report.previousTotal ? Color.orange : Color.green)
                        Text("overall change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.history.count >= 2 {
                    HistoryChart(points: model.history)
                }

                if report.items.isEmpty {
                    Text("Nothing grew by more than 100 MB.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Biggest increases")
                        CardList {
                            ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider().padding(.leading, 56)
                                }
                                GrowthRow(item: item, largest: report.items.first?.delta ?? 1)
                                    .draggable(item.node.path)
                            }
                        }
                    }
                }

                WatchCard()
            }
        } else {
            PaneScroll {
                PaneHeader(tab: .growth,
                           title: "First snapshot saved",
                           summary: "DiskMap saved the size of everything in \(model.root?.name ?? "this location"). Rescan in a week or two, or turn on automatic checks below, and this view shows exactly what grew in between.")
                if model.history.count >= 2 {
                    HistoryChart(points: model.history)
                }
                WatchCard()
            }
        }
    }
}

struct GrowthRow: View {
    @EnvironmentObject var model: AppModel
    let item: GrowthItem
    let largest: Int64

    var body: some View {
        let explanation = model.explainer.explain(item.node)
        HStack(spacing: 12) {
            FileIcon(node: item.node, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(explanation?.title ?? item.node.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.shortPath(item.node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.signedBytes(item.delta))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundColor(.orange)
                GrowthBar(oldSize: item.oldSize, newSize: item.newSize, scale: largest)
                    .frame(width: 110, height: 6)
                Text(changeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ItemActions(node: item.node)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var changeText: String {
        if item.isNew { return "New (or under 5 MB before)" }
        return Fmt.bytes(item.oldSize) + " → " + Fmt.bytes(item.newSize)
    }
}

/// Gray for the size it was, orange for what was added.
struct GrowthBar: View {
    let oldSize: Int64
    let newSize: Int64
    let scale: Int64

    /// Bars are sized relative to the biggest increase, with a minimum so small ones stay visible.
    private var lengthShare: Double {
        let growth = Double(max(newSize - oldSize, 0))
        let biggest = Double(max(scale, 1))
        return min(1, growth / biggest * 0.85 + 0.15)
    }

    private var oldShare: Double {
        Double(max(oldSize, 0)) / Double(max(newSize, 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * CGFloat(lengthShare)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: width * CGFloat(oldShare))
                Rectangle()
                    .fill(LinearGradient(colors: Palette.orange, startPoint: .leading, endPoint: .trailing))
            }
            .frame(width: width)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct HistoryChart: View {
    let points: [HistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Size over time")
            Chart(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("GB", Double(point.total) / 1_000_000_000)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [Palette.orange[0].opacity(0.35), Palette.orange[0].opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("GB", Double(point.total) / 1_000_000_000)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Palette.orange[1])
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("GB", Double(point.total) / 1_000_000_000)
                )
                .foregroundStyle(Palette.orange[1])
                .symbolSize(30)
            }
            .chartYAxisLabel("GB")
            .frame(height: 170)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Big & Untouched

struct UntouchedTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .untouched,
                       title: "Big files you haven't opened",
                       summary: model.untouched.isEmpty
                           ? "Your own files only. App data and system folders are left out."
                           : "\(model.untouched.count) files, \(Fmt.bytes(totalSize)) in all. App data and system folders are left out.") {
                if model.untouchedBusy {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("At least")
                    .foregroundStyle(.secondary)
                Picker("Minimum size", selection: $model.untouchedMinSize) {
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                .labelsHidden()
                .fixedSize()
                Text("and not opened in")
                    .foregroundStyle(.secondary)
                Picker("Age", selection: $model.untouchedMonths) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            if model.untouched.isEmpty && !model.untouchedBusy {
                EmptyState(symbol: "clock.arrow.circlepath",
                           title: "Nothing forgotten at this size",
                           message: "No files this big have gone unopened that long. Try a smaller size or a shorter time.")
                    .frame(height: 280)
            } else {
                CardList {
                    ForEach(Array(model.untouched.enumerated()), id: \.element.id) { index, file in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        UntouchedRow(file: file, largest: model.untouched.first?.node.size ?? 1)
                            .draggable(file.node.path)
                    }
                }
            }
        }
    }

    private var totalSize: Int64 {
        var sum: Int64 = 0
        for file in model.untouched { sum += file.node.size }
        return sum
    }
}

struct UntouchedRow: View {
    @EnvironmentObject var model: AppModel
    let file: UntouchedFile
    let largest: Int64

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(node: file.node, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.node.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.shortPath(file.node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(file.node.size))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                SizeBar(fraction: Double(file.node.size) / Double(max(largest, 1)), colors: Palette.indigo)
                    .frame(width: 90, height: 4)
                Text(lastUsedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ItemActions(node: file.node)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var lastUsedText: String {
        if file.lastUsed == Date.distantPast { return "Date unknown" }
        let verb = file.isLastOpened ? "Opened" : "Changed"
        return "\(verb) \(Fmt.relative(file.lastUsed))"
    }
}

// MARK: - Duplicates

struct DuplicatesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .duplicates, title: "Duplicate files", summary: summary) {
                if model.duplicateState == .finished && !model.duplicateGroups.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.bytes(wastedTotal))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("in extra copies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Compare files larger than")
                    .foregroundStyle(.secondary)
                Picker("Minimum size", selection: $model.duplicateMinSize) {
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.duplicateState == .running)
                Spacer()
                if model.duplicateState == .running {
                    Button("Stop") { model.cancelDuplicates() }
                } else {
                    Button(searchButtonTitle) { model.findDuplicates() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.duplicateState {
        case .notStarted:
            EmptyState(symbol: "doc.on.doc",
                       title: "Find identical files",
                       message: "DiskMap compares the actual contents of your files, so a search can take a few minutes on a full disk.")
                .frame(height: 280)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                GradientProgressBar(fraction: model.duplicateFraction, colors: Palette.pink, height: 8)
                HStack {
                    Text(model.duplicatePhase)
                    Spacer()
                    Text("\(Int(model.duplicateFraction * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        case .finished:
            if model.duplicateGroups.isEmpty {
                EmptyState(symbol: "checkmark.seal",
                           title: "No duplicates found",
                           message: "No identical files above this size.")
                    .frame(height: 280)
            } else {
                Text("Copies made with Finder's Duplicate command can share space on disk, so deleting one may free less than shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVStack(spacing: 12) {
                    ForEach(model.duplicateGroups) { group in
                        DuplicateGroupView(group: group)
                    }
                }
            }
        }
    }

    private var summary: String {
        switch model.duplicateState {
        case .notStarted:
            return "Identical copies of the same file, matched by contents rather than name. App data, system folders and the insides of apps are skipped."
        case .running:
            return "Matching files by size first, then by contents. You can keep using the other views."
        case .finished:
            if model.duplicateGroups.isEmpty { return "No identical files found above this size." }
            return "\(model.duplicateGroups.count) sets of identical files. Keep one copy of each and the rest can go."
        }
    }

    private var wastedTotal: Int64 {
        var sum: Int64 = 0
        for group in model.duplicateGroups { sum += group.wasted }
        return sum
    }

    private var searchButtonTitle: String {
        model.duplicateState == .finished ? "Search Again" : "Find Duplicates"
    }
}

struct DuplicateGroupView: View {
    @EnvironmentObject var model: AppModel
    let group: DuplicateGroup

    var body: some View {
        CardList {
            if let first = group.files.first {
                HStack(spacing: 12) {
                    FileIcon(node: first, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(group.files.count) identical copies, \(Fmt.bytes(group.fileSize)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Fmt.bytes(group.wasted)) extra")
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    Button("Keep Oldest, Trash Others") {
                        model.requestTrash(Array(group.files.dropFirst()))
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                Divider().padding(.leading, 56)
                HStack(spacing: 8) {
                    Text(verbatim: index == 0 ? "Oldest" : "")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.green)
                        .frame(width: 44, alignment: .leading)
                    Text(model.shortPath(file))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let modified = file.modified {
                        Text(Fmt.date(modified))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ItemActions(node: file)
                }
                .padding(.leading, 56)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .draggable(file.path)
            }
        }
    }
}
