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
            code: u32,
            message: []const u8,

            pub fn parse(payload: []const u32) Error {
                const object_id = payload[0];
                const code = payload[1];

                const message_len_bytes = payload[2];
                const payload_bytes: []const u8 = @ptrCast(payload[3..]);
                const message = payload_bytes[0 .. message_len_bytes - 1];

                return .{
                    .object_id = object_id,
                    .code = code,
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
    pub const Errors = enum(u32) {
        invalid_object,
        invalid_method,
        no_memory,
        implementation,
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

            pub fn parse(payload: []const u32) GlobalRemove {
                const name = payload[0];
                return .{
                    .name = name,
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
                .opcode = 1,
                .msg_len = @sizeOf(CreateRegion),
            },
            id: u32,
        };
    };
};

pub const ShmPool = struct {
    pub const Requests = struct {
        pub const CreateBuffer = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(CreateBuffer),
            },
            id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: Shm.Events.Format.Values,
        };
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(Destroy),
            },
        };
        pub const Resize = extern struct {
            header: RequestHeader = .{
                .opcode = 2,
                .msg_len = @sizeOf(Resize),
            },
            size: i32,
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
            format: Values,

            pub const Values = enum(u32) {
                argb8888 = 0,
                xrgb8888 = 1,
                c8 = 0x20203843,
                rgb332 = 0x38424752,
                bgr233 = 0x38524742,
                xrgb4444 = 0x32315258,
                xbgr4444 = 0x32314258,
                rgbx4444 = 0x32315852,
                bgrx4444 = 0x32315842,
                argb4444 = 0x32315241,
                abgr4444 = 0x32314241,
                rgba4444 = 0x32314152,
                bgra4444 = 0x32314142,
                xrgb1555 = 0x35315258,
                xbgr1555 = 0x35314258,
                rgbx5551 = 0x35315852,
                bgrx5551 = 0x35315842,
                argb1555 = 0x35315241,
                abgr1555 = 0x35314241,
                rgba5551 = 0x35314152,
                bgra5551 = 0x35314142,
                rgb565 = 0x36314752,
                bgr565 = 0x36314742,
                rgb888 = 0x34324752,
                bgr888 = 0x34324742,
                xbgr8888 = 0x34324258,
                rgbx8888 = 0x34325852,
                bgrx8888 = 0x34325842,
                abgr8888 = 0x34324241,
                rgba8888 = 0x34324152,
                bgra8888 = 0x34324142,
                xrgb2101010 = 0x30335258,
                xbgr2101010 = 0x30334258,
                rgbx1010102 = 0x30335852,
                bgrx1010102 = 0x30335842,
                argb2101010 = 0x30335241,
                abgr2101010 = 0x30334241,
                rgba1010102 = 0x30334152,
                bgra1010102 = 0x30334142,
                yuyv = 0x56595559,
                yvyu = 0x55595659,
                uyvy = 0x59565955,
                vyuy = 0x59555956,
                ayuv = 0x56555941,
                nv12 = 0x3231564e,
                nv21 = 0x3132564e,
                nv16 = 0x3631564e,
                nv61 = 0x3136564e,
                yuv410 = 0x39565559,
                yvu410 = 0x39555659,
                yuv411 = 0x31315559,
                yvu411 = 0x31315659,
                yuv420 = 0x32315559,
                yvu420 = 0x32315659,
                yuv422 = 0x36315559,
                yvu422 = 0x36315659,
                yuv444 = 0x34325559,
                yvu444 = 0x34325659,
                r8 = 0x20203852,
                r16 = 0x20363152,
                rg88 = 0x38384752,
                gr88 = 0x38385247,
                rg1616 = 0x32334752,
                gr1616 = 0x32335247,
                xrgb16161616f = 0x48345258,
                xbgr16161616f = 0x48344258,
                argb16161616f = 0x48345241,
                abgr16161616f = 0x48344241,
                xyuv8888 = 0x56555958,
                vuy888 = 0x34325556,
                vuy101010 = 0x30335556,
                y210 = 0x30313259,
                y212 = 0x32313259,
                y216 = 0x36313259,
                y410 = 0x30313459,
                y412 = 0x32313459,
                y416 = 0x36313459,
                xvyu2101010 = 0x30335658,
                xvyu12_16161616 = 0x36335658,
                xvyu16161616 = 0x38345658,
                y0l0 = 0x304c3059,
                x0l0 = 0x304c3058,
                y0l2 = 0x324c3059,
                x0l2 = 0x324c3058,
                yuv420_8bit = 0x38305559,
                yuv420_10bit = 0x30315559,
                xrgb8888_a8 = 0x38415258,
                xbgr8888_a8 = 0x38414258,
                rgbx8888_a8 = 0x38415852,
                bgrx8888_a8 = 0x38415842,
                rgb888_a8 = 0x38413852,
                bgr888_a8 = 0x38413842,
                rgb565_a8 = 0x38413552,
                bgr565_a8 = 0x38413542,
                nv24 = 0x3432564e,
                nv42 = 0x3234564e,
                p210 = 0x30313250,
                p010 = 0x30313050,
                p012 = 0x32313050,
                p016 = 0x36313050,
                axbxgxrx106106106106 = 0x30314241,
                nv15 = 0x3531564e,
                q410 = 0x30313451,
                q401 = 0x31303451,
                xrgb16161616 = 0x38345258,
                xbgr16161616 = 0x38344258,
                argb16161616 = 0x38345241,
                abgr16161616 = 0x38344241,
                c1 = 0x20203143,
                c2 = 0x20203243,
                c4 = 0x20203443,
                d1 = 0x20203144,
                d2 = 0x20203244,
                d4 = 0x20203444,
                d8 = 0x20203844,
                r1 = 0x20203152,
                r2 = 0x20203252,
                r4 = 0x20203452,
                r10 = 0x20303152,
                r12 = 0x20323152,
                avuy8888 = 0x59555641,
                xvuy8888 = 0x59555658,
                p030 = 0x30333050,
            };

            pub fn parse(payload: []const u32) Format {
                const format = payload[0];
                return .{
                    .format = @enumFromInt(format),
                };
            }
        };
    };
    pub const Errors = enum(u32) {
        invalid_format,
        invalid_stride,
        invalid_fd,
    };
};

pub const Buffer = struct {
    pub const Requests = struct {
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(Destroy),
            },
        };
    };

    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            _ = payload;
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .release => {
                    return .{ .buffer_release = Release{} };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            release,
        };
        pub const Release = struct {};
    };
};

pub const Surface = struct {
    pub const Requests = struct {
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(Destroy),
            },
        };
        pub const Attach = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(Attach),
            },
            id: u32,
            x: i32,
            y: i32,
        };
        pub const Damage = extern struct {
            header: RequestHeader = .{
                .opcode = 2,
                .msg_len = @sizeOf(Damage),
            },
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };
        pub const Frame = extern struct {
            header: RequestHeader = .{
                .opcode = 3,
                .msg_len = @sizeOf(Frame),
            },
            callback: u32,
        };
        pub const SetOpaqueRegion = extern struct {
            header: RequestHeader = .{
                .opcode = 4,
                .msg_len = @sizeOf(SetOpaqueRegion),
            },
            region: u32,
        };
        pub const SetInputRegion = extern struct {
            header: RequestHeader = .{
                .opcode = 5,
                .msg_len = @sizeOf(SetInputRegion),
            },
            region: u32,
        };
        pub const Commit = extern struct {
            header: RequestHeader = .{
                .opcode = 6,
                .msg_len = @sizeOf(Commit),
            },
        };
        pub const SetBufferTransform = extern struct {
            header: RequestHeader = .{
                .opcode = 7,
                .msg_len = @sizeOf(SetBufferTransform),
            },
            transform: u32,
        };
        pub const SetBufferScale = extern struct {
            header: RequestHeader = .{
                .opcode = 8,
                .msg_len = @sizeOf(SetBufferScale),
            },
            scale: i32,
        };
        pub const DamageBuffer = extern struct {
            header: RequestHeader = .{
                .opcode = 9,
                .msg_len = @sizeOf(DamageBuffer),
            },
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };
        pub const Offset = extern struct {
            header: RequestHeader = .{
                .opcode = 10,
                .msg_len = @sizeOf(Offset),
            },
            x: i32,
            y: i32,
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .enter => {
                    const enter = Enter.parse(payload);
                    return .{ .surface_enter = enter };
                },
                .leave => {
                    const leave = Leave.parse(payload);
                    return .{ .surface_leave = leave };
                },
                .preferred_buffer_scale => {
                    const scale = PreferredBufferScale.parse(payload);
                    return .{ .surface_preferred_buffer_scale = scale };
                },
                .preferred_buffer_transform => {
                    const transform = PreferredBufferTransform.parse(payload);
                    return .{ .surface_preferred_buffer_transform = transform };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            enter,
            leave,
            preferred_buffer_scale,
            preferred_buffer_transform,
        };
        pub const Enter = struct {
            output: u32,

            pub fn parse(payload: []const u32) Enter {
                const output = payload[0];
                return .{
                    .output = output,
                };
            }
        };
        pub const Leave = struct {
            output: u32,

            pub fn parse(payload: []const u32) Leave {
                const output = payload[0];
                return .{
                    .output = output,
                };
            }
        };
        pub const PreferredBufferScale = struct {
            factor: i32,

            pub fn parse(payload: []const u32) PreferredBufferScale {
                const factor = payload[0];
                return .{
                    .factor = @bitCast(factor),
                };
            }
        };
        pub const PreferredBufferTransform = struct {
            transform: u32,

            pub fn parse(payload: []const u32) PreferredBufferTransform {
                const transform = payload[0];
                return .{
                    .transform = transform,
                };
            }
        };
    };
    pub const Errors = enum(u32) {
        invalid_scale,
        invalid_transform,
        invalid_size,
        invalid_offset,
        defunct_role_object,
    };
};

pub const XDGWmBase = struct {
    pub const Requests = struct {
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(Destroy),
            },
        };
        pub const CreatePositioner = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(CreatePositioner),
            },
            id: u32,
        };
        pub const GetXDGSurface = extern struct {
            header: RequestHeader = .{
                .opcode = 2,
                .msg_len = @sizeOf(GetXDGSurface),
            },
            id: u32,
            surface: u32,
        };
        pub const Pong = extern struct {
            header: RequestHeader = .{
                .opcode = 3,
                .msg_len = @sizeOf(Pong),
            },
            serial: u32,
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .ping => {
                    const ping = Ping.parse(payload);
                    return .{ .xdg_wm_base_ping = ping };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            ping,
        };
        pub const Ping = struct {
            serial: u32,

            pub fn parse(payload: []const u32) Ping {
                const serial = payload[0];
                return .{
                    .serial = serial,
                };
            }
        };
    };
    pub const Errors = enum(u32) {
        role,
        defunct_surfaces,
        not_the_topmost_popup,
        invalid_popup_parent,
        invalid_surface_state,
        invalid_positioner,
        unresponsive,
    };
};

pub const XDGSurface = struct {
    pub const Requests = struct {
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(Destroy),
            },
        };
        pub const GetToplevel = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(GetToplevel),
            },
            id: u32,
        };
        pub const GetPopup = extern struct {
            header: RequestHeader = .{
                .opcode = 2,
                .msg_len = @sizeOf(GetPopup),
            },
            id: u32,
            parent: u32,
            positioner: u32,
        };
        pub const SetWindowGeometry = extern struct {
            header: RequestHeader = .{
                .opcode = 3,
                .msg_len = @sizeOf(SetWindowGeometry),
            },
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };
        pub const AckConfigure = extern struct {
            header: RequestHeader = .{
                .opcode = 4,
                .msg_len = @sizeOf(AckConfigure),
            },
            serial: u32,
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .configure => {
                    const configure = Configure.parse(payload);
                    return .{ .xdg_surface_configure = configure };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            configure,
        };
        pub const Configure = struct {
            serial: u32,

            pub fn parse(payload: []const u32) Configure {
                const serial = payload[0];
                return .{
                    .serial = serial,
                };
            }
        };
    };
    pub const Errors = enum(u32) {
        not_constructed,
        already_constructed,
        unconfigured_buffer,
        invalid_serial,
        invalid_size,
        defunct_role_object,
    };
};

pub const XDGToplevel = struct {
    pub const Requests = struct {
        pub const Destroy = extern struct {
            header: RequestHeader = .{
                .opcode = 0,
                .msg_len = @sizeOf(Destroy),
            },
        };
        pub const SetParent = extern struct {
            header: RequestHeader = .{
                .opcode = 1,
                .msg_len = @sizeOf(SetParent),
            },
            parent: u32,
        };
        pub fn SetTitle(comptime TITLE_STR: []const u8) type {
            const len = TITLE_STR.len + 1;
            const padding_bytes = std.mem.alignForward(usize, len, 4) - len;
            return extern struct {
                const Self = @This();
                header: RequestHeader = .{
                    .opcode = 2,
                    .msg_len = @sizeOf(Self),
                },
                title_len: u32 = len,
                title: [TITLE_STR.len + padding_bytes]u8 =
                    (TITLE_STR ++ .{0} ** padding_bytes).*,
            };
        }
        pub fn SetAppId(comptime ID_STR: []const u8) type {
            const len = ID_STR.len + 1;
            const padding_bytes = std.mem.alignForward(usize, len, 4) - len;
            return extern struct {
                const Self = @This();
                header: RequestHeader = .{
                    .opcode = 3,
                    .msg_len = @sizeOf(Self),
                },
                id_len: u32 = len,
                id: [ID_STR.len + padding_bytes]u8 =
                    (ID_STR ++ .{0} ** padding_bytes).*,
            };
        }
        pub const ShowWindowMenu = extern struct {
            header: RequestHeader = .{
                .opcode = 4,
                .msg_len = @sizeOf(SetParent),
            },
            seat: u32,
            serial: u32,
            x: i32,
            y: i32,
        };
        pub const Move = extern struct {
            header: RequestHeader = .{
                .opcode = 5,
                .msg_len = @sizeOf(Move),
            },
            seat: u32,
            serial: u32,
        };
        pub const Resize = extern struct {
            header: RequestHeader = .{
                .opcode = 6,
                .msg_len = @sizeOf(Resize),
            },
            seat: u32,
            serial: u32,
            edges: enum(u32) {
                none,
                top,
                bottom,
                left,
                top_left,
                bottom_left,
                right,
                top_right,
                bottom_right,
            },
        };
        pub const SetMaxSize = extern struct {
            header: RequestHeader = .{
                .opcode = 7,
                .msg_len = @sizeOf(SetMaxSize),
            },
            width: i32,
            height: i32,
        };
        pub const SetMinSize = extern struct {
            header: RequestHeader = .{
                .opcode = 8,
                .msg_len = @sizeOf(SetMinSize),
            },
            width: i32,
            height: i32,
        };
        pub const SetMaximized = extern struct {
            header: RequestHeader = .{
                .opcode = 9,
                .msg_len = @sizeOf(SetMaximized),
            },
        };
        pub const UnsetMaximized = extern struct {
            header: RequestHeader = .{
                .opcode = 10,
                .msg_len = @sizeOf(UnsetMaximized),
            },
        };
        pub const SetFullscreen = extern struct {
            header: RequestHeader = .{
                .opcode = 11,
                .msg_len = @sizeOf(SetFullscreen),
            },
        };
        pub const UnsetFullscreen = extern struct {
            header: RequestHeader = .{
                .opcode = 12,
                .msg_len = @sizeOf(UnsetFullscreen),
            },
        };
        pub const SetMinimized = extern struct {
            header: RequestHeader = .{
                .opcode = 13,
                .msg_len = @sizeOf(SetMinimized),
            },
        };
    };
    pub const Events = struct {
        pub fn parse(opcode: u16, payload: []const u32) Event {
            const event_opcode: Opcodes = @enumFromInt(opcode);
            switch (event_opcode) {
                .configure => {
                    const configure = Configure.parse(payload);
                    return .{ .xdg_top_level_configure = configure };
                },
                .close => {
                    const close = Close{};
                    return .{ .xdg_top_level_close = close };
                },
                .configure_bounds => {
                    const bounds = ConfigureBounds.parse(payload);
                    return .{ .xdg_top_level_configure_bounds = bounds };
                },
                .wm_capabilities => {
                    const capabilities = WmCapabilities.parse(payload);
                    return .{ .xdg_top_level_wm_capabilities = capabilities };
                },
            }
        }
        pub const Opcodes = enum(u16) {
            configure,
            close,
            configure_bounds,
            wm_capabilities,
        };
        pub const Configure = struct {
            width: i32,
            height: i32,
            states: []const State,

            pub const State = enum(u32) {
                maximized,
                fullscreen,
                resizing,
                activated,
                tiled_left,
                tiled_right,
                tiled_tops,
                tiled_bottom,
                suspended,
                constrained_left,
                constrained_right,
                constrained_top,
                constrained_bottom,
            };

            pub fn parse(payload: []const u32) Configure {
                const width = payload[0];
                const height = payload[1];
                const len = payload[2] / @sizeOf(u32);
                const states = payload[3..][0..len];
                return .{
                    .width = @bitCast(width),
                    .height = @bitCast(height),
                    .states = @ptrCast(states),
                };
            }
        };
        pub const Close = struct {};
        pub const ConfigureBounds = struct {
            width: i32,
            height: i32,

            pub fn parse(payload: []const u32) ConfigureBounds {
                const width = payload[0];
                const height = payload[2];
                return .{
                    .width = @bitCast(width),
                    .height = @bitCast(height),
                };
            }
        };
        pub const WmCapabilities = struct {
            array: []const Capabilities,

            pub const Capabilities = enum(u32) {
                window_menu,
                maximize,
                fullscreen,
                minimize,
            };

            pub fn parse(payload: []const u32) WmCapabilities {
                const len = payload[0] / @sizeOf(u32);
                const array = payload[1..][0..len];
                return .{
                    .array = @ptrCast(array),
                };
            }
        };
    };
    pub const Errors = enum(u32) {
        invalid_resize_edge,
        invalid_parent,
        invalid_size,
    };
};

pub const Event = union(enum) {
    display_error: Display.Events.Error,
    display_delete_id: Display.Events.DeleteId,
    registry_global: Registry.Events.Global,
    registry_global_remove: Registry.Events.GlobalRemove,
    callback_done: Callback.Events.Done,
    shm_format: Shm.Events.Format,
    buffer_release: Buffer.Events.Release,
    surface_enter: Surface.Events.Enter,
    surface_leave: Surface.Events.Leave,
    surface_preferred_buffer_scale: Surface.Events.PreferredBufferScale,
    surface_preferred_buffer_transform: Surface.Events.PreferredBufferTransform,
    xdg_wm_base_ping: XDGWmBase.Events.Ping,
    xdg_surface_configure: XDGSurface.Events.Configure,
    xdg_top_level_configure: XDGToplevel.Events.Configure,
    xdg_top_level_close: XDGToplevel.Events.Close,
    xdg_top_level_configure_bounds: XDGToplevel.Events.ConfigureBounds,
    xdg_top_level_wm_capabilities: XDGToplevel.Events.WmCapabilities,
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
    shm_pool: u32,
    shm_pool_buffer: u32,
    shm: u32,
    buffer: u32,
    surface: u32,
    xdg_wm_base: u32,
    xdg_surface: u32,
    xdg_top_level: u32,
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

    const socket_fd = try std.posix.socket(
        std.os.linux.PF.UNIX,
        std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK,
        0,
    );
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

pub fn send_request(socket_fd: std.posix.fd_t, request: []const u8, fd: ?std.posix.fd_t) !void {
    var iov: std.posix.iovec_const = .{
        .base = request.ptr,
        .len = request.len,
    };

    var control_message_bytes: []const u8 = &.{};
    if (fd) |f| {
        const control_message = cmsg(std.posix.fd_t){
            .level = std.os.linux.SOL.SOCKET,
            .type = 0x01,
            .data = f,
        };
        control_message_bytes = @ptrCast(&control_message);
    }

    const msg: std.posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = control_message_bytes.ptr,
        .controllen = control_message_bytes.len,
        .flags = 0,
    };
    _ = try std.posix.sendmsg(
        socket_fd,
        &msg,
        std.os.linux.MSG.NOSIGNAL | std.os.linux.MSG.DONTWAIT,
    );
}

fn cmsg(comptime T: type) type {
    const padding_size = (@sizeOf(T) + @sizeOf(c_long) - 1) & ~(@as(usize, @sizeOf(c_long)) - 1);
    return extern struct {
        len: c_ulong = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
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
    if (std.posix.errno(len) == .AGAIN) return &.{};

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
                .display => |id| if (id == header.id) {
                    const event = Display.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .registry => |id| if (id == header.id) {
                    const event = Registry.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .callback => |id| if (id == header.id) {
                    const event = Callback.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .compositor => {},
                .shm_pool => {},
                .shm_pool_buffer => {},
                .shm => |id| if (id == header.id) {
                    const event = Shm.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .buffer => |id| if (id == header.id) {
                    const event = Buffer.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .surface => |id| if (id == header.id) {
                    const event = Surface.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .xdg_wm_base => |id| if (id == header.id) {
                    const event = XDGWmBase.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .xdg_surface => |id| if (id == header.id) {
                    const event = XDGSurface.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
                .xdg_top_level => |id| if (id == header.id) {
                    const event = XDGToplevel.Events.parse(header.opcode, payload);
                    try result.append(alloc, .{ .id = header.id, .event = event });
                },
            }
        }
    }
    return result;
}
