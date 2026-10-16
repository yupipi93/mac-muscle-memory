#!/usr/bin/env bash
# Builds ~/Applications/Update Cursor.app, the one-click front end for bin/cursor-update.sh.
# The app carries its own copy of the script, so it keeps working wherever this repo lives.
# Re-run (or run bin/apply.sh) after changing bin/cursor-update.sh. Idempotent.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/bin/cursor-update.sh"
APP="$HOME/Applications/Update Cursor.app"

if cmp -s "$SRC" "$APP/Contents/Resources/cursor-update.sh" 2>/dev/null; then
    echo "already up to date: $APP"
    exit 0
fi

rm -rf "$APP"
mkdir -p "$HOME/Applications"
# The script runs detached, so it survives Cursor closing and the applet quits at once.
osacompile -o "$APP" -e 'do shell script "/bin/bash " & quoted form of (POSIX path of (path to resource "cursor-update.sh")) & " --gui >/dev/null 2>&1 &"'
cp "$SRC" "$APP/Contents/Resources/cursor-update.sh"
for cursor in "$HOME/Applications/Cursor.app" /Applications/Cursor.app; do
    if [ -f "$cursor/Contents/Resources/Cursor.icns" ]; then
        cp "$cursor/Contents/Resources/Cursor.icns" "$APP/Contents/Resources/applet.icns"
        # The asset catalog osacompile writes would win over applet.icns.
        rm -f "$APP/Contents/Resources/Assets.car"
        plutil -remove CFBundleIconName "$APP/Contents/Info.plist"
        break
    fi
done
# Adding files broke the ad hoc signature osacompile made; sign again so Gatekeeper runs it.
codesign --force --sign - "$APP" >/dev/null 2>&1
touch "$APP"
echo "built: $APP"
