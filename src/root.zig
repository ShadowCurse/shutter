const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DISPLAY_ID = 1;
pub const MAX_MESSAGE_SIZE = 4096;
pub const MAX_MESSAGE_SIZE_U32 = MAX_MESSAGE_SIZE / @sizeOf(u32);

pub const RequestHeader = extern struct {
    id: u32 = 0,
    opcode: u16 = 0,
    msg_len: u16 = 0,
};

pub const Display = struct {
    pub const Requests = struct {
        pub const Sync = extern struct {
            header: RequestHeader = .{
                .id = DISPLAY_ID,
                .opcode = 0,
                .msg_len = @sizeOf(Sync),
            },
            callback: u32,
        };
        pub const GetRegistry = extern struct {
            header: RequestHeader = .{
                .id = DISPLAY_ID,
                .opcode = 1,
                .msg_len = @sizeOf(GetRegistry),
            },
            registry: u32,
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .@"error" => {
                    const err = Error.parse(payload);
                    return .{ .display_error = err };
                },
                .delete_id => {
                    const delete_id = DeleteId.parse(payload);
                    return .{ .display_delete_id = delete_id };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            @"error",
            delete_id,
        };
        pub const Error = struct {
            object_id: u32,
            code: enum {
                invalid_object,
                invalid_method,
                no_memory,
                implementation,
            },
            message: []const u8,

            pub fn parse(payload: []const u32) Error {
                const object_id = payload[0];
                const code = payload[1];

                const message_len_bytes = payload[2];
                const payload_bytes: []const u8 = @ptrCast(payload[3..]);
                const message = payload_bytes[0 .. message_len_bytes - 1];

                return .{
                    .object_id = object_id,
                    .code = @enumFromInt(code),
                    .message = message,
                };
            }
        };
        pub const DeleteId = struct {
            id: u32,

            pub fn parse(payload: []const u32) DeleteId {
                const id = payload[0];

                return .{
                    .id = id,
                };
            }
        };
    };
};

pub const Registry = struct {
    pub const Requests = struct {
        pub fn Bind(comptime INTERFACE_STR: []const u8) type {
            const len = INTERFACE_STR.len + 1;
            const padding_bytes = std.mem.alignForward(usize, len, 4) - len;
            return extern struct {
                const Self = @This();
                header: RequestHeader = .{
                    .opcode = 0,
                    .msg_len = @sizeOf(Self),
                },
                name: u32,
                interface_len: u32 = len,
                interface: [INTERFACE_STR.len + padding_bytes]u8 =
                    (INTERFACE_STR ++ .{0} ** padding_bytes).*,
                version: u32,
                id: u32,
            };
        }
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .global => {
                    const global = Global.parse(payload);
                    return .{ .registry_global = global };
                },
                .global_remove => unreachable,
            }
        }
        pub const Opcodes = enum(u16) {
            global,
            global_remove,
        };
        pub const Global = struct {
            name: u32,
            interface: []const u8,
            version: u32,

            pub fn parse(payload: []const u32) Global {
                const name = payload[0];

                var interface_len_bytes = payload[1];
                const payload_bytes: []const u8 = @ptrCast(payload[2..]);
                const interface = payload_bytes[0 .. interface_len_bytes - 1];

                if (interface_len_bytes % 4 != 0)
                    interface_len_bytes = std.mem.alignForward(u32, interface_len_bytes, 4);
                const version = payload[interface_len_bytes / @sizeOf(u32) + 2];

                return .{
                    .name = name,
                    .interface = interface,
                    .version = version,
                };
            }
        };

        pub const GlobalRemove = struct {
            name: u32,
        };
    };
};

pub const Compositor = struct {
    pub const Requests = struct {
        pub const CreateSurface = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(CreateSurface),
            },
            id: u32,
        };
        pub const CreateRegion = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(CreateSurface),
            },
            id: u32,
        };
    };
};

pub const Shm = struct {
    pub const Requests = struct {
        pub const CreatePool = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(CreatePool),
            },
            id: u32,
            size: i32,
            // TODO fd
        };
        pub const Release = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(Release),
            },
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .format => {
                    const format = Format.parse(payload);
                    return .{ .shm_format = format };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            format,
        };
        pub const Format = struct {
            format: u32,

            pub fn parse(payload: []const u32) Format {
                const format = payload[0];
                return .{
                    .format = format,
                };
            }
        };
    };
};

pub const Callback = struct {
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .done => {
                    const done = Done.parse(payload);
                    return .{ .callback_done = done };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            done,
        };
        pub const Done = struct {
            callback_data: u32,

            pub fn parse(payload: []const u32) Done {
                const callback_data = payload[0];
                return .{
                    .callback_data = callback_data,
                };
            }
        };
    };
};

pub const Event = union(enum) {
    display_error: Display.Events.Error,
    display_delete_id: Display.Events.DeleteId,
    registry_global: Registry.Events.Global,
    registry_global_remove: Registry.Events.GlobalRemove,
    shm_format: Shm.Events.Format,
    callback_done: Callback.Events.Done,
};

pub const Response = struct {
    id: u32,
    event: Event,
};

pub const ObjectId = union(enum) {
    display: u32,
    registry: u32,
    callback: u32,
    compositor: u32,
    shm: u32,
    xdg_wm_base: u32,
};

pub fn open_socket(xdg_runtime_dir: ?[]const u8, wayland_display: ?[]const u8) !std.posix.fd_t {
    const xrd = if (xdg_runtime_dir) |d|
        d
    else
        std.posix.getenv("XDG_RUNTIME_DIR") orelse {
            return error.NoXDGRuntimeDir;
        };
    const wd = if (wayland_display) |d|
        d
    else
        std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

    const socket_fd = try std.posix.socket(std.os.linux.PF.UNIX, std.os.linux.SOCK.STREAM, 0);
    var addr: std.posix.sockaddr.un = .{
        .family = std.os.linux.PF.UNIX,
        .path = undefined,
    };
    const path = if (wd[0] == '/')
        try std.fmt.bufPrint(&addr.path, "{s}", .{wd})
    else
        try std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ xrd, wd });

    try std.posix.connect(
        socket_fd,
        @ptrCast(&addr),
        @offsetOf(std.posix.sockaddr, "data") + @as(u32, @intCast(path.len)),
    );
    return socket_fd;
}

pub fn send_request(fd: std.posix.fd_t, request: []const u8) !void {
    var iov: std.posix.iovec_const = .{
        .base = request.ptr,
        .len = request.len,
    };
    const msg: std.posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    _ = try std.posix.sendmsg(
        fd,
        &msg,
        std.os.linux.MSG.NOSIGNAL | std.os.linux.MSG.DONTWAIT,
    );
}

pub fn read_response(fd: std.posix.fd_t, buffer: []u32) ![]const u32 {
    const buffer_bytes: []u8 = @ptrCast(buffer);
    var iov: std.posix.iovec = .{
        .base = buffer_bytes.ptr,
        .len = buffer_bytes.len,
    };
    var msg: std.posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const len = std.os.linux.recvmsg(fd, &msg, 0);
    if (len % 4 != 0) return error.PartialResponse;

    const response_bytes = buffer_bytes[0..len];
    const response: []const u32 = @ptrCast(@alignCast(response_bytes));
    return response;
}

pub fn parse_response(
    alloc: Allocator,
    object_ids: []const ObjectId,
    response: []const u32,
) !std.ArrayList(Response) {
    var result: std.ArrayList(Response) = .empty;
    var slice = response;
    while (slice.len != 0) {
        const header: *const RequestHeader = @ptrCast(slice.ptr);
        slice = slice[@sizeOf(RequestHeader) / @sizeOf(u32) ..];

        const payload_len = (header.msg_len - @sizeOf(RequestHeader)) / @sizeOf(u32);
        const payload = slice[0..payload_len];
        slice = slice[payload_len..];

        for (object_ids) |oid| {
            switch (oid) {
                .display => |d| if (d == header.id) {
                    const event = Display.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .registry => |r| if (r == header.id) {
                    const event = Registry.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .callback => |s| if (s == header.id) {
                    const event = Callback.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .compositor => {},
                .shm => |s| if (s == header.id) {
                    const event = Shm.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .xdg_wm_base => {},
            }
        }
    }
    return result;
}
