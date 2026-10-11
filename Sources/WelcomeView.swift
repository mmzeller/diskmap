import SwiftUI
import AppKit

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 26) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 112, height: 112)
                        .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 10)
                    VStack(spacing: 6) {
                        Text("DiskMap")
                            .font(.system(size: 34, weight: .bold))
                        Text("See what's filling your disk, and what's safe to remove.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if let volume = model.startupVolume {
                        VolumePanel(volume: volume)
                            .frame(maxWidth: 580)
                    }

                    if !model.hasFullDiskAccess {
                        AccessCard()
                            .frame(maxWidth: 580)
                    }

                    if let saved = model.cachedScan {
                        OpenLastScanCard(info: saved) {
                            model.openLastScan()
                        }
                        .frame(maxWidth: 580)
                    }

                    HStack(spacing: 14) {
                        ScanCard(title: "Scan \(model.diskName)", subtitle: "Everything on this Mac",
                                 symbol: "internaldrive.fill", colors: Palette.blue) {
                            model.scanDisk()
                        }
                        ScanCard(title: "Scan Home Folder", subtitle: "Your files and app data",
                                 symbol: "house.fill", colors: Palette.teal) {
                            model.scanHome()
                        }
                        ScanCard(title: "Choose Folder…", subtitle: "Any folder or drive",
                                 symbol: "folder.fill", colors: Palette.orange) {
                            model.chooseFolder()
                        }
                    }

                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(44)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (build \(build))"
    }

}

/// Shortcut back into the saved scan from the start screen.
struct OpenLastScanCard: View {
    let info: ScanCacheInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: "clock.arrow.circlepath", colors: Palette.indigo, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Last Scan")
                        .font(.headline)
                    Text("\(info.displayName), \(Fmt.bytes(info.total)), scanned \(Fmt.relative(info.date))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

/// Shown for the second or two it takes to read the saved scan at launch.
struct LoadingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 20) {
                ScanRing(icon: NSApp.applicationIconImage)
                Text("Opening your last scan of \(model.scanName)…")
                    .font(.title2.weight(.semibold))
                if let saved = model.cachedScan {
                    Text("Scanned \(Fmt.relative(saved.date)). Use Rescan in the toolbar for fresh numbers.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
        }
    }
}

struct VolumePanel: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "internaldrive.fill", colors: Palette.graphite, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name)
                        .font(.headline)
                    Text("\(Fmt.bytes(volume.available)) available of \(Fmt.bytes(volume.total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.percent(volume.used, of: volume.total))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    + Text(" used")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            StorageMeter(segments: segments, total: volume.total, height: 12)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var segments: [MeterSegment] {
        let lowSpace = Double(volume.available) / Double(max(volume.total, 1)) < 0.1
        var list = [MeterSegment(label: "Used", value: max(0, volume.used - volume.purgeable),
                                 colors: lowSpace ? Palette.orange : Palette.blue)]
        if volume.purgeable > 0 {
            list.append(MeterSegment(label: "macOS can free", value: volume.purgeable,
                                     colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.25)]))
        }
        return list
    }
}

struct AccessCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "lock.shield.fill", colors: Palette.orange, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on Full Disk Access")
                    .font(.headline)
                Text("Without it, macOS hides folders like Safari's website data, Mail and Messages, so big items there won't show up. Turn DiskMap on in the list, then quit and reopen DiskMap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Again") { model.recheckAccess() }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

struct ScanCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                IconTile(symbol: symbol, colors: colors, size: 46)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 186, height: 132)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1)
            )
            .shadow(color: Color.black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 12 : 6, x: 0, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 24) {
                ScanRing(icon: NSApp.applicationIconImage)
                VStack(spacing: 6) {
                    Text(model.isQuickRescan ? "Updating \(model.scanName)…" : "Scanning \(model.scanName)…")
                        .font(.title2.weight(.semibold))
                    if !model.scanNote.isEmpty {
                        Text(model.scanNote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 8) {
                    if let fraction = model.scanFraction {
                        GradientProgressBar(fraction: fraction, colors: Palette.blue, height: 8)
                        HStack {
                            if model.scanStepFraction == nil {
                                Text("\(Fmt.bytes(model.scanBytes)) of about \(Fmt.bytes(model.scanExpectedBytes))")
                            } else {
                                Text("Only folders that changed since the last scan")
                            }
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("\(Fmt.bytes(model.scanBytes)) found so far")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 440)

                HStack(spacing: 40) {
                    StatTile(label: "Items checked", value: Fmt.count(model.scanItems))
                    StatTile(label: "Space found", value: Fmt.bytes(model.scanBytes))
                }

                Text(model.explainer.relative(model.scanCurrentPath))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)

                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            .padding(40)
        }
    }
}

/// The app icon with a gradient ring turning around it while a scan runs.
struct ScanRing: View {
    let icon: NSImage
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 5)
                .frame(width: 136, height: 136)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    AngularGradient(colors: [Color.accentColor.opacity(0), Color.accentColor, Color.purple],
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .frame(width: 136, height: 136)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spinning)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
        }
        .onAppear { spinning = true }
    }
}
