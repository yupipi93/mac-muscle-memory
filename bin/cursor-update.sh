#!/bin/bash
# Keeps Cursor where a user without admin rights can keep it updated, and updates it on demand.
#
# The problem. Cursor updates itself with Squirrel, which installs without a password only when
# it can write both Cursor.app and the folder that holds it. /Applications is root:admin, so on
# a standard account every update asks for an admin, and with just-in-time elevation (Admin By
# Request and similar) that dialog comes before elevation can be turned on. An elevated update
# also leaves Cursor.app owned by root, so the next one needs admin again.
#
# The fix. A Cursor.app in ~/Applications that belongs to the user: Squirrel can replace it by
# itself from then on. This script gets there in one step, and updates on demand later:
#
#   1. Picks the target: the latest build from Cursor's update feed, or an installed copy if
#      that one is newer (staged rollouts) or the feed cannot be reached.
#   2. Prepares a fresh Cursor.app owned by the user in its cache (unzips the download, or
#      copies the installed bundle) and checks signature, Team ID, bundle id and version.
#   3. Waits for admin rights, only if an old copy sits where the user cannot write.
#   4. Closes Cursor, sets every old copy aside and puts the new one in ~/Applications.
#   5. Opens it and waits until it runs. If it does not, puts the old copies back.
#
# Rules that keep Cursor working whatever happens (learned the hard way, see docs/tools.md):
#   - Everything that can fail harmlessly happens before Cursor is closed.
#   - Nothing inside an installed bundle is ever changed, chowned or deleted: macOS App
#     Management forbids it even to root. Whole bundles are only renamed, which it allows.
#   - Every rename is written to a journal first, so it can be undone.
#   - Old copies are deleted only after the new Cursor runs, and only the ones the user owns.
#   - Every message describes the state read back from disk, never the state intended.
#
# Usage:
#   cursor-update.sh              do whatever is needed (nothing, when all is well)
#   cursor-update.sh --check      show installed copies, the latest build and the plan
#   cursor-update.sh --dry-run    also prepare and verify the new bundle, change nothing
#   cursor-update.sh --force      reinstall the latest build even when nothing is needed
#   cursor-update.sh --gui        dialogs and notifications (what "Update Cursor.app" runs)
#
# Tests: tests/cursor-update.test.sh. The CU_* variables exist for them.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BUNDLE_ID="${CU_BUNDLE_ID:-com.todesktop.230313mzl4w4u92}"
TEAM_ID="${CU_TEAM_ID:-VDXQ22DGB9}"
EXEC_NAME="${CU_EXEC_NAME:-Cursor}"
SYSTEM_APP="${CU_SYSTEM_APP:-/Applications/Cursor.app}"
USER_APP="${CU_USER_APP:-$HOME/Applications/Cursor.app}"
CACHE="${CU_CACHE:-$HOME/Library/Caches/cursor-update}"
LOG="${CU_LOG:-$HOME/Library/Logs/cursor-update.log}"
FEED="${CU_FEED:-https://api2.cursor.sh/updates/api/update}"
LAUNCH_TIMEOUT="${CU_LAUNCH_TIMEOUT:-90}"
PRIV_RUNNER="${CU_PRIV_RUNNER:-osascript}"   # tests: "sh" runs the same command, no dialog
INJECT="${CU_INJECT_FAILURE:-}"              # tests: retire-<n> | install | launch
ELEVATION_APP="/Applications/Admin By Request.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TITLE="Update Cursor"

# --- the part that may run as root ------------------------------------------------------------
# Reached through run_step: as root via the macOS admin dialog when an old copy sits where the
# user cannot write, as the user otherwise. It renames whole bundles and nothing else.

# Puts back every copy listed in <hold>/journal that is still set aside, last one first.
journal_restore() {
    local hold="$1" orig held rc=0
    [ -f "$hold/journal" ] || return 0
    while IFS=$'\t' read -r orig held; do
        if [ -e "$held" ] && [ ! -e "$orig" ]; then mv "$held" "$orig" || rc=1; fi
    done < <(tail -r "$hold/journal")
    return "$rc"
}

case "${1:-}" in
--_swap)
    # --_swap <new bundle, or - to keep the destination> <destination> <hold> <old copy>...
    new="$2" dest="$3" hold="$4"
    shift 4
    set +e
    : >"$hold/journal" || exit 20
    n=0
    for old in "$@"; do
        [ -e "$old" ] || continue
        n=$((n + 1))
        held="$hold/$n-$(basename "$(dirname "$old")" | tr ' /' '__')-$(basename "$old").disabled"
        printf '%s\t%s\n' "$old" "$held" >>"$hold/journal" || { journal_restore "$hold"; exit 20; }
        if [ "$INJECT" = "retire-$n" ] || ! mv "$old" "$held"; then
            journal_restore "$hold"
            exit 21
        fi
    done
    if [ "$new" != - ]; then
        # An existing destination would make mv nest the new bundle inside it.
        if [ "$INJECT" = install ] || [ -e "$dest" ] || ! mv "$new" "$dest"; then
            journal_restore "$hold"
            exit 22
        fi
        : >"$hold/installed"
    fi
    exit 0 ;;
--_rollback)
    # --_rollback <destination> <hold>: undoes a --_swap whose new Cursor did not start.
    dest="$2" hold="$3"
    set +e
    if [ -f "$hold/installed" ] && [ -e "$dest" ]; then
        mv "$dest" "$hold/failed-new.app.disabled" || exit 30
    fi
    journal_restore "$hold" || exit 31
    exit 0 ;;
esac

# --- options, log, dialogs --------------------------------------------------------------------
CHECK=0 DRY=0 FORCE=0 GUI=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;; --dry-run) DRY=1 ;; --force) FORCE=1 ;; --gui) GUI=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

mkdir -p "$CACHE" "$(dirname "$LOG")"
[ "$GUI" = 1 ] && exec >>"$LOG" 2>&1
log() { printf '%s %s\n' "$(date '+%F %T')" "$1"; }
pretty() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

notify() {
    log "$1"
    if [ "$GUI" = 1 ]; then
        osascript -e 'on run a' -e 'display notification (item 1 of a) with title (item 2 of a)' \
            -e 'end run' "$1" "$TITLE" >/dev/null 2>&1 || true
    fi
}
# ask <message> <button>...: prints the button pressed (the last one is the default), or
# "Cancel". In the terminal it does not ask: it answers with the default.
ask() {
    local msg="$1"
    shift
    if [ "$GUI" != 1 ]; then printf '%s\n' "${@: -1}"; return 0; fi
    osascript - "$msg" "$TITLE" "$@" <<'OSA' 2>/dev/null || echo Cancel
on run argv
    set btns to items 3 thru -1 of argv
    activate
    try
        set r to display dialog (item 1 of argv) with title (item 2 of argv) buttons btns default button (count of btns) with icon note
        return button returned of r
    on error number -128
        return "Cancel"
    end try
end run
OSA
}
say_done() { # final message: a dialog in the app, plain output in the terminal
    log "$1"
    if [ "$GUI" = 1 ]; then ask "$1" OK >/dev/null; else printf '%s\n' "$1"; fi
}
fail() {
    log "ERROR: $1"
    if [ "$GUI" = 1 ]; then ask "$1

Log: $(pretty "$LOG")" OK >/dev/null; else printf 'error: %s\n' "$1" >&2; fi
    exit 1
}

# One run at a time: a second click on the app while the first one works does nothing.
# On exit, a hold folder with nothing set aside in it (journal only) goes away.
HOLD="" WAS_RUNNING=""
cleanup() {
    rm -rf "$LOCK"
    if [ -n "$HOLD" ] && [ -d "$HOLD" ] && ! ls "$HOLD"/*.disabled >/dev/null 2>&1; then rm -rf "$HOLD"; fi
}
if [ "$CHECK" = 0 ]; then
    LOCK="$CACHE/.running"
    if ! mkdir "$LOCK" 2>/dev/null; then
        if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then log "already running"; exit 0; fi
        rm -rf "$LOCK"
        mkdir "$LOCK"
    fi
    echo $$ >"$LOCK/pid"
    trap cleanup EXIT
fi

# --- helpers ----------------------------------------------------------------------------------
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
plist_get() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
version_of() { plist_get "$1" CFBundleShortVersionString || echo 0; }
owner_of() { stat -f %Su "$1"; }
# vgt A B: true when version A is newer than version B.
vgt() {
    local IFS=. i x y
    local -a a=($1) b=($2)
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        x="${a[i]:-0}" y="${b[i]:-0}"
        x="${x%%[!0-9]*}" y="${y%%[!0-9]*}"
        if ((10#${x:-0} > 10#${y:-0})); then return 0; fi
        if ((10#${x:-0} < 10#${y:-0})); then return 1; fi
    done
    return 1
}
# mine <bundle>: the user can move it without admin rights (owns it, can write it and its folder).
mine() { [ "$(stat -f %u "$1")" = "$(id -u)" ] && [ -w "$1" ] && [ -w "$(dirname "$1")" ]; }
all_mine() { [ -z "$(find "$1" ! -user "$(id -un)" -print -quit 2>/dev/null)" ]; }
is_admin() { dseditgroup -o checkmember -m "$(id -un)" admin >/dev/null 2>&1; }
# Never `ps | grep -q` here: grep exits at the first match, ps dies of SIGPIPE, and pipefail
# turns a match into a failure, i.e. "Cursor is not running" while it is.
exe_running() {
    local procs
    procs="$(ps -axo comm=)"
    grep -Fxq "$1/Contents/MacOS/$EXEC_NAME" <<<"$procs"
}
running_copy() {
    local c
    for c in "$USER_APP" "$SYSTEM_APP"; do exe_running "$c" && { printf '%s\n' "$c"; return 0; }; done
    return 1
}
# Cursor's own installer (Squirrel's ShipIt), started from either copy. Other apps have one too.
squirrel_running() {
    local procs c
    procs="$(ps -axo comm=)"
    for c in "$USER_APP" "$SYSTEM_APP"; do
        grep -Fxq "$c/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" <<<"$procs" && return 0
    done
    return 1
}
snapshot() { local c; for c in "$USER_APP" "$SYSTEM_APP"; do printf '%s=%s;' "$c" "$(stat -f %i "$c" 2>/dev/null || echo none)"; done; }

state_report() {
    local c held s=""
    for c in "$USER_APP" "$SYSTEM_APP"; do
        [ -d "$c" ] && s="$s
- $(pretty "$c"): Cursor $(version_of "$c"), owner $(owner_of "$c")$(exe_running "$c" && echo ', running')"
    done
    if [ -n "$HOLD" ]; then
        for held in "$HOLD"/*.disabled; do
            [ -e "$held" ] && s="$s
- set aside: $(pretty "$held")"
        done
    fi
    [ -n "$s" ] || s="
- no Cursor.app in /Applications or ~/Applications"
    printf 'State now:%s' "$s"
}

verify_bundle() { # <bundle> <expected version>: prints why it fails, if it does
    local b="$1"
    [ -x "$b/Contents/MacOS/$EXEC_NAME" ] || { echo "no executable"; return 1; }
    [ "$(plist_get "$b" CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "not Cursor's bundle id"; return 1; }
    [ "$(version_of "$b")" = "$2" ] || { echo "version is not $2"; return 1; }
    codesign --verify --deep --strict "$b" 2>/dev/null || { echo "invalid code signature"; return 1; }
    [ "$(codesign -dv "$b" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$TEAM_ID" ] \
        || { echo "not signed by Cursor's developer"; return 1; }
    all_mine "$b" || { echo "not entirely owned by you"; return 1; }
}

launch_and_wait() {
    local i
    [ "$INJECT" = launch ] && return 1
    env -u ELECTRON_RUN_AS_NODE open "$1" >/dev/null 2>&1 || return 1
    for ((i = 0; i < LAUNCH_TIMEOUT * 2; i++)); do
        exe_running "$1" && return 0
        sleep 0.5
    done
    return 1
}
reopen_previous() { # after a failure: give back the Cursor that was open, if one was
    local c
    [ -n "$WAS_RUNNING" ] || return 0
    for c in "$WAS_RUNNING" "$USER_APP" "$SYSTEM_APP"; do
        if [ -d "$c" ] && ! exe_running "$c"; then
            env -u ELECTRON_RUN_AS_NODE open "$c" >/dev/null 2>&1 && return 0
        fi
    done
}

# run_step <hidden subcommand> <args>: as the user, or as root through the admin dialog.
run_step() {
    local cmd="/bin/bash" a
    if [ "$NEED_ROOT" = 0 ]; then /bin/bash "$SELF" "$@"; return; fi
    for a in "$SELF" "$@"; do cmd="$cmd $(q "$a")"; done
    if [ "$PRIV_RUNNER" = sh ]; then /bin/sh -c "$cmd"; return; fi
    osascript - "$cmd" <<'OSA'
on run argv
    do shell script (item 1 of argv) with prompt "Update Cursor needs admin rights to move the old Cursor.app aside." with administrator privileges
end run
OSA
}

# --- what is installed, what is current ---------------------------------------------------------
case "$(uname -m)" in arm64) PLATFORM=darwin-arm64 ;; *) PLATFORM=darwin-x64 ;; esac
COPIES=()
for c in "$USER_APP" "$SYSTEM_APP"; do [ -d "$c" ] && COPIES+=("$c"); done
NEWEST="" NEWEST_VER=0
for c in ${COPIES[@]+"${COPIES[@]}"}; do
    v="$(version_of "$c")"
    if [ -z "$NEWEST" ] || vgt "$v" "$NEWEST_VER"; then NEWEST="$c" NEWEST_VER="$v"; fi
done

# The feed Squirrel polls. Asking on behalf of version 0.0.0 always returns the latest build.
if [ -n "${CU_FEED_JSON:-}" ]; then
    FEED_BODY="$CU_FEED_JSON"
else
    FEED_OUT="$(curl -fsS -m 30 -w '\n%{http_code}' "$FEED/$PLATFORM/cursor/0.0.0/0/stable" 2>/dev/null)" || FEED_OUT=""
    if [ "$(tail -n1 <<<"$FEED_OUT")" = 200 ]; then FEED_BODY="$(sed '$d' <<<"$FEED_OUT")"; else FEED_BODY=""; fi
fi
LATEST="$(plutil -extract name raw -o - - <<<"$FEED_BODY" 2>/dev/null)" || LATEST=""
ZIP_URL="$(plutil -extract url raw -o - - <<<"$FEED_BODY" 2>/dev/null)" || ZIP_URL=""
[ -n "$ZIP_URL" ] || LATEST=""

# --- the plan -------------------------------------------------------------------------------------
# SOURCE of the Cursor.app that ends up in ~/Applications:
#   download  the latest build from the feed
#   copy      a copy made by the user of the newest installed bundle (no newer build exists, or
#             the feed is unreachable), so it belongs to the user
#   keep      ~/Applications/Cursor.app already is the newest and already belongs to the user
DEST="$USER_APP"
if [ -n "$LATEST" ] && { [ "$FORCE" = 1 ] || [ -z "$NEWEST" ] || vgt "$LATEST" "$NEWEST_VER"; }; then
    SOURCE=download TARGET_VER="$LATEST"
elif [ -z "$NEWEST" ]; then
    fail "Cursor is not installed and its update server cannot be reached. Nothing was changed."
elif [ "$NEWEST" = "$DEST" ] && mine "$DEST" && all_mine "$DEST" && [ "$FORCE" = 0 ]; then
    SOURCE=keep TARGET_VER="$NEWEST_VER"
else
    SOURCE=copy TARGET_VER="$NEWEST_VER"
fi
RETIRE=()
for c in ${COPIES[@]+"${COPIES[@]}"}; do
    [ "$SOURCE" = keep ] && [ "$c" = "$DEST" ] && continue
    RETIRE+=("$c")
done
NEED_ROOT=0
for c in ${RETIRE[@]+"${RETIRE[@]}"}; do mine "$c" || NEED_ROOT=1; done
[ -d "$(dirname "$DEST")" ] && [ ! -w "$(dirname "$DEST")" ] && NEED_ROOT=1
[ -n "${CU_FORCE_ROOT:-}" ] && NEED_ROOT=1

plan_text() {
    local c s
    case "$SOURCE" in
        download) s="Install Cursor $TARGET_VER, downloaded from Cursor and signature-checked, in your own Applications folder." ;;
        copy) s="Put a copy of Cursor $TARGET_VER that belongs to you in your own Applications folder." ;;
        keep) s="Keep Cursor $TARGET_VER in your own Applications folder." ;;
    esac
    for c in ${RETIRE[@]+"${RETIRE[@]}"}; do
        s="$s
- set aside $(pretty "$c") (Cursor $(version_of "$c"), owner $(owner_of "$c"))"
    done
    printf '%s' "$s"
}
NOTHING=0
[ "$SOURCE" = keep ] && [ ${#RETIRE[@]} -eq 0 ] && NOTHING=1

if [ "$CHECK" = 1 ]; then
    echo "installed:"
    [ ${#COPIES[@]} -gt 0 ] || echo "  none"
    for c in ${COPIES[@]+"${COPIES[@]}"}; do
        echo "  $(pretty "$c")  $(version_of "$c")  owner $(owner_of "$c")$(exe_running "$c" && echo '  running')"
    done
    echo "latest:     ${LATEST:-unknown (update server unreachable)}"
    echo "admin now:  $(is_admin && echo yes || echo no)"
    if [ "$NOTHING" = 1 ]; then
        echo "plan:       nothing to do. Cursor is yours and in ~/Applications, so it updates itself."
    else
        echo "plan:"
        plan_text | sed 's/^/  /'
        echo
        echo "admin:      $([ "$NEED_ROOT" = 1 ] && echo 'needed for the swap' || echo 'not needed')"
    fi
    exit 0
fi

log "installed: ${COPIES[*]:-none}; newest $NEWEST_VER; latest ${LATEST:-unknown}; source=$SOURCE target=$TARGET_VER retire=${RETIRE[*]:-none} root=$NEED_ROOT"
if [ "$NOTHING" = 1 ]; then
    say_done "Cursor $TARGET_VER is up to date. It is yours and lives in your own Applications folder, so it updates itself. Nothing to do."
    exit 0
fi

if [ "$GUI" = 1 ] && [ "$DRY" = 0 ]; then
    msg="$(plan_text)

Cursor will close and reopen. Nothing is deleted until the new Cursor is running."
    [ "$NEED_ROOT" = 1 ] && msg="$msg Admin rights are needed once, to move the old copy."
    [ "$(ask "$msg" Cancel Continue)" = Continue ] || { log "cancelled at the plan"; exit 0; }
fi
if [ "$DRY" = 0 ] && [ "$GUI" = 0 ] && [ "${TERM_PROGRAM:-}" = vscode ] && running_copy >/dev/null; then
    fail "Run this outside Cursor: it closes Cursor, and Cursor's terminal with it. Or open the 'Update Cursor' app. Nothing was changed."
fi
BEFORE="$(snapshot)"

# --- prepare and verify the new bundle (Cursor still open, nothing changed yet) ---------------
STAGE="$CACHE/stage"
rm -rf "$STAGE" "$CACHE"/[0-9]*
mkdir -p "$STAGE"
NEW=-
ZIP=""
case "$SOURCE" in
download)
    ZIP="$CACHE/Cursor-$TARGET_VER-$PLATFORM.zip"
    if [ ! -s "$ZIP" ]; then
        find "$CACHE" -maxdepth 1 -name '*.zip*' -delete
        notify "Downloading Cursor $TARGET_VER..."
        curl -fL -sS -m 900 -o "$ZIP.part" "$ZIP_URL" || fail "The download failed. Nothing was changed."
        mv "$ZIP.part" "$ZIP"
    fi
    if ! ditto -x -k "$ZIP" "$STAGE" 2>/dev/null; then
        rm -f "$ZIP"
        fail "The download is damaged and was discarded. Nothing was changed: run it again."
    fi
    NEW="$STAGE/Cursor.app" ;;
copy)
    notify "Copying Cursor $TARGET_VER..."
    ditto "$NEWEST" "$STAGE/Cursor.app" 2>/dev/null || fail "Could not copy $(pretty "$NEWEST"). Nothing was changed."
    NEW="$STAGE/Cursor.app" ;;
esac
if [ "$NEW" != - ]; then
    if ! why="$(verify_bundle "$NEW" "$TARGET_VER")"; then
        [ -n "$ZIP" ] && rm -f "$ZIP"
        fail "The new Cursor failed a check ($why) and was discarded. Nothing was changed."
    fi
    log "verified $NEW: Cursor $TARGET_VER, team $TEAM_ID, owned by $(id -un)"
fi
if [ "$DRY" = 1 ]; then
    printf 'dry run, nothing changed. Verified and ready:\n%s\nadmin: %s\n' "$(plan_text)" \
        "$([ "$NEED_ROOT" = 1 ] && echo 'needed for the swap' || echo 'not needed')"
    exit 0
fi

# --- admin rights, only when an old copy needs them --------------------------------------------
if [ "$NEED_ROOT" = 1 ] && [ "$PRIV_RUNNER" = osascript ]; then
    while ! is_admin; do
        [ "$GUI" = 1 ] || fail "Admin rights are not active. Request elevation (Admin By Request) and run this again. Nothing was changed."
        if [ -d "$ELEVATION_APP" ]; then
            choice="$(ask "Admin rights are not active yet. Nothing has been changed.

Request elevation in $(basename "$ELEVATION_APP" .app), then press Continue." \
                Cancel "Open $(basename "$ELEVATION_APP" .app)" Continue)"
        else
            choice="$(ask "Admin rights are not active yet. Get them, then press Continue. Nothing has been changed." Cancel Continue)"
        fi
        case "$choice" in
            Continue) ;;
            Open*) open "$ELEVATION_APP" ;;
            *) log "cancelled waiting for admin"; exit 0 ;;
        esac
    done
fi

mkdir -p "$(dirname "$DEST")"
HOLD="$CACHE/retired-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HOLD"

# --- close Cursor, and let its own updater finish if quitting started it -----------------------
WAS_RUNNING="$(running_copy || true)"
if [ -n "$WAS_RUNNING" ]; then
    notify "Closing Cursor..."
    while :; do
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 60); do running_copy >/dev/null || break; sleep 0.5; done
        running_copy >/dev/null || break
        [ "$GUI" = 1 ] || fail "Cursor did not close (unsaved changes?). Nothing was changed."
        [ "$(ask "Cursor did not close, probably because of unsaved changes. Save or discard them, then press Retry. Nothing has been changed yet." \
            Cancel Retry)" = Retry ] || { log "cancelled, Cursor still open"; exit 0; }
    done
fi
# Quitting Cursor with an update pending starts Squirrel's installer, which moves bundles too.
for _ in $(seq 240); do squirrel_running || break; sleep 0.5; done
while squirrel_running; do
    [ "$GUI" = 1 ] || { reopen_previous; fail "Cursor's own updater is still running. Nothing was changed: run this again when it is done."; }
    [ "$(ask "Cursor's own updater is running (it may be showing a password dialog). Let it finish or cancel it, then press Retry. Nothing has been changed yet." \
        Cancel Retry)" = Retry ] || { reopen_previous; log "cancelled, Squirrel still running"; exit 0; }
done
if [ "$(snapshot)" != "$BEFORE" ]; then
    reopen_previous
    fail "Cursor changed while this was preparing (its own updater ran). Nothing was changed by this app: press the button again. $(state_report)"
fi

# --- swap ---------------------------------------------------------------------------------------
notify "Installing Cursor $TARGET_VER..."
if ! swap_out="$(run_step --_swap "$NEW" "$DEST" "$HOLD" ${RETIRE[@]+"${RETIRE[@]}"} 2>&1)"; then
    log "swap did not complete: $swap_out"
    reopen_previous
    case "$swap_out" in
        *-128*) fail "Cancelled at the password dialog. Nothing was changed. $(state_report)" ;;
        *) fail "Cursor could not be installed, and every old copy was put back where it was. $(state_report)" ;;
    esac
fi
log "swap done: $(snapshot)"
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# --- open it, and undo everything if it does not start -----------------------------------------
notify "Opening Cursor $TARGET_VER..."
if ! launch_and_wait "$DEST"; then
    log "Cursor did not start from $DEST within ${LAUNCH_TIMEOUT}s, putting the old copies back"
    if run_step --_rollback "$DEST" "$HOLD" >/dev/null 2>&1; then
        [ "$(stat -f %u "$HOLD/failed-new.app.disabled" 2>/dev/null)" = "$(id -u)" ] \
            && rm -rf "$HOLD/failed-new.app.disabled" 2>/dev/null
        reopen_previous
        fail "The new Cursor did not start, so the previous one was put back. $(state_report)"
    fi
    reopen_previous
    fail "The new Cursor did not start, and putting the previous one back failed too. $(state_report)"
fi

# --- tidy up: only now, with the new Cursor running ----------------------------------------------
for held in "$HOLD"/*.disabled; do
    [ -e "$held" ] || continue
    [ "$(stat -f %u "$held")" = "$(id -u)" ] && { rm -rf "$held" 2>/dev/null || true; }
done
LEFT=""
for held in "$HOLD"/*.disabled; do [ -e "$held" ] && LEFT="$held"; done
[ -n "$LEFT" ] || rm -rf "$HOLD"
rm -rf "$STAGE"
find "$CACHE" -maxdepth 1 -name '*.zip*' -delete

msg="Cursor $(version_of "$DEST") is running from your own Applications folder."
# macOS denies writes to a bundle for a moment while it assesses its first launch.
for _ in $(seq 20); do mine "$DEST" && break; sleep 0.25; done
if mine "$DEST" && all_mine "$DEST"; then
    msg="$msg It belongs to you, so from now on it updates itself, with no admin rights."
else
    msg="$msg Warning: it is not entirely yours, so its updates may still ask for admin rights."
fi
[ -d "$SYSTEM_APP" ] && msg="$msg Warning: $(pretty "$SYSTEM_APP") is still there."
if [ -n "$LEFT" ]; then
    msg="$msg

Old copies this app is not allowed to delete (owned by root, or protected by macOS) are disabled and set aside here. Delete the folder from Finder when you like; it may ask for admin rights:
$(pretty "$HOLD")"
    log "$msg"
    if [ "$GUI" = 1 ]; then
        [ "$(ask "$msg" "Show in Finder" OK)" = "Show in Finder" ] && open -R "$LEFT"
    else
        printf '%s\n' "$msg"
    fi
else
    say_done "$msg"
fi
