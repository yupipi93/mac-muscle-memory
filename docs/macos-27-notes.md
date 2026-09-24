# macOS 27 findings

Everything here was verified empirically on this machine (macOS 27.0, build 26A428) on
2026-09-22. Read it before automating anything that touches windows, Spaces or input.

## Spaces APIs in Hammerspoon

| Call | Works? | Detail |
|------|--------|--------|
| `hs.spaces.spacesForScreen()` | yes | returns the real space ids |
| `hs.spaces.activeSpaceOnScreen()` | yes | accurate, reads are trustworthy |
| `hs.spaces.focusedSpace()` | yes | accurate |
| `hs.spaces.windowSpaces(win)` | yes | accurate, use it to verify a move |
| `hs.spaces.watcher` | yes | reliable probe for "did the space actually change" |
| `hs.spaces.gotoSpace(id)` | **no** | returns `nil, "no display with specified id found"` |
| `hs.spaces.moveWindowToSpace(win, id)` | **no** | returns `true` and does nothing. It lies. |
| `hs.spaces.missionControlSpaceNames()` | **no** | returns `nil` |

### Why gotoSpace fails

`com.apple.spaces spans-displays = 1` ("Displays have separate Spaces" is off). In that mode
the Dock writes the monitor into `~/Library/Preferences/com.apple.spaces.plist` with
`Display Identifier = "Main"` instead of the display UUID. Hammerspoon looks the display up by
UUID, finds nothing, and errors.

Untested hypothesis: setting `spans-displays = false` and logging out might make both
`gotoSpace` and `moveWindowToSpace` work natively, which would remove the cliclick dependency
entirely. It requires a logout and changes multi-display behaviour, so it was not attempted.
Tracked in `OPEN-ITEMS.md`.

### Reading the plist

That plist also accumulates stale `Collapsed Space` entries for displays that are no longer
connected. Counting `uuid` occurrences overcounts desktops badly (10 entries for 2 real
desktops). Only `SpacesDisplayConfiguration > Management Data > Monitors > 0 > Spaces` is the
live list.

## Why injected Ctrl+Arrow does nothing, and what actually works

> **Since 2026-09-24 the native shortcut is Ctrl+Cmd+Arrow, not Ctrl+Arrow.** Symbolic hotkeys
> 79 and 81 were rebound to free Ctrl+Arrow. This section keeps the original wording because it
> records how the mechanism was found; read "Ctrl+Arrow" below as "the Space shortcut". Every
> injector now sends Ctrl+Cmd. See the section on two modifiers further down.

This is the single most important finding, and the obvious explanation is wrong.

`hs.eventtap.keyStroke({"ctrl"}, "left")` **is emitted**, an eventtap catches it, and the
arrow arrives carrying `ctrl = true`. macOS still does not switch Space.

It is **not** an injection level problem. The first theory here was that WindowServer listens
at the HID tap while `hs.eventtap` posts at the session tap. That is wrong, and reading
cliclick's source proves it: cliclick posts to `kCGSessionEventTap`, with a `NULL` event
source, and never sets a single flag.

The real cause: **the Control flag on the arrow event is not enough. Control has to be pressed
as a real key.** WindowServer derives the modifier from the actual key event stream, not from
the flags an injected event claims to carry.

The working sequence, which is exactly what cliclick does:

```c
CGEventPost(kCGSessionEventTap, CGEventCreateKeyboardEvent(NULL, 59,    true));  // Control down
usleep(12000);                                                                   // must settle
CGEventPost(kCGSessionEventTap, CGEventCreateKeyboardEvent(NULL, arrow, true));  // no flags
CGEventPost(kCGSessionEventTap, CGEventCreateKeyboardEvent(NULL, arrow, false));
usleep(12000);
CGEventPost(kCGSessionEventTap, CGEventCreateKeyboardEvent(NULL, 59,    false)); // Control up
```

Details that matter:

- No flags on any event. Setting `kCGEventFlagMaskControl` is neither needed nor sufficient.
- `NULL` event source. `kCGEventSourceStateHIDSystemState` and `kCGEventSourceStatePrivate`
  both fail.
- Control must be a plain keyDown, **not** a `kCGEventFlagsChanged` event. The correct-looking
  choice is the broken one here.
- The gap after the Control keyDown is load bearing. Measured: 0, 1 and 4 ms fail every time,
  8 ms succeeds about two thirds of the time, 12 ms and above succeed consistently. The config
  uses 20 ms for margin.
- The process must be spawned **by Hammerspoon**, not from a shell, so it inherits the
  Accessibility grant. Verified: `AXIsProcessTrusted()` returns 1 in the child, so TCC
  responsibility really is inherited.

This is implemented in `helper/spaceswitch.c`, built by `bin/apply.sh`. It replaced cliclick
on this path purely for speed, see the latency section below.

## Modifier contamination

When a hotkey like Ctrl+Shift+Left fires, the user is still physically holding Ctrl and Shift.
(The window move is Ctrl+Cmd+Shift+Arrow since 2026-09-24; the same wait applies, and
`afterModifiersReleased` already waits for Cmd too.)
Any keystroke injected at that moment arrives with those modifiers merged in, so an injected
Ctrl+Left becomes Ctrl+Shift+Left and WindowServer ignores it.

Fix: wait for the modifiers to be released before injecting.

```lua
hs.timer.waitUntil(function()
    local m = hs.eventtap.checkKeyboardModifiers()
    return not (m.ctrl or m.shift or m.cmd or m.alt)
end, fn, 0.02)
```

Visible consequence: the action happens a fraction of a second after the keys are released,
not while they are held. This is expected, not a bug.

## Moving a window between Spaces

`hs.spaces.moveWindowToSpace` does not work, so the only reliable method is to reproduce the
manual gesture: grab the window by its title bar, then press Ctrl+Arrow while it is still
held. The window travels with the drag.

```
m:X,Y  dd:X,Y  w:100  kd:ctrl kp:arrow-left ku:ctrl  w:300  du:X,Y
```

### Where to grab

Do **not** grab the horizontal centre of the title bar. On a maximised window the centre lands
on app UI and the click opens it instead of dragging:

- Cursor and VS Code: the command centre search box sits dead centre
- Chrome: the tab strip spans the full width, and dragging there tears a tab out into a new
  window, which is destructive

This is why the bug only showed up on maximised windows. On a small window the centre falls
past that UI into empty draggable title bar.

Current choice: **85% of the window width**, 10 px below the top. Verified working on Cursor
maximised at 2560 px. It is a heuristic, not a guarantee. If it fails on a specific app, that
app has a control in that region and the point needs revisiting.

### True fullscreen

A window in real fullscreen (green button, menu bar hidden) already owns its own Space and has
no title bar to grab. It cannot be moved. The config detects `win:isFullScreen()` and shows an
alert instead of failing silently. This is a macOS design constraint, not a limitation of the
script.

## TCC permission boundaries

Permissions that cannot be granted programmatically. Any attempt is a dead end:

| Permission | State | Consequence |
|-----------|-------|-------------|
| Hammerspoon Accessibility | granted | required for everything here |
| Terminal / Cursor Accessibility | not granted | `cliclick` from the shell does nothing |
| Screen Recording | not granted | `screencapture` fails with `could not create image from rect`, so screenshots cannot be used to verify state |
| Automation (System Events) | not granted | `osascript` calls hang and time out with `-1712` |
| Full Disk Access | not granted | `defaults write com.apple.universalaccess` fails with `Could not write domain`, so Reduce Motion must be toggled by hand |

## Useful probes

Since screenshots are unavailable, verify state this way:

```bash
hs -c 'hs.spaces.focusedSpace()'                              # current space
hs -c 'local w=hs.window.focusedWindow(); return hs.inspect(hs.spaces.windowSpaces(w))'
hs -c 'hs.eventtap.isSecureInputEnabled()'                     # blocks synthetic input if true
```

A `hs.spaces.watcher` counter is the most trustworthy "did the Space actually change" probe.

## Gotchas that cost time

- `hs -c "hs.reload()"` can hang the IPC call. Budget a timeout around it.
- `timeout` is not installed on macOS. Use the calling tool's own timeout.
- The shell is **zsh**: `set -- $var` does not word split. Use `${=var}` or an explicit array.
- `hs.window.allWindows()` only returns windows on the current Space, so a window you are
  looking for may simply be on another desktop.
- Finder's desktop appears in `hs.window.visibleWindows()` as a window spanning every display
  (here 4480 px wide). It is not movable. Filter by `w:isStandard()` and `w:subrole()`.
- `NSWindowShouldDragOnGesture` (Ctrl+Cmd drag a window from anywhere) is read by AppKit at
  app launch, so enabling it has no effect on already running apps. It was tested and reverted.

## The desktop switch animation: solved with noswoosh

**Result: ~1165 ms to ~130 ms, about 9x faster.** Native Spaces are kept, and Spaces still
span all three displays, which is a hard requirement here.

### Measured

`bin/measure-switch.sh` takes the numbers. It uses `hs.spaces.watcher` because that is the
only trustworthy signal that a Space really changed.

| Configuration | Median |
|---|---|
| Native Ctrl+Arrow, the baseline | 1165 ms |
| **noswoosh, what is used now** | **~130 ms** |
| Full gesture, wheel over the Dock to switched | ~125 to 175 ms |

### Every native setting is dead, with evidence

Do not spend time on `defaults` keys. `workspaces-swoosh-animation-off` **does not exist in
the Dock binary at all** on this build:

```bash
strings -a /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -i swoosh
# only prints: workspaces-auto-swoosh
```

Keys that do exist in the binary were tested individually, each with a Dock restart and three
timed trials. All within noise of the 1165 ms baseline:

| Key | Value tested | Median |
|---|---|---|
| `firenze-animation-time` | 0.2 | 1216 ms |
| `xfade-duration` | 0.2 | 1177 ms |
| `workspaces-auto-swoosh` | false | 1147 ms |

Previously tested and equally ineffective: `expose-animation-duration` at 0.2, 0.05 and 0.001,
`workspaces-edge-delay`, and Accessibility Reduce motion. The duration-bearing private API
`CGSSetWorkspaceWithTransition` no longer exists either.

The Dock does carry a dedicated Swift class for this exact setup,
`SpaceTransitionEnterExitToDifferentSpaceSpacesSpanDisplays`, so spanning displays really is a
separate and heavier code path. There is no preference that shortens it.

### How noswoosh is wired here, and the trap

Installed to **`~/Applications`**, not `/Applications`. The Homebrew cask needs `sudo` to write
to `/Applications` and an agent cannot answer a password prompt. Download is checksum verified
in `bin/apply.sh`; the app is notarised, Developer ID `RZ3SBD89YD`.

Hammerspoon calls the CLI directly, `noswoosh left|right`, and the child **inherits
Hammerspoon's Accessibility grant**. Run the same command from a shell and it silently does
nothing, exactly like cliclick.

**Do not run `noswoosh setup`, and do not install its LaunchAgent.** `setup` disables the
system Ctrl+Arrow shortcuts, symbolic hotkeys 79 and 81, so the daemon can own them. That
breaks moving a window between desktops, which works by holding the window in a drag while the
**native** Ctrl+Arrow fires. Verified: with `setup` applied, the window stays put.

If those shortcuts ever end up disabled, the fix is one command:

```bash
~/Applications/noswoosh.app/Contents/MacOS/noswoosh teardown
```

The cost of skipping the daemon: pressing Ctrl+Arrow **physically** still gets the slow native
animation. Only the scroll gesture and the Hammerspoon hotkeys are fast. Making both fast
would need the window move rewritten to not depend on the native shortcut; an attempt to drive
it by calling noswoosh mid-drag did not switch at all.

### noswoosh has no animation option

Checked directly: it has no preferences domain (`defaults read ax.max.noswoosh` finds nothing)
and no animation, duration or speed strings in its binary. It is instant or nothing. A
configurable fast animation therefore has to be drawn by us, which is what `showSwitchHint` in
`init.lua` does.

### Alternatives considered

| Option | Why not |
|---|---|
| Per display Spaces (`spans-displays = false`) | **Ruled out permanently by the user.** All monitors must show the same desktop. |
| Drop the monitor to 60 Hz | The animation scales with refresh rate, so this roughly halves it. Far worse than 9x and sacrifices the 144 Hz panel. |
| `instantspaces` dylib injection | Allows an arbitrary duration, but requires SIP disabled. Not acceptable here: SIP stays enabled. |
| AeroSpace, FlashSpace | Replace native Spaces with their own virtual workspaces. Loses native fullscreen behaviour. |

## Gotchas found while measuring

- **`hs` blocks on stdin.** `hs -c '...'` inside a script hangs until it is killed unless you
  redirect `</dev/null`. It looks exactly like an IPC hang and it is not.
- **`hs.task` gets garbage collected.** `hs.task.new(...):start()` without keeping a reference
  works sometimes and silently does nothing other times. This caused intermittent failures
  that looked like the switch itself being unreliable. Keep the task in a table until its
  callback fires, which is what `runTask` in `init.lua` does.
- **Check the screen is not locked before concluding anything is broken.** With the screen
  locked, every switcher fails simultaneously: noswoosh, cliclick and the helper. It looks
  exactly like a systemic failure and costs real time to chase. The tell:

  ```bash
  ioreg -l -w 0 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*'
  hs -c 'hs.eventtap.isSecureInputEnabled()'   # the lock screen holds Secure Input
  ```

  `bin/measure-switch.sh` now refuses to run in that state.
- Measure with `hs.spaces.watcher`, never with a fixed sleep, and always pick a direction that
  has somewhere to go or hitting the last desktop scores as a failure.

## Injecting a shortcut with two modifiers needs the flags too

Found when the Space shortcut moved to Ctrl+Cmd+Arrow on 2026-09-24.

With Control alone, `helper/spaceswitch` posted real key events with **no flags** and the system
derived the modifier from the Control key event. That rule does not carry over to two
modifiers. Posting Control down, Command down, the arrow, then the ups, all without flags,
**did not switch**, while `cliclick kd:ctrl,cmd kp:arrow-left ku:ctrl,cmd` did.

What works is what a physical keyboard reports: real modifier key events **and** the
accumulated flags on every event. Control down carries ctrl, Command down carries ctrl|cmd, the
arrow carries ctrl|cmd plus the secondary-fn and numeric-pad bits (the same bits the system
stores on arrow shortcuts, mask `0x800000`), and the ups step the flags back down.

Measured from Hammerspoon after the rebind:

| Injector | Result |
|----------|--------|
| cliclick, old Ctrl+Arrow | no switch, as intended |
| spaceswitch, Ctrl+Cmd without flags | **no switch** |
| spaceswitch, Ctrl+Cmd with accumulated flags | switches, both directions |
| cliclick `kd:ctrl,cmd` | switches |
| noswoosh | switches, it uses a synthetic gesture and never reads the binding |
| Ctrl+Shift+Arrow window move (drag + Ctrl+Cmd+Arrow) | window and view moved and came back |

The earlier conclusion, that a ctrl flag on the arrow without a real Control event fails, still
stands. The flags are needed in addition to the real key events, not instead of them.

## Moving a window between Spaces: what is left on macOS 27

Tested on 2026-09-24 while cutting the window-move latency.

| Approach | Result |
|----------|--------|
| `hs.spaces.moveWindowToSpace` | returns success, does nothing (known since day one) |
| SkyLight compat-ID trick: `SLSSpaceSetCompatID`, then `SLSSetWindowListWorkspace` | `SLSSetWindowListWorkspace` returns **1006, not implemented**. The trick that works on macOS 15 without SIP changes is gone |
| noswoosh gesture while the title bar is held | Dock ignores the gesture during a drag, no switch |
| Mouse down alone, then the native shortcut | the desktop switches, **the window stays behind** |
| Mouse down + three 1 px `leftMouseDragged` events, then the native shortcut | window travels, ~356 to 410 ms to the view flip |

Two findings worth keeping. A window is only "grabbed" once the system has seen drag events,
a bare mouse down is not enough. And injected shortcuts that carry explicit accumulated
flags are **not** contaminated by modifiers the user is still holding, so the old wait for
the user to release the keys is unnecessary.

