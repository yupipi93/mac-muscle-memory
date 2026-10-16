# Tools

Everything installed to make this Mac behave like Ubuntu and Windows, what each piece does,
where its configuration lives, and how it gets onto a new machine. `bin/apply.sh` installs and
wires up all of it; the permissions macOS reserves for a human are in `manual-steps.md`.

| Tool | Role | Installed by | Config in this repo | Needs |
|------|------|--------------|---------------------|-------|
| [Hammerspoon](#hammerspoon) | runs every custom shortcut | `brew install --cask hammerspoon` | `hammerspoon/init.lua` | Accessibility, Screen Recording |
| [noswoosh](#noswoosh) | switches desktops in ~130 ms instead of ~1.2 s | `apply.sh`, pinned release, checksum verified | none | nothing extra, runs as a child of Hammerspoon |
| [spaceswitch](#spaceswitch) | fires the native desktop shortcut from code | `apply.sh`, compiled from `helper/spaceswitch.c` | `helper/spaceswitch.c` | nothing extra |
| [Ghostty](#ghostty) | terminal with Linux-style shortcuts | `brew install --cask ghostty` | `ghostty/config` | nothing |
| [MesloLGS Nerd Font](#ghostty) | terminal font with prompt glyphs | `brew install --cask font-meslo-lg-nerd-font` | referenced by `ghostty/config` | nothing |
| [GNU nano](#gnu-nano) | terminal editor with line numbers and colours | `brew install nano` | `nano/nanorc` | nothing |
| [cliclick](#cliclick) | manual debugging only | `brew install cliclick` | none | Accessibility when run from Hammerspoon |
| [Update Cursor](#update-cursor) | keeps Cursor updatable on an account without admin rights | `apply.sh`, built by `bin/build-update-cursor-app.sh` | `bin/cursor-update.sh`, `tests/cursor-update.test.sh` | admin rights once, to move an old copy out of `/Applications` |

## Hammerspoon

A Lua automation engine for macOS. Everything custom on this machine is one file,
`hammerspoon/init.lua`, symlinked to `~/.hammerspoon/init.lua` by `apply.sh`, so editing the
repo file and reloading Hammerspoon is the whole workflow.

What it provides, each explained in `settings.md`:

- Scroll over the Dock to change desktop.
- Ctrl+Cmd+Shift+Arrow to take a window to the next desktop, Option+Shift+Arrow (Win+Shift) to the next monitor.
- Ctrl+C / X / V / Z / A, Ctrl+Shift+V, Ctrl+Arrow and Ctrl+Shift+Arrow in every app.
- Print Screen crops, saves and copies. Delete and Shift+Delete in Finder.
- Ctrl+Cmd+L to lock, Ctrl+Cmd+T for a new Ghostty window.

Two techniques do most of the work, and both are documented because neither is obvious:

- **Event taps that rewrite a key** by returning the replacement events from the tap itself,
  so they go wherever the original key was going (Spotlight and Save panels included).
  Changing the flags of the original event does nothing.
- **Child processes inherit Accessibility.** A binary launched by Hammerspoon can post events
  that WindowServer accepts; the same binary started from a shell silently does nothing.

Launches at login (`hs.autoLaunch(true)`, set by `apply.sh`). Reload after editing with the
menu bar icon, or `hs -c 'hs.reload()'` once the `hs` CLI is installed.

Permissions: **Accessibility** for everything, **Screen Recording** for the screenshot key.
Without Screen Recording, `screencapture` returns an empty image rather than an error.

## noswoosh

macOS 27 exposes no setting for the desktop switch animation; every `defaults` key the internet
suggests is gone from the Dock binary (see `macos-27-notes.md`). noswoosh switches desktops with
a synthetic gesture that skips the animation while keeping native Spaces, shared across all
monitors. Measured: ~1165 ms down to ~130 ms.

`apply.sh` downloads a pinned release into `~/Applications`, not `/Applications`, so no `sudo` is
needed, and refuses it if the SHA-256 does not match. Hammerspoon calls its CLI directly.

**Do not run `noswoosh setup`.** It disables the system shortcuts for switching desktops, and
moving a window between desktops depends on those. `noswoosh teardown` restores them.

## spaceswitch

A 60-line C program in `helper/spaceswitch.c` that presses the native desktop shortcut,
Ctrl+Cmd+Arrow, the way a physical keyboard would: real modifier key events plus the
accumulated flags on every event. The window move uses it mid-drag, and it is the fallback
switcher if noswoosh is missing.

`apply.sh` compiles it. On a system whose Command Line Tools cannot parse the newest SDK, it
builds against the newest older SDK it can find.

## Ghostty

The terminal. Its config, `ghostty/config`, is symlinked to `~/.config/ghostty/config`.

| Shortcut | Does | Why |
|----------|------|-----|
| Ctrl+Shift+T | new tab | as in Terminator and GNOME Terminal |
| Ctrl+Shift+W | close the current tab or split | as in Terminator |
| Ctrl+Tab / Ctrl+Shift+Tab | next / previous tab | Ghostty default, same as Terminator's Ctrl+PageDown / PageUp role |
| Ctrl+Shift+A | **split**: a second terminal inside the same tab | **ours**, not a Ghostty default (its own is Cmd+D / Cmd+Shift+D); `new_split:auto` picks the direction from the pane's shape |
| Cmd+Option+Arrow | move between splits | Ghostty default |
| Ctrl+Plus / Minus / 0 | font size up, down, reset | same as browsers and Linux terminals |
| Cmd+` | show or hide a drop-down terminal from any app | like Guake or Yakuake |
| Ctrl+Cmd+T | new Ghostty window, from anywhere | Ubuntu's Ctrl+Alt+T; bound in Hammerspoon |

Splits are the feature most worth knowing: Ctrl+Shift+A opens another terminal beside the
current one inside the same tab, and Ctrl+Shift+W closes whichever split has focus (the tab goes
when its last split does). Both bindings are in `ghostty/config`, not Ghostty defaults.

One conflict to know about: Ghostty resizes splits with Ctrl+Cmd+Arrow by default, and that
combination now switches desktops system-wide, so it no longer reaches Ghostty. Drag the divider
instead, or bind `resize_split` to something else in `ghostty/config`.

Font: MesloLGS Nerd Font Mono, 13 pt, so prompt themes that use Nerd Font glyphs render.

Ghostty on macOS also reads `~/Library/Application Support/com.mitchellh.ghostty/config`, and that
file wins over the first. `apply.sh` moves it aside so the repo file is the only source of truth.

**SSH to servers.** Ghostty identifies itself as `TERM=xterm-ghostty`, a terminal type remote
machines do not know. The symptoms are confusing: zsh repeats every character typed (`htop`
shows as `htoptophttohtop`) and full-screen programs refuse to start with
`Error opening terminal: xterm-ghostty`. `shell-integration-features = ssh-env,ssh-terminfo`
fixes it for every host: on the first connection Ghostty installs its terminfo entry on the
server with `tic` and caches that it did; where it cannot, it connects as `xterm-256color`.
It applies to shells opened after a config reload. To install the entry by hand on one host,
from a Ghostty window: `infocmp -x xterm-ghostty | ssh user@host -- tic -x -`.

Reload after editing with Cmd+Shift+, inside Ghostty. Check a config with
`ghostty +validate-config`.

Remember that the Ctrl remaps apply here too: Ctrl+C copies instead of interrupting (use
Ctrl+\), and Ctrl+Z and Ctrl+A are undo and select all. `settings.md` explains how to give a
single app back its native behaviour.

## GNU nano

`/usr/bin/nano` on macOS is not nano: it is a symlink to **pico**, an older editor with no line
numbers and no syntax colours. Homebrew's GNU nano (9.2 here) is the same editor as on Ubuntu,
and `/opt/homebrew/bin` comes first in `PATH`, so plain `nano` opens it.

`nano/nanorc`, symlinked to `~/.nanorc`:

- **Line numbers** (`set linenumbers`) and a scroll-position bar (`set indicator`).
- **Colours per file type**: it includes every syntax Homebrew ships, among them YAML, JSON,
  shell, Python, Markdown, Go, SQL, HTML, CSS and Makefile. Terraform and Dockerfile are not
  among them.
- Auto-indent, tabs shown 4 wide.
- **Keys that survive this repo's Ctrl remaps.** Hammerspoon turns Ctrl+X and Ctrl+C into cut and
  copy in every app, so nano's usual Exit (^X) and Cancel (^C) never arrive. Bound instead:
  **Ctrl+S** save and **Ctrl+Q** exit, or cancel a question nano is asking. F2 (exit) and F3
  (save) also work.

Verified in a pseudo-terminal: a YAML file opened with numbered lines and colour codes, no
nanorc errors, and Ctrl+Q, F2 and Ctrl+X each closed nano (Ctrl+X only because a raw
pseudo-terminal bypasses Hammerspoon; in Ghostty it becomes cut).

## cliclick

A command-line mouse and keyboard tool. The first versions of the window move used it; it is no
longer used at runtime because its internal waits cost about 450 ms per call. Kept installed
because it is handy for poking at the UI by hand.

## Update Cursor

**The problem.** Cursor updates itself with Squirrel (Electron's macOS updater). Squirrel installs
silently only when it can write both `Cursor.app` *and the folder that holds it*. On a standard
account `/Applications` is `root:admin` and not writable, so every update opens an
authorization dialog. On a machine where admin rights come from a just-in-time elevation tool
(Admin By Request and similar), that dialog shows up before the elevation is active and cannot
be answered. And when an elevated update does go through, Squirrel's privileged installer
leaves `Cursor.app` owned by root, so changing the owner alone fixes nothing: the folder is
still the obstacle.

**The fix.** A `Cursor.app` in `~/Applications` that belongs to the user. Squirrel can replace
it by itself from then on, so the elevation problem disappears instead of being worked around.
Settings, extensions and permissions do not depend on where the bundle lives.

**The button.** `~/Applications/Update Cursor.app` (Spotlight: "Update Cursor") gets there in
one step, and updates on demand later. Click it with Cursor open: it runs detached, so it
survives Cursor closing. When all is well it says so and does nothing. Otherwise it shows the
plan and, once confirmed:

1. Picks the target build: the latest from Cursor's update feed (`api2.cursor.sh/updates`, the
   one Squirrel polls), or an installed copy if that one is newer or the feed is unreachable.
2. Prepares a fresh `Cursor.app` owned by the user in `~/Library/Caches/cursor-update`: unzips
   the download or copies the installed bundle. Rejects it unless the code signature is valid,
   the Team ID is Cursor's developer (`VDXQ22DGB9`), the bundle id and version match, and every
   file belongs to the user.
3. Waits for admin rights only if an old copy sits where the user cannot write (a dialog opens
   the elevation app).
4. Closes Cursor (asking again if unsaved changes keep it open), lets Squirrel finish if
   quitting started it, and checks nothing changed meanwhile.
5. Sets every old copy aside (renamed, never modified) and moves the new one into place.
6. Opens it and waits until it runs. If it does not, puts every old copy back and reopens the
   previous Cursor.
7. Only then deletes the old copies it is allowed to delete, and reports any it is not, with
   their location.

Log: `~/Library/Logs/cursor-update.log`. The Dock and Spotlight keep working: their bookmarks
prefer the path when something is at it, so they open the new bundle (checked).

### Lessons from the first version, which broke Cursor on 2026-10-16

The first version moved the root-owned bundle to `~/Applications` and then ran
`chown -R` on it. **macOS App Management refuses any change inside a launched, notarized app
bundle, even to root** ("Operation not permitted" on every file). Renaming the whole bundle is
allowed. The script had no undo for that step and no relaunch from the new path, and its message
said the old version was still in place when it was not. Cursor was left closed, at a new path,
owned by root. What the rewrite does about each:

| Failure | Rule now |
|---------|----------|
| `chown` inside the bundle refused by App Management | Nothing inside an installed bundle is ever changed. The new bundle is a fresh copy made by the user, so it is the user's from the start. |
| A step failed with no way back | Every rename goes to a journal first; any failure puts all copies back. |
| Cursor left closed | The new Cursor must be seen running, or the old one is restored and reopened. |
| The message described the intended state | Messages read the state back from disk. |
| Old copy deleted too early, or never | Deleted only after the new Cursor runs, and only if the user owns it. |

The tests also caught two traps worth knowing: `ps | grep -q` under `set -o pipefail` reports
"not running" for a running process (grep exits early, ps dies of SIGPIPE), which would have
skipped closing Cursor; and macOS denies writes to a bundle for about half a second while it
assesses its first launch.

### Commands and tests

From a terminal (not from Cursor's own terminal, which dies when Cursor quits):

```bash
bin/cursor-update.sh --check     # copies installed, latest build, the plan, admin needed or not
bin/cursor-update.sh --dry-run   # also prepare and verify the new bundle; change nothing
bin/cursor-update.sh             # do it
tests/cursor-update.test.sh      # 19 scenarios on fake apps, failures injected at every step
```

The tests build stay-open AppleScript applets as fake Cursors in a temporary folder (paths with
spaces and an apostrophe), run the script with `/bin/bash` 3.2 as the app does, and check the
disk and the processes afterwards. They cannot reproduce App Management or the admin dialog; the
privileged path runs the same quoted command through `/bin/sh` instead.

The app carries its own copy of the script. After editing `bin/cursor-update.sh`, run
`bin/build-update-cursor-app.sh` (or `apply.sh`) to rebuild it.

## Not installed on purpose

| Idea | Why not |
|------|---------|
| Karabiner-Elements | Every remap here needs app awareness or actions beyond a key swap, which Hammerspoon covers. A second input layer would only add a place for conflicts. |
| yabai with its scripting addition | Needs System Integrity Protection partly disabled. |
| Per-display Spaces | Would fix several broken APIs, but every monitor must show the same desktop. Ruled out permanently. |
| Passwordless sudo | A standing security hole for a small convenience. |
