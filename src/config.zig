const std = @import("std");
const types = @import("types.zig");
const composer = @import("composer.zig");

const ProjectConfig = types.ProjectConfig;

// ============================================================================
// PHPCMA Configuration File Parser
// ============================================================================

pub const ConfigError = error{
    FileNotFound,
    InvalidJson,
    MissingField,
    OutOfMemory,
    InvalidPath,
};

/// Configuration parsed from .phpcma.json
pub const PhpcmaConfig = struct {
    config_root: []const u8, // Directory containing .phpcma.json
    scan_paths: []const []const u8, // Parent dirs to scan (e.g., "plugins", "bundles")
    discovered_projects: []const []const u8, // Discovered composer.json paths
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PhpcmaConfig) void {
        for (self.scan_paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.scan_paths);

        for (self.discovered_projects) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.discovered_projects);

        self.allocator.free(self.config_root);
    }
};

/// Parse a .phpcma.json configuration file and discover all composer projects
pub fn parseConfigFile(allocator: std.mem.Allocator, config_path: []const u8) !PhpcmaConfig {
    // Determine root path (directory containing .phpcma.json)
    const config_root = std.fs.path.dirname(config_path) orelse ".";

    // Read the file
    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) return ConfigError.FileNotFound;
        return ConfigError.InvalidPath;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return ConfigError.OutOfMemory;
    };
    defer allocator.free(content);

    // Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return ConfigError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Extract scan_paths array
    const scan_paths_json = root.object.get("scan_paths") orelse {
        return ConfigError.MissingField;
    };

    if (scan_paths_json != .array) {
        return ConfigError.InvalidJson;
    }

    var scan_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (scan_paths.items) |p| allocator.free(p);
        scan_paths.deinit(allocator);
    }

    for (scan_paths_json.array.items) |item| {
        if (item == .string) {
            // Make absolute path
            const abs_path = try std.fs.path.join(allocator, &.{ config_root, item.string });
            try scan_paths.append(allocator, abs_path);
        }
    }

    // Discover composer projects in each scan path
    var discovered: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (discovered.items) |p| allocator.free(p);
        discovered.deinit(allocator);
    }

    for (scan_paths.items) |scan_path| {
        const projects = try discoverComposerProjects(allocator, scan_path);
        defer allocator.free(projects);

        for (projects) |project| {
            try discovered.append(allocator, project);
        }
    }

    return PhpcmaConfig{
        .config_root = try allocator.dupe(u8, config_root),
        .scan_paths = try scan_paths.toOwnedSlice(allocator),
        .discovered_projects = try discovered.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Scan a directory for subdirectories containing composer.json files
fn discoverComposerProjects(allocator: std.mem.Allocator, scan_path: []const u8) ![]const []const u8 {
    var projects: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (projects.items) |p| allocator.free(p);
        projects.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(scan_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return try projects.toOwnedSlice(allocator);
        return err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Only check directories (and symlinks to directories)
        const is_dir = entry.kind == .directory or entry.kind == .sym_link;
        if (!is_dir) continue;

        // Build path to potential composer.json
        const composer_path = try std.fs.path.join(allocator, &.{
            scan_path,
            entry.name,
            "composer.json",
        });
        errdefer allocator.free(composer_path);

        // Check if composer.json exists
        if (std.fs.cwd().access(composer_path, .{})) {
            try projects.append(allocator, composer_path);
        } else |_| {
            allocator.free(composer_path);
        }
    }

    return try projects.toOwnedSlice(allocator);
}

/// Parse all discovered composer projects and return their configs
pub fn parseDiscoveredProjects(allocator: std.mem.Allocator, phpcma_config: *const PhpcmaConfig) ![]ProjectConfig {
    var configs: std.ArrayListUnmanaged(ProjectConfig) = .empty;
    errdefer {
        for (configs.items) |*c| c.deinit();
        configs.deinit(allocator);
    }

    for (phpcma_config.discovered_projects) |composer_path| {
        const config = composer.parseComposerJson(allocator, composer_path) catch |err| {
            std.debug.print("Warning: Failed to parse {s}: {}\n", .{ composer_path, err });
            continue;
        };
        try configs.append(allocator, config);
    }

    return try configs.toOwnedSlice(allocator);
}

/// Discover files from all project configs (without vendor directories)
pub fn discoverFilesFromConfigs(allocator: std.mem.Allocator, configs: []const ProjectConfig) ![]const []const u8 {
    var all_files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (all_files.items) |f| allocator.free(f);
        all_files.deinit(allocator);
    }

    for (configs) |*config| {
        // Use the existing discoverFiles but it will no longer include vendor
        const project_files = try composer.discoverFiles(allocator, config);
        defer allocator.free(project_files);

        for (project_files) |file| {
            try all_files.append(allocator, file);
        }
    }

    return all_files.toOwnedSlice(allocator);
}

// ============================================================================
// Printing
// ============================================================================

pub fn printConfig(phpcma_config: *const PhpcmaConfig, file: std.fs.File) !void {
    const allocator = phpcma_config.allocator;

    try file.writeAll("PHPCMA Configuration:\n");

    const root_msg = try std.fmt.allocPrint(allocator, "  Config Root: {s}\n", .{phpcma_config.config_root});
    defer allocator.free(root_msg);
    try file.writeAll(root_msg);

    try file.writeAll("\n  Scan Paths:\n");
    for (phpcma_config.scan_paths) |path| {
        const path_msg = try std.fmt.allocPrint(allocator, "    - {s}\n", .{path});
        defer allocator.free(path_msg);
        try file.writeAll(path_msg);
    }

    try file.writeAll("\n  Discovered Projects:\n");
    for (phpcma_config.discovered_projects) |path| {
        const path_msg = try std.fmt.allocPrint(allocator, "    - {s}\n", .{path});
        defer allocator.free(path_msg);
        try file.writeAll(path_msg);
    }

    const count_msg = try std.fmt.allocPrint(allocator, "\n  Total: {d} projects\n", .{phpcma_config.discovered_projects.len});
    defer allocator.free(count_msg);
    try file.writeAll(count_msg);
}
