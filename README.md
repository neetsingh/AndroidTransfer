# Android Transfer

A native macOS app for browsing an Android device over USB MTP and saving individual files to your Mac. It does not require USB debugging or an Android app. macOS 13 or later is required.

## Setup and run

Install Apple's Command Line Tools and [Homebrew](https://brew.sh/), then:

```sh
brew install libmtp pkgconf
swift run AndroidTransfer
```

For a clickable app bundle, run `./build-app.sh` and open `dist/Android Transfer.app`. The script bundles the locally installed libmtp and libusb libraries, their license texts, and applies an ad-hoc signature. It is not notarized for distribution; the bundled libraries must support the target Mac's architecture and macOS version. Do not enable the App Sandbox: libmtp requires direct USB access.

## Use

1. Connect **one** Android device using a USB cable that supports data.
2. Unlock the phone, tap the USB notification, select **File transfer / Android Auto** (sometimes called **MTP**), and allow access if prompted.
3. Close other MTP applications, then click **Connect**. Select a storage volume and open folders.
4. Select a file and click **Download**, or double-click the file. Choose a new destination name; existing Mac files are never overwritten.
5. To delete items from the phone, use the selection circles or **Select All**, then click **Delete** and confirm. Deletion is permanent; deleting a folder may delete its contents. The app stops on the first failure and reports how many items were deleted.

Opening storage and folders shows an indeterminate progress bar: MTP does not report a reliable percentage for directory listings. Folders containing recognized photos, videos, or audio open in Gallery view automatically; use the view control to switch back to List. Gallery includes folders and other files. Thumbnails come from the phone when it has one, which is usually only for camera JPEGs with an embedded EXIF thumbnail. For everything else (screenshots, PNG/HEIC/WebP files, shared or edited images and videos), Android Transfer makes a preview on the Mac; progress appears above the grid. Images up to 80 MB are read in full. For videos it usually reads only the first 16 MB and last 8 MB of the file. Videos up to 300 MB are read in full if that isn't enough. An icon is shown when no preview could be made; audio uses a music icon. Gallery shows the current folder, not a recursive library of all media.

Both views show each item's modification date and time as reported by the phone, in your Mac's local time zone; hover for the full date. Items without a date reported by the device show "—".

Use the **Group by** menu to group either view:

- **Date** groups files by the day they were modified (Today, Yesterday, and so on). Days are listed newest first, or oldest first when sorting by Date (Oldest First). Folders stay at the top.
- **Location** groups photos by where they were taken. The app reads the GPS position from each photo's EXIF metadata, usually just the first 256 KB of the file. Photos up to 40 MB whose metadata is further into the file are read in full. It then looks up the place name with Apple's geocoding service, which needs an internet connection. Without a connection, groups are labelled with rounded coordinates instead. Videos, other files and photos without GPS data appear under **No location**. Scanning a large folder takes a while; progress appears above the files.

Use the **Sort** menu to order files by name (A–Z or Z–A) or by date and time (newest or oldest first). Folders always stay above files, and items without a date go last when sorting by date. The sort order also applies inside each group.

### Selecting files

Selection works like Finder in both List and Gallery:

| Action | Result |
|---|---|
| Click | Select only that item |
| ⌘-click or Control-click | Add or remove an item |
| Shift-click | Select everything between the last clicked item and this one |
| ⌘-Shift-click | Add that range to the current selection |
| Arrow keys | Move the selection (in Gallery, ↑/↓ move between rows) |
| Shift + arrow keys | Extend or shrink the selection |
| Home / End, Page Up / Page Down (Shift to extend) | Jump to the first/last item or by a page |
| ⌘A / ⌥⌘A or Escape | Select all / deselect all |
| Return, ⌘↓ or double-click | Open a folder, or download the selected file(s) |
| ⌘↑ | Go to the enclosing folder |
| Delete or ⌘⌫ | Delete the selection (after confirmation) |
| ⌘S | Download the selected file(s) |

The round checkbox on each item also adds or removes it from the selection.

When files are grouped by date or location, each group header has its own checkbox:

| Action | Result |
|---|---|
| Click the header checkbox | Select the whole group, or deselect it if it is already fully selected |
| ⌥-click the header checkbox | Select only this group |
| Right-click the header | Select Group, Select Only This Group, or Deselect Group |

The checkbox shows a dash when only part of a group is selected, and the header shows "X of N selected".

When several files are selected, **Download** asks for a destination folder and saves them all, showing overall progress. Existing files are never overwritten; a clash is saved as `IMG (2).jpg` and so on. Selected folders are skipped.

### Caching

Android Transfer caches what it reads from the phone so that browsing feels fast:

- **Folder listings** are kept for the current connection. Revisiting a folder shows it immediately while the app checks the phone for changes in the background (a small spinner appears in the status bar). **Refresh** always re-reads the folder from the phone.
- **Thumbnails and photo locations** are saved on disk in `~/Library/Caches/local.androidtransfer.app`, so they appear instantly after reconnecting or relaunching. Entries are keyed by the device's serial number, the file's path, size and modification time, so edited or replaced files are read again. The thumbnail cache is trimmed automatically when it grows past 300 MB.
- Choose **Android Transfer › Clear Cache** to remove all cached data.

Reconnect if the device disconnects or changes USB mode. Folder downloads, multiple-device selection, uploads, and automatic USB detection are not yet supported. An interrupted transfer uses a temporary `.part` file in the destination directory, which the app attempts to remove on failure.

## Library choice and references

- [libmtp](https://github.com/libmtp/libmtp) is a mature, actively maintained MTP initiator using libusb, available as a [Homebrew formula](https://formulae.brew.sh/formula/libmtp). It handles Android's standard USB file-transfer protocol rather than requiring ADB developer settings. It is licensed LGPL-2.1-or-later; its dependencies have their own licenses. Review license and redistribution obligations before distributing a bundled build.
- [OpenMTP](https://github.com/ganeshrvel/openmtp) demonstrates the viability of USB MTP on macOS, but is a complete Electron application rather than a small native library.
- [MTPKit](https://github.com/junwatu/MTPKit) is a Swift wrapper over libmtp, but at the time of research had no published version tags and little adoption. This app uses libmtp directly to avoid depending on an unversioned wrapper.

## Tests

```sh
swift test
```

Device integration requires a physical Android phone; the automated tests cover the platform-independent file ordering only.
`swift test` requires Xcode's testing frameworks; Command Line Tools alone may not include them.
