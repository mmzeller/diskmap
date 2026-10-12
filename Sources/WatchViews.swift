import SwiftUI
import AppKit

/// Controls for the background watch. Shown in DiskMap → Settings and on the What Grew page.
struct WatchSettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(WatchKeys.frequency) private var frequency = WatchFrequency.off.rawValue
    @AppStorage(WatchKeys.thresholdGB) private var thresholdGB = 5
    @AppStorage(WatchKeys.lowSpace) private var lowSpace = true
    @AppStorage(WatchKeys.menuBar) private var showMenuBar = false
    @State private var message: String?
    @State private var notificationsDenied = false
    @State private var lastCheck: Double = 0
    @State private var lastSummary = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Check my disk automatically", selection: $frequency) {
                ForEach(WatchFrequency.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .fixedSize()

            Picker("Notify me when usage grows by", selection: $thresholdGB) {
                Text("1 GB").tag(1)
                Text("5 GB").tag(5)
                Text("10 GB").tag(10)
                Text("25 GB").tag(25)
            }
            .fixedSize()
            .disabled(frequency == WatchFrequency.off.rawValue)

            Toggle("Also notify me when the disk is less than 10% free", isOn: $lowSpace)
                .disabled(frequency == WatchFrequency.off.rawValue)

            Toggle("Show DiskMap in the menu bar", isOn: $showMenuBar)

            if let message = message {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if notificationsDenied && frequency != WatchFrequency.off.rawValue {
                Label("Notifications are turned off for DiskMap. Turn them on in System Settings → Notifications → DiskMap.",
                      systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if frequency != WatchFrequency.off.rawValue {
                HStack(spacing: 10) {
                    Button(checking ? "Checking…" : "Check Now") { checkNow() }
                        .disabled(checking)
                    if lastCheck > 0 {
                        Text(lastSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onChange(of: frequency) { newValue in
            apply(WatchFrequency(rawValue: newValue) ?? .off)
        }
        .task {
            notificationsDenied = await Notifier.isDenied()
            readLastCheck()
        }
    }

    private func apply(_ choice: WatchFrequency) {
        if choice == .off {
            WatchAgent.remove()
            message = "Automatic checks are off."
            return
        }
        if let problem = WatchAgent.install(frequency: choice) {
            message = problem
            return
        }
        message = choice == .daily
            ? "DiskMap will check once a day around 12:40 pm, even when it isn't open."
            : "DiskMap will check every Monday around 12:40 pm, even when it isn't open."
        Task {
            let granted = await Notifier.requestPermission()
            notificationsDenied = !granted
        }
    }

    private func readLastCheck() {
        let defaults = UserDefaults.standard
        lastCheck = defaults.double(forKey: WatchKeys.lastCheck)
        lastSummary = defaults.string(forKey: WatchKeys.lastSummary) ?? ""
    }

    /// Runs the real background check now, then reloads the updated scan when it finishes.
    private func checkNow() {
        if !WatchAgent.isInstalled {
            apply(WatchFrequency(rawValue: frequency) ?? .weekly)
        }
        let before = UserDefaults.standard.double(forKey: WatchKeys.lastCheck)
        guard WatchAgent.runNow() else {
            message = "macOS didn't start the check. Try turning automatic checks off and on again."
            return
        }
        checking = true
        message = "Checking in the background. You'll get a notification if anything crossed your limit."
        Task {
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                UserDefaults.standard.synchronize()
                if UserDefaults.standard.double(forKey: WatchKeys.lastCheck) != before { break }
            }
            checking = false
            readLastCheck()
            message = nil
            model.openLastScan()
        }
    }
}

/// DiskMap → Settings.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                UpdateSettingsView()
            } header: {
                Text("Updates")
            } footer: {
                Text("DiskMap looks for new versions on GitHub about once a day. Updating downloads the new version, checks it, and reopens DiskMap. Your scans and settings are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                WatchSettingsView()
            } header: {
                Text("Background checks")
            } footer: {
                Text("DiskMap updates your last scan using macOS's change log, so a check usually takes seconds and doesn't slow your Mac down. It compares the result with the last scan you ran yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

/// Compact version of the settings for the What Grew page.
struct WatchCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: "bell.badge.fill", colors: Palette.orange, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Get notified when something grows")
                        .font(.headline)
                    Text("DiskMap can check on its own and tell you before a folder quietly eats your disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            WatchSettingsView()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// The small window that opens from DiskMap's menu bar icon.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let volume = VolumeInfo.forPath("/") {
                HStack(spacing: 10) {
                    IconTile(symbol: "internaldrive.fill", colors: Palette.graphite, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name)
                            .font(.headline)
                        Text("\(Fmt.bytes(volume.available)) available of \(Fmt.bytes(volume.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                StorageMeter(
                    segments: [MeterSegment(label: "Used", value: volume.used, colors: Palette.blue)],
                    total: volume.total,
                    height: 8,
                    showLegend: false
                )
            }

            if let report = model.growth {
                Text("Since your scan \(Fmt.relative(report.previousDate)): \(Fmt.signedBytes(report.currentTotal - report.previousTotal))")
                    .font(.callout)
            }
            let summary = UserDefaults.standard.string(forKey: WatchKeys.lastSummary) ?? ""
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Open DiskMap") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                Button("Update Now") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    model.rescan()
                }
                .disabled(model.phase != .results)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
