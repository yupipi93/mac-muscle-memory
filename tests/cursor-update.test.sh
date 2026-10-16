#!/bin/bash
# Scenario tests for bin/cursor-update.sh. Never touches the real Cursor.
#
# Each scenario builds fake Cursor apps (stay-open AppleScript applets, so they launch and
# quit like a real app) in a temporary folder whose paths contain spaces and an apostrophe,
# runs the script through /bin/bash (the bash the Update Cursor app uses), and checks the state
# on disk and the running processes afterwards. Failures are injected at every step that
# changes something, to prove each one leaves the previous Cursor installed and running.
#
# What this cannot cover: macOS App Management on a real, notarized Cursor, and the admin
# dialog. The privileged path is exercised by running the exact same quoted command with
# /bin/sh instead of the dialog (CU_PRIV_RUNNER=sh).
#
# Usage: tests/cursor-update.test.sh     (about a minute; fake apps flash in the Dock)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$REPO/bin/cursor-update.sh"
FAKE_ID="test.mac-muscle-memory.fake-cursor"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cursor update test.XXXXXX")"
FEEDDIR="$(mktemp -d "${TMPDIR:-/tmp}/cursor-update-feed.XXXXXX")"
TPL="$ROOT/templates"
PASS=0 FAILS=0 S="" RC=0

# --- fixtures -----------------------------------------------------------------------------------
make_template() { # <version>
    local app="$TPL/$1/Cursor.app"
    mkdir -p "$TPL/$1"
    osacompile -s -o "$app" -e 'on idle' -e 'return 60' -e 'end idle' >/dev/null || exit 1
    plutil -replace CFBundleIdentifier -string "$FAKE_ID" "$app/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$1" "$app/Contents/Info.plist"
    codesign --force --sign - "$app" >/dev/null 2>&1
}
place() { mkdir -p "$(dirname "$2")" && ditto "$TPL/$1/Cursor.app" "$2"; }   # <version> <path>
feed_json() { printf '{"url":"file://%s","name":"%s"}' "$FEEDDIR/Cursor-$1.zip" "$1"; }

ver() { if [ -d "$1" ]; then plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist"; else echo absent; fi; }
ino() { stat -f %i "$1" 2>/dev/null || echo none; }
# No `ps | grep -q`: with pipefail, grep's early exit makes ps fail and a match reads as "no".
procs() { ps -axo pid=,comm=; }
is_running() { local p; p="$(procs)"; grep -Fq " $1/Contents/MacOS/applet" <<<"$p"; }
pid_of() { local p; p="$(procs)"; awk -v want="$1/Contents/MacOS/applet" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == want) print pid }' <<<"$p" | head -1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
held() { find "$CU_CACHE" -maxdepth 2 -name '*.disabled' 2>/dev/null | wc -l | tr -d ' '; }
mine_all() { [ -z "$(find "$1" ! -user "$(id -un)" -print -quit)" ]; }
# Opens a fake Cursor and waits until it is settled like a real one that has been open a while:
# on a bundle's first launch macOS denies writes to it for about half a second.
start() {
    open "$1"
    for _ in $(seq 40); do is_running "$1" && [ -w "$1" ] && return 0; sleep 0.25; done
    echo "fixture: could not start $1" >&2
}
# Quits every fake app this run started. They are identified by their unique temp path, and
# whatever does not quit politely is ended by its exact PID.
ours() { local p; p="$(procs)"; awk -v root="$ROOT/" 'index($0, root) { print $1 }' <<<"$p"; }
stop_all() {
    [ -n "$(ours)" ] || return 0
    osascript -e "tell application id \"$FAKE_ID\" to quit" >/dev/null 2>&1
    for _ in $(seq 40); do [ -n "$(ours)" ] || return 0; sleep 0.25; done
    for pid in $(ours); do kill "$pid" 2>/dev/null; done
    for _ in $(seq 20); do [ -n "$(ours)" ] || return 0; sleep 0.25; done
    echo "warning: fake apps still running: $(ours)" >&2
}

setup() { # <name>
    stop_all
    S="$ROOT/$1"
    mkdir -p "$S/system apps" "$S/home apps"
    export CU_SYSTEM_APP="$S/system apps/Cursor.app" CU_USER_APP="$S/home apps/Cursor.app"
    export CU_CACHE="$S/cache dir" CU_LOG="$S/update.log" CU_BUNDLE_ID="$FAKE_ID"
    export CU_TEAM_ID="not set" CU_EXEC_NAME=applet CU_LAUNCH_TIMEOUT=20
    export CU_FEED_JSON="$(feed_json 1.2)"
    unset CU_INJECT_FAILURE CU_FORCE_ROOT CU_PRIV_RUNNER CU_FEED
    printf '\n%s\n' "$1"
}
# TEST_TRACE=1 runs the script under bash -x; a failing check then shows the end of the trace.
run() { /bin/bash ${TEST_TRACE:+-x} "$SUT" "$@" >"$S/out" 2>&1; RC=$?; }
check() { # <description> <test command...>
    if "${@:2}"; then
        PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
    else
        FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"
        sed 's/^/        | /' "$S/out" | tail -8
    fi
}
eq() { [ "$1" = "$2" ]; }
ne() { [ "$1" != "$2" ]; }
has() { grep -Fq "$1" "$S/out"; }

# The state every failure must leave: both old copies back, untouched, and Cursor running again.
expect_untouched() { # <system inode> <user inode> <was running: user|none>
    check "exit code is an error" ne "$RC" 0
    check "system copy back, same bundle" eq "$(ino "$CU_SYSTEM_APP")" "$1"
    check "user copy back, same bundle" eq "$(ino "$CU_USER_APP")" "$2"
    if [ "$3" = user ]; then check "Cursor running again from the user copy" is_running "$CU_USER_APP"; fi
    check "nothing left set aside" eq "$(held)" 0
}
# The state every success must leave: one copy, in ~/Applications, the user's, running.
expect_installed() { # <version>
    check "exit code 0" eq "$RC" 0
    check "~/Applications has Cursor $1" eq "$(ver "$CU_USER_APP")" "$1"
    check "no copy left in /Applications" eq "$(ver "$CU_SYSTEM_APP")" absent
    check "every file belongs to the user" mine_all "$CU_USER_APP"
    check "running from ~/Applications" is_running "$CU_USER_APP"
    check "old copies deleted, nothing set aside" eq "$(held)" 0
    check "no download or staging left in the cache" eq "$(find "$CU_CACHE" -mindepth 1 -maxdepth 1 ! -name .running | wc -l | tr -d ' ')" 0
}

cleanup() {
    stop_all
    find "$ROOT" \( -name '*.app' -o -name '*.disabled' \) -prune -exec \
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u {} \; 2>/dev/null
    rm -rf "$ROOT" "$FEEDDIR"
}
trap cleanup EXIT

for v in 1.0 1.1 1.2 1.3; do make_template "$v"; done
ditto -c -k --keepParent "$TPL/1.2/Cursor.app" "$FEEDDIR/Cursor-1.2.zip"
printf 'not a zip' >"$FEEDDIR/Cursor-9.9.zip"

# --- scenarios ------------------------------------------------------------------------------------
setup "two copies, the user's one running, update available (this Mac on 2026-10-16)"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
old="$(pid_of "$CU_USER_APP")"
check "fixture: old Cursor is running" alive "$old"
run
expect_installed 1.2
check "the old Cursor process was closed, not left running" ne "$(alive "$old" && echo alive)" alive
check "the one running is a new process" ne "$(pid_of "$CU_USER_APP")" "$old"

setup "same, through the privileged path, with an apostrophe in every path"
export CU_SYSTEM_APP="$S/owner's apps/Cursor.app" CU_USER_APP="$S/home's apps/Cursor.app" CU_FORCE_ROOT=1 CU_PRIV_RUNNER=sh
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
old="$(pid_of "$CU_USER_APP")"
run
expect_installed 1.2
check "the old Cursor process was closed, not left running" ne "$(alive "$old" && echo alive)" alive

setup "Cursor running from /Applications (the original state)"
place 1.1 "$CU_SYSTEM_APP"; start "$CU_SYSTEM_APP"
old="$(pid_of "$CU_SYSTEM_APP")"
run
expect_installed 1.2
check "the old Cursor process was closed, not left running" ne "$(alive "$old" && echo alive)" alive

setup "only in /Applications, already current (the original state): copied, not downloaded"
place 1.2 "$CU_SYSTEM_APP"
before="$(ino "$CU_SYSTEM_APP")"
run
expect_installed 1.2
check "the new copy is a fresh bundle" ne "$(ino "$CU_USER_APP")" "$before"
check "said it copied" has "Copying"
check "no false 'not entirely yours' warning" ne "$(has "not entirely yours" && echo warned)" warned

setup "healthy and current: nothing to do"
place 1.2 "$CU_USER_APP"
before="$(ino "$CU_USER_APP")"
run
check "exit code 0" eq "$RC" 0
check "bundle untouched" eq "$(ino "$CU_USER_APP")" "$before"
check "says there is nothing to do" has "Nothing to do"
check "did not launch anything" ne "$(is_running "$CU_USER_APP" && echo yes)" yes

setup "healthy, update available, running"
place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
run
expect_installed 1.2

setup "installed copy newer than the feed (staged rollout): never downgrades"
place 1.3 "$CU_SYSTEM_APP"
run
expect_installed 1.3

setup "nothing installed: installs from the feed"
run
expect_installed 1.2

setup "update server unreachable, a copy exists: still moves it"
export CU_FEED_JSON="" CU_FEED="http://127.0.0.1:9"
place 1.1 "$CU_SYSTEM_APP"
run
expect_installed 1.1

setup "update server unreachable, nothing installed: clear error"
export CU_FEED_JSON="" CU_FEED="http://127.0.0.1:9"
run
check "exit code is an error" ne "$RC" 0
check "explains it" has "cannot be reached"
check "nothing created" eq "$(ver "$CU_USER_APP")" absent

setup "FAILURE: installing the new bundle fails"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
s="$(ino "$CU_SYSTEM_APP")" u="$(ino "$CU_USER_APP")"
export CU_INJECT_FAILURE=install
run
expect_untouched "$s" "$u" user
check "says every old copy was put back" has "put back"

setup "FAILURE: setting aside the second old copy fails"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
s="$(ino "$CU_SYSTEM_APP")" u="$(ino "$CU_USER_APP")"
export CU_INJECT_FAILURE=retire-2
run
expect_untouched "$s" "$u" user

setup "FAILURE: the new Cursor does not start, so it is rolled back"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
s="$(ino "$CU_SYSTEM_APP")" u="$(ino "$CU_USER_APP")" old="$(pid_of "$CU_USER_APP")"
export CU_INJECT_FAILURE=launch
run
expect_untouched "$s" "$u" user
check "says the previous one was put back" has "previous one was put back"
check "the old process was closed before the swap" ne "$(alive "$old" && echo alive)" alive
check "the failed new copy was deleted, not left in the cache" eq "$(find "$CU_CACHE" -name 'failed-new*' | wc -l | tr -d ' ')" 0

setup "FAILURE: the new Cursor does not start, privileged path"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
s="$(ino "$CU_SYSTEM_APP")" u="$(ino "$CU_USER_APP")"
export CU_INJECT_FAILURE=launch CU_FORCE_ROOT=1 CU_PRIV_RUNNER=sh
run
expect_untouched "$s" "$u" user

setup "FAILURE: download signed by someone else, caught before closing Cursor"
place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
u="$(ino "$CU_USER_APP")"
export CU_TEAM_ID="SOMEONEELSE"
run
check "exit code is an error" ne "$RC" 0
check "names the reason" has "not signed by Cursor's developer"
check "bundle untouched" eq "$(ino "$CU_USER_APP")" "$u"
check "Cursor never closed" is_running "$CU_USER_APP"

setup "FAILURE: damaged download, caught before closing Cursor"
place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
u="$(ino "$CU_USER_APP")"
export CU_FEED_JSON="$(feed_json 9.9)"
run
check "exit code is an error" ne "$RC" 0
check "bundle untouched" eq "$(ino "$CU_USER_APP")" "$u"
check "Cursor never closed" is_running "$CU_USER_APP"
check "damaged zip discarded" eq "$(find "$CU_CACHE" -name '*.zip' | wc -l | tr -d ' ')" 0

setup "dry run changes nothing"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"; start "$CU_USER_APP"
s="$(ino "$CU_SYSTEM_APP")" u="$(ino "$CU_USER_APP")"
run --dry-run
check "exit code 0" eq "$RC" 0
check "reports a dry run" has "dry run"
check "bundles untouched" eq "$(ino "$CU_SYSTEM_APP") $(ino "$CU_USER_APP")" "$s $u"
check "Cursor never closed" is_running "$CU_USER_APP"

setup "--check lists both copies and the plan"
place 1.0 "$CU_SYSTEM_APP"; place 1.1 "$CU_USER_APP"
run --check
check "exit code 0" eq "$RC" 0
check "lists the system copy" has "system apps/Cursor.app  1.0"
check "shows the latest build" has "latest:     1.2"
check "shows the plan" has "set aside"

setup "a second run while one is in progress does nothing"
place 1.1 "$CU_USER_APP"
u="$(ino "$CU_USER_APP")"
mkdir -p "$CU_CACHE/.running" && echo $$ >"$CU_CACHE/.running/pid"
run
check "exit code 0" eq "$RC" 0
check "bundle untouched" eq "$(ino "$CU_USER_APP")" "$u"
check "logged as already running" has "already running"
rm -rf "$CU_CACHE/.running"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
