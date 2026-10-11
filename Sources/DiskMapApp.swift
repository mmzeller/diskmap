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
    @AppStorage(WatchKeys.menuBar) private var showMenuBar = false

    var body: some Scene {
        WindowGroup("DiskMap", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
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
        }

        Settings {
            SettingsView()
                .environmentObject(model)
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
