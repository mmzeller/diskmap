# DiskMap

A free disk-space map for your Mac, in the spirit of DaisyDisk, with a few things DaisyDisk doesn't do:

- **Explains mystery folders.** Hashed folders like Safari's website data are translated into the site they belong to ("Safari data for lookmovie2.to"). App containers, caches, iPhone backups and leftovers from deleted apps get plain-language labels and a safety rating.
- **Cleanup Ideas.** A ranked list of big items that are safe or probably safe to remove, each with an explanation.
- **What Grew.** Every scan saves a snapshot. The next scan shows exactly which folders grew and by how much.
- **Background checks.** DiskMap can check your disk every day or week on its own and notify you when usage grows past a limit you set, or when the disk is nearly full.
- **Quick rescans.** Rescan reads only the folders macOS says changed since the last scan, so it usually takes seconds.
- **Cleanup Basket.** Collect items from anywhere, see the total, and move them to the Trash together.
- **Categories.** Your disk split into Applications, Documents, Photos, Developer, Caches, App Data, macOS and more, like the Storage page in System Settings but counted from the scan, with the biggest items in each.
- **Find.** Search the whole scan by name, list the largest files, or filter by kind (videos, installers and disk images, archives and so on).
- **System & hidden, explained.** The space a scan can't see is broken down into swap, startup files and snapshots, with an option to remove local Time Machine snapshots.
- **Big & Untouched.** Large files you haven't opened in months (uses Spotlight's "last opened" date).
- **Duplicates.** Finds identical files by comparing their actual contents.
- **Uninstall Apps.** Removes an app together with the settings, caches and data it leaves in your Library, like AppCleaner. Trashing an app from anywhere in DiskMap opens the uninstaller too.
- **Quick Clean.** One checklist of routine cleanups (app caches, logs, Xcode build data, Homebrew and npm downloads, opened Mail attachments, old device backups, installers in Downloads, data from deleted apps) with sizes and a total.
- **Recently Removed.** Everything DiskMap moved to the Trash, with Put Back while it's still there.
- **Quick Look and rectangles.** Press Space or ⌘Y to preview the selected item. The map can show nested rectangles (a treemap) instead of rings.

Everything you delete goes to the Trash, so you can change your mind until you empty it.

## Download (easiest)

1. Go to [Releases](https://github.com/mmzeller/diskmap/releases/latest) and download **DiskMap.zip**.
2. Double-click it, then drag **DiskMap** into your Applications folder.
3. The first time you open it, macOS says it can't check the app for malicious software, because DiskMap isn't signed with a paid Apple developer certificate. Click **Done**, then open **System Settings → Privacy & Security**, scroll down to the message about DiskMap and click **Open Anyway**. You only do this once per version.
4. Turn on Full Disk Access (step 3 below).

The download works on both Apple silicon and Intel Macs running macOS 13 or newer.

## Build it yourself

You need macOS 13 Ventura or newer and Apple's free developer tools.

1. Open Terminal and check for the developer tools:

   ```
   xcode-select -p
   ```

   If that prints an error instead of a path, run `xcode-select --install`, click Install, and wait for it to finish.

2. Download DiskMap and build it:

   ```
   git clone https://github.com/mmzeller/diskmap.git ~/DiskMap
   bash ~/DiskMap/build.sh
   ```

   The script compiles the app, copies it to your Applications folder and opens it.

3. Turn on Full Disk Access. DiskMap shows a button that opens the right Settings page. Switch DiskMap on, then quit DiskMap (⌘Q) and open it again. Without this, macOS hides folders like Safari's website data, Mail and Messages.

## Update

If you downloaded DiskMap, download the new DiskMap.zip from Releases and replace the app.

If you built it yourself:

```
bash ~/DiskMap/update.sh
```

That gets the latest version from GitHub, rebuilds it and reopens it. Your saved scan, history and settings are kept. macOS may ask for Full Disk Access again after an update, since the rebuilt app counts as a new version.

## Using it

- **Map:** click a ring to open a folder, click the center to go back up. The list on the right shows the same folder; double-click a row to open it. Colored dots mean: green safe, teal probably safe, orange check first, purple keep, gray part of macOS. The switch at the top right (or ⌥⌘1 and ⌥⌘2) shows the map as rectangles instead; click a rectangle to open it.
- **Quick Look:** select an item and press Space or ⌘Y, or use the eye button in any list.
- **Uninstall Apps:** lists your apps by size or by when you last opened them. Uninstall shows everything that goes with the app; untick anything you want to keep. If the app is open, DiskMap offers to quit it first. Apps that come with macOS can't be removed.
- **Quick Clean:** tick the cleanups you want and click Clean Up. The arrow on each line shows exactly what's included, and you can untick single items. Moving things to the Trash doesn't free space until the Trash is emptied; tick "Empty the Trash when done" to do both at once.
- **Recently Removed:** Put Back returns an item (or a whole cleanup) to where it was, as long as it's still in the Trash.
- **Cleanup Basket:** drag rows onto Cleanup Basket in the sidebar, click the tray button next to an item, or press ⌘B. Then open the basket and click Move All to Trash.
- **Background checks:** turn them on from What Grew or DiskMap → Settings. Checks run around 12:40 pm (daily, or Mondays for weekly) even when DiskMap isn't open; if the Mac is asleep, they run when it wakes. You're notified once each time growth since your last scan passes another multiple of your limit (5 GB, then 10 GB, and so on). Clicking the notification opens What Grew.
- **Menu bar:** optional, in the same settings. With it on, closing the window leaves DiskMap in the menu bar.
- **Keyboard:** ⌘1 scan the whole disk, ⌘2 scan your home folder, ⌘O choose a folder, ⌘R quick rescan, ⇧⌘R full rescan, ⌘F find, ⌘B add to basket, Space or ⌘Y Quick Look, ⇧⌘K Quick Clean, ⇧⌘U Uninstall Apps, ⌥⌘Z Recently Removed, Delete moves the selected item to the Trash, Esc goes up a level.
- **System & hidden** on a whole-disk scan is space DiskMap can't see as files. Click "What's in System & hidden?" under the map for the breakdown: swap and sleep image, startup and recovery files, and local snapshots plus folders DiskMap can't read. Removing local Time Machine snapshots asks for your password and doesn't touch backups on your Time Machine disk.

## Notes

- Files under 1 MB are grouped per folder ("312 small files") to keep scans fast and memory use low. Find lists files of 1 MB and up.
- Files inside an app or a library (such as a Photos library) can't be trashed on their own, since that would damage it. Remove the whole app, or delete photos inside Photos.
- Copies made with Finder's Duplicate command can share space on disk (an APFS feature), so deleting one may free less than the Duplicates tab shows.
- DiskMap reopens your most recent scan when it starts. The saved scan, the snapshots for What Grew and the size history are kept in `~/Library/Application Support/DiskMap`.
- Quick rescans fall back to a full scan when macOS's change log can't cover the whole period (for example after it was reset).
- The background check is a launch agent at `~/Library/LaunchAgents/io.github.mmzeller.DiskMap.watch.plist`. Turning checks off removes it.
- The uninstaller matches leftovers by the app's identifier (like `com.tinyspeck.slackmacgap`) and, in Application Support, Caches and Logs, by its name. Name matches are labeled so you can check them. Files that belong to another installed app, even one from the same developer, are never included. System-wide items in `/Library` are listed but unticked, since removing them needs an administrator.
- Quick Clean skips the caches of apps that are open, and never touches Apple's own caches.
- Each release is built by GitHub Actions from the code in this repository (see `.github/workflows/build.yml`). Every push to `main` is built too, so a broken build shows up on the Actions tab.
