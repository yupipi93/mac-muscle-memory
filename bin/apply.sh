#!/usr/bin/env bash
# Applies every machine setting that can be scripted. Idempotent, safe to re-run.
# The steps that macOS only allows a human to perform are listed at the end.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()  { printf '  ok   %s\n' "$1"; }
warn(){ printf '  warn %s\n' "$1"; }

say "Input"
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
ok "natural scrolling off (wheel behaves like Windows and Linux)"

say "Spaces and animations"
defaults write com.apple.dock mru-spaces -bool false
ok "desktops keep a fixed order"
defaults write com.apple.dock workspaces-swoosh-animation-off -bool true
ok "desktop switch animation off (needs a session restart)"
defaults write com.apple.dock workspaces-edge-delay -float 0.05
ok "edge delay shortened"
defaults write com.apple.dock expose-animation-duration -float 0.001
ok "Mission Control animation shortened"
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
ok "window resize animation shortened"

# Screenshots land in ~/Pictures/Screenshots instead of burying the Desktop. The folder has
# to exist first: screencapture does not create it and silently falls back to the Desktop.
mkdir -p "$HOME/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"
killall SystemUIServer 2>/dev/null || true
ok "screenshots saved to ~/Pictures/Screenshots"

# Switching desktops is Ctrl+Cmd+Left / Right instead of the default Ctrl+Left / Right, to free
# Ctrl+Arrow for other uses. Symbolic hotkeys 79 and 81. The mask is ctrl | cmd | the fn-key
# bit the system itself stores on arrow shortcuts. helper/spaceswitch, the only injector left,
# sends this same combination; change them together.
python3 - <<'PYEOF'
import plistlib, subprocess
d = plistlib.loads(subprocess.run(["defaults", "export", "com.apple.symbolichotkeys", "-"],
                                  capture_output=True, check=True).stdout)
hk = d.setdefault("AppleSymbolicHotKeys", {})
mask = 0x40000 | 0x100000 | 0x800000
for key, arrow in (("79", 123), ("81", 124)):
    hk[key] = {"enabled": True, "value": {"parameters": [65535, arrow, mask], "type": "standard"}}
# 27, "move focus to next window" of the same app: Option+Tab instead of Cmd+`, like
# Alt+` on GNOME. Frees Cmd+` for Ghostty's Quick Terminal. Shift reverses it.
hk["27"] = {"enabled": True, "value": {"parameters": [65535, 48, 0x80000], "type": "standard"}}
subprocess.run(["defaults", "import", "com.apple.symbolichotkeys", "-"], input=plistlib.dumps(d), check=True)
PYEOF
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u >/dev/null 2>&1 || true
ok "desktop switch set to Ctrl+Cmd+Arrow, next window of an app to Option+Tab"

say "Tooling"
if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew missing. Install it first, then re-run this script."
    exit 1
fi
# cliclick is no longer used at runtime (since 2026-09-24); kept as a manual debugging tool.
if command -v cliclick >/dev/null 2>&1; then
    ok "cliclick already installed"
else
    brew install cliclick
    ok "cliclick installed"
fi
if [ -d /Applications/Hammerspoon.app ]; then
    ok "Hammerspoon already installed"
else
    brew install --cask hammerspoon
    ok "Hammerspoon installed"
fi

# Ghostty, the terminal, plus the Nerd Font its config asks for. See docs/tools.md.
if [ -d /Applications/Ghostty.app ]; then
    ok "Ghostty already installed"
else
    brew install --cask ghostty
    ok "Ghostty installed"
fi
# GNU nano: macOS's /usr/bin/nano is really pico, with no line numbers and no colours.
if brew list nano >/dev/null 2>&1; then
    ok "GNU nano already installed"
else
    brew install nano
    ok "GNU nano installed"
fi
if brew list --cask font-meslo-lg-nerd-font >/dev/null 2>&1; then
    ok "MesloLGS Nerd Font already installed"
else
    brew install --cask font-meslo-lg-nerd-font
    ok "MesloLGS Nerd Font installed"
fi

say "noswoosh"
# Switches desktop in ~130 ms against the ~1165 ms native animation, which macOS 27 no longer
# exposes any setting for. Installed into ~/Applications rather than /Applications because the
# Homebrew cask needs sudo to write there and we cannot prompt for a password.
#
# Deliberately NOT running `noswoosh setup` and NOT installing its LaunchAgent. setup disables
# the system Ctrl+arrow shortcuts (symbolic hotkeys 79 and 81), and moving a window between
# desktops depends on those firing during a drag. Run `noswoosh teardown` if they ever get
# disabled by accident.
NOSWOOSH_APP="$HOME/Applications/noswoosh.app"
if [ -d "$NOSWOOSH_APP" ]; then
    ok "already installed at $NOSWOOSH_APP"
else
    NOSWOOSH_VERSION="1.7.5"
    NOSWOOSH_SHA="d75fdefc62c3c73a31faf182a671f4129ce280e0e2e29f39407f94962ea1c141"
    TMP_ZIP="$(mktemp -t noswoosh).zip"
    URL="https://github.com/mmathys/noswoosh/releases/download/v${NOSWOOSH_VERSION}/noswoosh-${NOSWOOSH_VERSION}.app.zip"
    if curl -fsSL "$URL" -o "$TMP_ZIP"; then
        if [ "$(shasum -a 256 "$TMP_ZIP" | cut -d' ' -f1)" = "$NOSWOOSH_SHA" ]; then
            mkdir -p "$HOME/Applications"
            ditto -x -k "$TMP_ZIP" "$HOME/Applications/" && ok "installed $NOSWOOSH_VERSION"
        else
            warn "checksum mismatch, not installing"
        fi
        rm -f "$TMP_ZIP"
    else
        warn "download failed, desktop switching falls back to the slower helper"
    fi
fi

say "Space switch helper"
HELPER_SRC="$REPO/helper/spaceswitch.c"
HELPER_BIN="$REPO/helper/spaceswitch"
if [ ! -f "$HELPER_SRC" ]; then
    warn "helper source missing, desktop switching will fall back to nothing"
elif [ -x "$HELPER_BIN" ] && [ "$HELPER_BIN" -nt "$HELPER_SRC" ]; then
    ok "already built"
else
    # The installed Command Line Tools cannot parse the newer MacOSX27 SDK, so build against
    # whichever older SDK is present. The resulting binary runs fine on macOS 27.
    SDK=""
    for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.sdk; do
        if [ -d "/Library/Developer/CommandLineTools/SDKs/$candidate" ]; then
            SDK="/Library/Developer/CommandLineTools/SDKs/$candidate"
            break
        fi
    done
    if [ -n "$SDK" ]; then
        clang -O2 -Wall -isysroot "$SDK" -framework ApplicationServices \
              -o "$HELPER_BIN" "$HELPER_SRC" && ok "built against $(basename "$SDK")"
    else
        clang -O2 -Wall -framework ApplicationServices -o "$HELPER_BIN" "$HELPER_SRC" \
            && ok "built against the default SDK" \
            || warn "build failed, see docs/macos-27-notes.md for the SDK workaround"
    fi
fi

# Cursor-shape probe for the middle-click paste in apps that expose no Accessibility.
CK_SRC="$REPO/helper/cursorkind.m"
CK_BIN="$REPO/helper/cursorkind"
if [ -x "$CK_BIN" ] && [ "$CK_BIN" -nt "$CK_SRC" ]; then
    ok "cursorkind already built"
else
    CK_SDK=""
    for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.sdk; do
        [ -d "/Library/Developer/CommandLineTools/SDKs/$candidate" ] && { CK_SDK="/Library/Developer/CommandLineTools/SDKs/$candidate"; break; }
    done
    clang -O2 -Wall -fobjc-arc ${CK_SDK:+-isysroot "$CK_SDK"} -framework AppKit -o "$CK_BIN" "$CK_SRC" \
        && ok "cursorkind built" || warn "cursorkind build failed; middle-click paste falls back to Accessibility only"
fi

# Symlink a config file from this repo into place, backing up whatever was there.
link_config() {
    local source="$1" target="$2" label="$3"
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
        ok "$label already linked to this repo"
        return
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        local backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$target" "$backup"
        warn "existing $label moved to $backup"
    fi
    ln -s "$source" "$target"
    ok "$label linked to this repo"
}

say "Config files"
link_config "$REPO/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua" "Hammerspoon init.lua"
link_config "$REPO/ghostty/config" "$HOME/.config/ghostty/config" "Ghostty config"
link_config "$REPO/nano/nanorc" "$HOME/.nanorc" "nano config"
# Ghostty also reads this second location and it wins over the first. Keep it out of the way
# so the repo file is the only source of truth.
GHOSTTY_AS="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
if [ -e "$GHOSTTY_AS" ] && [ ! -L "$GHOSTTY_AS" ]; then
    mv "$GHOSTTY_AS" "$GHOSTTY_AS.bak-$(date +%Y%m%d-%H%M%S)"
    warn "second Ghostty config moved aside, the repo config is now the only one"
fi

say "Restarting Dock"
killall Dock 2>/dev/null || true
ok "Dock restarted so the settings above take effect"

if command -v hs >/dev/null 2>&1 && pgrep -x Hammerspoon >/dev/null 2>&1; then
    say "Hammerspoon runtime"
    # Hammerspoon's IPC occasionally blocks, so cap each call. macOS ships no timeout(1).
    hsq() { perl -e 'alarm 5; exec @ARGV' hs -c "$1" >/dev/null 2>&1; }
    hsq "hs.autoLaunch(true)" && ok "set to launch at login" || warn "could not reach Hammerspoon over IPC"
    hsq "hs.reload()" || true
    ok "config reloaded"
else
    warn "Hammerspoon is not running, start it and it will pick up the linked config"
fi

cat <<'EOF'

Done with everything that can be scripted.

These still need a human, see docs/manual-steps.md:
  1. Grant Hammerspoon the Accessibility permission. Nothing works until this is done.
  2. Grant Hammerspoon Screen Recording, for the Print Screen shortcut.
  3. Turn on System Settings > Accessibility > Motion > Reduce motion.
  4. Create your desktops with Mission Control (F3) and the + button.
  5. Log out and back in, so the desktop switch animation setting is picked up.

Then run bin/capture.sh to confirm the machine matches what this repo expects.

EOF
