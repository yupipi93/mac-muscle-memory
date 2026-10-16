#!/usr/bin/env bash
# Updates Cursor on a Mac where the user is not an administrator.
#
# Cursor updates itself with Squirrel. Squirrel only installs without asking for an admin
# password when it can write both Cursor.app and the folder that holds it. /Applications is
# root:admin, so for a standard user every update pops an authorization dialog, and on a
# machine with just-in-time elevation (Admin By Request and similar) that dialog arrives
# before the elevation is active and cannot be answered. Worse, the privileged install leaves
# Cursor.app owned by root, so the next update needs admin again.
#
# This script does the update on demand, once elevation is active: it asks Cursor's own update
# feed for the latest build, downloads it, checks the code signature, quits Cursor, swaps the
# bundle and reopens it. With --move it also relocates Cursor to ~/Applications, which the user
# owns, and from then on Cursor's built-in updater works with no password at all.
#
# Usage:
#   cursor-update.sh              update if a newer build exists
#   cursor-update.sh --check      print installed and latest versions, change nothing
#   cursor-update.sh --move       also move Cursor to ~/Applications (one-time fix)
#   cursor-update.sh --force      reinstall even when already on the latest build
#   cursor-update.sh --dry-run    download and verify, but do not touch the installed app
#   cursor-update.sh --gui        dialogs and notifications instead of terminal output
#                                 (what the "Update Cursor" app runs)
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BUNDLE_ID="com.todesktop.230313mzl4w4u92"
TEAM_ID="VDXQ22DGB9"
FEED="https://api2.cursor.sh/updates/api/update"
SYSTEM_APP="/Applications/Cursor.app"
USER_APP="$HOME/Applications/Cursor.app"
CACHE="$HOME/Library/Caches/cursor-update"
LOG="$HOME/Library/Logs/cursor-update.log"
ELEVATION_APP="/Applications/Admin By Request.app"
TITLE="Update Cursor"

# --- privileged half -------------------------------------------------------------------------
# Runs as root through the macOS admin dialog. Only whole bundles are renamed, never files
# inside one, and the old bundle is kept until the new one is in place.
#   --_install <new bundle or ""> <current> <destination> <backup> <owner>
if [ "${1:-}" = "--_install" ]; then
    new="$2" current="$3" dest="$4" backup="$5" owner="$6"
    mv "$current" "$backup"
    if [ -n "$new" ]; then
        mv "$new" "$dest" || { mv "$backup" "$current"; exit 1; }
    else
        mv "$backup" "$dest" || { mv "$backup" "$current"; exit 1; }
    fi
    chown -R "$owner" "$dest"
    rm -rf "$backup" 2>/dev/null || true
    exit 0
fi

CHECK=0 MOVE=0 FORCE=0 DRY=0 GUI=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;; --move) MOVE=1 ;; --force) FORCE=1 ;;
        --dry-run) DRY=1 ;; --gui) GUI=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

mkdir -p "$CACHE" "$(dirname "$LOG")"
[ "$GUI" = 1 ] && exec >>"$LOG" 2>&1
log() { printf '%s %s\n' "$(date '+%F %T')" "$1"; }

# One run at a time: a second click on the app while the first is downloading does nothing.
if [ "$CHECK" = 0 ]; then
    LOCK="$CACHE/.running"
    if ! mkdir "$LOCK" 2>/dev/null; then
        if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then log "already running"; exit 0; fi
        rm -rf "$LOCK"; mkdir "$LOCK"
    fi
    echo $$ >"$LOCK/pid"
    trap 'rm -rf "$LOCK"' EXIT
fi

# --- user interface: terminal or dialogs ----------------------------------------------------
notify() {
    log "$1"
    [ "$GUI" = 1 ] && osascript -e 'on run a' -e 'display notification (item 1 of a) with title (item 2 of a)' \
        -e 'end run' "$1" "$TITLE" >/dev/null 2>&1 || true
}
# ask <message> <button>...: prints the button pressed (the last one is the default),
# or "Cancel". In the terminal it never asks and answers with the default.
ask() {
    local msg="$1"; shift
    if [ "$GUI" != 1 ]; then printf '%s\n' "${@: -1}"; return; fi
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
fail() {
    log "ERROR: $1"
    if [ "$GUI" = 1 ]; then ask "$1" "OK" >/dev/null; else echo "error: $1" >&2; fi
    exit 1
}

running() { pgrep -f "Cursor.app/Contents/MacOS/Cursor\$" >/dev/null 2>&1; }

# --- where is Cursor, and which version --------------------------------------------------------
if [ -d "$USER_APP" ]; then CURRENT="$USER_APP"
elif [ -d "$SYSTEM_APP" ]; then CURRENT="$SYSTEM_APP"
else fail "Cursor.app is in neither /Applications nor ~/Applications."
fi
INSTALLED="$(defaults read "$CURRENT/Contents/Info.plist" CFBundleShortVersionString)"
case "$(uname -m)" in arm64) PLATFORM=darwin-arm64 ;; *) PLATFORM=darwin-x64 ;; esac

# The same feed Squirrel polls: 204 means "no newer build", 200 returns {"url", "name"}.
# Asking on behalf of version 0.0.0 always returns the latest build, which --force needs.
feed() {
    curl -fsS -m 30 -w '\n%{http_code}' "$FEED/$PLATFORM/cursor/$1/0/stable"
}
RESP="$(feed "$INSTALLED")" || fail "Could not reach Cursor's update server."
if [ "$(tail -n1 <<<"$RESP")" = 200 ]; then UPDATE=1; else UPDATE=0; fi
[ "$FORCE" = 1 ] && { RESP="$(feed 0.0.0)" || fail "Could not reach Cursor's update server."; UPDATE=1; }
if [ "$UPDATE" = 1 ]; then
    JSON="$(sed '$d' <<<"$RESP")"
    LATEST="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["name"])' <<<"$JSON")"
    ZIP_URL="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["url"])' <<<"$JSON")"
else
    LATEST="$INSTALLED"
fi

ADMIN=0; dseditgroup -o checkmember -m "$USER" admin >/dev/null 2>&1 && ADMIN=1
if [ "$CHECK" = 1 ]; then
    echo "installed:  $INSTALLED  ($CURRENT, owner $(stat -f %Su "$CURRENT"))"
    echo "latest:     $LATEST$([ "$UPDATE" = 1 ] && [ "$FORCE" = 0 ] && echo '  <- update available')"
    echo "admin now:  $([ "$ADMIN" = 1 ] && echo yes || echo no)"
    if [ "$CURRENT" = "$SYSTEM_APP" ]; then
        echo "updates:    need admin (lives in /Applications). Run once with --move to fix that."
    else
        echo "updates:    Cursor updates itself, no admin needed."
    fi
    exit 0
fi

log "installed $INSTALLED at $CURRENT, latest $LATEST, update=$UPDATE force=$FORCE move=$MOVE admin=$ADMIN"

# --- decide what to do ---------------------------------------------------------------------------
if [ "$CURRENT" = "$SYSTEM_APP" ] && [ "$MOVE" = 0 ] && [ "$GUI" = 1 ]; then
    if [ "$UPDATE" = 1 ]; then
        msg="Cursor $LATEST is available (installed: $INSTALLED). Cursor will close and reopen.

Cursor lives in /Applications, so every update needs admin rights. Moving it to your own Applications folder lets it update itself from now on, with no password."
        choice="$(ask "$msg" "Cancel" "Update only" "Update and move")"
    else
        msg="Cursor $INSTALLED is already the latest version.

It lives in /Applications, so every update needs admin rights. Move it to your own Applications folder, so it updates itself from now on? Cursor will close and reopen."
        choice="$(ask "$msg" "Not now" "Move it")"
    fi
    case "$choice" in
        "Update and move"|"Move it") MOVE=1 ;;
        "Update only") ;;
        *) log "cancelled"; exit 0 ;;
    esac
elif [ "$UPDATE" = 1 ] && [ "$GUI" = 1 ]; then
    [ "$(ask "Cursor $LATEST is available (installed: $INSTALLED). Cursor will close and reopen." \
        "Cancel" "Update")" = Update ] || { log "cancelled"; exit 0; }
fi

[ "$CURRENT" != "$SYSTEM_APP" ] && MOVE=0
if [ "$UPDATE" = 0 ] && [ "$MOVE" = 0 ]; then
    notify "Cursor $INSTALLED is already the latest version."
    [ "$GUI" = 1 ] || echo "Cursor $INSTALLED is already the latest version."
    exit 0
fi
if [ "$MOVE" = 1 ]; then DEST="$USER_APP"; mkdir -p "$HOME/Applications"; else DEST="$CURRENT"; fi

# Run from Cursor's own terminal, the script would die with Cursor halfway through the swap.
if [ "$DRY" = 0 ] && [ "$GUI" = 0 ] && [ "${TERM_PROGRAM:-}" = vscode ] && running; then
    fail "Run this outside Cursor (it closes Cursor halfway), or open the 'Update Cursor' app."
fi

# --- download and verify ---------------------------------------------------------------------------
NEW=""
if [ "$UPDATE" = 1 ]; then
    STAGE="$CACHE/$LATEST"
    ZIP="$CACHE/Cursor-$LATEST-$PLATFORM.zip"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    if [ ! -s "$ZIP" ]; then
        find "$CACHE" -maxdepth 1 -name '*.zip*' -delete
        notify "Downloading Cursor $LATEST..."
        curl -fL -sS -m 900 -o "$ZIP.part" "$ZIP_URL" || fail "Download failed: $ZIP_URL"
        mv "$ZIP.part" "$ZIP"
    fi
    ditto -x -k "$ZIP" "$STAGE" || { rm -f "$ZIP"; fail "The download is corrupt, run it again."; }
    NEW="$STAGE/Cursor.app"
    [ -d "$NEW" ] || fail "The download does not contain Cursor.app."
    codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "Code signature check failed, not installing."
    [ "$(codesign -dv "$NEW" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$TEAM_ID" ] \
        || fail "The download is not signed by Cursor's developer, not installing."
    [ "$(defaults read "$NEW/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
        || fail "The download is not Cursor, not installing."
    log "verified $NEW ($(defaults read "$NEW/Contents/Info.plist" CFBundleShortVersionString), team $TEAM_ID)"
fi
if [ "$DRY" = 1 ]; then
    echo "dry run: would install ${NEW:-the current bundle} at $DEST$([ "$MOVE" = 1 ] && echo ", removing $CURRENT")"
    exit 0
fi

# --- admin rights, only when the swap needs them -------------------------------------------------
NEED_ROOT=0
for p in "$CURRENT" "$(dirname "$CURRENT")" "$(dirname "$DEST")"; do [ -w "$p" ] || NEED_ROOT=1; done
[ "$(stat -f %u "$CURRENT")" = "$(id -u)" ] || NEED_ROOT=1
while [ "$NEED_ROOT" = 1 ] && ! dseditgroup -o checkmember -m "$USER" admin >/dev/null 2>&1; do
    [ "$GUI" = 1 ] || fail "Admin rights are not active. Request elevation (Admin By Request) and run this again."
    if [ -d "$ELEVATION_APP" ]; then
        choice="$(ask "Admin rights are not active yet.

Request elevation in $(basename "$ELEVATION_APP" .app), then press Continue." \
            "Cancel" "Open $(basename "$ELEVATION_APP" .app)" "Continue")"
    else
        choice="$(ask "Admin rights are not active yet. Get them, then press Continue." "Cancel" "Continue")"
    fi
    case "$choice" in
        Continue) ;;
        Open*) open "$ELEVATION_APP" ;;
        *) log "cancelled waiting for admin"; exit 0 ;;
    esac
done

# --- quit, swap, reopen ------------------------------------------------------------------------------
WAS_RUNNING=0
if running; then
    WAS_RUNNING=1
    notify "Closing Cursor..."
    while :; do
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 60); do running || break; sleep 0.5; done
        running || break
        [ "$GUI" = 1 ] || fail "Cursor did not close (unsaved changes?). Close it and run this again."
        [ "$(ask "Cursor did not close, probably because of unsaved changes. Save or discard them, then press Retry." \
            "Cancel" "Retry")" = Retry ] || { log "cancelled, Cursor still open"; exit 0; }
    done
fi

BACKUP="$CACHE/Cursor.previous.$$.app"
OWNER="$(id -un)"
if [ "$NEED_ROOT" = 1 ]; then
    cmd="$(printf '%q ' /bin/bash "$SELF" --_install "$NEW" "$CURRENT" "$DEST" "$BACKUP" "$OWNER")"
    osascript - "$cmd" <<'OSA' || INSTALL_FAILED=1
on run argv
    do shell script (item 1 of argv) with prompt "Update Cursor needs admin rights to replace Cursor.app." with administrator privileges
end run
OSA
else
    /bin/bash "$SELF" --_install "$NEW" "$CURRENT" "$DEST" "$BACKUP" "$OWNER" || INSTALL_FAILED=1
fi

if [ "${INSTALL_FAILED:-0}" = 1 ] || [ ! -d "$DEST" ]; then
    [ "$WAS_RUNNING" = 1 ] && [ -d "$CURRENT" ] && env -u ELECTRON_RUN_AS_NODE open "$CURRENT"
    fail "Cursor.app could not be replaced, the previous version is still in place. If macOS said 'Operation not permitted', allow this app under System Settings > Privacy & Security > App Management (needs admin) and try again. Log: $LOG"
fi
rm -rf "$CACHE"/*.zip "$CACHE"/[0-9]* 2>/dev/null || true
log "installed $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString) at $DEST"

[ "$WAS_RUNNING" = 1 ] && env -u ELECTRON_RUN_AS_NODE open "$DEST"
done_msg="Cursor $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString) installed"
[ "$MOVE" = 1 ] && done_msg="$done_msg in ~/Applications. From now on it updates itself, no admin needed"
notify "$done_msg."
[ "$GUI" = 1 ] || echo "$done_msg."
