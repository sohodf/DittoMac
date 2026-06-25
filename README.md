# DittoMac

A native macOS clipboard manager — a functional clone of [Ditto for Windows](https://github.com/sabrogden/Ditto), built entirely in Swift with no Xcode required.

## Features

- **Clipboard history** — captures text, RTF, images, and file paths automatically
- **Search** — full-text search powered by SQLite FTS5
- **Pin clips** — pin important clips to keep them at the top permanently
- **Paste anywhere** — select a clip and press Enter to paste it into any app
- **Plain-text paste** — Shift+Enter strips formatting before pasting
- **Fully configurable shortcuts** — every keyboard shortcut can be remapped in Settings
- **Per-app exclusions** — prevent specific apps from being captured
- **History limit** — configurable cap on how many clips to keep (default: 500)
- **Launch at login** — optional, configurable in Settings
- **Menu-bar app** — lives in the system tray, no Dock icon

## Requirements

- macOS 13 Ventura or later (tested on macOS 15 Sequoia)
- Swift Command Line Tools (`xcode-select --install`)
- **Accessibility permission** — required for simulating paste (Cmd+V) in other apps; the app prompts on first launch

## Building from source

```bash
git clone https://github.com/sohodf/DittoMac.git
cd DittoMac
make app
open DittoMac.app
```

On first launch, macOS will ask for **Accessibility** permission. Grant it in **System Settings → Privacy & Security → Accessibility** — this is required for the paste-simulation to work.

## Usage

| Action | Default shortcut |
|---|---|
| Open / close popup | **⌘⇧V** (global) |
| Navigate clips | **↑ / ↓** |
| Paste selected clip | **Enter** |
| Paste as plain text | **⇧Enter** |
| Pin / unpin clip | **⌘D** |
| Delete clip | **⌫** |
| Focus search | **⌘F** |
| Dismiss popup | **Esc** |
| Open Settings | **⌘,** |

All shortcuts are fully remappable in **Settings → Shortcuts**.

Right-click the menu-bar icon for quick access to Settings, Clear History, and Quit.

## Project structure

```
Sources/DittoMac/
├── main.swift                   # Entry point
├── AppDelegate.swift            # App lifecycle, menu bar, hotkey wiring
├── Core/
│   ├── ClipboardEntry.swift     # Data model (GRDB)
│   ├── ClipboardMonitor.swift   # NSPasteboard polling (0.5s interval)
│   ├── DatabaseManager.swift    # SQLite via GRDB, FTS5 search, migrations
│   └── ShortcutManager.swift    # Carbon global hotkeys + local key monitor
├── UI/
│   ├── Popup/                   # Floating NSPanel popup (SwiftUI)
│   └── Settings/                # Settings window (SwiftUI)
├── Utilities/
│   ├── PasteHelper.swift        # CGEvent Cmd+V simulation
│   ├── AppIconFetcher.swift     # Source-app icon lookup
│   ├── CRC32.swift              # Deduplication hashing
│   └── RelativeDate.swift       # Human-readable timestamps
└── ViewModels/
    ├── ClipsViewModel.swift     # Clip list state (ObservableObject)
    └── SettingsViewModel.swift  # Settings state
```

## Tech stack

| Component | Technology |
|---|---|
| Language | Swift 5.9+ |
| UI | SwiftUI + AppKit hybrid |
| Storage | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) 6.x |
| Full-text search | SQLite FTS5 |
| Global hotkeys | Carbon `RegisterEventHotKey` |
| Paste simulation | `CGEvent` → `.cghidEventTap` |
| Build | Swift Package Manager + Makefile |

## Install from release

1. Download **DittoMac.dmg** from the [Releases](https://github.com/sohodf/DittoMac/releases) page
2. Open the DMG and drag **DittoMac.app** to Applications
3. Remove the macOS quarantine flag (required for apps not signed with an Apple Developer ID):

```bash
xattr -dr com.apple.quarantine /Applications/DittoMac.app
```

4. Open DittoMac — grant **Accessibility** permission when prompted (needed for paste simulation)

## Database location

Clips are stored at:

```
~/Library/Application Support/DittoMac/clips.db
```

## License

MIT
