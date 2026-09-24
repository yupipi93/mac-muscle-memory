# Changelog

## 2026-09-22

Initial setup. The session started as "make the mouse wheel scroll like Windows" and grew into
a working Ubuntu-style desktop switcher.

### Added

- Scroll over the Dock to change desktop, in `hammerspoon/init.lua`. Wheel up goes to the
  previous desktop, wheel down to the next. The event is consumed so macOS does not also fire
  App Expose.
- `cliclick` via Homebrew, as the only way found to inject a keystroke that WindowServer
  actually acts on.
- Hammerspoon set to launch at login. It was installed and configured but never running.

### Fixed

- Ctrl+Shift+Left / Right, which moved nothing. Two independent causes: `moveWindowToSpace`
  silently does nothing on macOS 27, and the injected Ctrl+Arrow arrived contaminated with the
  Shift the user was still holding. Replaced with a title bar drag, and a wait for the
  modifiers to be released.
- The same shortcut failing specifically on maximised windows. The grab point was the centre
  of the title bar, which on a maximised window lands on Cursor's command centre or a Chrome
  tab, so the click opened UI instead of dragging. Moved to 85% of the window width.

### Changed

- `com.apple.swipescrolldirection` to `false`, natural scrolling off. Done by the user.
- `mru-spaces` to `false`, so desktops keep a fixed order.
- `expose-animation-duration` to 0.001, `NSWindowResizeTime` to 0.001,
  `workspaces-edge-delay` to 0.05, `workspaces-swoosh-animation-off` to true.
- Reduce motion enabled by the user in System Settings > Accessibility > Motion. It cannot be
  scripted, the domain is protected.

### Tried and rejected

- `hs.spaces.gotoSpace` and `hs.spaces.moveWindowToSpace`, both broken on this build.
- `hs.eventtap.keyStroke` and `hs.eventtap.event.newKeyEvent():post()` for the Space shortcut.
  Emitted but ignored, they post below the level WindowServer listens at.
- AppleScript through System Events. Automation permission was never granted, the call hangs
  and times out with `-1712`.
- `NSWindowShouldDragOnGesture`, to drag a window from any point with Ctrl+Cmd. Only applies
  to apps launched afterwards, so it did not help. Reverted.
- Passwordless `sudo` for the agent. Rejected as a standing security hole.

### Still open

The desktop switch animation is still too slow for the user. See `OPEN-ITEMS.md`.

## 2026-09-22, later the same day

### Desktop switch animation, solved

From ~1165 ms to ~130 ms, roughly 9x, with native Spaces still spanning all three displays.
That constraint is now recorded as non negotiable: every monitor shows the same desktop, so
per display Spaces is permanently off the table.

- Added **noswoosh**, installed to `~/Applications` with a checksum check, because the
  Homebrew cask needs `sudo` for `/Applications` and an agent cannot answer a password prompt.
  Hammerspoon calls its CLI and the child inherits the Accessibility grant.
- Added `bin/measure-switch.sh`, so configurations are compared with numbers rather than
  impressions.

### Ruled out, with evidence rather than rumour

Grepping the Dock binary showed `workspaces-swoosh-animation-off` no longer exists at all on
macOS 27, which is why setting it did nothing. Three keys that *do* exist were each tested with
a Dock restart and timed trials: `firenze-animation-time`, `xfade-duration` and
`workspaces-auto-swoosh`. All within noise of the baseline.

### Fixed

- `hs.task` objects were not being kept alive, so the switch failed intermittently in a way
  that looked like the mechanism being unreliable. `runTask` now holds the reference.

### Trap worth knowing

`noswoosh setup` disables system shortcuts 79 and 81, which breaks moving a window between
desktops, since that depends on the native Ctrl+Arrow firing during a drag. Its LaunchAgent is
deliberately not installed. `noswoosh teardown` restores the shortcuts.

### Directional sweep

Instant switching lost the only useful thing the native animation did: showing which way you
went. Added `showSwitchHint`, a panel that sweeps in the direction the desktop content would
have moved, one canvas per display, tunable via `HINT_DURATION` and `HINT_ALPHA`. Since we
draw it, its speed is ours to choose, unlike the native animation. Measured cost: none, the
switch still medians 130 ms.

## 2026-09-24, Option+Tab for the next window of the same app

- Symbolic hotkey 27, "move focus to next window", rebound from Cmd+` to **Option+Tab**, like
  Alt+` on GNOME. Shift reverses it. Native behaviour, only moved; it also frees Cmd+` for
  Ghostty's Quick Terminal.
- Verified with three Chrome windows: Option+Tab visited each in turn, Option+Shift+Tab went
  back. Backup of the previous shortcuts taken first; `apply.sh` writes it, `capture.sh` checks it.
- Shortcut card updated, still one A4 page (print sizes tightened slightly).

## 2026-09-24, Ctrl+B for bold

- **Ctrl+B** bolds the selected text in every app, posted as Cmd+B. Verified in TextEdit:
  Helvetica became Helvetica-Bold.
- Cost: Ctrl+B no longer reaches terminals, where it is tmux's default prefix and readline's
  "back one character". Listed on the shortcut card with the other terminal trade-offs.

## 2026-09-24, Ghostty tabs, and keyboard-specific material made private

- Ghostty: **Ctrl+Shift+T** opens a new tab, alongside the existing Ctrl+Shift+W to close it,
  as in Terminator. Ctrl+Tab and Ctrl+Shift+Tab switch tabs by Ghostty default. Verified in the
  running Ghostty through Accessibility: one tab, two after Ctrl+Shift+T, one after Ctrl+Shift+W.
- Everything about one particular keyboard model, its key mapper script and its manual steps
  moved to the gitignored `personal/`. The public docs keep only the generic idea of a
  programmable keyboard as a configuration layer.
- Shortcut card: new Ghostty terminal section, still one A4 page; README screenshot refreshed.

## 2026-09-24, published under the MIT license

- `LICENSE` (MIT) added and the repository made public.

## 2026-09-24, personal/ for private data, and a fresh public history

- **`personal/`**, in `.gitignore`: the owner's machine identifiers, the full record of their
  keyboard, machine-specific open items, backups and notes. **`personal.example/`** is the
  tracked template other users copy to keep their own details out of git.
- `docs/machine.md` moved to `personal/machine.md`, the keyboard's device record to
  `personal/keyboard.md`, and the machine-specific open items to `personal/open-items.md`.
- **The git history was restarted** for publishing: the original 30 commits carried personal
  identifiers and a work email as author. They are preserved, restorable, as a git bundle in
  `personal/history/`, next to the full commit log and pre-scrub copies of the docs. This
  changelog is the public record of everything done before.

## 2026-09-24, renamed to mac-muscle-memory and prepared for publishing

- **Renamed** from `mac-config` to `mac-muscle-memory`, on GitHub (which redirects the old
  name) and locally. `init.lua` now derives the repo path from where `~/.hammerspoon/init.lua`
  points, so the clone can live anywhere under any name.
- **Ghostty config moved into the repo** as `ghostty/config`, symlinked to
  `~/.config/ghostty/config`. The two files Ghostty was reading were merged; the second one,
  under Application Support, overrides the first and is now moved aside by `apply.sh`.
  `apply.sh` also installs Ghostty and the MesloLGS Nerd Font.
- **`docs/tools.md`**: every installed tool, its role, where its config lives, and the
  permissions it needs, plus what was deliberately not installed.
- **README rewritten** around a screenshot of the shortcut card, with the measured numbers,
  quick start, how it works and the trade-offs.
- **Personal data removed** from the files: machine serial, display UUIDs, email addresses,
  absolute home paths, the owner's name, and notes about the workplace. `AGENTS.md` now forbids
  adding them back.
- `capture.sh` checks that both config symlinks point into the repo and that Ghostty is there.

## 2026-09-24, Delete and Shift+Delete in Finder

- In Finder, **Delete** (forward delete) moves the selection to the Trash and **Shift+Delete**
  deletes immediately behind Finder's own confirmation dialog, as on Ubuntu.
- Passes through while a text field has focus, so renaming and searching still work. Checked
  through the Accessibility role of the focused element.
- Verified on scratch files: Delete trashed the file, Delete while renaming left it alone,
  Shift+Delete showed the delete-immediately dialog (cancelled with Esc, nothing deleted).
- A first check for the dialog looked only for a sheet and missed it: Finder shows it as a
  separate `AXDialog` window.
- Shortcut card updated with both keys, still one A4 page.

## 2026-09-24, printable shortcut card

- `docs/shortcuts.html`: every custom shortcut on one A4 page, grouped as desktops and windows,
  text editing, screenshots, session and apps, plus what the remaps took away in terminals.
  Open it in a browser and print. Light and dark on screen, forced light when printed.
- Checked with headless Chrome: one page. A first version with a wider keys column spilled onto
  a second page and was tightened for print only.

## 2026-09-24, move and select by word with Ctrl

- **Ctrl+Left / Right** jump a word and **Ctrl+Shift+Left / Right** extend the selection by a
  word, in every app, sent as Option+Arrow and Option+Shift+Arrow. Uses the Ctrl+Arrow and
  Ctrl+Shift+Arrow combinations freed earlier the same day.
- Arrow keys always carry the fn flag, which the tap used to read as "different shortcut".
  Ignored for arrows only.
- Verified in TextEdit with and without the fn flag: `cuatro` and `tres` selected as expected.

## 2026-09-24, window move between desktops made fast

The owner reported a long pause between the shortcut and the window starting to move.

- Measured first: ~700 ms until the window changed desktop, ~980 ms until the view did, plus
  the time taken to release the keys, since the code waited for that.
- Now: Hammerspoon posts the mouse down and three 1 px drag events itself, fires the native
  shortcut through `spaceswitch` at once, and releases 60 ms after the view flips. No wait for
  the keys. **~356 to 410 ms to the view, 6 of 6 moves correct**, on Cursor and on Chrome.
- cliclick is no longer used at runtime. Still installed for manual debugging.
- Ruled out with evidence: the SkyLight compat-ID trick (`SLSSetWindowListWorkspace` returns
  1006, not implemented, on macOS 27), and noswoosh mid-drag (Dock ignores it).
- Slip during the change: a stray `end)` left by the edit made `init.lua` fail to parse, so for
  about two minutes Hammerspoon ran with no config and none of the shortcuts worked. Found by
  diffing, fixed, Hammerspoon restarted and every hotkey and tap confirmed live.

## 2026-09-24, window move moved to Ctrl+Cmd+Shift+Arrow

- Moving the focused window to the next desktop is now **Ctrl+Cmd+Shift+Left / Right**, so it
  matches Ctrl+Cmd+Left / Right for switching. Ctrl+Shift+Arrow is free again.
- No system symbolic hotkey uses that combination. `afterModifiersReleased` already waited for
  Cmd, so the injected drag is not contaminated by the extra modifier.

## 2026-09-24, desktop switch moved to Ctrl+Cmd+Arrow

- Symbolic hotkeys 79 and 81 rebound from Ctrl+Left / Right to **Ctrl+Cmd+Left / Right**, to
  free Ctrl+Arrow. Applied live with `activateSettings -u`, backup kept, written by `apply.sh`,
  checked by `capture.sh`.
- The window move's cliclick drag now presses Ctrl+Cmd. noswoosh needed no change.
- `helper/spaceswitch` stopped working with two modifiers until each event carried the
  accumulated flags, as a physical keyboard reports them. Recorded in `docs/macos-27-notes.md`.
- Verified from Hammerspoon: old Ctrl+Arrow no longer switches; spaceswitch, cliclick and
  noswoosh all switch; Ctrl+Shift+Arrow moved Cursor to desktop 1 and back to 2 with the view
  following.

## 2026-09-24, lock the session

- **Ctrl+Cmd+L** locks the session through `hs.caffeinate.lockScreen()`, which is
  `SACLockScreenImmediate`, the same call as the native Ctrl+Cmd+Q. Password asked for at once.
- Bound to Ctrl+Alt+L first. The owner tested it, it locked, and he preferred Ctrl+Cmd+L. No
  system symbolic hotkey uses that combination.
- Confirmed it is a lock and not a logout: Hammerspoon and Cursor kept the same process ids
  across his tests.

## 2026-09-23, Ctrl+A

- **Ctrl+A** selects all, in every app, posted as Cmd+A. Verified in TextEdit: three typed
  lines, then Ctrl+A and Cmd+C copied all three.
- Cost: Ctrl+A no longer jumps to the start of the line in the shell or in macOS text fields.

## 2026-09-23, Ctrl+Z and plain-text paste

- **Ctrl+Z** undoes, in every app, through the same post-to-the-app mechanism as Ctrl+C.
  Cost: in a terminal it no longer suspends the process.
- **Ctrl+Shift+V** pastes without formatting, in every app. macOS has no universal shortcut
  for this, so the pasteboard is reduced to plain text, pasted with Cmd+V, and restored with
  all its formats 0.4 s later unless something new was copied in between.
- Verified in TextEdit by reading back the font of what was pasted: Helvetica-Bold 30 on the
  clipboard, Helvetica 12 in the document after Ctrl+Shift+V, clipboard restored to
  Helvetica-Bold 30 afterwards, and Ctrl+Z removing the paste.

## 2026-09-23, later: screenshots save and copy, and the repo goes to GitHub

### The capture now does both, with sound

The owner asked for the shutter back and for the file to be kept as well as the clipboard copy.

`screencapture` cannot do both in one call: `-c` sends to the clipboard and ignores the file
path. So it captures to the file first and the file is then read back onto the pasteboard. That
order matters: the file is the original, the clipboard is the copy.

`-x` is gone, so the shutter plays. It is the confirmation the capture happened, which is what
is missing when the only result is invisible on the clipboard. `SCREENSHOT_SOUND = false`
restores silence.

Cancelling with Esc writes no file, and in that case the clipboard is left untouched rather
than being overwritten with the previous capture. The existence check retries twice at 100 ms,
because the file can land a moment after the process exits.

`init.lua` now reads `com.apple.screencapture location` instead of hardcoding the folder, so it
cannot drift from what `apply.sh` writes, and creates the folder if it is missing.

Verified end to end before handing it over: folder resolved from the system default, file
written, image loaded, pasteboard write returned true and the change count advanced.

### The repository is on GitHub

It was local only, which made "replicate this on another machine" untrue. Now pushed to
GitHub.

## 2026-09-23, screenshots

### The Print Screen key now crops to the clipboard

The key was assumed to be unbindable, since macOS has no concept of Print Screen. An event
sniffer showed otherwise: on its Mac layer the keyboard emits **Cmd+Shift+3**, the native
save-screen-to-file shortcut. An ordinary shortcut, so it can be intercepted like any other.

`hammerspoon/init.lua` consumes it and runs `screencapture -i -c -x`: crosshair crop, straight
to the clipboard, no shutter sound and no file. Each drag draws a new selection, which is what
The owner meant by not wanting to move a square around. That square belongs to Cmd+Shift+5, a
different tool, and neither it nor Ctrl+Cmd+Shift+4 was touched.

Verified with counts rather than impressions: four presses gave four interceptions, the
Desktop stayed at 34 files before and after, so macOS did not also fire its own screenshot,
and the clipboard held a PNG.

Reassigning symbolichotkey 31 onto Cmd+Shift+3 would have worked too, natively. Rejected as
much less reversible: this version is undone by deleting a block, while editing
symbolichotkeys is exactly what broke window moves once already through `noswoosh setup`.

### The detour worth remembering

For most of the session the key sent a bare `3`, keycode 20 with no modifiers, which would
have been unusable: binding it hijacks the digit. The plan had already become a firmware
remap to F13.

The cause was an **automated keyboard remap left over from an earlier agent's experiments**,
recorded nowhere. The owner removed it and the factory Cmd+Shift+3 came back, making the whole
F13 plan unnecessary. This is the exact failure mode the keyboard-layer documentation added
earlier the same day warns about, arriving within hours of being written down.

### Screenshots no longer land on the Desktop

`com.apple.screencapture location` now points at `~/Pictures/Screenshots`. Only affects the
shortcuts that save a file; the Print Screen path writes none.

`bin/apply.sh` creates the folder **before** setting the key, because `screencapture` does not
create a missing directory: it silently falls back to the Desktop, which is indistinguishable
from the setting being ignored.

`bin/capture.sh` now checks the location key, and reports whether the clipboard and screenshot
event taps are live. Both are event taps, not hotkeys, so neither showed in the hotkey count.

## 2026-09-23, the keyboard as a configuration layer

### The keyboard is now documented as a configuration layer

A programmable keyboard is a real option when implementing a request. Recorded in
`AGENTS.md` as an operating rule and in `docs/settings.md` as policy.

The rule of thumb: **"this key should send that key" belongs in firmware, "this key should do
something" belongs in Hammerspoon.** Firmware works before login, in Secure Input fields and
without the Accessibility permission; it cannot know which app is in front or run a script.

The combination is the strongest option and is exactly what the Print Screen key needs: the
keyboard emits a key macOS understands (an unused F13 to F19), Hammerspoon binds the behaviour.

Cost, now written down: a firmware remap is invisible to `bin/capture.sh` and to `defaults`,
so every remap has to be recorded in `personal/keyboard.md` or it is undiagnosable drift.

## 2026-09-23

- **Ctrl+C / Ctrl+V / Ctrl+X** now copy, paste and cut in every app. Mutating the event's flags
  does nothing and injecting replacement events loses to the Ctrl the user is still holding;
  posting the keystroke straight to the frontmost application is what works.
  Measured trade-off, accepted by the owner: in Terminal with `sleep 45` running, Ctrl+C no longer
  interrupts it.
- **Ctrl+Alt+Left / Right** move the focused window between monitors. The one thing this
  machine did without a workaround.
- Sweep duration settled at 114 ms after trying 260 and 600.
