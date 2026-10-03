# PecoFence for macOS

This port uses PecoFence's existing Rust core for configuration, routing rules,
snapshots, validation, and atomic backups. AppKit and SwiftUI replace the Windows
desktop host, DirectComposition renderer, Explorer integration, and WebView2 UI.

## Build and run

Requirements: macOS 14 or newer, Xcode command-line tools, and Rust stable.
The build uses the current Mac's architecture. This checkout was tested on Apple
Silicon with macOS 26.5.1.

```sh
bash scripts/build-macos.sh
open "$HOME/Library/Caches/PecoFence/build/PecoFence.app"
```

The build creates an ad-hoc signed app in `~/Library/Caches/PecoFence/build/`
and an archive in `dist/PecoFence-macOS-arm64.zip` (or `x86_64`). Build outside
the synced Desktop because macOS File Provider can attach Finder metadata to app
bundles there, which invalidates signing. To install:

```sh
mkdir -p "$HOME/Applications"
ditto "$HOME/Library/Caches/PecoFence/build/PecoFence.app" "$HOME/Applications/PecoFence.app"
open "$HOME/Applications/PecoFence.app"
```

The local build is ad-hoc signed, not notarized for distribution to other Macs.

## Use

- Open the three-panel menu-bar icon for new fences, folder portals, settings,
  visibility, Peek, or Quit. The app does not need a Dock icon.
- Click anywhere on a fence's title bar to collapse or expand it; the chevron
  also works. Double-click the name to rename it. Drag the title bar to move it.
  Drag the bottom-right grip to resize. Lock position in
  the fence menu when the layout is settled.
- Title clicks toggle immediately. **Settings → General → Snap reordering** is
  enabled by default: drag a title onto another fence to insert it above or below
  that fence, with an 8-point gap. Panels stay in place while choosing the target;
  the target gets an outline. Disable the setting for free dragging. Locked
  panels and screen limits are respected, and rejected reorders leave the saved
  layout unchanged.
- Expanding a fence pushes overlapping fences below it down with an 8-point gap.
  Collapsing pulls a contiguous stack back up. Positions are saved together.
  Locked neighbors and insufficient screen space prevent expansion rather than
  moving a locked fence or placing another fence off-screen; the title warning
  opens Settings with the explanation. Other columns and displays stay in place.
- Drag files or folders from Finder into a virtual fence, or use **Choose files**. Assignments
  reference existing files; they do not move, copy, or delete the originals.
  Native AppKit pasteboard handling accepts Finder folder URLs, including paths
  with spaces. Dropped folders open in Finder when double-clicked; use a folder
  portal when you want to browse their contents inside a fence.
- Double-click a file to open it. Return also opens a focused file. The context
  menu provides Show in Finder, Copy file, and assignment to another fence.
- Folder portals show a live folder. Double-click subfolders to navigate inside
  the portal; the back and home controls return to its parent or root. Portals
  do not accept drops that would move files on disk.
- Use **Rules** for extension routing. Rules refresh every three seconds. Manual
  assignments take precedence until **Apply rules to all files** is selected.
- Use **Workspaces** to save or restore positions and memberships. Up to twenty
  snapshots are retained. The menu-bar Workspaces submenu switches without
  opening Settings; **⌘⌥]** selects next and **⌘⌥[** previous. Saving records stable
  display IDs. Matching workspaces restore after the connected display set
  changes; turn that behavior off in the Workspaces tab. When multiple saved
  workspaces match, the most recently saved one is selected. Positions are
  clamped to available screen space after resolution changes.
- **⌘⌥Space** toggles Peek above ordinary application windows. **Esc** returns
  fences to their desktop level. Menu-bar Peek remains available if another app
  already owns that shortcut.
- System, Light, and Dark appearance applies to fences and settings.

Controls accept the first click even when another app is active. Folding and stack
reflow share a 140 ms easing animation; Reduce Motion disables it. File icons and
portal listings are cached so resizing does not repeatedly query Finder.

**Settings → General → Hide fenced Desktop items** is off by default. When enabled,
items directly on Desktop that belong to virtual fences (including Desktop inbox)
receive Finder’s hidden flag. Files stay in place and remain available inside
fences. Disabling the option, hiding all fences, or quitting restores flags owned
by PecoFence; already-hidden files remain hidden. A recovery journal tracks file
identities and bookmarks across restarts and renames. After a crash, reopening
PecoFence reconciles the journal. Symlinks and items outside Desktop are excluded.
Finder’s Show Hidden Files shortcut can still reveal flagged originals.

Desktop access may require the macOS Files and Folders prompt. If denied, Settings
shows the error; grant access and select Retry. The app makes no global Finder preference changes.

## Developer tools

File context menus and portal menus include **Open project in**. Terminal and
installed VS Code/Xcode appear there, plus **Choose application** for another
editor. A file uses its containing directory; a folder uses itself. Xcode opens
the first `.xcworkspace`, otherwise `.xcodeproj`, in that directory. **Copy path**
copies a file's absolute path; **Copy folder path** copies the project directory.

Select a file, then press **Space** for native Quick Look. Arrow keys move through
the fence (or through items in Quick Look); **Return** opens the focused file,
**Command-C** copies it, and **Space/Esc** closes the preview. Available previews
depend on macOS and installed Quick Look providers. Quick Look stays out of the
main panel until requested.

Repository portals show branch, changed-path count, and ahead/behind counts in
one footer line. Hover for the full summary. Local Git status refreshes about
every ten seconds without fetching, committing, or pushing. Ahead/behind reflects
the last locally available tracking state. Non-repository portals show no Git
summary.

Portal options include **Hide build and dependency folders**, off by default.
It hides directory names such as `node_modules`, `target`, `build`, `dist`,
`coverage`, `Pods`, `Carthage`, and `__pycache__`. It only filters the portal view;
it does not change files or explicit virtual-fence assignments. Dot folders
remain hidden by the existing portal behavior.

Mac UI preferences (filters, snap mode, Desktop visibility, display restoration, active workspace)
live in `mac-preferences.json` beside the main config, with an atomic write and
a `.bak` copy. Copy this file separately when migrating all Mac preferences;
JSON config export includes workspaces and display profiles, not these UI
preferences.

## Configuration and CLI

Configuration lives in `~/Library/Application Support/PecoFence/config.json`.
The previous version is retained as `config.bak`, and the Rust core keeps seven
daily backups. Corrupt primary files are preserved before backup recovery.
Settings provides JSON import/export. Windows paths in imported configurations
need reassignment to local Mac files.

The bundled Mac CLI reads one JSON request from stdin and writes one JSON reply.
`ok: false` includes an error and exits with status 1. Successful replies include
the complete display state, including fence IDs. GUI and CLI writes share a
process lock. The GUI picks up terminal changes on its next refresh.

```sh
cli="$HOME/Applications/PecoFence.app/Contents/MacOS/pecofence-mac-cli"
echo '{"op":"state"}' | "$cli"
echo '{"op":"create","title":"Reading"}' | "$cli"
echo '{"op":"settings","theme":"dark"}' | "$cli"
echo '{"op":"snapshot-save","name":"Before changes"}' | "$cli"
"$cli" --help
```

Supported requests:

| `op` | Additional fields |
| --- | --- |
| `state` | None |
| `sync` | `desktop`: absolute folder path |
| `create` | `title`, optional `path` for a folder portal |
| `update` | `id`, optional `title`, `geometry`, `rolledUp`, `locked`, `view` (`icons`/`list`), `sort` (`manual`/`name`/`type`/`date`) |
| `reorder` | `id`, `target`: fence IDs, optional `after`: boolean; inserts into target stack |
| `delete` | `id` (Desktop inbox cannot be deleted) |
| `assign` | `fence`: ID, `paths`: array of existing paths |
| `remove` | `item`: ID; returns its assignment to Desktop |
| `rule-add` | `name`, `extensions`: comma-separated string, `fence`: ID |
| `rule-delete` | `id` |
| `apply-rules` | None; replaces manual assignments |
| `snapshot-save` | `name`, optional `fingerprint`: monitor identities, `geometries`: map of fence IDs to geometry |
| `snapshot-restore` | `id` |
| `settings` | Optional `theme` (`system`/`light`/`dark`), `keepUpdated`: boolean |
| `export`, `import` | `path`: JSON file path |

Use `--config-dir PATH` or `PECOFENCE_CONFIG_DIR` for isolated configuration.
`PECOFENCE_DESKTOP_DIR` overrides the GUI's Desktop source for testing.

## Verification

```sh
cargo test -p pecofence-core
cargo clippy -p pecofence-mac-cli -- -D warnings
bash scripts/build-macos.sh
python3 scripts/test-macos.py
bash scripts/test-macos-native.sh
# Quit any existing PecoFence instance before this UI check:
python3 scripts/test-macos-app.py
```

The integration test uses temporary files and checks routing, manual assignments,
snapshots, portal restrictions, invalid requests, import/export, simultaneous
clients, no-op refreshes, backup recovery, and unchanged original file contents.
The app test verifies first-click acceptance, native Quick Look, and hiding/quit
restoration on a temporary Desktop. `PecoFence --smoke-test` launches native panels
and exits after validating them;
run it with isolated config/Desktop environment variables and no other running
PecoFence instance.

## Scope

This is a usable macOS port of the grouping workflow, not full Windows feature
parity. Tabbed fences, Explorer shell extensions, Windows glass shaders, detailed
column view, multi-select, advanced rule editing, global desktop double-click
hide, language switching, login-item setup, and the Windows CLI protocol are not
implemented in the Mac UI. The upstream Windows application remains intact.
Monitor IDs and fence positions are persisted, with off-screen positions clamped
to the available work area. Fullscreen and Stage Manager behavior has not been
validated across all configurations.

## Credit

PecoFence was originally created by [DayuanJiang](https://github.com/DayuanJiang)
and contributors. This port retains that project's Rust core and Apache 2.0
license. [Original project](https://github.com/DayuanJiang/PecoFence).
