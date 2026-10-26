//! Minimal RFC 6455 WebSocket transport for the sync hub.
//! Server-side framing only: server frames are unmasked, client frames are masked.
const std = @import("std");
const Io = std.Io;

pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const accept_len = 28;
pub const max_frame_payload = 256 * 1024;

pub const Error = error{
    PayloadTooLarge,
    Protocol,
} || Io.Reader.Error || Io.Writer.Error;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Borrowed from the buffer passed to readFrame.
    payload: []const u8,
};

/// Compute the Sec-WebSocket-Accept value for a client Sec-WebSocket-Key.
pub fn acceptKey(client_key: []const u8, out: *[accept_len]u8) ![]const u8 {
    if (client_key.len == 0 or client_key.len > 64) return error.Protocol;
    var joined_buf: [64 + guid.len]u8 = undefined;
    const joined = std.fmt.bufPrint(&joined_buf, "{s}{s}", .{ client_key, guid }) catch return error.Protocol;

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined, &digest, .{});

    return std.base64.standard.Encoder.encode(out[0..out.len], &digest);
}

/// Write an unmasked server-to-client frame.
pub fn writeFrame(writer: *Io.Writer, opcode: Opcode, payload: []const u8) Io.Writer.Error!void {
    try writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode))); // FIN always set
    if (payload.len < 126) {
        try writer.writeByte(@intCast(payload.len));
    } else if (payload.len <= math_max_u16) {
        try writer.writeByte(126);
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, &ext, @intCast(payload.len), .big);
        try writer.writeAll(&ext);
    } else {
        try writer.writeByte(127);
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, &ext, @intCast(payload.len), .big);
        try writer.writeAll(&ext);
    }
    try writer.writeAll(payload);
}

const math_max_u16 = 65535;

/// Read one client-side frame into buf. The payload is unmasked in place.
pub fn readFrame(reader: *Io.Reader, buf: []u8) Error!Frame {
    const b0 = try reader.takeByte();
    const b1 = try reader.takeByte();

    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(b0 & 0x0f);
    const masked = (b1 & 0x80) != 0;
    var len: usize = b1 & 0x7f;

    if (len == 126) {
        const ext = try reader.takeArray(2);
        len = std.mem.readInt(u16, ext, .big);
    } else if (len == 127) {
        const ext = try reader.takeArray(8);
        const wide = std.mem.readInt(u64, ext, .big);
        if (wide > max_frame_payload) return error.PayloadTooLarge;
        len = @intCast(wide);
    }

    if (len > max_frame_payload) return error.PayloadTooLarge;
    if (len > buf.len) return error.PayloadTooLarge;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        mask_key = (try reader.takeArray(4)).*;
    }

    if (len > 0) {
        try reader.readSliceAll(buf[0..len]);
        if (masked) {
            for (buf[0..len], 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }
    }

    return .{ .fin = fin, .opcode = opcode, .payload = buf[0..len] };
}

test "acceptKey matches RFC 6455 section 1.3 example" {
    var out: [accept_len]u8 = undefined;
    const key = try acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", key);
}

test "writeFrame and readFrame round trip for text" {
    var out_buf: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);
    const message = "{\"type\":\"snapshot\",\"seq\":7}";
    try writeFrame(&writer, .text, message);

    var reader = Io.Reader.fixed(writer.buffered());
    var payload_buf: [256]u8 = undefined;
    const frame = try readFrame(&reader, &payload_buf);
    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings(message, frame.payload);
}

test "readFrame decodes masked client frames" {
    // Client frame: FIN + text, length 5, mask key 0x37 0xfa 0x76 0x35,
    // masked payload for "Hello".
    const raw = [_]u8{
        0x81, 0x85, // FIN, masked, len 5
        0x37,       0xfa,       0x76,       0x35, // mask key
        'H' ^ 0x37, 'e' ^ 0xfa, 'l' ^ 0x76, 'l' ^ 0x35,
        'o' ^ 0x37,
    };
    var reader = Io.Reader.fixed(&raw);
    var payload_buf: [64]u8 = undefined;
    const frame = try readFrame(&reader, &payload_buf);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualStrings("Hello", frame.payload);
}

test "extended 16-bit payload length" {
    const payload = @as([300]u8, @splat('x'));
    var out_buf: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&out_buf);
    try writeFrame(&writer, .text, &payload);
    // 2 byte header (7-bit length 126 marker) + 2 byte extended length + payload
    try std.testing.expectEqual(4 + payload.len, writer.buffered().len);

    var reader = Io.Reader.fixed(writer.buffered());
    var payload_buf: [512]u8 = undefined;
    const frame = try readFrame(&reader, &payload_buf);
    try std.testing.expectEqual(payload.len, frame.payload.len);
    try std.testing.expectEqualStrings(&payload, frame.payload);
}
