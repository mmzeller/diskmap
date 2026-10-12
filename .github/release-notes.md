## Install

1. Download **DiskMap.zip** below, double-click it, and drag **DiskMap** into your Applications folder.
2. Open DiskMap. macOS will say it can't check the app for malicious software, because DiskMap isn't signed with a paid Apple developer certificate. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down to the message about DiskMap and click **Open Anyway**. You only need to do this once per version.
3. When DiskMap asks, turn on **Full Disk Access** for it, then quit (⌘Q) and reopen it.

Works on Apple silicon and Intel Macs with macOS 13 Ventura or newer. Built automatically from this repository's code by GitHub Actions.

## What's new in 2.2

- **Uninstall Apps** removes an app together with the settings, caches and data it leaves in your Library. Files belonging to another installed app are never included.
- **Quick Clean** puts routine cleanups in one checklist with sizes: app caches, logs, Xcode build data, Homebrew and npm downloads, opened Mail attachments, device backups, installers in Downloads and data from deleted apps.
- **Recently Removed** lists everything DiskMap moved to the Trash, with **Put Back**.
- **Quick Look**: press Space or ⌘Y to preview the selected item.
- The map can show **rectangles** (a treemap) instead of rings.
