// Prints "ibeam" when the system is showing the text cursor, "other" otherwise.
//
// Used by the middle-click paste in hammerspoon/init.lua. Chrome and Electron apps expose
// nothing through Accessibility about what is under the pointer, so a text field cannot be told
// from a link or a tab. The cursor shape can: apps show the I-beam over editable or selectable
// text, a pointing hand over links, an arrow over tabs and chrome.
//
// usage: cursorkind
#import <AppKit/AppKit.h>

static BOOL sameCursor(NSCursor *a, NSCursor *b) {
    if (!a || !b) return NO;
    NSPoint ha = a.hotSpot, hb = b.hotSpot;
    NSSize sa = a.image.size, sb = b.image.size;
    if (NSEqualPoints(ha, hb) && NSEqualSizes(sa, sb)) {
        NSData *da = [a.image TIFFRepresentation], *db = [b.image TIFFRepresentation];
        return [da isEqualToData:db];
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        // Without an NSApplication the reference cursors come back empty (0x0).
        [NSApplication sharedApplication];
        NSCursor *current = [NSCursor currentSystemCursor];
        BOOL ibeam = sameCursor(current, [NSCursor IBeamCursor]) ||
                     sameCursor(current, [NSCursor IBeamCursorForVerticalLayout]);
        if (!ibeam && current) {
            // Some apps draw their own I-beam at another scale: fall back to geometry. The
            // system I-beam is tall and narrow with its hot spot in the middle.
            NSSize s = current.image.size; NSPoint h = current.hotSpot;
            NSSize is = [NSCursor IBeamCursor].image.size;
            if (s.height > 0 && fabs(s.width / s.height - is.width / is.height) < 0.08 &&
                fabs(h.x - s.width / 2) < 2.5 && fabs(h.y - s.height / 2) < 3.5) ibeam = YES;
        }
        printf("%s\n", ibeam ? "ibeam" : "other");
    }
    return 0;
}
