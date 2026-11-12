# Open items

Unfinished or unverified work. Update the status when you touch one of these.

## 1. Desktop switch animation ✅ RESOLVED 2026-09-22

From ~1165 ms to ~130 ms, about 9x, using noswoosh as a CLI driven by Hammerspoon. Native
Spaces kept, still spanning all three displays. Full detail in `docs/macos-27-notes.md`.

Every native `defaults` route was tested and is dead, including keys found by grepping the
Dock binary. Do not reopen that line of investigation; the evidence is in the notes.

## 2. Per display Spaces ❌ CLOSED, will not do

`com.apple.spaces spans-displays = false` would fix the broken `hs.spaces` APIs and probably
shorten the transition, but **the user has ruled it out permanently**: every monitor must show
the same desktop. This is a hard product requirement, not a preference to revisit.

Do not propose it again, and do not accept a solution that depends on it.

## 2b. The physical Space shortcut is still slow

**Status:** open, accepted for now.

The fast path only covers the scroll gesture over the Dock and the Hammerspoon hotkeys, which
call `noswoosh` directly. Pressing the native shortcut on the keyboard (Ctrl+Cmd+Arrow since
2026-09-24, Ctrl+Arrow before) still goes through the native
~1165 ms animation.

noswoosh solves this with a daemon, but its `setup` step disables system shortcuts 79 and 81,
and moving a window between desktops depends on those firing during a drag. Verified: with
`setup` applied, the window move breaks. So the daemon is deliberately not installed.

**Next action if this becomes annoying:** rewrite `moveFocusedWindowToSpace` so it does not
need the native shortcut, then install the daemon. Calling noswoosh in the middle of a drag
does not switch at all, confirmed twice (with cliclick, then with Hammerspoon's own mouse
events on 2026-09-24), and moving the window directly with SkyLight returns "not implemented"
on macOS 27. Another angle is dragging the window to the screen edge, which flips the desktop
natively via `workspaces-edge-delay`.

## 3. Title bar grab point ✅ RESOLVED 2026-10-01

The fixed 85% point failed in Notes (search field) and Finder (Share button). `grabPoint` now
reads the title bar through Accessibility and moves off 85% only when a control is there.
Detail in `docs/macos-27-notes.md`, "Where to grab".

**If another app fails:** an app whose title bar controls are not exposed to Accessibility
(some Electron or custom-drawn apps) still gets the blind 85%. Probe it the same way and record
it here. A verify-and-retry loop stays rejected: a failed retry inside a tab strip is
destructive.

Machine-specific items (this keyboard, this desktop layout) live in `personal/open-items.md`,
which git ignores.
