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
    // Freeing already handled by session, just remove the reference.
    hid_provider = null;
}

pub fn handleEvent(session: *c.IHS_Session, event: *const c.SDL_Event) bool {
    return c.IHS_HIDHandleSDLEvent(session, event);
}
