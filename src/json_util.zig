const std = @import("std");

/// Write JSON-escaped string content (without surrounding quotes) to the writer.
/// Use this when you need to embed escaped content inside a manually opened string.
pub fn writeJsonStringContent(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Write a JSON-escaped string value (with surrounding quotes) to the writer.
/// Escapes backslashes, double quotes, and control characters per RFC 8259.
pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringContent(writer, value);
    try writer.writeByte('"');
}

test "writeJsonString escapes backslashes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try writeJsonString(&writer, "Pickware\\ProductSetBundle");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"Pickware\\\\ProductSetBundle\"", result);
}

test "writeJsonString escapes quotes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try writeJsonString(&writer, "say \"hello\"");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"say \\\"hello\\\"\"", result);
}

test "writeJsonString passes plain strings through" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try writeJsonString(&writer, "simple");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"simple\"", result);
}

test "writeJsonString escapes control characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    try writeJsonString(&writer, "a\x01b");
    const result = fbs.getWritten();
    try std.testing.expectEqualStrings("\"a\\u0001b\"", result);
}
