import SwiftUI
import AppKit

struct MapTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                BreadcrumbBar()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                AccessNote()
                Group {
                    if model.mapStyle == .treemap {
                        TreemapView()
                            .padding(14)
                    } else {
                        SunburstView()
                            .padding(18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                DiskSummaryBar()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            VStack(spacing: 0) {
                ItemListView()
                    .frame(minHeight: 200, maxHeight: .infinity)
                Divider()
                DetailView()
                    .frame(height: 290)
            }
            .frame(minWidth: 370, idealWidth: 440, maxWidth: 660, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onDeleteCommand {
            if let node = model.selection { model.requestTrash([node]) }
        }
        .onExitCommand {
            model.goUp()
        }
    }
}

struct BreadcrumbBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(model.focus?.parent == nil)
            .opacity(model.focus?.parent == nil ? 0.4 : 1)
            .help("Up one level")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.focus?.ancestors ?? []) { node in
                        let isCurrent = node === model.focus
                        Button(node.name) { model.open(node) }
                            .buttonStyle(.plain)
                            .font(isCurrent ? Font.callout.weight(.semibold) : Font.callout)
                            .foregroundColor(isCurrent ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if !isCurrent {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Picker("Map style", selection: $model.mapStyle) {
                Image(systemName: "chart.pie")
                    .help("Rings (⌥⌘1)")
                    .tag(AppModel.MapStyle.rings)
                Image(systemName: "square.grid.2x2")
                    .help("Rectangles (⌥⌘2)")
                    .tag(AppModel.MapStyle.treemap)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the map as rings or rectangles")
        }
    }
}

struct AccessNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.hasFullDiskAccess {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.orange)
                Text("Full Disk Access is off, so Safari data, Mail and Messages are hidden.")
                    .font(.callout)
                Spacer()
                Button("Open Settings") { model.openFullDiskAccessSettings() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.10)))
            .padding(.horizontal, 14)
        } else if model.unreadableCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("\(Fmt.count(model.unreadableCount)) protected folders couldn't be read. They're counted in System & hidden.")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        }
    }
}

struct SunburstView: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: FileNode?
    @State private var sweepStart = Date()
    @State private var animating = true

    private static let sweepDuration = 0.55

    var body: some View {
        let segments = model.segments
        let selected = model.selection
        let hoveredNode = hovered
        let start = sweepStart
        GeometryReader { geometry in
            let size = geometry.size
            let innerDiameter = SunburstGeometry.innerRadius(size) * 2
            ZStack {
                TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
                    let progress = timeline.date.timeIntervalSince(start) / SunburstView.sweepDuration
                    Canvas { context, canvasSize in
                        SunburstGeometry.draw(context: &context, size: canvasSize, segments: segments,
                                              hovered: hoveredNode, selected: selected,
                                              separator: Color(nsColor: .windowBackgroundColor),
                                              accent: Color.accentColor, progress: progress)
                    }
                }
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .frame(width: max(0, innerDiameter - 10), height: max(0, innerDiameter - 10))
                    .shadow(color: Color.black.opacity(0.16), radius: 8, x: 0, y: 3)
                    .allowsHitTesting(false)
                centerLabel
                    .frame(width: innerDiameter * 0.8)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let node = SunburstGeometry.hit(location, size: size, segments: segments)?.node
                    if node !== hovered { hovered = node }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        click(at: value.location, size: size, segments: segments)
                    }
            )
        }
        .onAppear { startSweep() }
        .onChange(of: model.focus) { _ in startSweep() }
    }

    private func startSweep() {
        sweepStart = Date()
        animating = true
        Task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            animating = false
        }
    }

    private var centerLabel: some View {
        let node = hovered ?? model.focus
        let explanation = node.flatMap { model.explainer.explain($0) }
        return VStack(spacing: 3) {
            if let node = node {
                Text(node.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                if let explanation = explanation, node.kind != .smallFiles {
                    Text(explanation.title)
                        .font(.caption)
                        .foregroundColor(explanation.safety.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Text(Fmt.bytes(node.size))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if hovered != nil, let focus = model.focus {
                    Text("\(Fmt.percent(node.size, of: focus.size)) of this folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.focus?.parent != nil {
                    Label("Back", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func click(at point: CGPoint, size: CGSize, segments: [ChartSegment]) {
        if SunburstGeometry.isInCenter(point, size: size) {
            model.goUp()
            return
        }
        guard let segment = SunburstGeometry.hit(point, size: size, segments: segments) else { return }
        if segment.node.isDirectory {
            model.open(segment.node)
        } else {
            model.select(segment.node)
        }
    }
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let focus = model.focus {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    FileIcon(node: focus, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(focus.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(Fmt.count(focus.children.count)) items, \(Fmt.count(focus.itemCount)) files in all")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.bytes(focus.size))
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()

                if focus.children.isEmpty {
                    EmptyState(symbol: focus.unreadable ? "lock.fill" : "folder",
                               title: focus.unreadable ? "Couldn't read this folder" : "Nothing inside",
                               message: focus.unreadable ? "macOS didn't let DiskMap look inside. Full Disk Access or admin rights may be needed." : "This folder is empty.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(focus.children) { child in
                                ItemRow(node: child, parentSize: focus.size, isSelected: model.selection === child)
                                    .contentShape(Rectangle())
                                    .draggable(child.path)
                                    .onTapGesture { model.select(child) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.open(child) })
                                    .contextMenu { ItemContextMenu(node: child) }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
    }
}

struct ItemContextMenu: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        if node.isDirectory {
            Button("Open") { model.open(node) }
        }
        Button("Quick Look") { model.preview(node) }
        Button("Reveal in Finder") { model.reveal(node) }
        Button("Copy Path") { model.copyPath(node) }
        Divider()
        Button("Add to Cleanup Basket") { model.addToBasket([node]) }
            .disabled(!model.canTrash(node) || model.isInBasket(node))
        Button("Move to Trash…") { model.requestTrash([node]) }
            .disabled(!model.canTrash(node))
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let parentSize: Int64
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let explanation = model.explainer.explain(node)
        let hue = model.hue(for: node)
        let swatch = hue.map { SunburstGeometry.swatch(hue: $0) } ?? Color.secondary.opacity(0.35)
        let barColors = hue.map { [SunburstGeometry.swatch(hue: $0).opacity(0.75), SunburstGeometry.swatch(hue: $0)] } ?? Palette.graphite
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(swatch)
                .frame(width: 4, height: 26)
            FileIcon(node: node, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
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
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(node.size))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                SizeBar(fraction: parentSize > 0 ? Double(node.size) / Double(parentSize) : 0, colors: barColors)
                    .frame(width: 76, height: 4)
            }
            Group {
                if node.isDirectory {
                    Button {
                        model.open(node)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Open this folder")
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground)
        )
        .onHover { inside in hovering = inside }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let node = model.selection ?? model.focus {
            DetailContent(node: node)
        } else {
            EmptyState(symbol: "cursorarrow.click", title: "Select an item", message: "Click a ring or a row to see details.")
        }
    }
}

struct DetailContent: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        let explanation = model.explainer.explain(node)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    FileIcon(node: node, size: 50)
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(model.shortPath(node))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    StatPill(label: "Size", value: Fmt.bytes(node.size))
                    if node.kind != .file {
                        StatPill(label: "Files", value: Fmt.count(node.itemCount))
                    }
                    if let parent = node.parent {
                        StatPill(label: "Of parent", value: Fmt.percent(node.size, of: parent.size))
                    }
                    if let modified = node.modified {
                        StatPill(label: "Modified", value: Fmt.date(modified))
                    }
                }

                if node.unreadable {
                    Label("macOS didn't let DiskMap read this folder, so its size isn't counted.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let explanation = explanation {
                    ExplanationCard(explanation: explanation)
                }

                HStack(spacing: 8) {
                    if node.isDirectory && node !== model.focus {
                        Button("Open") { model.open(node) }
                    }
                    Button {
                        model.preview(node)
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .help("Preview it (Space or ⌘Y)")
                    Button("Reveal in Finder") { model.reveal(node) }
                    Button("Copy Path") { model.copyPath(node) }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Spacer()
                    if model.isTrashFolder(node) {
                        Button("Empty Trash…") { model.showEmptyTrashConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    } else {
                        Button {
                            model.addToBasket([node])
                        } label: {
                            Label(model.isInBasket(node) ? "In Basket" : "Add to Basket",
                                  systemImage: model.isInBasket(node) ? "tray.full.fill" : "tray.and.arrow.down")
                        }
                        .disabled(!model.canTrash(node) || model.isInBasket(node))
                        .help("Collect it in the Cleanup Basket to trash later with other items")
                        Button {
                            model.requestTrash([node])
                        } label: {
                            Label(model.isInstalledApp(node) ? "Uninstall…" : "Move to Trash", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!model.canTrash(node))
                    }
                }
            }
            .padding(16)
        }
    }
}

struct DiskSummaryBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let root = model.root, let volume = model.volume {
            if model.scannedRootPath == "/" {
                VStack(alignment: .leading, spacing: 6) {
                    StorageMeter(
                        segments: [
                            MeterSegment(label: "Scanned", value: root.size, colors: Palette.blue),
                            MeterSegment(label: "System & hidden", value: max(0, volume.used - root.size), colors: Palette.graphite),
                        ],
                        total: volume.total,
                        height: 10
                    )
                    Button {
                        model.openHiddenSpace()
                    } label: {
                        Label("What's in System & hidden?", systemImage: "questionmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            } else {
                StorageMeter(
                    segments: [
                        MeterSegment(label: root.name, value: root.size, colors: Palette.blue),
                        MeterSegment(label: "Rest of disk", value: max(0, volume.used - root.size), colors: Palette.graphite),
                    ],
                    total: volume.total,
                    height: 10
                )
            }
        }
    }
}
