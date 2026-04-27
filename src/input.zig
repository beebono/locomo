const std = @import("std");
const c = @import("c.zig").c;

var hid_provider: ?*c.IHS_HIDProvider = null;

pub fn init(session: *c.IHS_Session) void {
    const provider = c.IHS_HIDProviderSDLCreateManaged() orelse return;
    hid_provider = provider;
    c.IHS_SessionHIDAddProvider(session, provider);
    _ = c.IHS_SessionHIDNotifyDeviceChange(session);
}

pub fn deinit() void {
    if (hid_provider) |p| {
        c.IHS_HIDProviderSDLDestroy(p);
        hid_provider = null;
    }
}

// Called from the main SDL event loop during streaming.
// Returns true if the event was consumed by HID, false if the caller should
// still inspect it (e.g. for the quit button).
pub fn handleEvent(session: *c.IHS_Session, event: *const c.SDL_Event) bool {
    return c.IHS_HIDHandleSDLEvent(session, event);
}
