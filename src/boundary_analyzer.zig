const std = @import("std");
const types = @import("types.zig");
const call_analyzer = @import("call_analyzer.zig");
const symbol_table = @import("symbol_table.zig");

const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ProjectConfig = types.ProjectConfig;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const SymbolTable = symbol_table.SymbolTable;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;

// ============================================================================
// Cross-Project Boundary Analyzer
// ============================================================================

/// A call that crosses project boundaries
pub const BoundaryCall = struct {
    caller_fqn: []const u8,
    callee_fqn: []const u8,
    caller_project: []const u8,
    callee_project: []const u8,
    file_path: []const u8,
    line: u32,
};

/// A method that is part of a project's public API surface
pub const ApiMethod = struct {
    fqn: []const u8,
    class_fqcn: []const u8,
    method_name: []const u8,
    visibility: types.Visibility,
    file_path: []const u8,
    used_by_projects: []const []const u8,
};

/// A dependency edge between two projects
pub const ProjectDependency = struct {
    from_project: []const u8,
    to_project: []const u8,
    call_count: usize,
};

/// Per-boundary summary
pub const BoundarySummary = struct {
    from_project: []const u8,
    to_project: []const u8,
    call_count: usize,
    api_methods: []const []const u8,
};

/// Full result of boundary analysis
pub const BoundaryResult = struct {
    boundary_calls: []const BoundaryCall,
    api_surface: []const ApiMethod,
    dependencies: []const ProjectDependency,
    summaries: []const BoundarySummary,
    total_calls: usize,
    cross_project_calls: usize,
    same_project_calls: usize,
    project_count: usize,
};

/// Analyzer for cross-project boundary detection
pub const BoundaryAnalyzer = struct {
    allocator: std.mem.Allocator,
    call_graph: *const ProjectCallGraph,
    project_configs: []const ProjectConfig,
    sym_table: *const SymbolTable,

    pub fn init(
        allocator: std.mem.Allocator,
        call_graph: *const ProjectCallGraph,
        project_configs: []const ProjectConfig,
        sym_table: *const SymbolTable,
    ) BoundaryAnalyzer {
        return .{
            .allocator = allocator,
            .call_graph = call_graph,
            .project_configs = project_configs,
            .sym_table = sym_table,
        };
    }

    /// Determine which project a file belongs to based on its path
    pub fn fileToProject(self: *const BoundaryAnalyzer, file_path: []const u8) ?[]const u8 {
        var best_match: ?[]const u8 = null;
        var best_len: usize = 0;

        for (self.project_configs) |*cfg| {
            if (std.mem.startsWith(u8, file_path, cfg.root_path)) {
                if (cfg.root_path.len > best_len) {
                    best_len = cfg.root_path.len;
                    best_match = cfg.root_path;
                }
            }
        }

        return best_match;
    }

    /// Determine which project an FQCN belongs to by looking up the class in the symbol table
    fn fqcnToProject(self: *const BoundaryAnalyzer, fqcn: []const u8) ?[]const u8 {
        // Extract class FQCN from "Class::method" format
        const class_fqcn = if (std.mem.indexOf(u8, fqcn, "::")) |sep|
            fqcn[0..sep]
        else
            fqcn;

        if (self.sym_table.getClass(class_fqcn)) |class| {
            return self.fileToProject(class.file_path);
        }

        // Try as a function
        if (self.sym_table.getFunction(fqcn)) |func| {
            return self.fileToProject(func.file_path);
        }

        return null;
    }

    /// Run the full boundary analysis
    pub fn analyze(self: *BoundaryAnalyzer) !BoundaryResult {
        var boundary_calls: std.ArrayListUnmanaged(BoundaryCall) = .empty;
        var same_project_count: usize = 0;

        // Track which projects use which methods (for API surface)
        // Key: callee_fqn, Value: set of project paths that call it
        var api_usage = std.StringHashMap(std.StringHashMap(void)).init(self.allocator);
        defer {
            var it = api_usage.valueIterator();
            while (it.next()) |v| v.deinit();
            api_usage.deinit();
        }

        // Track dependency counts: "from\x00to" -> count
        var dep_counts = std.StringHashMap(usize).init(self.allocator);
        defer dep_counts.deinit();

        for (self.call_graph.calls.items) |call| {
            const caller_project = self.fileToProject(call.file_path) orelse continue;
            const callee_fqn = call.resolved_target orelse continue;
            const callee_project = self.fqcnToProject(callee_fqn) orelse continue;

            if (std.mem.eql(u8, caller_project, callee_project)) {
                same_project_count += 1;
                continue;
            }

            // Cross-project call detected
            try boundary_calls.append(self.allocator, .{
                .caller_fqn = call.caller_fqn,
                .callee_fqn = callee_fqn,
                .caller_project = caller_project,
                .callee_project = callee_project,
                .file_path = call.file_path,
                .line = call.line,
            });

            // Track API usage
            const usage_result = try api_usage.getOrPut(callee_fqn);
            if (!usage_result.found_existing) {
                usage_result.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            try usage_result.value_ptr.put(caller_project, {});

            // Track dependency count
            const dep_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ caller_project, callee_project });
            const dep_result = try dep_counts.getOrPut(dep_key);
            if (!dep_result.found_existing) {
                dep_result.value_ptr.* = 0;
            }
            dep_result.value_ptr.* += 1;
        }

        // Build API surface
        var api_surface: std.ArrayListUnmanaged(ApiMethod) = .empty;
        var api_it = api_usage.iterator();
        while (api_it.next()) |entry| {
            const fqn = entry.key_ptr.*;
            const projects_map = entry.value_ptr;

            var used_by: std.ArrayListUnmanaged([]const u8) = .empty;
            var proj_it = projects_map.keyIterator();
            while (proj_it.next()) |proj| {
                try used_by.append(self.allocator, proj.*);
            }

            // Extract class and method names
            const class_fqcn: []const u8 = if (std.mem.indexOf(u8, fqn, "::")) |sep| fqn[0..sep] else fqn;
            const method_name: []const u8 = if (std.mem.indexOf(u8, fqn, "::")) |sep| fqn[sep + 2 ..] else fqn;

            var visibility: types.Visibility = .public;
            var file_path: []const u8 = "";

            if (self.sym_table.getClass(class_fqcn)) |class| {
                file_path = class.file_path;
                if (class.methods.get(method_name)) |method| {
                    visibility = method.visibility;
                    file_path = method.file_path;
                }
            }

            try api_surface.append(self.allocator, .{
                .fqn = fqn,
                .class_fqcn = class_fqcn,
                .method_name = method_name,
                .visibility = visibility,
                .file_path = file_path,
                .used_by_projects = try used_by.toOwnedSlice(self.allocator),
            });
        }

        // Build dependencies
        var dependencies: std.ArrayListUnmanaged(ProjectDependency) = .empty;
        var dep_it = dep_counts.iterator();
        while (dep_it.next()) |entry| {
            const key = entry.key_ptr.*;
            const count = entry.value_ptr.*;

            // Split key on \x00
            if (std.mem.indexOf(u8, key, "\x00")) |sep| {
                try dependencies.append(self.allocator, .{
                    .from_project = key[0..sep],
                    .to_project = key[sep + 1 ..],
                    .call_count = count,
                });
            }
        }

        // Build per-boundary summaries
        var summaries: std.ArrayListUnmanaged(BoundarySummary) = .empty;
        // Group API methods by boundary pair
        var boundary_apis = std.StringHashMap(std.StringHashMap(void)).init(self.allocator);
        defer {
            var it2 = boundary_apis.valueIterator();
            while (it2.next()) |v| v.deinit();
            boundary_apis.deinit();
        }

        for (boundary_calls.items) |bc| {
            const bkey = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ bc.caller_project, bc.callee_project });
            const bresult = try boundary_apis.getOrPut(bkey);
            if (!bresult.found_existing) {
                bresult.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            try bresult.value_ptr.put(bc.callee_fqn, {});
        }

        for (dependencies.items) |dep| {
            const bkey = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ dep.from_project, dep.to_project });
            var api_methods: std.ArrayListUnmanaged([]const u8) = .empty;
            if (boundary_apis.get(bkey)) |methods_map| {
                var m_it = methods_map.keyIterator();
                while (m_it.next()) |m| {
                    try api_methods.append(self.allocator, m.*);
                }
            }

            try summaries.append(self.allocator, .{
                .from_project = dep.from_project,
                .to_project = dep.to_project,
                .call_count = dep.call_count,
                .api_methods = try api_methods.toOwnedSlice(self.allocator),
            });
        }

        // Count unique projects
        var project_set = std.StringHashMap(void).init(self.allocator);
        defer project_set.deinit();
        for (self.project_configs) |*cfg| {
            try project_set.put(cfg.root_path, {});
        }

        return BoundaryResult{
            .boundary_calls = try boundary_calls.toOwnedSlice(self.allocator),
            .api_surface = try api_surface.toOwnedSlice(self.allocator),
            .dependencies = try dependencies.toOwnedSlice(self.allocator),
            .summaries = try summaries.toOwnedSlice(self.allocator),
            .total_calls = same_project_count + boundary_calls.items.len,
            .cross_project_calls = boundary_calls.items.len,
            .same_project_calls = same_project_count,
            .project_count = project_set.count(),
        };
    }

    // ========================================================================
    // Output Formats
    // ========================================================================

    /// Extract a short project name from a root path
    pub fn shortProjectName(root_path: []const u8) []const u8 {
        // Take last path component as the project name
        var last_sep: ?usize = null;
        var second_last_sep: ?usize = null;
        for (root_path, 0..) |c, i| {
            if (c == '/') {
                second_last_sep = last_sep;
                last_sep = i;
            }
        }
        // If root_path ends with '/', use second-to-last segment
        if (last_sep) |ls| {
            if (ls == root_path.len - 1) {
                if (second_last_sep) |sls| {
                    return root_path[sls + 1 .. ls];
                }
                return root_path[0..ls];
            }
            return root_path[ls + 1 ..];
        }
        return root_path;
    }

    /// Output as text format
    pub fn toText(_: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        // Header
        try writer.writeAll("Cross-Project Boundary Analysis\n");
        try writer.writeAll("================================\n\n");

        try writer.print("Projects: {d}\n", .{result.project_count});
        try writer.print("Total resolved calls: {d}\n", .{result.total_calls});
        try writer.print("Same-project calls: {d}\n", .{result.same_project_calls});
        try writer.print("Cross-project calls: {d}\n\n", .{result.cross_project_calls});

        // Dependency summary
        if (result.summaries.len > 0) {
            try writer.writeAll("Project Dependencies:\n");
            try writer.writeAll("---------------------\n");
            for (result.summaries) |summary| {
                try writer.print("  {s} -> {s} ({d} calls, {d} API methods)\n", .{
                    shortProjectName(summary.from_project),
                    shortProjectName(summary.to_project),
                    summary.call_count,
                    summary.api_methods.len,
                });
                for (summary.api_methods) |method| {
                    try writer.print("    - {s}\n", .{method});
                }
            }
            try writer.writeAll("\n");
        }

        // API Surface
        if (result.api_surface.len > 0) {
            try writer.writeAll("Public API Surface (methods used across project boundaries):\n");
            try writer.writeAll("------------------------------------------------------------\n");
            for (result.api_surface) |api| {
                try writer.print("  {s}\n", .{api.fqn});
                try writer.print("    used by: ", .{});
                for (api.used_by_projects, 0..) |proj, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}", .{shortProjectName(proj)});
                }
                try writer.writeAll("\n");
            }
            try writer.writeAll("\n");
        }

        // Cross-project calls
        if (result.boundary_calls.len > 0) {
            try writer.writeAll("Cross-Project Calls:\n");
            try writer.writeAll("--------------------\n");
            for (result.boundary_calls) |bc| {
                try writer.print("  {s} -> {s}\n", .{ bc.caller_fqn, bc.callee_fqn });
                try writer.print("    {s} -> {s} (line {d})\n", .{
                    shortProjectName(bc.caller_project),
                    shortProjectName(bc.callee_project),
                    bc.line,
                });
            }
        }

        try writer.flush();
    }

    /// Output as DOT graph format (cross-project dependency graph)
    pub fn toDot(self: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("digraph ProjectDependencies {\n");
        try writer.writeAll("    rankdir=LR;\n");
        try writer.writeAll("    node [shape=box, fontname=\"Helvetica\", style=filled, fillcolor=\"#e1f5fe\"];\n");
        try writer.writeAll("    edge [fontname=\"Helvetica\", fontsize=10];\n\n");

        // Output project nodes
        var project_set = std.StringHashMap(void).init(self.allocator);
        defer project_set.deinit();
        for (result.dependencies) |dep| {
            try project_set.put(dep.from_project, {});
            try project_set.put(dep.to_project, {});
        }

        var proj_it = project_set.keyIterator();
        while (proj_it.next()) |proj| {
            const name = shortProjectName(proj.*);
            try writer.print("    \"{s}\";\n", .{name});
        }

        try writer.writeAll("\n");

        // Output dependency edges
        for (result.dependencies) |dep| {
            try writer.print("    \"{s}\" -> \"{s}\" [label=\"{d} calls\"];\n", .{
                shortProjectName(dep.from_project),
                shortProjectName(dep.to_project),
                dep.call_count,
            });
        }

        try writer.writeAll("}\n");
        try writer.flush();
    }

    /// Output as JSON format
    pub fn toJson(_: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");

        // Summary
        try writer.print("  \"projects\": {d},\n", .{result.project_count});
        try writer.print("  \"total_calls\": {d},\n", .{result.total_calls});
        try writer.print("  \"same_project_calls\": {d},\n", .{result.same_project_calls});
        try writer.print("  \"cross_project_calls\": {d},\n", .{result.cross_project_calls});

        // Dependencies
        try writer.writeAll("  \"dependencies\": [\n");
        for (result.dependencies, 0..) |dep, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"from\": \"{s}\",\n", .{shortProjectName(dep.from_project)});
            try writer.print("      \"to\": \"{s}\",\n", .{shortProjectName(dep.to_project)});
            try writer.print("      \"call_count\": {d}\n", .{dep.call_count});
            if (i < result.dependencies.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        // API surface
        try writer.writeAll("  \"api_surface\": [\n");
        for (result.api_surface, 0..) |api, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"fqn\": \"{s}\",\n", .{api.fqn});
            try writer.print("      \"class\": \"{s}\",\n", .{api.class_fqcn});
            try writer.print("      \"method\": \"{s}\",\n", .{api.method_name});
            try writer.writeAll("      \"used_by\": [");
            for (api.used_by_projects, 0..) |proj, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{shortProjectName(proj)});
            }
            try writer.writeAll("]\n");
            if (i < result.api_surface.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        // Boundary calls
        try writer.writeAll("  \"boundary_calls\": [\n");
        for (result.boundary_calls, 0..) |bc, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"caller\": \"{s}\",\n", .{bc.caller_fqn});
            try writer.print("      \"callee\": \"{s}\",\n", .{bc.callee_fqn});
            try writer.print("      \"from_project\": \"{s}\",\n", .{shortProjectName(bc.caller_project)});
            try writer.print("      \"to_project\": \"{s}\",\n", .{shortProjectName(bc.callee_project)});
            try writer.print("      \"line\": {d}\n", .{bc.line});
            if (i < result.boundary_calls.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ]\n");

        try writer.writeAll("}\n");
        try writer.flush();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "shortProjectName extracts last component" {
    try std.testing.expectEqualStrings("plugin-a", BoundaryAnalyzer.shortProjectName("/tmp/monorepo/plugins/plugin-a"));
    try std.testing.expectEqualStrings("plugin-a", BoundaryAnalyzer.shortProjectName("/tmp/monorepo/plugins/plugin-a/"));
    try std.testing.expectEqualStrings("simple", BoundaryAnalyzer.shortProjectName("simple"));
    try std.testing.expectEqualStrings("last", BoundaryAnalyzer.shortProjectName("/a/b/last"));
}

test "fileToProject matches longest prefix" {
    const allocator = std.testing.allocator;

    var configs = try allocator.alloc(ProjectConfig, 2);
    defer allocator.free(configs);
    configs[0] = ProjectConfig.init(allocator, "/mono/plugins/a");
    defer configs[0].deinit();
    configs[1] = ProjectConfig.init(allocator, "/mono/plugins/b");
    defer configs[1].deinit();

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    const analyzer = BoundaryAnalyzer.init(allocator, &call_graph, configs, &sym_table);

    try std.testing.expectEqualStrings("/mono/plugins/a", analyzer.fileToProject("/mono/plugins/a/src/Foo.php").?);
    try std.testing.expectEqualStrings("/mono/plugins/b", analyzer.fileToProject("/mono/plugins/b/src/Bar.php").?);
    try std.testing.expect(analyzer.fileToProject("/mono/plugins/c/src/Baz.php") == null);
}

test "same-project calls not flagged" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var class_a = ClassSymbol.init(alloc, "PluginA\\Foo");
    class_a.file_path = "/mono/plugins/a/src/Foo.php";
    try class_a.addMethod(.{
        .name = "doStuff",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 5,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "PluginA\\Foo",
        .file_path = "/mono/plugins/a/src/Foo.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "PluginA\\Bar");
    class_b.file_path = "/mono/plugins/a/src/Bar.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "PluginA\\Bar::run",
        .callee_name = "doStuff",
        .call_type = .method,
        .line = 15,
        .column = 1,
        .file_path = "/mono/plugins/a/src/Bar.php",
        .resolved_target = "PluginA\\Foo::doStuff",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 1);
    configs[0] = ProjectConfig.init(alloc, "/mono/plugins/a");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 0), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 1), result.same_project_calls);
}

test "cross-project call detected" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "PluginA\\Service");
    class_a.file_path = "/mono/plugins/a/src/Service.php";
    try class_a.addMethod(.{
        .name = "help",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 5,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "PluginA\\Service",
        .file_path = "/mono/plugins/a/src/Service.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "PluginB\\Consumer");
    class_b.file_path = "/mono/plugins/b/src/Consumer.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "PluginB\\Consumer::run",
        .callee_name = "help",
        .call_type = .method,
        .line = 20,
        .column = 1,
        .file_path = "/mono/plugins/b/src/Consumer.php",
        .resolved_target = "PluginA\\Service::help",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/plugins/a");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugins/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 1), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.same_project_calls);
    try std.testing.expectEqual(@as(usize, 1), result.boundary_calls.len);
    try std.testing.expectEqualStrings("PluginB\\Consumer::run", result.boundary_calls[0].caller_fqn);
    try std.testing.expectEqualStrings("PluginA\\Service::help", result.boundary_calls[0].callee_fqn);
}

test "API surface extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "PluginA\\Api");
    class_a.file_path = "/mono/plugins/a/src/Api.php";
    try class_a.addMethod(.{
        .name = "getData",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 5,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "PluginA\\Api",
        .file_path = "/mono/plugins/a/src/Api.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "PluginB\\Worker");
    class_b.file_path = "/mono/plugins/b/src/Worker.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "PluginB\\Worker::process",
        .callee_name = "getData",
        .call_type = .method,
        .line = 25,
        .column = 1,
        .file_path = "/mono/plugins/b/src/Worker.php",
        .resolved_target = "PluginA\\Api::getData",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/plugins/a");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugins/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 1), result.api_surface.len);
    try std.testing.expectEqualStrings("PluginA\\Api::getData", result.api_surface[0].fqn);
    try std.testing.expectEqual(@as(usize, 1), result.api_surface[0].used_by_projects.len);
}

test "dependency graph accuracy" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "A\\Svc");
    class_a.file_path = "/m/a/src/Svc.php";
    try class_a.addMethod(.{
        .name = "x",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Svc",
        .file_path = "/m/a/src/Svc.php",
    });
    try class_a.addMethod(.{
        .name = "y",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 4,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Svc",
        .file_path = "/m/a/src/Svc.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "B\\Use");
    class_b.file_path = "/m/b/src/Use.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    // Two cross-project calls from B -> A
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "B\\Use::run",
        .callee_name = "x",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/m/b/src/Use.php",
        .resolved_target = "A\\Svc::x",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "B\\Use::run",
        .callee_name = "y",
        .call_type = .method,
        .line = 11,
        .column = 1,
        .file_path = "/m/b/src/Use.php",
        .resolved_target = "A\\Svc::y",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 1), result.dependencies.len);
    try std.testing.expectEqual(@as(usize, 2), result.dependencies[0].call_count);
    try std.testing.expectEqual(@as(usize, 2), result.cross_project_calls);
}

test "isolated projects have no boundary calls" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Two classes in different projects that don't call each other
    var class_a = ClassSymbol.init(alloc, "A\\Solo");
    class_a.file_path = "/m/a/src/Solo.php";
    try class_a.addMethod(.{
        .name = "internal",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Solo",
        .file_path = "/m/a/src/Solo.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "B\\Solo");
    class_b.file_path = "/m/b/src/Solo.php";
    try class_b.addMethod(.{
        .name = "internal",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "B\\Solo",
        .file_path = "/m/b/src/Solo.php",
    });
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    // Each calls only within its own project
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "A\\Solo::run",
        .callee_name = "internal",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/a/src/Solo.php",
        .resolved_target = "A\\Solo::internal",
        .resolution_confidence = 1.0,
        .resolution_method = .this_reference,
    });
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "B\\Solo::run",
        .callee_name = "internal",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/b/src/Solo.php",
        .resolved_target = "B\\Solo::internal",
        .resolution_confidence = 1.0,
        .resolution_method = .this_reference,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 0), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 2), result.same_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.dependencies.len);
}

test "multiple plugins same bundle not flagged" {
    // Two classes in the same project should NOT produce boundary calls
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_1 = ClassSymbol.init(alloc, "Bundle\\ServiceA");
    class_1.file_path = "/mono/bundles/my-bundle/src/ServiceA.php";
    try class_1.addMethod(.{
        .name = "helper",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "Bundle\\ServiceA",
        .file_path = "/mono/bundles/my-bundle/src/ServiceA.php",
    });
    try sym_table.addClass(class_1);

    var class_2 = ClassSymbol.init(alloc, "Bundle\\ServiceB");
    class_2.file_path = "/mono/bundles/my-bundle/src/ServiceB.php";
    try sym_table.addClass(class_2);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Bundle\\ServiceB::work",
        .callee_name = "helper",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/bundles/my-bundle/src/ServiceB.php",
        .resolved_target = "Bundle\\ServiceA::helper",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 1);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundles/my-bundle");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 0), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 1), result.same_project_calls);
}

test "circular dependency detection" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "A\\Svc");
    class_a.file_path = "/m/a/src/Svc.php";
    try class_a.addMethod(.{
        .name = "doA",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Svc",
        .file_path = "/m/a/src/Svc.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "B\\Svc");
    class_b.file_path = "/m/b/src/Svc.php";
    try class_b.addMethod(.{
        .name = "doB",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "B\\Svc",
        .file_path = "/m/b/src/Svc.php",
    });
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    // A calls B
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "A\\Svc::run",
        .callee_name = "doB",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/a/src/Svc.php",
        .resolved_target = "B\\Svc::doB",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    // B calls A (circular)
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "B\\Svc::run",
        .callee_name = "doA",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/b/src/Svc.php",
        .resolved_target = "A\\Svc::doA",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 2), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 2), result.dependencies.len);

    // Both directions should be present
    var has_a_to_b = false;
    var has_b_to_a = false;
    for (result.dependencies) |dep| {
        if (std.mem.eql(u8, BoundaryAnalyzer.shortProjectName(dep.from_project), "a") and
            std.mem.eql(u8, BoundaryAnalyzer.shortProjectName(dep.to_project), "b"))
        {
            has_a_to_b = true;
        }
        if (std.mem.eql(u8, BoundaryAnalyzer.shortProjectName(dep.from_project), "b") and
            std.mem.eql(u8, BoundaryAnalyzer.shortProjectName(dep.to_project), "a"))
        {
            has_b_to_a = true;
        }
    }
    try std.testing.expect(has_a_to_b);
    try std.testing.expect(has_b_to_a);
}

test "boundary call count per summary" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "A\\Lib");
    class_a.file_path = "/m/a/src/Lib.php";
    try class_a.addMethod(.{
        .name = "fn1",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Lib",
        .file_path = "/m/a/src/Lib.php",
    });
    try class_a.addMethod(.{
        .name = "fn2",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 4,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Lib",
        .file_path = "/m/a/src/Lib.php",
    });
    try class_a.addMethod(.{
        .name = "fn3",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 5,
        .end_line = 6,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "A\\Lib",
        .file_path = "/m/a/src/Lib.php",
    });
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "B\\App");
    class_b.file_path = "/m/b/src/App.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    // 3 cross-project calls from B -> A
    try call_graph.calls.append(alloc, .{ .caller_fqn = "B\\App::go", .callee_name = "fn1", .call_type = .method, .line = 10, .column = 1, .file_path = "/m/b/src/App.php", .resolved_target = "A\\Lib::fn1", .resolution_confidence = 1.0, .resolution_method = .native_type });
    try call_graph.calls.append(alloc, .{ .caller_fqn = "B\\App::go", .callee_name = "fn2", .call_type = .method, .line = 11, .column = 1, .file_path = "/m/b/src/App.php", .resolved_target = "A\\Lib::fn2", .resolution_confidence = 1.0, .resolution_method = .native_type });
    try call_graph.calls.append(alloc, .{ .caller_fqn = "B\\App::go", .callee_name = "fn3", .call_type = .method, .line = 12, .column = 1, .file_path = "/m/b/src/App.php", .resolved_target = "A\\Lib::fn3", .resolution_confidence = 1.0, .resolution_method = .native_type });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var ba = BoundaryAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try ba.analyze();

    try std.testing.expectEqual(@as(usize, 3), result.cross_project_calls);
    try std.testing.expectEqual(@as(usize, 1), result.summaries.len);
    try std.testing.expectEqual(@as(usize, 3), result.summaries[0].call_count);
    try std.testing.expectEqual(@as(usize, 3), result.summaries[0].api_methods.len);
}
