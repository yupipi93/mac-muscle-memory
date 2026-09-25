#!/usr/bin/env bash
# Prints the current value of every tracked setting against what this repo expects.
# Read-only. Use it to spot drift, or to survey a machine before applying anything.
set -uo pipefail

pass=0
fail=0

# Hammerspoon's IPC occasionally blocks, so every query is capped. macOS ships no timeout(1).
hsq() { perl -e 'alarm 5; exec @ARGV' hs -c "$1" 2>/dev/null | tail -1 || echo '<timeout>'; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check() {
    local domain="$1" key="$2" expected="$3"
    local actual
    actual="$(defaults read "$domain" "$key" 2>/dev/null || echo '<unset>')"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-46s %s\n' "$domain $key" "$actual"
        pass=$((pass + 1))
    else
        printf '  DRIFT %-46s %s (expected %s)\n' "$domain $key" "$actual" "$expected"
        fail=$((fail + 1))
    fi
}

printf '\n\033[1mTracked defaults\033[0m\n'
check NSGlobalDomain com.apple.swipescrolldirection 0
check NSGlobalDomain NSWindowResizeTime 0.001
check com.apple.dock mru-spaces 0
check com.apple.dock workspaces-swoosh-animation-off 1
check com.apple.dock workspaces-edge-delay 0.05
check com.apple.dock expose-animation-duration 0.001
check com.apple.screencapture location "$HOME/Pictures/Screenshots"

# Symbolic hotkeys 79/81 (move a desktop left/right) must be Ctrl+Cmd+Arrow.
spacekeys="$(python3 -c '
import plistlib, subprocess
d = plistlib.loads(subprocess.run(["defaults","export","com.apple.symbolichotkeys","-"],capture_output=True).stdout).get("AppleSymbolicHotKeys", {})
p = lambda k: [int(x) for x in (d.get(k, {}).get("value", {}).get("parameters") or [0, 0, 0])]
ok = all(p(k)[2] == 9699328 for k in ("79", "81")) and p("27")[1:] == [48, 524288]
print("ctrl+cmd" if ok else "NOT ctrl+cmd")
' 2>/dev/null)"
if [ "$spacekeys" = "ctrl+cmd" ]; then
    printf '  ok    %-46s %s\n' "system shortcuts (79/81/27)" "Ctrl+Cmd+Arrow, Option+Tab"
    pass=$((pass + 1))
else
    printf '  DRIFT %-46s %s (expected Ctrl+Cmd+Arrow)\n' "system shortcuts (79/81/27)" "$spacekeys"
    fail=$((fail + 1))
fi

printf '\n\033[1mManual settings\033[0m\n'
check com.apple.universalaccess reduceMotion 1

printf '\n\033[1mTooling\033[0m\n'
for tool in brew hs cliclick; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  ok    %-46s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '  MISSING %-44s\n' "$tool"
        fail=$((fail + 1))
    fi
done
if [ -d "$HOME/Applications/noswoosh.app" ]; then
    printf '  ok    %-46s %s\n' "noswoosh" "$HOME/Applications/noswoosh.app"
else
    printf '  MISSING %-44s\n' "noswoosh"
    fail=$((fail + 1))
fi
if [ -d /Applications/Hammerspoon.app ]; then
    printf '  ok    %-46s installed\n' "Hammerspoon.app"
else
    printf '  MISSING %-44s\n' "Hammerspoon.app"
    fail=$((fail + 1))
fi

printf '\n\033[1mConfig links\033[0m\n'
for pair in "$HOME/.hammerspoon/init.lua|$REPO/hammerspoon/init.lua" "$HOME/.config/ghostty/config|$REPO/ghostty/config" "$HOME/.nanorc|$REPO/nano/nanorc"; do
    target="${pair%%|*}"; source="${pair#*|}"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        printf '  ok    %-46s -> repo\n' "${target/#$HOME/~}"
        pass=$((pass + 1))
    else
        printf '  DRIFT %-46s not linked to this repo\n' "${target/#$HOME/~}"
        fail=$((fail + 1))
    fi
done
if [ -d /Applications/Ghostty.app ]; then
    printf '  ok    %-46s installed\n' "Ghostty.app"
else
    printf '  MISSING %-44s\n' "Ghostty.app"
    fail=$((fail + 1))
fi

printf '\n\033[1mHammerspoon runtime\033[0m\n'
if command -v hs >/dev/null 2>&1 && pgrep -x Hammerspoon >/dev/null 2>&1; then
    printf '  %-52s %s\n' "accessibility granted"   "$(hsq 'hs.accessibilityState()')"
    printf '  %-52s %s\n' "launches at login"       "$(hsq 'hs.autoLaunch()')"
    printf '  %-52s %s\n' "dock scroll tap active"  "$(hsq 'dockScrollTap:isEnabled()')"
    printf '  %-52s %s\n' "clipboard tap active"    "$(hsq 'clipboardTap:isEnabled()')"
    printf '  %-52s %s\n' "screenshot tap active"   "$(hsq 'screenshotTap:isEnabled()')"
    printf '  %-52s %s\n' "hotkeys registered"      "$(hsq 'return #hs.hotkey.getHotkeys()')"
    printf '  %-52s %s\n' "desktops on main screen" "$(hsq '#hs.spaces.spacesForScreen(hs.screen.mainScreen())')"
else
    printf '  Hammerspoon is not running, runtime checks skipped\n'
fi

printf '\n\033[1mDisplays\033[0m\n'
if command -v hs >/dev/null 2>&1 && pgrep -x Hammerspoon >/dev/null 2>&1; then
    perl -e 'alarm 5; exec @ARGV' hs -c 'local t={} for _,s in ipairs(hs.screen.allScreens()) do local f=s:fullFrame(); t[#t+1]=string.format("  %s %dx%d at (%d,%d)", s:name(), f.w, f.h, f.x, f.y) end return table.concat(t,"\n")' 2>/dev/null | grep -v "^--"
fi

printf '\n%d ok, %d to look at\n' "$pass" "$fail"
