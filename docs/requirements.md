# DittoMac — Requirements & Implementation Plan

A native macOS clipboard manager: a functional clone of [Ditto for Windows](https://github.com/sabrogden/Ditto), rebuilt from the ground up for macOS using Swift and SwiftUI.

---

## Table of Contents

1. [Overview & Goals](#1-overview--goals)
2. [Tech Stack & Dependencies](#2-tech-stack--dependencies)
3. [Architecture](#3-architecture)
4. [Data Model & SQLite Schema](#4-data-model--sqlite-schema)
5. [Feature Scope](#5-feature-scope)
6. [UI/UX Specification](#6-uiux-specification)
7. [Keyboard Shortcuts](#7-keyboard-shortcuts)
8. [Storage & Persistence](#8-storage--persistence)
9. [Project Structure](#9-project-structure)
10. [Phased Implementation Plan](#10-phased-implementation-plan)
11. [Distribution & System Requirements](#11-distribution--system-requirements)
12. [Verification & Testing](#12-verification--testing)

---

## 1. Overview & Goals

DittoMac is a menu-bar clipboard manager for macOS. It silently monitors the system clipboard in the background and maintains a searchable, persistent history of everything the user copies. At any moment the user can summon a popup window, find an old clip, and paste it into whatever app they're working in.

### Primary Goals

| # | Goal |
|---|------|
| 1 | **Working app on macOS** — menu bar icon, runs at login, never crashes |
| 2 | **Save & pin clips** — persist clipboard history locally; pin important clips so they're always available |
| 3 | **Search** — instantly find any clip by typing; full-text search, not just prefix matching |
| 4 | **Local storage** — all data stays on-device in a SQLite database; no cloud dependency |

### Non-Goals (out of scope)
- LAN clipboard sharing (Ditto "Friends") — macOS networking APIs differ enough to be a separate project
- ChaiScript/plugin scripting engine
- Windows Registry or any platform-specific Windows feature
- Mac App Store distribution (sandbox prevents reliable clipboard monitoring)

---

## 2. Tech Stack & Dependencies

### Language & Frameworks
| Component | Choice | Reason |
|-----------|--------|--------|
| Language | Swift 5.9+ | Native, safe, best macOS API coverage |
| UI framework | SwiftUI (primary) + AppKit (where needed) | SwiftUI for speed; AppKit for window management, NSPanel, NSStatusItem |
| Minimum macOS | **13.0 (Ventura)** | Modern SwiftUI NavigationSplitView, async/await, wide adoption |
| Architecture | MVVM + service layer | Clean separation; SwiftUI binds naturally to ObservableObject ViewModels |

### Third-Party Dependencies (Swift Package Manager)
| Package | Version | Purpose |
|---------|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.x | SQLite ORM with FTS5 support, migrations, type-safe queries |
| [HotKey](https://github.com/soffes/HotKey) | 0.2.x | Global hotkey registration (wraps Carbon event APIs) |
| [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern) | 1.x | Launch-at-login toggle using ServiceManagement framework |

No other third-party dependencies. All UI is SwiftUI/AppKit; no Electron, Catalyst, or web views.

### System APIs Used
- `NSPasteboard` — read clipboard content and detect changes (polling)
- `NSStatusItem` / `NSStatusBar` — menu bar icon and menu
- `NSPanel` — floating popup window (shows above other windows without activating app)
- `CGEvent` / `CGEventPost` — simulate Cmd+V to paste into the active app
- `NSWorkspace` — look up the frontmost app's bundle ID and icon
- `ServiceManagement` — launch-at-login
- `SQLite3` (via GRDB) — local persistence

---

## 3. Architecture

### Layer Diagram

```
┌──────────────────────────────────────────┐
│              UI Layer (SwiftUI)          │
│  MainView · ClipRowView · SettingsView   │
└────────────────────┬─────────────────────┘
                     │ @Published / @ObservedObject
┌────────────────────▼─────────────────────┐
│           ViewModel Layer                │
│  ClipsViewModel · SettingsViewModel      │
└────┬───────────────┬──────────────────┬──┘
     │               │                  │
┌────▼───┐   ┌───────▼──────┐   ┌──────▼──────┐
│  Clip  │   │   Database   │   │  Keyboard   │
│Monitor │   │   Manager    │   │  Shortcut   │
│Service │   │  (GRDB/SQL)  │   │   Manager   │
└────────┘   └──────────────┘   └─────────────┘
     │
┌────▼─────────────┐
│  NSPasteboard    │  (system)
└──────────────────┘
```

### Core Modules

#### `AppDelegate`
- Owns `NSStatusItem` (menu bar icon and menu)
- Instantiates and holds all services (ClipboardMonitor, DatabaseManager, ShortcutManager)
- Registers the global popup hotkey on launch; re-registers when user changes it
- Handles app lifecycle (terminate, sleep/wake)
- Shows/hides the popup window

#### `ClipboardMonitor`
- Background `Timer` polling `NSPasteboard.general` every **0.5 seconds**
- Compares `changeCount` — only processes when changeCount differs from last observed value
- Extracts all supported clipboard formats in priority order (see §5)
- Computes CRC32 hash of content; skips if duplicate of the most recent clip
- Records source app bundle ID via `NSWorkspace.shared.frontmostApplication`
- Publishes new `ClipboardEntry` values to `ClipsViewModel` via Combine

#### `DatabaseManager`
- GRDB `DatabasePool` (WAL mode, auto-vacuum)
- Versioned migrations (GRDB `DatabaseMigrator`)
- CRUD methods: `insert`, `fetchRecent`, `search`, `pin`, `unpin`, `delete`, `clearAll`
- Enforces history limit: after each insert, deletes oldest non-pinned clips if count > limit
- FTS5 virtual table kept in sync via SQL triggers on insert/delete

#### `SearchEngine`
- Wraps DatabaseManager's FTS5 query
- Sanitizes user input (escapes special FTS5 characters)
- Supports: substring match, phrase match (`"exact phrase"`), wildcard (`word*`)
- Returns results ranked by BM25 relevance, then recency

#### `ShortcutManager`
- Loads shortcut bindings from `UserDefaults`
- Registers/unregisters global hotkeys with HotKey library
- Provides in-app local shortcut handling for the popup window (key event monitoring)
- Emits action events (paste, pin, delete, dismiss, etc.) to the active view controller
- Re-registers global hotkeys when settings change

#### `PasteHelper`
- Writes the selected `ClipboardEntry` content back to `NSPasteboard.general`
- Posts a `CGEvent` sequence (keyDown + keyUp for Cmd+V) to the system event stream
- Handles plain-text-only paste by stripping all formats except `NSPasteboard.PasteboardType.string`
- Dismisses the popup before pasting so the target app is frontmost

#### `PopupWindowController`
- `NSWindowController` wrapping an `NSPanel` (`.nonactivatingPanel`, `.hudWindow`)
- Panel appears at the configured position (at cursor, at previous position)
- Hosts a SwiftUI `MainView` via `NSHostingView`
- Monitors for clicks outside the window → auto-dismiss
- Handles show/hide animation (fade in/out)

---

## 4. Data Model & SQLite Schema

### `ClipboardEntry` (Swift model)

```swift
struct ClipboardEntry: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var contentType: ContentType      // text | rtf | image | file
    var content: String               // plain-text representation (always present; used for search/preview)
    var contentRTF: Data?             // RTF blob, if available
    var contentImage: Data?           // PNG blob, if available
    var contentFilePaths: String?     // newline-separated file paths
    var sourceApp: String?            // bundle ID, e.g. "com.apple.Safari"
    var createdAt: Date
    var lastPastedAt: Date?
    var pasteCount: Int
    var isPinned: Bool
    var pinOrder: Int?                // lower = higher in pinned list
    var title: String?                // user-editable label (Phase 2)
    var crc32: UInt32                 // for deduplication
}

enum ContentType: String, Codable {
    case text, rtf, image, file
}
```

### SQLite Schema

```sql
-- Main clips table
CREATE TABLE clips (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    content_type    TEXT NOT NULL CHECK(content_type IN ('text','rtf','image','file')),
    content         TEXT NOT NULL,          -- plain text for FTS, preview
    content_rtf     BLOB,
    content_image   BLOB,
    content_files   TEXT,                   -- newline-separated paths
    source_app      TEXT,
    created_at      DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    last_pasted_at  DATETIME,
    paste_count     INTEGER NOT NULL DEFAULT 0,
    is_pinned       INTEGER NOT NULL DEFAULT 0,
    pin_order       INTEGER,
    title           TEXT,
    crc32           INTEGER NOT NULL
);

-- Full-text search index (FTS5)
CREATE VIRTUAL TABLE clips_fts USING fts5(
    content,
    title,
    content='clips',
    content_rowid='id'
);

-- Keep FTS in sync
CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
    INSERT INTO clips_fts(rowid, content, title)
    VALUES (new.id, new.content, new.title);
END;

CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
    INSERT INTO clips_fts(clips_fts, rowid, content, title)
    VALUES ('delete', old.id, old.content, old.title);
END;

CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
    INSERT INTO clips_fts(clips_fts, rowid, content, title)
    VALUES ('delete', old.id, old.content, old.title);
    INSERT INTO clips_fts(rowid, content, title)
    VALUES (new.id, new.content, new.title);
END;

-- Indexes for common queries
CREATE INDEX idx_clips_created_at ON clips(created_at DESC);
CREATE INDEX idx_clips_is_pinned  ON clips(is_pinned, pin_order);
CREATE INDEX idx_clips_crc32      ON clips(crc32);
```

### `UserDefaults` Keys (settings)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `historyLimit` | Int | 500 | Max non-pinned clips to retain |
| `shortcut_openPopup` | Data | Cmd+Shift+V | Global popup hotkey |
| `shortcut_paste` | Data | Return | Paste selected |
| `shortcut_pastePlain` | Data | Shift+Return | Paste as plain text |
| `shortcut_pin` | Data | Cmd+D | Toggle pin |
| `shortcut_delete` | Data | Delete | Delete clip |
| `shortcut_dismiss` | Data | Escape | Dismiss popup |
| `shortcut_focusSearch` | Data | Cmd+F | Focus search bar |
| `shortcut_openSettings` | Data | Cmd+, | Open Settings |
| `shortcut_navUp` | Data | Up arrow | Navigate up |
| `shortcut_navDown` | Data | Down arrow | Navigate down |
| `popupPosition` | String | "cursor" | Where popup appears |
| `launchAtLogin` | Bool | false | Login item |
| `captureImages` | Bool | true | Save image clips |
| `captureFiles` | Bool | true | Save file-path clips |
| `excludedApps` | [String] | [] | Bundle IDs to ignore |

---

## 5. Feature Scope

### Phase 1 — MVP

#### Clipboard Capture
- [x] Monitor `NSPasteboard` every 0.5s; detect changes via `changeCount`
- [x] Capture **plain text** (`NSPasteboard.PasteboardType.string`)
- [x] Capture **RTF** (`com.apple.flat-rtf`) — stored as blob, plain-text fallback for search
- [x] Capture **images** (`public.png`, `public.tiff`) — stored as PNG blob
- [x] Capture **file paths** (`NSFilenamesPboardType`) — stored as newline-separated string
- [x] Deduplication — CRC32 hash comparison against the most recent clip; skip exact duplicates
- [x] Record source application bundle ID and name
- [x] Ignore clipboard changes from DittoMac itself (prevent feedback loop on paste)

#### Storage
- [x] SQLite database at `~/Library/Application Support/DittoMac/clips.db`
- [x] WAL journal mode, auto-vacuum
- [x] Versioned schema migrations via GRDB migrator
- [x] Auto-enforce history limit: delete oldest non-pinned clips when `COUNT(*) WHERE is_pinned=0 > historyLimit`
- [x] Pinned clips are **never** auto-deleted regardless of history limit

#### UI — Menu Bar
- [x] `NSStatusItem` icon in the menu bar (monochrome, adapts to dark/light mode)
- [x] Right-click/click menu: Open DittoMac, Settings, Clear History, Quit

#### UI — Popup Window
- [x] `NSPanel` floating above all windows, non-activating
- [x] Appears at mouse cursor position (or last position — user preference)
- [x] Default size: 420 × 520 pt (resizable; persisted)
- [x] Layout from top to bottom:
  - Search bar (always visible, auto-focused on open)
  - **Pinned** section header + pinned clips (if any)
  - **Recent** section header + recent clips list
  - Status bar: clip count, storage size
- [x] Each clip row shows:
  - Source app icon (16×16, via `NSWorkspace`)
  - Content type badge (text/image/file)
  - Content preview (first 120 chars of plain text, or "Image" / "N files")
  - Relative timestamp ("2 min ago", "Yesterday", etc.)
  - Pin indicator (filled pin icon if pinned)
- [x] Selected row highlighted in system accent color
- [x] Click outside panel → dismiss
- [x] Empty state: centered message "Nothing copied yet"

#### Search
- [x] Search bar at top of popup, auto-focused on open
- [x] Full-text search using SQLite FTS5 (`clips_fts`)
- [x] Results update as the user types (debounced 150ms)
- [x] Matching terms highlighted in the preview text
- [x] Search across both `content` and `title` fields
- [x] Clear button (×) inside search field

#### Pin / Unpin
- [x] Any clip can be pinned via keyboard shortcut, right-click menu, or swipe action
- [x] Pinned clips appear in a dedicated "Pinned" section above recent clips
- [x] Pinned order is preserved (drag to reorder within pinned section — Phase 2; initial order = pin time)
- [x] Pinning/unpinning persists to SQLite immediately

#### Paste Actions
- [x] **Paste** — writes clip to `NSPasteboard`, posts Cmd+V CGEvent to frontmost app, dismisses popup
- [x] **Paste as plain text** — strips all formats, pastes only `NSString` data

#### Delete
- [x] Delete selected clip (keyboard shortcut or right-click)
- [x] "Clear History" in menu bar menu — deletes all non-pinned clips with confirmation dialog
- [x] Pinned clips are not cleared by "Clear History"

#### Keyboard Navigation (all shortcuts user-configurable)
- [x] Open/close popup (global)
- [x] Navigate up/down through clip list
- [x] Paste selected
- [x] Paste as plain text
- [x] Toggle pin on selected
- [x] Delete selected
- [x] Dismiss popup
- [x] Focus search bar
- [x] Open Settings

#### Settings Window
- [x] General tab: launch at login, history limit (50–10,000), popup position
- [x] Keyboard Shortcuts tab: recorder UI for every action listed in §7
- [x] Capture tab: enable/disable image capture, file capture, excluded apps list
- [x] Storage tab: show DB path, DB size, "Open in Finder", "Compact Database" button

### Phase 2 — Extended Features

#### Organization
- [ ] User-editable clip title/label
- [ ] Tags (freeform, comma-separated)
- [ ] Groups / folders (hierarchical, unlimited depth — mirrors Ditto's group model)
- [ ] Drag-to-reorder pinned clips
- [ ] Drag clips into groups

#### Paste Transformations
- [ ] Paste UPPERCASE
- [ ] Paste lowercase
- [ ] Paste Titlecase
- [ ] Paste trimmed (strip leading/trailing whitespace)
- [ ] Paste with line breaks removed
- [ ] Strip formatting (already in Phase 1 as "plain text")
- [ ] Triggered via modifier key held on paste or a "Paste As…" submenu

#### Image Support
- [ ] Inline image preview in clip row (thumbnail)
- [ ] Full-size image viewer (click to expand)
- [ ] Capture image dimensions metadata

#### App Exclusions
- [ ] Settings UI to add bundle IDs to exclude list (drag-and-drop from running apps)
- [ ] DittoMac always excludes itself automatically

#### Multiple Copy Buffers
- [ ] Up to 5 named clipboard buffers, each with a separate global hotkey
- [ ] Buffers are independent of main history

#### Export / Import
- [ ] Export all clips to JSON or SQLite file
- [ ] Import from a DittoMac export file
- [ ] Selective export (export only pinned, or search results)

#### QR Code Generation
- [ ] Right-click a text clip → "Show QR Code" → generates locally via CoreImage `CIQRCodeGenerator`
- [ ] QR displayed in a small popover with copy-to-clipboard button

#### iCloud Sync (optional, behind a toggle)
- [ ] Sync pinned clips via CloudKit private database
- [ ] Recent history stays local only

#### Dark / Light Mode Theming
- [ ] Automatically follows system appearance
- [ ] Option to lock to light or dark

### Out of Scope
| Feature | Reason |
|---------|--------|
| LAN clipboard sharing ("Friends") | Requires platform-specific socket architecture; separate project |
| ChaiScript scripting | No macOS port of ChaiScript; not useful without plugin ecosystem |
| Plugin / CDLL system | Not needed for the core use case |
| Windows Registry / INI settings | macOS uses `UserDefaults` |
| RTF editing toolbar | Use the native system text editor for editing needs |
| Sending email from clips | Out of scope for a clipboard manager |

---

## 6. UI/UX Specification

### Popup Window

```
┌────────────────────────────────────────┐
│ 🔍  Search clips…                    × │  ← search bar, always focused on open
├────────────────────────────────────────┤
│ 📌 PINNED                              │
│ ┌──────────────────────────────────┐   │
│ │ 🌐 Safari  [text]  My API key…   │   │
│ │                         3 days ago│   │
│ └──────────────────────────────────┘   │
├────────────────────────────────────────┤
│ 🕐 RECENT                              │
│ ┌──────────────────────────────────┐   │
│ │ 📝 Notes   [text]  Meeting notes │   │  ← selected (accent color bg)
│ │                          2 min ago│   │
│ └──────────────────────────────────┘   │
│ ┌──────────────────────────────────┐   │
│ │ 🌐 Chrome  [img]   Image         │   │
│ │                         15 min ago│   │
│ └──────────────────────────────────┘   │
│  …                                     │
├────────────────────────────────────────┤
│ 142 clips  ·  2.3 MB                   │  ← status bar
└────────────────────────────────────────┘
```

### Clip Row States
| State | Visual |
|-------|--------|
| Normal | Default background, dimmed timestamp |
| Hovered | Slightly elevated background (system hover color) |
| Selected | System accent color background, white text |
| Pinned | Pin icon (filled) on right edge |

### Settings Window
Tabbed preferences window (standard macOS style, `NSTabViewController` or SwiftUI `TabView`):

**General tab**
- Launch at Login: toggle
- History Limit: stepper + text field (50 – 10,000)
- Popup Position: segmented control (At Cursor / At Previous Position)
- Show menu bar icon: toggle (with warning that disabling it hides access to the app)

**Keyboard Shortcuts tab**

A table with two columns: Action name | Shortcut recorder field. Every action has a "Reset" button that restores the default. Shortcut recorder is a custom `NSView` that captures the next key+modifier combination the user presses.

**Capture tab**
- Capture images: toggle
- Capture file paths: toggle
- Excluded Apps: list with +/− buttons; shows app icon + name + bundle ID

**Storage tab**
- Database path (label, non-editable)
- Database size (label, live)
- [Open in Finder] button
- [Compact Database] button (runs `VACUUM`)

---

## 7. Keyboard Shortcuts

All shortcuts are **fully user-configurable**. The table below lists defaults only. Defaults are applied on first launch if no saved preference exists. Users can change any shortcut via Settings → Keyboard Shortcuts. Pressing Delete in the recorder resets that action to its default.

| Action | Default Shortcut | Scope |
|--------|-----------------|-------|
| Open / close popup | ⌘⇧V | Global |
| Navigate up | ↑ | In popup |
| Navigate down | ↓ | In popup |
| Paste selected clip | ↩ Return | In popup |
| Paste as plain text | ⇧↩ Shift+Return | In popup |
| Toggle pin on selected | ⌘D | In popup |
| Delete selected clip | ⌫ Delete | In popup |
| Dismiss popup | ⎋ Escape | In popup |
| Focus search bar | ⌘F | In popup |
| Open Settings | ⌘, | In popup / global |

### Implementation Notes

- **Global shortcuts** (Open popup, Open Settings) are registered via the `HotKey` library, which wraps the Carbon `InstallEventHandler` API. These fire even when DittoMac is not the frontmost app.
- **Local shortcuts** (everything else) are handled via `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` within the popup window while it is key/main.
- Each shortcut is persisted in `UserDefaults` as a `Data`-encoded `KeyCombo` (keyCode + modifierFlags).
- On settings save, global hotkeys are unregistered and re-registered with the new bindings.
- Conflict detection: if the user tries to assign a shortcut already in use by another action, show an inline warning "Already used by [Action Name]" and prevent saving.

---

## 8. Storage & Persistence

### Database Location
```
~/Library/Application Support/DittoMac/clips.db
```
Created automatically on first launch. The directory is created if it does not exist.

### Database Configuration (via GRDB)
| Setting | Value | Reason |
|---------|-------|--------|
| Journal mode | WAL | Concurrent reads; faster writes |
| Auto-vacuum | INCREMENTAL | Reclaims space without full rewrite |
| Synchronous | NORMAL | Safe with WAL; faster than FULL |
| Busy timeout | 5000 ms | Graceful handling of contention |
| Cache size | 4000 pages (16 MB) | Fast repeated queries |

### History Limit Enforcement

After every `INSERT`, run:
```sql
DELETE FROM clips
WHERE is_pinned = 0
  AND id NOT IN (
    SELECT id FROM clips
    WHERE is_pinned = 0
    ORDER BY created_at DESC
    LIMIT :historyLimit
  );
```
This preserves pinned clips regardless of count. The limit only applies to unpinned history.

### Migrations

GRDB `DatabaseMigrator` is used. Each migration is named and applied in order. Never modify an applied migration — always add a new one.

```
v1: create clips, clips_fts, triggers, indexes
v2: (future) add tags column
v3: (future) add groups table
```

### Backup

Phase 2: automatic nightly backup to `~/Library/Application Support/DittoMac/backups/clips_YYYY-MM-DD.db` (keep last 7). No backup in Phase 1.

---

## 9. Project Structure

```
DittoMac/
├── DittoMac.xcodeproj
├── DittoMac/
│   ├── DittoMacApp.swift              # @main, AppDelegate wiring
│   ├── AppDelegate.swift              # NSApplicationDelegate, status item, hotkey bootstrap
│   │
│   ├── Core/
│   │   ├── ClipboardEntry.swift       # Data model (struct, Codable, GRDB protocols)
│   │   ├── ClipboardMonitor.swift     # NSPasteboard polling, publishes new entries
│   │   ├── DatabaseManager.swift      # GRDB pool, migrations, all CRUD methods
│   │   ├── SearchEngine.swift         # FTS5 query builder, sanitizer, ranking
│   │   └── ShortcutManager.swift      # UserDefaults-backed shortcut storage + HotKey registration
│   │
│   ├── ViewModels/
│   │   ├── ClipsViewModel.swift       # @MainActor, drives MainView; owns search state, clip list
│   │   └── SettingsViewModel.swift    # Drives SettingsView; reads/writes UserDefaults
│   │
│   ├── UI/
│   │   ├── Popup/
│   │   │   ├── PopupWindowController.swift  # NSPanel lifecycle, show/hide, click-outside dismiss
│   │   │   ├── MainView.swift               # Root SwiftUI view: search + sections
│   │   │   ├── ClipRowView.swift            # Single clip row
│   │   │   ├── SearchBarView.swift          # Custom search field (clear button, focus ring)
│   │   │   └── EmptyStateView.swift         # "Nothing copied yet" placeholder
│   │   │
│   │   └── Settings/
│   │       ├── SettingsWindowController.swift
│   │       ├── SettingsView.swift           # Root tab view
│   │       ├── GeneralSettingsView.swift
│   │       ├── ShortcutsSettingsView.swift  # Shortcut recorder table
│   │       ├── CaptureSettingsView.swift
│   │       └── StorageSettingsView.swift
│   │
│   ├── Utilities/
│   │   ├── PasteHelper.swift          # Write to NSPasteboard + CGEvent Cmd+V simulation
│   │   ├── AppIconFetcher.swift       # NSWorkspace icon lookup with caching
│   │   ├── Hasher.swift               # CRC32 for deduplication
│   │   └── RelativeDate.swift         # "2 min ago", "Yesterday" formatting
│   │
│   └── Resources/
│       ├── Assets.xcassets            # App icon (1024×1024), menu bar icon (18×18 template)
│       └── Info.plist                 # LSUIElement=YES (no dock icon), NSAppleEventsUsageDescription
│
├── DittoMacTests/
│   ├── DatabaseManagerTests.swift
│   ├── SearchEngineTests.swift
│   ├── HasherTests.swift
│   └── ClipboardMonitorTests.swift
│
└── docs/
    └── requirements.md                # This file
```

### `Info.plist` Required Keys

| Key | Value | Reason |
|-----|-------|--------|
| `LSUIElement` | YES | Hide dock icon; menu bar only |
| `NSAppleEventsUsageDescription` | "DittoMac uses Apple Events to paste clipboard content into other apps." | Required for CGEvent paste |
| `NSPrincipalClass` | NSApplication | Standard |

---

## 10. Phased Implementation Plan

### Phase 1 — MVP (~6 weeks)

#### Week 1: Project Scaffolding
- Create Xcode project (macOS App, SwiftUI, `LSUIElement=YES`)
- Add Swift Package dependencies (GRDB, HotKey, LaunchAtLogin)
- Implement `AppDelegate`: `NSStatusItem` with icon, basic menu (Open, Settings, Quit)
- Wire global hotkey (default Cmd+Shift+V) via `HotKey`; show/hide a placeholder `NSPanel`

#### Week 2: Data Layer
- Implement `ClipboardEntry` model with GRDB protocols
- Implement `DatabaseManager`: pool setup, migration v1 (schema + FTS + triggers + indexes)
- Unit tests for CRUD: insert, fetch, pin, delete, history limit enforcement
- Implement `Hasher` (CRC32) and test deduplication logic

#### Week 3: Clipboard Monitoring
- Implement `ClipboardMonitor`: timer loop, `changeCount` detection, format extraction
- Handle text, RTF, image, file-path formats
- Source app detection via `NSWorkspace`
- Wire monitor → `ClipsViewModel` → `DatabaseManager`
- Integration test: copy from Terminal → entry appears in DB

#### Week 4: Popup UI
- Implement `PopupWindowController` (`NSPanel` + `NSHostingView`)
- Implement `MainView`: `ClipsViewModel`-driven list with pinned/recent sections
- Implement `ClipRowView`: icon, type badge, preview, timestamp
- Implement `SearchBarView` with live FTS5 query
- Keyboard navigation (↑↓, Return, Escape) via `ShortcutManager`

#### Week 5: Paste & Pin & Settings
- Implement `PasteHelper`: write to pasteboard + CGEvent Cmd+V
- Implement paste as plain text (strip non-string formats)
- Implement pin/unpin (DB update + `ClipsViewModel` refresh)
- Implement delete (individual + clear history with confirmation)
- Implement `SettingsView` with all four tabs
- Implement `ShortcutsSettingsView` with shortcut recorder per action
- Implement `LaunchAtLogin` integration

#### Week 6: Polish & Edge Cases
- App icon (1024×1024) + menu bar template icon
- `EmptyStateView`
- `RelativeDate` formatter (2 min ago, Yesterday, etc.)
- `AppIconFetcher` with `NSCache`
- Handle edge cases: empty clipboard, binary-only formats, very large images (cap at 5 MB)
- Manual end-to-end test across Safari, Terminal, VS Code, Finder
- Fix any regressions; prepare `.app` bundle

### Phase 2 — Extended (~4 weeks)
- Weeks 7–8: Tags, groups, title editing, drag-to-reorder pinned
- Week 9: Paste transformations, image preview/expand, QR code generation
- Week 10: Export/import, app exclusions UI, multiple copy buffers

---

## 11. Distribution & System Requirements

| Property | Value |
|----------|-------|
| Distribution | Direct download — `.dmg` via GitHub Releases or personal website |
| Code signing | Developer ID Application certificate (required for Gatekeeper) |
| Notarization | Required (macOS 10.15+); submit to Apple notary service via `notarytool` |
| Sandboxed | **No** — clipboard monitoring requires `NSPasteboard` polling without entitlement restrictions; CGEvent paste simulation requires `com.apple.security.temporary-exception.apple-events` which is not granted in the sandbox |
| Minimum macOS | 13.0 (Ventura) |
| Architecture | Universal binary (arm64 + x86_64) |
| Disk space | < 5 MB app bundle; DB grows with usage (~1–50 MB typical) |

### Privacy Considerations
- All clipboard data is stored locally only; no network calls
- `Info.plist` must include usage descriptions for any sensitive APIs used
- Consider adding a "Privacy" section to the in-app About screen explaining local-only storage

---

## 12. Verification & Testing

### Automated Tests (`DittoMacTests`)

| Test | What it verifies |
|------|----------------|
| `DatabaseManagerTests.testInsertAndFetch` | Insert clip → fetch returns it |
| `DatabaseManagerTests.testHistoryLimit` | After 501 inserts (limit=500), oldest is deleted; pinned clips survive |
| `DatabaseManagerTests.testPinUnpin` | Pin sets `is_pinned=1`, appears in pinned section; unpin reverses |
| `DatabaseManagerTests.testDeduplication` | Two inserts with same CRC32 → second insert skipped |
| `SearchEngineTests.testFullTextSearch` | FTS5 query returns matching clips; non-matching clips excluded |
| `SearchEngineTests.testSearchSanitization` | Special FTS5 characters in query don't crash |
| `HasherTests.testCRC32Consistency` | Same input always produces same hash |
| `ClipboardMonitorTests.testChangeCountDetection` | No new entry when changeCount unchanged |

### Manual End-to-End Checklist

- [ ] Launch app → menu bar icon appears, no dock icon
- [ ] Copy text in Safari → open popup → clip appears at top of Recent
- [ ] Copy same text again → no duplicate in list (deduplication)
- [ ] Copy image in Preview → clip appears with "Image" badge
- [ ] Type partial search query → list filters in real time
- [ ] Press Escape → popup dismisses
- [ ] Select a clip + press Return → text pasted into active text field in another app
- [ ] Shift+Return → pasted without RTF formatting (plain text only)
- [ ] Pin a clip → it moves to Pinned section; stays there after restart
- [ ] Unpin → moves back to Recent
- [ ] Delete a clip → disappears from list
- [ ] Clear History → all non-pinned clips removed; pinned clips remain
- [ ] Change popup hotkey in Settings → new hotkey works; old one no longer works
- [ ] Set history limit to 5, copy 6 items → oldest auto-deleted
- [ ] Launch at Login toggle → app appears/disappears from Login Items
- [ ] Quit and relaunch → all clips and settings persist
