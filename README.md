# DiskMap

A free disk-space map for your Mac, in the spirit of DaisyDisk, with a few things DaisyDisk doesn't do:

- **Explains mystery folders.** Hashed folders like Safari's website data are translated into the site they belong to ("Safari data for lookmovie2.to"). App containers, caches, iPhone backups and leftovers from deleted apps get plain-language labels and a safety rating.
- **Cleanup Ideas.** A ranked list of big items that are safe or probably safe to remove, each with an explanation.
- **What Grew.** Every scan saves a snapshot. The next scan shows exactly which folders grew and by how much.
- **Background checks.** DiskMap can check your disk every day or week on its own and notify you when usage grows past a limit you set, or when the disk is nearly full.
- **Quick rescans.** Rescan reads only the folders macOS says changed since the last scan, so it usually takes seconds.
- **Cleanup Basket.** Collect items from anywhere, see the total, and move them to the Trash together.
- **Big & Untouched.** Large files you haven't opened in months (uses Spotlight's "last opened" date).
- **Duplicates.** Finds identical files by comparing their actual contents.

Everything you delete goes to the Trash, so you can change your mind until you empty it.

## Install

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

```
bash ~/DiskMap/update.sh
```

That gets the latest version from GitHub, rebuilds it and reopens it. Your saved scan, history and settings are kept. macOS may ask for Full Disk Access again after an update, since the rebuilt app counts as a new version.

## Using it

- **Map:** click a ring to open a folder, click the center to go back up. The list on the right shows the same folder; double-click a row to open it. Colored dots mean: green safe, teal probably safe, orange check first, purple keep, gray part of macOS.
- **Cleanup Basket:** drag rows onto Cleanup Basket in the sidebar, click the tray button next to an item, or press ⌘B. Then open the basket and click Move All to Trash.
- **Background checks:** turn them on from What Grew or DiskMap → Settings. Checks run around 12:40 pm (daily, or Mondays for weekly) even when DiskMap isn't open; if the Mac is asleep, they run when it wakes. You're notified once each time growth since your last scan passes another multiple of your limit (5 GB, then 10 GB, and so on). Clicking the notification opens What Grew.
- **Menu bar:** optional, in the same settings. With it on, closing the window leaves DiskMap in the menu bar.
- **Keyboard:** ⌘1 scan the whole disk, ⌘2 scan your home folder, ⌘O choose a folder, ⌘R quick rescan, ⇧⌘R full rescan, ⌘B add to basket, Delete moves the selected item to the Trash, Esc goes up a level.
- **System & hidden** on a whole-disk scan is space DiskMap can't see as files: macOS itself, local Time Machine snapshots, swap, purgeable files and protected folders.

## Notes

- Files under 1 MB are grouped per folder ("312 small files") to keep scans fast and memory use low.
- Copies made with Finder's Duplicate command can share space on disk (an APFS feature), so deleting one may free less than the Duplicates tab shows.
- DiskMap reopens your most recent scan when it starts. The saved scan, the snapshots for What Grew and the size history are kept in `~/Library/Application Support/DiskMap`.
- Quick rescans fall back to a full scan when macOS's change log can't cover the whole period (for example after it was reset).
- The background check is a launch agent at `~/Library/LaunchAgents/io.github.mmzeller.DiskMap.watch.plist`. Turning checks off removes it.
