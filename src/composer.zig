const std = @import("std");
const types = @import("types.zig");

const ProjectConfig = types.ProjectConfig;

// ============================================================================
// Composer.json Parser
// ============================================================================

pub const ComposerError = error{
    FileNotFound,
    InvalidJson,
    MissingAutoload,
    OutOfMemory,
    InvalidPath,
};

/// Parse a composer.json file and extract autoload configuration
pub fn parseComposerJson(allocator: std.mem.Allocator, composer_path: []const u8) ComposerError!ProjectConfig {
    // Determine root path (directory containing composer.json)
    const root_path = std.fs.path.dirname(composer_path) orelse ".";

    var config = ProjectConfig.init(allocator, root_path);
    config.composer_path = composer_path;

    // Read the file
    const file = std.fs.openFileAbsolute(composer_path, .{}) catch {
        return ComposerError.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return ComposerError.OutOfMemory;
    };
    defer allocator.free(content);

    // Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return ComposerError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Extract autoload configuration
    if (root.object.get("autoload")) |autoload| {
        try parseAutoloadSection(allocator, &config, autoload, root_path);
    }

    // Also check autoload-dev for test files
    if (root.object.get("autoload-dev")) |autoload_dev| {
        try parseAutoloadSection(allocator, &config, autoload_dev, root_path);
    }

    return config;
}

fn parseAutoloadSection(
    allocator: std.mem.Allocator,
    config: *ProjectConfig,
    autoload: std.json.Value,
    root_path: []const u8,
) !void {
    // Parse PSR-4
    if (autoload.object.get("psr-4")) |psr4| {
        var it = psr4.object.iterator();
        while (it.next()) |entry| {
            const namespace = entry.key_ptr.*;
            var paths: std.ArrayListUnmanaged([]const u8) = .empty;

            switch (entry.value_ptr.*) {
                .string => |path| {
                    const full_path = try std.fs.path.join(allocator, &.{ root_path, path });
                    try paths.append(allocator, full_path);
                },
                .array => |arr| {
                    for (arr.items) |item| {
                        if (item == .string) {
                            const full_path = try std.fs.path.join(allocator, &.{ root_path, item.string });
                            try paths.append(allocator, full_path);
                        }
                    }
                },
                else => {},
            }

            if (paths.items.len > 0) {
                try config.autoload_psr4.put(
                    try allocator.dupe(u8, namespace),
                    try paths.toOwnedSlice(allocator),
                );
            }
        }
    }

    // Parse PSR-0 (legacy)
    if (autoload.object.get("psr-0")) |psr0| {
        var it = psr0.object.iterator();
        while (it.next()) |entry| {
            const namespace = entry.key_ptr.*;
            var paths: std.ArrayListUnmanaged([]const u8) = .empty;

            switch (entry.value_ptr.*) {
                .string => |path| {
                    const full_path = try std.fs.path.join(allocator, &.{ root_path, path });
                    try paths.append(allocator, full_path);
                },
                .array => |arr| {
                    for (arr.items) |item| {
                        if (item == .string) {
                            const full_path = try std.fs.path.join(allocator, &.{ root_path, item.string });
                            try paths.append(allocator, full_path);
                        }
                    }
                },
                else => {},
            }

            if (paths.items.len > 0) {
                try config.autoload_psr0.put(
                    try allocator.dupe(u8, namespace),
                    try paths.toOwnedSlice(allocator),
                );
            }
        }
    }

    // Parse classmap
    if (autoload.object.get("classmap")) |classmap| {
        if (classmap == .array) {
            var paths: std.ArrayListUnmanaged([]const u8) = .empty;
            for (classmap.array.items) |item| {
                if (item == .string) {
                    const full_path = try std.fs.path.join(allocator, &.{ root_path, item.string });
                    try paths.append(allocator, full_path);
                }
            }
            config.autoload_classmap = try paths.toOwnedSlice(allocator);
        }
    }

    // Parse files
    if (autoload.object.get("files")) |files| {
        if (files == .array) {
            var paths: std.ArrayListUnmanaged([]const u8) = .empty;
            for (files.array.items) |item| {
                if (item == .string) {
                    const full_path = try std.fs.path.join(allocator, &.{ root_path, item.string });
                    try paths.append(allocator, full_path);
                }
            }
            config.autoload_files = try paths.toOwnedSlice(allocator);
        }
    }
}

// ============================================================================
// File Discovery
// ============================================================================

/// Discover all PHP files from the project configuration
pub fn discoverFiles(allocator: std.mem.Allocator, config: *const ProjectConfig) ![]const []const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Discover from PSR-4 paths
    var psr4_it = config.autoload_psr4.valueIterator();
    while (psr4_it.next()) |paths| {
        for (paths.*) |path| {
            try walkDirectory(allocator, path, &files);
        }
    }

    // Discover from PSR-0 paths
    var psr0_it = config.autoload_psr0.valueIterator();
    while (psr0_it.next()) |paths| {
        for (paths.*) |path| {
            try walkDirectory(allocator, path, &files);
        }
    }

    // Add classmap paths
    for (config.autoload_classmap) |path| {
        const stat = std.fs.cwd().statFile(path) catch continue;
        if (stat.kind == .directory) {
            try walkDirectory(allocator, path, &files);
        } else if (std.mem.endsWith(u8, path, ".php")) {
            try files.append(allocator, try allocator.dupe(u8, path));
        }
    }

    // Add explicit files
    for (config.autoload_files) |path| {
        if (std.mem.endsWith(u8, path, ".php")) {
            try files.append(allocator, try allocator.dupe(u8, path));
        }
    }

    // NOTE: Vendor directory is no longer indexed.
    // Use .phpcma.json with scan_paths to explicitly include monorepo projects.

    return files.toOwnedSlice(allocator);
}

/// Recursively walk a directory and collect all .php files
/// Skips test files ending in .unit.php or .integration.php
/// Follows symlinks to directories (with cycle detection)
fn walkDirectory(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayListUnmanaged([]const u8)) !void {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        // Free visited keys
        var it = visited.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        visited.deinit();
    }
    try walkDirectoryInternal(allocator, dir_path, files, &visited, 0);
}

fn walkDirectoryInternal(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    visited: *std.StringHashMap(void),
    depth: u32,
) !void {
    // Limit recursion depth to prevent runaway traversal
    if (depth > 50) return;

    // Get real path to handle symlinks properly and detect cycles
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = std.fs.cwd().realpath(dir_path, &real_path_buf) catch dir_path;

    // Check if we've already visited this directory (cycle detection)
    if (visited.contains(real_path)) return;
    try visited.put(try allocator.dupe(u8, real_path), {});

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        // Directory might not exist, skip it
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".php")) {
                    // Skip test files
                    if (std.mem.endsWith(u8, entry.name, ".unit.php") or
                        std.mem.endsWith(u8, entry.name, ".integration.php"))
                    {
                        continue;
                    }
                    try files.append(allocator, try allocator.dupe(u8, full_path));
                }
            },
            .directory => {
                try walkDirectoryInternal(allocator, full_path, files, visited, depth + 1);
            },
            .sym_link => {
                // Follow symlink and check if it's a directory
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                if (stat.kind == .directory) {
                    try walkDirectoryInternal(allocator, full_path, files, visited, depth + 1);
                } else if (stat.kind == .file and std.mem.endsWith(u8, entry.name, ".php")) {
                    // Skip test files
                    if (std.mem.endsWith(u8, entry.name, ".unit.php") or
                        std.mem.endsWith(u8, entry.name, ".integration.php"))
                    {
                        continue;
                    }
                    try files.append(allocator, try allocator.dupe(u8, full_path));
                }
            },
            else => {},
        }
    }
}

/// Get the namespace prefix for a file path based on PSR-4 mapping
pub fn getNamespaceForFile(config: *const ProjectConfig, file_path: []const u8) ?[]const u8 {
    var psr4_it = config.autoload_psr4.iterator();
    while (psr4_it.next()) |entry| {
        const namespace = entry.key_ptr.*;
        const paths = entry.value_ptr.*;

        for (paths) |base_path| {
            if (std.mem.startsWith(u8, file_path, base_path)) {
                // Found matching PSR-4 entry
                return namespace;
            }
        }
    }
    return null;
}

/// Calculate expected FQCN for a class based on file path and PSR-4 mapping
pub fn calculateFQCN(
    allocator: std.mem.Allocator,
    config: *const ProjectConfig,
    file_path: []const u8,
    class_name: []const u8,
) !?[]const u8 {
    var psr4_it = config.autoload_psr4.iterator();
    while (psr4_it.next()) |entry| {
        const namespace_prefix = entry.key_ptr.*;
        const paths = entry.value_ptr.*;

        for (paths) |base_path| {
            if (std.mem.startsWith(u8, file_path, base_path)) {
                // Calculate relative path
                const relative = file_path[base_path.len..];

                // Convert path separators to namespace separators
                // Remove .php extension and leading slash
                var start: usize = 0;
                if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
                    start = 1;
                }

                const without_ext = if (std.mem.endsWith(u8, relative, ".php"))
                    relative[start .. relative.len - 4]
                else
                    relative[start..];

                // Get directory part (without filename)
                const dir_part = std.fs.path.dirname(without_ext) orelse "";

                // Build FQCN
                if (dir_part.len > 0) {
                    // Replace path separators with namespace separators
                    var ns_path = try allocator.alloc(u8, dir_part.len);
                    for (dir_part, 0..) |c, i| {
                        ns_path[i] = if (c == '/' or c == '\\') '\\' else c;
                    }

                    return try std.fmt.allocPrint(allocator, "{s}{s}\\{s}", .{
                        namespace_prefix,
                        ns_path,
                        class_name,
                    });
                } else {
                    return try std.fmt.allocPrint(allocator, "{s}{s}", .{
                        namespace_prefix,
                        class_name,
                    });
                }
            }
        }
    }
    return null;
}

// ============================================================================
// Project Info
// ============================================================================

pub const ProjectInfo = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    php_version: ?[]const u8,
};

/// Extract basic project information from composer.json
pub fn getProjectInfo(allocator: std.mem.Allocator, composer_path: []const u8) !ProjectInfo {
    const file = std.fs.openFileAbsolute(composer_path, .{}) catch {
        return .{ .name = null, .description = null, .php_version = null };
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return .{ .name = null, .description = null, .php_version = null };
    };
    defer parsed.deinit();

    const root = parsed.value;

    var info = ProjectInfo{
        .name = null,
        .description = null,
        .php_version = null,
    };

    if (root.object.get("name")) |name| {
        if (name == .string) {
            info.name = try allocator.dupe(u8, name.string);
        }
    }

    if (root.object.get("description")) |desc| {
        if (desc == .string) {
            info.description = try allocator.dupe(u8, desc.string);
        }
    }

    // Extract PHP version from require
    if (root.object.get("require")) |require| {
        if (require.object.get("php")) |php| {
            if (php == .string) {
                info.php_version = try allocator.dupe(u8, php.string);
            }
        }
    }

    return info;
}

// ============================================================================
// Printing
// ============================================================================

pub fn printConfig(config: *const ProjectConfig, file: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    const writer = &w.interface;

    try writer.writeAll("Project Configuration:\n");

    try writer.print("  Root: {s}\n", .{config.root_path});

    try writer.writeAll("\n  PSR-4 Autoload:\n");
    var psr4_it = config.autoload_psr4.iterator();
    while (psr4_it.next()) |entry| {
        try writer.print("    {s} =>\n", .{entry.key_ptr.*});
        for (entry.value_ptr.*) |path| {
            try writer.print("      - {s}\n", .{path});
        }
    }

    if (config.autoload_psr0.count() > 0) {
        try writer.writeAll("\n  PSR-0 Autoload:\n");
        var psr0_it = config.autoload_psr0.iterator();
        while (psr0_it.next()) |entry| {
            try writer.print("    {s} =>\n", .{entry.key_ptr.*});
            for (entry.value_ptr.*) |path| {
                try writer.print("      - {s}\n", .{path});
            }
        }
    }

    if (config.autoload_classmap.len > 0) {
        try writer.writeAll("\n  Classmap:\n");
        for (config.autoload_classmap) |path| {
            try writer.print("    - {s}\n", .{path});
        }
    }

    if (config.autoload_files.len > 0) {
        try writer.writeAll("\n  Files:\n");
        for (config.autoload_files) |path| {
            try writer.print("    - {s}\n", .{path});
        }
    }

    try writer.flush();
}
