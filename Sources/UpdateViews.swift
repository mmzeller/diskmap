import SwiftUI
import AppKit

/// The Software Update window: checking, what's new, download progress, and the result.
struct UpdateSheet: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content

            HStack(spacing: 10) {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return "Checking for Updates"
        case .upToDate: return "DiskMap Is Up to Date"
        case .available(let release): return "DiskMap \(release.version) Is Available"
        case .downloading, .installing: return "Updating DiskMap"
        case .failed: return "Couldn't Update"
        case .updated(let version, _): return "DiskMap Was Updated to \(version)"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .idle, .checking: return "Looking for a newer version on GitHub…"
        case .upToDate: return "You have the newest version, \(updater.currentVersion)."
        case .available: return "You have version \(updater.currentVersion)."
        case .downloading: return "Downloading the new version…"
        case .installing: return updater.installStep.isEmpty ? "Putting the new version in place…" : updater.installStep
        case .failed: return "Nothing was changed. You still have version \(updater.currentVersion)."
        case .updated: return "Your scans, history and settings were kept."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking, .installing:
            ProgressView()
                .progressViewStyle(.linear)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                GradientProgressBar(fraction: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            EmptyView()
        case .available(let release):
            VStack(alignment: .leading, spacing: 10) {
                if !release.notes.isEmpty {
                    WhatsNewList(notes: release.notes)
                }
                Text("DiskMap will download the update, quit, and open again on the new version. It takes a few seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        case .updated(_, let notes):
            VStack(alignment: .leading, spacing: 10) {
                if !notes.isEmpty {
                    WhatsNewList(notes: notes)
                }
                if !Permissions.hasFullDiskAccess() {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("macOS treats each new version as a new app, so Full Disk Access needs turning on again. If DiskMap is already switched on in the list, switch it off and back on, then quit and reopen DiskMap.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Full Disk Access Settings") { updater.openFullDiskAccessSettings() }
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .idle, .checking:
            Button("Cancel") { updater.dismiss() }
                .keyboardShortcut(.cancelAction)
        case .downloading, .installing:
            EmptyView()
        case .upToDate, .updated:
            Button("OK") { updater.dismiss() }
                .keyboardShortcut(.defaultAction)
        case .available:
            Button("Not Now") { updater.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Update and Reopen") { updater.install() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Show Log") { updater.showLog() }
            Button("Open Download Page") { updater.openDownloadPage() }
            Button("Close") { updater.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The bullet points from a release's "What's new".
struct WhatsNewList: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's new")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(WhatsNewList.styled(note))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// Keeps **bold** and similar from the release notes.
    static func styled(_ note: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: note, options: options)) ?? AttributedString(note)
    }
}

/// Settings → Updates.
struct UpdateSettingsView: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(updater.currentVersion)")
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let release = updater.available {
                Button("Update to \(release.version)…") { updater.showAvailable() }
            }
            Button("Check Now") { updater.checkNow(showWindow: false) }
                .disabled(updater.isBusy)
        }
    }

    private var lastCheckedText: String {
        switch updater.phase {
        case .checking: return "Checking…"
        case .downloading, .installing: return "Updating…"
        case .failed(let message): return message
        case .upToDate: return "Up to date"
        default: break
        }
        if let release = updater.available { return "Version \(release.version) is available" }
        guard let date = updater.lastChecked else { return "Not checked yet" }
        return "Last checked \(Fmt.relative(date))"
    }
}
