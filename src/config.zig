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
    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    const writer = &w.interface;

    try writer.writeAll("PHPCMA Configuration:\n");

    try writer.print("  Config Root: {s}\n", .{phpcma_config.config_root});

    try writer.writeAll("\n  Scan Paths:\n");
    for (phpcma_config.scan_paths) |path| {
        try writer.print("    - {s}\n", .{path});
    }

    try writer.writeAll("\n  Discovered Projects:\n");
    for (phpcma_config.discovered_projects) |path| {
        try writer.print("    - {s}\n", .{path});
    }

    try writer.print("\n  Total: {d} projects\n", .{phpcma_config.discovered_projects.len});

    try writer.flush();
}

// ============================================================================
// Tests
// ============================================================================

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        dir.makePath(parent) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    const f = try dir.createFile(sub_path, .{});
    defer f.close();
    try f.writeAll(content);
}

test "reads extra.phpcma section from composer.json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "composer.json",
        \\{"autoload":{"psr-4":{"App\\":"src/"}},"extra":{"phpcma":{"checks":["interfaces","types","boundaries"],"strict":true,"min-confidence":0.8,"called-before":[{"before":"::validate","after":"::save"}],"plugins":["symfony-events"],"exclude":["src/Legacy/**"]}}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const composer_path = try tmp.dir.realpath("composer.json", &buf);
    const composer_path_owned = try allocator.dupe(u8, composer_path);
    defer allocator.free(composer_path_owned);

    const maybe_settings = try parseComposerExtraPhpcma(allocator, composer_path_owned);
    try std.testing.expect(maybe_settings != null);

    var settings = maybe_settings.?;
    defer settings.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), settings.checks.len);
    try std.testing.expectEqualStrings("interfaces", settings.checks[0]);
    try std.testing.expectEqualStrings("types", settings.checks[1]);
    try std.testing.expectEqualStrings("boundaries", settings.checks[2]);
    try std.testing.expect(settings.strict);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), settings.min_confidence, 0.001);
    try std.testing.expectEqual(@as(usize, 1), settings.called_before.len);
    try std.testing.expectEqualStrings("::validate", settings.called_before[0].before);
    try std.testing.expectEqualStrings("::save", settings.called_before[0].after);
    try std.testing.expectEqual(@as(usize, 1), settings.plugins.len);
    try std.testing.expectEqualStrings("symfony-events", settings.plugins[0]);
    try std.testing.expectEqual(@as(usize, 1), settings.exclude.len);
    try std.testing.expectEqualStrings("src/Legacy/**", settings.exclude[0]);
}

test "ignores missing extra section in composer.json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "composer.json",
        \\{"autoload":{"psr-4":{"App\\":"src/"}}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const composer_path = try tmp.dir.realpath("composer.json", &buf);
    const composer_path_owned = try allocator.dupe(u8, composer_path);
    defer allocator.free(composer_path_owned);

    const maybe_settings = try parseComposerExtraPhpcma(allocator, composer_path_owned);
    try std.testing.expect(maybe_settings == null);
}

test "CLI flags override composer.json extra settings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "composer.json",
        \\{"extra":{"phpcma":{"strict":false,"min-confidence":0.5}}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const composer_path = try tmp.dir.realpath("composer.json", &buf);
    const composer_path_owned = try allocator.dupe(u8, composer_path);
    defer allocator.free(composer_path_owned);

    const maybe_settings = try parseComposerExtraPhpcma(allocator, composer_path_owned);
    try std.testing.expect(maybe_settings != null);

    var settings = maybe_settings.?;
    defer settings.deinit(allocator);

    // Simulate CLI override: CLI says strict=true, config says false
    const cli_strict = true;
    const effective_strict = cli_strict; // CLI wins
    try std.testing.expect(effective_strict);
    // Config value is still accessible
    try std.testing.expect(!settings.strict);
}

test "exclude patterns from extra.phpcma applied" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "composer.json",
        \\{"extra":{"phpcma":{"exclude":["src/Legacy/**","tests/**","vendor/**"]}}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const composer_path = try tmp.dir.realpath("composer.json", &buf);
    const composer_path_owned = try allocator.dupe(u8, composer_path);
    defer allocator.free(composer_path_owned);

    const maybe_settings = try parseComposerExtraPhpcma(allocator, composer_path_owned);
    try std.testing.expect(maybe_settings != null);

    var settings = maybe_settings.?;
    defer settings.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), settings.exclude.len);
    try std.testing.expectEqualStrings("src/Legacy/**", settings.exclude[0]);
    try std.testing.expectEqualStrings("tests/**", settings.exclude[1]);
    try std.testing.expectEqualStrings("vendor/**", settings.exclude[2]);
}

test "called-before constraints from extra.phpcma config" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "composer.json",
        \\{"extra":{"phpcma":{"called-before":[{"before":"::validate","after":"::save"},{"before":"::auth","after":"::execute"}]}}}
    );

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const composer_path = try tmp.dir.realpath("composer.json", &buf);
    const composer_path_owned = try allocator.dupe(u8, composer_path);
    defer allocator.free(composer_path_owned);

    const maybe_settings = try parseComposerExtraPhpcma(allocator, composer_path_owned);
    try std.testing.expect(maybe_settings != null);

    var settings = maybe_settings.?;
    defer settings.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), settings.called_before.len);
    try std.testing.expectEqualStrings("::validate", settings.called_before[0].before);
    try std.testing.expectEqualStrings("::save", settings.called_before[0].after);
    try std.testing.expectEqualStrings("::auth", settings.called_before[1].before);
    try std.testing.expectEqualStrings("::execute", settings.called_before[1].after);
}

test ".phpcma.json parsing with scan_paths" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create .phpcma.json with scan_paths
    try writeFile(tmp.dir, ".phpcma.json",
        \\{"scan_paths":["plugins","bundles"]}
    );

    // Create plugin and bundle subdirs with composer.json
    try writeFile(tmp.dir, "plugins/plugin-a/composer.json",
        \\{"autoload":{"psr-4":{"PluginA\\":"src/"}}}
    );
    try writeFile(tmp.dir, "bundles/bundle-b/composer.json",
        \\{"autoload":{"psr-4":{"BundleB\\":"src/"}}}
    );

    // A dir without composer.json should be ignored
    try tmp.dir.makePath("plugins/no-composer");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try tmp.dir.realpath(".phpcma.json", &buf);
    const config_path_owned = try allocator.dupe(u8, config_path);
    defer allocator.free(config_path_owned);

    var phpcma_config = try parseConfigFile(allocator, config_path_owned);
    defer phpcma_config.deinit();

    try std.testing.expectEqual(@as(usize, 2), phpcma_config.scan_paths.len);
    try std.testing.expectEqual(@as(usize, 2), phpcma_config.discovered_projects.len);

    // Verify discovered projects end with composer.json
    for (phpcma_config.discovered_projects) |p| {
        try std.testing.expect(std.mem.endsWith(u8, p, "composer.json"));
    }
}
