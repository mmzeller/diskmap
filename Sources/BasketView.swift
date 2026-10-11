import SwiftUI

/// Items collected from anywhere in DiskMap, to move to the Trash together.
struct BasketTab: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        PaneScroll {
            PaneHeader(tab: .basket, title: title, summary: summary) {
                if !model.basket.isEmpty {
                    Button {
                        model.trashBasket()
                    } label: {
                        Label("Move All to Trash…", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
            }

            if model.basket.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Drag items here")
                        .font(.title3.weight(.semibold))
                    Text("Drag rows from the Map or any list onto this space or onto Cleanup Basket in the sidebar. You can also use the tray button next to an item, or press ⌘B for the selected item.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                )
            } else {
                StorageMeter(
                    segments: basketSegments,
                    total: max(1, model.basketTotal),
                    height: 10
                )
                CardList {
                    ForEach(Array(model.basket.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Divider().padding(.leading, 56)
                        }
                        BasketRow(node: node)
                    }
                }
                HStack {
                    Spacer()
                    Button("Empty the Basket") { model.clearBasket() }
                        .help("Take everything out of the basket without deleting anything")
                }
            }
        }
        .dropDestination(for: String.self) { paths, _ in
            model.addToBasket(paths: paths)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    private var title: String {
        if model.basket.isEmpty { return "Cleanup Basket" }
        return "\(Fmt.bytes(model.basketTotal)) ready to remove"
    }

    private var summary: String {
        if model.basket.isEmpty {
            return "Collect things to remove from anywhere in DiskMap, then move them to the Trash in one go."
        }
        let count = model.basket.count
        return "\(count) \(count == 1 ? "item" : "items") collected. Nothing is deleted until you click Move All to Trash, and even then it goes to the Trash first."
    }

    /// Up to five biggest items get their own color in the bar; the rest share one.
    private var basketSegments: [MeterSegment] {
        let palettes = [Palette.red, Palette.orange, Palette.pink, Palette.indigo, Palette.blue]
        var segments: [MeterSegment] = []
        var rest: Int64 = 0
        for (index, node) in model.basket.enumerated() {
            if index < palettes.count {
                segments.append(MeterSegment(label: node.name, value: node.size, colors: palettes[index]))
            } else {
                rest += node.size
            }
        }
        if rest > 0 {
            segments.append(MeterSegment(label: "Others", value: rest, colors: Palette.graphite))
        }
        return segments
    }
}

struct BasketRow: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        let explanation = model.explainer.explain(node)
        HStack(spacing: 12) {
            FileIcon(node: node, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let explanation = explanation {
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
            Text(Fmt.bytes(node.size))
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
            HStack(spacing: 10) {
                Button {
                    model.showInMap(node)
                } label: {
                    Image(systemName: "chart.pie")
                }
                .help("Show in the map")
                Button {
                    model.reveal(node)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Reveal in Finder")
                Button {
                    model.removeFromBasket(node)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Take it out of the basket")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
