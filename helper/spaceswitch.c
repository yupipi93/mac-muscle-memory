// Posts Ctrl+Cmd+Left / Ctrl+Cmd+Right so WindowServer honours it as the Space-switching
// shortcut. It was Ctrl+Arrow until 2026-09-24, when the native binding (symbolic hotkeys 79
// and 81) moved to Ctrl+Cmd+Arrow to free Ctrl+Arrow for other uses.
// Exists purely for speed: cliclick does the same job but spends around 450 ms per invocation
// in internal delays, which dominated the latency between turning the wheel and the desktop
// starting to change.
//
// This mirrors what cliclick actually does, which is not what it looks like from the outside:
//   - plain keyboard events, NULL source, posted to kCGSessionEventTap. Not the HID tap.
//   - Control and Command are pressed as real keys. With one modifier no flags were needed;
//     with two, each event must also carry the accumulated flags (see main). Setting kCGEventFlagMaskControl on the arrow instead, without a real
//     Control key event, is exactly why hs.eventtap.keyStroke does nothing here.
//
// Must be launched by a process holding the Accessibility permission (Hammerspoon), so the
// child inherits the grant. Run from a plain shell it silently does nothing.
//
// usage: spaceswitch left|right [gap_ms]
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void post(CGKeyCode key, bool down, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, down);
    if (!event) return;
    CGEventSetFlags(event, flags);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;

    CGKeyCode arrow;
    if (strcmp(argv[1], "left") == 0)       arrow = 123;
    else if (strcmp(argv[1], "right") == 0) arrow = 124;
    else return 2;

    useconds_t gap = 12000;
    if (argc >= 3) gap = (useconds_t)(atoi(argv[2]) * 1000);

    const CGKeyCode CONTROL = 59;
    const CGKeyCode COMMAND = 55;
    // Flags accumulate exactly as a physical keyboard reports them. With Control alone the
    // system derived the modifier from the real key event; with two modifiers it does not, so
    // each event now carries the modifiers held at that moment. The arrow also carries the
    // secondary-fn bit, which is how the system itself stores arrow shortcuts.
    const CGEventFlags CTRL = kCGEventFlagMaskControl;
    const CGEventFlags CMD = kCGEventFlagMaskCommand;
    const CGEventFlags FN = kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad;
    post(CONTROL, true, CTRL);
    post(COMMAND, true, CTRL | CMD);
    usleep(gap);
    post(arrow, true, CTRL | CMD | FN);
    post(arrow, false, CTRL | CMD | FN);
    usleep(gap);
    post(COMMAND, false, CTRL);
    post(CONTROL, false, 0);

    return 0;
}
