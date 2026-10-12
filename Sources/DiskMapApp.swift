import SwiftUI
import AppKit
import UserNotifications

/// Entry point. macOS starts the same program for scheduled background checks, with --background-check;
/// those run without any windows and exit when done.
@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--background-check") {
            exit(BackgroundCheck.run())
        }
        // Used only by the automated tests on GitHub: install a downloaded zip over this copy.
        let arguments = CommandLine.arguments
        if ProcessInfo.processInfo.environment["DISKMAP_SELF_TEST"] == "1",
           let index = arguments.firstIndex(of: "--test-install"), arguments.count > index + 2 {
            exit(UpdateSelfTest.run(zip: arguments[index + 1], version: arguments[index + 2]))
        }
        DiskMapApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        WatchAgent.ensureCurrent()
    }

    /// With the menu bar icon on, closing the window leaves DiskMap running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: WatchKeys.menuBar)
    }
}

struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()
    @AppStorage(WatchKeys.menuBar) private var showMenuBar = false

    var body: some Scene {
        WindowGroup("DiskMap", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkNow() }
                    .disabled(updater.isBusy)
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan \(model.diskName)") { model.scanDisk() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Scan Home Folder") { model.scanHome() }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Choose Folder to Scan…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Full Rescan") { model.fullRescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Find Files…") { model.selectedTab = .find }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.phase != .results)
                Button("Add Selection to Cleanup Basket") {
                    if let node = model.selection { model.addToBasket([node]) }
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Quick Look") { model.previewSelection() }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(model.selection == nil && model.previewURL == nil)
                Divider()
                Button("Show Map as Rings") { model.mapStyle = .rings }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Show Map as Rectangles") { model.mapStyle = .treemap }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
                Button("Quick Clean") { model.selectedTab = .quickClean }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.phase != .results)
                Button("Uninstall Apps") { model.selectedTab = .apps }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.phase != .results)
                Button("Recently Removed") { model.selectedTab = .removed }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(model.phase != .results)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: "chart.pie.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
