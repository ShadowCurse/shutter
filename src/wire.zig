const std    = @import("std");
const os     = @import("os.zig");
const assert = std.debug.assert;

const fd_t = std.os.linux.fd_t;

pub const MESSAGE_SIZE_MAX = 4096;
pub const FDS_MAX = 28;
pub const CLIENT_OBJECTS_MAX = 4096;
pub const SERVER_OBJECTS_MAX = 256;
pub const SERVER_ID_FIRST = 0xff000000;
pub const DISPLAY_ID = 1;
// Value of `Interface.wl_display` in the generated bindings.
pub const DISPLAY_INTERFACE = 1;

const HEADER_SIZE    = 8;
const SEND_WORDS_MAX = 2 * MESSAGE_SIZE_MAX / 4;
const RECV_WORDS_MAX = 4 * MESSAGE_SIZE_MAX / 4;
// Upper bound of messages in the receive buffer.
pub const RECV_MESSAGES_MAX = RECV_WORDS_MAX * 4 / HEADER_SIZE;
const RECV_FDS_MAX     = 4 * FDS_MAX;
const CMSG_HEADER_SIZE = @sizeOf(CmsgHeader);

const CmsgHeader = extern struct {
  len: u64,
  level: i32,
  type: i32,
};

comptime {
  assert(MESSAGE_SIZE_MAX <= SEND_WORDS_MAX * 4);
  assert(MESSAGE_SIZE_MAX <= RECV_WORDS_MAX * 4);
  assert(CLIENT_OBJECTS_MAX <= std.math.maxInt(u16) + 1);
  assert(DISPLAY_ID < CLIENT_OBJECTS_MAX);
  assert(FDS_MAX * @sizeOf(fd_t) % 8 == 0);
  assert(CMSG_HEADER_SIZE == 16);
}

/// Signed 24.8 fixed point number.
pub const Fixed = enum(i32) {
  _,

  pub fn from_f64(value: f64) Fixed {
    return @enumFromInt(@as(i32, @intFromFloat(value * 256.0)));
  }

  pub fn to_f64(fixed: Fixed) f64 {
    return @as(f64, @floatFromInt(@intFromEnum(fixed))) / 256.0;
  }
};

pub fn string_size(string: ?[]const u8) u32 {
  const s = string orelse return 4;
  return 4 + std.mem.alignForward(u32, @intCast(s.len + 1), 4);
}

pub fn array_size(array: []const u8) u32 {
  return 4 + std.mem.alignForward(u32, @intCast(array.len), 4);
}

pub const Message = struct {
  id: u32,
  opcode: u16,
  payload: []const u32,
};

/// Decodes message arguments. Payload comes from the server, so every read is bounds checked.
pub const Reader = struct {
  payload: []const u32,
  index: u32 = 0,

  pub fn uint(reader: *Reader) !u32 {
    if (reader.payload.len <= reader.index) return error.InvalidMessage;
    const value = reader.payload[reader.index];
    reader.index += 1;
    return value;
  }

  pub fn array(reader: *Reader) ![]const u8 {
    const len   = try reader.uint();
    const words = std.mem.alignForward(u32, len, 4) / 4;
    if (reader.payload.len - reader.index < words) return error.InvalidMessage;
    const bytes = std.mem.sliceAsBytes(reader.payload[reader.index..][0..words]);
    reader.index += words;
    return bytes[0..len];
  }

  pub fn string_optional(reader: *Reader) !?[]const u8 {
    const bytes = try reader.array();
    if (bytes.len == 0) return null;
    if (bytes[bytes.len - 1] != 0) return error.InvalidMessage;
    return bytes[0 .. bytes.len - 1];
  }

  pub fn string(reader: *Reader) ![]const u8 {
    return try reader.string_optional() orelse error.InvalidMessage;
  }
};

/// Client side of a wayland socket. Big (~45KiB), so it is initialized in place.
pub const Connection = struct {
  socket_fd: fd_t,

  send_words: [SEND_WORDS_MAX]u32,
  send_words_count: u32,
  // Must stay open until `flush` returns.
  send_fds: [FDS_MAX]fd_t,
  send_fds_count: u32,

  recv_words: [RECV_WORDS_MAX]u32,
  recv_start: u32,
  recv_end: u32,
  recv_fds: [RECV_FDS_MAX]fd_t,
  recv_fds_start: u32,
  recv_fds_count: u32,

  // Interface of each object id, 0 if free.
  client_objects: [CLIENT_OBJECTS_MAX]u8,
  server_objects: [SERVER_OBJECTS_MAX]u8,
  ids_free: [CLIENT_OBJECTS_MAX]u16,
  ids_free_count: u32,
  id_next: u32,

  pub fn init(conn: *Connection, socket_fd: fd_t) void {
    conn.socket_fd = socket_fd;
    conn.send_words_count = 0;
    conn.send_fds_count = 0;
    conn.recv_start = 0;
    conn.recv_end = 0;
    conn.recv_fds_start = 0;
    conn.recv_fds_count = 0;
    conn.client_objects = @splat(0);
    conn.server_objects = @splat(0);
    conn.ids_free_count = 0;
    conn.id_next = DISPLAY_ID + 1;

    conn.client_objects[DISPLAY_ID] = DISPLAY_INTERFACE;
  }

  pub fn connect(
    conn: *Connection,
    environ: *const std.process.Environ,
    xdg_runtime_dir: ?[]const u8,
    wayland_display: ?[]const u8,
  ) !void {
    const xrd = xdg_runtime_dir orelse environ.getPosix("XDG_RUNTIME_DIR") orelse
      return error.NoXDGRuntimeDir;
    const wd = wayland_display orelse environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    if (wd.len == 0) return error.InvalidWaylandDisplay;

    const socket_fd = try os.socket(
      std.os.linux.PF.UNIX,
      std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC,
      0,
    );
    errdefer os.close(socket_fd);

    var addr: std.posix.sockaddr.un = .{
      .family = std.os.linux.PF.UNIX,
      .path   = undefined,
    };
    const path = if (wd[0] == '/')
      try std.fmt.bufPrint(&addr.path, "{s}", .{ wd })
    else
      try std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ xrd, wd });

    try os.connect(
      socket_fd,
      @ptrCast(&addr),
      @offsetOf(std.posix.sockaddr, "data") + @as(u32, @intCast(path.len)),
    );
    conn.init(socket_fd);
  }

  pub fn object_new(conn: *Connection, interface: u8) !u32 {
    assert(interface != 0);

    var id: u32 = undefined;
    if (0 < conn.ids_free_count) {
      conn.ids_free_count -= 1;
      id = conn.ids_free[conn.ids_free_count];
    } else if (conn.id_next < CLIENT_OBJECTS_MAX) {
      id = conn.id_next;
      conn.id_next += 1;
    } else {
      return error.TooManyObjects;
    }
    assert(DISPLAY_ID < id);
    assert(conn.client_objects[id] == 0);
    conn.client_objects[id] = interface;
    return id;
  }

  /// Registers an object created by the server with a `new_id` event argument.
  pub fn object_new_server(conn: *Connection, id: u32, interface: u8) !u32 {
    assert(interface != 0);

    if (id < SERVER_ID_FIRST) return error.InvalidMessage;
    const index = id - SERVER_ID_FIRST;
    if (SERVER_OBJECTS_MAX <= index) return error.TooManyObjects;
    conn.server_objects[index] = interface;
    return id;
  }

  pub fn object_interface(conn: *const Connection, id: u32) u8 {
    if (id < CLIENT_OBJECTS_MAX) return conn.client_objects[id];
    if (id < SERVER_ID_FIRST) return 0;
    const index = id - SERVER_ID_FIRST;
    if (index < SERVER_OBJECTS_MAX) return conn.server_objects[index];
    return 0;
  }

  /// Called after a destructor request. Client ids stay valid until `wl_display.delete_id`, so
  /// events already in flight for them can still be decoded.
  pub fn object_destroy(conn: *Connection, id: u32) void {
    assert(id != DISPLAY_ID);

    if (id < SERVER_ID_FIRST) return;
    const index = id - SERVER_ID_FIRST;
    if (index < SERVER_OBJECTS_MAX) conn.server_objects[index] = 0;
  }

  /// Called on `wl_display.delete_id`. The id comes from the server, so unknown ids are ignored.
  pub fn object_free(conn: *Connection, id: u32) void {
    if (id <= DISPLAY_ID) return;
    if (CLIENT_OBJECTS_MAX <= id) return;
    if (conn.client_objects[id] == 0) return;

    conn.client_objects[id] = 0;
    assert(conn.ids_free_count < CLIENT_OBJECTS_MAX);
    conn.ids_free[conn.ids_free_count] = @intCast(id);
    conn.ids_free_count += 1;
  }

  /// Reserves `size` bytes and `fds` file descriptors for one message and writes its header.
  pub fn message_begin(conn: *Connection, id: u32, opcode: u16, size: u32, fds: u32) !u32 {
    assert(HEADER_SIZE <= size);
    assert(size % 4 == 0);
    assert(fds <= FDS_MAX);

    if (MESSAGE_SIZE_MAX < size) return error.MessageTooLarge;
    if (SEND_WORDS_MAX < conn.send_words_count + size / 4) try conn.flush();
    if (FDS_MAX < conn.send_fds_count + fds) try conn.flush();

    const start = conn.send_words_count;
    conn.put_uint(id);
    conn.put_uint(size << 16 | opcode);
    return start;
  }

  pub fn message_end(conn: *Connection, start: u32) void {
    const size = conn.send_words[start + 1] >> 16;
    assert(start < conn.send_words_count);
    assert((conn.send_words_count - start) * 4 == size);
  }

  pub fn put_uint(conn: *Connection, value: u32) void {
    assert(conn.send_words_count < SEND_WORDS_MAX);
    conn.send_words[conn.send_words_count] = value;
    conn.send_words_count += 1;
  }

  pub fn put_array(conn: *Connection, array: []const u8) void {
    const words = std.mem.alignForward(u32, @intCast(array.len), 4) / 4;
    conn.put_uint(@intCast(array.len));
    assert(conn.send_words_count + words <= SEND_WORDS_MAX);

    const target = conn.send_words[conn.send_words_count..][0..words];
    @memset(target, 0);
    @memcpy(std.mem.sliceAsBytes(target)[0..array.len], array);
    conn.send_words_count += words;
  }

  pub fn put_string(conn: *Connection, string: ?[]const u8) void {
    const s     = string orelse return conn.put_uint(0);
    const words = std.mem.alignForward(u32, @intCast(s.len + 1), 4) / 4;
    conn.put_uint(@intCast(s.len + 1));
    assert(conn.send_words_count + words <= SEND_WORDS_MAX);

    const target = conn.send_words[conn.send_words_count..][0..words];
    @memset(target, 0);
    @memcpy(std.mem.sliceAsBytes(target)[0..s.len], s);
    conn.send_words_count += words;
  }

  pub fn put_fd(conn: *Connection, fd: fd_t) void {
    assert(0 <= fd);
    assert(conn.send_fds_count < FDS_MAX);
    conn.send_fds[conn.send_fds_count] = fd;
    conn.send_fds_count += 1;
  }

  /// Sends all queued messages. File descriptors go with the first `sendmsg`.
  pub fn flush(conn: *Connection) !void {
    if (conn.send_words_count == 0) {
      assert(conn.send_fds_count == 0);
      return;
    }

    var control: [CMSG_HEADER_SIZE + FDS_MAX * @sizeOf(fd_t)]u8 align(8) = undefined;
    const fds_size                                                       = conn.send_fds_count * @sizeOf(fd_t);
    const header: *CmsgHeader                                            = @ptrCast(&control);
    header.* = .{
      .len   = CMSG_HEADER_SIZE + fds_size,
      .level = std.os.linux.SOL.SOCKET,
      .type  = std.os.linux.SCM.RIGHTS,
    };
    const fds_bytes = std.mem.sliceAsBytes(conn.send_fds[0..conn.send_fds_count]);
    @memcpy(control[CMSG_HEADER_SIZE..][0..fds_size], fds_bytes);

    const bytes          = std.mem.sliceAsBytes(conn.send_words[0..conn.send_words_count]);
    var sent: usize      = 0;
    var control_len: u32 = 0;
    if (0 < conn.send_fds_count) control_len = CMSG_HEADER_SIZE + std.mem.alignForward(u32, fds_size, 8);
    for (0..bytes.len) |_| {
      if (bytes.len <= sent) break;
      var iov: std.posix.iovec_const = .{ .base = bytes[sent..].ptr, .len = bytes.len - sent };
      const msg: std.os.linux.msghdr_const = .{
        .name       = null,
        .namelen    = 0,
        .iov        = @ptrCast(&iov),
        .iovlen     = 1,
        .control    = if (control_len == 0) null else &control,
        .controllen = control_len,
        .flags      = 0,
      };
      sent += try os.sendmsg(conn.socket_fd, &msg, std.os.linux.MSG.NOSIGNAL);
      control_len = 0;
    }
    assert(sent == bytes.len);

    conn.send_words_count = 0;
    conn.send_fds_count = 0;
  }

  /// Reads available bytes and file descriptors from the socket. Returns number of bytes read.
  /// Invalidates payloads of previously returned messages.
  pub fn receive(conn: *Connection) !u32 {
    assert(conn.recv_start <= conn.recv_end);
    assert(conn.recv_start % 4 == 0);

    const recv_bytes = std.mem.sliceAsBytes(&conn.recv_words);
    const len_left   = conn.recv_end - conn.recv_start;
    std.mem.copyForwards(u8, recv_bytes[0..len_left], recv_bytes[conn.recv_start..conn.recv_end]);
    conn.recv_start = 0;
    conn.recv_end = len_left;
    assert(conn.recv_end < recv_bytes.len);

    var control: [CMSG_HEADER_SIZE + FDS_MAX * @sizeOf(fd_t)]u8 align(8) = undefined;
    var iov: std.posix.iovec = .{
      .base = recv_bytes[conn.recv_end..].ptr,
      .len  = recv_bytes.len - conn.recv_end,
    };
    var msg: std.os.linux.msghdr = .{
      .name       = null,
      .namelen    = 0,
      .iov        = @ptrCast(&iov),
      .iovlen     = 1,
      .control    = &control,
      .controllen = control.len,
      .flags      = 0,
    };
    const len = os.recvmsg(conn.socket_fd, &msg, std.os.linux.MSG.CMSG_CLOEXEC) catch |e| switch (e) {
      error.WouldBlock => return 0,
      else             => return e,
    };
    if (len == 0) return error.ConnectionClosed;
    if (msg.flags & std.os.linux.MSG.CTRUNC != 0) return error.ControlMessageTruncated;
    conn.recv_end += @intCast(len);

    var offset: usize = 0;
    for (0..control.len / CMSG_HEADER_SIZE) |_| {
      if (msg.controllen < offset + CMSG_HEADER_SIZE) break;
      const header: *const CmsgHeader = @ptrCast(@alignCast(&control[offset]));
      if (header.len < CMSG_HEADER_SIZE) return error.InvalidMessage;
      if (msg.controllen - offset < header.len) return error.InvalidMessage;
      if (header.level == std.os.linux.SOL.SOCKET and header.type == std.os.linux.SCM.RIGHTS) {
        const fds_bytes = control[offset + CMSG_HEADER_SIZE ..][0 .. header.len - CMSG_HEADER_SIZE];
        for (std.mem.bytesAsSlice(fd_t, fds_bytes)) |fd| try conn.fd_push(fd);
      }
      offset += std.mem.alignForward(usize, header.len, 8);
    }
    return @intCast(len);
  }

  fn fd_push(conn: *Connection, fd: fd_t) !void {
    if (RECV_FDS_MAX <= conn.recv_fds_count) {
      os.close(fd);
      return error.TooManyFds;
    }
    conn.recv_fds[(conn.recv_fds_start + conn.recv_fds_count) % RECV_FDS_MAX] = fd;
    conn.recv_fds_count += 1;
  }

  /// Takes the next received file descriptor. Caller owns it.
  pub fn fd_take(conn: *Connection) !fd_t {
    if (conn.recv_fds_count == 0) return error.InvalidMessage;
    const fd = conn.recv_fds[conn.recv_fds_start];
    conn.recv_fds_start = (conn.recv_fds_start + 1) % RECV_FDS_MAX;
    conn.recv_fds_count -= 1;
    return fd;
  }

  /// Returns the next complete received message or null if more bytes are needed.
  /// Payload is valid until the next `receive`.
  pub fn message_next(conn: *Connection) !?Message {
    assert(conn.recv_start <= conn.recv_end);
    assert(conn.recv_start % 4 == 0);

    const len = conn.recv_end - conn.recv_start;
    if (len < HEADER_SIZE) return null;

    const words = conn.recv_words[conn.recv_start / 4 ..];
    const size  = words[1] >> 16;
    if (size < HEADER_SIZE) return error.InvalidMessage;
    if (size % 4 != 0) return error.InvalidMessage;
    if (len < size) return null;

    conn.recv_start += size;
    return .{
      .id      = words[0],
      .opcode  = @truncate(words[1]),
      .payload = words[HEADER_SIZE / 4 .. size / 4],
    };
  }
};

fn test_loopback(conn: *Connection, bytes_count: u32) void {
  const send_bytes = std.mem.sliceAsBytes(conn.send_words[0..conn.send_words_count]);
  const recv_bytes = std.mem.sliceAsBytes(&conn.recv_words);
  @memcpy(recv_bytes[conn.recv_end..][0..bytes_count], send_bytes[0..bytes_count]);
  conn.recv_end += bytes_count;
}

test "string and array round trip" {
  var conn: Connection = undefined;
  conn.init(-1);

  const size  = HEADER_SIZE + string_size("abc") + string_size(null) + array_size("12345") + 4;
  const start = try conn.message_begin(7, 3, size, 0);
  conn.put_string("abc");
  conn.put_string(null);
  conn.put_array("12345");
  conn.put_uint(42);
  conn.message_end(start);
  try std.testing.expectEqual(size / 4, conn.send_words_count);

  test_loopback(&conn, size);
  const message = (try conn.message_next()).?;
  try std.testing.expectEqual(7, message.id);
  try std.testing.expectEqual(3, message.opcode);

  var reader: Reader = .{ .payload = message.payload };
  try std.testing.expectEqualStrings("abc", try reader.string());
  try std.testing.expectEqual(null, try reader.string_optional());
  try std.testing.expectEqualStrings("12345", try reader.array());
  try std.testing.expectEqual(42, try reader.uint());
  try std.testing.expectError(error.InvalidMessage, reader.uint());
  try std.testing.expectEqual(null, try conn.message_next());
}

test "message split across receives" {
  var conn: Connection = undefined;
  conn.init(-1);

  const start = try conn.message_begin(1, 0, HEADER_SIZE + 4, 0);
  conn.put_uint(5);
  conn.message_end(start);

  test_loopback(&conn, 6);
  try std.testing.expectEqual(null, try conn.message_next());
  const send_bytes = std.mem.sliceAsBytes(conn.send_words[0..conn.send_words_count]);
  @memcpy(std.mem.sliceAsBytes(&conn.recv_words)[6..12], send_bytes[6..12]);
  conn.recv_end = 12;
  const message = (try conn.message_next()).?;
  try std.testing.expectEqualSlices(u32, &.{ 5 }, message.payload);
}

test "invalid messages" {
  var conn: Connection = undefined;
  conn.init(-1);
  conn.recv_words[0] = 1;
  conn.recv_words[1] = 4 << 16;
  conn.recv_end = 8;
  try std.testing.expectError(error.InvalidMessage, conn.message_next());

  var reader: Reader = .{ .payload = &.{ 100 } };
  try std.testing.expectError(error.InvalidMessage, reader.array());
  reader = .{ .payload = &.{ 1, 0x41 } };
  try std.testing.expectError(error.InvalidMessage, reader.string());
}

test "fixed" {
  try std.testing.expectEqual(256, @intFromEnum(Fixed.from_f64(1.0)));
  try std.testing.expectEqual(-384, @intFromEnum(Fixed.from_f64(-1.5)));
  try std.testing.expectEqual(2.25, Fixed.to_f64(@enumFromInt(576)));
}

test "object ids are reused only after free" {
  var conn: Connection = undefined;
  conn.init(-1);

  try std.testing.expectEqual(DISPLAY_INTERFACE, conn.object_interface(DISPLAY_ID));
  const a = try conn.object_new(5);
  const b = try conn.object_new(6);
  try std.testing.expectEqual(2, a);
  try std.testing.expectEqual(3, b);
  conn.object_destroy(a);
  try std.testing.expectEqual(5, conn.object_interface(a));
  conn.object_free(a);
  try std.testing.expectEqual(0, conn.object_interface(a));
  try std.testing.expectEqual(a, try conn.object_new(7));
  try std.testing.expectEqual(4, try conn.object_new(7));

  const s = try conn.object_new_server(SERVER_ID_FIRST + 1, 9);
  try std.testing.expectEqual(9, conn.object_interface(s));
  conn.object_destroy(s);
  try std.testing.expectEqual(0, conn.object_interface(s));
  try std.testing.expectError(error.InvalidMessage, conn.object_new_server(5, 9));
}

test "fds are passed in order" {
  var sockets: [2]i32 = undefined;
  try std.testing.expectEqual(0, std.os.linux.socketpair(
    std.os.linux.AF.UNIX,
    std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK,
    0,
    &sockets,
  ));
  defer os.close(sockets[0]);
  defer os.close(sockets[1]);

  var client: Connection = undefined;
  client.init(sockets[0]);
  var server: Connection = undefined;
  server.init(sockets[1]);

  var pipe_fds: [2]i32 = undefined;
  try std.testing.expectEqual(0, std.os.linux.pipe2(&pipe_fds, .{}));
  defer os.close(pipe_fds[0]);
  defer os.close(pipe_fds[1]);

  const start = try client.message_begin(1, 0, HEADER_SIZE, 2);
  client.put_fd(pipe_fds[0]);
  client.put_fd(pipe_fds[1]);
  client.message_end(start);
  try client.flush();

  try std.testing.expectEqual(HEADER_SIZE, try server.receive());
  _ = (try server.message_next()).?;
  const read_fd  = try server.fd_take();
  const write_fd = try server.fd_take();
  defer os.close(read_fd);
  defer os.close(write_fd);
  try std.testing.expectError(error.InvalidMessage, server.fd_take());

  _ = try os.write(write_fd, "x");
  var byte: [1]u8 = undefined;
  try std.testing.expectEqual(1, try os.read(pipe_fds[0], &byte));
  try std.testing.expectEqual(0, try server.receive());
}
