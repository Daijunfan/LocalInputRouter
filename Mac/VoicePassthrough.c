#include <ApplicationServices/ApplicationServices.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

// Scoped to the router's bundled Deskflow process. Marked local speech keys
// bypass its remote forwarding callback; every other event uses it unchanged.
typedef struct { CGEventTapCallBack callback; void *context; } TapContext;
static const int64_t rdpPointerMarker=0x444A4652445050LL;
static int cursorHides=0, requestedHidden=0, rdpPointer=0;
static void setRDPPointer(int enabled) {
    if(rdpPointer==enabled)return;
    rdpPointer=enabled;
    if(enabled) {
        while(cursorHides>0){CGDisplayShowCursor(CGMainDisplayID());cursorHides--;}
        CGAssociateMouseAndMouseCursorPosition(true);
    } else if(requestedHidden && cursorHides==0) {
        if(CGDisplayHideCursor(CGMainDisplayID())==kCGErrorSuccess)cursorHides++;
    }
}
static CGError hideCursor(CGDirectDisplayID display) {
    requestedHidden=1;
    if(rdpPointer)return kCGErrorSuccess;
    CGError result=CGDisplayHideCursor(display);
    if(result==kCGErrorSuccess)cursorHides++;
    return result;
}
static CGError showCursor(CGDirectDisplayID display) {
    requestedHidden=0;
    if(cursorHides==0)return kCGErrorSuccess;
    CGError result=CGDisplayShowCursor(display);
    if(result==kCGErrorSuccess)cursorHides--;
    return result;
}
static CGError associateCursor(boolean_t enabled) {
    return CGAssociateMouseAndMouseCursorPosition(rdpPointer ? true : enabled);
}
static CGEventRef route(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *value) {
    TapContext *tap=value;
    if(event && CGEventGetIntegerValueField(event,kCGEventSourceUserData)==rdpPointerMarker) {
        setRDPPointer(1);
        return event; // Windows App handles coordinates/clicks for its own RDP window.
    }
    if(type==kCGEventMouseMoved || type==kCGEventLeftMouseDown || type==kCGEventLeftMouseUp
       || type==kCGEventLeftMouseDragged || type==kCGEventRightMouseDown || type==kCGEventRightMouseUp
       || type==kCGEventRightMouseDragged || type==kCGEventOtherMouseDown || type==kCGEventOtherMouseUp
       || type==kCGEventOtherMouseDragged)setRDPPointer(0);
    if(event && (CGEventGetIntegerValueField(event,kCGEventSourceUserData)&~0xffLL)==0x444A46564F494300LL) {
        // The final local guard still needs this marker to admit the key.
        return event;
    }
    return tap->callback(proxy,type,event,tap->context);
}
static CFMachPortRef createTap(CGEventTapLocation location,CGEventTapPlacement place,
    CGEventTapOptions options,CGEventMask mask,CGEventTapCallBack callback,void *context) {
    if(location!=kCGHIDEventTap || options!=kCGEventTapOptionDefault)
        return CGEventTapCreate(location,place,options,mask,callback,context);
    TapContext *tap=malloc(sizeof(*tap));if(!tap)return NULL;
    *tap=(TapContext){callback,context};
    CFMachPortRef port=CGEventTapCreate(location,place,options,mask,route,tap);
    if(!port)free(tap); // Successful contexts live with the backend process.
    return port;
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement,*original;} hooks[]={
    {(void*)createTap,(void*)CGEventTapCreate},
    {(void*)hideCursor,(void*)CGDisplayHideCursor},
    {(void*)showCursor,(void*)CGDisplayShowCursor},
    {(void*)associateCursor,(void*)CGAssociateMouseAndMouseCursorPosition}
};
__attribute__((constructor)) static void loaded(void) {
    const char message[]="Local input voice passthrough loaded\n";
    write(STDERR_FILENO,message,sizeof(message)-1);
}
