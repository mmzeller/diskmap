import SwiftUI

/// One wedge of the ring chart.
struct ChartSegment {
    let node: FileNode
    /// 1 is the innermost ring.
    let depth: Int
    /// Angles in radians, starting at 12 o'clock and going clockwise.
    let start: Double
    let end: Double
    let hue: Double
}

enum ChartLayout {
    static let maxDepth = 5
    /// Wedges thinner than this (about half a degree) aren't drawn.
    static let minAngle = 0.009

    static func segments(for focus: FileNode) -> [ChartSegment] {
        var result: [ChartSegment] = []
        guard focus.size > 0 else { return result }
        place(focus, depth: 1, start: 0, end: 2 * Double.pi, hue: nil, into: &result)
        return result
    }

    private static func place(_ node: FileNode, depth: Int, start: Double, end: Double, hue: Double?, into result: inout [ChartSegment]) {
        guard node.size > 0 else { return }
        let span = end - start
        var cursor = start
        for child in node.children {
            if child.size <= 0 { continue }
            let angle = span * Double(child.size) / Double(node.size)
            if angle < minAngle { break }
            let middle = cursor + angle / 2
            let childHue: Double
            if let base = hue {
                childHue = base + ((middle - start) / span - 0.5) * 0.08
            } else {
                childHue = middle / (2 * Double.pi)
            }
            result.append(ChartSegment(node: child, depth: depth, start: cursor, end: cursor + angle, hue: childHue))
            if child.isDirectory && depth < maxDepth {
                place(child, depth: depth + 1, start: cursor, end: cursor + angle, hue: childHue, into: &result)
            }
            cursor += angle
        }
    }
}

/// Drawing and hit-testing for the ring chart. Kept free of view state so it can run inside Canvas.
enum SunburstGeometry {
    static func outerRadius(_ size: CGSize) -> CGFloat {
        max(20, min(size.width, size.height) / 2 - 6)
    }

    static func innerRadius(_ size: CGSize) -> CGFloat {
        outerRadius(size) * 0.27
    }

    static func ringWidth(_ size: CGSize) -> CGFloat {
        (outerRadius(size) - innerRadius(size)) / CGFloat(ChartLayout.maxDepth)
    }

    static func wedge(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        let safeEnd = min(end, start + 2 * Double.pi - 0.0005)
        let from = Angle(radians: start - Double.pi / 2)
        let to = Angle(radians: safeEnd - Double.pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Hues the chart moves through around the circle: teal, blue, indigo, purple, pink, coral, orange, amber.
    /// Values above 1 wrap around the color wheel; skipping yellow-green keeps the palette calm.
    private static let anchorHues: [Double] = [0.50, 0.58, 0.67, 0.77, 0.90, 0.99, 1.06, 1.11]

    /// Turns a position around the chart (0...1) into a hue from the palette above.
    private static func normalized(_ position: Double) -> Double {
        var fraction = position.truncatingRemainder(dividingBy: 1)
        if fraction < 0 { fraction += 1 }
        let scaled = fraction * Double(anchorHues.count - 1)
        let index = min(anchorHues.count - 2, Int(scaled))
        let local = scaled - Double(index)
        let hue = anchorHues[index] + (anchorHues[index + 1] - anchorHues[index]) * local
        return hue.truncatingRemainder(dividingBy: 1)
    }

    /// `lift` brightens the color; used for the light inner edge of each wedge.
    static func color(for segment: ChartSegment, highlighted: Bool, lift: Double = 0) -> Color {
        if segment.node.kind == .smallFiles {
            return Color(white: min(1, (highlighted ? 0.74 : 0.6) + lift))
        }
        let level = Double(segment.depth - 1)
        let isFile = segment.node.kind == .file
        var saturation = isFile ? 0.30 : max(0.30, 0.72 - level * 0.08)
        var brightness = isFile ? 0.82 : min(0.95, 0.82 + level * 0.025)
        if highlighted {
            saturation = min(1, saturation + 0.15)
            brightness = min(1, brightness + 0.05)
        }
        saturation = max(0, saturation - lift * 0.6)
        brightness = min(1, brightness + lift)
        return Color(hue: normalized(segment.hue), saturation: saturation, brightness: brightness)
    }

    /// The color an innermost-ring item has, for matching swatches in lists.
    static func swatch(hue: Double) -> Color {
        Color(hue: normalized(hue), saturation: 0.66, brightness: 0.88)
    }

    /// Treemap tiles use the same palette as the rings, a little softer because tiles are large.
    static func tileColor(hue: Double, depth: Int, kind: FileNode.Kind, highlighted: Bool, lift: Double = 0) -> Color {
        if kind == .smallFiles {
            return Color(white: min(1, (highlighted ? 0.72 : 0.62) + lift))
        }
        var saturation = depth == 1 ? 0.62 : 0.50
        var brightness = depth == 1 ? 0.80 : 0.88
        if kind == .file {
            saturation -= 0.24
            brightness += 0.02
        }
        if highlighted {
            saturation = min(1, saturation + 0.12)
            brightness = min(1, brightness + 0.06)
        }
        saturation = max(0, saturation - lift * 0.6)
        brightness = min(1, brightness + lift)
        return Color(hue: normalized(hue), saturation: saturation, brightness: brightness)
    }

    private enum WedgeState {
        case normal
        case highlighted
        case dimmed
    }

    /// `progress` runs from 0 to 1 while the chart sweeps in after opening a folder.
    static func draw(context: inout GraphicsContext, size: CGSize, segments: [ChartSegment],
                     hovered: FileNode?, selected: FileNode?, separator: Color, accent: Color, progress: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let inner = innerRadius(size)
        let ring = ringWidth(size)
        let clamped = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - clamped, 3)

        for segment in segments {
            let start = segment.start * eased
            let end = segment.end * eased
            if end - start < 0.0004 { continue }
            let r0 = inner + CGFloat(segment.depth - 1) * ring
            let path = wedge(center: center, inner: r0, outer: r0 + ring, start: start, end: end)

            var state = WedgeState.normal
            if let hoveredNode = hovered {
                if segment.node === hoveredNode || segment.node.isDescendant(of: hoveredNode) {
                    state = .highlighted
                } else if !hoveredNode.isDescendant(of: segment.node) {
                    state = .dimmed
                }
            }

            let highlighted = state == .highlighted
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [color(for: segment, highlighted: highlighted, lift: 0.10),
                                  color(for: segment, highlighted: highlighted)]),
                center: center,
                startRadius: r0,
                endRadius: r0 + ring
            )
            var layer = context
            layer.opacity = (state == .dimmed ? 0.38 : 1) * (0.3 + 0.7 * eased)
            layer.fill(path, with: shading)
            // Very thin wedges skip the separator line so the outer rings don't look like a comb.
            if Double(end - start) * Double(r0) > 3 {
                layer.stroke(path, with: .color(separator), lineWidth: 1)
            }
        }

        if clamped >= 1, let selectedNode = selected, let segment = segments.first(where: { $0.node === selectedNode }) {
            let r0 = inner + CGFloat(segment.depth - 1) * ring
            let path = wedge(center: center, inner: r0, outer: r0 + ring, start: segment.start, end: segment.end)
            context.stroke(path, with: .color(separator), lineWidth: 4)
            context.stroke(path, with: .color(accent), lineWidth: 2)
        }
    }

    static func isInCenter(_ point: CGPoint, size: CGSize) -> Bool {
        let dx = Double(point.x - size.width / 2)
        let dy = Double(point.y - size.height / 2)
        return (dx * dx + dy * dy).squareRoot() < Double(innerRadius(size))
    }

    static func hit(_ point: CGPoint, size: CGSize, segments: [ChartSegment]) -> ChartSegment? {
        let dx = Double(point.x - size.width / 2)
        let dy = Double(point.y - size.height / 2)
        let radius = (dx * dx + dy * dy).squareRoot()
        let inner = Double(innerRadius(size))
        let outer = Double(outerRadius(size))
        guard radius >= inner, radius <= outer else { return nil }
        let ring = Double(ringWidth(size))
        let depth = min(ChartLayout.maxDepth, Int((radius - inner) / ring) + 1)
        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += 2 * Double.pi }
        if angle >= 2 * Double.pi { angle -= 2 * Double.pi }
        return segments.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}

// MARK: - Treemap

/// One rectangle of the treemap.
struct TreemapCell {
    let node: FileNode
    let rect: CGRect
    /// 1 for items in the open folder, 2 for what's inside those.
    let depth: Int
    let hue: Double
    /// True for a folder whose contents are drawn inside it; only its top strip shows.
    let hasChildren: Bool
    /// For the tile that stands for many items too small to draw: how many. `node` is then their folder.
    var restCount = 0
}

enum TreemapLayout {
    /// Most items drawn per folder; the rest share one tile.
    static let maxItems = 250
    static let maxInnerItems = 60
    /// Height of the label strip along the top of a folder that shows its contents.
    static let header: CGFloat = 17
    static let gap: CGFloat = 2

    /// Lays out the open folder's items, and inside the bigger folders, their items too.
    static func cells(for focus: FileNode, in bounds: CGRect) -> [TreemapCell] {
        var result: [TreemapCell] = []
        guard focus.size > 0, bounds.width > 4, bounds.height > 4 else { return result }
        let items = visibleChildren(of: focus, limit: maxItems)
        let (rects, restRect) = layout(items, total: focus.size, in: bounds)
        var cursor: Int64 = 0
        var inner: [TreemapCell] = []
        for (child, rect) in zip(items, rects) {
            let middle = (Double(cursor) + Double(child.size) / 2) / Double(focus.size)
            cursor += child.size
            let tile = rect.insetBy(dx: gap / 2, dy: gap / 2)
            guard tile.width >= 1, tile.height >= 1 else { continue }
            let room = CGRect(x: tile.minX + gap, y: tile.minY + header, width: tile.width - gap * 2, height: tile.height - header - gap)
            let showInside = child.isDirectory && !child.children.isEmpty && room.width >= 40 && room.height >= 24
            result.append(TreemapCell(node: child, rect: tile, depth: 1, hue: middle, hasChildren: showInside))
            guard showInside else { continue }

            let grandchildren = visibleChildren(of: child, limit: maxInnerItems)
            let (innerRects, innerRest) = layout(grandchildren, total: child.size, in: room)
            var innerCursor: Int64 = 0
            for (grandchild, innerRect) in zip(grandchildren, innerRects) {
                let position = (Double(innerCursor) + Double(grandchild.size) / 2) / Double(child.size)
                innerCursor += grandchild.size
                let innerTile = innerRect.insetBy(dx: 0.5, dy: 0.5)
                guard innerTile.width >= 1, innerTile.height >= 1 else { continue }
                inner.append(TreemapCell(node: grandchild, rect: innerTile, depth: 2,
                                         hue: middle + (position - 0.5) * 0.08, hasChildren: false))
            }
            if let restRect = innerRest, restRect.width >= 2, restRect.height >= 2 {
                inner.append(TreemapCell(node: child, rect: restRect.insetBy(dx: 0.5, dy: 0.5), depth: 2, hue: middle,
                                         hasChildren: false, restCount: child.children.count - grandchildren.count))
            }
        }
        if let restRect = restRect, restRect.width >= 2, restRect.height >= 2 {
            result.append(TreemapCell(node: focus, rect: restRect.insetBy(dx: gap / 2, dy: gap / 2), depth: 1, hue: 0,
                                      hasChildren: false, restCount: focus.children.count - items.count))
        }
        // Inner tiles go last so they're drawn on top and found first when clicked.
        return result + inner
    }

    private static func visibleChildren(of node: FileNode, limit: Int) -> [FileNode] {
        var list: [FileNode] = []
        for child in node.children where child.size > 0 {
            list.append(child)
            if list.count == limit { break }
        }
        return list
    }

    /// Lays out items (largest first). Whatever share of `total` they don't cover gets a block of its own,
    /// placed by size like any other, so every tile keeps a sensible shape.
    static func layout(_ items: [FileNode], total: Int64, in box: CGRect) -> (items: [CGRect], rest: CGRect?) {
        var values = items.map { Double($0.size) }
        let shown = values.reduce(0, +)
        let rest = Double(total) - shown
        var restIndex: Int?
        if rest > max(1, Double(total) * 0.002) {
            let index = values.firstIndex(where: { $0 < rest }) ?? values.count
            values.insert(rest, at: index)
            restIndex = index
        }
        var rects = squarify(values, in: box)
        var restRect: CGRect?
        if let index = restIndex, index < rects.count {
            restRect = rects.remove(at: index)
        }
        return (rects, restRect)
    }

    /// Squarified treemap (Bruls, Huizing and van Wijk). `values` must be sorted largest first.
    static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let sum = values.reduce(0, +)
        guard sum > 0, bounds.width > 0, bounds.height > 0 else {
            return values.map { _ in .zero }
        }
        var remaining = bounds
        let scale = Double(bounds.width * bounds.height) / sum
        let areas = values.map { $0 * scale }

        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var row: [Double] = []
        var index = 0
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [areas[index]]
            if row.isEmpty || worst(candidate, side: side) <= worst(row, side: side) {
                row = candidate
                index += 1
            } else {
                result += place(row, in: &remaining)
                row = []
            }
        }
        if !row.isEmpty {
            result += place(row, in: &remaining)
        }
        return result
    }

    /// The most stretched aspect ratio in a row laid along a side of length `side`.
    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else {
            return .infinity
        }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    /// Puts a row along the short side of the box and returns the box that's left.
    private static func place(_ row: [Double], in box: inout CGRect) -> [CGRect] {
        let sum = row.reduce(0, +)
        var rects: [CGRect] = []
        if box.width >= box.height {
            let width = box.height > 0 ? CGFloat(sum) / box.height : 0
            var y = box.minY
            for area in row {
                let height = width > 0 ? CGFloat(area) / width : 0
                rects.append(CGRect(x: box.minX, y: y, width: width, height: height))
                y += height
            }
            box = CGRect(x: box.minX + width, y: box.minY, width: max(0, box.width - width), height: box.height)
        } else {
            let height = box.width > 0 ? CGFloat(sum) / box.width : 0
            var x = box.minX
            for area in row {
                let width = height > 0 ? CGFloat(area) / height : 0
                rects.append(CGRect(x: x, y: box.minY, width: width, height: height))
                x += width
            }
            box = CGRect(x: box.minX, y: box.minY + height, width: box.width, height: max(0, box.height - height))
        }
        return rects
    }
}
