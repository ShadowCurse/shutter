// Unit tests of the wayland runtime (src/wayland_wire.zig) and of the generated bindings.

const std     = @import("std");
const wayland = @import("wayland.zig");

const Connection        = wayland.wire.Connection;
const Reader            = wayland.wire.Reader;
const Fixed             = wayland.wire.Fixed;
const HEADER_SIZE       = wayland.wire.HEADER_SIZE;
const DISPLAY_ID        = wayland.wire.DISPLAY_ID;
const DISPLAY_INTERFACE = wayland.wire.DISPLAY_INTERFACE;
const SERVER_ID_FIRST   = wayland.wire.SERVER_ID_FIRST;
const string_size       = wayland.wire.string_size;
const array_size        = wayland.wire.array_size;
const device_number     = wayland.device_number;
const event_next        = wayland.event_next;
const wl_display        = wayland.wl_display;
const wl_registry       = wayland.wl_registry;
const wl_compositor     = wayland.wl_compositor;

// Forces analysis of every declaration, including all generated interfaces.
test "all declarations compile" {
  std.testing.refAllDecls(wayland);
  inline for (@typeInfo(wayland).@"struct".decls) |decl| {
    const value = @field(wayland, decl.name);
    if (@TypeOf(value) == type) {
      if (@typeInfo(value) == .@"struct") std.testing.refAllDecls(value);
    }
  }
}

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
  defer _ = std.os.linux.close(sockets[0]);
  defer _ = std.os.linux.close(sockets[1]);

  var client: Connection = undefined;
  client.init(sockets[0]);
  var server: Connection = undefined;
  server.init(sockets[1]);

  var pipe_fds: [2]i32 = undefined;
  try std.testing.expectEqual(0, std.os.linux.pipe2(&pipe_fds, .{}));
  defer _ = std.os.linux.close(pipe_fds[0]);
  defer _ = std.os.linux.close(pipe_fds[1]);

  const start = try client.message_begin(1, 0, HEADER_SIZE, 2);
  client.put_fd(pipe_fds[0]);
  client.put_fd(pipe_fds[1]);
  client.message_end(start);
  try client.flush();

  try std.testing.expectEqual(HEADER_SIZE, try server.receive());
  _ = (try server.message_next()).?;
  const read_fd  = try server.fd_take();
  const write_fd = try server.fd_take();
  defer _ = std.os.linux.close(read_fd);
  defer _ = std.os.linux.close(write_fd);
  try std.testing.expectError(error.InvalidMessage, server.fd_take());

  try std.testing.expectEqual(1, std.os.linux.write(write_fd, "x", 1));
  var byte: [1]u8 = undefined;
  try std.testing.expectEqual(1, std.os.linux.read(pipe_fds[0], &byte, 1));
  try std.testing.expectEqual(0, try server.receive());
}

test "device_number" {
  try std.testing.expectEqual(0xe280, device_number(226, 128));
  try std.testing.expectEqual(0x100056723489, device_number(0x1234, 0x56789));
}

test "requests and events" {
  var conn: Connection = undefined;
  conn.init(-1);

  const display: wl_display.Id = @enumFromInt(DISPLAY_ID);
  const registry               = try wl_display.get_registry(&conn, display);
  const compositor             = try wl_registry.bind(&conn, registry, 7, wl_compositor, 4);
  try std.testing.expectEqual(2, @intFromEnum(registry));
  try std.testing.expectEqual(3, @intFromEnum(compositor));
  try std.testing.expectEqualSlices(u32, &.{
    1,          12 << 16 | 1, 2,
    2,          40 << 16 | 0, 7,
    14,         0x635f6c77,   0x6f706d6f,
    0x6f746973, 0x72,         4,
    3,
  }, conn.send_words[0..conn.send_words_count]);

  // Server replies with wl_registry.global and wl_display.delete_id for the registry.
  const reply = [_]u32{
    2, 28 << 16 | 0, 9, 7, 0x735f6c77, 0x6d68, 1,
    1, 12 << 16 | 1, 2,
  };
  @memcpy(conn.recv_words[0..reply.len], &reply);
  conn.recv_end = reply.len * 4;

  const global = (try event_next(&conn)).?;
  try std.testing.expectEqual(2, global.id);
  try std.testing.expectEqualStrings("wl_shm", global.event.wl_registry.global.interface);
  const delete = (try event_next(&conn)).?;
  try std.testing.expectEqual(2, delete.event.wl_display.delete_id.id);
  try std.testing.expectEqual(0, conn.object_interface(2));
  try std.testing.expectEqual(null, try event_next(&conn));
}
