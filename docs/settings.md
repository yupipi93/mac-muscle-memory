# Tracked settings

Every setting `bin/apply.sh` writes, with the reason. Values verified 2026-09-22.

## Input

| Domain | Key | Value | Why |
|--------|-----|-------|-----|
| NSGlobalDomain | `com.apple.swipescrolldirection` | `0` | Turns off macOS "natural scrolling" so the wheel behaves like Windows and Linux. Set by the user through System Settings before this repo existed. |

Note: this key is shared between mouse and trackpad. To give them opposite directions you need
a third-party tool such as Mos or LinearMouse.

## Spaces and Mission Control

| Domain | Key | Value | Why |
|--------|-----|-------|-----|
| com.apple.dock | `mru-spaces` | `false` | Stops macOS reordering desktops by most recent use. Without this, "left" and "right" are not stable and any positional navigation becomes unpredictable. |
| com.apple.dock | `workspaces-swoosh-animation-off` | `true` | **Does nothing.** The key no longer exists in the Dock binary on macOS 27. Kept only so nobody re-adds it thinking it was missed. |
| com.apple.dock | `workspaces-edge-delay` | `0.05` | Shortens the pause before the desktop flips when dragging a window to the screen edge. |
| com.apple.dock | `expose-animation-duration` | `0.001` | Speeds up Mission Control and Expose. Note it does **not** appear to affect the desktop switch itself, which is why lowering it changed nothing visible. |
| NSGlobalDomain | `NSWindowResizeTime` | `0.001` | Speeds up window resize animations. |

All of the `com.apple.dock` keys need `killall Dock` to take effect. None of them affects the
desktop switch animation, which was confirmed after a full logout and login.

## Accessibility

| Setting | Value | Why |
|---------|-------|-----|
| Reduce motion | on | Turns the desktop switch from a slide into an immediate crossfade. This is the strongest lever available for switch speed. |

This one **cannot be scripted**. `com.apple.universalaccess` is protected and
`defaults write` fails with `Could not write domain`. It lives in System Settings >
Accessibility > **Motion** on macOS 27. It used to be under Display, which is why it is easy
to miss. See `manual-steps.md`.

## Hammerspoon

Config source of truth: `hammerspoon/init.lua` in this repo, symlinked to
`~/.hammerspoon/init.lua` by `bin/apply.sh`.

Provides:

- **Scroll over the Dock to change desktop.** Wheel up goes to the previous desktop, wheel
  down to the next, matching the Ubuntu behaviour the user is used to. The event is consumed
  so macOS does not also fire its own App Expose.
- **Ctrl+Cmd+Shift+Left / Right** (Ctrl+Shift+Left / Right until 2026-09-24) move the focused
  window to the adjacent desktop and
  follow it.
- **Ctrl+Option+Left / Ctrl+Option+Right** move the focused window to the adjacent monitor.

Tunables at the top of the file:

| Constant | Default | Meaning |
|----------|---------|---------|
| `SCROLL_INVERT` | `false` | Flip if the scroll direction feels backwards |
| `SCROLL_COOLDOWN` | `0.28` | Minimum seconds between desktop changes. One wheel notch emits several events, so without this it would skip several desktops. |
| `DOCK_FALLBACK_STRIP` | `6` | Height in px of the hot zone when the Dock is set to auto-hide and therefore reserves no screen space |
| `HINT_ENABLED` | `true` | Draws a directional sweep on every desktop change. Set to `false` for a bare instant switch. |
| `HINT_DURATION` | `0.114` | Seconds the sweep takes. The number to tune. |
| `HINT_ALPHA` | `0.5` | How dark the sweep panel is, 0 to 1. Lower is subtler. |
| `HINT_FPS` | `60` | Frames per second of the sweep. |

Hammerspoon also needs `hs.autoLaunch(true)` so it starts at login, and the Accessibility
permission, without which none of this runs.

## Desktop switch speed

Handled by **noswoosh**, not by any setting. ~1165 ms down to ~130 ms. See
`docs/macos-27-notes.md` for the measurements, why every native key is dead, and the
`noswoosh setup` trap that breaks moving windows between desktops.

Installed to `~/Applications` by `bin/apply.sh`, checksum verified. Hammerspoon calls its CLI
and the child inherits the Accessibility grant.

## The directional sweep

Switching is now instant, which removed the one useful thing the native animation did: showing
which way you moved. `showSwitchHint` puts that back, as a panel that sweeps in the direction
the desktop content would have travelled, one canvas per display.

It is drawn by us, so its duration is whatever we want, unlike the native animation which
macOS 27 does not expose at all. It costs nothing measurable: the switch still medians 130 ms
with the sweep on.

The canvases are built once and reused, carry `canJoinAllSpaces` so the sweep is visible on
the desktop you arrive at rather than the one you left, and are torn down by a
`hs.screen.watcher` when displays change, since a cached canvas would no longer cover them.

## Hard constraints

**Spaces must span all displays.** `com.apple.spaces spans-displays` stays at `1`, and
"Displays have separate Spaces" stays off. The user requires every monitor to show the same
desktop. This closes off several otherwise attractive fixes, and that is accepted.

## The keyboard as a configuration layer

Not a `defaults` key, and not a fallback either. A programmable keyboard stores its own key map
in firmware, which makes it a real third place to implement a request, alongside `defaults` and
Hammerspoon. If yours is one, consider it every time.

Use the keyboard when the request is **"this key should send that key"**: it works before
login and in Secure Input fields, needs no Accessibility permission, and survives Hammerspoon
not running. Use Hammerspoon when the request is **"this key should do something"**, because
firmware cannot know which app is in front or run a script.

The strongest option is both at once. macOS has no concept of some keys, so Hammerspoon never
sees them. Remap the keyboard to send an unused F13 to F19 and bind that instead: the keyboard
supplies the key, Hammerspoon supplies the behaviour.

The cost is that a firmware remap is invisible to this repo. `bin/capture.sh` cannot read the
keyboard and `defaults` knows nothing about it, so record every remap in `personal/keyboard.md`
(see `personal.example/`) or it becomes undiagnosable drift.

## Moving a window between monitors

**Ctrl+Option+Left / Ctrl+Option+Right.** On a Windows keyboard in Mac mode, Option is the
Windows key, not Alt; Hammerspoon calls the modifier `alt`. Nothing to do with Spaces: this is plain geometry, so
`hs.window:moveToScreen` works and none of the broken APIs apply. It is the one thing on this
machine that needed no workaround.

Picks the neighbour with `screen:toWest()` / `toEast()`, so it follows the physical arrangement
and scales past two displays. It does not wrap. The window is rescaled proportionally, which is
what you want between panels of different resolution, and moved with duration 0. A window in
real fullscreen cannot be moved and says so.

Chosen over Cmd+Shift+arrow, which editors use for selecting to the start or end of a line.

## Copy, paste and cut with Ctrl

**Ctrl+C / Ctrl+V / Ctrl+X** work alongside the native Cmd equivalents, for Windows and Linux
muscle memory.

Two approaches failed first, both for reasons worth remembering:

1. Mutating the event with `event:setFlags({cmd = true})` and letting it through does nothing.
   The system still delivers the original Ctrl.
2. Consuming it and returning replacement `newKeyEvent` events also fails, and it is the same
   modifier contamination that broke the desktop shortcut: the user is **still physically
   holding Ctrl**, so it merges into the injected Cmd and the app sees Ctrl+Cmd+C.

What works is posting the keystroke **straight to the application**, which bypasses the global
modifier state:

```lua
hs.eventtap.keyStroke({ "cmd" }, key, 0, app)
```

### Undo, and paste without formatting

Added 2026-09-23:

| Shortcut | Does | How |
|----------|------|-----|
| **Ctrl+Z** | undo | Posted to the app as Cmd+Z, same mechanism as Ctrl+C. |
| **Ctrl+A** | select all | Posted as Cmd+A. Verified in TextEdit: three typed lines, Ctrl+A then Cmd+C copied all three. |
| **Ctrl+B** | bold | Posted as Cmd+B. Verified in TextEdit: selected text went from Helvetica to Helvetica-Bold. |
| **Ctrl+Shift+V** | paste as plain text | See below. Matches Ctrl+Shift+V in Linux terminals. |

**macOS has no universal plain-paste shortcut.** Chrome and native apps use Cmd+Alt+Shift+V,
Slack uses Cmd+Shift+V, and Cursor / VS Code have none. Rather than a per-app table that would
always be missing an app, `pastePlain` works the same everywhere:

1. Save the whole pasteboard, every type, with `hs.pasteboard.readAllData()`.
2. Replace it with only its plain-text string.
3. Send an ordinary Cmd+V to the app.
4. After 0.4 s, write the saved contents back, so the next Ctrl+V pastes with formatting again.

The delay exists because the app reads the pasteboard asynchronously after receiving Cmd+V;
restoring at once makes it paste the formatted version. The restore is skipped if the
pasteboard changed in the meantime (checked with `changeCount`), so something copied inside
that window is never overwritten. If the clipboard holds no text at all, an image or a file,
it falls back to a normal paste.

Verified in TextEdit with `NEGRITA` in Helvetica-Bold 30 on the clipboard:

| Step | Font read back |
|------|----------------|
| Clipboard before | Helvetica-Bold 30 |
| Pasted with Ctrl+Shift+V | **Helvetica 12**, the document default, so no formatting came across |
| Clipboard after the paste | Helvetica-Bold 30, restored |
| Pasted with plain Ctrl+V | Helvetica-Bold 30 |
| After Ctrl+Z | document empty, the paste was undone |

**Cost in terminals, same trade-off as Ctrl+C:** Ctrl+Z no longer suspends the running process
(SIGTSTP), it becomes undo. Ctrl+B is bold, so it no longer reaches tmux (its default prefix) or readline. Ctrl+A no longer jumps to the start of the line, neither in the
shell (readline) nor in macOS text fields, which also bind it that way; Cmd+Left or Home does
that now. The `CLIPBOARD_PASSTHROUGH_APPS` list restores it per app.

### Moving and selecting by word

Added 2026-09-24, Ubuntu and Windows style:

| Shortcut | Sent to the app as | Does |
|----------|--------------------|------|
| **Ctrl+Left / Right** | Option+Left / Right | jump a word |
| **Ctrl+Shift+Left / Right** | Option+Shift+Left / Right | extend the selection by a word |

Only possible because both combinations were freed the same day: Ctrl+Arrow no longer switches
desktops (now Ctrl+Cmd+Arrow) and Ctrl+Shift+Arrow no longer moves windows (now
Ctrl+Cmd+Shift+Arrow). Ctrl+Up / Down are untouched and still open Mission Control and App
Exposé.

**Arrow keys always carry the fn flag**, the keyboard marks them that way. The tap otherwise
treats fn as "a different shortcut, leave it alone", so for arrows fn is ignored; without that
exception a physical Ctrl+Left would never be remapped. Key repeat works: each auto-repeat is
its own keyDown and is remapped like the first.

Verified in TextEdit on `uno dos tres cuatro`, with the arrows posted both without and with
the fn flag, the way the physical keyboard sends them:

| From | Keys | Selected |
|------|------|----------|
| end of line | Ctrl+Shift+Left | `cuatro` |
| end of line | Ctrl+Left twice, then Ctrl+Shift+Right | `tres` |

Terminals get Option+Arrow, so word jumps there depend on the terminal translating Option+Arrow
into the shell's word motion. Not tested in Ghostty.

### It applies to every app, including terminals

`CLIPBOARD_PASSTHROUGH_APPS` is **empty**. the owner asked for no exceptions on 2026-09-23, after
being told the cost.

**That cost was measured, not assumed.** In Terminal.app with `sleep 45` running, Ctrl+C did
not interrupt it: the process survived. Ctrl+C is turned into copy before the shell ever sees
it, so the interrupt character never arrives.

Ways to stop a running command now:

- `Ctrl+\` sends SIGQUIT and is not remapped.
- Close the tab or window.
- `stty intr ^]` changes the interrupt character for that shell.
- Put the app back in the list, which restores normal behaviour there:

  ```lua
  local CLIPBOARD_PASSTHROUGH_APPS = { ["Terminal"] = true, ["iTerm2"] = true, ["Cursor"] = true }
  ```

VS Code family editors are affected the same way: their embedded terminal cannot be told apart
from the editor from outside the app.

## Screenshots

**The Print Screen key crops the screen and copies it to the clipboard.** Ctrl+Cmd+Shift+4
still does the same thing natively, and Cmd+Shift+5 still opens the full UI.

### What the key actually sends

macOS has no concept of a Print Screen key, so the first assumption was that it emitted
nothing bindable. It does: on its Mac layer the keyboard used here emits **Cmd+Shift+3**, the
native "save picture of screen as file" shortcut. Measured with an event sniffer: four
presses, four clean Cmd+Shift+3, no stray codes.

That is an ordinary shortcut, which is why it can be intercepted like any other.

Worth knowing, because it cost a detour: the key briefly sent a bare `3` (keycode 20, no
modifiers) after an automated remap left over from earlier keyboard experiments. A bare `3`
would have been unusable, since binding it would hijack the digit. the owner removed that remap
and the factory behaviour came back. **If this key ever stops working, sniff it again before
assuming the code is wrong.**

### What replaces it

`hammerspoon/init.lua` consumes Cmd+Shift+3 and captures to a file, then loads that file onto
the clipboard. **Both outputs, every time**, with the shutter sound.

```
screencapture -i "~/Pictures/Screenshots/Screenshot <date> at <time>.png"
```

| Flag | Effect | Why |
|------|--------|-----|
| `-i` | interactive crosshair | Every drag draws a fresh selection, so there is no square to move around. That square belongs to Cmd+Shift+5, a different tool. |
| no `-x` | the shutter plays | Requested on 2026-09-23. The sound is the confirmation the capture happened, which is exactly what is missing when the result is invisible because it went to the clipboard. |

**`screencapture` cannot do both at once.** `-c` sends to the clipboard and ignores the file
path, so it is one or the other. Hence two steps: capture to the file first, then read it back
with `hs.image.imageFromPath` and write it to the pasteboard. The file is the original and the
clipboard is the copy, which is the right way round if anything fails in between.

**Cancelling with Esc leaves the clipboard alone.** `screencapture` writes nothing when the
user cancels, so the code checks the file exists before touching the pasteboard. Overwriting
the clipboard with the previous capture would be worse than doing nothing.

The file can appear a fraction of a second after the process exits, so the check retries twice
at 100 ms before concluding the capture was cancelled.

The filename matches the macOS convention, so keyboard captures and native-shortcut captures
sort together in the folder.

`SCREENSHOT_SOUND = false` in `init.lua` puts `-x` back and silences it.

Returning `true` consumes the event so macOS does not also fire its own screenshot.
**Verified with counts, not impressions:** four presses produced four interceptions, the
Desktop stayed at 34 files before and after, and the clipboard held a PNG.

Hammerspoon needs the **Screen Recording** permission for this, granted 2026-09-23. Without
it `screencapture` returns a black or empty image rather than failing loudly.

### Why not reassign the system shortcut

Reassigning symbolichotkey 31 ("copy picture of selected area to clipboard") onto Cmd+Shift+3
would also have worked, without Hammerspoon. It was rejected because it is far less
reversible: the Hammerspoon version is undone by deleting a block, while editing
symbolichotkeys is exactly what broke moving windows between desktops once already, via
`noswoosh setup` and shortcuts 79 and 81. See `docs/macos-27-notes.md`.

### Where the files go

| Domain | Key | Value |
|--------|-----|-------|
| com.apple.screencapture | `location` | `~/Pictures/Screenshots` |

This is where the Print Screen key writes too, and where Cmd+Shift+4 and Cmd+Shift+5 save.

`init.lua` **reads this same key** rather than hardcoding the path, so the two cannot drift
apart. It is read once at load, so changing the folder needs a Hammerspoon reload. It also
creates the folder if it is missing, for the same reason `apply.sh` does.

`bin/apply.sh` **creates the folder before setting the key**. This matters: `screencapture`
does not create a missing directory, it silently falls back to the Desktop, which looks
exactly like the setting having been ignored. `killall SystemUIServer` picks up the change.

## Desktop switch shortcut: Ctrl+Cmd+Arrow

| Symbolic hotkey | Action | Default | Now |
|-----------------|--------|---------|-----|
| 79 | Move left a space | Ctrl+Left | **Ctrl+Cmd+Left** |
| 81 | Move right a space | Ctrl+Right | **Ctrl+Cmd+Right** |

Moved on 2026-09-24 so Ctrl+Arrow is free for other uses. Stored as parameters
`[65535, 123 or 124, 9699328]`, where 9699328 is ctrl | cmd | the fn-key bit the system keeps on
arrow shortcuts. `bin/apply.sh` writes it and runs `activateSettings -u`, so it takes effect
without logging out. `bin/capture.sh` flags drift. Backup of the previous state:
`~/Library/Preferences/com.apple.symbolichotkeys.bak-2026-09-24.plist`.

**Everything that injects the shortcut had to change with it**, and must keep changing together:

- `hammerspoon/init.lua`, the window move (now Ctrl+Cmd+Shift+Arrow): drags the title bar and
  fires the shortcut through `helper/spaceswitch`. That move depends on the **native** shortcut
  firing mid-drag, which is why the binding lives in symbolic hotkeys and not in Hammerspoon.
- `helper/spaceswitch`, the fallback switcher: now presses Control and Command, and needed the
  accumulated flags to work, see `docs/macos-27-notes.md`.
- noswoosh, the primary switcher, needed nothing: it switches with a synthetic gesture.

Still bound to Ctrl+Arrow by the system: **Ctrl+Up** (Mission Control) and **Ctrl+Down**
(App Exposé), symbolic hotkeys 32 to 35. Not moved, since only desktop switching was asked for.

Possible conflict: some apps use Ctrl+Cmd+Left / Right themselves, for example VS Code family
editors for moving an editor between groups. The system shortcut wins, so those app bindings no
longer fire.

## Select to copy, middle-click to paste

The X11 primary selection that Ubuntu users rely on, added 2026-09-24. Selecting text copies it
to a **second clipboard**; the middle mouse button pastes it. Ctrl+C / Ctrl+V and the normal
clipboard are never affected.

**Capture.** After a drag, a double or triple click, or a Shift+click, `init.lua` reads the
selection:

1. Through Accessibility (`AXSelectedText` of the focused element), which touches nothing.
2. If the app does not expose it (Chrome and Electron apps report no focused element at all,
   terminals expose no selection), it sends Cmd+C and restores the clipboard straight after,
   every type, from `hs.pasteboard.readAllData()`.

It only tries when the focused element holds text, or when the app exposes no accessibility at
all. Finder is excluded outright: dragging there selects files.

**Paste.** Only where there is something editable under the pointer, as Ubuntu does: a text
field, a text area, a web editor with an editable ancestor, or an app in
`PRIMARY_PASTE_ANYWHERE_APPS` (Ghostty by default). The caret is first moved to the pointer with
a click, then the text is pasted with the same clipboard-preserving swap as Ctrl+Shift+V.
Anywhere else the middle click passes through untouched: opening a link in a new tab or closing
a tab keep working.

**Cursor shape, for apps that expose nothing.** When Accessibility cannot say what is under the
pointer, `helper/cursorkind` asks macOS which cursor is showing: the text I-beam means paste, a
pointing hand (a link) or the arrow (a tab) means let the middle click through. It is a second
signal, only consulted when Accessibility has nothing, so it can only add paste targets.
Synthetic pointer moves did not change the reported cursor in testing, so this path still needs
confirming with a real mouse.

**Screenshots.** The crop drag of the Print Screen key looks exactly like a text selection. The
copy-and-restore capture used to fire on it and restore the old clipboard over the screenshot
that had just been copied. Capture now stands down while a screenshot is in progress
(`screenshotInProgress`), and never runs inside the screenshot UI.

**Diagnosing.** A short log of every capture and middle click, with the decision and the reason:

```bash
hs -c 'return table.concat(dockScroll.primaryLog(), "\n")'
```

**Limitation, measured.** Chrome and Electron apps such as Cursor expose nothing under the
pointer (only a generic scroll area, even with `AXManualAccessibility` set), so there is no way
to tell a text field from a link or a tab. Selecting in them **does** capture; middle-click
pasting into them is **off** by default so links and tabs keep their middle-click behaviour. Add
an app's bundle id to `PRIMARY_PASTE_ANYWHERE_APPS` to paste there regardless.

Verified:

| Where | Action | Result |
|-------|--------|--------|
| TextEdit, `alfa beta gamma`, clipboard holding `NORMAL` | double-click `beta` | second clipboard `beta`, clipboard still `NORMAL` |
| same | drag across `gamma` | second clipboard `gamma`, clipboard still `NORMAL` |
| same | middle-click after the text | document `alfa beta gammabeta`, clipboard still `NORMAL` |
| Chrome, a web page | double-click a word | captured through the copy-and-restore path, clipboard restored |

`PRIMARY_ENABLED = false` in `init.lua` turns it off.

## Next window of the same app: Option+Tab

| Symbolic hotkey | Action | Default | Now |
|-----------------|--------|---------|-----|
| 27 | Move focus to next window (of the frontmost app) | Cmd+` | **Option+Tab**, add Shift to go back |

Native macOS behaviour, only rebound, like Alt+` on GNOME: with three Chrome windows open,
Option+Tab walked through all three and Option+Shift+Tab stepped back. Stored as
`[65535, 48, 524288]` (Tab, Option). Written by `bin/apply.sh` next to 79 and 81, applied live with
`activateSettings -u`, checked by `bin/capture.sh`.

Moving it off Cmd+` also leaves that combination to Ghostty's Quick Terminal, which binds it
globally. Nothing in the system used Option+Tab before.

## Moving a window between desktops, fast

Ctrl+Cmd+Shift+Left / Right. Rewritten on 2026-09-24 because it took too long to start.

| | Before | After |
|--|--------|-------|
| Wait for the user to release Ctrl+Cmd+Shift | yes, human release time on top | **no** |
| Drag and shortcut | cliclick with fixed waits (100 ms + 300 ms + its own overhead) | Hammerspoon mouse events + `helper/spaceswitch` |
| Release the drag | after a fixed wait | as soon as the view has flipped, plus 60 ms |
| Measured, to the view flipping | ~980 ms, window moved at ~700 ms | **~356 to 410 ms**, 6 of 6 moved, Cursor and Chrome |

How it works now, in `moveFocusedWindowToSpace`:

1. Mouse down on the title bar at 85% of the width, then **three 1 px drag events**. Without
   the drag events macOS does not treat the window as grabbed: the desktop switches and the
   window stays behind. Measured both ways.
2. Fire the native Ctrl+Cmd+Arrow through `spaceswitch`, straight away.
3. Poll the active space every 5 ms and release 60 ms after it flips. A 3 s timeout releases
   anyway so a failed switch never leaves the mouse held down.

A busy flag ignores a second press while a move is in flight.

**Why not wait for the modifiers any more.** The old code waited because the keys still held
by the user merged into the injected shortcut and broke it. `spaceswitch` now sets explicit
flags on every event, and with Ctrl+Cmd+Shift held down during a move the switch still fired.

**What was tried and ruled out**, so nobody retries it:

- Moving the window directly with the SkyLight compat-ID trick (`SLSSpaceSetCompatID` +
  `SLSSetWindowListWorkspace`), which works on macOS 15 without disabling SIP. On macOS 27
  `SLSSetWindowListWorkspace` returns `1006`, not implemented. Dead.
- Switching with noswoosh during the drag, which would have cut the switch to ~130 ms. Dock
  ignores the gesture while a drag is in progress. Tried with cliclick earlier and without it
  now: no switch either time.

The remaining ~350 ms is the native switch itself, which the drag forces us to use.

## Deleting files in Finder, Ubuntu style

| Key | In Finder | Sent as |
|-----|-----------|---------|
| **Delete** (forward delete, keycode 117) | move the selection to the Trash | Cmd+Backspace |
| **Shift+Delete** | delete immediately, skipping the Trash | Option+Cmd+Backspace |

Added 2026-09-24. Only when Finder is the frontmost app, and **never while typing**: if the
focused element is a text field (renaming a file, the search box), the key passes through and
deletes the character to the right as usual. That is decided by asking Accessibility for the
focused element's role (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`).

Shift+Delete keeps Finder's own confirmation, the same safety net Ubuntu gives: *"Are you sure
you want to delete ...? This item will be deleted immediately. You can't undo this action."*,
with Cancel and Delete.

Forward delete carries the fn flag like the arrows, so fn does not disqualify it.

Verified in Finder on scratch files:

| Test | Result |
|------|--------|
| Delete on a selected file | file left the folder and appeared in `~/.Trash` |
| Delete while renaming (focus `AXTextField`) | file still in place, not trashed |
| Shift+Delete | Finder's delete-immediately dialog appeared; cancelled with Esc, file still in place |

The permanent deletion itself was not executed in the test, on purpose; the dialog is Finder's
own and pressing Delete there is ordinary Finder behaviour. The shortcut glyphs were read from
Finder's File menu: "Move to Trash" is Cmd+Delete, "Delete Immediately..." is Option+Cmd+Delete.

`FINDER_DELETE_ENABLED = false` in `init.lua` turns it off.

## Locking the session

**Ctrl+Cmd+L** locks the session, the equivalent of Win+L on Windows and Ctrl+Alt+L on Ubuntu.
The native macOS shortcut is **Ctrl+Cmd+Q**, and it still works.

It is a real lock, not a logout: `hs.caffeinate.lockScreen()` calls `SACLockScreenImmediate`
from the private login framework, the same call as Ctrl+Cmd+Q. Apps and the session stay open.
The password is asked for at once, because `sysadminctl -screenLock status` reports
`screenLock delay is immediate`.

Chosen after trying Ctrl+Alt+L first. That worked, and the owner preferred Ctrl+Cmd+L. No system
symbolic hotkey uses Ctrl+Cmd+L, checked in `com.apple.symbolichotkeys` before binding it.

The macOS lock screen looks almost the same as the login window, user picture and password
field. That makes a lock easy to mistake for a logout. The way to tell: after unlocking, the
apps are still running with the same process ids.

## Settings deliberately not applied

| Setting | Why not |
|---------|---------|
| `com.apple.spaces spans-displays = false` | **Permanently ruled out by the user**, see Hard constraints above. |
| `firenze-animation-time`, `xfade-duration`, `workspaces-auto-swoosh` | Real keys in the Dock binary, each tested with a Dock restart and timed trials. None affects the desktop switch. |
| `NSWindowShouldDragOnGesture` | Tested and reverted. Only applies to apps launched afterwards, so it did not solve the maximised window problem. |
| Passwordless `sudo` | Rejected as a standing security hole. Commands needing root are handed to the user instead. |
