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
    plugins: []const []const u8, // Monorepo-wide default plugins (per-project override wins)
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

        for (self.plugins) |p| {
            self.allocator.free(p);
        }
        self.allocator.free(self.plugins);

        self.allocator.free(self.config_root);
    }
};

/// A called-before constraint from config
pub const CalledBeforeConstraint = struct {
    before: []const u8,
    after: []const u8,
};

/// PHPCMA settings that can appear in .phpcma.json or composer.json extra.phpcma
pub const PhpcmaSettings = struct {
    checks: []const []const u8 = &.{},
    strict: bool = false,
    min_confidence: f64 = 0.0,
    called_before: []const CalledBeforeConstraint = &.{},
    plugins: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},

    pub fn deinit(self: *PhpcmaSettings, allocator: std.mem.Allocator) void {
        for (self.checks) |s| allocator.free(s);
        if (self.checks.len > 0) allocator.free(self.checks);

        for (self.called_before) |cb| {
            allocator.free(cb.before);
            allocator.free(cb.after);
        }
        if (self.called_before.len > 0) allocator.free(self.called_before);

        for (self.plugins) |s| allocator.free(s);
        if (self.plugins.len > 0) allocator.free(self.plugins);

        for (self.exclude) |s| allocator.free(s);
        if (self.exclude.len > 0) allocator.free(self.exclude);
    }
};

/// Parse a "phpcma" JSON object into PhpcmaSettings
pub fn parsePhpcmaSettings(allocator: std.mem.Allocator, obj: std.json.Value) !PhpcmaSettings {
    if (obj != .object) return PhpcmaSettings{};

    var settings = PhpcmaSettings{};

    // checks: string array
    if (obj.object.get("checks")) |checks_val| {
        if (checks_val == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (checks_val.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            settings.checks = try list.toOwnedSlice(allocator);
        }
    }

    // strict: bool
    if (obj.object.get("strict")) |strict_val| {
        if (strict_val == .bool) {
            settings.strict = strict_val.bool;
        }
    }

    // min-confidence: float
    if (obj.object.get("min-confidence")) |mc_val| {
        switch (mc_val) {
            .float => settings.min_confidence = mc_val.float,
            .integer => settings.min_confidence = @floatFromInt(mc_val.integer),
            else => {},
        }
    }

    // called-before: array of {before, after}
    if (obj.object.get("called-before")) |cb_val| {
        if (cb_val == .array) {
            var list: std.ArrayListUnmanaged(CalledBeforeConstraint) = .empty;
            for (cb_val.array.items) |item| {
                if (item == .object) {
                    const before = item.object.get("before") orelse continue;
                    const after = item.object.get("after") orelse continue;
                    if (before != .string or after != .string) continue;
                    try list.append(allocator, .{
                        .before = try allocator.dupe(u8, before.string),
                        .after = try allocator.dupe(u8, after.string),
                    });
                }
            }
            settings.called_before = try list.toOwnedSlice(allocator);
        }
    }

    // plugins: string array
    if (obj.object.get("plugins")) |plugins_val| {
        if (plugins_val == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (plugins_val.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            settings.plugins = try list.toOwnedSlice(allocator);
        }
    }

    // exclude: string array
    if (obj.object.get("exclude")) |exclude_val| {
        if (exclude_val == .array) {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (exclude_val.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            settings.exclude = try list.toOwnedSlice(allocator);
        }
    }

    return settings;
}

/// Extract PhpcmaSettings from a composer.json's extra.phpcma section
pub fn parseComposerExtraPhpcma(allocator: std.mem.Allocator, composer_path: []const u8) !?PhpcmaSettings {
    const file = std.fs.openFileAbsolute(composer_path, .{}) catch {
        return null;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return null;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return null;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const extra = root.object.get("extra") orelse return null;
    if (extra != .object) return null;
    const phpcma = extra.object.get("phpcma") orelse return null;

    return try parsePhpcmaSettings(allocator, phpcma);
}

/// Parse a .phpcma.json configuration file and discover all composer projects
pub fn parseConfigFile(allocator: std.mem.Allocator, config_path: []const u8) !PhpcmaConfig {
    // Determine root path (directory containing .phpcma.json)
    const config_root = std.fs.path.dirname(config_path) orelse ".";

    // Read the file
    const content = std.Io.Dir.cwd().readFileAlloc(types.io, config_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return ConfigError.FileNotFound;
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

    // Optional monorepo-wide default plugin list. Each project's own
    // `extra.phpcma.plugins` (in its composer.json) takes precedence.
    var plugins: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (plugins.items) |p| allocator.free(p);
        plugins.deinit(allocator);
    }
    if (root.object.get("plugins")) |plugins_json| {
        if (plugins_json == .array) {
            for (plugins_json.array.items) |item| {
                if (item == .string) {
                    try plugins.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    return PhpcmaConfig{
        .config_root = try allocator.dupe(u8, config_root),
        .scan_paths = try scan_paths.toOwnedSlice(allocator),
        .discovered_projects = try discovered.toOwnedSlice(allocator),
        .plugins = try plugins.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Scan a directory tree for composer.json files. Recurses so nested package
/// layouts (e.g. `libraries/composer-packages/<pkg>/composer.json`) are found,
/// not just direct children. Stops descending once a directory yields a
/// composer.json (a project boundary — its own `vendor/` etc. must not be
/// indexed) and skips vendor/.git/node_modules and hidden dirs.
fn discoverComposerProjects(allocator: std.mem.Allocator, scan_path: []const u8) ![]const []const u8 {
    var projects: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (projects.items) |p| allocator.free(p);
        projects.deinit(allocator);
    }

    try collectComposerProjects(allocator, scan_path, &projects, 0);

    return try projects.toOwnedSlice(allocator);
}

/// Recursive worker for `discoverComposerProjects`. Bounded depth guards
/// against pathological trees / symlink cycles.
fn collectComposerProjects(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    projects: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
) !void {
    if (depth > 8) return;

    // Skip anything we can't open as a directory (missing paths, symlinks to
    // files such as `vendor/bin/*`, permission issues). Discovery must be
    // robust to a messy tree rather than aborting the whole scan.
    var dir = std.Io.Dir.cwd().openDir(types.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(types.io);

    var it = dir.iterate();
    while (try it.next(types.io)) |entry| {
        const is_dir = entry.kind == .directory or entry.kind == .sym_link;
        if (!is_dir) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue; // .git and other hidden dirs
        if (std.mem.eql(u8, entry.name, "vendor") or
            std.mem.eql(u8, entry.name, "node_modules")) continue;

        const child_dir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(child_dir);

        const composer_path = try std.fs.path.join(allocator, &.{ child_dir, "composer.json" });
        errdefer allocator.free(composer_path);

        if (std.Io.Dir.cwd().access(types.io, composer_path, .{})) {
            // Project boundary: record it and do NOT descend further so we
            // never index this project's own vendored dependencies.
            try projects.append(allocator, composer_path);
        } else |_| {
            allocator.free(composer_path);
            try collectComposerProjects(allocator, child_dir, projects, depth + 1);
        }
    }
}

/// Parse all discovered composer projects and return their configs
pub fn parseDiscoveredProjects(allocator: std.mem.Allocator, phpcma_config: *const PhpcmaConfig) ![]ProjectConfig {
    var configs: std.ArrayListUnmanaged(ProjectConfig) = .empty;
    errdefer {
        for (configs.items) |*c| c.deinit();
        configs.deinit(allocator);
    }

    for (phpcma_config.discovered_projects) |composer_path| {
        var config = composer.parseComposerJson(allocator, composer_path) catch |err| {
            std.debug.print("Warning: Failed to parse {s}: {}\n", .{ composer_path, err });
            continue;
        };
        // A project that doesn't declare its own plugins inherits the
        // monorepo-wide default from .phpcma.json.
        if (config.plugins.len == 0 and phpcma_config.plugins.len > 0) {
            var inherited = try allocator.alloc([]const u8, phpcma_config.plugins.len);
            for (phpcma_config.plugins, 0..) |name, i| inherited[i] = try allocator.dupe(u8, name);
            config.plugins = inherited;
        }
        try configs.append(allocator, config);
    }

    return try configs.toOwnedSlice(allocator);
}

/// Discover files from all project configs (without vendor directories)
pub fn discoverFilesFromConfigs(allocator: std.mem.Allocator, configs: []const ProjectConfig) ![]const []const u8 {
    var all_files: std.ArrayListUnmanaged([]const u8) = .empty;
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

pub fn printConfig(phpcma_config: *const PhpcmaConfig, file: std.Io.File) !void {
    const allocator = phpcma_config.allocator;

    try file.writeStreamingAll(types.io, "PHPCMA Configuration:\n");

    const root_msg = try std.fmt.allocPrint(allocator, "  Config Root: {s}\n", .{phpcma_config.config_root});
    defer allocator.free(root_msg);
    try file.writeStreamingAll(types.io, root_msg);

    try file.writeStreamingAll(types.io, "\n  Scan Paths:\n");
    for (phpcma_config.scan_paths) |path| {
        const path_msg = try std.fmt.allocPrint(allocator, "    - {s}\n", .{path});
        defer allocator.free(path_msg);
        try file.writeStreamingAll(types.io, path_msg);
    }

    try file.writeStreamingAll(types.io, "\n  Discovered Projects:\n");
    for (phpcma_config.discovered_projects) |path| {
        const path_msg = try std.fmt.allocPrint(allocator, "    - {s}\n", .{path});
        defer allocator.free(path_msg);
        try file.writeStreamingAll(types.io, path_msg);
    }

    const count_msg = try std.fmt.allocPrint(allocator, "\n  Total: {d} projects\n", .{phpcma_config.discovered_projects.len});
    defer allocator.free(count_msg);
    try file.writeStreamingAll(types.io, count_msg);
}
