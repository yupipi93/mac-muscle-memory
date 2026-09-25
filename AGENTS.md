# mac-muscle-memory: agent entrypoint

You are working on the configuration of a specific physical machine. This repository is the
single source of truth for how that machine is set up, what has already been tried, and what
is known not to work.

## Read this first

1. `personal/` if it exists: this machine's private data (hardware, displays, keyboard remaps,
   backups, machine-specific open items). It is gitignored. Then the macOS version in
   `sw_vers`. Several behaviours in this
   repo depend on the exact macOS version, so check it before assuming anything.
2. `docs/macos-27-notes.md` before automating any window, Space or input behaviour. It records
   which macOS APIs are broken on this build and which workarounds replaced them. Skipping it
   means rediscovering the same dead ends.
3. `OPEN-ITEMS.md` for work that is unfinished or unverified.
4. `docs/manual-steps.md` for the settings no agent can apply, because macOS requires a human
   click. Never claim one of these is done. Ask the user to do it and confirm.

## Operating rules

- **Verify, do not assume.** macOS APIs on this build lie. `hs.spaces.gotoSpace` returns an
  error, `hs.spaces.moveWindowToSpace` returns success and does nothing. Always read the state
  back after writing it, with an independent probe where possible.
- **Record every change.** Any setting you apply goes into `bin/apply.sh` and `docs/settings.md`
  in the same session, with the reason. An undocumented change is drift. A change to a shortcut
  also goes into `docs/shortcuts.html`, the printable card, and it must still fit on one A4 page
  (check with headless Chrome `--print-to-pdf`). A new tool, or a change to one, goes into
  `docs/tools.md`.
- **The keyboard can be part of the solution.** A programmable keyboard stores its own key map
  in firmware, so "key X should send key Y" can be done there: it works before login and in
  Secure Input fields, and does not depend on Hammerspoon. The strongest option combines both:
  the keyboard emits a key macOS understands (an unused F13 to F19) and `hammerspoon/init.lua`
  binds the behaviour. A firmware remap is invisible to this repo: record it in
  `personal/keyboard.md`. Sniff a key with `hs.eventtap` before concluding what it sends.
- **Machine-specific goes to `personal/`, generic goes to `docs/`.** `personal/` is gitignored and
  holds the owner's identifiers, device state, backups and anything about their workplace; keep
  it current as you work, it is the only record of those facts. `personal.example/` is the
  public template for other users; keep it in step when `personal/` gains a new kind of file.
- **Keep personal data out.** This repository is meant to be public. No serial numbers,
  hardware UUIDs, email addresses, absolute home paths, employer names or anything about the
  owner's workplace. Write `<repo>` or `$HOME` instead of a real path, and "the owner" instead
  of a name. Grep before every commit.
- **Headless Chrome leaves Dock clutter.** Every `Google Chrome --headless` run (the card's PDF
  and screenshot checks) registers as a recent app, and the Dock's recent-apps section fills with
  extra Chrome icons. Clear it afterwards with
  `defaults write com.apple.dock recent-apps -array && killall Dock`.
- **Prefer reversible steps.** Back up before overwriting, and say where the backup is.
- **State what you could not verify.** Some changes only take effect after a logout or a
  restart. Say so rather than reporting success.

## Applying this configuration

```bash
bin/apply.sh          # idempotent, safe to re-run
bin/capture.sh        # prints current values against expected ones, for drift checks
```

`bin/apply.sh` covers everything that can be scripted. It deliberately stops short of the
items in `docs/manual-steps.md`, and prints them as a reminder at the end.

## Replicating on another machine

The repository lives at **https://github.com/yupipi93/mac-muscle-memory**.

1. Clone it anywhere, install Homebrew, then run `bin/apply.sh`. Nothing depends on the clone
   path: the scripts and `init.lua` work out where the repo is.
2. Grant Hammerspoon the Accessibility permission (see `docs/manual-steps.md`). Nothing that
   drives the window manager works until this is granted.
3. Work through `docs/manual-steps.md` in order.
4. Run `bin/capture.sh` and reconcile any differences.

The display layout in `personal/machine.md` is specific to one machine. Anything that hardcodes
screen coordinates must be re-checked on different hardware.

## Conventions

- Files in this repository are written in English. The Hammerspoon config keeps its original
  Spanish comments.
- Never write the Unicode em dash in generated text.
- Shell scripts are POSIX-ish bash, run under zsh on this machine. Beware: zsh does not word
  split unquoted variables the way bash does.
