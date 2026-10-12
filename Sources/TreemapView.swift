import SwiftUI

/// Keeps the last layout so hovering doesn't lay the whole map out again.
final class TreemapCache {
    private var focusID: ObjectIdentifier?
    private var version = -1
    private var size: CGSize = .zero
    private var stored: [TreemapCell] = []

    func cells(focus: FileNode, version newVersion: Int, size newSize: CGSize) -> [TreemapCell] {
        let id = ObjectIdentifier(focus)
        if id == focusID && newVersion == version && newSize == size {
            return stored
        }
        stored = TreemapLayout.cells(for: focus, in: CGRect(origin: .zero, size: newSize))
        focusID = id
        version = newVersion
        size = newSize
        return stored
    }
}

/// The map as nested rectangles: each item's area is its share of the open folder.
struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    @State private var hoveredIndex: Int?
    @State private var cache = TreemapCache()

    var body: some View {
        let selected = model.selection
        let version = model.treeVersion
        let hovered = hoveredIndex
        GeometryReader { geometry in
            let size = geometry.size
            let cells = model.focus.map { cache.cells(focus: $0, version: version, size: size) } ?? []
            ZStack(alignment: .bottomLeading) {
                Canvas { context, _ in
                    TreemapView.draw(&context, cells: cells, hovered: hovered, selected: selected,
                                     separator: Color(nsColor: .windowBackgroundColor), accent: Color.accentColor)
                }
                if let index = hovered, index < cells.count {
                    infoTag(cells[index])
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let index = TreemapView.hit(location, cells: cells)
                    if index != hoveredIndex { hoveredIndex = index }
                case .ended:
                    hoveredIndex = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        click(at: value.location, cells: cells)
                    }
            )
        }
        .onChange(of: model.focus) { _ in hoveredIndex = nil }
    }

    private func click(at point: CGPoint, cells: [TreemapCell]) {
        guard let index = TreemapView.hit(point, cells: cells) else { return }
        let cell = cells[index]
        if cell.restCount > 0 {
            // The "smaller items" tile inside a folder opens that folder.
            if cell.depth == 2 { model.open(cell.node) }
            return
        }
        if cell.node.isDirectory {
            model.open(cell.node)
        } else {
            model.select(cell.node)
        }
    }

    private func infoTag(_ cell: TreemapCell) -> some View {
        HStack(spacing: 8) {
            if cell.restCount > 0 {
                Text("\(Fmt.count(cell.restCount)) smaller items")
                    .fontWeight(.medium)
            } else {
                FileIcon(node: cell.node, size: 16)
                Text(cell.node.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Fmt.bytes(cell.node.size))
                    .monospacedDigit()
                if let focus = model.focus {
                    Text(Fmt.percent(cell.node.size, of: focus.size))
                        .foregroundStyle(.secondary)
                }
                if let explanation = model.explainer.explain(cell.node), cell.node.kind != .smallFiles {
                    Text(explanation.title)
                        .foregroundColor(explanation.safety.color)
                        .lineLimit(1)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
    }

    static func hit(_ point: CGPoint, cells: [TreemapCell]) -> Int? {
        // Inner tiles come last, so search from the end to find the most specific one.
        for index in cells.indices.reversed() where cells[index].rect.contains(point) {
            return index
        }
        return nil
    }

    static func draw(_ context: inout GraphicsContext, cells: [TreemapCell], hovered: Int?, selected: FileNode?,
                     separator: Color, accent: Color) {
        let ink = Color.black.opacity(0.76)
        for (index, cell) in cells.enumerated() {
            let highlighted = index == hovered
            let rect = cell.rect
            let path = Path(roundedRect: rect, cornerRadius: cell.depth == 1 ? 4 : 2.5, style: .continuous)

            if cell.restCount > 0 {
                context.fill(path, with: .color(Color.primary.opacity(highlighted ? 0.16 : 0.08)))
                if rect.width > 50 && rect.height > 16 {
                    label(&context, Text("\(Fmt.count(cell.restCount)) more").font(.system(size: 10)).foregroundColor(.secondary),
                          in: rect.insetBy(dx: 5, dy: 3))
                }
                continue
            }

            let kind = cell.node.kind
            let top = SunburstGeometry.tileColor(hue: cell.hue, depth: cell.depth, kind: kind, highlighted: highlighted, lift: 0.08)
            let bottom = SunburstGeometry.tileColor(hue: cell.hue, depth: cell.depth, kind: kind, highlighted: highlighted)
            context.fill(path, with: .linearGradient(Gradient(colors: [top, bottom]),
                                                     startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                     endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            context.stroke(path, with: .color(Color.black.opacity(0.10)), lineWidth: 0.5)

            if cell.hasChildren {
                // A folder showing its contents: name and size along the top strip.
                let strip = CGRect(x: rect.minX + 5, y: rect.minY + 2, width: rect.width - 10, height: TreemapLayout.header - 3)
                if strip.width > 24 {
                    let text = Text(cell.node.name).font(.system(size: 11, weight: .semibold))
                        + Text("  " + Fmt.bytes(cell.node.size)).font(.system(size: 10))
                    label(&context, text.foregroundColor(ink), in: strip)
                }
            } else if rect.width > 44 && rect.height > 17 {
                let size: CGFloat = cell.depth == 1 ? 11 : 10
                var text = Text(cell.node.name).font(.system(size: size, weight: cell.depth == 1 ? .semibold : .regular))
                if rect.height > 32 {
                    text = text + Text("\n" + Fmt.bytes(cell.node.size)).font(.system(size: size - 1))
                }
                label(&context, text.foregroundColor(ink), in: rect.insetBy(dx: 5, dy: 3))
            }
        }

        if let selectedNode = selected, let cell = cells.last(where: { $0.node === selectedNode && $0.restCount == 0 }) {
            let path = Path(roundedRect: cell.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3, style: .continuous)
            context.stroke(path, with: .color(separator), lineWidth: 3.5)
            context.stroke(path, with: .color(accent), lineWidth: 2)
        }
    }

    /// Draws text clipped to a tile so long names never spill into neighbors.
    private static func label(_ context: inout GraphicsContext, _ text: Text, in rect: CGRect) {
        guard rect.width > 4, rect.height > 4 else { return }
        var layer = context
        layer.clip(to: Path(rect))
        layer.draw(text, in: rect)
    }
}
