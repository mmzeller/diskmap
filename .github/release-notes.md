## Install

1. Download **DiskMap.zip** below, double-click it, and drag **DiskMap** into your Applications folder.
2. Open DiskMap. macOS will say it can't check the app for malicious software, because DiskMap isn't signed with a paid Apple developer certificate. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down to the message about DiskMap and click **Open Anyway**. You only need to do this once per version.
3. When DiskMap asks, turn on **Full Disk Access** for it, then quit (⌘Q) and reopen it.

Works on Apple silicon and Intel Macs with macOS 13 Ventura or newer. Built automatically from this repository's code by GitHub Actions.

## What's new in 2.5

- **Fixed: updating could get stuck** on "Checking the download and putting it in place". The updater now swaps the app with simple file moves, gives up with a clear message instead of waiting forever, and quits and reopens reliably.
- If an update can't finish, **Show Log** opens a record of each step (in `~/Library/Logs/DiskMap`).
- Signed with DiskMap's own key, so Full Disk Access stays on through future updates.
