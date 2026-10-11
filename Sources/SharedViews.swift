import SwiftUI
import AppKit

// MARK: - Colors and symbols

extension Safety {
    var color: Color {
        switch self {
        case .safe: return .green
        case .likelySafe: return .teal
        case .review: return .orange
        case .keep: return .purple
        case .system: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .likelySafe: return "checkmark.circle"
        case .review: return "magnifyingglass.circle.fill"
        case .keep: return "lock.circle.fill"
        case .system: return "gearshape.fill"
        }
    }
}

enum Palette {
    static let blue = [Color(red: 0.33, green: 0.62, blue: 1.0), Color(red: 0.15, green: 0.40, blue: 0.96)]
    static let green = [Color(red: 0.34, green: 0.84, blue: 0.50), Color(red: 0.10, green: 0.63, blue: 0.45)]
    static let orange = [Color(red: 1.0, green: 0.66, blue: 0.26), Color(red: 0.97, green: 0.40, blue: 0.20)]
    static let indigo = [Color(red: 0.58, green: 0.50, blue: 1.0), Color(red: 0.38, green: 0.30, blue: 0.92)]
    static let pink = [Color(red: 1.0, green: 0.45, blue: 0.64), Color(red: 0.84, green: 0.24, blue: 0.55)]
    static let graphite = [Color(red: 0.62, green: 0.65, blue: 0.70), Color(red: 0.40, green: 0.43, blue: 0.49)]
    static let teal = [Color(red: 0.30, green: 0.82, blue: 0.86), Color(red: 0.10, green: 0.58, blue: 0.70)]
    static let red = [Color(red: 1.0, green: 0.42, blue: 0.38), Color(red: 0.88, green: 0.20, blue: 0.22)]
}

extension AppModel.Tab {
    var symbol: String {
        switch self {
        case .map: return "chart.pie.fill"
        case .ideas: return "sparkles"
        case .growth: return "chart.line.uptrend.xyaxis"
        case .untouched: return "clock.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .basket: return "tray.full.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .map: return Palette.blue
        case .ideas: return Palette.green
        case .growth: return Palette.orange
        case .untouched: return Palette.indigo
        case .duplicates: return Palette.pink
        case .basket: return Palette.red
        }
    }
}

// MARK: - Texture

/// A tiny tile of random grain, generated once and tiled at low opacity over large backgrounds.
enum Grain {
    static let image: NSImage = {
        let side = 96
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(side * side) {
            let value = UInt8.random(in: 0...255, using: &generator)
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return NSImage() }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }()
}

struct GrainOverlay: View {
    var opacity: Double = 0.05

    var body: some View {
        Image(nsImage: Grain.image)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// Soft tinted background with grain, used behind the start and scanning screens.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.purple.opacity(0.05), Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.teal.opacity(0.12), Color.clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 700)
            GrainOverlay(opacity: 0.06)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Building blocks

/// A white SF Symbol on a colored rounded square, like System Settings uses.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(.white)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 0.5)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]

    func icon(for node: FileNode) -> NSImage {
        if node.kind == .smallFiles {
            return NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage()
        }
        let path = node.path
        lock.lock()
        if let hit = cache[path] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let image = NSWorkspace.shared.icon(forFile: path)
        lock.lock()
        if cache.count > 3000 { cache.removeAll() }
        cache[path] = image
        lock.unlock()
        return image
    }
}

struct FileIcon: View {
    let node: FileNode
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: node))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// A thin bar showing one share of a whole.
struct SizeBar: View {
    let fraction: Double
    var colors: [Color] = Palette.blue

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
    }
}

struct MeterSegment: Identifiable {
    let id = UUID()
    let label: String
    let value: Int64
    let colors: [Color]
}

/// A storage-style bar made of colored parts, with an optional legend.
struct StorageMeter: View {
    let segments: [MeterSegment]
    let total: Int64
    var height: CGFloat = 10
    var showLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        LinearGradient(colors: segment.colors, startPoint: .top, endPoint: .bottom)
                            .frame(width: width(of: segment, in: geometry.size.width))
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1)
                            }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: height)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height / 2, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))

            if showLegend {
                HStack(spacing: 14) {
                    ForEach(segments) { segment in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(LinearGradient(colors: segment.colors, startPoint: .top, endPoint: .bottom))
                                .frame(width: 8, height: 8)
                            Text("\(segment.label) \(Fmt.bytes(segment.value))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func width(of segment: MeterSegment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let share = min(1, max(0, Double(segment.value) / Double(total)))
        return available * CGFloat(share)
    }
}

/// A progress bar with a gradient fill that eases toward its new value.
struct GradientProgressBar: View {
    let fraction: Double
    var colors: [Color] = Palette.blue
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
                    .shadow(color: (colors.last ?? Color.accentColor).opacity(0.35), radius: 4, x: 0, y: 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// Rounded container for rows, in the style of System Settings' grouped lists.
struct CardList<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Title area at the top of each insight pane.
struct PaneHeader<Accessory: View>: View {
    let tab: AppModel.Tab
    let title: String
    let summary: String
    let accessory: Accessory

    init(tab: AppModel.Tab, title: String, summary: String, @ViewBuilder accessory: () -> Accessory) {
        self.tab = tab
        self.title = title
        self.summary = summary
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: tab.symbol, colors: tab.colors, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(tab: AppModel.Tab, title: String, summary: String) {
        self.init(tab: tab, title: title, summary: summary) { EmptyView() }
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundColor(safety.color)
            .background(Capsule().fill(safety.color.opacity(0.15)))
    }
}

struct ExplanationCard: View {
    let explanation: Explanation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: explanation.safety.symbol)
                .font(.title2)
                .foregroundColor(explanation.safety.color)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(explanation.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    SafetyBadge(safety: explanation.safety)
                }
                Text(explanation.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(explanation.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [explanation.safety.color.opacity(0.13), explanation.safety.color.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(explanation.safety.color.opacity(0.25), lineWidth: 1)
        )
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small labeled number, used on the scanning screen.
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .modifier(NumericTransition())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A labeled value in a light rounded box, used in the details panel.
struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Rolling digits on macOS 14 and later; plain text before that.
struct NumericTransition: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            content.contentTransition(.numericText())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Buttons shared by every list: show in the map, reveal in Finder, move to Trash.
struct ItemActions: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    var showInMap = true

    var body: some View {
        HStack(spacing: 10) {
            if showInMap {
                Button {
                    model.showInMap(node)
                } label: {
                    Image(systemName: "chart.pie")
                }
                .help("Show in the map")
            }
            Button {
                model.reveal(node)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Reveal in Finder")
            BasketButton(node: node)
            Button {
                model.requestTrash([node])
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!model.canTrash(node))
            .help("Move to Trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// Adds an item to the Cleanup Basket, or shows that it's already there.
struct BasketButton: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        let inBasket = model.isInBasket(node)
        Button {
            model.addToBasket([node])
        } label: {
            Image(systemName: inBasket ? "tray.full.fill" : "tray.and.arrow.down")
                .foregroundColor(inBasket ? Palette.red[1] : nil)
        }
        .buttonStyle(.borderless)
        .disabled(inBasket || !model.canTrash(node) || model.isTrashFolder(node))
        .help(inBasket ? "In the Cleanup Basket" : "Add to the Cleanup Basket")
    }
}
