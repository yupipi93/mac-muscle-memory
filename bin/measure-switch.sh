#!/usr/bin/env bash
# Measures how long a desktop switch takes, end to end, and prints the median.
#
# Needs Hammerspoon running with the config from this repo loaded. Detection uses
# hs.spaces.watcher, which is the only trustworthy signal that the Space really changed:
# hs.spaces.gotoSpace lies and screenshots are unavailable without Screen Recording.
#
# usage: measure-switch.sh [trials]
set -uo pipefail

TRIALS="${1:-5}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Must exercise the same mechanism init.lua uses, or the numbers describe nothing real.
NOSWOOSH="$HOME/Applications/noswoosh.app/Contents/MacOS/noswoosh"
if [ -x "$NOSWOOSH" ]; then
    SWITCHER="$NOSWOOSH"
    SWITCH_ARGS() { printf '"%s"' "$1"; }
else
    SWITCHER="$REPO/helper/spaceswitch"
    SWITCH_ARGS() { printf '"%s","20"' "$1"; }
fi
echo "using: $SWITCHER"

# Hammerspoon's IPC occasionally blocks, so every query is capped. macOS ships no timeout(1).
# `hs` blocks reading stdin unless it is redirected, which makes it look like an IPC hang.
hsq() { { perl -e 'alarm 20; exec @ARGV' hs -c "$1" </dev/null 2>/dev/null | tail -1; } 2>/dev/null; }

if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
    echo "Hammerspoon is not running" >&2
    exit 1
fi

# A locked screen cannot change Space, and every switcher fails at once. Without this check
# that looks exactly like the switching mechanism being broken, and it is not.
if ioreg -l -w 0 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
    echo "the screen is locked, unlock it first: nothing can switch Spaces from the lock screen" >&2
    exit 1
fi
if [ "$(hsq 'return tostring(hs.eventtap.isSecureInputEnabled())')" = "true" ]; then
    echo "warning: Secure Input is on, something is holding a password field" >&2
fi

hsq 'if _msW then _msW:stop() end; _msT=nil
_msW = hs.spaces.watcher.new(function() if not _msT then _msT = hs.timer.secondsSinceEpoch() end end)
_msW:start(); return "ok"' >/dev/null

samples=()
for ((i = 1; i <= TRIALS; i++)); do
    # Pick a direction that actually has somewhere to go, so a wall is never scored as a failure.
    idx=$(hsq 'local s=hs.spaces.spacesForScreen(hs.screen.mainScreen())
local c=hs.spaces.activeSpaceOnScreen(hs.screen.mainScreen())
for k,v in ipairs(s) do if v==c then return k end end return 1')
    if [ "$idx" = "1" ]; then dir=right; else dir=left; fi

    hsq "_msT=nil; _msT0=hs.timer.secondsSinceEpoch(); _msTask=hs.task.new('$SWITCHER', nil, {$(SWITCH_ARGS "$dir")}); _msTask:start()" >/dev/null
    sleep 2.5
    ms=$(hsq 'return _msT and string.format("%.0f", (_msT-_msT0)*1000) or "0"')
    if [ "$ms" = "0" ]; then
        printf '  trial %d: no switch detected\n' "$i"
    else
        printf '  trial %d: %s ms\n' "$i" "$ms"
        samples+=("$ms")
    fi
done

if [ ${#samples[@]} -eq 0 ]; then
    echo "no successful switches" >&2
    exit 1
fi

median=$(printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END {print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}')
printf '\nmedian over %d successful trials: %s ms\n' "${#samples[@]}" "$median"
