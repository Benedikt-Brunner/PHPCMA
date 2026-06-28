const std = @import("std");
const types = @import("types.zig");
const call_analyzer = @import("call_analyzer.zig");
const symbol_table = @import("symbol_table.zig");
const query = @import("query.zig");
const json_util = @import("json_util.zig");

const ProjectConfig = types.ProjectConfig;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const SymbolTable = symbol_table.SymbolTable;

// ============================================================================
// Cross-Project Boundary Analyzer
// ============================================================================
//
// Ported from the pre-MCP `check-boundaries` CLI subcommand onto the current
// `ProjectIndex` backbone (call_graph + project_configs + sym_table). The core
// `analyze` logic is unchanged; the CLI's text/dot/json file writers were
// dropped in favor of an MCP JSON renderer (see `mcp_server.zig`).
//
// Accuracy note: only *resolved* calls (`resolved_target != null`) can be
// attributed to a callee project, so the report is a lower bound. The result
// carries `unresolved_calls` (calls invisible to this analysis) and the
// `exclude_tests` option so callers can judge / tighten the signal — this is
// the "never silently under-report" guarantee from the iteration plan.

/// A call that crosses project boundaries.
pub const BoundaryCall = struct {
    caller_fqn: []const u8,
    callee_fqn: []const u8,
    caller_project: []const u8,
    callee_project: []const u8,
    file_path: []const u8,
    line: u32,
    confidence: f32,
    is_test: bool,
};

/// A method that is part of a project's public API surface (i.e. called from
/// another project).
pub const ApiMethod = struct {
    fqn: []const u8,
    class_fqcn: []const u8,
    method_name: []const u8,
    visibility: types.Visibility,
    file_path: []const u8,
    used_by_projects: []const []const u8,
};

/// A dependency edge between two projects.
pub const ProjectDependency = struct {
    from_project: []const u8,
    to_project: []const u8,
    call_count: usize,
};

/// Per-boundary summary (the API methods one project exposes to another).
pub const BoundarySummary = struct {
    from_project: []const u8,
    to_project: []const u8,
    call_count: usize,
    api_methods: []const []const u8,
};

/// Full result of boundary analysis.
pub const BoundaryResult = struct {
    boundary_calls: []const BoundaryCall,
    api_surface: []const ApiMethod,
    dependencies: []const ProjectDependency,
    summaries: []const BoundarySummary,
    total_calls: usize,
    cross_project_calls: usize,
    same_project_calls: usize,
    project_count: usize,
    // Caveats — what this analysis could NOT see / chose to drop.
    unresolved_calls: usize, // calls with no resolved callee (invisible here)
    tests_excluded: usize, // cross-project calls dropped by exclude_tests
};

pub const AnalyzeOptions = struct {
    /// Drop cross-project calls whose caller lives in a test file. On by default
    /// so the report reflects production coupling (the common ask).
    exclude_tests: bool = true,
};

/// Analyzer for cross-project boundary detection.
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

    /// Determine which project a file belongs to (longest matching root_path).
    pub fn fileToProject(self: *const BoundaryAnalyzer, file_path: []const u8) ?[]const u8 {
        var best_match: ?[]const u8 = null;
        var best_len: usize = 0;
        for (self.project_configs) |*cfg| {
            if (cfg.root_path.len == 0) continue;
            if (std.mem.startsWith(u8, file_path, cfg.root_path)) {
                if (cfg.root_path.len > best_len) {
                    best_len = cfg.root_path.len;
                    best_match = cfg.root_path;
                }
            }
        }
        return best_match;
    }

    /// Determine which project an FQCN (Class or Class::method) belongs to.
    fn fqcnToProject(self: *const BoundaryAnalyzer, fqcn: []const u8) ?[]const u8 {
        const class_fqcn = if (std.mem.indexOf(u8, fqcn, "::")) |sep| fqcn[0..sep] else fqcn;
        if (self.sym_table.getClass(class_fqcn)) |class| {
            return self.fileToProject(class.file_path);
        }
        if (self.sym_table.getFunction(fqcn)) |func| {
            return self.fileToProject(func.file_path);
        }
        return null;
    }

    /// Run the full boundary analysis. All output is allocated in
    /// `self.allocator` (an arena in the MCP path), freed wholesale after render.
    pub fn analyze(self: *BoundaryAnalyzer, opts: AnalyzeOptions) !BoundaryResult {
        var boundary_calls: std.ArrayListUnmanaged(BoundaryCall) = .empty;
        var same_project_count: usize = 0;
        var unresolved_count: usize = 0;
        var tests_excluded: usize = 0;

        // callee_fqn -> set of caller-project paths (for the API surface).
        var api_usage = std.StringHashMap(std.StringHashMap(void)).init(self.allocator);
        defer {
            var it = api_usage.valueIterator();
            while (it.next()) |v| v.deinit();
            api_usage.deinit();
        }
        // "from\x00to" -> count.
        var dep_counts = std.StringHashMap(usize).init(self.allocator);
        defer dep_counts.deinit();

        for (self.call_graph.calls.items) |call| {
            const callee_fqn = call.resolved_target orelse {
                unresolved_count += 1;
                continue;
            };
            const caller_project = self.fileToProject(call.file_path) orelse continue;
            const callee_project = self.fqcnToProject(callee_fqn) orelse continue;

            if (std.mem.eql(u8, caller_project, callee_project)) {
                same_project_count += 1;
                continue;
            }

            // Cross-project call.
            const caller_is_test = query.isTestFile(call.file_path);
            if (opts.exclude_tests and caller_is_test) {
                tests_excluded += 1;
                continue;
            }

            try boundary_calls.append(self.allocator, .{
                .caller_fqn = call.caller_fqn,
                .callee_fqn = callee_fqn,
                .caller_project = caller_project,
                .callee_project = callee_project,
                .file_path = call.file_path,
                .line = call.line,
                .confidence = call.resolution_confidence,
                .is_test = caller_is_test,
            });

            const usage_result = try api_usage.getOrPut(callee_fqn);
            if (!usage_result.found_existing) {
                usage_result.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            try usage_result.value_ptr.put(caller_project, {});

            const dep_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ caller_project, callee_project });
            const dep_result = try dep_counts.getOrPut(dep_key);
            if (!dep_result.found_existing) dep_result.value_ptr.* = 0;
            dep_result.value_ptr.* += 1;
        }

        // Build the API surface (sorted by FQN for deterministic output).
        var api_surface: std.ArrayListUnmanaged(ApiMethod) = .empty;
        var api_it = api_usage.iterator();
        while (api_it.next()) |entry| {
            const fqn = entry.key_ptr.*;
            var used_by: std.ArrayListUnmanaged([]const u8) = .empty;
            var proj_it = entry.value_ptr.keyIterator();
            while (proj_it.next()) |proj| try used_by.append(self.allocator, proj.*);
            std.mem.sort([]const u8, used_by.items, {}, lessThanStr);

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
        std.mem.sort(ApiMethod, api_surface.items, {}, struct {
            fn lt(_: void, l: ApiMethod, r: ApiMethod) bool {
                return std.mem.order(u8, l.fqn, r.fqn) == .lt;
            }
        }.lt);

        // Build dependency edges (sorted).
        var dependencies: std.ArrayListUnmanaged(ProjectDependency) = .empty;
        var dep_it = dep_counts.iterator();
        while (dep_it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.indexOf(u8, key, "\x00")) |sep| {
                try dependencies.append(self.allocator, .{
                    .from_project = key[0..sep],
                    .to_project = key[sep + 1 ..],
                    .call_count = entry.value_ptr.*,
                });
            }
        }
        std.mem.sort(ProjectDependency, dependencies.items, {}, struct {
            fn lt(_: void, l: ProjectDependency, r: ProjectDependency) bool {
                const c = std.mem.order(u8, l.from_project, r.from_project);
                if (c != .eq) return c == .lt;
                return std.mem.order(u8, l.to_project, r.to_project) == .lt;
            }
        }.lt);

        // Build per-boundary summaries (the API methods grouped by project pair).
        var summaries: std.ArrayListUnmanaged(BoundarySummary) = .empty;
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

        // Count unique projects.
        var project_set = std.StringHashMap(void).init(self.allocator);
        defer project_set.deinit();
        for (self.project_configs) |*cfg| try project_set.put(cfg.root_path, {});

        // Capture the cross-project count BEFORE `toOwnedSlice` empties the list.
        const cross_count = boundary_calls.items.len;

        return BoundaryResult{
            .boundary_calls = try boundary_calls.toOwnedSlice(self.allocator),
            .api_surface = try api_surface.toOwnedSlice(self.allocator),
            .dependencies = try dependencies.toOwnedSlice(self.allocator),
            .summaries = try summaries.toOwnedSlice(self.allocator),
            .total_calls = same_project_count + cross_count,
            .cross_project_calls = cross_count,
            .same_project_calls = same_project_count,
            .project_count = project_set.count(),
            .unresolved_calls = unresolved_count,
            .tests_excluded = tests_excluded,
        };
    }

    /// One caller of the target symbol.
    pub const ImpactCaller = struct {
        caller_fqn: []const u8,
        file_path: []const u8,
        line: u32,
        is_test: bool,
        confidence: f32,
        arg_count: u32, // arguments passed at this call site
        /// Per-positional-argument resolved types at this call site (null where
        /// unresolved). Borrowed from the call graph; outlives this result.
        arg_types: []const ?types.TypeInfo,
        /// How this call site consumes the result (return-narrowing analysis).
        result_used: types.EnhancedFunctionCall.ResultUse,
    };

    /// Declared signature of the target symbol, used to reason about whether a
    /// proposed change is source-breaking for the observed call sites.
    pub const SignatureInfo = struct {
        total_params: u32,
        required_params: u32, // no default, not variadic
        optional_params: u32, // has default or variadic-tail
        has_variadic: bool,
    };

    /// Callers grouped by their project.
    pub const CallerGroup = struct {
        project: []const u8, // root_path ("" = unknown / outside any project)
        is_cross_package: bool,
        callers: []const ImpactCaller,
    };

    /// Blast radius of changing a single symbol (e.g. its signature).
    pub const ImpactResult = struct {
        fqn: []const u8,
        symbol_project: ?[]const u8,
        total_callers: usize,
        cross_package_callers: usize,
        internal_callers: usize,
        groups: []const CallerGroup,
        /// Caveat: unresolved calls sharing the target's short method name —
        /// possible callers the analyzer could not attribute (under-report).
        unresolved_same_name: usize,
        /// Declared signature of the target (null when not found in-project,
        /// e.g. an external symbol).
        signature: ?SignatureInfo,
        /// Smallest / largest argument count observed across counted callers
        /// (both 0 when there are no callers).
        min_caller_args: u32,
        max_caller_args: u32,
    };

    /// Compute the impact (caller blast radius) of a method/function FQN,
    /// grouped by caller project. Only *resolved* calls to exactly `fqn` are
    /// counted; `unresolved_same_name` reports how many same-named calls were
    /// invisible. `opts.exclude_tests` drops test-file callers.
    pub fn impact(self: *BoundaryAnalyzer, fqn: []const u8, opts: AnalyzeOptions) !ImpactResult {
        const symbol_project = self.fqcnToProject(fqn);
        const short_name: []const u8 = if (std.mem.indexOf(u8, fqn, "::")) |sep| fqn[sep + 2 ..] else fqn;

        // project root_path -> list of callers.
        var by_project = std.StringHashMap(std.ArrayListUnmanaged(ImpactCaller)).init(self.allocator);
        defer {
            var vit = by_project.valueIterator();
            while (vit.next()) |v| v.deinit(self.allocator);
            by_project.deinit();
        }

        var unresolved_same_name: usize = 0;
        var min_caller_args: u32 = std.math.maxInt(u32);
        var max_caller_args: u32 = 0;
        for (self.call_graph.calls.items) |call| {
            const target = call.resolved_target orelse {
                if (call.call_type == .method and std.mem.eql(u8, call.callee_name, short_name)) {
                    unresolved_same_name += 1;
                }
                continue;
            };
            if (!std.mem.eql(u8, target, fqn)) continue;

            const caller_is_test = query.isTestFile(call.file_path);
            if (opts.exclude_tests and caller_is_test) continue;

            if (call.arg_count < min_caller_args) min_caller_args = call.arg_count;
            if (call.arg_count > max_caller_args) max_caller_args = call.arg_count;

            const proj = self.fileToProject(call.file_path) orelse "";
            const gop = try by_project.getOrPut(proj);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, .{
                .caller_fqn = call.caller_fqn,
                .file_path = call.file_path,
                .line = call.line,
                .is_test = caller_is_test,
                .confidence = call.resolution_confidence,
                .arg_count = call.arg_count,
                .arg_types = call.arg_types,
                .result_used = call.result_used,
            });
        }

        // Materialize groups (sorted by project for determinism).
        var groups: std.ArrayListUnmanaged(CallerGroup) = .empty;
        var total: usize = 0;
        var cross: usize = 0;
        var internal: usize = 0;
        var it = by_project.iterator();
        while (it.next()) |entry| {
            const proj = entry.key_ptr.*;
            const callers = try entry.value_ptr.toOwnedSlice(self.allocator);
            std.mem.sort(ImpactCaller, callers, {}, struct {
                fn lt(_: void, l: ImpactCaller, r: ImpactCaller) bool {
                    const c = std.mem.order(u8, l.caller_fqn, r.caller_fqn);
                    if (c != .eq) return c == .lt;
                    return l.line < r.line;
                }
            }.lt);
            const is_cross = if (symbol_project) |sp| !std.mem.eql(u8, sp, proj) else false;
            total += callers.len;
            if (is_cross) cross += callers.len else internal += callers.len;
            try groups.append(self.allocator, .{
                .project = proj,
                .is_cross_package = is_cross,
                .callers = callers,
            });
        }
        std.mem.sort(CallerGroup, groups.items, {}, struct {
            fn lt(_: void, l: CallerGroup, r: CallerGroup) bool {
                return std.mem.order(u8, l.project, r.project) == .lt;
            }
        }.lt);

        return ImpactResult{
            .fqn = fqn,
            .symbol_project = symbol_project,
            .total_callers = total,
            .cross_package_callers = cross,
            .internal_callers = internal,
            .groups = try groups.toOwnedSlice(self.allocator),
            .unresolved_same_name = unresolved_same_name,
            .signature = self.lookupSignature(fqn),
            .min_caller_args = if (total == 0) 0 else min_caller_args,
            .max_caller_args = max_caller_args,
        };
    }

    /// Look up the declared signature of `fqn` (Class::method or free function)
    /// from the symbol table, summarizing parameter arity. Returns null when
    /// the symbol is not part of the indexed project (e.g. an external method).
    fn lookupSignature(self: *BoundaryAnalyzer, fqn: []const u8) ?SignatureInfo {
        const params: []const types.ParameterInfo = blk: {
            if (std.mem.indexOf(u8, fqn, "::")) |sep| {
                const class_fqcn = fqn[0..sep];
                const method_name = fqn[sep + 2 ..];
                const method = self.sym_table.resolveMethod(class_fqcn, method_name) orelse return null;
                break :blk method.parameters;
            } else {
                const func = self.sym_table.getFunction(fqn) orelse return null;
                break :blk func.parameters;
            }
        };

        var required: u32 = 0;
        var optional: u32 = 0;
        var has_variadic = false;
        for (params) |p| {
            if (p.is_variadic) {
                has_variadic = true;
                optional += 1; // a variadic tail accepts zero or more args
            } else if (p.has_default) {
                optional += 1;
            } else {
                required += 1;
            }
        }
        return SignatureInfo{
            .total_params = @intCast(params.len),
            .required_params = required,
            .optional_params = optional,
            .has_variadic = has_variadic,
        };
    }

    /// Extract a short project name (last path segment) from a root path.
    pub fn shortProjectName(root_path: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, root_path, "/");
        if (std.mem.lastIndexOf(u8, trimmed, "/")) |i| return trimmed[i + 1 ..];
        return trimmed;
    }

    // ========================================================================
    // Output Formats (used by the `check-boundaries` CLI; the MCP renders its
    // own JSON from `BoundaryResult`).
    // ========================================================================

    pub fn toText(_: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.Io.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(types.io, &buf);
        const writer = &w.interface;

        try writer.writeAll("Cross-Project Boundary Analysis\n");
        try writer.writeAll("================================\n\n");

        try writer.print("Projects: {d}\n", .{result.project_count});
        try writer.print("Total resolved calls: {d}\n", .{result.total_calls});
        try writer.print("Same-project calls: {d}\n", .{result.same_project_calls});
        try writer.print("Cross-project calls: {d}\n\n", .{result.cross_project_calls});

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

    /// Output as DOT graph format (cross-project dependency graph).
    pub fn toDot(self: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.Io.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(types.io, &buf);
        const writer = &w.interface;

        try writer.writeAll("digraph ProjectDependencies {\n");
        try writer.writeAll("    rankdir=LR;\n");
        try writer.writeAll("    node [shape=box, fontname=\"Helvetica\", style=filled, fillcolor=\"#e1f5fe\"];\n");
        try writer.writeAll("    edge [fontname=\"Helvetica\", fontsize=10];\n\n");

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

    /// Output as JSON format.
    pub fn toJson(_: *const BoundaryAnalyzer, result: *const BoundaryResult, file: std.Io.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(types.io, &buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");

        try writer.print("  \"projects\": {d},\n", .{result.project_count});
        try writer.print("  \"total_calls\": {d},\n", .{result.total_calls});
        try writer.print("  \"same_project_calls\": {d},\n", .{result.same_project_calls});
        try writer.print("  \"cross_project_calls\": {d},\n", .{result.cross_project_calls});

        try writer.writeAll("  \"dependencies\": [\n");
        for (result.dependencies, 0..) |dep, i| {
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"from\": ");
            try json_util.writeJsonString(writer, shortProjectName(dep.from_project));
            try writer.writeAll(",\n      \"to\": ");
            try json_util.writeJsonString(writer, shortProjectName(dep.to_project));
            try writer.print(",\n      \"call_count\": {d}\n", .{dep.call_count});
            if (i < result.dependencies.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        try writer.writeAll("  \"api_surface\": [\n");
        for (result.api_surface, 0..) |api, i| {
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"fqn\": ");
            try json_util.writeJsonString(writer, api.fqn);
            try writer.writeAll(",\n      \"class\": ");
            try json_util.writeJsonString(writer, api.class_fqcn);
            try writer.writeAll(",\n      \"method\": ");
            try json_util.writeJsonString(writer, api.method_name);
            try writer.writeAll(",\n      \"used_by\": [");
            for (api.used_by_projects, 0..) |proj, j| {
                if (j > 0) try writer.writeAll(", ");
                try json_util.writeJsonString(writer, shortProjectName(proj));
            }
            try writer.writeAll("]\n");
            if (i < result.api_surface.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        try writer.writeAll("  \"boundary_calls\": [\n");
        for (result.boundary_calls, 0..) |bc, i| {
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"caller\": ");
            try json_util.writeJsonString(writer, bc.caller_fqn);
            try writer.writeAll(",\n      \"callee\": ");
            try json_util.writeJsonString(writer, bc.callee_fqn);
            try writer.writeAll(",\n      \"from_project\": ");
            try json_util.writeJsonString(writer, shortProjectName(bc.caller_project));
            try writer.writeAll(",\n      \"to_project\": ");
            try json_util.writeJsonString(writer, shortProjectName(bc.callee_project));
            try writer.print(",\n      \"line\": {d}\n", .{bc.line});
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

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const project_index = @import("project_index.zig");

fn analyzeFixture(
    a: std.mem.Allocator,
    idx: *project_index.ProjectIndex,
    opts: AnalyzeOptions,
) !BoundaryResult {
    var analyzer = BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    return analyzer.analyze(opts);
}

// Two-project monorepo fixture: ProjA exposes Api::getData (a static method, so
// the call resolves at confidence 1.0); ProjB calls it across the boundary and
// also calls within itself (same-project).
const api_php =
    \\<?php
    \\namespace ProjA;
    \\class Api {
    \\    public static function getData(): void {}
    \\}
;
const consumer_php =
    \\<?php
    \\namespace ProjB;
    \\class Consumer {
    \\    public function run(): void {
    \\        \ProjA\Api::getData();   // cross-project
    \\        \ProjB\Consumer::helper(); // same-project
    \\    }
    \\    public static function helper(): void {}
    \\}
;

fn twoProjectConfigs(a: std.mem.Allocator) ![]ProjectConfig {
    const configs = try a.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(a, "/mono/a");
    configs[1] = ProjectConfig.init(a, "/mono/b");
    return configs;
}

test "boundary: cross-project call detected, same-project ignored" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = try twoProjectConfigs(a);
    const idx = try project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/mono/a/src/Api.php", api_php },
        .{ "/mono/b/src/Consumer.php", consumer_php },
    }, configs);
    defer idx.destroy();

    const result = try analyzeFixture(a, idx, .{});

    // Exactly one cross-project call (getData); the helper() call is same-project.
    try testing.expectEqual(@as(usize, 1), result.cross_project_calls);
    try testing.expect(result.same_project_calls >= 1);
    try testing.expectEqualStrings("ProjB\\Consumer::run", result.boundary_calls[0].caller_fqn);
    try testing.expectEqualStrings("ProjA\\Api::getData", result.boundary_calls[0].callee_fqn);
    try testing.expectEqualStrings("/mono/b", result.boundary_calls[0].caller_project);
    try testing.expectEqualStrings("/mono/a", result.boundary_calls[0].callee_project);

    // API surface: ProjA\Api::getData, used by one project (ProjB).
    try testing.expectEqual(@as(usize, 1), result.api_surface.len);
    try testing.expectEqualStrings("ProjA\\Api::getData", result.api_surface[0].fqn);
    try testing.expectEqual(@as(usize, 1), result.api_surface[0].used_by_projects.len);
}

test "boundary: exclude_tests drops test-file callers" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // A test-file caller in ProjB that crosses into ProjA.
    const test_consumer =
        \\<?php
        \\namespace ProjB;
        \\class ApiTest {
        \\    public function testGetData(): void {
        \\        \ProjA\Api::getData();
        \\    }
        \\}
    ;
    const configs = try twoProjectConfigs(a);
    const idx = try project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/mono/a/src/Api.php", api_php },
        .{ "/mono/b/tests/ApiTest.php", test_consumer },
    }, configs);
    defer idx.destroy();

    // Default (exclude_tests = true): the test caller is dropped, counted.
    const excluded = try analyzeFixture(a, idx, .{});
    try testing.expectEqual(@as(usize, 0), excluded.cross_project_calls);
    try testing.expect(excluded.tests_excluded >= 1);

    // exclude_tests = false: the cross-project call from the test is reported and
    // flagged is_test.
    const included = try analyzeFixture(a, idx, .{ .exclude_tests = false });
    try testing.expectEqual(@as(usize, 1), included.cross_project_calls);
    try testing.expect(included.boundary_calls[0].is_test);
}

test "boundary: shortProjectName takes the last path segment" {
    try testing.expectEqualStrings("a", BoundaryAnalyzer.shortProjectName("/mono/plugins/a"));
    try testing.expectEqualStrings("a", BoundaryAnalyzer.shortProjectName("/mono/plugins/a/"));
    try testing.expectEqualStrings("solo", BoundaryAnalyzer.shortProjectName("solo"));
}

test "impact: cross-package caller grouped and counted" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = try twoProjectConfigs(a);
    const idx = try project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/mono/a/src/Api.php", api_php },
        .{ "/mono/b/src/Consumer.php", consumer_php },
    }, configs);
    defer idx.destroy();

    var analyzer = BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const r = try analyzer.impact("ProjA\\Api::getData", .{});

    try testing.expectEqualStrings("/mono/a", r.symbol_project.?);
    try testing.expectEqual(@as(usize, 1), r.total_callers);
    try testing.expectEqual(@as(usize, 1), r.cross_package_callers);
    try testing.expectEqual(@as(usize, 0), r.internal_callers);
    try testing.expectEqual(@as(usize, 1), r.groups.len);
    try testing.expect(r.groups[0].is_cross_package);
    try testing.expectEqualStrings("ProjB\\Consumer::run", r.groups[0].callers[0].caller_fqn);
}

const sig_php =
    \\<?php
    \\namespace App;
    \\class Repo {
    \\    public function save(int $id, string $name = "x", ...$rest): void {}
    \\}
    \\class Caller {
    \\    public function run(Repo $r): void {
    \\        $r->save(1, "a");
    \\    }
    \\}
;

test "impact: signature arity + call-site arg counts captured" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = try a.alloc(ProjectConfig, 1);
    configs[0] = ProjectConfig.init(a, "/app");
    const idx = try project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/app/src/Repo.php", sig_php },
    }, configs);
    defer idx.destroy();

    var analyzer = BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const r = try analyzer.impact("App\\Repo::save", .{});

    const sig = r.signature orelse return error.TestExpectedSignature;
    try testing.expectEqual(@as(u32, 3), sig.total_params);
    try testing.expectEqual(@as(u32, 1), sig.required_params);
    try testing.expectEqual(@as(u32, 2), sig.optional_params); // default + variadic tail
    try testing.expect(sig.has_variadic);

    // The single caller passes 2 positional args (1, "a").
    try testing.expectEqual(@as(usize, 1), r.total_callers);
    try testing.expectEqual(@as(u32, 2), r.min_caller_args);
    try testing.expectEqual(@as(u32, 2), r.max_caller_args);
    try testing.expectEqual(@as(u32, 2), r.groups[0].callers[0].arg_count);
}

test "impact: internal-only symbol has no cross-package callers" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = try twoProjectConfigs(a);
    const idx = try project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/mono/a/src/Api.php", api_php },
        .{ "/mono/b/src/Consumer.php", consumer_php },
    }, configs);
    defer idx.destroy();

    var analyzer = BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    // helper() is called only from within ProjB (same package).
    const r = try analyzer.impact("ProjB\\Consumer::helper", .{});

    try testing.expectEqual(@as(usize, 1), r.total_callers);
    try testing.expectEqual(@as(usize, 0), r.cross_package_callers);
    try testing.expectEqual(@as(usize, 1), r.internal_callers);
}
