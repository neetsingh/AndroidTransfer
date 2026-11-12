# Android Transfer

A native macOS app for browsing an Android device over USB MTP and saving individual files to your Mac. It does not require USB debugging or an Android app. macOS 13 or later is required.

## Install on another Mac

The target Mac needs macOS 13 or later and a build whose executable **and bundled libraries** support its processor and macOS version. A compatible app bundle does not require Homebrew, Swift, or libmtp to be installed on the target Mac.

### Install a shared app bundle

1. Obtain `Android Transfer.zip` from someone you trust who has built the app using the steps below. The private GitHub repository contains source code, not a prebuilt download; you need repository access to build from source.
2. Double-click the ZIP in Finder, then drag `Android Transfer.app` to **Applications**.
3. Open it from **Applications**. The app is ad-hoc signed, not notarized, so macOS may block its first launch. If you trust the source, try opening it once, then go to **System Settings > Privacy & Security**, select **Open Anyway**, and confirm. Do not bypass a malware warning or open a bundle you do not trust.
4. Connect an Android phone and follow the instructions in [Use](#use).

To uninstall, quit the app and drag it from **Applications** to the Trash. To also remove its cached thumbnails and locations, remove `~/Library/Caches/local.androidtransfer.app`.

### Build a bundle to share

On a Mac with access to this private repository, install Apple's Command Line Tools and [Homebrew](https://brew.sh/). Then clone and build:

```sh
git clone https://github.com/neetsingh/AndroidTransfer.git
cd AndroidTransfer
brew install libmtp pkgconf
./build-app.sh
```

GitHub will require authentication for the private repository. The build creates `dist/Android Transfer.app`, bundles the locally installed libmtp and libusb libraries and their license texts, and applies an ad-hoc signature. Review license and redistribution obligations before sharing it.

Build on a Mac with the same processor architecture as the target Mac, and verify all three binaries. `arm64` is Apple silicon; `x86_64` is Intel. The `minos` shown for each binary must not exceed the target's macOS version:

```sh
for binary in \
  "dist/Android Transfer.app/Contents/MacOS/AndroidTransfer" \
  "dist/Android Transfer.app/Contents/Frameworks/libmtp.9.dylib" \
  "dist/Android Transfer.app/Contents/Frameworks/libusb-1.0.0.dylib"
do
  echo "$binary"
  lipo -archs "$binary"
  vtool -show-build "$binary"
done
codesign --verify --deep --strict --verbose=2 "dist/Android Transfer.app"
```

Homebrew libraries may require a newer macOS version than the app's macOS 13 minimum. If any binary is incompatible, build with compatible libraries and toolchain, then test on the target macOS version before sharing. For example, libraries with a macOS 27 minimum will not run on macOS 13.

Create a ZIP that preserves the app bundle, and transfer it to the target Mac:

```sh
ditto -c -k --sequesterRsrc --keepParent "dist/Android Transfer.app" "dist/Android Transfer.zip"
```

Do not enable the App Sandbox: libmtp requires direct USB access. For broader distribution without first-launch warnings, use an Apple Developer ID signature and notarization rather than the script's ad-hoc signature.

### Run from source

If you prefer to build directly on the target Mac, follow the build steps above and open `dist/Android Transfer.app`, or run from the source directory:

```sh
swift run AndroidTransfer
```

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
