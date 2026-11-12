# Manual steps

macOS requires a human click for all of these. No agent can do them, and none should claim to.
Work through them in order when setting up a machine.

## 1. Grant Hammerspoon the Accessibility permission

**Nothing else in this repository works until this is done.**

System Settings > Privacy & Security > Accessibility > enable **Hammerspoon**.

Verify:

```bash
hs -c "hs.accessibilityState()"     # must print true
```

## 2. Turn on Reduce motion

System Settings > Accessibility > **Motion** > Reduce motion.

On macOS 27 this moved out of the Display pane, so it is easy to conclude it no longer exists.
If you cannot find it, use the search box at the top left of System Settings.

Verify:

```bash
defaults read com.apple.universalaccess reduceMotion    # must print 1
```

This cannot be scripted: the domain is protected and `defaults write` fails with
`Could not write domain com.apple.universalaccess`.

## 3. Create the desktops

The scroll gesture is useless with a single desktop. Press F3 for Mission Control and use the
`+` button at the top right to add as many as you want.

Desktops cannot be created programmatically here, because that path goes through the same
broken `hs.spaces` API.

Verify:

```bash
hs -c "#hs.spaces.spacesForScreen(hs.screen.mainScreen())"
```

## 4. Restart the session

`workspaces-swoosh-animation-off` appears to be read once when the login session starts.
`killall Dock` is not enough. Log out and back in, or reboot, then confirm the desktop switch
animation is actually shorter.

## Optional, only if needed

### Grant the terminal Accessibility

Only needed to run `cliclick` directly from a shell. The Hammerspoon config does not need it,
because Hammerspoon spawns `cliclick` itself and it inherits the grant.

### Grant Screen Recording

Only needed if you want `screencapture` to work, for example to verify visual state. Without
it, `screencapture` fails with `could not create image from rect`.
