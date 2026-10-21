# DiscLink (光盘通)

[中文](README.md) | English

Read and write discs on a Mac that were formatted in Windows as **“Like a USB flash drive”** (Windows' Live File System, which is UDF).

macOS can read these discs but can't write to them. DiscLink talks to the optical drive directly, so you can add, delete and replace files on them from your Mac, and keep using the same disc in Windows.

The app is called “光盘通” on Chinese systems and “DiscLink” elsewhere; its interface, error messages and command-line output follow the system language (Chinese or English).

## Status

| Disc | Format written by Windows | DiscLink |
|---|---|---|
| CD-RW, DVD-RW, DVD+RW, DVD-RAM, BD-RE | UDF 2.01, sparable or physical partition | Read & write: add, replace, delete; deleting frees the space |
| CD-R, DVD-R, DVD+R (not finalized) | UDF 2.01 + VAT (virtual allocation table) | Read & write, append only: replacing writes a new version, deleting only hides the file, space is not freed (same as in Windows) |
| UDF 2.50/2.60 (metadata partition), UDF 1.50 CD-R, BD-R | — | Read only |
| Blank or finalized discs | — | Can't be written (format blank discs in Windows first) |

- ✅ Command-line tool `udfdisc`: list folders, export, write (verified after writing), create folders, delete, consistency check
- ✅ App “DiscLink”: browse, add files (button or drag and drop), create folders, export, delete, check the disc, eject
- ✅ Liquid Glass design on macOS 26 and later: the path and status float over the file list as glass capsules, toolbar actions are grouped; macOS 14–15 get the classic look. Requires macOS 14 or later
- ✅ App icon: a complete silver disc on blue with a Liquid Glass badge (a clear glass ring, a blue puck and two-way arrows) over its lower right edge. Built as a layered Icon Composer icon (`Resources/AppIcon.icon`); the clear ring has refraction turned on, so it bends the disc's rim and tracks beneath it (the same technique as the Maps app icon). macOS 26+ renders it and adapts it to the light, dark, tinted and clear icon styles; macOS 14–15 use a regular icon that actool generates alongside. Without Xcode, the build script falls back to a flat picture (`Resources/AppIcon-1024.png`)
- ✅ All tests pass: 14 unit tests and 119 end-to-end tests (images simulating packet writing with 16- and 32-block packets, and write-once discs including the 7 link blocks a CD-R drive leaves after every write; results cross-checked with macOS's own UDF driver)
- ✅ Tested on real hardware (2026-10-19, LG GP78N external burner + a DVD-R formatted in Windows): reading, appending files and folders and deleting all work; a disc written on the Mac shows up correctly in Windows and Windows can keep adding to it, and the Mac reads and writes it again afterwards
- ⚠️ Not yet tested on real hardware: CD-RW / DVD±RW / BD-RE (packet writing), CD-R, DVD+R

### Problems found and fixed on real hardware

- On write-once discs the drive keeps reporting the old recorded capacity after appending, so DiscLink uses the track's Last Recorded Address to find the newest VAT.
- Drives retry for a long time when reading unrecorded gaps: the VAT search reads one sector at a time with a limit on failures, and cached reads fall back to single sectors when a whole block fails.
- Windows only looks for the VAT in the last sector of a 16-sector unit (a DVD ECC block), so DiscLink pads with empty sectors before writing the VAT. Discs written before this fix can be repaired with `udfdisc fix-vat drive:1`.

### How write-once discs are written

Nothing on a write-once disc can be changed, so every operation appends: first the new files' data, then the changed folders and file entries, and finally a new VAT (the table that maps virtual block numbers to their real positions). Readers always use the last VAT, so newer versions replace older ones. If an operation fails half way, the previous VAT is written again, which puts the disc back as it was, at the cost of a little space.

## Download

Download `DiscLink.zip` from the GitHub Releases page, unzip it and drag `DiscLink.app` into your Applications folder. Requires macOS 14 or later.

The app isn't notarized by Apple (it is only signed locally), so the first time you open it macOS may say the developer can't be verified: Control-click the app, choose Open, then click Open in the dialog.

## Using the app

- A disc in a drive opens automatically, whether it was already there when the app starts or you insert it while the app is running. After “Close Disc” it stays closed until you insert another disc (or eject and reinsert it).
- You can also pick a drive in the sidebar, or open a disc image with “Open Disc Image…” (an image path given on the command line takes priority).
- While the app has a disc open it holds the drive exclusively, so the disc doesn't appear in the Finder. To use the disc in the Finder, choose “Close Disc” or quit the app.
- Opening a drive first has macOS unmount the disc, then takes the drive over; closing the disc or quitting hands it back, and macOS mounts it again.
- Add files with “Add Files” in the toolbar or by dragging files and folders into the list. Everything written is read back and verified.
- Double-click a folder to open it; the path at the top takes you back up. Control-click for Export and Delete.
- The list shows Finder-style icons and a Kind column; hover over a long name to see all of it.
- The top right shows what kind of disc it is (for example “DVD-R · Write-once disc”); hover over it to see what that disc allows.
- The bottom bar shows whether the disc can be written (and why not, if it can't), the number of items or the size of the selection, and a storage bar with the free space. “Check Disc” is in the More menu.
- The first write to a real disc asks for confirmation once; try it with an unimportant disc first.
- Eject: the ⏏ button next to the drive in the sidebar, its context menu, File › Eject Disc (⌘E) or the More menu. With no disc in the drive, ⏏ opens the tray.
- File › Close Disc (⇧⌘W) only hands the drive back to macOS; it doesn't eject the disc.

## Command-line tool

```bash
.build/debug/udfdisc drives
.build/debug/udfdisc info drive:1
.build/debug/udfdisc ls drive:1 /
.build/debug/udfdisc put drive:1 ~/Desktop/file.pdf /file.pdf
.build/debug/udfdisc check drive:1
.build/debug/udfdisc eject drive:1
```

The target can also be the path of a disc image. Opening a drive unmounts the disc and takes the drive exclusively.
Images of write-once discs need `--sequential` (append only); `--link 7` simulates a CD-R's link blocks.

## Building

The app (produces `build/DiscLink.app`, shown as “光盘通” in a Chinese Finder; double-click to open):

```bash
scripts/build_app.sh
```

Use this script rather than `swift run UDFDiscApp`: with only the Command Line Tools installed, SwiftPM records the deployment target as the SDK version (14.0), and macOS then runs the app in compatibility mode with the old window chrome instead of Liquid Glass. The script records the real SDK version at link time.

If Xcode is installed but its license hasn't been accepted yet, the script falls back to the Command Line Tools.

Only the command-line tool:

```bash
swift build
```

## Languages

- Every user-facing string is written as `L("中文", "English")` (`UDFKit/Localization.swift`), keeping both languages side by side without Xcode string catalogs.
- The app follows the language macOS picks for it (`en.lproj`, `zh-Hans.lproj`), so it matches the system-provided menus; the command-line tool follows the user's language settings.
- To switch temporarily: `open build/DiscLink.app --args -AppleLanguages "(en)"` for the app, `UDFDISC_LANG=en` or `UDFDISC_LANG=zh` for the command-line tool. The end-to-end tests always run in Chinese.

## Tests

```bash
scripts/test.sh
```

Runs the unit tests (`swift run udfkit-tests`) and then the end-to-end tests. Temporary files go to the system's temporary folder and are removed afterwards; pass a folder to keep them: `scripts/test.sh ~/udf-test`.
The unit tests are a plain executable because XCTest and Swift Testing need a full Xcode install and aren't available with only the Command Line Tools.

## Code layout

| File | What it does |
|---|---|
| `Sources/CMMC/` | Optical drive access in C: sends SCSI/MMC commands through IOKit |
| `UDFKit/OpticalDrive.swift` | The drive: detects the disc type, sets write parameters, writes by packet or by appending |
| `UDFKit/SectorDevice.swift` | Sector devices (the interface shared by images and drives) and the packet-writing cache |
| `UDFKit/Bytes.swift`, `Descriptors.swift` | Byte access, CRC, descriptor tags, file name encoding, timestamps |
| `UDFKit/Structures.swift`, `SpaceBitmap.swift` | File entries, folder entries, the space bitmap |
| `UDFKit/UDFVolume.swift` | Mounting: partitions (physical / sparable / metadata / VAT) and address translation |
| `UDFKit/UDFVolume+Read.swift` | Reading: folders, files, paths, export |
| `UDFKit/UDFWrite.swift` | Writing rewritable discs: transactions, allocation, rewriting folders, deleting |
| `UDFKit/UDFWrite+VAT.swift` | Writing write-once discs: appending data and a new VAT |
| `UDFKit/Check.swift` | Consistency check and troubleshooting output |
| `UDFKit/Localization.swift` | Chinese / English text |
| `Sources/udfdisc/` | Command-line tool |
| `Sources/UDFDiscApp/` | The SwiftUI app; `Glass.swift` holds the Liquid Glass effects and their fallbacks for older systems |
| `scripts/build_app.sh` | Builds the .app, including the icon |
| `scripts/make_icon.swift`, `Resources/` | Draws the app icon: `flat` draws the single picture, `layers` draws the four layers of the layered icon (disc, glass ring, blue puck, arrows) into `AppIcon.icon/Assets`; the glass and refraction settings are in `AppIcon.icon/icon.json` |
| `Tests/UnitTests/` | Unit tests |
| `scripts/test.sh` | Full test run |

## Before using a real drive

1. Use an **unimportant test disc** first (a CD-R/DVD-R that goes wrong can only be thrown away).
2. Format it in Windows as “Like a USB flash drive” and put a few files on it.
3. On the Mac, run `info`, `ls` and `check` to make sure it reads correctly, then try `put`.
4. Take the disc back to Windows and make sure everything opens.

## License

[MIT](LICENSE)
