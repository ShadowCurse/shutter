const std     = @import("std");
const log     = @import("log.zig");
const os      = @import("os.zig");
const wayland = @import("wayland.zig");
const wire    = wayland.wire;

const WIDTH     = 128;
const HEIGHT    = 128;
const STRIDE    = WIDTH * 4;
const POOL_SIZE = STRIDE * HEIGHT;

const Epoll = struct {
  fd: std.posix.fd_t,

  const Self = @This();

  pub fn init(socket_fd: std.posix.fd_t) !Self {
    const fd = try os.epoll_create1(0);

    var event: std.os.linux.epoll_event = .{
      .events = std.os.linux.EPOLL.IN,
      .data   = .{ .u64 = 0 },
    };

    try os.epoll_ctl(fd, std.os.linux.EPOLL.CTL_ADD, socket_fd, &event);

    return Self{
      .fd = fd,
    };
  }

  pub fn wait(self: *const Self) !void {
    var event: std.os.linux.epoll_event = undefined;
    const nfds                          = try os.epoll_wait(self.fd, (&event)[0..1], -1);
    log.assert(@src(), 0 < nfds, "epoll_wait returned {}", .{ nfds });
  }
};

// Big, so it lives in static memory.
var conn: wire.Connection = undefined;

// Logs events not handled by the caller. Returns an error on a fatal display error.
fn event_log(message: *const wayland.Message) !void {
  switch (message.event) {
    .wl_display => |*event| switch (event.*) {
      .@"error" => |*e| {
        log.err(
          @src(),
          "display error: object_id: {d} code: {d} message: {s}",
          .{ e.object_id, e.code, e.message },
        );
        return error.DisplayError;
      },
      .delete_id => {},
    },
    else => log.info(@src(), "event: id: {d} {any}", .{ message.id, message.event }),
  }
}

// Binds the global with the highest version supported by both sides.
fn global_bind(
  registry: wayland.wl_registry.Id,
  global: *const wayland.wl_registry.Event.Global,
  comptime T: type,
) !T.Id {
  const version = @min(global.version, T.VERSION);
  return wayland.wl_registry.bind(&conn, registry, global.name, T, version);
}

pub fn main(init: std.process.Init.Minimal) !void {
  try conn.connect(&init.environ, null, null);
  defer os.close(conn.socket_fd);

  const epoll: Epoll = try .init(conn.socket_fd);

  const display: wayland.wl_display.Id = @enumFromInt(wire.DISPLAY_ID);
  const registry                       = try wayland.wl_display.get_registry(&conn, display);
  const sync                           = try wayland.wl_display.sync(&conn, display);
  try conn.flush();

  var compositor: wayland.wl_compositor.Id = .none;
  var shm: wayland.wl_shm.Id               = .none;
  var wm_base: wayland.xdg_wm_base.Id      = .none;
  var synced                               = false;
  while (!synced) {
    try epoll.wait();
    _ = try conn.receive();
    while (try wayland.event_next(&conn)) |*message| {
      switch (message.event) {
        .wl_registry => |*event| switch (event.*) {
          .global => |*global| {
            log.info(
              @src(),
              "registry_global: name: {d} interface: {s} version: {d}",
              .{ global.name, global.interface, global.version },
            );
            if (std.mem.eql(u8, global.interface, wayland.wl_compositor.NAME))
              compositor = try global_bind(registry, global, wayland.wl_compositor);
            if (std.mem.eql(u8, global.interface, wayland.wl_shm.NAME))
              shm = try global_bind(registry, global, wayland.wl_shm);
            if (std.mem.eql(u8, global.interface, wayland.xdg_wm_base.NAME))
              wm_base = try global_bind(registry, global, wayland.xdg_wm_base);
          },
          .global_remove => {},
        },
        .wl_callback => if (message.id == @intFromEnum(sync)) {
          synced = true;
        },
        else => try event_log(message),
      }
    }
  }
  if (compositor == .none) return error.NoCompositor;
  if (shm == .none) return error.NoShm;
  if (wm_base == .none) return error.NoXdgWmBase;

  log.info(@src(), "creating window", .{});
  const surface     = try wayland.wl_compositor.create_surface(&conn, compositor);
  const xdg_surface = try wayland.xdg_wm_base.get_xdg_surface(&conn, wm_base, surface);
  const toplevel    = try wayland.xdg_surface.get_toplevel(&conn, xdg_surface);
  try wayland.xdg_toplevel.set_title(&conn, toplevel, "shutter");
  try wayland.wl_surface.commit(&conn, surface);

  log.info(@src(), "creating shm pool", .{});
  const pool_fd = try std.posix.memfd_create("wayland-framebuffer", 0);
  defer os.close(pool_fd);
  _ = std.os.linux.ftruncate(pool_fd, POOL_SIZE);
  const pool_bytes = try std.posix.mmap(
    null,
    POOL_SIZE,
    .{ .READ = true, .WRITE = true },
    .{ .TYPE = .SHARED },
    pool_fd,
    0,
  );
  const framebuffer: []u32 = @ptrCast(pool_bytes);
  for (framebuffer, 0..) |*pixel, i| {
    const c: u32 = @intCast(i % 256);
    pixel.* = c << 16 | c << 8 | c;
  }
  const pool   = try wayland.wl_shm.create_pool(&conn, shm, pool_fd, POOL_SIZE);
  const buffer = try wayland.wl_shm_pool.create_buffer(&conn, pool, 0, WIDTH, HEIGHT, STRIDE, .xrgb8888);
  try conn.flush();

  while (true) {
    try epoll.wait();
    _ = try conn.receive();
    while (try wayland.event_next(&conn)) |*message| {
      switch (message.event) {
        .xdg_wm_base => |*event| try wayland.xdg_wm_base.pong(&conn, wm_base, event.ping.serial),
        .xdg_surface => |*event| {
          log.info(@src(), "xdg_surface configure: serial: {d}", .{ event.configure.serial });
          try wayland.xdg_surface.ack_configure(&conn, xdg_surface, event.configure.serial);
          try wayland.wl_surface.attach(&conn, surface, buffer, 0, 0);
          try wayland.wl_surface.damage(&conn, surface, 0, 0, WIDTH, HEIGHT);
          try wayland.wl_surface.commit(&conn, surface);
        },
        .xdg_toplevel => |*event| switch (event.*) {
          .close => return,
          else => log.info(@src(), "xdg_toplevel: {any}", .{ event.* }),
        },
        else => try event_log(message),
      }
    }
    try conn.flush();
  }
}

test {
  _ = wayland;
}
