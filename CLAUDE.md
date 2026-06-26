# DittoMac — Codebase Guide

> **For AI agents:** Read this file before scanning source files. It covers architecture,
> critical gotchas, and hard-won platform knowledge that is not obvious from the code alone.
> **Update this file whenever you change a file listed below** (add/remove/rename files, fix
> a non-obvious bug, or discover a new platform constraint). Append to "Known Gotchas" when
> you hit a macOS platform issue that took more than one attempt to solve.

---

## Project summary

Native macOS clipboard manager, a functional clone of Ditto (Windows). Menu-bar app, no Dock
icon. Built with Swift + SwiftUI/AppKit hybrid, GRDB for SQLite, Carbon for global hotkeys.
No Xcode project — uses Swift Package Manager + a Makefile.

- **Repo:** https://github.com/sohodf/DittoMac
- **Min macOS:** 13 Ventura (tested on 15 Sequoia)
- **Releases:** GitHub Releases, manual-dispatch workflow, unsigned DMG

---

## File map

```
DittoMac/
├── CLAUDE.md                          ← this file
├── README.md                          ← user-facing docs
├── Package.swift                      ← SPM manifest (GRDB dep, macOS 13, -strict-concurrency=minimal)
├── Info.plist                         ← LSUIElement=YES (hides Dock icon), bundle ID com.dittomac.app
├── Makefile                           ← build / run / debug / clean targets (NO codesign)
├── .github/workflows/build.yml        ← manual-dispatch release workflow
└── Sources/DittoMac/
    ├── main.swift                     ← @NSApplicationMain entry; sets NSApp.activationPolicy = .accessory
    ├── AppDelegate.swift              ← app lifecycle, status item, hotkey wiring, accessibility prompt
    ├── Core/
    │   ├── ClipboardEntry.swift       ← data model (GRDB FetchableRecord + MutablePersistableRecord)
    │   ├── ClipboardMonitor.swift     ← NSPasteboard polling every 0.5 s; fires onNewClip closure
    │   ├── DatabaseManager.swift      ← GRDB DatabasePool, migrations, FTS5, history-limit enforcement
    │   └── ShortcutManager.swift      ← Carbon global hotkeys + NSEvent local monitor; see gotchas
    ├── UI/
    │   ├── Popup/
    │   │   ├── PopupWindowController.swift  ← NSPanel controller; tracks previousApp for paste flow
    │   │   ├── MainView.swift               ← root SwiftUI view (search bar + clip list)
    │   │   ├── ClipRowView.swift            ← individual row; double-tap fires .pasteSelectedClip notification
    │   │   ├── SearchBarView.swift          ← NSTextField wrapper with focusSearchField observer
    │   │   └── EmptyStateView.swift         ← shown when list is empty
    │   └── Settings/
    │       ├── SettingsWindowController.swift   ← singleton; show() opens or focuses window
    │       ├── SettingsView.swift               ← tab container
    │       ├── GeneralSettingsView.swift        ← launch-at-login, history limit
    │       ├── CaptureSettingsView.swift        ← per-app exclusions, image/file toggles
    │       ├── StorageSettingsView.swift        ← db path, size, vacuum, clear
    │       └── ShortcutsSettingsView.swift      ← per-action key recorder
    ├── ViewModels/
    │   ├── ClipsViewModel.swift         ← @MainActor ObservableObject; selectedEntry, refresh, selectNext/Prev
    │   └── SettingsViewModel.swift      ← @MainActor ObservableObject; wraps UserDefaults
    └── Utilities/
        ├── PasteHelper.swift            ← write to NSPasteboard + CGEvent Cmd+V injection
        ├── AppIconFetcher.swift         ← NSWorkspace icon lookup by bundle ID
        ├── CRC32.swift                  ← deduplication checksum
        └── RelativeDate.swift           ← human-readable timestamps
```

---

## Architecture overview

### Startup sequence
1. `main.swift` creates `NSApplication`, sets `.accessory` policy, runs `AppDelegate`
2. `AppDelegate.applicationDidFinishLaunching`:
   - `DatabaseManager.shared.setup()` — opens/migrates SQLite
   - Creates `PopupWindowController` (panel not yet shown)
   - Creates `ClipboardMonitor`, wires `onNewClip`, calls `monitor.start()`
   - `setupStatusItem()` — creates menu-bar icon
   - `ShortcutManager.shared.registerGlobalHotKeys()` — Carbon hotkeys
   - `ShortcutManager.shared.onGlobalAction = { ... }` — **set once here, never overwritten**
   - `requestAccessibilityIfNeeded()` — system prompt if not granted

### Clipboard capture flow
```
NSPasteboard (poll 0.5s) → ClipboardMonitor.poll()
  → isDuplicate(crc32) check → insert() → enforceHistoryLimit()
  → ClipsViewModel.shared.refresh()
```

### Paste flow (critical — see gotchas)
```
User presses Enter in popup
  → ShortcutManager local monitor fires onLocalAction(.paste)
  → PopupWindowController.paste()
      1. PasteHelper.write(entry) — loads entry into NSPasteboard.general
      2. recordPaste(id) — async, fire-and-forget
      3. previousApp stored before dismiss
      4. dismiss() — stops local monitor, hides panel
      5. +80ms: previousApp.activate(ignoringOtherApps: true)
      6. +50ms more: PasteHelper.postCmdV() — synthesizes Cmd+V via CGEvent
```

### Shortcut routing (two separate channels)
- **Global** (`isGlobal == true`): `togglePopup`, `openSettings` — registered via Carbon
  `RegisterEventHotKey`, fired from C callback → `_shortcutManager?.handleGlobalHotKey(id:)`
  → `onGlobalAction` (set in AppDelegate, never changed)
- **Local** (all others): registered via `NSEvent.addLocalMonitorForEvents` while popup is
  open; `onLocalAction` set in `PopupWindowController.show()`, cleared on dismiss

---

## SQLite schema

**Table: `clips`**

| Column | Type | Notes |
|---|---|---|
| id | INTEGER PK | AUTOINCREMENT |
| contentType | TEXT | `text \| rtf \| image \| file` |
| content | TEXT | plain-text representation (always populated) |
| contentRTF | BLOB | raw RTF bytes |
| contentImage | BLOB | PNG data |
| contentFiles | TEXT | newline-separated paths |
| sourceApp | TEXT | bundle ID |
| sourceAppName | TEXT | display name |
| createdAt | DATETIME | |
| lastPastedAt | DATETIME | |
| pasteCount | INTEGER | default 0 |
| isPinned | INTEGER | 0/1 |
| pinOrder | INTEGER | NULL when unpinned |
| title | TEXT | user label (nullable) |
| crc32 | INTEGER | dedup checksum |

**FTS5 virtual table `clips_fts`** mirrors `content` + `title` with triggers for insert/
update/delete. Search uses `bm25()` ranking.

**Fetch order:** `isPinned DESC, pinOrder ASC (pinned only), createdAt DESC`

---

## UserDefaults keys

| Key | Type | Default | Set by |
|---|---|---|---|
| `historyLimit` | Int | 500 | StorageSettingsView |
| `captureImages` | Bool | true | CaptureSettingsView |
| `captureFiles` | Bool | true | CaptureSettingsView |
| `excludedApps` | [String] | [] | CaptureSettingsView |
| `shortcut_<action.rawValue>` | Data (JSON KeyCombo) | — | ShortcutsSettingsView |

---

## Default keyboard shortcuts

| Key | Action | `ShortcutAction` rawValue |
|---|---|---|
| ⌘⇧V | Open/close popup (global) | `togglePopup` |
| ↑ / ↓ | Navigate clips | `navigateUp` / `navigateDown` |
| ↩ | Paste selected clip | `paste` |
| ⇧↩ | Paste as plain text | `pastePlainText` |
| ⌘D | Toggle pin | `pin` |
| ⌫ | Delete clip | `delete` |
| ⎋ | Dismiss popup | `dismiss` |
| ⌘F | Focus search | `focusSearch` |
| ⌘, | Open Settings (global) | `openSettings` |

All configurable via Settings → Shortcuts. Stored in UserDefaults as JSON-encoded `KeyCombo`.

---

## Build & run

```bash
# Local development
make app          # release build → DittoMac.app
make run          # build + open
make debug        # debug build → DittoMac-Debug.app
make clean

# After rebuild, kill any running instance first:
pkill DittoMac; make run
```

**Do NOT add codesign to the Makefile.** See "TCC identity" gotcha below.

### Release workflow

File: `.github/workflows/build.yml`

- Trigger: `workflow_dispatch` with `version` input (e.g. `v1.0.2`)
- Builds with `swift build -c release` on `macos-15`
- Packages `.app` manually (no Xcode, no codesign)
- Creates UDZO-compressed DMG with `/Applications` symlink
- Auto-generates release notes from `git log` since previous tag
- Uploads DMG to a new GitHub Release via `softprops/action-gh-release@v2`
- Requires `permissions: contents: write` in the workflow

**User install steps for downloaded build:**
```bash
xattr -dr com.apple.quarantine /Applications/DittoMac.app
# Grant Accessibility when prompted on first launch
# If permission shows "already enabled" but doesn't work:
tccutil reset Accessibility com.dittomac.app
# Then relaunch and grant again
```

---

## Known gotchas (platform constraints, hard-won)

### 1. Upgrade path — version must be injected at build time
`Info.plist` in the repo always has `CFBundleShortVersionString = "1.0.0"`. The CI workflow
(`build.yml`) uses `PlistBuddy` to overwrite it with the dispatch version tag *before* building.
Without this, `AppDelegate.requestAccessibilityIfNeeded()` cannot detect upgrades (it compares
the plist version against `UserDefaults["lastLaunchedVersion"]`). On upgrade detection, the app
runs `tccutil reset Accessibility com.dittomac.app` to clear the stale TCC entry, then
re-prompts. If `tccutil` fails (requires sudo), `showManualAccessibilityResetAlert()` guides
the user to toggle the switch in System Settings → Privacy & Security → Accessibility.

### 2. TCC identity — NEVER codesign the binary
macOS TCC (Transparency, Consent, Control) tracks apps by *code identity*. An ad-hoc signed
app (`codesign --force --sign -`) gets a new identity on *every build*, so Accessibility
permission is lost after each rebuild. An **unsigned** app is tracked by **bundle path** — the
grant persists as long as the `.app` lives at the same path. Both the Makefile and the CI
workflow deliberately omit codesign for this reason. Note: on macOS 13+, even unsigned apps
lose their TCC entry when the binary is replaced, which is why upgrade detection was added.

### 2. CGEvent tap must be `.cghidEventTap`
On macOS 14+, `.cgAnnotatedSessionEventTap` silently fails to inject keyboard events.
Only `.cghidEventTap` works, but it requires Accessibility permission. See
`PasteHelper.postCmdV()`. If paste stops working in a future macOS, check this first.

### 3. Arrow key modifier flags include `.numericPad`
macOS sets `.numericPad` (and sometimes `.function`) on *all* arrow key events, even from a
regular keyboard. `deviceIndependentFlagsMask` includes these bits, so naive comparisons break.
`ShortcutManager` strips them by intersecting with `realMods = [.command, .shift, .option, .control]`
before comparing.

### 4. `onGlobalAction` vs `onLocalAction` — do not conflate
`onGlobalAction` is set once in `AppDelegate` and must never be overwritten. Early versions
let `PopupWindowController` overwrite the single `onAction` closure, breaking the global
hotkey after the first popup open. The fix was two separate closures.

### 5. ⌫ guard for search text field
The `.delete` shortcut uses keyCode 51 (backspace). When the search `NSTextField` is focused,
backspace must reach the text field, not delete the selected clip. `ShortcutManager` checks
`NSApp.keyWindow?.firstResponder is NSTextView` and passes the event through when true.

### 6. Paste timing — two nested `asyncAfter` delays
The paste flow needs 80ms for the previous app to activate before Cmd+V is sent, then a
further 50ms for the event injection. Collapsing to a single delay or using 0ms causes missed
pastes in some apps (especially Electron-based ones). Do not reduce these delays.

### 7. Carbon callback — file-scope global, not `Unmanaged`
The Carbon `InstallEventHandler` callback is a plain C function — it cannot capture Swift
context. The manager instance is stored in a `nonisolated(unsafe) private var _shortcutManager`
file-scope global. Using `Unmanaged` is fragile across rebuilds. This pattern is intentional.

### 8. Swift concurrency — `-strict-concurrency=minimal`
`Package.swift` passes `-strict-concurrency=minimal` because GRDB 6.x + AppKit have many
`Sendable` violations under `complete` checking. Do not remove this flag without a significant
migration effort.

### 9. `ClipboardMonitor` self-capture and DittoMac exclusion
The monitor checks `sourceApp == Bundle.main.bundleIdentifier` and drops its own pastes to
avoid feedback loops when loading clips into `NSPasteboard` during paste flow.

---

## Where to look for common tasks

| Task | File(s) |
|---|---|
| Add a new shortcut action | `ShortcutAction` enum in `ShortcutManager.swift`, then `handleAction` in `PopupWindowController.swift` |
| Change popup size/position | `PopupWindowController.init` and `show(relativeTo:)` |
| Add a database column | New migration in `DatabaseManager.setup()`, update `ClipboardEntry` struct |
| Change polling interval | `ClipboardMonitor.pollInterval` |
| Add a new settings pane | New SwiftUI view under `UI/Settings/`, add tab to `SettingsView.swift` |
| Debug paste not working | Check Accessibility grant, verify `.cghidEventTap` tap, check timing delays in `paste()` |
| Debug hotkey not firing | Check `_shortcutManager` is set, verify `onGlobalAction` not overwritten |
| Release a new version | Trigger `build.yml` workflow dispatch with version tag |
