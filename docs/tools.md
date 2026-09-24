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
| [cliclick](#cliclick) | manual debugging only | `brew install cliclick` | none | Accessibility when run from Hammerspoon |

## Hammerspoon

A Lua automation engine for macOS. Everything custom on this machine is one file,
`hammerspoon/init.lua`, symlinked to `~/.hammerspoon/init.lua` by `apply.sh`, so editing the
repo file and reloading Hammerspoon is the whole workflow.

What it provides, each explained in `settings.md`:

- Scroll over the Dock to change desktop.
- Ctrl+Cmd+Shift+Arrow to take a window to the next desktop, Option+Shift+Arrow (Win+Shift) to the next monitor.
- Ctrl+C / X / V / Z / A, Ctrl+Shift+V, Ctrl+Arrow and Ctrl+Shift+Arrow in every app.
- Print Screen crops, saves and copies. Delete and Shift+Delete in Finder.
- Select text and middle-click to paste it, from a second clipboard, as on Linux.
- Ctrl+Cmd+L to lock, Ctrl+Cmd+T for a new Ghostty window.

Two techniques do most of the work, and both are documented because neither is obvious:

- **Event taps that rewrite a key** and post the replacement straight to the frontmost app with
  `hs.eventtap.keyStroke(mods, key, 0, app)`. Posting to the app sidesteps the modifier the user
  is still holding. Changing the flags of the original event does nothing.
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

Reload after editing with Cmd+Shift+, inside Ghostty. Check a config with
`ghostty +validate-config`.

Remember that the Ctrl remaps apply here too: Ctrl+C copies instead of interrupting (use
Ctrl+\), and Ctrl+Z and Ctrl+A are undo and select all. `settings.md` explains how to give a
single app back its native behaviour.

## cliclick

A command-line mouse and keyboard tool. The first versions of the window move used it; it is no
longer used at runtime because its internal waits cost about 450 ms per call. Kept installed
because it is handy for poking at the UI by hand.

## Not installed on purpose

| Idea | Why not |
|------|---------|
| Karabiner-Elements | Every remap here needs app awareness or actions beyond a key swap, which Hammerspoon covers. A second input layer would only add a place for conflicts. |
| yabai with its scripting addition | Needs System Integrity Protection partly disabled. |
| Per-display Spaces | Would fix several broken APIs, but every monitor must show the same desktop. Ruled out permanently. |
| Passwordless sudo | A standing security hole for a small convenience. |
