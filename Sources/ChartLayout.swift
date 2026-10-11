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
