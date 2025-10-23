const std = @import("std");
const log = @import("log.zig");
const shutter = @import("shutter");

const Allocator = std.mem.Allocator;

const REGISTRY = 2;
const CALLBACK = 3;
const COMPOSITOR = 4;
const SHM = 5;
const XDG_WM_BASE = 6;
const SURFACE = 7;
const XDG_SURFACE = 8;
const XDG_TOPLEVEL = 9;
const CALLBACK2 = 10;
const SHM_POOL = 11;
const BUFFER = 12;

const Epoll = struct {
    fd: std.posix.fd_t,

    const Self = @This();

    pub fn init(socket_fd: std.posix.fd_t) !Self {
        const fd = try std.posix.epoll_create1(0);

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = 0 },
        };

        try std.posix.epoll_ctl(fd, std.os.linux.EPOLL.CTL_ADD, socket_fd, &event);

        return Self{
            .fd = fd,
        };
    }

    pub fn wait(self: *const Self) !void {
        var event: std.os.linux.epoll_event = undefined;
        const nfds = std.posix.epoll_wait(self.fd, @ptrCast(&event), -1);
        log.assert(@src(), 0 < nfds, "epoll_wait returned {}", .{nfds});
    }
};

pub fn main() !void {
    const socket_fd = try shutter.open_socket(null, null);
    defer std.posix.close(socket_fd);

    const epoll: Epoll = try .init(socket_fd);

    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Display.Requests.GetRegistry.init(REGISTRY)),
        null,
    );

    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Display.Requests.Sync.init(CALLBACK)),
        null,
    );

    try epoll.wait();
    const ids = [_]shutter.ObjectId{
        .{ .display = shutter.DISPLAY_ID },
        .{ .registry = REGISTRY },
        .{ .callback = CALLBACK },
        .{ .callback = CALLBACK2 },
        .{ .compositor = COMPOSITOR },
        .{ .shm_pool = SHM_POOL },
        .{ .buffer = BUFFER },
        .{ .shm = SHM },
        .{ .surface = SURFACE },
        .{ .xdg_wm_base = XDG_WM_BASE },
        .{ .xdg_surface = XDG_SURFACE },
        .{ .xdg_top_level = XDG_TOPLEVEL },
    };
    var buffer: [shutter.MAX_MESSAGE_SIZE_U32]u32 = undefined;
    while (true) {
        const response = try shutter.read_response(socket_fd, &buffer);
        var parser: shutter.ResponseParser = .{ .response = response, .object_ids = &ids };
        while (parser.next()) |r| {
            switch (r.event) {
                .display_error => |*e| {
                    log.info(
                        @src(),
                        "display_error: object_id: {d} code: {d} message: {s}",
                        .{ e.object_id, e.code, e.message },
                    );
                },
                .display_delete_id => |*e| {
                    log.info(
                        @src(),
                        "delete_id: {d}",
                        .{e.id},
                    );
                },
                .registry_global => |*e| {
                    log.info(
                        @src(),
                        "registry_global: name: {d} interface: {s} version: {d}",
                        .{ e.name, e.interface, e.version },
                    );
                    if (std.mem.eql(u8, e.interface, "wl_compositor")) {
                        try shutter.send_request(
                            socket_fd,
                            @ptrCast(&shutter.Registry.Requests.Bind("wl_compositor").init(
                                REGISTRY,
                                e.name,
                                e.version,
                                COMPOSITOR,
                            )),
                            null,
                        );
                    }
                    if (std.mem.eql(u8, e.interface, "wl_shm")) {
                        try shutter.send_request(
                            socket_fd,
                            @ptrCast(&shutter.Registry.Requests.Bind("wl_shm").init(
                                REGISTRY,
                                e.name,
                                e.version,
                                SHM,
                            )),
                            null,
                        );
                    }
                    if (std.mem.eql(u8, e.interface, "xdg_wm_base")) {
                        try shutter.send_request(
                            socket_fd,
                            @ptrCast(&shutter.Registry.Requests.Bind("xdg_wm_base").init(
                                REGISTRY,
                                e.name,
                                e.version,
                                XDG_WM_BASE,
                            )),
                            null,
                        );
                    }
                },
                .shm_format => |*e| {
                    log.info(@src(), "shm_format: format: {t}", .{e.format});
                },
                .callback_done => |*e| {
                    log.info(@src(), "callback_done: format: {d}", .{e.callback_data});
                },
                else => {
                    log.info(@src(), "got unknown response", .{});
                },
            }
        }

        if (response.len == 0)
            break;
    }

    log.info(@src(), "creating surface", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Compositor.Requests.CreateSurface.init(COMPOSITOR, SURFACE)),
        null,
    );

    log.info(@src(), "creating xdg surface", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.XDGWmBase.Requests.GetXDGSurface.init(
            XDG_WM_BASE,
            XDG_SURFACE,
            SURFACE,
        )),
        null,
    );

    log.info(@src(), "creating xdg top level", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.XDGSurface.Requests.GetToplevel.init(XDG_SURFACE, XDG_TOPLEVEL)),
        null,
    );

    {
        try shutter.send_request(
            socket_fd,
            @ptrCast(&shutter.Surface.Requests.Commit.init(SURFACE)),
            null,
        );
        try shutter.send_request(
            socket_fd,
            @ptrCast(&shutter.Display.Requests.Sync.init(CALLBACK2)),
            null,
        );

        var c = true;
        while (c) {
            try epoll.wait();
            const response = try shutter.read_response(socket_fd, &buffer);
            var parser: shutter.ResponseParser = .{ .response = response, .object_ids = &ids };
            while (parser.next()) |r| {
                switch (r.event) {
                    .display_error => |*e| {
                        log.info(
                            @src(),
                            "display_error: object_id: {d} code: {d} message: {s}",
                            .{ e.object_id, e.code, e.message },
                        );
                    },
                    .display_delete_id => |*e| {
                        log.info(
                            @src(),
                            "delete_id: {d}",
                            .{e.id},
                        );
                    },
                    .callback_done => |*e| {
                        log.info(@src(), "callback_done: format: {d}", .{e.callback_data});
                        c = false;
                    },
                    .xdg_surface_configure => |*e| {
                        log.info(@src(), "xdg_surface_configure", .{});
                        try shutter.send_request(
                            socket_fd,
                            @ptrCast(&shutter.XDGSurface.Requests.AckConfigure.init(
                                XDG_SURFACE,
                                e.serial,
                            )),
                            null,
                        );

                        c = false;
                    },
                    else => {
                        log.info(@src(), "got response: {any}", .{r.event});
                    },
                }
            }
        }
    }

    log.info(@src(), "creating shm pool", .{});
    const shared_memory_pool_len = 128 * 128 * 4;
    const shared_memory_pool_fd = try std.posix.memfd_create("wayland-framebuffer", 0);
    _ = std.os.linux.ftruncate(shared_memory_pool_fd, @intCast(shared_memory_pool_len));
    const shared_memory_pool_bytes = try std.posix.mmap(
        null,
        shared_memory_pool_len,
        std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
        .{ .TYPE = .SHARED },
        @intCast(shared_memory_pool_fd),
        0,
    );
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Shm.Requests.CreatePool.init(
            SHM,
            SHM_POOL,
            shared_memory_pool_len,
        )),
        shared_memory_pool_fd,
    );

    log.info(@src(), "creating shm pool buffer", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.ShmPool.Requests.CreateBuffer.init(
            SHM_POOL,
            BUFFER,
            0,
            128,
            128,
            128 * 4,
            .xrgb8888,
        )),
        shared_memory_pool_fd,
    );

    const framebuffer: []u32 = @ptrCast(shared_memory_pool_bytes);
    for (framebuffer, 0..) |*pixel, i|
        pixel.* = @as(u32, @intCast(i)) << 16 |
            @as(u32, @intCast(i)) << 8 |
            @as(u32, @intCast(i));

    log.info(@src(), "attaching surface", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Surface.Requests.Attach.init(SURFACE, BUFFER, 0, 0)),
        shared_memory_pool_fd,
    );

    log.info(@src(), "damaging surface", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Surface.Requests.Damage.init(SURFACE, 0, 0, 128, 128)),
        shared_memory_pool_fd,
    );

    log.info(@src(), "commit surface", .{});
    try shutter.send_request(
        socket_fd,
        @ptrCast(&shutter.Surface.Requests.Commit.init(SURFACE)),
        shared_memory_pool_fd,
    );

    outer: while (true) {
        try epoll.wait();
        const response = try shutter.read_response(socket_fd, &buffer);
        var parser: shutter.ResponseParser = .{ .response = response, .object_ids = &ids };
        while (parser.next()) |r| {
            switch (r.event) {
                .display_error => |*e| {
                    log.info(
                        @src(),
                        "display_error: object_id: {d} code: {d} message: {s}",
                        .{ e.object_id, e.code, e.message },
                    );
                },
                .display_delete_id => |*e| {
                    log.info(
                        @src(),
                        "delete_id: {d}",
                        .{e.id},
                    );
                },
                .registry_global => |*e| {
                    log.info(
                        @src(),
                        "registry_global: name: {d} interface: {s} version: {d}",
                        .{ e.name, e.interface, e.version },
                    );
                },
                .shm_format => |*e| {
                    log.info(@src(), "shm_format: format: {t}", .{e.format});
                },
                .callback_done => |*e| {
                    log.info(@src(), "callback_done: format: {d}", .{e.callback_data});
                },
                .xdg_surface_configure => |*e| {
                    log.info(@src(), "got surface configure: {any}. Confirming configure", .{e});
                    try shutter.send_request(
                        socket_fd,
                        @ptrCast(&shutter.XDGSurface.Requests.AckConfigure.init(
                            XDG_SURFACE,
                            e.serial,
                        )),
                        null,
                    );
                },
                .xdg_top_level_configure => |*e| {
                    log.info(@src(), "got top level configure: {any}", .{e});
                },
                .xdg_top_level_close => break :outer,
                else => {
                    log.info(@src(), "got response: {any}", .{r.event});
                },
            }
        }
    }
}
