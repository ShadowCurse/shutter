const std    = @import("std");
const assert = std.debug.assert;

const fd_t = std.os.linux.fd_t;

// Defined by the protocol (doc/book/src/Protocol.md of wayland):
// - message header is 2 words: object id, then size (upper 16 bits) and opcode (lower 16 bits);
// - `wl_display` is always object 1;
// - client ids are [2, 0xfeffffff], server ids are [0xff000000, 0xffffffff], 0 is null.
pub const HEADER_SIZE = 8;
pub const DISPLAY_ID = 1;
pub const SERVER_ID_FIRST = 0xff000000;

// Limits of libwayland. The protocol does not define them, but compositors built on libwayland
// enforce them:
// - WL_MAX_MESSAGE_SIZE: bigger messages make the server drop the client;
// - MAX_FDS_OUT: most fds sent with one `sendmsg`.
pub const MESSAGE_SIZE_MAX = 4096;
pub const FDS_MAX = 28;

// Limits of this implementation. libwayland allows 0x00f00000 objects on each side.
pub const CLIENT_OBJECTS_MAX = 4096;
pub const SERVER_OBJECTS_MAX = 256;
// Value of `Interface.wl_display` in the generated bindings.
pub const DISPLAY_INTERFACE = 1;

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
  assert(MESSAGE_SIZE_MAX <= std.math.maxInt(u16));
  assert(MESSAGE_SIZE_MAX <= SEND_WORDS_MAX * 4);
  assert(MESSAGE_SIZE_MAX <= RECV_WORDS_MAX * 4);
  assert(CLIENT_OBJECTS_MAX <= std.math.maxInt(u16) + 1);
  assert(DISPLAY_ID < CLIENT_OBJECTS_MAX);
  assert(FDS_MAX * @sizeOf(fd_t) % 8 == 0);
  assert(CMSG_HEADER_SIZE == 16);
}

pub const Error = error{
  // `Connection.connect` could not find or fit the socket path.
  NoXDGRuntimeDir,
  InvalidWaylandDisplay,
  SocketPathTooLong,
  // Socket operations.
  WouldBlock,
  ConnectionClosed,
  ControlMessageTruncated,
  Unexpected,
  // Server sent malformed data or more than the fixed limits allow.
  InvalidMessage,
  TooManyObjects,
  TooManyFds,
  // Request does not fit into a single message.
  MessageTooLarge,
};

// Converts a raw syscall return value into a result or an error.
fn syscall_result(result: usize) Error!usize {
  return switch (std.os.linux.errno(result)) {
    .SUCCESS => result,
    .AGAIN   => error.WouldBlock,
    else     => |e| std.posix.unexpectedErrno(e),
  };
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

  pub fn uint(reader: *Reader) Error!u32 {
    if (reader.payload.len <= reader.index) return error.InvalidMessage;
    const value = reader.payload[reader.index];
    reader.index += 1;
    return value;
  }

  pub fn array(reader: *Reader) Error![]const u8 {
    const len   = try reader.uint();
    const words = std.mem.alignForward(u32, len, 4) / 4;
    if (reader.payload.len - reader.index < words) return error.InvalidMessage;
    const bytes = std.mem.sliceAsBytes(reader.payload[reader.index..][0..words]);
    reader.index += words;
    return bytes[0..len];
  }

  pub fn string_optional(reader: *Reader) Error!?[]const u8 {
    const bytes = try reader.array();
    if (bytes.len == 0) return null;
    if (bytes[bytes.len - 1] != 0) return error.InvalidMessage;
    return bytes[0 .. bytes.len - 1];
  }

  pub fn string(reader: *Reader) Error![]const u8 {
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
  ) Error!void {
    const xrd = xdg_runtime_dir orelse environ.getPosix("XDG_RUNTIME_DIR") orelse
      return error.NoXDGRuntimeDir;
    const wd = wayland_display orelse environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    if (wd.len == 0) return error.InvalidWaylandDisplay;

    const socket_fd: fd_t = @intCast(try syscall_result(std.os.linux.socket(
      std.os.linux.PF.UNIX,
      std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC,
      0,
    )));
    errdefer _ = std.os.linux.close(socket_fd);

    var addr: std.posix.sockaddr.un = .{
      .family = std.os.linux.PF.UNIX,
      .path   = undefined,
    };
    const path = if (wd[0] == '/')
      std.fmt.bufPrint(&addr.path, "{s}", .{ wd }) catch return error.SocketPathTooLong
    else
      std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ xrd, wd }) catch return error.SocketPathTooLong;

    _ = try syscall_result(std.os.linux.connect(
      socket_fd,
      @ptrCast(&addr),
      @offsetOf(std.posix.sockaddr, "data") + @as(u32, @intCast(path.len)),
    ));
    conn.init(socket_fd);
  }

  pub fn object_new(conn: *Connection, interface: u8) Error!u32 {
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
  pub fn object_new_server(conn: *Connection, id: u32, interface: u8) Error!u32 {
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
  pub fn message_begin(conn: *Connection, id: u32, opcode: u16, size: u32, fds: u32) Error!u32 {
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
  pub fn flush(conn: *Connection) Error!void {
    if (conn.send_words_count == 0) {
      assert(conn.send_fds_count == 0);
      return;
    }

    var control: [CMSG_HEADER_SIZE + FDS_MAX * @sizeOf(fd_t)]u8 align(8) = undefined;

    const fds_size            = conn.send_fds_count * @sizeOf(fd_t);
    const header: *CmsgHeader = @ptrCast(&control);
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
      const send_result = std.os.linux.sendmsg(conn.socket_fd, &msg, std.os.linux.MSG.NOSIGNAL);
      sent += try syscall_result(send_result);
      control_len = 0;
    }
    assert(sent == bytes.len);

    conn.send_words_count = 0;
    conn.send_fds_count = 0;
  }

  /// Reads available bytes and file descriptors from the socket. Returns number of bytes read.
  /// Invalidates payloads of previously returned messages.
  pub fn receive(conn: *Connection) Error!u32 {
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
    const recv_result = std.os.linux.recvmsg(conn.socket_fd, &msg, std.os.linux.MSG.CMSG_CLOEXEC);
    const len = syscall_result(recv_result) catch |e| switch (e) {
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

  fn fd_push(conn: *Connection, fd: fd_t) Error!void {
    if (RECV_FDS_MAX <= conn.recv_fds_count) {
      _ = std.os.linux.close(fd);
      return error.TooManyFds;
    }
    conn.recv_fds[(conn.recv_fds_start + conn.recv_fds_count) % RECV_FDS_MAX] = fd;
    conn.recv_fds_count += 1;
  }

  /// Takes the next received file descriptor. Caller owns it.
  pub fn fd_take(conn: *Connection) Error!fd_t {
    if (conn.recv_fds_count == 0) return error.InvalidMessage;
    const fd = conn.recv_fds[conn.recv_fds_start];
    conn.recv_fds_start = (conn.recv_fds_start + 1) % RECV_FDS_MAX;
    conn.recv_fds_count -= 1;
    return fd;
  }

  /// Returns the next complete received message or null if more bytes are needed.
  /// Payload is valid until the next `receive`.
  pub fn message_next(conn: *Connection) Error!?Message {
    assert(conn.recv_start <= conn.recv_end);
    assert(conn.recv_start % 4 == 0);

    const len = conn.recv_end - conn.recv_start;
    if (len < HEADER_SIZE) return null;

    const words = conn.recv_words[conn.recv_start / 4 ..];
    const size  = words[1] >> 16;
    if (size < HEADER_SIZE) return error.InvalidMessage;
    if (size % 4 != 0) return error.InvalidMessage;
    if (MESSAGE_SIZE_MAX < size) return error.InvalidMessage;
    if (len < size) return null;

    conn.recv_start += size;
    return .{
      .id      = words[0],
      .opcode  = @truncate(words[1]),
      .payload = words[HEADER_SIZE / 4 .. size / 4],
    };
  }
};
