const std = @import("std");
const plugin_interface = @import("plugin_interface.zig");
const symfony_event_plugin = @import("symfony_event_plugin.zig");

const Plugin = plugin_interface.Plugin;

// ============================================================================
// Plugin Registry
// Compile-time registry of all available plugins
// ============================================================================

/// All available plugins (compile-time constant)
pub const available_plugins = [_]Plugin{
    symfony_event_plugin.plugin,
    // Add more plugins here at compile time:
    // doctrine_entity_plugin.plugin,
    // laravel_event_plugin.plugin,
};

/// Get a plugin by name
pub fn getPlugin(name: []const u8) ?*const Plugin {
    for (&available_plugins) |*p| {
        if (std.mem.eql(u8, p.name, name)) {
            return p;
        }
    }
    return null;
}

/// All plugin names, materialized at comptime with static lifetime so a slice
/// to it can be safely returned.
const plugin_names = blk: {
    var names: [available_plugins.len][]const u8 = undefined;
    for (available_plugins, 0..) |p, i| names[i] = p.name;
    break :blk names;
};

/// Get all plugin names (for CLI help)
pub fn getPluginNames() []const []const u8 {
    return &plugin_names;
}

/// Check if a plugin name is valid
pub fn isValidPlugin(name: []const u8) bool {
    return getPlugin(name) != null;
}

/// Get plugin descriptions for help text
pub fn getPluginDescriptions(allocator: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;

    try result.appendSlice(allocator, "Available plugins:\n");
    for (available_plugins) |p| {
        try result.print(allocator, "  {s}: {s}\n", .{ p.name, p.description });
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "getPlugin returns plugin for valid name" {
    const plugin = getPlugin("symfony-events");
    try std.testing.expect(plugin != null);
    try std.testing.expectEqualStrings("symfony-events", plugin.?.name);
}

test "getPlugin returns null for invalid name" {
    const plugin = getPlugin("nonexistent-plugin");
    try std.testing.expect(plugin == null);
}

test "isValidPlugin" {
    try std.testing.expect(isValidPlugin("symfony-events"));
    try std.testing.expect(!isValidPlugin("invalid"));
}

test "getPluginNames returns all names" {
    const names = getPluginNames();
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("symfony-events", names[0]);
}
