#include "Cursor.h"
#include <ApplicationServices/ApplicationServices.h>

// Same WindowServer interface used by the bundled Deskflow backend.
extern int _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(int connection, int target,
                                      CFStringRef key, CFTypeRef value);

int DJFAllowBackgroundCursor(void) {
    int connection = _CGSDefaultConnection();
    return CGSSetConnectionProperty(connection, connection,
                                   CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
}

int DJFCursorIsVisible(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGCursorIsVisible();
#pragma clang diagnostic pop
}
