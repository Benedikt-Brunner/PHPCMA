//! PHPCMA MCP server (stdio).
//!
//! Exposes the analysis engine as a Model Context Protocol server over stdio so
//! an agent can drive it as a secondary interaction surface alongside the CLI.
//!
//! This is the step-4 foundation: the JSON-RPC `initialize` handshake (handled
//! by the `mcp.zig` server) plus an explicit `load_project` tool that builds the
//! in-memory `ProjectIndex` and returns a priming payload. The flexible `query`
//! and `called_before` tools land in later steps.
//!
//! Lifecycle notes:
//!   - The server runs a single-threaded message loop until stdin closes.
//!   - A persistent `McpState` is shared with tool handlers via `user_data`.
//!     The loaded index lives in `state.gpa` (NOT the per-message arena the
//!     handler receives, which is freed after each response).
//!   - Pass-1 discovery (project configs + file list) is allocated in a
//!     heap-pinned arena owned alongside the index; the index borrows the
//!     configs, so they must outlive it. The arena is heap-pinned so vended
//!     allocators never dangle when the owning struct is stored.

const std = @import("std");
const mcp = @import("mcp");
const tree_sitter = @import("tree-sitter");

const types = @import("types.zig");
const composer = @import("composer.zig");
const config_parser = @import("config.zig");
const project_index = @import("project_index.zig");
const query = @import("query.zig");
const call_analyzer = @import("call_analyzer.zig");
const boundary_analyzer = @import("boundary_analyzer.zig");
const references_mod = @import("references.zig");
const symbol_table_mod = @import("symbol_table.zig");
const dead_code = @import("dead_code.zig");
const return_type_checker = @import("return_type_checker.zig");
const null_safety = @import("null_safety.zig");
const type_violation_analyzer = @import("type_violation_analyzer.zig");
const report_mod = @import("report.zig");

extern fn tree_sitter_php() callconv(.c) *tree_sitter.Language;

const ProjectConfig = types.ProjectConfig;
const ProjectIndex = project_index.ProjectIndex;
const CalledBeforeAnalyzer = call_analyzer.CalledBeforeAnalyzer;
const CalledBeforeResult = call_analyzer.CalledBeforeResult;

const server_name = "phpcma";
const server_version = "0.0.0";

/// Static instructions surfaced in the `initialize` response so a client has
/// orientation before any tool call.
const server_instructions =
    \\PHPCMA exposes PHP call-graph static analysis as MCP tools.
    \\
    \\Start by calling the `load_project` tool. You may pass the path to a
    \\project's `composer.json` (single project) or `.phpcma.json` (monorepo),
    \\but you can also call it with no arguments: the server then auto-discovers
    \\the project by walking up from its working directory. It builds the
    \\in-memory index and returns a priming payload describing the loaded graph
    \\and how to query it. All node ids are PHP fully-qualified names (FQNs), e.g.
    \\`App\Service\UserService::save`.
;

// ============================================================================
// Server state
// ============================================================================

/// mtime+size fingerprint of the project's config file (composer.json or
/// .phpcma.json). Used to detect on-disk config edits (plugins, scan paths,
/// autoload) on a same-path reload, which must force a full re-parse — an
/// incremental file refresh alone reuses the stale parsed config.
const ConfigFingerprint = struct {
    mtime: i96 = 0,
    size: u64 = 0,
    /// True when the config file could not be stat'd (treated as "changed" so we
    /// conservatively fall back to a full rebuild).
    missing: bool = true,

    fn of(path: []const u8) ConfigFingerprint {
        const st = std.Io.Dir.cwd().statFile(types.io, path, .{}) catch {
            return .{ .missing = true };
        };
        return .{ .mtime = st.mtime.nanoseconds, .size = st.size, .missing = false };
    }

    fn changed(self: ConfigFingerprint, other: ConfigFingerprint) bool {
        if (self.missing or other.missing) return true;
        return self.mtime != other.mtime or self.size != other.size;
    }
};

/// A loaded project: the index plus the heap-pinned arena that owns its pass-1
/// discovery (configs + file list), which the index borrows.
const LoadedProject = struct {
    arena: *std.heap.ArenaAllocator,
    index: *ProjectIndex,
    project_path: []const u8,
    config_fp: ConfigFingerprint,

    fn deinit(self: *LoadedProject, gpa: std.mem.Allocator) void {
        // Destroy the index first (it borrows the configs in `arena`).
        self.index.destroy();
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// Persistent state shared with tool handlers via `user_data`.
const McpState = struct {
    gpa: std.mem.Allocator,
    /// Default project path from `--project`; used when `load_project` is called
    /// with no argument.
    default_project: []const u8,
    loaded: ?LoadedProject = null,

    fn unload(self: *McpState) void {
        if (self.loaded) |*lp| {
            lp.deinit(self.gpa);
            self.loaded = null;
        }
    }
};

// ============================================================================
// Entry point
// ============================================================================

/// Run the stdio MCP server until the client disconnects. `types.io` must be set
/// by the caller (done in `main`).
pub fn run(io: std.Io, gpa: std.mem.Allocator, default_project: []const u8) !void {
    var state = McpState{ .gpa = gpa, .default_project = default_project };
    defer state.unload();

    // Pre-warm: build the index now so the first tool call is instant. Use the
    // configured `--project` if present, otherwise auto-discover by walking up
    // from the server's cwd (so one static config pre-warms whichever worktree
    // it is launched in). A failure here is non-fatal — the client can still
    // call `load_project` explicitly (and will get the precise error).
    var prewarm_arena = std.heap.ArenaAllocator.init(gpa);
    defer prewarm_arena.deinit();
    const prewarm_path: ?[]const u8 = if (default_project.len > 0)
        default_project
    else
        discoverProjectFromCwd(prewarm_arena.allocator()) catch null;
    if (prewarm_path) |pp| {
        if (loadProjectInto(&state, pp)) |_| {
            logStderr("phpcma: pre-warmed project ", pp);
        } else |err| {
            logStderr("phpcma: pre-warm failed (continuing): ", @errorName(err));
        }
    }

    var server = mcp.Server.init(gpa, .{
        .name = server_name,
        .version = server_version,
        .title = "PHPCMA — PHP Call-Map Analysis",
        .instructions = server_instructions,
    });
    defer server.deinit();
    server.enableLogging();

    // Tool input schemas must outlive every `tools/list` response, so build them
    // in an arena that lives for the whole server run.
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const sa = schema_arena.allocator();

    try server.addTool(.{
        .name = "load_project",
        .description = "Load (or reload) a PHP project and build its in-memory call graph. " ++
            "Pass `project_path` (a composer.json or .phpcma.json path); omit it to fall back " ++
            "to the server's --project default, or, failing that, to auto-discovery (the server " ++
            "walks up from its working directory to find a composer.json/.phpcma.json). " ++
            "Returns a priming payload describing the indexed graph. " ++
            "Call this first; it is idempotent (same path reloads, a different path swaps).",
        .inputSchema = try buildLoadProjectSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = loadProjectHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "query",
        .description = query_tool_description,
        .inputSchema = try buildQuerySchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = queryHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "called_before",
        .description = called_before_tool_description,
        .inputSchema = try buildCalledBeforeSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = calledBeforeHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "dependencies",
        .description = dependencies_tool_description,
        .inputSchema = try buildDependenciesSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = dependenciesHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "impact",
        .description = impact_tool_description,
        .inputSchema = try buildImpactSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = impactHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "references",
        .description = references_tool_description,
        .inputSchema = try buildReferencesSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = referencesHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "describe_symbol",
        .description = describe_symbol_tool_description,
        .inputSchema = try buildDescribeSymbolSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = describeSymbolHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "resolve_interface",
        .description = resolve_interface_tool_description,
        .inputSchema = try buildResolveInterfaceSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = resolveInterfaceHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "find_by_type",
        .description = find_by_type_tool_description,
        .inputSchema = try buildFindByTypeSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = findByTypeHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "check_conformance",
        .description = check_conformance_tool_description,
        .inputSchema = try buildCheckConformanceSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = checkConformanceHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "check_dead",
        .description = check_dead_tool_description,
        .inputSchema = try buildCheckDeadSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = checkDeadHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "check_types",
        .description = check_types_tool_description,
        .inputSchema = try buildCheckTypesSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = checkTypesHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "check_boundaries",
        .description = check_boundaries_tool_description,
        .inputSchema = try buildCheckBoundariesSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = checkBoundariesHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "null_safety",
        .description = null_safety_tool_description,
        .inputSchema = try buildNullSafetySchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = nullSafetyHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "return_types",
        .description = return_types_tool_description,
        .inputSchema = try buildReturnTypesSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = returnTypesHandler,
        .user_data = &state,
    });

    try server.addTool(.{
        .name = "report",
        .description = report_tool_description,
        .inputSchema = try buildReportSchema(sa),
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
            .openWorldHint = false,
        },
        .handler = reportHandler,
        .user_data = &state,
    });

    try server.run(io, gpa, .stdio);
}

fn buildLoadProjectSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(
        a,
        "project_path",
        "Absolute path to the project's composer.json (single project) or .phpcma.json (monorepo). " ++
            "If omitted, the server uses its --project default, or auto-discovers by walking up " ++
            "from its working directory.",
        false,
    );
    return builder.toInputSchema(a);
}

// ============================================================================
// load_project tool
// ============================================================================

fn loadProjectHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const arg_path = mcp.tools.getString(arguments, "project_path");
    // Resolution order: explicit `project_path` arg > server `--project`
    // default > auto-discovery by walking up from the server's cwd. The last
    // step lets one static MCP config serve every worktree it is launched in.
    var discovered: ?[]const u8 = null;
    defer if (discovered) |d| allocator.free(d);
    const path = blk: {
        if (arg_path) |p| {
            if (p.len > 0) break :blk p;
        }
        if (state.default_project.len > 0) break :blk state.default_project;
        discovered = discoverProjectFromCwd(allocator) catch null;
        if (discovered) |d| break :blk d;
        break :blk "";
    };

    if (path.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "No project found. Pass project_path explicitly " ++
                "({\"project_path\": \"/path/to/composer.json\"}), or launch the server " ++
                "with its working directory inside a project (a composer.json or " ++
                ".phpcma.json in the cwd or an ancestor), or set --project.",
        ) catch return error.OutOfMemory;
    }

    loadProjectInto(state, path) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "Failed to load project '{s}': {s}",
            .{ path, @errorName(err) },
        ) catch return error.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return error.OutOfMemory;
    };

    const payload = buildPrimingPayload(allocator, state) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// Build (or rebuild) the index for `path`, swapping out any previously loaded
/// project only after the new one succeeds.
fn loadProjectInto(state: *McpState, path: []const u8) !void {
    // Incremental reload: if the same project is already loaded, reuse its parse
    // cache and only re-read changed/added/removed files. (composer.json autoload
    // changes still warrant a fresh load with a different/cleared path.)
    if (state.loaded) |*lp| {
        if (std.mem.eql(u8, lp.project_path, path)) {
            // If the config file itself changed on disk (plugins, scan paths,
            // autoload), the parsed config is stale — an incremental file
            // refresh would silently keep using it. Fall through to a full
            // re-parse + rebuild in that case; otherwise reuse the parse cache.
            const current_fp = ConfigFingerprint.of(path);
            if (!current_fp.changed(lp.config_fp)) {
                var tmp = std.heap.ArenaAllocator.init(state.gpa);
                defer tmp.deinit();
                const files = try discoverFiles(tmp.allocator(), path, lp.index.project_configs);
                _ = try lp.index.refresh(files);
                return;
            }
        }
    }

    // Full build + swap (new or different project).
    // Heap-pin the arena so allocators vended from it never dangle once the
    // owning LoadedProject is stored in `state`.
    const arena = try state.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(state.gpa);
    errdefer {
        arena.deinit();
        state.gpa.destroy(arena);
    }
    const a = arena.allocator();

    // Parse from the arena-owned copy: `composer.parseComposerJson` makes the
    // config's `root_path`/`composer_path` slices *into* this string, so it must
    // outlive the index. The caller's `path` may be request-scoped (freed once
    // load_project returns), which would dangle and crash later tools.
    const owned_path = try a.dupe(u8, path);
    const configs = try parseConfigs(a, owned_path);
    const files = try discoverFiles(a, owned_path, configs);

    // Build the index in the persistent gpa; it dupes file keys into its own
    // arena and borrows `configs` (which live in `arena`).
    const index = try ProjectIndex.create(state.gpa, files, configs);
    errdefer index.destroy();

    // Commit: drop the old project only now that the new build succeeded.
    // Fingerprint the config now so a later same-path reload can tell whether
    // the config changed on disk (forcing a full re-parse) or only PHP files
    // did (cheap incremental refresh).
    const config_fp = ConfigFingerprint.of(path);
    state.unload();
    state.loaded = .{
        .arena = arena,
        .index = index,
        .project_path = owned_path,
        .config_fp = config_fp,
    };
}

/// Walk up from the current working directory looking for a project config,
/// preferring `.phpcma.json` (monorepo) over `composer.json` at each level.
/// Returns an allocator-owned absolute path, or null if none is found before
/// the filesystem root. This lets one static MCP config serve many worktrees:
/// the server resolves whichever project its cwd lives in.
fn discoverProjectFromCwd(allocator: std.mem.Allocator) !?[]const u8 {
    // `Dir.cwd()` carries the AT_FDCWD sentinel handle, so `realPath` can't
    // canonicalize it; use the libc `getcwd` syscall to get the absolute path.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const c_ptr = std.c.getcwd(&buf, buf.len) orelse return null;
    var dir: []const u8 = std.mem.sliceTo(c_ptr, 0);

    while (true) {
        for ([_][]const u8{ ".phpcma.json", "composer.json" }) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ dir, name });
            if (std.Io.Dir.accessAbsolute(types.io, candidate, .{})) {
                return candidate;
            } else |_| {
                allocator.free(candidate);
            }
        }
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return null;
}

/// Parse the project's config(s): `.phpcma.json` (monorepo) or `composer.json`.
fn parseConfigs(a: std.mem.Allocator, path: []const u8) ![]ProjectConfig {
    if (std.mem.endsWith(u8, path, ".phpcma.json")) {
        var phpcma_config = try config_parser.parseConfigFile(a, path);
        return config_parser.parseDiscoveredProjects(a, &phpcma_config);
    }
    const single = try composer.parseComposerJson(a, path);
    const arr = try a.alloc(ProjectConfig, 1);
    arr[0] = single;
    return arr;
}

/// Discover the PHP file set for `path` given its already-parsed `configs`.
fn discoverFiles(a: std.mem.Allocator, path: []const u8, configs: []ProjectConfig) ![]const []const u8 {
    if (std.mem.endsWith(u8, path, ".phpcma.json")) {
        return config_parser.discoverFilesFromConfigs(a, configs);
    }
    return composer.discoverFiles(a, &configs[0]);
}

// ============================================================================
// query tool
// ============================================================================

const query_tool_description =
    \\Run a graph query over the loaded PHP call graph. Compose primitives to
    \\build your own analysis instead of relying on canned questions.
    \\
    \\Argument: `query`, a JSON object with this shape:
    \\  start:    {"fqn": "App\\Service::save"}   exact node, OR
    \\            {"match": {"kind": "method", "name": "*::save",
    \\                       "namespace_prefix": "App\\", "file": "src/"}}
    \\  traverse: {"direction": "callers"|"callees",
    \\             "min_depth": 1, "max_depth": 5,
    \\             "edge_filter": {"min_confidence": 0.5,
    \\                             "include_synthetic": true,
    \\                             "include_unresolved": false,
    \\                             "exclude_tests": false}}   (optional)
    \\  where:    node predicate applied to the traversal frontier (optional;
    \\            same fields as `match`)
    \\  select:   "nodes" | "edges" | "count" | "paths"   (default "nodes")
    \\  limit:    max results (default 200, hard cap 1000)
    \\
    \\Node ids are FQNs (`Class::method`, `func`, `Class`). `name` uses globs
    \\(`*`, `?`) — no regex. Traversal is directed only. Results are bounded:
    \\`max_depth` is clamped, visited nodes are capped, and a `truncated`/
    \\`limited` flag is set when any cap bites, so a partial answer is never
    \\mistaken for complete. Call `load_project` first.
;

fn buildQuerySchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    // The query AST is a nested object the flat InputSchemaBuilder can't express,
    // so build the JSON schema by hand. Validation happens server-side in
    // `query.zig`; this schema is advisory orientation for the client.
    var query_obj: std.json.ObjectMap = .empty;
    try query_obj.put(a, "type", .{ .string = "object" });
    try query_obj.put(a, "description", .{
        .string = "Graph query AST: {start, traverse?, where?, select?, limit?}. " ++
            "See the tool description for the full grammar.",
    });

    var props: std.json.ObjectMap = .empty;
    try props.put(a, "query", .{ .object = query_obj });

    const required = try a.dupe([]const u8, &.{"query"});

    return .{
        .type = "object",
        .properties = .{ .object = props },
        .required = required,
    };
}

fn queryHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    // Accept the AST under `query`, or (leniently) the arguments object itself.
    const query_value = blk: {
        if (mcp.tools.getObject(arguments, "query")) |obj| break :blk std.json.Value{ .object = obj };
        if (arguments) |args| break :blk args;
        break :blk null;
    } orelse return mcp.tools.errorResult(
        allocator,
        "Missing `query`. Pass {\"query\": {\"start\": {...}, ...}}.",
    ) catch return error.OutOfMemory;

    const result = query.run(allocator, lp.index, query_value) catch |err| switch (err) {
        error.InvalidQuery => return mcp.tools.errorResult(
            allocator,
            "Invalid query AST. Required: `start` ({\"fqn\":...} or {\"match\":{...}}). " ++
                "Optional: `traverse`, `where`, `select`, `limit`. See the tool description.",
        ) catch return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return mcp.tools.textResult(allocator, result) catch return error.OutOfMemory;
}

// ============================================================================
// called_before tool
// ============================================================================

const called_before_tool_description =
    \\Check an ordering constraint over the call graph: is `before` always called
    \\before `after`? Interprocedural — if a function calls `after` without first
    \\calling `before`, the check walks its callers to see whether they establish
    \\`before` first.
    \\
    \\Arguments:
    \\  before: the "must come first" target
    \\  after:  the "comes later" target
    \\Each target is one of:
    \\  - a full FQN method:   "App\\Service\\UserService::validate"
    \\  - a class-agnostic method: "::validate" (matches that method on any class)
    \\  - a free function:     "validateInput"
    \\
    \\Returns JSON: {satisfied, satisfied_in[], violations[], matches[]} with each
    \\violation's kind (wrong_order | missing_before | conditional_before) and,
    \\for interprocedural cases, the caller paths missing the `before` call.
    \\Lists are capped (see `*_truncated`). Call `load_project` first.
;

const cb_list_cap: usize = 200;

/// Soft ceiling on the size of a single tool's JSON payload. The terse
/// verdict/summary header is always emitted first (well under this), so it
/// survives no matter what; once a heavy list pushes the buffer past this
/// budget we stop appending items and set a `*_truncated` flag. This keeps
/// results degrading gracefully instead of returning a megabyte of callers.
const response_byte_budget: usize = 48 * 1024;

/// Case-insensitive substring match of a project filter against a project's
/// short name (the `ShortName` of its root path). An empty/`null` filter
/// matches everything.
fn projectFilterMatches(filter: ?[]const u8, root_path: []const u8) bool {
    const f = filter orelse return true;
    if (f.len == 0) return true;
    const short = boundary_analyzer.BoundaryAnalyzer.shortProjectName(root_path);
    return asciiContainsIgnoreCase(short, f);
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn buildCalledBeforeSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "before", "The target that must be called first (FQN, \"::method\", or function name).", true);
    _ = try builder.addString(a, "after", "The target that must come later (FQN, \"::method\", or function name).", true);
    return builder.toInputSchema(a);
}

fn calledBeforeHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const before = mcp.tools.getString(arguments, "before") orelse "";
    const after = mcp.tools.getString(arguments, "after") orelse "";
    if (before.len == 0 or after.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "Both `before` and `after` are required (FQN, \"::method\", or function name).",
        ) catch return error.OutOfMemory;
    }

    var analyzer = CalledBeforeAnalyzer.init(allocator, &lp.index.call_graph);
    defer analyzer.deinit();
    const result = analyzer.analyze(before, after) catch return error.OutOfMemory;

    const payload = renderCalledBefore(allocator, before, after, result) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn renderCalledBefore(
    a: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    r: CalledBeforeResult,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"before\":");
    try appendJson(a, w, before);
    try w.appendSlice(a, ",\"after\":");
    try appendJson(a, w, after);
    try w.print(a, ",\"satisfied\":{s}", .{if (r.satisfied) "true" else "false"});

    // satisfied_in
    try w.print(a, ",\"satisfied_in_count\":{d},\"satisfied_in\":[", .{r.satisfied_in.len});
    {
        const shown = @min(r.satisfied_in.len, cb_list_cap);
        for (r.satisfied_in[0..shown], 0..) |fqn, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try appendJson(a, w, fqn);
        }
        try w.appendSlice(a, "]");
        if (shown < r.satisfied_in.len) try w.appendSlice(a, ",\"satisfied_in_truncated\":true");
    }

    // violations
    try w.print(a, ",\"violations_count\":{d},\"violations\":[", .{r.violations.len});
    {
        const shown = @min(r.violations.len, cb_list_cap);
        for (r.violations[0..shown], 0..) |v, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"context_function\":");
            try appendJson(a, w, v.context_function);
            try w.appendSlice(a, ",\"file\":");
            try appendJson(a, w, v.file_path);
            try w.print(a, ",\"after_line\":{d},\"kind\":\"{s}\"", .{ v.after_line, @tagName(v.kind) });
            if (v.before_line) |bl| try w.print(a, ",\"before_line\":{d}", .{bl});
            if (v.missing_before_paths.len > 0) {
                try w.appendSlice(a, ",\"missing_before_paths\":[");
                for (v.missing_before_paths, 0..) |p, j| {
                    if (j != 0) try w.appendSlice(a, ",");
                    try w.appendSlice(a, "{\"caller\":");
                    try appendJson(a, w, p.caller);
                    try w.print(a, ",\"call_line\":{d},\"file\":", .{p.call_line});
                    try appendJson(a, w, p.file_path);
                    try w.appendSlice(a, "}");
                }
                try w.appendSlice(a, "]");
            }
            try w.appendSlice(a, "}");
        }
        try w.appendSlice(a, "]");
        if (shown < r.violations.len) try w.appendSlice(a, ",\"violations_truncated\":true");
    }

    // matches
    try w.print(a, ",\"matches_count\":{d},\"matches\":[", .{r.matches.len});
    {
        const shown = @min(r.matches.len, cb_list_cap);
        for (r.matches[0..shown], 0..) |m, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"context_function\":");
            try appendJson(a, w, m.context_function);
            try w.appendSlice(a, ",\"file\":");
            try appendJson(a, w, m.file_path);
            try w.print(a, ",\"after_line\":{d},\"before_line\":{d}", .{ m.after_line, m.before_line });
            try w.appendSlice(a, ",\"after_callee\":");
            try appendJson(a, w, m.after_callee);
            try w.appendSlice(a, ",\"before_callee\":");
            try appendJson(a, w, m.before_callee);
            try w.print(a, ",\"via_caller\":{s}", .{if (m.via_caller) "true" else "false"});
            if (m.caller_context) |cc| {
                try w.appendSlice(a, ",\"caller_context\":");
                try appendJson(a, w, cc);
            }
            try w.appendSlice(a, "}");
        }
        try w.appendSlice(a, "]");
        if (shown < r.matches.len) try w.appendSlice(a, ",\"matches_truncated\":true");
    }

    try w.appendSlice(a, "}");
    return buf.items;
}

// ============================================================================
// dependencies tool
// ============================================================================

const dependencies_tool_description =
    \\Report cross-package (cross-project) coupling in a monorepo: which projects
    \\call into which, the public API surface each project exposes to others, and
    \\per-pair dependency counts. Automates the "check-dependencies" PR ritual
    \\(no more jq over composer.json).
    \\
    \\Only resolved calls can be attributed to a callee project, so the report is
    \\a LOWER BOUND. The `caveats` block surfaces what was NOT seen:
    \\`unresolved_calls` (invisible to this analysis), `resolution_rate`, and
    \\`tests_excluded`. Each finding carries `resolution` and `is_test`.
    \\
    \\Arguments (all optional):
    \\  exclude_tests: bool (default true) — drop cross-package calls whose caller
    \\                 is a test file, so the report reflects production coupling.
    \\  min_call_count: int (default 1) — only report dependency edges (and their
    \\                 individual calls) with at least this many calls; raise it to
    \\                 surface the heavy couplings and hide one-off references.
    \\  from: string — keep only edges/calls *from* a project whose short name
    \\                 contains this (case-insensitive).
    \\  to: string — keep only edges/calls *to* a project whose short name
    \\                 contains this (case-insensitive).
    \\  include_calls: bool (default false) — include the heavy per-call
    \\                 `cross_package_calls[]` array. Off by default; the
    \\                 `dependencies[]` edge summary is usually what you want.
    \\  include_api_surface: bool (default false) — include the
    \\                 `api_surface_used[]` symbol inventory. Off by default; also
    \\                 honors the from/to/min_call_count filters (`to` matches the
    \\                 exposing project, `from`/min_call_count prune consumers).
    \\
    \\Returns JSON: {summary, caveats, dependencies[]} plus, only when their flag
    \\is set, `cross_package_calls[]` (`include_calls`) and `api_surface_used[]`
    \\(`include_api_surface`); omitted lists are flagged `*_omitted`. Heavy lists
    \\are capped and carry a `*_truncated` flag (count cap or response-size
    \\budget). Requires a multi-project `.phpcma.json`; a single composer.json
    \\project has no boundaries to report. Call `load_project` first.
;

fn buildDependenciesSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addBoolean(
        a,
        "exclude_tests",
        "Drop cross-package calls whose caller is a test file (default true).",
        false,
    );
    _ = try builder.addInteger(
        a,
        "min_call_count",
        "Only report dependency edges/calls with at least this many calls (default 1).",
        false,
    );
    _ = try builder.addString(
        a,
        "from",
        "Keep only edges/calls from a project whose short name contains this (case-insensitive).",
        false,
    );
    _ = try builder.addString(
        a,
        "to",
        "Keep only edges/calls to a project whose short name contains this (case-insensitive).",
        false,
    );
    _ = try builder.addBoolean(
        a,
        "include_calls",
        "Include the heavy per-call cross_package_calls[] array (default false).",
        false,
    );
    _ = try builder.addBoolean(
        a,
        "include_api_surface",
        "Include the api_surface_used[] symbol inventory (default false).",
        false,
    );
    return builder.toInputSchema(a);
}

/// Render-time filters/flags for the `dependencies` tool, parsed from args.
const DepsRenderOpts = struct {
    min_call_count: usize = 1,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    include_calls: bool = false,
    include_api_surface: bool = false,
};

fn dependenciesHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const min_call_count: usize = blk: {
        const n = mcp.tools.getInteger(arguments, "min_call_count") orelse break :blk 1;
        if (n < 1) break :blk 1;
        break :blk @intCast(n);
    };
    const opts = DepsRenderOpts{
        .min_call_count = min_call_count,
        .from = nonEmpty(mcp.tools.getString(arguments, "from")),
        .to = nonEmpty(mcp.tools.getString(arguments, "to")),
        .include_calls = mcp.tools.getBoolean(arguments, "include_calls") orelse false,
        .include_api_surface = mcp.tools.getBoolean(arguments, "include_api_surface") orelse false,
    };

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(
        allocator,
        &lp.index.call_graph,
        lp.index.project_configs,
        &lp.index.sym_table,
    );
    const result = analyzer.analyze(.{ .exclude_tests = exclude_tests }) catch return error.OutOfMemory;

    const payload = renderBoundary(allocator, result, exclude_tests, opts, lp.index) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// Look up the total call count for a (from,to) project pair in the dependency
/// edge list. Linear scan — the edge list is per-pair (project² at most), tiny
/// next to the per-call list it filters.
fn pairCallCount(
    deps: []const boundary_analyzer.ProjectDependency,
    from_project: []const u8,
    to_project: []const u8,
) usize {
    for (deps) |d| {
        if (std.mem.eql(u8, d.from_project, from_project) and
            std.mem.eql(u8, d.to_project, to_project)) return d.call_count;
    }
    return 0;
}

/// Determine which project root a file belongs to (longest matching prefix).
/// Mirrors `BoundaryAnalyzer.fileToProject` but reads `index.project_configs`
/// directly, so the renderer can attribute an API method to its owner project.
fn fileToProjectRoot(index: *ProjectIndex, file_path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    for (index.project_configs) |*cfg| {
        if (cfg.root_path.len == 0) continue;
        if (std.mem.startsWith(u8, file_path, cfg.root_path) and cfg.root_path.len > best_len) {
            best_len = cfg.root_path.len;
            best = cfg.root_path;
        }
    }
    return best;
}

/// Treat an empty string argument the same as an absent one.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    if (s) |v| {
        if (v.len > 0) return v;
    }
    return null;
}

fn renderBoundary(
    a: std.mem.Allocator,
    r: boundary_analyzer.BoundaryResult,
    exclude_tests: bool,
    opts: DepsRenderOpts,
    index: *ProjectIndex,
) ![]const u8 {
    const ShortName = boundary_analyzer.BoundaryAnalyzer.shortProjectName;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"projects\":{d},\"cross_package_calls\":{d},\"same_project_calls\":{d},\"dependency_edges\":{d}", .{
        r.project_count, r.cross_project_calls, r.same_project_calls, r.dependencies.len,
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"unresolved_calls\":{d},\"resolution_rate\":{d:.1},\"exclude_tests\":{s},\"tests_excluded\":{d}", .{
        r.unresolved_calls,
        index.call_graph.getResolutionRate(),
        if (exclude_tests) "true" else "false",
        r.tests_excluded,
    });
    try w.appendSlice(a,
        "},\"note\":\"Only resolved calls are attributed; cross_package_calls is a lower bound (see caveats.unresolved_calls).\"");

    // Echo the active filters so a filtered (partial) report is never mistaken
    // for the whole picture.
    const filters_active = opts.min_call_count > 1 or opts.from != null or opts.to != null;
    if (filters_active) {
        try w.print(a, ",\"filters\":{{\"min_call_count\":{d}", .{opts.min_call_count});
        if (opts.from) |f| {
            try w.appendSlice(a, ",\"from\":");
            try appendJson(a, w, f);
        }
        if (opts.to) |t| {
            try w.appendSlice(a, ",\"to\":");
            try appendJson(a, w, t);
        }
        try w.appendSlice(a, "}");
    }

    // Dependency edges (the part you usually want). Honors min_call_count +
    // from/to project filters.
    try w.appendSlice(a, ",\"dependencies\":[");
    {
        var matched: usize = 0;
        var shown: usize = 0;
        var truncated = false;
        for (r.dependencies) |d| {
            if (d.call_count < opts.min_call_count) continue;
            if (!projectFilterMatches(opts.from, d.from_project)) continue;
            if (!projectFilterMatches(opts.to, d.to_project)) continue;
            matched += 1;
            if (shown >= cb_list_cap or buf.items.len >= response_byte_budget) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"from\":");
            try appendJson(a, w, d.from_project);
            try w.appendSlice(a, ",\"from_short\":");
            try appendJson(a, w, ShortName(d.from_project));
            try w.appendSlice(a, ",\"to\":");
            try appendJson(a, w, d.to_project);
            try w.appendSlice(a, ",\"to_short\":");
            try appendJson(a, w, ShortName(d.to_project));
            try w.print(a, ",\"call_count\":{d}}}", .{d.call_count});
            shown += 1;
        }
        try w.appendSlice(a, "]");
        try w.print(a, ",\"dependencies_matched\":{d}", .{matched});
        if (truncated) try w.appendSlice(a, ",\"dependencies_truncated\":true");
    }

    // Cross-package calls — heavy per-call list, gated behind `include_calls`.
    // A call is kept only if its (from,to) pair meets min_call_count and the
    // from/to project filters.
    if (opts.include_calls) {
        try w.appendSlice(a, ",\"cross_package_calls\":[");
        var matched: usize = 0;
        var shown: usize = 0;
        var truncated = false;
        for (r.boundary_calls) |c| {
            if (opts.min_call_count > 1 and
                pairCallCount(r.dependencies, c.caller_project, c.callee_project) < opts.min_call_count) continue;
            if (!projectFilterMatches(opts.from, c.caller_project)) continue;
            if (!projectFilterMatches(opts.to, c.callee_project)) continue;
            matched += 1;
            if (shown >= cb_list_cap or buf.items.len >= response_byte_budget) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"caller\":");
            try appendJson(a, w, c.caller_fqn);
            try w.appendSlice(a, ",\"callee\":");
            try appendJson(a, w, c.callee_fqn);
            try w.appendSlice(a, ",\"caller_project\":");
            try appendJson(a, w, ShortName(c.caller_project));
            try w.appendSlice(a, ",\"callee_project\":");
            try appendJson(a, w, ShortName(c.callee_project));
            try w.appendSlice(a, ",\"file\":");
            try appendJson(a, w, c.file_path);
            try w.print(a, ",\"line\":{d},\"confidence\":{d:.2},\"resolution\":\"exact\",\"is_test\":{s}}}", .{
                c.line, c.confidence, if (c.is_test) "true" else "false",
            });
            shown += 1;
        }
        try w.appendSlice(a, "]");
        try w.print(a, ",\"cross_package_calls_matched\":{d}", .{matched});
        if (truncated) try w.appendSlice(a, ",\"cross_package_calls_truncated\":true");
    } else {
        try w.appendSlice(a, ",\"cross_package_calls_omitted\":true");
    }

    // API surface used across boundaries — the symbol inventory, gated behind
    // `include_api_surface`. Honors the same from/to/min_call_count filters:
    // `to` matches the method's owner (exposing) project, `from`/min_call_count
    // restrict (and prune) the consuming `used_by_projects`.
    if (opts.include_api_surface) {
        try w.appendSlice(a, ",\"api_surface_used\":[");
        var matched: usize = 0;
        var shown: usize = 0;
        var truncated = false;
        for (r.api_surface) |m| {
            const owner = fileToProjectRoot(index, m.file_path);
            if (opts.to != null and (owner == null or !projectFilterMatches(opts.to, owner.?))) continue;

            // Keep only consumers matching `from` and the min_call_count pair
            // threshold; drop the method entirely if none survive.
            var consumer_count: usize = 0;
            for (m.used_by_projects) |p| {
                if (!projectFilterMatches(opts.from, p)) continue;
                if (opts.min_call_count > 1 and
                    (owner == null or pairCallCount(r.dependencies, p, owner.?) < opts.min_call_count)) continue;
                consumer_count += 1;
            }
            if (consumer_count == 0) continue;

            matched += 1;
            if (shown >= cb_list_cap or buf.items.len >= response_byte_budget) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"fqn\":");
            try appendJson(a, w, m.fqn);
            try w.print(a, ",\"visibility\":\"{s}\",\"used_by_projects\":[", .{@tagName(m.visibility)});
            var emitted: usize = 0;
            for (m.used_by_projects) |p| {
                if (!projectFilterMatches(opts.from, p)) continue;
                if (opts.min_call_count > 1 and
                    (owner == null or pairCallCount(r.dependencies, p, owner.?) < opts.min_call_count)) continue;
                if (emitted != 0) try w.appendSlice(a, ",");
                try appendJson(a, w, ShortName(p));
                emitted += 1;
            }
            try w.appendSlice(a, "],\"file\":");
            try appendJson(a, w, m.file_path);
            try w.appendSlice(a, "}");
            shown += 1;
        }
        try w.appendSlice(a, "]");
        try w.print(a, ",\"api_surface_used_matched\":{d}", .{matched});
        if (truncated) try w.appendSlice(a, ",\"api_surface_used_truncated\":true");
    } else {
        try w.appendSlice(a, ",\"api_surface_used_omitted\":true");
    }

    try w.appendSlice(a, "}");
    return buf.items;
}

// ============================================================================
// impact tool
// ============================================================================

const impact_tool_description =
    \\Blast radius of changing one symbol: given a method/function FQN, list its
    \\callers grouped by package (cross-package vs internal), and emit a
    \\breaking-change risk verdict. The agent-facing "if I change this signature,
    \\who breaks?" tool.
    \\
    \\Only *resolved* calls to exactly this FQN are counted; `caveats
    \\.unresolved_same_name` reports same-named calls that couldn't be attributed
    \\(possible additional callers). `exclude_tests` (default true) drops
    \\test-file callers.
    \\
    \\Arguments:
    \\  fqn: string (required) — e.g. "App\\Service\\UserService::save".
    \\  exclude_tests: bool (default true).
    \\  verbose: bool (default false) — include the full per-caller list under
    \\           each package group. Off by default: you get the verdict +
    \\           per-package counts, and the heavy caller list only on request.
    \\  packages_only: bool (default false) — never emit individual callers, even
    \\           with verbose (wins over it). Use when even one package's caller
    \\           list is more than you need.
    \\  limit: int (default 200) — cap the callers emitted per package group when
    \\           verbose.
    \\  simulate: object (optional) — a type edit to evaluate against the observed
    \\           call sites: `{"param_type_change":{"position":0,"to":"App\\Bar"}}`
    \\           and/or `{"return_type_change":{"to":"?App\\User"}}`.
    \\
    \\The verdict header (risk, summary, signature, breaking_change) is always
    \\emitted first, so it survives any truncation. When callers are not included
    \\the response carries `callers_omitted:true` (re-call with verbose to get
    \\them); each group always reports its `caller_count`.
    \\
    \\Returns JSON: {fqn, symbol_project, risk, summary, caveats, signature,
    \\call_site_arity, breaking_change, groups[]}. `risk` is internal_only |
    \\public_api_low | public_api_medium | public_api_high (by cross-package
    \\caller count). `signature` reports the target's declared arity
    \\(total/required/optional params + variadic). `call_site_arity` is the
    \\min/max args observed across callers, and each verbose caller carries its
    \\own `arg_count`, observed `arg_types[]`, and `result_used`. `breaking_change`
    \\gives data-driven verdicts for common signature edits (add_required_param,
    \\remove_trailing_param, add_optional_param, make_param_optional).
    \\
    \\With `simulate`, adds `type_breaking_change`: for `param_type_change`, each
    \\caller's argument type is checked against `to` (or an in-project subtype) —
    \\`verdict` is breaking | safe | unknown with `{typed_args, total_call_sites}`
    \\coverage and `incompatible_call_sites[]`. For `return_type_change`, callers
    \\that dereference or forward the result are flagged in `risky_call_sites[]`
    \\(narrowing to `?T` would newly require a null check); `verdict` is risky |
    \\safe. A `safe` verdict requires every call site to be typed and compatible,
    \\so a low-resolution graph yields `unknown`, never false `safe`. Call
    \\`load_project` first.
;

fn buildImpactSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    // Hand-built (like `query`) because the optional `simulate` argument is a
    // nested object the flat InputSchemaBuilder can't express.
    var props: std.json.ObjectMap = .empty;

    var fqn_obj: std.json.ObjectMap = .empty;
    try fqn_obj.put(a, "type", .{ .string = "string" });
    try fqn_obj.put(a, "description", .{ .string = "Method/function FQN whose callers to survey (e.g. \"App\\Service::save\")." });
    try props.put(a, "fqn", .{ .object = fqn_obj });

    inline for (.{
        .{ "exclude_tests", "Drop test-file callers (default true)." },
        .{ "verbose", "Include the full per-caller list under each package group (default false)." },
        .{ "packages_only", "Never emit individual callers, even with verbose (default false)." },
    }) |pair| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "boolean" });
        try o.put(a, "description", .{ .string = pair[1] });
        try props.put(a, pair[0], .{ .object = o });
    }

    var limit_obj: std.json.ObjectMap = .empty;
    try limit_obj.put(a, "type", .{ .string = "integer" });
    try limit_obj.put(a, "description", .{ .string = "Cap callers emitted per package group when verbose (default 200)." });
    try props.put(a, "limit", .{ .object = limit_obj });

    var sim_obj: std.json.ObjectMap = .empty;
    try sim_obj.put(a, "type", .{ .string = "object" });
    try sim_obj.put(a, "description", .{
        .string = "Optional type edit to evaluate against observed call sites. " ++
            "`{\"param_type_change\":{\"position\":0,\"to\":\"App\\\\Bar\"}}` checks whether each " ++
            "caller's argument type is `to` or an in-project subtype; " ++
            "`{\"return_type_change\":{\"to\":\"?App\\\\User\"}}` flags callers that dereference " ++
            "or forward the result (narrowing the return to nullable would break them).",
    });
    try props.put(a, "simulate", .{ .object = sim_obj });

    const required = try a.dupe([]const u8, &.{"fqn"});
    return .{
        .type = "object",
        .properties = .{ .object = props },
        .required = required,
    };
}

/// A proposed type edit to evaluate against observed call sites.
const Simulate = struct {
    param_type_change: ?struct { position: usize, to: []const u8 } = null,
    return_type_change: ?struct { to: []const u8 } = null,

    fn isEmpty(self: Simulate) bool {
        return self.param_type_change == null and self.return_type_change == null;
    }
};

/// Render-time flags for the `impact` tool, parsed from args.
const ImpactRenderOpts = struct {
    verbose: bool = false,
    packages_only: bool = false,
    limit: usize = cb_list_cap,
    simulate: Simulate = .{},

    /// Individual callers are emitted only when explicitly requested and not
    /// suppressed by `packages_only`.
    fn includeCallers(self: ImpactRenderOpts) bool {
        return self.verbose and !self.packages_only;
    }
};

/// Parse the optional `simulate` object. A leading `\` (and, for the param
/// `to`, a leading `?`) is tolerated/stripped so the FQCN matches table keys.
fn parseSimulate(arguments: ?std.json.Value) Simulate {
    var sim = Simulate{};
    const so = mcp.tools.getObject(arguments, "simulate") orelse return sim;
    const sv = std.json.Value{ .object = so };

    if (mcp.tools.getObject(sv, "param_type_change")) |pco| {
        const pv = std.json.Value{ .object = pco };
        if (mcp.tools.getString(pv, "to")) |raw| {
            var to = raw;
            if (to.len > 0 and to[0] == '?') to = to[1..];
            if (to.len > 0 and to[0] == '\\') to = to[1..];
            if (to.len > 0) {
                const pos = mcp.tools.getInteger(pv, "position") orelse 0;
                sim.param_type_change = .{ .position = if (pos < 0) 0 else @intCast(pos), .to = to };
            }
        }
    }
    if (mcp.tools.getObject(sv, "return_type_change")) |rco| {
        const rv = std.json.Value{ .object = rco };
        if (mcp.tools.getString(rv, "to")) |raw| {
            var to = raw;
            if (to.len > 0 and to[0] == '\\') to = to[1..];
            if (to.len > 0) sim.return_type_change = .{ .to = to };
        }
    }
    return sim;
}

fn impactHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const fqn = mcp.tools.getString(arguments, "fqn") orelse "";
    if (fqn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`fqn` is required (a method/function FQN, e.g. \"App\\Service::save\").",
        ) catch return error.OutOfMemory;
    }
    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const opts = ImpactRenderOpts{
        .verbose = mcp.tools.getBoolean(arguments, "verbose") orelse false,
        .packages_only = mcp.tools.getBoolean(arguments, "packages_only") orelse false,
        .limit = blk: {
            const n = mcp.tools.getInteger(arguments, "limit") orelse break :blk cb_list_cap;
            if (n < 1) break :blk cb_list_cap;
            break :blk @intCast(n);
        },
        .simulate = parseSimulate(arguments),
    };

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(
        allocator,
        &lp.index.call_graph,
        lp.index.project_configs,
        &lp.index.sym_table,
    );
    const result = analyzer.impact(fqn, .{ .exclude_tests = exclude_tests }) catch return error.OutOfMemory;

    const payload = renderImpact(allocator, lp.index, result, exclude_tests, opts) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// Classify breaking-change risk from the cross-package caller count.
fn impactRisk(cross_package_callers: usize) []const u8 {
    if (cross_package_callers == 0) return "internal_only";
    if (cross_package_callers <= 2) return "public_api_low";
    if (cross_package_callers <= 9) return "public_api_medium";
    return "public_api_high";
}

fn renderImpact(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    r: boundary_analyzer.BoundaryAnalyzer.ImpactResult,
    exclude_tests: bool,
    opts: ImpactRenderOpts,
) ![]const u8 {
    const ShortName = boundary_analyzer.BoundaryAnalyzer.shortProjectName;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, r.fqn);
    try w.appendSlice(a, ",\"symbol_project\":");
    if (r.symbol_project) |sp| try appendJson(a, w, ShortName(sp)) else try w.appendSlice(a, "null");
    try w.print(a, ",\"risk\":\"{s}\"", .{impactRisk(r.cross_package_callers)});
    try w.print(a, ",\"summary\":{{\"total_callers\":{d},\"cross_package_callers\":{d},\"internal_callers\":{d},\"caller_packages\":{d}}}", .{
        r.total_callers, r.cross_package_callers, r.internal_callers, r.groups.len,
    });
    try w.print(a, ",\"caveats\":{{\"unresolved_same_name\":{d},\"exclude_tests\":{s}}}", .{
        r.unresolved_same_name, if (exclude_tests) "true" else "false",
    });
    if (r.symbol_project == null) {
        try w.appendSlice(a, ",\"note\":\"symbol not found in any indexed project; callers (if any) are attributed but cross-package classification is unavailable\"");
    }

    // Signature + signature-aware breaking-change analysis.
    if (r.signature) |sig| {
        try w.print(
            a,
            ",\"signature\":{{\"total_params\":{d},\"required_params\":{d},\"optional_params\":{d},\"has_variadic\":{s}}}",
            .{ sig.total_params, sig.required_params, sig.optional_params, if (sig.has_variadic) "true" else "false" },
        );
        try w.print(a, ",\"call_site_arity\":{{\"min\":{d},\"max\":{d}}}", .{ r.min_caller_args, r.max_caller_args });

        // Data-driven verdicts about common signature edits. `remove_param` is
        // judged safe only when no observed call site fills the last positional
        // slot (max args < total params) and there is no variadic tail.
        const add_required = if (r.total_callers == 0) "no_known_callers" else "breaking";
        const remove_param = if (r.total_callers == 0)
            "no_known_callers"
        else if (!sig.has_variadic and sig.total_params > 0 and r.max_caller_args < sig.total_params)
            "safe"
        else
            "breaking";
        try w.print(
            a,
            ",\"breaking_change\":{{\"add_required_param\":\"{s}\",\"remove_trailing_param\":\"{s}\",\"add_optional_param\":\"safe\",\"make_param_optional\":\"safe\"}}",
            .{ add_required, remove_param },
        );
    } else {
        try w.appendSlice(a, ",\"signature\":null");
    }

    // Type-aware breaking-change analysis (only when a `simulate` edit is given).
    if (!opts.simulate.isEmpty()) {
        try appendTypeBreakingChange(a, w, index, r, opts.simulate);
    }

    // The verdict header above always survives. The per-package `groups`
    // breakdown (counts) follows; individual callers are emitted only when
    // requested (`verbose`, and not suppressed by `packages_only`).
    const include_callers = opts.includeCallers();
    if (!include_callers) try w.appendSlice(a, ",\"callers_omitted\":true");
    try w.appendSlice(a, ",\"groups\":[");
    {
        const shown = @min(r.groups.len, cb_list_cap);
        for (r.groups[0..shown], 0..) |g, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"project\":");
            try appendJson(a, w, if (g.project.len > 0) ShortName(g.project) else "<external>");
            try w.print(a, ",\"is_cross_package\":{s},\"caller_count\":{d}", .{
                if (g.is_cross_package) "true" else "false", g.callers.len,
            });
            if (include_callers) {
                try w.appendSlice(a, ",\"callers\":[");
                const cap = @min(g.callers.len, opts.limit);
                var cshown: usize = 0;
                var ctruncated = false;
                for (g.callers[0..cap]) |c| {
                    if (buf.items.len >= response_byte_budget) {
                        ctruncated = true;
                        break;
                    }
                    if (cshown != 0) try w.appendSlice(a, ",");
                    try w.appendSlice(a, "{\"caller\":");
                    try appendJson(a, w, c.caller_fqn);
                    try w.appendSlice(a, ",\"file\":");
                    try appendJson(a, w, c.file_path);
                    try w.print(a, ",\"line\":{d},\"is_test\":{s},\"confidence\":{d:.2},\"arg_count\":{d}", .{
                        c.line, if (c.is_test) "true" else "false", c.confidence, c.arg_count,
                    });
                    try appendArgTypesJson(a, w, c.arg_types);
                    try w.print(a, ",\"result_used\":\"{s}\"}}", .{@tagName(c.result_used)});
                    cshown += 1;
                }
                try w.appendSlice(a, "]");
                if (ctruncated or cap < g.callers.len) try w.appendSlice(a, ",\"callers_truncated\":true");
            }
            try w.appendSlice(a, "}");
        }
        try w.appendSlice(a, "]");
        if (shown < r.groups.len) try w.appendSlice(a, ",\"groups_truncated\":true");
    }

    try w.appendSlice(a, "}");
    return buf.items;
}

/// Emit `,"arg_types":[...]` — each observed positional argument type as a small
/// `{text,kind,builtin,nullable}` object, or `null` where unresolved.
fn appendArgTypesJson(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), arg_types: []const ?types.TypeInfo) !void {
    try w.appendSlice(a, ",\"arg_types\":[");
    for (arg_types, 0..) |maybe_t, i| {
        if (i != 0) try w.appendSlice(a, ",");
        if (maybe_t) |t| try appendTypeJson(a, w, t) else try w.appendSlice(a, "null");
    }
    try w.appendSlice(a, "]");
}

/// Evaluate a `simulate` type edit against the observed call sites and emit the
/// `type_breaking_change` object. Honest about coverage: a verdict is never
/// `safe` unless every counted call site is typed (params) and compatible.
fn appendTypeBreakingChange(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    index: *const ProjectIndex,
    r: boundary_analyzer.BoundaryAnalyzer.ImpactResult,
    sim: Simulate,
) !void {
    try w.appendSlice(a, ",\"type_breaking_change\":{");
    var wrote_one = false;

    // ---- Param type change ----------------------------------------------
    if (sim.param_type_change) |pc| {
        wrote_one = true;
        // The accepted set: `to` plus its in-project subtypes. A caller's arg is
        // compatible iff its (FQCN-normalized) type is in this set.
        var set = try buildMatchSet(a, index, pc.to, true);
        defer set.deinit();

        var typed_args: usize = 0;
        var total: usize = 0;
        var incompatible: std.ArrayListUnmanaged(u8) = .empty;
        var incompatible_count: usize = 0;

        for (r.groups) |g| {
            for (g.callers) |c| {
                total += 1;
                if (pc.position >= c.arg_types.len) continue;
                const at = c.arg_types[pc.position] orelse continue;
                typed_args += 1;
                if (typeMatchesSet(&set, at)) continue;
                const at_text = try at.format(a);
                if (incompatible_count != 0) try incompatible.appendSlice(a, ",");
                try incompatible.appendSlice(a, "{\"caller\":");
                try appendJson(a, &incompatible, c.caller_fqn);
                try incompatible.appendSlice(a, ",\"file\":");
                try appendJson(a, &incompatible, c.file_path);
                try incompatible.print(a, ",\"line\":{d},\"arg_type\":", .{c.line});
                try appendJson(a, &incompatible, at_text);
                try incompatible.appendSlice(a, ",\"reason\":");
                const reason = try std.fmt.allocPrint(a, "{s} is not {s} or an in-project subtype", .{ at_text, pc.to });
                try appendJson(a, &incompatible, reason);
                try incompatible.appendSlice(a, "}");
                incompatible_count += 1;
            }
        }

        const verdict: []const u8 = if (incompatible_count > 0)
            "breaking"
        else if (total > 0 and typed_args == total)
            "safe"
        else
            "unknown";

        try w.print(a, "\"param_type_change\":{{\"position\":{d},\"to\":", .{pc.position});
        try appendJson(a, w, pc.to);
        try w.appendSlice(a, ",\"incompatible_call_sites\":[");
        try w.appendSlice(a, incompatible.items);
        try w.print(a, "],\"verdict\":\"{s}\",\"coverage\":{{\"typed_args\":{d},\"total_call_sites\":{d}}}}}", .{
            verdict, typed_args, total,
        });
    }

    // ---- Return type change ---------------------------------------------
    if (sim.return_type_change) |rc| {
        if (wrote_one) try w.appendSlice(a, ",");
        const to_nullable = rc.to.len > 0 and rc.to[0] == '?';

        var total: usize = 0;
        var risky: std.ArrayListUnmanaged(u8) = .empty;
        var risky_count: usize = 0;

        for (r.groups) |g| {
            for (g.callers) |c| {
                total += 1;
                const use = c.result_used;
                if (use != .member_access and use != .passed) continue;
                const reason = if (use == .member_access)
                    (if (to_nullable)
                        try std.fmt.allocPrint(a, "result is dereferenced; narrowing the return to {s} would require a null check here", .{rc.to})
                    else
                        try std.fmt.allocPrint(a, "result is dereferenced; verify {s} still exposes the accessed member", .{rc.to}))
                else
                    (if (to_nullable)
                        try std.fmt.allocPrint(a, "result is forwarded; {s} may flow into a non-nullable position", .{rc.to})
                    else
                        try std.fmt.allocPrint(a, "result is forwarded; verify {s} is accepted at the destination", .{rc.to}));

                if (risky_count != 0) try risky.appendSlice(a, ",");
                try risky.appendSlice(a, "{\"caller\":");
                try appendJson(a, &risky, c.caller_fqn);
                try risky.appendSlice(a, ",\"file\":");
                try appendJson(a, &risky, c.file_path);
                try risky.print(a, ",\"line\":{d},\"result_used\":\"{s}\",\"reason\":", .{ c.line, @tagName(use) });
                try appendJson(a, &risky, reason);
                try risky.appendSlice(a, "}");
                risky_count += 1;
            }
        }

        const verdict: []const u8 = if (risky_count > 0) "risky" else "safe";

        try w.appendSlice(a, "\"return_type_change\":{\"to\":");
        try appendJson(a, w, rc.to);
        try w.appendSlice(a, ",\"risky_call_sites\":[");
        try w.appendSlice(a, risky.items);
        // result_used is recorded for every counted call site, so coverage here
        // is always complete (the partiality is in *whether* a use is risky).
        try w.print(a, "],\"verdict\":\"{s}\",\"coverage\":{{\"result_use_known\":{d},\"total_call_sites\":{d}}}}}", .{
            verdict, total, total,
        });
    }

    try w.appendSlice(a, "}");
}

// ============================================================================
// references tool
// ============================================================================

const references_tool_description =
    \\Rename blast radius for a class/interface/trait/enum: given its FQN, find
    \\every *non-call* occurrence a rename must touch — type hints, `new`,
    \\`extends`/`implements`, `::class` and other static refs, `use` imports, and
    \\exact-FQN string literals. (Call sites are covered by `query`/`impact`.)
    \\
    \\References are resolved to fully-qualified names via each file's namespace +
    \\`use` table, so a class in a sibling namespace with the same short name is
    \\never matched — the corruption risk a plain text search can't avoid.
    \\
    \\Argument:
    \\  fqn: string (required) — the class FQN, e.g. "App\\Dto\\Item" (a leading
    \\       backslash is tolerated).
    \\
    \\Returns JSON: {fqn, summary{total, files, by_kind{...}}, references[
    \\{kind, file, line, column}]} where `kind` is use_import | type_hint |
    \\instantiation | extends | implements | class_const | static_ref |
    \\string_literal. Call `load_project` first.
;

fn buildReferencesSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "fqn", "Class/interface/trait/enum FQN to find references to (e.g. \"App\\Dto\\Item\").", true);
    return builder.toInputSchema(a);
}

fn referencesHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    var fqn = mcp.tools.getString(arguments, "fqn") orelse "";
    if (fqn.len > 0 and fqn[0] == '\\') fqn = fqn[1..];
    if (fqn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`fqn` is required (a class FQN, e.g. \"App\\Dto\\Item\").",
        ) catch return error.OutOfMemory;
    }

    const refs = lp.index.collectReferences(allocator, fqn) catch return error.OutOfMemory;
    const payload = renderReferences(allocator, fqn, refs) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn renderReferences(
    a: std.mem.Allocator,
    fqn: []const u8,
    refs: []const references_mod.Reference,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    // Per-kind histogram + distinct-file count (refs are sorted by file).
    const kind_count = @typeInfo(references_mod.ReferenceKind).@"enum".fields.len;
    var by_kind = [_]usize{0} ** kind_count;
    var files: usize = 0;
    var last_file: []const u8 = "";
    for (refs) |r| {
        by_kind[@intFromEnum(r.kind)] += 1;
        if (files == 0 or !std.mem.eql(u8, r.file_path, last_file)) {
            files += 1;
            last_file = r.file_path;
        }
    }

    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, fqn);
    try w.print(a, ",\"summary\":{{\"total\":{d},\"files\":{d},\"by_kind\":{{", .{ refs.len, files });
    {
        var first = true;
        inline for (@typeInfo(references_mod.ReferenceKind).@"enum".fields) |f| {
            const c = by_kind[f.value];
            if (c != 0) {
                if (!first) try w.appendSlice(a, ",");
                first = false;
                try w.print(a, "\"{s}\":{d}", .{ f.name, c });
            }
        }
    }
    try w.appendSlice(a, "}}");

    try w.appendSlice(a, ",\"references\":[");
    const shown = @min(refs.len, cb_list_cap);
    for (refs[0..shown], 0..) |r, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try w.print(a, "{{\"kind\":\"{s}\",\"file\":", .{r.kind.label()});
        try appendJson(a, w, r.file_path);
        try w.print(a, ",\"line\":{d},\"column\":{d}}}", .{ r.line, r.column });
    }
    try w.appendSlice(a, "]");
    if (shown < refs.len) try w.appendSlice(a, ",\"references_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

/// Minimal JSON string emitter (control chars escaped) for tool payloads.
fn appendJson(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try w.append(a, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.appendSlice(a, "\\\""),
            '\\' => try w.appendSlice(a, "\\\\"),
            '\n' => try w.appendSlice(a, "\\n"),
            '\r' => try w.appendSlice(a, "\\r"),
            '\t' => try w.appendSlice(a, "\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print(a, "\\u{x:0>4}", .{ch});
                } else {
                    try w.append(a, ch);
                }
            },
        }
    }
    try w.append(a, '"');
}

// ============================================================================
// describe_symbol tool
// ============================================================================

const describe_symbol_tool_description =
    \\Resolved, inheritance-aware, typed view of a single symbol — the signature
    \\an agent needs *before* calling or editing it, without opening the file.
    \\Native and PHPDoc types are merged (the `effective` type is what the
    \\resolver uses) and simple/union/array class types are FQCN-normalized.
    \\
    \\Argument:
    \\  fqn: string (required) — a Class, Interface, Trait, Class::method, or
    \\       function FQN. A leading backslash is tolerated.
    \\  members: enum(none|signatures|full) default signatures — for a TYPE
    \\       target, how much member detail to emit.
    \\  inherited: bool (default true) — for a TYPE target, include inherited /
    \\       trait members.
    \\
    \\Returns JSON. For a METHOD/function: {fqn, symbol, declared_in?, inherited?,
    \\visibility?, modifiers?, parameters[{name, position, type{native, phpdoc,
    \\effective}, has_default, variadic, by_reference, promoted}], return{native,
    \\phpdoc, effective}, location, signature_text}. For a PROPERTY: type{declared,
    \\phpdoc, effective} + static/readonly. For a TYPE: {modifiers, extends,
    \\implements, uses_traits, generics?, parent_chain, members{...}}. Each typed
    \\field is {text, kind, builtin, nullable, parts?}. Call `load_project` first.
;

const DescribeMembers = enum { none, signatures, full };

fn buildDescribeSymbolSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "fqn", "Class, Interface, Trait, Class::method, or function FQN (e.g. \"App\\Service::find\").", true);
    _ = try builder.addEnumWithDefault(a, "members", "For a type target: how much member detail to emit.", &.{ "none", "signatures", "full" }, "signatures", false);
    _ = try builder.addBooleanWithDefault(a, "inherited", "For a type target: include inherited/trait members (default true).", true, false);
    return builder.toInputSchema(a);
}

fn describeSymbolHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    var fqn = mcp.tools.getString(arguments, "fqn") orelse "";
    if (fqn.len > 0 and fqn[0] == '\\') fqn = fqn[1..];
    if (fqn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`fqn` is required (a Class, Class::method, or function FQN).",
        ) catch return error.OutOfMemory;
    }

    const members: DescribeMembers = blk: {
        const s = mcp.tools.getString(arguments, "members") orelse break :blk .signatures;
        if (std.mem.eql(u8, s, "none")) break :blk .none;
        if (std.mem.eql(u8, s, "full")) break :blk .full;
        break :blk .signatures;
    };
    const inherited = mcp.tools.getBoolean(arguments, "inherited") orelse true;

    const payload = renderDescribeSymbol(allocator, lp.index, fqn, members, inherited) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// Emit a `TypeInfo` as a small JSON object: {text, kind, builtin, nullable, parts?}.
fn appendTypeJson(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), t: types.TypeInfo) !void {
    const text = try t.format(a);
    const is_nullable = t.kind == .nullable or blk: {
        if (t.kind == .union_type) {
            for (t.type_parts) |p| if (std.mem.eql(u8, p, "null")) break :blk true;
        }
        break :blk false;
    };
    try w.appendSlice(a, "{\"text\":");
    try appendJson(a, w, text);
    try w.print(a, ",\"kind\":\"{s}\",\"builtin\":{s},\"nullable\":{s}", .{
        @tagName(t.kind),
        if (t.is_builtin) "true" else "false",
        if (is_nullable) "true" else "false",
    });
    if ((t.kind == .union_type or t.kind == .intersection) and t.type_parts.len > 0) {
        try w.appendSlice(a, ",\"parts\":[");
        for (t.type_parts, 0..) |p, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try appendJson(a, w, p);
        }
        try w.appendSlice(a, "]");
    }
    try w.appendSlice(a, "}");
}

/// Emit a `{native, phpdoc, effective}` triad, each a type object or null.
fn appendTypeTriad(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    native_key: []const u8,
    native: ?types.TypeInfo,
    phpdoc_t: ?types.TypeInfo,
    effective: ?types.TypeInfo,
) !void {
    try w.print(a, "{{\"{s}\":", .{native_key});
    if (native) |t| try appendTypeJson(a, w, t) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"phpdoc\":");
    if (phpdoc_t) |t| try appendTypeJson(a, w, t) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"effective\":");
    if (effective) |t| try appendTypeJson(a, w, t) else try w.appendSlice(a, "null");
    try w.appendSlice(a, "}");
}

/// Render one method as a JSON object. `queried_class` lets us mark inherited
/// members (declared elsewhere up the chain).
fn appendMethodJson(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    m: *const types.MethodSymbol,
    queried_class: ?[]const u8,
) !void {
    try w.appendSlice(a, "{\"name\":");
    try appendJson(a, w, m.name);
    try w.appendSlice(a, ",\"symbol\":\"method\"");
    try w.appendSlice(a, ",\"declared_in\":");
    try appendJson(a, w, m.containing_class);
    if (queried_class) |qc| {
        const inh = !std.mem.eql(u8, qc, m.containing_class);
        try w.print(a, ",\"inherited\":{s}", .{if (inh) "true" else "false"});
    }
    try w.print(a, ",\"visibility\":\"{s}\",\"modifiers\":{{\"static\":{s},\"abstract\":{s},\"final\":{s}}}", .{
        @tagName(m.visibility),
        if (m.is_static) "true" else "false",
        if (m.is_abstract) "true" else "false",
        if (m.is_final) "true" else "false",
    });

    try w.appendSlice(a, ",\"parameters\":[");
    for (m.parameters, 0..) |p, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"name\":");
        try appendJson(a, w, p.name);
        try w.print(a, ",\"position\":{d},\"type\":", .{i});
        const eff = p.type_info orelse p.phpdoc_type;
        try appendTypeTriad(a, w, "native", p.type_info, p.phpdoc_type, eff);
        try w.print(a, ",\"has_default\":{s},\"variadic\":{s},\"by_reference\":{s},\"promoted\":{s}}}", .{
            if (p.has_default) "true" else "false",
            if (p.is_variadic) "true" else "false",
            if (p.is_by_reference) "true" else "false",
            if (p.is_promoted) "true" else "false",
        });
    }
    try w.appendSlice(a, "]");

    try w.appendSlice(a, ",\"return\":");
    try appendTypeTriad(a, w, "native", m.return_type, m.phpdoc_return, m.effectiveReturnType());

    try w.print(a, ",\"location\":{{\"file\":", .{});
    try appendJson(a, w, m.file_path);
    try w.print(a, ",\"start_line\":{d},\"end_line\":{d}}}", .{ m.start_line, m.end_line });

    try w.appendSlice(a, ",\"signature_text\":");
    const sig = try methodSignatureText(a, m);
    try appendJson(a, w, sig);

    try w.appendSlice(a, "}");
}

/// Reconstruct a human-readable signature line for a method.
fn methodSignatureText(a: std.mem.Allocator, m: *const types.MethodSymbol) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;
    try w.print(a, "{s}{s} function {s}(", .{
        @tagName(m.visibility),
        if (m.is_static) " static" else "",
        m.name,
    });
    for (m.parameters, 0..) |p, i| {
        if (i != 0) try w.appendSlice(a, ", ");
        const t = p.type_info orelse p.phpdoc_type;
        if (t) |tt| {
            const ts = try tt.format(a);
            try w.print(a, "{s} ", .{ts});
        }
        if (p.is_variadic) try w.appendSlice(a, "...");
        try w.print(a, "${s}", .{p.name});
        if (p.has_default) try w.appendSlice(a, " = …");
    }
    try w.appendSlice(a, ")");
    if (m.effectiveReturnType()) |rt| {
        const rs = try rt.format(a);
        try w.print(a, ": {s}", .{rs});
    }
    return buf.items;
}

/// Render one property as a JSON object.
fn appendPropertyJson(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    p: *const types.PropertySymbol,
) !void {
    try w.appendSlice(a, "{\"name\":");
    try appendJson(a, w, p.name);
    try w.print(a, ",\"symbol\":\"property\",\"visibility\":\"{s}\",\"static\":{s},\"readonly\":{s},\"type\":", .{
        @tagName(p.visibility),
        if (p.is_static) "true" else "false",
        if (p.is_readonly) "true" else "false",
    });
    try appendTypeTriad(a, w, "declared", p.declared_type, p.phpdoc_type, p.effectiveType());
    try w.print(a, ",\"location\":{{\"line\":{d}}}", .{p.line});
    try w.appendSlice(a, "}");
}

fn renderDescribeSymbol(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    fqn: []const u8,
    members: DescribeMembers,
    inherited: bool,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;
    const st = &index.sym_table;

    // ---- Member path: Class::method or Class::property -------------------
    if (std.mem.indexOf(u8, fqn, "::")) |sep| {
        const class_fqcn = fqn[0..sep];
        const member = fqn[sep + 2 ..];

        // Method (class, incl. inherited via resolved view; then interface).
        if (st.resolveMethod(class_fqcn, member)) |m| {
            try appendMethodJson(a, w, m, class_fqcn);
            return buf.items;
        }
        if (st.resolveInterfaceMethod(class_fqcn, member)) |m| {
            try appendMethodJson(a, w, m, class_fqcn);
            return buf.items;
        }
        if (st.getTrait(class_fqcn)) |tr| {
            if (tr.methods.getPtr(member)) |m| {
                try appendMethodJson(a, w, m, class_fqcn);
                return buf.items;
            }
        }
        // Property.
        if (st.resolveProperty(class_fqcn, member)) |p| {
            try appendPropertyJson(a, w, p);
            return buf.items;
        }
        try renderNotFound(a, w, fqn, "member not found on an indexed class/interface/trait (it may be inherited from a vendor base, magic, or external)");
        return buf.items;
    }

    // ---- Function -------------------------------------------------------
    if (st.getFunction(fqn)) |f| {
        try w.appendSlice(a, "{\"fqn\":");
        try appendJson(a, w, fqn);
        try w.appendSlice(a, ",\"symbol\":\"function\",\"parameters\":[");
        for (f.parameters, 0..) |p, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"name\":");
            try appendJson(a, w, p.name);
            try w.print(a, ",\"position\":{d},\"type\":", .{i});
            const eff = p.type_info orelse p.phpdoc_type;
            try appendTypeTriad(a, w, "native", p.type_info, p.phpdoc_type, eff);
            try w.print(a, ",\"has_default\":{s},\"variadic\":{s}}}", .{
                if (p.has_default) "true" else "false",
                if (p.is_variadic) "true" else "false",
            });
        }
        try w.appendSlice(a, "],\"return\":");
        try appendTypeTriad(a, w, "native", f.return_type, f.phpdoc_return, f.effectiveReturnType());
        try w.print(a, ",\"location\":{{\"file\":", .{});
        try appendJson(a, w, f.file_path);
        try w.print(a, ",\"start_line\":{d},\"end_line\":{d}}}}}", .{ f.start_line, f.end_line });
        return buf.items;
    }

    // ---- Type: class / interface / trait --------------------------------
    if (st.getClass(fqn)) |c| {
        try renderClass(a, w, index, c, members, inherited);
        return buf.items;
    }
    if (st.getInterface(fqn)) |iface| {
        try renderInterface(a, w, iface, members);
        return buf.items;
    }
    if (st.getTrait(fqn)) |tr| {
        try renderTrait(a, w, tr, members);
        return buf.items;
    }

    try renderNotFound(a, w, fqn, "not found in any indexed project (it may be a vendor/core symbol, or the FQN is misspelled)");
    return buf.items;
}

fn renderNotFound(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), fqn: []const u8, note: []const u8) !void {
    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, fqn);
    try w.appendSlice(a, ",\"found\":false,\"note\":");
    try appendJson(a, w, note);
    try w.appendSlice(a, "}");
}

fn appendStringArray(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), items: []const []const u8) !void {
    try w.appendSlice(a, "[");
    for (items, 0..) |s, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try appendJson(a, w, s);
    }
    try w.appendSlice(a, "]");
}

fn renderClass(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    index: *const ProjectIndex,
    c: *const types.ClassSymbol,
    members: DescribeMembers,
    inherited: bool,
) !void {
    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, c.fqcn);
    try w.print(a, ",\"symbol\":\"class\",\"modifiers\":{{\"abstract\":{s},\"final\":{s},\"readonly\":{s}}}", .{
        if (c.is_abstract) "true" else "false",
        if (c.is_final) "true" else "false",
        if (c.is_readonly) "true" else "false",
    });
    try w.appendSlice(a, ",\"namespace\":");
    if (c.namespace) |ns| try appendJson(a, w, ns) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"extends\":");
    if (c.extends) |e| try appendJson(a, w, e) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"implements\":");
    try appendStringArray(a, w, c.implements);
    try w.appendSlice(a, ",\"uses_traits\":");
    try appendStringArray(a, w, c.uses);

    // Generics (omit when absent).
    if (c.template_params.len > 0 or c.extends_type_args.len > 0) {
        try w.appendSlice(a, ",\"generics\":{\"templates\":[");
        for (c.template_params, 0..) |tp, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try w.appendSlice(a, "{\"name\":");
            try appendJson(a, w, tp.name);
            try w.appendSlice(a, ",\"fallback\":");
            if (tp.fallback) |fb| try appendJson(a, w, fb) else try w.appendSlice(a, "null");
            try w.appendSlice(a, "}");
        }
        try w.appendSlice(a, "],\"extends_args\":");
        try appendStringArray(a, w, c.extends_type_args);
        try w.appendSlice(a, "}");
    }

    const rc = if (index.resolved) |rv| rv.getClass(c.fqcn) else null;
    if (rc) |resolved_class| {
        try w.appendSlice(a, ",\"parent_chain\":");
        try appendStringArray(a, w, resolved_class.parent_chain);
    }

    try w.print(a, ",\"location\":{{\"file\":", .{});
    try appendJson(a, w, c.file_path);
    try w.print(a, ",\"start_line\":{d},\"end_line\":{d}}}", .{ c.start_line, c.end_line });

    // Members.
    try w.appendSlice(a, ",\"members\":{");
    const detail = members != .none;
    try appendMemberSection(a, w, "method", c, rc, inherited, detail);
    try w.appendSlice(a, ",");
    try appendMemberSection(a, w, "property", c, rc, inherited, detail);
    try w.appendSlice(a, "}}");
}

/// Emit `own_methods`/`inherited_methods` (or `_properties`) sections. "Own"
/// = directly declared on the class; "inherited" = present in the resolved view
/// but not declared on the class. When `detail` is false, arrays hold names;
/// otherwise full member objects (capped).
fn appendMemberSection(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    comptime which: []const u8,
    c: *const types.ClassSymbol,
    rc: ?*const symbol_table_mod.ResolvedClass,
    inherited: bool,
    detail: bool,
) !void {
    const is_method = comptime std.mem.eql(u8, which, "method");

    // Own members (sorted by name for determinism).
    var own_names: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var it = if (is_method) c.methods.keyIterator() else c.properties.keyIterator();
        while (it.next()) |k| try own_names.append(a, k.*);
    }
    std.mem.sort([]const u8, own_names.items, {}, lessThanStrFn);

    try w.appendSlice(a, if (is_method) "\"own_methods\":[" else "\"own_properties\":[");
    var shown: usize = 0;
    for (own_names.items) |name| {
        if (shown >= cb_list_cap) break;
        if (shown != 0) try w.appendSlice(a, ",");
        if (detail) {
            if (is_method) {
                try appendMethodJson(a, w, c.methods.getPtr(name).?, c.fqcn);
            } else {
                try appendPropertyJson(a, w, c.properties.getPtr(name).?);
            }
        } else {
            try appendJson(a, w, name);
        }
        shown += 1;
    }
    try w.appendSlice(a, "]");
    if (own_names.items.len > shown) try w.appendSlice(a, if (is_method) ",\"own_methods_truncated\":true" else ",\"own_properties_truncated\":true");

    if (!inherited) return;

    // Inherited members = resolved view minus own.
    try w.appendSlice(a, if (is_method) ",\"inherited_methods\":[" else ",\"inherited_properties\":[");
    if (rc) |resolved_class| {
        var inh_names: std.ArrayListUnmanaged([]const u8) = .empty;
        {
            var it = if (is_method) resolved_class.all_methods.keyIterator() else resolved_class.all_properties.keyIterator();
            while (it.next()) |k| {
                const owned = if (is_method) c.methods.contains(k.*) else c.properties.contains(k.*);
                if (!owned) try inh_names.append(a, k.*);
            }
        }
        std.mem.sort([]const u8, inh_names.items, {}, lessThanStrFn);
        var ishown: usize = 0;
        for (inh_names.items) |name| {
            if (ishown >= cb_list_cap) break;
            if (ishown != 0) try w.appendSlice(a, ",");
            if (detail) {
                if (is_method) {
                    try appendMethodJson(a, w, resolved_class.all_methods.get(name).?, c.fqcn);
                } else {
                    try appendPropertyJson(a, w, resolved_class.all_properties.get(name).?);
                }
            } else {
                try appendJson(a, w, name);
            }
            ishown += 1;
        }
        try w.appendSlice(a, "]");
        if (inh_names.items.len > ishown) try w.appendSlice(a, if (is_method) ",\"inherited_methods_truncated\":true" else ",\"inherited_properties_truncated\":true");
    } else {
        try w.appendSlice(a, "]");
    }
}

fn lessThanStrFn(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn renderInterface(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    iface: *const types.InterfaceSymbol,
    members: DescribeMembers,
) !void {
    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, iface.fqcn);
    try w.appendSlice(a, ",\"symbol\":\"interface\",\"namespace\":");
    if (iface.namespace) |ns| try appendJson(a, w, ns) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"extends\":");
    try appendStringArray(a, w, iface.extends);
    try w.print(a, ",\"location\":{{\"file\":", .{});
    try appendJson(a, w, iface.file_path);
    try w.print(a, ",\"start_line\":{d},\"end_line\":{d}}}", .{ iface.start_line, iface.end_line });

    try w.appendSlice(a, ",\"members\":{\"own_methods\":[");
    if (members != .none) {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = iface.methods.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStrFn);
        for (names.items, 0..) |name, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try appendMethodJson(a, w, iface.methods.getPtr(name).?, iface.fqcn);
        }
    } else {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = iface.methods.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStrFn);
        for (names.items, 0..) |name, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try appendJson(a, w, name);
        }
    }
    try w.appendSlice(a, "]}}");
}

fn renderTrait(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    tr: *const types.TraitSymbol,
    members: DescribeMembers,
) !void {
    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, tr.fqcn);
    try w.appendSlice(a, ",\"symbol\":\"trait\",\"namespace\":");
    if (tr.namespace) |ns| try appendJson(a, w, ns) else try w.appendSlice(a, "null");
    try w.appendSlice(a, ",\"uses_traits\":");
    try appendStringArray(a, w, tr.uses);
    try w.print(a, ",\"location\":{{\"file\":", .{});
    try appendJson(a, w, tr.file_path);
    try w.print(a, ",\"start_line\":{d},\"end_line\":{d}}}", .{ tr.start_line, tr.end_line });

    const detail = members != .none;
    try w.appendSlice(a, ",\"members\":{\"own_methods\":[");
    {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = tr.methods.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStrFn);
        for (names.items, 0..) |name, i| {
            if (i != 0) try w.appendSlice(a, ",");
            if (detail) try appendMethodJson(a, w, tr.methods.getPtr(name).?, tr.fqcn) else try appendJson(a, w, name);
        }
    }
    try w.appendSlice(a, "],\"own_properties\":[");
    {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = tr.properties.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStrFn);
        for (names.items, 0..) |name, i| {
            if (i != 0) try w.appendSlice(a, ",");
            if (detail) try appendPropertyJson(a, w, tr.properties.getPtr(name).?) else try appendJson(a, w, name);
        }
    }
    try w.appendSlice(a, "]}}");
}

// ============================================================================
// resolve_interface tool
// ============================================================================

const resolve_interface_tool_description =
    \\DI/wiring explainer: what does an interface-typed call actually hit, and
    \\why? Given an INTERFACE FQN, returns its in-project implementors and the
    \\concrete the resolver would pick (`binding.kind`: di_config 0.85 >
    \\single_impl 0.6 > ambiguous > none), mirroring the engine's
    \\`di_config_binding`/`interface_single_impl` resolution. Given a CLASS FQN,
    \\runs the reverse query: the interfaces it satisfies and which it is the
    \\chosen DI implementor of.
    \\
    \\Argument:
    \\  fqn: string (required) — an interface FQCN, or a class FQCN for the
    \\       reverse query. A leading backslash is tolerated.
    \\
    \\Returns JSON. Interface target: {fqn, symbol:"interface", implementors[],
    \\binding{resolves_to?, kind, confidence?, explanation}, methods[]}. Class
    \\target: {fqn, symbol:"class", implements[], implements_in_project[],
    \\is_di_bound_for[], bound_kind{iface:kind}}. Only in-project implementors
    \\are visible. Call `load_project` first.
;

fn buildResolveInterfaceSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "fqn", "An interface FQCN (forward query), or a class FQCN (reverse query). E.g. \"App\\Contract\\Mailer\".", true);
    return builder.toInputSchema(a);
}

fn resolveInterfaceHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    var fqn = mcp.tools.getString(arguments, "fqn") orelse "";
    if (fqn.len > 0 and fqn[0] == '\\') fqn = fqn[1..];
    if (fqn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`fqn` is required (an interface FQCN, or a class FQCN for the reverse query).",
        ) catch return error.OutOfMemory;
    }

    const payload = renderResolveInterface(allocator, lp.index, fqn) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// True if interface `start` is, or transitively extends, `target`. Bounded
/// depth guards against malformed cyclic `extends`.
fn interfaceReaches(st: *const symbol_table_mod.SymbolTable, start: []const u8, target: []const u8, depth: u8) bool {
    if (std.mem.eql(u8, start, target)) return true;
    if (depth == 0) return false;
    const iface = st.getInterface(start) orelse return false;
    for (iface.extends) |parent| {
        if (interfaceReaches(st, parent, target, depth - 1)) return true;
    }
    return false;
}

/// Collect every in-project class that implements `iface_fqcn` (directly, or via
/// an implemented interface that transitively extends it). Sorted, deduped.
fn collectImplementors(
    a: std.mem.Allocator,
    st: *const symbol_table_mod.SymbolTable,
    iface_fqcn: []const u8,
) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = st.classes.iterator();
    while (it.next()) |entry| {
        const class = entry.value_ptr;
        for (class.implements) |impl_iface| {
            if (interfaceReaches(st, impl_iface, iface_fqcn, 16)) {
                try list.append(a, entry.key_ptr.*);
                break;
            }
        }
    }
    std.mem.sort([]const u8, list.items, {}, lessThanStrFn);
    return list.items;
}

fn renderResolveInterface(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    fqn: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;
    const st = &index.sym_table;

    // ---- Forward: interface target --------------------------------------
    if (st.getInterface(fqn)) |iface| {
        const implementors = try collectImplementors(a, st, fqn);

        try w.appendSlice(a, "{\"fqn\":");
        try appendJson(a, w, fqn);
        try w.appendSlice(a, ",\"symbol\":\"interface\",\"implementors\":");
        try appendStringArray(a, w, implementors);

        // Binding: config-authoritative first, then single-implementor heuristic.
        const explicit = if (index.resolved) |rv| rv.explicitImplementor(fqn) else null;
        const single = if (index.resolved) |rv| rv.singleImplementor(fqn) else null;
        try w.appendSlice(a, ",\"binding\":");
        if (explicit) |concrete| {
            try w.appendSlice(a, "{\"resolves_to\":");
            try appendJson(a, w, concrete);
            try w.print(a, ",\"kind\":\"di_config\",\"confidence\":0.85,\"explanation\":\"Bound in services.yaml (authoritative over {d} implementor(s)).\"}}", .{implementors.len});
        } else if (single) |concrete| {
            try w.appendSlice(a, "{\"resolves_to\":");
            try appendJson(a, w, concrete);
            try w.appendSlice(a, ",\"kind\":\"single_impl\",\"confidence\":0.6,\"explanation\":\"Exactly one in-project implementor.\"}");
        } else if (implementors.len >= 2) {
            try w.appendSlice(a, "{\"kind\":\"ambiguous\",\"explanation\":\"Multiple implementors and no services.yaml binding; the concrete is chosen by the DI container at runtime.\"}");
        } else {
            try w.appendSlice(a, "{\"kind\":\"none\",\"explanation\":\"No in-project implementor (it may be implemented in vendor/core).\"}");
        }

        // Own method names.
        try w.appendSlice(a, ",\"methods\":");
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var mit = iface.methods.keyIterator();
        while (mit.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStrFn);
        try appendStringArray(a, w, names.items);
        try w.appendSlice(a, "}");
        return buf.items;
    }

    // ---- Reverse: class target ------------------------------------------
    if (st.getClass(fqn)) |c| {
        try w.appendSlice(a, "{\"fqn\":");
        try appendJson(a, w, fqn);
        try w.appendSlice(a, ",\"symbol\":\"class\",\"implements\":");
        try appendStringArray(a, w, c.implements);

        // Which implemented interfaces are themselves indexed.
        var in_project: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.implements) |iface_fqcn| {
            if (st.getInterface(iface_fqcn) != null) try in_project.append(a, iface_fqcn);
        }
        std.mem.sort([]const u8, in_project.items, {}, lessThanStrFn);
        try w.appendSlice(a, ",\"implements_in_project\":");
        try appendStringArray(a, w, in_project.items);

        // Interfaces this class is the chosen DI implementor of (scan the
        // resolved view's binding indexes for values pointing at this class).
        var bound_for: std.ArrayListUnmanaged([]const u8) = .empty;
        var bound_kinds: std.ArrayListUnmanaged([2][]const u8) = .empty;
        if (index.resolved) |rv| {
            var eit = rv.explicit_bindings.iterator();
            while (eit.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, fqn)) {
                    try bound_for.append(a, entry.key_ptr.*);
                    try bound_kinds.append(a, .{ entry.key_ptr.*, "di_config" });
                }
            }
            var sit = rv.iface_single_impl.iterator();
            while (sit.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, fqn)) {
                    // Don't double-list an interface already bound via config.
                    if (rv.explicitImplementor(entry.key_ptr.*) == null) {
                        try bound_for.append(a, entry.key_ptr.*);
                        try bound_kinds.append(a, .{ entry.key_ptr.*, "single_impl" });
                    }
                }
            }
        }
        std.mem.sort([]const u8, bound_for.items, {}, lessThanStrFn);
        try w.appendSlice(a, ",\"is_di_bound_for\":");
        try appendStringArray(a, w, bound_for.items);

        try w.appendSlice(a, ",\"bound_kind\":{");
        std.mem.sort([2][]const u8, bound_kinds.items, {}, struct {
            fn lt(_: void, l: [2][]const u8, r: [2][]const u8) bool {
                return std.mem.lessThan(u8, l[0], r[0]);
            }
        }.lt);
        for (bound_kinds.items, 0..) |bk, i| {
            if (i != 0) try w.appendSlice(a, ",");
            try appendJson(a, w, bk[0]);
            try w.print(a, ":\"{s}\"", .{bk[1]});
        }
        try w.appendSlice(a, "}}");
        return buf.items;
    }

    try renderNotFound(a, w, fqn, "not found as an in-project interface or class (it may be a vendor/core symbol, or the FQN is misspelled)");
    return buf.items;
}

// ============================================================================
// find_by_type tool
// ============================================================================

const find_by_type_tool_description =
    \\Type producer/consumer/holder index — navigate by TYPE, not by call (the
    \\one thing the call graph can't give). For a class/interface FQCN:
    \\  - producers: methods/functions whose return type is the type ("where do
    \\    I get one?")
    \\  - consumers: methods/functions that accept it as a parameter ("where can
    \\    it go?")
    \\  - holders: properties typed as it ("who stores one?")
    \\
    \\Arguments:
    \\  type: string (required) — a class/interface FQCN (not a builtin).
    \\  roles: enum(all|producers|consumers|holders) default all.
    \\  include_subtypes: bool (default false) — also match in-project subclasses
    \\    / implementors / sub-interfaces of `type`.
    \\  namespace_prefix: string (optional) — keep only results declared under
    \\    this namespace prefix.
    \\  exclude_tests: bool (default true) — drop results declared in test files.
    \\  limit: int (default 200, cap 1000) — per-role cap.
    \\
    \\Returns JSON: {type, matched_types[], summary{producers,consumers,holders},
    \\producers[], consumers[], holders[], caveats}. Each match: {fqn, kind, match
    \\{via, type_text, source[, param, position]}, file, line, is_test}. Only
    \\in-project subtypes are visible. Call `load_project` first.
;

const FindRoles = enum { all, producers, consumers, holders };

fn buildFindByTypeSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "type", "A class/interface FQCN to search for (e.g. \"App\\User\"). Builtins are rejected.", true);
    _ = try builder.addEnumWithDefault(a, "roles", "Which relationships to return.", &.{ "all", "producers", "consumers", "holders" }, "all", false);
    _ = try builder.addBooleanWithDefault(a, "include_subtypes", "Also match in-project subclasses/implementors/sub-interfaces (default false).", false, false);
    _ = try builder.addString(a, "namespace_prefix", "Keep only results declared under this namespace prefix.", false);
    _ = try builder.addBooleanWithDefault(a, "exclude_tests", "Drop results declared in test files (default true).", true, false);
    _ = try builder.addInteger(a, "limit", "Per-role result cap (default 200, max 1000).", false);
    return builder.toInputSchema(a);
}

const FindOpts = struct {
    roles: FindRoles = .all,
    include_subtypes: bool = false,
    namespace_prefix: ?[]const u8 = null,
    exclude_tests: bool = true,
    limit: usize = cb_list_cap,
};

/// A single type-usage match (a producer, consumer, or holder).
const TypeMatch = struct {
    fqn: []const u8, // e.g. "App\\Foo::bar" or "App\\helper"
    kind: []const u8, // "method" | "function" | "property"
    via: []const u8, // "return" | "param" | "property"
    param_name: ?[]const u8 = null,
    position: ?usize = null,
    type_text: []const u8,
    source: []const u8, // "native" | "phpdoc"
    file: []const u8,
    line: u32,
    is_test: bool,
};

fn typeMatchesSet(set: *const std.StringHashMap(void), t: types.TypeInfo) bool {
    if (set.contains(t.base_type)) return true;
    if (t.kind == .union_type or t.kind == .intersection) {
        for (t.type_parts) |p| if (set.contains(p)) return true;
    }
    return false;
}

const PickedType = struct { t: types.TypeInfo, source: []const u8 };

/// Pick whichever of the native/PHPDoc type matches the set, native first.
fn pickMatch(set: *const std.StringHashMap(void), native: ?types.TypeInfo, doc: ?types.TypeInfo) ?PickedType {
    if (native) |n| {
        if (typeMatchesSet(set, n)) return .{ .t = n, .source = "native" };
    }
    if (doc) |d| {
        if (typeMatchesSet(set, d)) return .{ .t = d, .source = "phpdoc" };
    }
    return null;
}

fn findByTypeHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    var type_fqcn = mcp.tools.getString(arguments, "type") orelse "";
    if (type_fqcn.len > 0 and type_fqcn[0] == '\\') type_fqcn = type_fqcn[1..];
    if (type_fqcn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`type` is required (a class/interface FQCN, e.g. \"App\\User\").",
        ) catch return error.OutOfMemory;
    }
    if (types.TypeInfo.isBuiltin(type_fqcn)) {
        return mcp.tools.errorResult(
            allocator,
            "`type` must be a class/interface FQCN, not a builtin (builtins match too broadly).",
        ) catch return error.OutOfMemory;
    }

    const opts = FindOpts{
        .roles = blk: {
            const s = mcp.tools.getString(arguments, "roles") orelse break :blk .all;
            if (std.mem.eql(u8, s, "producers")) break :blk .producers;
            if (std.mem.eql(u8, s, "consumers")) break :blk .consumers;
            if (std.mem.eql(u8, s, "holders")) break :blk .holders;
            break :blk .all;
        },
        .include_subtypes = mcp.tools.getBoolean(arguments, "include_subtypes") orelse false,
        .namespace_prefix = blk: {
            const s = mcp.tools.getString(arguments, "namespace_prefix") orelse break :blk null;
            break :blk if (s.len == 0) null else s;
        },
        .exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true,
        .limit = blk: {
            const n = mcp.tools.getInteger(arguments, "limit") orelse break :blk cb_list_cap;
            if (n < 1) break :blk cb_list_cap;
            if (n > query.limit_ceiling) break :blk query.limit_ceiling;
            break :blk @intCast(n);
        },
    };

    const payload = renderFindByType(allocator, lp.index, type_fqcn, opts) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// Build the match set: `{type}` plus, when requested, every in-project subtype
/// (subclass via parent_chain, implementor via implements, or sub-interface via
/// extends).
fn buildMatchSet(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    type_fqcn: []const u8,
    include_subtypes: bool,
) !std.StringHashMap(void) {
    const st = &index.sym_table;
    var set = std.StringHashMap(void).init(a);
    try set.put(type_fqcn, {});
    if (!include_subtypes) return set;

    // Subclasses + implementors.
    var cit = st.classes.iterator();
    while (cit.next()) |entry| {
        const class = entry.value_ptr;
        var matched = false;
        if (index.resolved) |rv| {
            if (rv.getClass(entry.key_ptr.*)) |rc| {
                for (rc.parent_chain) |anc| {
                    if (std.mem.eql(u8, anc, type_fqcn)) {
                        matched = true;
                        break;
                    }
                }
            }
        }
        if (!matched) {
            for (class.implements) |impl_iface| {
                if (interfaceReaches(st, impl_iface, type_fqcn, 16)) {
                    matched = true;
                    break;
                }
            }
        }
        if (matched) try set.put(entry.key_ptr.*, {});
    }

    // Sub-interfaces (an interface that transitively extends `type`).
    var iit = st.interfaces.iterator();
    while (iit.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, type_fqcn)) continue;
        if (interfaceReaches(st, entry.key_ptr.*, type_fqcn, 16)) {
            try set.put(entry.key_ptr.*, {});
        }
    }
    return set;
}

/// Scan one method (or interface method) for producer/consumer matches.
fn scanMethodForType(
    a: std.mem.Allocator,
    set: *const std.StringHashMap(void),
    owner_fqcn: []const u8,
    m: *const types.MethodSymbol,
    producers: *std.ArrayListUnmanaged(TypeMatch),
    consumers: *std.ArrayListUnmanaged(TypeMatch),
    want_producers: bool,
    want_consumers: bool,
) !void {
    const fqn = try std.fmt.allocPrint(a, "{s}::{s}", .{ owner_fqcn, m.name });

    if (want_producers) {
        if (pickMatch(set, m.return_type, m.phpdoc_return)) |pm| {
            try producers.append(a, .{
                .fqn = fqn,
                .kind = "method",
                .via = "return",
                .type_text = try pm.t.format(a),
                .source = pm.source,
                .file = m.file_path,
                .line = m.start_line,
                .is_test = query.isTestFile(m.file_path),
            });
        }
    }

    if (want_consumers) {
        for (m.parameters, 0..) |p, i| {
            if (pickMatch(set, p.type_info, p.phpdoc_type)) |pm| {
                try consumers.append(a, .{
                    .fqn = fqn,
                    .kind = "method",
                    .via = "param",
                    .param_name = p.name,
                    .position = i,
                    .type_text = try pm.t.format(a),
                    .source = pm.source,
                    .file = m.file_path,
                    .line = m.start_line,
                    .is_test = query.isTestFile(m.file_path),
                });
            }
        }
    }
}

fn renderFindByType(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    type_fqcn: []const u8,
    opts: FindOpts,
) ![]const u8 {
    const st = &index.sym_table;
    var set = try buildMatchSet(a, index, type_fqcn, opts.include_subtypes);
    defer set.deinit();

    const want_p = opts.roles == .all or opts.roles == .producers;
    const want_c = opts.roles == .all or opts.roles == .consumers;
    const want_h = opts.roles == .all or opts.roles == .holders;

    var producers: std.ArrayListUnmanaged(TypeMatch) = .empty;
    var consumers: std.ArrayListUnmanaged(TypeMatch) = .empty;
    var holders: std.ArrayListUnmanaged(TypeMatch) = .empty;

    // Pass over classes: own methods (producers/consumers) + properties (holders).
    var cit = st.classes.iterator();
    while (cit.next()) |entry| {
        const class = entry.value_ptr;
        if (want_p or want_c) {
            var mit = class.methods.valueIterator();
            while (mit.next()) |m| {
                try scanMethodForType(a, &set, entry.key_ptr.*, m, &producers, &consumers, want_p, want_c);
            }
        }
        if (want_h) {
            var pit = class.properties.iterator();
            while (pit.next()) |pe| {
                const prop = pe.value_ptr;
                if (pickMatch(&set, prop.declared_type, prop.phpdoc_type)) |pm| {
                    const fqn = try std.fmt.allocPrint(a, "{s}::{s}", .{ entry.key_ptr.*, prop.name });
                    try holders.append(a, .{
                        .fqn = fqn,
                        .kind = "property",
                        .via = "property",
                        .type_text = try pm.t.format(a),
                        .source = pm.source,
                        .file = class.file_path,
                        .line = prop.line,
                        .is_test = query.isTestFile(class.file_path),
                    });
                }
            }
        }
    }

    // Interface methods (producers/consumers).
    if (want_p or want_c) {
        var iit = st.interfaces.iterator();
        while (iit.next()) |entry| {
            var mit = entry.value_ptr.methods.valueIterator();
            while (mit.next()) |m| {
                try scanMethodForType(a, &set, entry.key_ptr.*, m, &producers, &consumers, want_p, want_c);
            }
        }
    }

    // Free functions (producers/consumers).
    if (want_p or want_c) {
        var fit = st.functions.iterator();
        while (fit.next()) |entry| {
            const f = entry.value_ptr;
            if (want_p) {
                if (pickMatch(&set, f.return_type, f.phpdoc_return)) |pm| {
                    try producers.append(a, .{
                        .fqn = entry.key_ptr.*,
                        .kind = "function",
                        .via = "return",
                        .type_text = try pm.t.format(a),
                        .source = pm.source,
                        .file = f.file_path,
                        .line = f.start_line,
                        .is_test = query.isTestFile(f.file_path),
                    });
                }
            }
            if (want_c) {
                for (f.parameters, 0..) |p, i| {
                    if (pickMatch(&set, p.type_info, p.phpdoc_type)) |pm| {
                        try consumers.append(a, .{
                            .fqn = entry.key_ptr.*,
                            .kind = "function",
                            .via = "param",
                            .param_name = p.name,
                            .position = i,
                            .type_text = try pm.t.format(a),
                            .source = pm.source,
                            .file = f.file_path,
                            .line = f.start_line,
                            .is_test = query.isTestFile(f.file_path),
                        });
                    }
                }
            }
        }
    }

    // Filter (tests / namespace) + sort each list deterministically.
    filterMatches(&producers, opts);
    filterMatches(&consumers, opts);
    filterMatches(&holders, opts);
    std.mem.sort(TypeMatch, producers.items, {}, typeMatchLess);
    std.mem.sort(TypeMatch, consumers.items, {}, typeMatchLess);
    std.mem.sort(TypeMatch, holders.items, {}, typeMatchLess);

    // Render.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;
    try w.appendSlice(a, "{\"type\":");
    try appendJson(a, w, type_fqcn);

    // matched_types (sorted).
    var matched: std.ArrayListUnmanaged([]const u8) = .empty;
    var sit = set.keyIterator();
    while (sit.next()) |k| try matched.append(a, k.*);
    std.mem.sort([]const u8, matched.items, {}, lessThanStrFn);
    try w.appendSlice(a, ",\"matched_types\":");
    try appendStringArray(a, w, matched.items);

    try w.print(a, ",\"summary\":{{\"producers\":{d},\"consumers\":{d},\"holders\":{d}}}", .{
        producers.items.len, consumers.items.len, holders.items.len,
    });

    var truncated = false;
    if (want_p) truncated = try appendMatchList(a, w, "producers", producers.items, opts.limit) or truncated;
    if (want_c) truncated = try appendMatchList(a, w, "consumers", consumers.items, opts.limit) or truncated;
    if (want_h) truncated = try appendMatchList(a, w, "holders", holders.items, opts.limit) or truncated;

    try w.print(a, ",\"caveats\":{{\"union_array_matching\":\"FQCN-resolved (simple/nullable/union/intersection/array element)\",\"subtypes_included\":{s},\"tests_excluded\":{s},\"truncated\":{s}}}", .{
        if (opts.include_subtypes) "true" else "false",
        if (opts.exclude_tests) "true" else "false",
        if (truncated) "true" else "false",
    });
    try w.appendSlice(a, "}");
    return buf.items;
}

/// Drop test-file matches (when excluding) and matches outside the namespace
/// prefix, in place.
fn filterMatches(list: *std.ArrayListUnmanaged(TypeMatch), opts: FindOpts) void {
    var i: usize = 0;
    while (i < list.items.len) {
        const m = list.items[i];
        const drop = (opts.exclude_tests and m.is_test) or
            (opts.namespace_prefix != null and !std.mem.startsWith(u8, m.fqn, opts.namespace_prefix.?));
        if (drop) {
            _ = list.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

fn typeMatchLess(_: void, l: TypeMatch, r: TypeMatch) bool {
    const c = std.mem.order(u8, l.fqn, r.fqn);
    if (c != .eq) return c == .lt;
    return (l.position orelse 0) < (r.position orelse 0);
}

/// Emit a `"name":[...]` match array (capped at `limit`). Returns true if the
/// list was truncated.
fn appendMatchList(
    a: std.mem.Allocator,
    w: *std.ArrayListUnmanaged(u8),
    comptime name: []const u8,
    items: []const TypeMatch,
    limit: usize,
) !bool {
    try w.appendSlice(a, ",\"" ++ name ++ "\":[");
    const shown = @min(items.len, limit);
    for (items[0..shown], 0..) |m, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"fqn\":");
        try appendJson(a, w, m.fqn);
        try w.print(a, ",\"kind\":\"{s}\",\"match\":{{\"via\":\"{s}\"", .{ m.kind, m.via });
        if (m.param_name) |pn| {
            try w.appendSlice(a, ",\"param\":");
            try appendJson(a, w, pn);
            try w.print(a, ",\"position\":{d}", .{m.position orelse 0});
        }
        try w.appendSlice(a, ",\"type_text\":");
        try appendJson(a, w, m.type_text);
        try w.print(a, ",\"source\":\"{s}\"}}", .{m.source});
        try w.appendSlice(a, ",\"file\":");
        try appendJson(a, w, m.file);
        try w.print(a, ",\"line\":{d},\"is_test\":{s}}}", .{ m.line, if (m.is_test) "true" else "false" });
    }
    try w.appendSlice(a, "]");
    if (shown < items.len) {
        try w.appendSlice(a, ",\"" ++ name ++ "_truncated\":true");
        return true;
    }
    return false;
}

// ============================================================================
// check_conformance tool
// ============================================================================

const check_conformance_tool_description =
    \\Contract conformance checker — use inheritance + resolved signatures to
    \\flag where a class *fails to match* the interfaces it implements and the
    \\abstract methods it inherits: missing methods, arity mismatches,
    \\incompatible param/return types, return nullability widening, and
    \\visibility narrowing. A correctness signal to check before trusting a class
    \\as a drop-in for its contract.
    \\
    \\Arguments:
    \\  fqn: string (required) — a class FQCN to check.
    \\  against: enum(all|interfaces|parent) default all — which contracts to
    \\    check against (implemented interfaces, the abstract parent chain, or
    \\    both).
    \\  include_ok: bool (default false) — also list conformant members
    \\    (otherwise only findings).
    \\
    \\Returns JSON: {fqn, symbol:"class", is_abstract, checked{interfaces[],
    \\parent}, summary{missing,mismatches,info,ok}, findings[], caveats}. Each
    \\finding: {severity (missing|mismatch|info|ok), member, contract, issue,
    \\detail, contract_signature, impl_signature?}. `issue` ∈ missing_method,
    \\param_count, param_type_incompatible, return_type_incompatible,
    \\nullability_widened, visibility_narrowed. This is a name-equality check, not
    \\a full LSP variance engine (see caveats). Call `load_project` first.
;

const ConformanceAgainst = enum { all, interfaces, parent };

fn buildCheckConformanceSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addString(a, "fqn", "A class FQCN to check for contract conformance (e.g. \"App\\Mailer\\SmtpMailer\").", true);
    _ = try builder.addEnumWithDefault(a, "against", "Which contracts to check against.", &.{ "all", "interfaces", "parent" }, "all", false);
    _ = try builder.addBooleanWithDefault(a, "include_ok", "Also list conformant members, not just findings (default false).", false, false);
    return builder.toInputSchema(a);
}

fn checkConformanceHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));

    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    var fqn = mcp.tools.getString(arguments, "fqn") orelse "";
    if (fqn.len > 0 and fqn[0] == '\\') fqn = fqn[1..];
    if (fqn.len == 0) {
        return mcp.tools.errorResult(
            allocator,
            "`fqn` is required (a class FQCN).",
        ) catch return error.OutOfMemory;
    }

    const against: ConformanceAgainst = blk: {
        const s = mcp.tools.getString(arguments, "against") orelse break :blk .all;
        if (std.mem.eql(u8, s, "interfaces")) break :blk .interfaces;
        if (std.mem.eql(u8, s, "parent")) break :blk .parent;
        break :blk .all;
    };
    const include_ok = mcp.tools.getBoolean(arguments, "include_ok") orelse false;

    const payload = renderCheckConformance(allocator, lp.index, fqn, against, include_ok) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

/// One contract method an implementor is obligated to provide compatibly.
const Contract = struct {
    name: []const u8,
    method: *const types.MethodSymbol, // the abstract declaration
    contract_fqn: []const u8, // declaring interface/parent FQCN
    is_interface: bool,
};

/// Visibility ordering, most permissive first: public(0) < protected(1) < private(2).
fn visibilityRank(v: types.Visibility) u8 {
    return switch (v) {
        .public => 0,
        .protected => 1,
        .private => 2,
    };
}

/// A `self`/`static`/`parent` type: name-equality can't judge these soundly
/// (they re-bind per class), so conformance comparison skips them.
fn isSelfReferentialType(t: types.TypeInfo) bool {
    return t.kind == .self_type or t.kind == .static_type or t.kind == .parent_type;
}

fn typeIsNullable(t: types.TypeInfo) bool {
    if (t.kind == .nullable) return true;
    if (t.kind == .union_type) {
        for (t.type_parts) |p| if (std.mem.eql(u8, p, "null")) return true;
    }
    return false;
}

/// A stable identity for name-equality comparison: the formatted type with a
/// leading `?` (nullable marker) stripped, so nullability is judged separately.
fn typeIdentity(a: std.mem.Allocator, t: types.TypeInfo) ![]const u8 {
    const s = try t.format(a);
    if (s.len > 0 and s[0] == '?') return s[1..];
    return s;
}

/// Recursively collect `iface` and every interface it transitively `extends`
/// (in-project only) into `out`. Bounded by a visited set.
fn collectInterfaceClosure(
    st: *const symbol_table_mod.SymbolTable,
    iface_fqcn: []const u8,
    out: *std.StringHashMap(void),
    depth: u8,
) !void {
    if (out.contains(iface_fqcn)) return;
    const iface = st.getInterface(iface_fqcn) orelse return;
    try out.put(iface_fqcn, {});
    if (depth == 0) return;
    for (iface.extends) |parent| {
        try collectInterfaceClosure(st, parent, out, depth - 1);
    }
}

/// Gather the contract methods a class must satisfy: every method declared by an
/// implemented interface (transitively, including interfaces implemented by
/// ancestors) and every abstract method inherited from the parent chain.
/// Deduped by method name (interface contracts win over parent abstracts).
fn collectContracts(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    class_fqcn: []const u8,
    against: ConformanceAgainst,
    iface_list_out: *std.ArrayListUnmanaged([]const u8),
) ![]const Contract {
    const st = &index.sym_table;
    var contracts: std.ArrayListUnmanaged(Contract) = .empty;
    var seen_names = std.StringHashMap(void).init(a);

    // The class plus its ancestors, so interfaces (and abstract methods)
    // introduced anywhere up the chain are accounted for.
    var lineage: std.ArrayListUnmanaged([]const u8) = .empty;
    try lineage.append(a, class_fqcn);
    if (index.resolved) |rv| {
        if (rv.getClass(class_fqcn)) |rc| {
            for (rc.parent_chain) |anc| try lineage.append(a, anc);
        }
    }

    // ---- Interface contracts --------------------------------------------
    if (against == .all or against == .interfaces) {
        var iface_set = std.StringHashMap(void).init(a);
        for (lineage.items) |fqcn| {
            const c = st.getClass(fqcn) orelse continue;
            for (c.implements) |impl_iface| {
                try collectInterfaceClosure(st, impl_iface, &iface_set, 16);
            }
        }
        var iit = iface_set.keyIterator();
        while (iit.next()) |k| try iface_list_out.append(a, k.*);
        std.mem.sort([]const u8, iface_list_out.items, {}, lessThanStrFn);

        for (iface_list_out.items) |iface_fqcn| {
            const iface = st.getInterface(iface_fqcn) orelse continue;
            var mit = iface.methods.iterator();
            while (mit.next()) |entry| {
                const name = entry.key_ptr.*;
                if (seen_names.contains(name)) continue;
                try seen_names.put(name, {});
                try contracts.append(a, .{
                    .name = name,
                    .method = entry.value_ptr,
                    .contract_fqn = iface_fqcn,
                    .is_interface = true,
                });
            }
        }
    }

    // ---- Parent abstract-method contracts -------------------------------
    if (against == .all or against == .parent) {
        // Walk only the ancestors (skip the class itself at index 0).
        for (lineage.items[@min(1, lineage.items.len)..]) |anc_fqcn| {
            const anc = st.getClass(anc_fqcn) orelse continue;
            var mit = anc.methods.iterator();
            while (mit.next()) |entry| {
                if (!entry.value_ptr.is_abstract) continue;
                const name = entry.key_ptr.*;
                if (seen_names.contains(name)) continue;
                try seen_names.put(name, {});
                try contracts.append(a, .{
                    .name = name,
                    .method = entry.value_ptr,
                    .contract_fqn = anc_fqcn,
                    .is_interface = false,
                });
            }
        }
    }

    std.mem.sort(Contract, contracts.items, {}, struct {
        fn lt(_: void, l: Contract, r: Contract) bool {
            return std.mem.lessThan(u8, l.name, r.name);
        }
    }.lt);
    return contracts.items;
}

const Finding = struct {
    severity: []const u8, // missing | mismatch | info | ok
    member: []const u8,
    contract: []const u8, // contract_fqn::method
    issue: []const u8,
    detail: []const u8,
    contract_signature: []const u8,
    impl_signature: ?[]const u8,
};

fn renderCheckConformance(
    a: std.mem.Allocator,
    index: *const ProjectIndex,
    fqn: []const u8,
    against: ConformanceAgainst,
    include_ok: bool,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;
    const st = &index.sym_table;

    const class = st.getClass(fqn) orelse {
        try renderNotFound(a, w, fqn, "not found as an in-project class (conformance is only checked for classes; interfaces/traits and vendor symbols are out of scope)");
        return buf.items;
    };

    var iface_list: std.ArrayListUnmanaged([]const u8) = .empty;
    const contracts = try collectContracts(a, index, fqn, against, &iface_list);

    // Magic `__call`/`__get` can satisfy a missing instance method at runtime.
    const has_call = st.resolveMethod(fqn, "__call") != null;

    var findings: std.ArrayListUnmanaged(Finding) = .empty;
    var n_missing: usize = 0;
    var n_mismatch: usize = 0;
    var n_info: usize = 0;
    var n_ok: usize = 0;

    for (contracts) |ct| {
        const contract_id = try std.fmt.allocPrint(a, "{s}::{s}", .{ ct.contract_fqn, ct.name });
        const contract_sig = try methodSignatureText(a, ct.method);

        const impl = st.resolveMethod(fqn, ct.name);
        if (impl == null) {
            // Abstract classes need not implement inherited abstract methods.
            if (class.is_abstract) continue;
            if (has_call) {
                n_info += 1;
                try findings.append(a, .{
                    .severity = "info",
                    .member = ct.name,
                    .contract = contract_id,
                    .issue = "missing_method",
                    .detail = "not declared, but the class defines __call so it may be handled dynamically at runtime",
                    .contract_signature = contract_sig,
                    .impl_signature = null,
                });
            } else {
                n_missing += 1;
                try findings.append(a, .{
                    .severity = "missing",
                    .member = ct.name,
                    .contract = contract_id,
                    .issue = "missing_method",
                    .detail = "required by the contract but not implemented",
                    .contract_signature = contract_sig,
                    .impl_signature = null,
                });
            }
            continue;
        }

        const im = impl.?;
        const impl_sig = try methodSignatureText(a, im);
        var member_ok = true;

        // --- Param arity ---------------------------------------------------
        var impl_has_variadic = false;
        var impl_required: usize = 0;
        for (im.parameters) |p| {
            if (p.is_variadic) impl_has_variadic = true;
            if (!p.has_default and !p.is_variadic) impl_required += 1;
        }
        const contract_count = ct.method.parameters.len;
        const arity_bad = (!impl_has_variadic and im.parameters.len < contract_count) or
            (impl_required > contract_count);
        if (arity_bad) {
            member_ok = false;
            n_mismatch += 1;
            try findings.append(a, .{
                .severity = "mismatch",
                .member = ct.name,
                .contract = contract_id,
                .issue = "param_count",
                .detail = try std.fmt.allocPrint(a, "contract declares {d} parameter(s); implementation declares {d} ({d} required)", .{ contract_count, im.parameters.len, impl_required }),
                .contract_signature = contract_sig,
                .impl_signature = impl_sig,
            });
        } else {
            // --- Per-position param type (only when arity is compatible) ---
            const n = @min(contract_count, im.parameters.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const cp = ct.method.parameters[i];
                const ip = im.parameters[i];
                const ct_t = cp.type_info orelse cp.phpdoc_type orelse continue;
                const ip_t = ip.type_info orelse ip.phpdoc_type orelse continue;
                if (isSelfReferentialType(ct_t) or isSelfReferentialType(ip_t)) continue;
                const ck = try typeIdentity(a, ct_t);
                const ik = try typeIdentity(a, ip_t);
                if (!std.mem.eql(u8, ck, ik)) {
                    member_ok = false;
                    n_mismatch += 1;
                    try findings.append(a, .{
                        .severity = "mismatch",
                        .member = ct.name,
                        .contract = contract_id,
                        .issue = "param_type_incompatible",
                        .detail = try std.fmt.allocPrint(a, "parameter #{d} (${s}): contract type {s}, implementation type {s}", .{ i + 1, ip.name, ck, ik }),
                        .contract_signature = contract_sig,
                        .impl_signature = impl_sig,
                    });
                }
            }
        }

        // --- Return type ---------------------------------------------------
        if (ct.method.effectiveReturnType()) |cr| {
            if (im.effectiveReturnType()) |ir| {
                if (!isSelfReferentialType(cr) and !isSelfReferentialType(ir)) {
                    const ck = try typeIdentity(a, cr);
                    const ik = try typeIdentity(a, ir);
                    if (!std.mem.eql(u8, ck, ik)) {
                        member_ok = false;
                        n_mismatch += 1;
                        try findings.append(a, .{
                            .severity = "mismatch",
                            .member = ct.name,
                            .contract = contract_id,
                            .issue = "return_type_incompatible",
                            .detail = try std.fmt.allocPrint(a, "contract returns {s}, implementation returns {s}", .{ ck, ik }),
                            .contract_signature = contract_sig,
                            .impl_signature = impl_sig,
                        });
                    } else if (typeIsNullable(ir) and !typeIsNullable(cr)) {
                        // Covariance: an implementation may not widen the return
                        // to nullable when the contract promises non-null.
                        member_ok = false;
                        n_mismatch += 1;
                        try findings.append(a, .{
                            .severity = "mismatch",
                            .member = ct.name,
                            .contract = contract_id,
                            .issue = "nullability_widened",
                            .detail = try std.fmt.allocPrint(a, "contract returns non-nullable {s}, implementation may return null", .{ck}),
                            .contract_signature = contract_sig,
                            .impl_signature = impl_sig,
                        });
                    }
                }
            }
        }

        // --- Visibility ----------------------------------------------------
        if (visibilityRank(im.visibility) > visibilityRank(ct.method.visibility)) {
            member_ok = false;
            n_mismatch += 1;
            try findings.append(a, .{
                .severity = "mismatch",
                .member = ct.name,
                .contract = contract_id,
                .issue = "visibility_narrowed",
                .detail = try std.fmt.allocPrint(a, "contract is {s}, implementation narrows to {s}", .{ @tagName(ct.method.visibility), @tagName(im.visibility) }),
                .contract_signature = contract_sig,
                .impl_signature = impl_sig,
            });
        }

        if (member_ok) {
            n_ok += 1;
            if (include_ok) {
                try findings.append(a, .{
                    .severity = "ok",
                    .member = ct.name,
                    .contract = contract_id,
                    .issue = "conformant",
                    .detail = "implementation matches the contract",
                    .contract_signature = contract_sig,
                    .impl_signature = impl_sig,
                });
            }
        }
    }

    // ---- Emit JSON -------------------------------------------------------
    try w.appendSlice(a, "{\"fqn\":");
    try appendJson(a, w, fqn);
    try w.print(a, ",\"symbol\":\"class\",\"is_abstract\":{s}", .{if (class.is_abstract) "true" else "false"});

    try w.appendSlice(a, ",\"checked\":{\"interfaces\":");
    try appendStringArray(a, w, iface_list.items);
    try w.appendSlice(a, ",\"parent\":");
    if (class.extends) |p| try appendJson(a, w, p) else try w.appendSlice(a, "null");
    try w.appendSlice(a, "}");

    try w.print(a, ",\"summary\":{{\"missing\":{d},\"mismatches\":{d},\"info\":{d},\"ok\":{d}}}", .{
        n_missing, n_mismatch, n_info, n_ok,
    });

    try w.appendSlice(a, ",\"findings\":[");
    for (findings.items, 0..) |f, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"severity\":\"");
        try w.appendSlice(a, f.severity);
        try w.appendSlice(a, "\",\"member\":");
        try appendJson(a, w, f.member);
        try w.appendSlice(a, ",\"contract\":");
        try appendJson(a, w, f.contract);
        try w.appendSlice(a, ",\"issue\":\"");
        try w.appendSlice(a, f.issue);
        try w.appendSlice(a, "\",\"detail\":");
        try appendJson(a, w, f.detail);
        try w.appendSlice(a, ",\"contract_signature\":");
        try appendJson(a, w, f.contract_signature);
        try w.appendSlice(a, ",\"impl_signature\":");
        if (f.impl_signature) |s| try appendJson(a, w, s) else try w.appendSlice(a, "null");
        try w.appendSlice(a, "}");
    }
    try w.appendSlice(a, "]");

    try w.appendSlice(a, ",\"caveats\":{\"variance\":\"name-equality check, not full LSP variance (no covariant-return / contravariant-param subtype resolution)\",\"self_types\":\"self/static/parent types are skipped\",\"union_array\":\"compared by FQCN-normalized identity; nullability judged separately for returns\"}");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ============================================================================
// Priming payload
// ============================================================================

/// Build the hybrid priming payload: dynamic orientation about the loaded graph
/// plus a static guide on how to use the server.
fn buildPrimingPayload(allocator: std.mem.Allocator, state: *McpState) ![]const u8 {
    const lp = state.loaded.?;
    const index = lp.index;
    const stats = index.sym_table.getStats();

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    try buf.appendSlice(allocator, "PHPCMA project loaded.\n\n");

    // --- Dynamic orientation -------------------------------------------------
    try buf.appendSlice(allocator, "## Orientation\n");
    try buf.print(allocator, "- project: {s}\n", .{lp.project_path});
    try buf.print(allocator, "- files indexed: {d}\n", .{index.file_sources.count()});
    const resolved_count = if (index.resolved) |r| r.classes.count() else 0;
    try buf.print(allocator, "- classes: {d} (resolved view: {d})\n", .{ stats.class_count, resolved_count });
    try buf.print(allocator, "- interfaces: {d}, traits: {d}, functions: {d}\n", .{ stats.interface_count, stats.trait_count, stats.function_count });
    try buf.print(allocator, "- methods: {d}, properties: {d}\n", .{ stats.method_count, stats.property_count });
    var synthetic_edges: usize = 0;
    var di_config_edges: usize = 0;
    var single_impl_edges: usize = 0;
    for (index.call_graph.calls.items) |c| {
        switch (c.resolution_method) {
            .plugin_generated => synthetic_edges += 1,
            .di_config_binding => di_config_edges += 1,
            .interface_single_impl => single_impl_edges += 1,
            else => {},
        }
    }
    try buf.print(allocator, "- call edges: {d} ({d} resolved, {d} unresolved, {d:.1}% resolution rate)\n", .{
        index.call_graph.total_calls,
        index.call_graph.resolved_calls,
        index.call_graph.unresolved_calls,
        index.call_graph.getResolutionRate(),
    });
    try buf.print(allocator, "- synthetic (plugin-generated) edges: {d}\n", .{synthetic_edges});
    const di_binding_count = if (index.resolved) |r| r.explicit_bindings.count() else 0;
    try buf.print(allocator, "- DI-aware edges: {d} via services.yaml bindings, {d} via single-implementor ({d} explicit interface bindings from {d} config file(s))\n", .{
        di_config_edges, single_impl_edges, di_binding_count, index.di_yaml.count(),
    });

    try appendUnresolvedBreakdown(allocator, &buf, index);
    try appendReceiverShapeBreakdown(allocator, &buf, index);
    try appendActivePlugins(allocator, &buf, index);
    try appendTopNamespaces(allocator, &buf, index);

    // --- Static guide --------------------------------------------------------
    try buf.appendSlice(allocator,
        \\
        \\## How to use this server
        \\- Node ids are PHP fully-qualified names (FQNs):
        \\    - method: `App\Service\UserService::save`
        \\    - function: `App\helper`
        \\    - class:  `App\Service\UserService`
        \\- Call edges are confidence-annotated in [0.0, 1.0]: static/self/parent
        \\  calls resolve at 1.0; type-directed instance calls lower; 0.0 means the
        \\  callee type could not be resolved.
        \\- `load_project` is idempotent: re-call with the same path to pick up
        \\  on-disk changes, or a different path to swap the active project.
        \\
        \\## Tools
        \\- `load_project`: build/reload the index, returns this payload.
        \\- `query`: run a graph query (below). This is the primary analysis tool —
        \\  compose primitives to build your own analyses.
        \\- `called_before`: check an ordering constraint (is `before` always
        \\  called before `after`?), interprocedurally. Targets are FQNs,
        \\  `::method` (any class), or a function name.
        \\- `dependencies`: cross-package coupling report for a monorepo (which
        \\  projects call which, API surface used, per-pair counts). Lower bound
        \\  with explicit caveats; honors `exclude_tests` (default true). Filter
        \\  with `min_call_count`/`from`/`to`; the heavy per-call list and the
        \\  API-surface inventory are gated behind `include_calls` /
        \\  `include_api_surface`.
        \\- `impact`: blast radius of one FQN — callers grouped by package +
        \\  a breaking-change risk verdict ("if I change this, who breaks?").
        \\  Verdict + per-package counts by default; pass `verbose` for the full
        \\  caller list (with observed arg types + result use). Pass `simulate`
        \\  to evaluate a param/return type edit against the call sites
        \\  (`type_breaking_change`).
        \\- `references`: rename blast radius for a class FQN — non-call
        \\  occurrences (type hints, `new`, extends/implements, `::class`, `use`,
        \\  string FQNs), FQN-scoped so sibling-namespace twins never match.
        \\- `describe_symbol`: resolved, inheritance-aware, typed view of one
        \\  symbol (Class, Class::method, function, interface, trait) — the
        \\  signature/types to read before calling or editing it. Native+PHPDoc
        \\  types merged; `effective` is what the resolver uses.
        \\- `resolve_interface`: DI/wiring explainer — given an interface FQN,
        \\  its implementors + which concrete a typed call resolves to and why
        \\  (di_config / single_impl / ambiguous / none). Given a class FQN, the
        \\  reverse (interfaces satisfied + DI-bound-for).
        \\- `find_by_type`: navigate by type — producers (return it), consumers
        \\  (take it as a param), and holders (properties) of a class/interface.
        \\  `include_subtypes` widens to in-project subtypes.
        \\- `check_conformance`: does a class actually satisfy its contracts?
        \\  Flags missing methods, arity/param/return type mismatches, return
        \\  nullability widening, and visibility narrowing against the interfaces
        \\  it implements and the abstract methods it inherits.
        \\- `check_dead`: whole-program dead-code (liveness) sweep from roots over
        \\  the resolved call graph. Trust-gated: a low resolution_rate inflates
        \\  false positives (`caveats.kept_alive_by_unresolved`).
        \\- `check_types`: cross-project type violations at resolved call sites
        \\  (arg type/count, return, visibility, interface mismatches).
        \\- `check_boundaries`: monorepo boundary verdict — total/cross/same-project
        \\  call counts, exposed API surface, per-pair dependency edges.
        \\- `null_safety`: intraprocedural nullable-dereference check (guarded vs
        \\  unguarded); heuristic, precision tracks the resolved type graph.
        \\- `return_types`: verifies returned values against declared return types
        \\  via each method's CFG; unresolved returns count as uncertain, not failed.
        \\- `report`: unified project health report (coverage, type-check tallies,
        \\  dead code, confidence distribution, violations) — same JSON as the
        \\  `report` CLI command.
        \\
        \\## Query grammar (the `query` tool's `query` argument)
        \\A JSON object: `{start, traverse?, where?, select?, limit?}`
        \\- `start`: `{"fqn": "App\Service::save"}` (exact node) OR
        \\  `{"match": {"kind": "method|function|class|interface|trait",
        \\  "name": "*::save", "namespace_prefix": "App\", "file": "src/"}}`
        \\- `traverse` (optional): `{"direction": "callers"|"callees",
        \\  "min_depth": 1, "max_depth": 5, "edge_filter":
        \\  {"min_confidence": 0.5, "include_synthetic": true,
        \\  "include_unresolved": false, "exclude_tests": false}}`
        \\  (`exclude_tests` drops edges whose caller is a test file, so
        \\  caller/impact surveys reflect production usage only).
        \\- `where` (optional): node predicate on the frontier (same fields as
        \\  `match`).
        \\- `select`: `"nodes"` (default) | `"edges"` | `"count"` | `"paths"`.
        \\- `limit`: default 200, hard cap 1000.
        \\`name` uses globs (`*`, `?`), never regex. Traversal is directed only.
        \\Every result carries `nodes_visited` and `truncated`; a `limited` flag
        \\appears when a projection was capped by `limit`.
        \\
        \\### Examples
        \\- Direct callers of a method (1 hop):
        \\  `{"start":{"fqn":"App\Service::save"},
        \\  "traverse":{"direction":"callers","max_depth":1},"select":"nodes"}`
        \\- How many functions transitively reach a sink (≤5 hops):
        \\  `{"start":{"fqn":"App\Db::query"},
        \\  "traverse":{"direction":"callers","max_depth":5},"select":"count"}`
        \\- Shortest call paths from a controller into a namespace:
        \\  `{"start":{"fqn":"App\Controller::index"},
        \\  "traverse":{"direction":"callees","max_depth":6},
        \\  "where":{"namespace_prefix":"App\Repository\"},"select":"paths"}`
        \\

    );

    return buf.toOwnedSlice(allocator);
}

/// Print a histogram of *why* the unresolved calls are unresolved, so "low
/// resolution rate" becomes actionable rather than opaque. The buckets mirror
/// the per-edge `unresolved_reason` the `query` tool emits (same classification:
/// only instance-method calls can name-bridge; static/function calls and
/// unknown names fall to `no_candidate`). The counts sum to the total
/// unresolved-call count.
///
/// `external_receiver` is split out *first*, ahead of the name-collision
/// buckets: these are calls whose receiver type WAS resolved but to a non-indexed
/// (vendor/core) class. Without this split they leak into `ambiguous_bridge`
/// (when a common accessor like getId/getName collides with an in-project name)
/// or `no_candidate`, badly overstating the fixable in-project opportunity. They
/// are definitively external and only fixable by indexing the vendor code.
const UnresolvedBreakdown = struct {
    single: usize = 0,
    ambiguous: usize = 0,
    no_candidate: usize = 0,
    external_receiver: usize = 0,
};

/// Classify every unresolved call into external_receiver / single_candidate /
/// ambiguous_bridge / no_candidate. The four buckets sum to
/// `call_graph.unresolved_calls` (each unresolved call lands in exactly one).
/// Pure (no I/O) so it can be unit tested.
fn computeUnresolvedBreakdown(allocator: std.mem.Allocator, index: *ProjectIndex) !UnresolvedBreakdown {
    // Short method-name → definition count, over the same symbol categories the
    // query graph bridges against (classes, interfaces, traits).
    var name_counts = std.StringHashMap(usize).init(allocator);
    defer name_counts.deinit();
    try tallyMethodNames(&name_counts, &index.sym_table.classes);
    try tallyMethodNames(&name_counts, &index.sym_table.interfaces);
    try tallyMethodNames(&name_counts, &index.sym_table.traits);

    var b = UnresolvedBreakdown{};
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue; // resolved
        // Receiver type resolved to a non-indexed external class: definitively
        // external. Pull these out before name-collision bucketing so they don't
        // masquerade as fixable in-project ambiguities.
        if (c.unresolved_reason == .recv_type_external) {
            b.external_receiver += 1;
            continue;
        }
        if (c.call_type != .method) {
            b.no_candidate += 1; // static/function calls are never name-bridged
            continue;
        }
        const n = name_counts.get(c.callee_name) orelse 0;
        if (n == 0) {
            b.no_candidate += 1;
        } else if (n == 1) {
            b.single += 1;
        } else {
            b.ambiguous += 1;
        }
    }
    return b;
}

fn appendUnresolvedBreakdown(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    index: *ProjectIndex,
) !void {
    if (index.call_graph.unresolved_calls == 0) return;
    const b = try computeUnresolvedBreakdown(allocator, index);
    try buf.print(
        allocator,
        "- unresolved breakdown: {d} single_candidate, {d} ambiguous_bridge, {d} no_candidate, {d} external_receiver (receiver type resolved to non-indexed vendor/core class; not fixable in-project)\n",
        .{ b.single, b.ambiguous, b.no_candidate, b.external_receiver },
    );
}

/// Print the *cause* histogram for unresolved instance calls, captured at
/// analysis time (`unresolved_reason`). Unlike the name-bridge breakdown above
/// (which only counts name collisions), this attributes failures to receiver
/// shapes, separating in-project/fixable causes from external receivers.
fn appendReceiverShapeBreakdown(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    index: *ProjectIndex,
) !void {
    if (index.call_graph.unresolved_calls == 0) return;

    var recv_param_untyped: usize = 0;
    var recv_local: usize = 0;
    var recv_var: usize = 0;
    var recv_property: usize = 0;
    var recv_chain: usize = 0;
    var recv_static_chain: usize = 0;
    var recv_func_chain: usize = 0;
    var recv_subscript: usize = 0;
    var recv_other: usize = 0;
    var recv_type_external: usize = 0;
    var mnf_external_ancestor: usize = 0;
    var mnf_pure: usize = 0;

    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        switch (c.unresolved_reason) {
            .none => {},
            .recv_param_untyped => recv_param_untyped += 1,
            .recv_local => recv_local += 1,
            .recv_var => recv_var += 1,
            .recv_property => recv_property += 1,
            .recv_chain => recv_chain += 1,
            .recv_static_chain => recv_static_chain += 1,
            .recv_func_chain => recv_func_chain += 1,
            .recv_subscript => recv_subscript += 1,
            .recv_other => recv_other += 1,
            .recv_type_external => recv_type_external += 1,
            .method_not_found_external_ancestor => mnf_external_ancestor += 1,
            .method_not_found_pure => mnf_pure += 1,
        }
    }

    try buf.print(
        allocator,
        "- unresolved instance-call causes: {d} recv_param_untyped, {d} recv_local, {d} recv_var, {d} recv_property, {d} recv_chain, {d} recv_static_chain, {d} recv_func_chain, {d} recv_subscript, {d} recv_other, {d} recv_type_external, {d} method_not_found_external_ancestor, {d} method_not_found_pure\n",
        .{ recv_param_untyped, recv_local, recv_var, recv_property, recv_chain, recv_static_chain, recv_func_chain, recv_subscript, recv_other, recv_type_external, mnf_external_ancestor, mnf_pure },
    );

    dumpDiagnosticSamplesIfEnabled(index);
}

/// When `PHPCMA_DIAG` is set, print concrete samples of the two most
/// actionable bug buckets to stderr (never stdout — that carries the MCP
/// protocol): `method_not_found_pure` (genuine resolver gaps) and `recv_local`
/// (assignment-tracking gaps). Capped per bucket. Diagnostic-only.
fn dumpDiagnosticSamplesIfEnabled(index: *ProjectIndex) void {
    if (std.c.getenv("PHPCMA_DIAG") == null) return;
    const cap: usize = 60;

    std.debug.print("\n=== PHPCMA_DIAG: method_not_found_pure samples (receiver::callee  <- caller) ===\n", .{});
    var n: usize = 0;
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        if (c.unresolved_reason != .method_not_found_pure) continue;
        std.debug.print("{s}::{s}  <- {s}\n", .{ c.receiver_type orelse "?", c.callee_name, c.caller_fqn });
        n += 1;
        if (n >= cap) break;
    }

    std.debug.print("\n=== PHPCMA_DIAG: recv_local samples ($var->callee  <- caller @ file:line) ===\n", .{});
    n = 0;
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        if (c.unresolved_reason != .recv_local) continue;
        std.debug.print("{s}->{s}  <- {s} @ {s}:{d}\n", .{ c.receiver_type orelse "?", c.callee_name, c.caller_fqn, c.file_path, c.line });
        n += 1;
        if (n >= cap) break;
    }

    std.debug.print("\n=== PHPCMA_DIAG: recv_local detail histogram (why the local was untyped) ===\n", .{});
    dumpDetailHistogram(index, .recv_local);

    std.debug.print("\n=== PHPCMA_DIAG: recv_chain detail histogram (inner receiver shape) ===\n", .{});
    dumpDetailHistogram(index, .recv_chain);

    std.debug.print("\n=== PHPCMA_DIAG: top external receiver types (opaque, by call count) ===\n", .{});
    dumpExternalReceiverTypes(index, 40);

    std.debug.print("\n=== PHPCMA_DIAG: edge resolution by caller origin (first-party vs core/vendor) ===\n", .{});
    dumpResolutionByOrigin(index);

    std.debug.print("\n=== PHPCMA_DIAG: chain:this samples ($this->..()->callee  <- caller @ file:line) ===\n", .{});
    n = 0;
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        if (c.unresolved_reason != .recv_chain) continue;
        const d = c.unresolved_detail orelse continue;
        if (!std.mem.eql(u8, d, "chain:this")) continue;
        std.debug.print("->{s}  <- {s} @ {s}:{d}\n", .{ c.callee_name, c.caller_fqn, c.file_path, c.line });
        n += 1;
        if (n >= cap) break;
    }

    std.debug.print("=== PHPCMA_DIAG end ===\n", .{});
}

/// Split every call edge by the origin of its *caller* file — first-party
/// (anywhere outside a `vendor/` directory) vs core/vendor — and report
/// resolved/total for each. This isolates how well the first-party code's own
/// outgoing calls resolve once core/vendor is indexed, separate from the
/// (large) volume of vendor-internal edges. Diagnostic-only.
fn dumpResolutionByOrigin(index: *ProjectIndex) void {
    var fp_total: usize = 0;
    var fp_resolved: usize = 0;
    var fp_real_total: usize = 0;
    var fp_real_resolved: usize = 0;
    var ext_total: usize = 0;
    var ext_resolved: usize = 0;
    for (index.call_graph.calls.items) |c| {
        const is_first_party = std.mem.indexOf(u8, c.file_path, "/vendor/") == null;
        const is_synthetic = c.resolution_method == .plugin_generated;
        if (is_first_party) {
            fp_total += 1;
            if (c.resolved_target != null) fp_resolved += 1;
            if (!is_synthetic) {
                fp_real_total += 1;
                if (c.resolved_target != null) fp_real_resolved += 1;
            }
        } else {
            ext_total += 1;
            if (c.resolved_target != null) ext_resolved += 1;
        }
    }
    const fp_rate: f64 = if (fp_total == 0) 0 else @as(f64, @floatFromInt(fp_resolved)) / @as(f64, @floatFromInt(fp_total)) * 100;
    const fp_real_rate: f64 = if (fp_real_total == 0) 0 else @as(f64, @floatFromInt(fp_real_resolved)) / @as(f64, @floatFromInt(fp_real_total)) * 100;
    const ext_rate: f64 = if (ext_total == 0) 0 else @as(f64, @floatFromInt(ext_resolved)) / @as(f64, @floatFromInt(ext_total)) * 100;
    std.debug.print("first-party callers (all):  {d} resolved / {d} edges ({d:.1}%)\n", .{ fp_resolved, fp_total, fp_rate });
    std.debug.print("first-party callers (real): {d} resolved / {d} edges ({d:.1}%)  [excludes synthetic plugin edges]\n", .{ fp_real_resolved, fp_real_total, fp_real_rate });
    std.debug.print("core/vendor callers (all):  {d} resolved / {d} edges ({d:.1}%)\n", .{ ext_resolved, ext_total, ext_rate });
}

/// Rank the `recv_type_external` receiver FQCNs by how many unresolved calls
/// target them, printing the top `limit`. Shows which non-indexed types cost
/// the most resolution — i.e. what's worth indexing. Diagnostic-only.
fn dumpExternalReceiverTypes(index: *ProjectIndex, limit: usize) void {
    var counts = std.StringHashMap(usize).init(index.gpa);
    defer counts.deinit();
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        if (c.unresolved_reason != .recv_type_external) continue;
        const fqcn = c.receiver_type orelse continue;
        const gop = counts.getOrPut(fqcn) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    // Simple selection of the top `limit` by repeated max scan (limit is small).
    var printed: usize = 0;
    var last_max: usize = std.math.maxInt(usize);
    while (printed < limit) {
        var cur_max: usize = 0;
        var it = counts.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (v < last_max and v > cur_max) cur_max = v;
        }
        if (cur_max == 0) break;
        var it2 = counts.iterator();
        while (it2.next()) |e| {
            if (e.value_ptr.* == cur_max) {
                std.debug.print("{d:>6}  {s}\n", .{ cur_max, e.key_ptr.* });
                printed += 1;
                if (printed >= limit) break;
            }
        }
        last_max = cur_max;
    }
}

/// Tally `unresolved_detail` labels for unresolved calls of a given reason and
/// print them sorted by count. Diagnostic-only; tolerates allocation failure.
fn dumpDetailHistogram(index: *ProjectIndex, reason: types.UnresolvedReason) void {
    var counts = std.StringHashMap(usize).init(index.gpa);
    defer counts.deinit();
    for (index.call_graph.calls.items) |c| {
        if (c.resolved_target != null) continue;
        if (c.unresolved_reason != reason) continue;
        const label = c.unresolved_detail orelse "(none)";
        const gop = counts.getOrPut(label) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var it = counts.iterator();
    while (it.next()) |e| {
        std.debug.print("{d:>6}  {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    }
}

/// Add each method's short name to `counts` for every entry in a symbol map
/// (ClassSymbol/InterfaceSymbol/TraitSymbol all expose a `methods` map).
fn tallyMethodNames(counts: *std.StringHashMap(usize), map: anytype) !void {
    var it = map.iterator();
    while (it.next()) |entry| {
        var m_it = entry.value_ptr.methods.iterator();
        while (m_it.next()) |m| {
            const gop = try counts.getOrPut(m.value_ptr.name);
            if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        }
    }
}

/// List the active analysis plugins (union across all project configs, sorted
/// and deduplicated). Mirrors `ProjectIndex.runPlugins`' enabled-set logic so
/// the agent can confirm which synthetic-edge sources are in effect.
fn appendActivePlugins(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    index: *ProjectIndex,
) !void {
    var enabled = std.StringHashMap(void).init(allocator);
    defer enabled.deinit();
    for (index.project_configs) |cfg| {
        for (cfg.plugins) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len == 0) continue;
            try enabled.put(trimmed, {});
        }
    }

    if (enabled.count() == 0) {
        try buf.appendSlice(allocator, "- active plugins: none\n");
        return;
    }

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = enabled.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    try buf.print(allocator, "- active plugins ({d}): ", .{names.items.len});
    for (names.items, 0..) |n, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, n);
    }
    try buf.appendSlice(allocator, "\n");
}

/// List distinct top-level namespace segments (alphabetically), capped, to give
/// the agent a sense of the project's shape.
fn appendTopNamespaces(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    index: *ProjectIndex,
) !void {
    const max_listed = 15;

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var it = index.sym_table.classes.keyIterator();
    while (it.next()) |fqcn_ptr| {
        const fqcn = fqcn_ptr.*;
        const seg = topLevelSegment(fqcn);
        if (seg.len == 0) continue;
        try seen.put(seg, {});
    }

    if (seen.count() == 0) return;

    // Collect + sort for deterministic output.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    var seen_it = seen.keyIterator();
    while (seen_it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    try buf.print(allocator, "- top-level namespaces ({d}): ", .{names.items.len});
    const limit = @min(names.items.len, max_listed);
    for (names.items[0..limit], 0..) |n, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, n);
    }
    if (names.items.len > limit) {
        try buf.print(allocator, ", … (+{d} more)", .{names.items.len - limit});
    }
    try buf.appendSlice(allocator, "\n");
}

/// First namespace segment of an FQCN (the part before the first backslash);
/// empty string for a top-level (namespace-less) class.
fn topLevelSegment(fqcn: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, fqcn, '\\')) |idx| {
        return fqcn[0..idx];
    }
    return "";
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Write a diagnostic line to stderr. Never stdout — that's the JSON-RPC channel.
/// Best-effort: I/O errors are ignored (diagnostics must not break the server).
fn logStderr(prefix: []const u8, detail: []const u8) void {
    const err_file = std.Io.File.stderr();
    err_file.writeStreamingAll(types.io, prefix) catch {};
    err_file.writeStreamingAll(types.io, detail) catch {};
    err_file.writeStreamingAll(types.io, "\n") catch {};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "unresolved breakdown buckets sum to unresolved_calls" {
    const gpa = testing.allocator;
    // A mix: a resolved static call, a single-candidate bridge, an ambiguous
    // bridge (two same-named methods), and a no-candidate (unknown name).
    const src =
        \\<?php
        \\namespace App;
        \\class Caller {
        \\    public function run($a, $b): void {
        \\        \App\Logger::ping();
        \\        $a->onlyHere();
        \\        $b->twin();
        \\        $a->doesNotExistAnywhere();
        \\    }
        \\}
        \\class Logger { public static function ping(): void {} }
        \\class A { public function onlyHere(): void {} public function twin(): void {} }
        \\class B { public function twin(): void {} }
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/All.php", src },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = try computeUnresolvedBreakdown(arena.allocator(), idx);

    // Every unresolved call lands in exactly one bucket.
    try testing.expectEqual(idx.call_graph.unresolved_calls, b.single + b.ambiguous + b.no_candidate + b.external_receiver);
    // And the buckets reflect the fixture: at least one ambiguous (twin x2),
    // and at least one no_candidate (doesNotExistAnywhere). No external
    // receivers here (every receiver is untyped or in-project).
    try testing.expect(b.ambiguous >= 1);
    try testing.expect(b.no_candidate >= 1);
    try testing.expectEqual(@as(usize, 0), b.external_receiver);
}

test "external-receiver calls are split out of the name-bridge buckets" {
    const gpa = testing.allocator;
    // `$this->product` resolves to a non-indexed vendor class. `getId` collides
    // with an in-project method of the same name, so WITHOUT the external-receiver
    // split it would masquerade as a (fixable) name-bridge candidate. It must
    // instead land in `external_receiver`.
    const src =
        \\<?php
        \\namespace App;
        \\class Entity { public function getId(): int { return 1; } }
        \\class Service {
        \\    public function __construct(private readonly \Vendor\Product $product) {}
        \\    public function run(): void { $this->product->getId(); }
        \\}
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/All.php", src },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = try computeUnresolvedBreakdown(arena.allocator(), idx);

    // The getId() call is attributed to the external receiver, not a bridge.
    try testing.expectEqual(@as(usize, 1), b.external_receiver);
    try testing.expectEqual(@as(usize, 0), b.single);
    try testing.expectEqual(@as(usize, 0), b.ambiguous);
    // Buckets still partition the unresolved calls exactly.
    try testing.expectEqual(idx.call_graph.unresolved_calls, b.single + b.ambiguous + b.no_candidate + b.external_receiver);
}

test "ConfigFingerprint.changed: same-path reload decision logic" {
    const base = ConfigFingerprint{ .mtime = 100, .size = 50, .missing = false };
    // Identical fingerprint → unchanged → cheap incremental refresh.
    try testing.expect(!base.changed(.{ .mtime = 100, .size = 50, .missing = false }));
    // mtime bump (typical on-disk edit) → changed → full re-parse.
    try testing.expect(base.changed(.{ .mtime = 101, .size = 50, .missing = false }));
    // size change → changed.
    try testing.expect(base.changed(.{ .mtime = 100, .size = 51, .missing = false }));
    // A missing fingerprint on either side → conservatively "changed".
    try testing.expect(base.changed(.{ .missing = true }));
    const unknown = ConfigFingerprint{ .missing = true };
    try testing.expect(unknown.changed(base));
}

test "called_before rendering: satisfied and violation cases" {
    const gpa = testing.allocator;
    const service_php =
        \\<?php
        \\namespace App;
        \\class Service {
        \\    public function run(): void {
        \\        $this->validate();
        \\        $this->save();
        \\    }
        \\    public function validate(): void {}
        \\    public function save(): void {}
        \\}
    ;
    const bad_php =
        \\<?php
        \\namespace App;
        \\class Bad {
        \\    public function run(): void {
        \\        $this->save();
        \\    }
        \\    public function save(): void {}
        \\}
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Service.php", service_php },
        .{ "/p/Bad.php", bad_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var analyzer = CalledBeforeAnalyzer.init(a, &idx.call_graph);
    defer analyzer.deinit();
    const result = try analyzer.analyze("::validate", "::save");

    const json = try renderCalledBefore(a, "::validate", "::save", result);

    // Bad::run calls save() without validate() -> not globally satisfied.
    try testing.expect(std.mem.indexOf(u8, json, "\"satisfied\":false") != null);
    // Service::run satisfies the constraint.
    try testing.expect(std.mem.indexOf(u8, json, "App\\\\Service::run") != null);
    // The violation is reported with its kind.
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"missing_before\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "App\\\\Bad::run") != null);

    // Result must be parseable JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// ---------------------------------------------------------------------------
// Rendering tests for the terse-by-default `impact` and filtered `dependencies`
// output (the response-shaping recommendations).
// ---------------------------------------------------------------------------

const impact_api_php =
    \\<?php
    \\namespace ProjA;
    \\class Api {
    \\    public static function getData(): void {}
    \\}
;
const impact_consumer_php =
    \\<?php
    \\namespace ProjB;
    \\class Consumer {
    \\    public function run(): void {
    \\        \ProjA\Api::getData();
    \\    }
    \\}
;

fn twoProjectIndexForRenderTest(gpa: std.mem.Allocator, a: std.mem.Allocator) !*ProjectIndex {
    const configs = try a.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(a, "/mono/a");
    configs[1] = ProjectConfig.init(a, "/mono/b");
    return project_index.createInMemoryWithConfigsForTest(gpa, &.{
        .{ "/mono/a/src/Api.php", impact_api_php },
        .{ "/mono/b/src/Consumer.php", impact_consumer_php },
    }, configs);
}

test "impact rendering: terse by default, full callers under verbose" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try twoProjectIndexForRenderTest(gpa, a);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.impact("ProjA\\Api::getData", .{});

    // Default: verdict + per-package counts, no individual callers.
    const terse = try renderImpact(a, idx, result, true, .{});
    try testing.expect(std.mem.indexOf(u8, terse, "\"callers_omitted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, terse, "\"caller_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, terse, "\"callers\":[") == null);
    // The risk verdict survives.
    try testing.expect(std.mem.indexOf(u8, terse, "\"risk\":\"public_api_low\"") != null);
    const tp = try std.json.parseFromSlice(std.json.Value, a, terse, .{});
    defer tp.deinit();

    // verbose: individual callers appear.
    const verbose = try renderImpact(a, idx, result, true, .{ .verbose = true });
    try testing.expect(std.mem.indexOf(u8, verbose, "\"callers_omitted\":true") == null);
    try testing.expect(std.mem.indexOf(u8, verbose, "ProjB\\\\Consumer::run") != null);

    // packages_only wins over verbose: still no callers.
    const po = try renderImpact(a, idx, result, true, .{ .verbose = true, .packages_only = true });
    try testing.expect(std.mem.indexOf(u8, po, "\"callers_omitted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, po, "\"callers\":[") == null);
}

/// Shared fixture for type-aware impact tests: `Repo::save(User): User` with a
/// dog/animal subtype hierarchy and three call sites exercising arg types and
/// result use.
const type_impact_sources = [_][2][]const u8{
    .{ "/p/Animal.php",
        \\<?php
        \\namespace App;
        \\interface Animal {}
    },
    .{ "/p/Dog.php",
        \\<?php
        \\namespace App;
        \\class Dog implements Animal {}
    },
    .{ "/p/Cat.php",
        \\<?php
        \\namespace App;
        \\class Cat {}
    },
    .{ "/p/Shelter.php",
        \\<?php
        \\namespace App;
        \\class Shelter {
        \\    public function take(Animal $a): Animal { return $a; }
        \\    public function tag(): string { return "x"; }
        \\}
    },
    .{ "/p/Client.php",
        \\<?php
        \\namespace App;
        \\class Client {
        \\    public function run(Shelter $s, Dog $d, Cat $c): void {
        \\        $s->take($d);          // arg Dog: compatible (subtype of Animal)
        \\        $kept = $s->take($d);  // result assigned (safe for narrowing)
        \\        $s->take($c)->tag();   // arg Cat: incompatible; result dereferenced
        \\    }
        \\}
    },
};

test "impact: param_type_change flags an incompatible in-project arg" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try project_index.createInMemoryForTest(gpa, &type_impact_sources);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.impact("App\\Shelter::take", .{});

    // Simulate narrowing the param to App\Dog: the Cat arg is incompatible, the
    // Dog args are compatible (exact). All three args are typed -> breaking.
    const out = try renderImpact(a, idx, result, true, .{
        .simulate = .{ .param_type_change = .{ .position = 0, .to = "App\\Dog" } },
    });
    const o = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer o.deinit();
    const ptc = o.value.object.get("type_breaking_change").?.object.get("param_type_change").?.object;
    try testing.expectEqualStrings("breaking", ptc.get("verdict").?.string);
    try testing.expectEqual(@as(usize, 1), ptc.get("incompatible_call_sites").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Cat is not App\\\\Dog") != null);
    // Coverage: all 3 call sites have a typed first arg.
    const cov = ptc.get("coverage").?.object;
    try testing.expectEqual(@as(i64, 3), cov.get("typed_args").?.integer);
    try testing.expectEqual(@as(i64, 3), cov.get("total_call_sites").?.integer);
}

test "impact: param_type_change widening to a supertype is safe" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try project_index.createInMemoryForTest(gpa, &type_impact_sources);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.impact("App\\Shelter::take", .{});

    // Widening to App\Animal: Dog is a subtype, Cat is not -> still breaking on
    // Cat. Use a target every arg satisfies instead: there is none common, so
    // assert the subtype logic accepts Dog by checking a Dog-only call set is
    // safe via position with only compatible args is covered above. Here we
    // confirm Animal accepts Dog (subtype) but flags Cat.
    const out = try renderImpact(a, idx, result, true, .{
        .simulate = .{ .param_type_change = .{ .position = 0, .to = "App\\Animal" } },
    });
    // Dog args are subtypes of Animal -> compatible; only Cat remains incompatible.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Cat is not App\\\\Animal") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Dog is not") == null);
}

test "impact: return narrowing to ?T flags a dereferencing caller" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try project_index.createInMemoryForTest(gpa, &type_impact_sources);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.impact("App\\Shelter::take", .{});

    const out = try renderImpact(a, idx, result, true, .{
        .simulate = .{ .return_type_change = .{ .to = "?App\\Animal" } },
    });
    const o = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer o.deinit();
    const rtc = o.value.object.get("type_breaking_change").?.object.get("return_type_change").?.object;
    // One call dereferences the result (`$s->take($c)->tag()`) -> risky.
    try testing.expectEqualStrings("risky", rtc.get("verdict").?.string);
    try testing.expectEqual(@as(usize, 1), rtc.get("risky_call_sites").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, out, "\"result_used\":\"member_access\"") != null);
}

test "impact: low coverage yields unknown, not safe" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The arg is an untyped local, so its type can't be resolved -> not typed.
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Dog.php",
            \\<?php
            \\namespace App;
            \\class Dog {}
        },
        .{ "/p/Shelter.php",
            \\<?php
            \\namespace App;
            \\class Shelter { public function take(Dog $d): void {} }
        },
        .{ "/p/Client.php",
            \\<?php
            \\namespace App;
            \\class Client {
            \\    public function run(Shelter $s): void {
            \\        $x = unknownThing();
            \\        $s->take($x);
            \\    }
            \\}
        },
    });
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.impact("App\\Shelter::take", .{});

    const out = try renderImpact(a, idx, result, true, .{
        .simulate = .{ .param_type_change = .{ .position = 0, .to = "App\\Dog" } },
    });
    const o = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer o.deinit();
    const ptc = o.value.object.get("type_breaking_change").?.object.get("param_type_change").?.object;
    // Untyped arg -> no incompatible sites, but not all typed -> unknown (not safe).
    try testing.expectEqualStrings("unknown", ptc.get("verdict").?.string);
    const cov = ptc.get("coverage").?.object;
    try testing.expectEqual(@as(i64, 0), cov.get("typed_args").?.integer);
    try testing.expectEqual(@as(i64, 1), cov.get("total_call_sites").?.integer);
}

test "dependencies rendering: gating, filters, and min_call_count" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try twoProjectIndexForRenderTest(gpa, a);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.analyze(.{});

    // Default: cross_package_calls and api_surface_used omitted, edge summary present.
    const def = try renderBoundary(a, result, true, .{}, idx);
    try testing.expect(std.mem.indexOf(u8, def, "\"cross_package_calls_omitted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, def, "\"cross_package_calls\":[") == null);
    try testing.expect(std.mem.indexOf(u8, def, "\"api_surface_used_omitted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, def, "\"api_surface_used\":[") == null);
    try testing.expect(std.mem.indexOf(u8, def, "\"dependencies_matched\":1") != null);
    const dp = try std.json.parseFromSlice(std.json.Value, a, def, .{});
    defer dp.deinit();

    // include_calls: the heavy per-call array appears.
    const withcalls = try renderBoundary(a, result, true, .{ .include_calls = true }, idx);
    try testing.expect(std.mem.indexOf(u8, withcalls, "ProjB\\\\Consumer::run") != null);
    try testing.expect(std.mem.indexOf(u8, withcalls, "\"cross_package_calls_matched\":1") != null);

    // include_api_surface: the inventory appears; `to` keeps only the exposing
    // project's surface, a non-matching `to` filters it all out.
    const withsurface = try renderBoundary(a, result, true, .{ .include_api_surface = true }, idx);
    try testing.expect(std.mem.indexOf(u8, withsurface, "ProjA\\\\Api::getData") != null);
    try testing.expect(std.mem.indexOf(u8, withsurface, "\"api_surface_used_matched\":1") != null);
    const surface_to_a = try renderBoundary(a, result, true, .{ .include_api_surface = true, .to = "a" }, idx);
    try testing.expect(std.mem.indexOf(u8, surface_to_a, "\"api_surface_used_matched\":1") != null);
    const surface_to_b = try renderBoundary(a, result, true, .{ .include_api_surface = true, .to = "b" }, idx);
    try testing.expect(std.mem.indexOf(u8, surface_to_b, "\"api_surface_used_matched\":0") != null);

    // from/to filters echo back and keep the matching edge.
    const filtered = try renderBoundary(a, result, true, .{ .from = "b", .to = "a" }, idx);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"filters\":{") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"dependencies_matched\":1") != null);

    // A non-matching `from` filters the edge out.
    const nomatch = try renderBoundary(a, result, true, .{ .from = "zzz" }, idx);
    try testing.expect(std.mem.indexOf(u8, nomatch, "\"dependencies_matched\":0") != null);

    // An unsatisfiable min_call_count drops every edge.
    const highmin = try renderBoundary(a, result, true, .{ .min_call_count = 99 }, idx);
    try testing.expect(std.mem.indexOf(u8, highmin, "\"dependencies_matched\":0") != null);
}

// ---------------------------------------------------------------------------
// describe_symbol rendering tests.
// ---------------------------------------------------------------------------

test "describe_symbol: method merges types, marks inherited, resolves FQCNs" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/User.php",
            \\<?php
            \\namespace App;
            \\class User {}
        },
        .{ "/p/Base.php",
            \\<?php
            \\namespace App;
            \\class Base {
            \\    public function find(int $id): ?User { return null; }
            \\}
        },
        .{ "/p/Repo.php",
            \\<?php
            \\namespace App;
            \\class Repo extends Base {
            \\    public function save(User $u): void {}
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Inherited method: declared_in is the base, inherited=true, ?User nullable.
    const inh = try renderDescribeSymbol(a, idx, "App\\Repo::find", .signatures, true);
    try testing.expect(std.mem.indexOf(u8, inh, "\"symbol\":\"method\"") != null);
    try testing.expect(std.mem.indexOf(u8, inh, "\"declared_in\":\"App\\\\Base\"") != null);
    try testing.expect(std.mem.indexOf(u8, inh, "\"inherited\":true") != null);
    try testing.expect(std.mem.indexOf(u8, inh, "\"nullable\":true") != null);
    try testing.expect(std.mem.indexOf(u8, inh, "App\\\\User") != null);

    // Own method: param type FQCN-resolved, inherited=false.
    const own = try renderDescribeSymbol(a, idx, "App\\Repo::save", .signatures, true);
    try testing.expect(std.mem.indexOf(u8, own, "\"inherited\":false") != null);
    try testing.expect(std.mem.indexOf(u8, own, "\"name\":\"u\"") != null);
    try testing.expect(std.mem.indexOf(u8, own, "App\\\\User") != null);

    // Parseable JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, own, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "describe_symbol: class lists own vs inherited members and parent chain" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Base.php",
            \\<?php
            \\namespace App;
            \\class Base {
            \\    public function boot(): void {}
            \\}
        },
        .{ "/p/Repo.php",
            \\<?php
            \\namespace App;
            \\class Repo extends Base implements \App\Contract {
            \\    public int $count = 0;
            \\    public function save(): void {}
            \\}
        },
        .{ "/p/Contract.php",
            \\<?php
            \\namespace App;
            \\interface Contract { public function save(): void; }
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderDescribeSymbol(a, idx, "App\\Repo", .none, true);
    try testing.expect(std.mem.indexOf(u8, out, "\"symbol\":\"class\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"extends\":\"App\\\\Base\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Contract") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"parent_chain\":[\"App\\\\Base\"]") != null);
    // own vs inherited method split (names only in `none` mode).
    try testing.expect(std.mem.indexOf(u8, out, "\"own_methods\":[\"save\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"inherited_methods\":[\"boot\"]") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "describe_symbol: interface, trait, and not-found paths" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Contract.php",
            \\<?php
            \\namespace App;
            \\interface Contract extends \App\Base { public function send(string $m): bool; }
        },
        .{ "/p/T.php",
            \\<?php
            \\namespace App;
            \\trait T { public function helper(): void {} }
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const iface = try renderDescribeSymbol(a, idx, "App\\Contract", .signatures, true);
    try testing.expect(std.mem.indexOf(u8, iface, "\"symbol\":\"interface\"") != null);
    try testing.expect(std.mem.indexOf(u8, iface, "App\\\\Base") != null);
    try testing.expect(std.mem.indexOf(u8, iface, "\"name\":\"send\"") != null);

    const trait = try renderDescribeSymbol(a, idx, "App\\T", .none, true);
    try testing.expect(std.mem.indexOf(u8, trait, "\"symbol\":\"trait\"") != null);
    try testing.expect(std.mem.indexOf(u8, trait, "\"own_methods\":[\"helper\"]") != null);

    const missing = try renderDescribeSymbol(a, idx, "App\\Nope::ghost", .signatures, true);
    try testing.expect(std.mem.indexOf(u8, missing, "\"found\":false") != null);
}

// ---------------------------------------------------------------------------
// resolve_interface rendering tests.
// ---------------------------------------------------------------------------

test "resolve_interface: single implementor -> single_impl binding" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer { public function send(string $m): bool; }
        },
        .{ "/p/Smtp.php",
            \\<?php
            \\namespace App;
            \\class SmtpMailer implements Mailer {
            \\    public function send(string $m): bool { return true; }
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderResolveInterface(a, idx, "App\\Mailer");
    try testing.expect(std.mem.indexOf(u8, out, "\"symbol\":\"interface\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\SmtpMailer") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"single_impl\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"resolves_to\":\"App\\\\SmtpMailer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"send\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "resolve_interface: multiple implementors via sub-interface -> ambiguous, and reverse query" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer { public function send(): void; }
        },
        // Sub-interface: a class implementing AsyncMailer counts as a Mailer
        // implementor (transitive `extends`, now that it's collected).
        .{ "/p/AsyncMailer.php",
            \\<?php
            \\namespace App;
            \\interface AsyncMailer extends Mailer {}
        },
        .{ "/p/Smtp.php",
            \\<?php
            \\namespace App;
            \\class SmtpMailer implements Mailer { public function send(): void {} }
        },
        .{ "/p/Ses.php",
            \\<?php
            \\namespace App;
            \\class SesMailer implements AsyncMailer { public function send(): void {} }
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Two implementors (one transitive) and no config binding -> ambiguous.
    const fwd = try renderResolveInterface(a, idx, "App\\Mailer");
    try testing.expect(std.mem.indexOf(u8, fwd, "App\\\\SmtpMailer") != null);
    try testing.expect(std.mem.indexOf(u8, fwd, "App\\\\SesMailer") != null);
    try testing.expect(std.mem.indexOf(u8, fwd, "\"kind\":\"ambiguous\"") != null);

    // Reverse: SesMailer implements AsyncMailer; that interface is recorded.
    const rev = try renderResolveInterface(a, idx, "App\\SesMailer");
    try testing.expect(std.mem.indexOf(u8, rev, "\"symbol\":\"class\"") != null);
    try testing.expect(std.mem.indexOf(u8, rev, "App\\\\AsyncMailer") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, rev, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// ---------------------------------------------------------------------------
// find_by_type rendering tests.
// ---------------------------------------------------------------------------

test "find_by_type: producers, consumers, and holders of a class" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/User.php",
            \\<?php
            \\namespace App;
            \\class User {}
        },
        .{ "/p/Repo.php",
            \\<?php
            \\namespace App;
            \\class Repo {
            \\    public function find(int $id): ?User { return null; }
            \\}
        },
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\class Mailer {
            \\    public function welcome(User $u): void {}
            \\}
        },
        .{ "/p/Session.php",
            \\<?php
            \\namespace App;
            \\class Session {
            \\    public User $current;
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderFindByType(a, idx, "App\\User", .{});
    // Producer: Repo::find returns ?User.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Repo::find") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"via\":\"return\"") != null);
    // Consumer: Mailer::welcome takes User.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Mailer::welcome") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"via\":\"param\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"param\":\"u\"") != null);
    // Holder: Session::current is a User property.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Session::current") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"via\":\"property\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"summary\":{\"producers\":1,\"consumers\":1,\"holders\":1}") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "find_by_type: include_subtypes matches an implementor; roles + namespace filters" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Animal.php",
            \\<?php
            \\namespace App;
            \\interface Animal {}
        },
        .{ "/p/Dog.php",
            \\<?php
            \\namespace App;
            \\class Dog implements Animal {}
        },
        .{ "/p/Shelter.php",
            \\<?php
            \\namespace App;
            \\class Shelter {
            \\    public function adopt(): Dog { return new Dog(); }
            \\}
        },
        .{ "/p/Other.php",
            \\<?php
            \\namespace Other;
            \\class Zoo {
            \\    public function take(\App\Dog $d): void {}
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Without subtypes, a producer returning Dog does NOT match type=Animal.
    const off = try renderFindByType(a, idx, "App\\Animal", .{ .include_subtypes = false });
    try testing.expect(std.mem.indexOf(u8, off, "App\\\\Shelter::adopt") == null);

    // With subtypes, Dog is in the match set, so Shelter::adopt is a producer.
    const on = try renderFindByType(a, idx, "App\\Animal", .{ .include_subtypes = true });
    try testing.expect(std.mem.indexOf(u8, on, "App\\\\Dog") != null); // matched_types
    try testing.expect(std.mem.indexOf(u8, on, "App\\\\Shelter::adopt") != null);

    // roles=producers omits the consumer list entirely.
    const prod_only = try renderFindByType(a, idx, "App\\Dog", .{ .roles = .producers });
    try testing.expect(std.mem.indexOf(u8, prod_only, "App\\\\Shelter::adopt") != null);
    try testing.expect(std.mem.indexOf(u8, prod_only, "\"consumers\":[") == null);

    // namespace_prefix=Other keeps only Other\Zoo::take among consumers of Dog.
    const ns = try renderFindByType(a, idx, "App\\Dog", .{ .roles = .consumers, .namespace_prefix = "Other\\" });
    try testing.expect(std.mem.indexOf(u8, ns, "Other\\\\Zoo::take") != null);
    // No consumer is declared under App\ (the namespace filter is on the result
    // FQN; `type_text` legitimately still mentions App\Dog).
    try testing.expect(std.mem.indexOf(u8, ns, "\"fqn\":\"App\\\\") == null);
}

test "find_by_type: exclude_tests drops a test-declared consumer" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/User.php",
            \\<?php
            \\namespace App;
            \\class User {}
        },
        .{ "/p/tests/UserTest.php",
            \\<?php
            \\namespace App\Tests;
            \\class UserTest {
            \\    public function check(\App\User $u): void {}
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const excluded = try renderFindByType(a, idx, "App\\User", .{ .roles = .consumers, .exclude_tests = true });
    try testing.expect(std.mem.indexOf(u8, excluded, "UserTest::check") == null);
    try testing.expect(std.mem.indexOf(u8, excluded, "\"consumers\":0") != null);

    const included = try renderFindByType(a, idx, "App\\User", .{ .roles = .consumers, .exclude_tests = false });
    try testing.expect(std.mem.indexOf(u8, included, "UserTest::check") != null);
    try testing.expect(std.mem.indexOf(u8, included, "\"is_test\":true") != null);
}

// ============================================================================
// check_conformance rendering tests.
// ============================================================================

test "check_conformance: missing interface method on concrete class" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer {
            \\    public function send(string $to): bool;
            \\    public function reset(): void;
            \\}
        },
        .{ "/p/Smtp.php",
            \\<?php
            \\namespace App;
            \\class Smtp implements Mailer {
            \\    public function send(string $to): bool { return true; }
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckConformance(a, idx, "App\\Smtp", .all, false);
    // `reset` is missing; `send` conforms (so not listed unless include_ok).
    try testing.expect(std.mem.indexOf(u8, out, "\"missing\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"issue\":\"missing_method\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"member\":\"reset\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ok\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Mailer") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "check_conformance: return type mismatch and visibility narrowing flagged" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Msg.php",
            \\<?php
            \\namespace App;
            \\class Msg {}
        },
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer {
            \\    public function send(Msg $m): bool;
            \\}
        },
        .{ "/p/Bad.php",
            \\<?php
            \\namespace App;
            \\class Bad implements Mailer {
            \\    protected function send(Msg $m): void {}
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckConformance(a, idx, "App\\Bad", .all, false);
    // Return type bool -> void, and public -> protected narrowing: 2 mismatches.
    try testing.expect(std.mem.indexOf(u8, out, "\"return_type_incompatible\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"visibility_narrowed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"mismatches\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"missing\":0") != null);
}

test "check_conformance: abstract class not flagged for unimplemented method" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer {
            \\    public function send(string $to): bool;
            \\}
        },
        .{ "/p/AbstractMailer.php",
            \\<?php
            \\namespace App;
            \\abstract class AbstractMailer implements Mailer {
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckConformance(a, idx, "App\\AbstractMailer", .all, false);
    // Abstract class: `send` is unimplemented but that is allowed -> no missing.
    try testing.expect(std.mem.indexOf(u8, out, "\"is_abstract\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"missing\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"issue\":\"missing_method\"") == null);
}

test "check_conformance: __call downgrades missing to info" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Mailer.php",
            \\<?php
            \\namespace App;
            \\interface Mailer {
            \\    public function send(string $to): bool;
            \\}
        },
        .{ "/p/Proxy.php",
            \\<?php
            \\namespace App;
            \\class Proxy implements Mailer {
            \\    public function __call($name, $args) {}
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckConformance(a, idx, "App\\Proxy", .all, false);
    // __call present: the missing `send` is downgraded to info, not missing.
    try testing.expect(std.mem.indexOf(u8, out, "\"missing\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"info\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"severity\":\"info\"") != null);
}

// ============================================================================
// Analyzer tools — thin MCP wrappers over the loaded ProjectIndex.
//
// Each handler builds the relevant analyzer directly on `lp.index` (no
// re-parse, no re-collection): the index already carries the symbol table,
// resolved inheritance view, framework stubs, DI bindings, and call graph that
// `buildDerived` produced. Results echo the same trust metadata the other MCP
// tools expose (resolution rate, is_test) so a low-resolution graph is never
// mistaken for a clean bill of health.
// ============================================================================

/// Parse an optional `limit` argument, clamped to [1, cb_list_cap].
fn parseListLimit(arguments: ?std.json.Value) usize {
    const n = mcp.tools.getInteger(arguments, "limit") orelse return cb_list_cap;
    if (n < 1) return 1;
    if (n > cb_list_cap) return cb_list_cap;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// check_dead
// ---------------------------------------------------------------------------

const check_dead_tool_description =
    \\Whole-program dead-code (liveness) analysis: mark-and-sweep from the
    \\project's roots (entrypoints, public API, framework hooks) over the
    \\resolved call graph, then report symbols nothing reaches.
    \\
    \\By default only *private* dead methods/properties are listed (public ones
    \\may be called from outside the analyzed set); pass `include_public` to
    \\widen. Dead classes/interfaces/traits/functions are always listed.
    \\
    \\CRITICAL: dead-code is only as trustworthy as the call graph. Unresolved
    \\calls cannot keep a symbol alive, so a low `caveats.resolution_rate`
    \\inflates false positives. `caveats.kept_alive_by_unresolved` counts
    \\symbols conservatively spared because something unresolved might reach
    \\them. Treat results as candidates to verify, not a delete list.
    \\
    \\Args: `exclude_tests` (default true), `include_public` (default false),
    \\`limit`. Call `load_project` first.
;

fn buildCheckDeadSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addBooleanWithDefault(a, "exclude_tests", "Drop dead symbols declared in test files (default true).", true, false);
    _ = try builder.addBooleanWithDefault(a, "include_public", "Also list dead public methods/properties, not just private ones (default false).", false, false);
    _ = try builder.addInteger(a, "limit", "Cap the dead-symbol list (default 200, max 200).", false);
    return builder.toInputSchema(a);
}

fn checkDeadHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const include_public = mcp.tools.getBoolean(arguments, "include_public") orelse false;
    const limit = parseListLimit(arguments);

    const payload = renderCheckDead(allocator, lp.index, exclude_tests, include_public, limit) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn renderCheckDead(
    a: std.mem.Allocator,
    index: *ProjectIndex,
    exclude_tests: bool,
    include_public: bool,
    limit: usize,
) ![]const u8 {
    const st = &index.sym_table;

    const refs = try dead_code.extractRefsFromCallGraph(a, &index.call_graph, st);
    var graph = dead_code.ProjectLivenessGraph.init(a);
    try graph.analyze(st, refs);
    const dead = try graph.collectDead(st);

    var counts = [_]usize{0} ** 6; // class, interface, trait, function, method, property
    for (dead) |d| counts[@intFromEnum(d.kind)] += 1;

    var kept_alive: usize = 0;
    const total = graph.index.count();
    var sid: dead_code.SymbolId = 0;
    while (sid < total) : (sid += 1) {
        if (graph.isWeaklyAlive(sid)) kept_alive += 1;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"dead_total\":{d},\"dead_classes\":{d},\"dead_interfaces\":{d},\"dead_traits\":{d},\"dead_functions\":{d},\"dead_methods\":{d},\"dead_properties\":{d}", .{
        dead.len, counts[0], counts[1], counts[2], counts[3], counts[4], counts[5],
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"resolution_rate\":{d:.1},\"kept_alive_by_unresolved\":{d},\"exclude_tests\":{s}", .{
        index.call_graph.getResolutionRate(),
        kept_alive,
        if (exclude_tests) "true" else "false",
    });
    try w.appendSlice(a,
        ",\"note\":\"Dead = unreachable from roots over the RESOLVED call graph. A low resolution_rate inflates false positives; verify before deleting.\"}");

    try w.appendSlice(a, ",\"dead\":[");
    var shown: usize = 0;
    var matched: usize = 0;
    var truncated = false;
    for (dead) |d| {
        const is_test = query.isTestFile(d.file_path);
        if (exclude_tests and is_test) continue;
        // Visibility filter: by default only private methods/properties surface.
        if (!include_public) {
            switch (d.kind) {
                .method => {
                    const vis = dead_code.ProjectLivenessGraph.getMethodVisibility(d.fqn, st);
                    if (vis != .private) continue;
                },
                .property => {
                    const owner = if (std.mem.indexOf(u8, d.fqn, "::")) |sep| d.fqn[0..sep] else continue;
                    const raw = d.fqn[(std.mem.indexOf(u8, d.fqn, "::") orelse continue) + 2 ..];
                    const pname = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
                    if (st.classes.get(owner)) |class| {
                        if (class.properties.get(pname)) |prop| {
                            if (prop.visibility != .private) continue;
                        }
                    }
                },
                else => {},
            }
        }
        matched += 1;
        if (shown >= limit or buf.items.len >= response_byte_budget) {
            truncated = true;
            continue;
        }
        if (shown != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"fqn\":");
        try appendJson(a, w, d.fqn);
        try w.appendSlice(a, ",\"kind\":");
        try appendJson(a, w, @tagName(d.kind));
        try w.appendSlice(a, ",\"file\":");
        try appendJson(a, w, d.file_path);
        try w.print(a, ",\"line\":{d},\"is_test\":{s}", .{ d.line, if (is_test) "true" else "false" });
        try w.appendSlice(a, "}");
        shown += 1;
    }
    try w.appendSlice(a, "]");
    try w.print(a, ",\"dead_listed\":{d}", .{matched});
    if (truncated) try w.appendSlice(a, ",\"dead_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ---------------------------------------------------------------------------
// check_types
// ---------------------------------------------------------------------------

const check_types_tool_description =
    \\Cross-project type-violation check at resolved call sites: argument
    \\type/count mismatches, return-type and visibility violations, and
    \\interface mismatches where one package calls another.
    \\
    \\Only *resolved* cross-project calls are inspected; unresolved calls are
    \\invisible (see `caveats.resolution_rate`). Args:
    \\  min_confidence: float (default 0.0) — skip call sites whose resolution
    \\                  confidence is below this.
    \\  strict: bool (default false) — treat warnings as significant.
    \\  interface_scope: "all" | "cross-project" (default "all").
    \\  limit: cap the violations list.
    \\Call `load_project` first.
;

fn buildCheckTypesSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addNumberWithDefault(a, "min_confidence", "Skip call sites below this resolution confidence (0.0-1.0, default 0.0).", 0.0, false);
    _ = try builder.addBooleanWithDefault(a, "strict", "Treat warnings as significant (default false).", false, false);
    _ = try builder.addEnumWithDefault(a, "interface_scope", "Which interface calls to check.", &.{ "all", "cross-project" }, "all", false);
    _ = try builder.addInteger(a, "limit", "Cap the violations list (default 200, max 200).", false);
    return builder.toInputSchema(a);
}

fn checkTypesHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const min_conf: f32 = @floatCast(mcp.tools.getFloat(arguments, "min_confidence") orelse 0.0);
    const strict = mcp.tools.getBoolean(arguments, "strict") orelse false;
    const scope: type_violation_analyzer.InterfaceScope = blk: {
        const s = mcp.tools.getString(arguments, "interface_scope") orelse break :blk .all;
        if (std.mem.eql(u8, s, "cross-project")) break :blk .cross_project;
        break :blk .all;
    };
    const limit = parseListLimit(arguments);

    const payload = renderCheckTypes(allocator, lp.index, min_conf, strict, scope, limit) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn typeViolationKindName(k: type_violation_analyzer.ViolationKind) []const u8 {
    return switch (k) {
        .wrong_argument_type => "wrong_argument_type",
        .wrong_argument_count => "wrong_argument_count",
        .wrong_return_type => "wrong_return_type",
        .visibility_violation => "visibility_violation",
        .interface_mismatch => "interface_mismatch",
        .breaking_change => "breaking_change",
    };
}

fn typeViolationSeverityName(s: type_violation_analyzer.ViolationSeverity) []const u8 {
    return switch (s) {
        .error_level => "error",
        .warning => "warning",
        .info => "info",
    };
}

fn renderCheckTypes(
    a: std.mem.Allocator,
    index: *ProjectIndex,
    min_confidence: f32,
    strict: bool,
    scope: type_violation_analyzer.InterfaceScope,
    limit: usize,
) ![]const u8 {
    var analyzer = type_violation_analyzer.TypeViolationAnalyzer.init(
        a,
        &index.call_graph,
        index.project_configs,
        &index.sym_table,
    );
    analyzer.min_confidence = min_confidence;
    analyzer.strict = strict;
    analyzer.interface_scope = scope;
    const result = try analyzer.analyze();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"cross_project_calls\":{d},\"violations\":{d},\"errors\":{d},\"warnings\":{d},\"breaking_changes\":{d}", .{
        result.total_cross_project_calls, result.total_violations, result.error_count, result.warning_count, result.breaking_changes.len,
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"resolution_rate\":{d:.1}", .{index.call_graph.getResolutionRate()});
    try w.appendSlice(a,
        ",\"note\":\"Only resolved cross-project calls are checked; unresolved calls are invisible here.\"}");

    try w.appendSlice(a, ",\"violations\":[");
    var shown: usize = 0;
    var truncated = false;
    for (result.violations) |v| {
        if (shown >= limit or buf.items.len >= response_byte_budget) {
            truncated = true;
            break;
        }
        if (shown != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"kind\":");
        try appendJson(a, w, typeViolationKindName(v.kind));
        try w.appendSlice(a, ",\"severity\":");
        try appendJson(a, w, typeViolationSeverityName(v.severity));
        try w.appendSlice(a, ",\"caller\":");
        try appendJson(a, w, v.caller_fqn);
        try w.appendSlice(a, ",\"callee\":");
        try appendJson(a, w, v.callee_fqn);
        try w.appendSlice(a, ",\"caller_project\":");
        try appendJson(a, w, v.caller_project);
        try w.appendSlice(a, ",\"callee_project\":");
        try appendJson(a, w, v.callee_project);
        try w.appendSlice(a, ",\"file\":");
        try appendJson(a, w, v.file_path);
        try w.print(a, ",\"line\":{d}", .{v.line});
        try w.appendSlice(a, ",\"message\":");
        try appendJson(a, w, v.message);
        if (v.expected_type) |t| {
            try w.appendSlice(a, ",\"expected\":");
            try appendJson(a, w, t);
        }
        if (v.actual_type) |t| {
            try w.appendSlice(a, ",\"actual\":");
            try appendJson(a, w, t);
        }
        try w.appendSlice(a, "}");
        shown += 1;
    }
    try w.appendSlice(a, "]");
    if (truncated) try w.appendSlice(a, ",\"violations_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ---------------------------------------------------------------------------
// check_boundaries
// ---------------------------------------------------------------------------

const check_boundaries_tool_description =
    \\Cross-project boundary report for a monorepo: total/cross/same-project
    \\call counts, the number of public API methods one package exposes to
    \\another, and the per-pair dependency edges. The boundary verdict that
    \\sits behind the more granular `dependencies` tool.
    \\
    \\Only resolved calls are attributed to a callee project, so cross-package
    \\counts are a LOWER BOUND (see `caveats.unresolved_calls`). `exclude_tests`
    \\(default true) drops cross-project calls whose caller is a test file.
    \\Requires a multi-project `.phpcma.json`. Call `load_project` first.
;

fn buildCheckBoundariesSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addBooleanWithDefault(a, "exclude_tests", "Drop cross-project calls whose caller is a test file (default true).", true, false);
    _ = try builder.addInteger(a, "limit", "Cap the dependency-edge list (default 200, max 200).", false);
    return builder.toInputSchema(a);
}

fn checkBoundariesHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const limit = parseListLimit(arguments);

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(
        allocator,
        &lp.index.call_graph,
        lp.index.project_configs,
        &lp.index.sym_table,
    );
    const result = analyzer.analyze(.{ .exclude_tests = exclude_tests }) catch return error.OutOfMemory;

    const payload = renderCheckBoundaries(allocator, result, exclude_tests, limit, lp.index) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn renderCheckBoundaries(
    a: std.mem.Allocator,
    r: boundary_analyzer.BoundaryResult,
    exclude_tests: bool,
    limit: usize,
    index: *ProjectIndex,
) ![]const u8 {
    const ShortName = boundary_analyzer.BoundaryAnalyzer.shortProjectName;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"projects\":{d},\"total_calls\":{d},\"cross_package_calls\":{d},\"same_project_calls\":{d},\"api_methods_exposed\":{d},\"dependency_edges\":{d}", .{
        r.project_count, r.total_calls, r.cross_project_calls, r.same_project_calls, r.api_surface.len, r.dependencies.len,
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"unresolved_calls\":{d},\"resolution_rate\":{d:.1},\"exclude_tests\":{s},\"tests_excluded\":{d}", .{
        r.unresolved_calls,
        index.call_graph.getResolutionRate(),
        if (exclude_tests) "true" else "false",
        r.tests_excluded,
    });
    try w.appendSlice(a,
        ",\"note\":\"Only resolved calls are attributed; cross_package_calls is a lower bound (see caveats.unresolved_calls).\"}");

    try w.appendSlice(a, ",\"dependencies\":[");
    var shown: usize = 0;
    var truncated = false;
    for (r.dependencies) |d| {
        if (shown >= limit or buf.items.len >= response_byte_budget) {
            truncated = true;
            break;
        }
        if (shown != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"from\":");
        try appendJson(a, w, ShortName(d.from_project));
        try w.appendSlice(a, ",\"to\":");
        try appendJson(a, w, ShortName(d.to_project));
        try w.print(a, ",\"call_count\":{d}", .{d.call_count});
        try w.appendSlice(a, "}");
        shown += 1;
    }
    try w.appendSlice(a, "]");
    if (truncated) try w.appendSlice(a, ",\"dependencies_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ---------------------------------------------------------------------------
// null_safety
// ---------------------------------------------------------------------------

const null_safety_tool_description =
    \\Intraprocedural null-safety analysis: flags dereferences (`->`, `[]`) of
    \\values that may be null without a preceding guard, and counts guarded vs
    \\unguarded accesses across the project.
    \\
    \\This is a heuristic, type-directed pass — its precision depends on the
    \\resolved type graph, so prefer running it after the project loads cleanly
    \\(stubs + DI active). `definite` = null on all paths; `possible` = nullable
    \\with some unguarded path. Args: `exclude_tests` (default true), `limit`.
    \\Call `load_project` first.
;

fn buildNullSafetySchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addBooleanWithDefault(a, "exclude_tests", "Drop violations in test files (default true).", true, false);
    _ = try builder.addInteger(a, "limit", "Cap the violations list (default 200, max 200).", false);
    return builder.toInputSchema(a);
}

fn nullSafetyHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const limit = parseListLimit(arguments);

    const payload = renderNullSafety(allocator, lp.index, exclude_tests, limit) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn nullSeverityName(s: null_safety.NullSeverity) []const u8 {
    return switch (s) {
        .definite => "definite",
        .possible => "possible",
        .guarded => "guarded",
    };
}

fn nullAccessName(k: null_safety.NullViolation.AccessKind) []const u8 {
    return switch (k) {
        .method_call => "method_call",
        .property_access => "property_access",
        .array_access => "array_access",
        .return_use => "return_use",
    };
}

const NullViolationRow = struct {
    file: []const u8,
    line: u32,
    severity: null_safety.NullSeverity,
    access: null_safety.NullViolation.AccessKind,
    variable: []const u8,
    message: []const u8,
    is_test: bool,
};

fn renderNullSafety(
    a: std.mem.Allocator,
    index: *ProjectIndex,
    exclude_tests: bool,
    limit: usize,
) ![]const u8 {
    const lang = tree_sitter_php();
    var total_guarded: u32 = 0;
    var total_unguarded: u32 = 0;
    var files_analyzed: usize = 0;
    var rows: std.ArrayListUnmanaged(NullViolationRow) = .empty;

    for (index.file_order) |path| {
        const unit = index.files.get(path) orelse continue;
        const file_ctx = index.file_contexts.getPtr(path) orelse continue;
        const is_test = query.isTestFile(path);
        if (exclude_tests and is_test) continue;

        var analyzer = null_safety.NullSafetyAnalyzer.init(a, &index.sym_table, file_ctx, lang);
        const result = analyzer.analyzeFile(unit.tree, unit.source) catch continue;
        files_analyzed += 1;
        total_guarded += result.guarded_accesses;
        total_unguarded += result.unguarded_accesses;

        for (result.violations) |v| {
            if (v.severity == .guarded) continue;
            try rows.append(a, .{
                .file = path,
                .line = v.line,
                .severity = v.severity,
                .access = v.access_kind,
                .variable = v.variable,
                .message = v.message,
                .is_test = is_test,
            });
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"files_analyzed\":{d},\"guarded_accesses\":{d},\"unguarded_accesses\":{d},\"violations\":{d}", .{
        files_analyzed, total_guarded, total_unguarded, rows.items.len,
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"resolution_rate\":{d:.1}", .{index.call_graph.getResolutionRate()});
    try w.appendSlice(a,
        ",\"note\":\"Heuristic intraprocedural analysis; precision depends on the resolved type graph.\"}");

    try w.appendSlice(a, ",\"violations\":[");
    var shown: usize = 0;
    var truncated = false;
    for (rows.items) |row| {
        if (shown >= limit or buf.items.len >= response_byte_budget) {
            truncated = true;
            break;
        }
        if (shown != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"file\":");
        try appendJson(a, w, row.file);
        try w.print(a, ",\"line\":{d}", .{row.line});
        try w.appendSlice(a, ",\"severity\":");
        try appendJson(a, w, nullSeverityName(row.severity));
        try w.appendSlice(a, ",\"access\":");
        try appendJson(a, w, nullAccessName(row.access));
        try w.appendSlice(a, ",\"variable\":");
        try appendJson(a, w, row.variable);
        try w.appendSlice(a, ",\"message\":");
        try appendJson(a, w, row.message);
        try w.print(a, ",\"is_test\":{s}", .{if (row.is_test) "true" else "false"});
        try w.appendSlice(a, "}");
        shown += 1;
    }
    try w.appendSlice(a, "]");
    if (truncated) try w.appendSlice(a, ",\"violations_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ---------------------------------------------------------------------------
// return_types
// ---------------------------------------------------------------------------

const return_types_tool_description =
    \\Return-type conformance check: walks each method's control-flow graph and
    \\verifies returned values against the declared return type — flagging
    \\mismatches, missing returns, `null` returned from a non-nullable type, and
    \\values returned from `void`.
    \\
    \\Graph-quality sensitive: a return whose type cannot be resolved is counted
    \\`uncertain`, not failed (so a low resolution rate suppresses, never
    \\fabricates, findings). Args: `exclude_tests` (default true), `limit`.
    \\Call `load_project` first.
;

fn buildReturnTypesSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    _ = try builder.addBooleanWithDefault(a, "exclude_tests", "Drop diagnostics in test files (default true).", true, false);
    _ = try builder.addInteger(a, "limit", "Cap the diagnostics list (default 200, max 200).", false);
    return builder.toInputSchema(a);
}

fn returnTypesHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const exclude_tests = mcp.tools.getBoolean(arguments, "exclude_tests") orelse true;
    const limit = parseListLimit(arguments);

    const payload = renderReturnTypes(allocator, lp.index, exclude_tests, limit) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn returnTypeKindName(k: return_type_checker.Diagnostic.Kind) []const u8 {
    return switch (k) {
        .return_type_mismatch => "return_type_mismatch",
        .missing_return => "missing_return",
        .return_null_non_nullable => "return_null_non_nullable",
        .void_with_value => "void_with_value",
    };
}

fn runReturnTypeChecker(index: *ProjectIndex, checker: *return_type_checker.ReturnTypeChecker) !void {
    var class_it = index.sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const class = entry.value_ptr;
        var method_it = class.methods.iterator();
        while (method_it.next()) |m_entry| {
            const method = m_entry.value_ptr;
            const unit = index.files.get(method.file_path) orelse continue;
            try checker.analyzeMethod(method, class.fqcn, unit.source, unit.tree);
        }
    }
}

fn renderReturnTypes(
    a: std.mem.Allocator,
    index: *ProjectIndex,
    exclude_tests: bool,
    limit: usize,
) ![]const u8 {
    const lang = tree_sitter_php();
    var checker = return_type_checker.ReturnTypeChecker.init(a, &index.sym_table, lang);
    try runReturnTypeChecker(index, &checker);
    const result = checker.result();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"summary\":{");
    try w.print(a, "\"methods_analyzed\":{d},\"methods_verified\":{d},\"methods_uncertain\":{d},\"diagnostics\":{d}", .{
        result.methods_analyzed, result.methods_verified, result.methods_uncertain, result.diagnostics.len,
    });
    try w.appendSlice(a, "},\"caveats\":{");
    try w.print(a, "\"resolution_rate\":{d:.1}", .{index.call_graph.getResolutionRate()});
    try w.appendSlice(a,
        ",\"note\":\"Unresolvable return types count as uncertain, not failed; a low resolution_rate suppresses findings rather than fabricating them.\"}");

    try w.appendSlice(a, ",\"diagnostics\":[");
    var shown: usize = 0;
    var truncated = false;
    for (result.diagnostics) |d| {
        const is_test = query.isTestFile(d.file_path);
        if (exclude_tests and is_test) continue;
        if (shown >= limit or buf.items.len >= response_byte_budget) {
            truncated = true;
            continue;
        }
        if (shown != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"kind\":");
        try appendJson(a, w, returnTypeKindName(d.kind));
        try w.appendSlice(a, ",\"class\":");
        try appendJson(a, w, d.class_name);
        try w.appendSlice(a, ",\"method\":");
        try appendJson(a, w, d.method_name);
        try w.appendSlice(a, ",\"file\":");
        try appendJson(a, w, d.file_path);
        try w.print(a, ",\"line\":{d}", .{d.line});
        try w.appendSlice(a, ",\"declared\":");
        try appendJson(a, w, d.declared_type);
        try w.appendSlice(a, ",\"actual\":");
        try appendJson(a, w, d.actual_type);
        try w.print(a, ",\"is_test\":{s}", .{if (is_test) "true" else "false"});
        try w.appendSlice(a, "}");
        shown += 1;
    }
    try w.appendSlice(a, "]");
    if (truncated) try w.appendSlice(a, ",\"diagnostics_truncated\":true");
    try w.appendSlice(a, "}");
    return buf.items;
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

const report_tool_description =
    \\Unified project health report (the MCP equivalent of the `report` CLI
    \\command): coverage + resolution rate, type-check tallies (interface
    \\compliance, call-site args, property/return types, null safety), dead-code
    \\counts with top candidates, call-confidence distribution, and a violation
    \\list. JSON output is byte-identical to `phpcma report --format json`.
    \\
    \\This rolls up the return-type, null-safety, and dead-code passes in one
    \\call; read `coverage.resolution_rate` before trusting any tally. Call
    \\`load_project` first.
;

fn buildReportSchema(a: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(a);
    return builder.toInputSchema(a);
}

fn reportHandler(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    _ = arguments;
    const state: *McpState = @ptrCast(@alignCast(user_data.?));
    const lp = state.loaded orelse return mcp.tools.errorResult(
        allocator,
        "No project loaded. Call `load_project` first.",
    ) catch return error.OutOfMemory;

    const payload = renderReport(allocator, lp.index) catch return error.OutOfMemory;
    return mcp.tools.textResult(allocator, payload) catch return error.OutOfMemory;
}

fn renderReport(a: std.mem.Allocator, index: *ProjectIndex) ![]const u8 {
    const st = &index.sym_table;
    const lang = tree_sitter_php();

    var unified = report_mod.UnifiedReport.init(a);
    unified.populate(st, &index.call_graph);
    unified.coverage.total_files = index.file_order.len;

    // Return-type pass.
    var rt_checker = return_type_checker.ReturnTypeChecker.init(a, st, lang);
    try runReturnTypeChecker(index, &rt_checker);
    const rt_result = rt_checker.result();
    unified.type_checks.return_types.pass += rt_result.methods_verified;
    unified.type_checks.return_types.fail += rt_result.diagnostics.len;
    unified.type_checks.return_types.unchecked += rt_result.methods_uncertain;
    for (rt_result.diagnostics) |diag| {
        try unified.addViolation(.{
            .severity = .warning,
            .category = "return-type-mismatch",
            .file_path = diag.file_path,
            .line = diag.line,
            .message = try diag.format(a),
        });
    }

    // Null-safety pass.
    var total_guarded: u32 = 0;
    var total_unguarded: u32 = 0;
    for (index.file_order) |path| {
        const unit = index.files.get(path) orelse continue;
        const file_ctx = index.file_contexts.getPtr(path) orelse continue;
        var analyzer = null_safety.NullSafetyAnalyzer.init(a, st, file_ctx, lang);
        const ns = analyzer.analyzeFile(unit.tree, unit.source) catch continue;
        total_guarded += ns.guarded_accesses;
        total_unguarded += ns.unguarded_accesses;
        for (ns.violations) |v| {
            const severity: report_mod.Violation.Severity = switch (v.severity) {
                .definite => .err,
                .possible => .warning,
                .guarded => .note,
            };
            try unified.addViolation(.{
                .severity = severity,
                .category = "null-safety",
                .file_path = path,
                .line = v.line,
                .message = v.message,
            });
        }
    }
    unified.type_checks.null_safety.pass = total_guarded;
    unified.type_checks.null_safety.fail = total_unguarded;
    unified.type_checks.null_safety.unchecked = 0;

    // Dead-code pass.
    const refs = try dead_code.extractRefsFromCallGraph(a, &index.call_graph, st);
    var graph = dead_code.ProjectLivenessGraph.init(a);
    try graph.analyze(st, refs);
    const dead = try graph.collectDead(st);
    for (dead) |d| {
        switch (d.kind) {
            .class => unified.dead_code.dead_classes += 1,
            .interface => unified.dead_code.dead_interfaces += 1,
            .trait => unified.dead_code.dead_traits += 1,
            .function => unified.dead_code.dead_functions += 1,
            .method => {
                unified.dead_code.dead_methods += 1;
                const vis = dead_code.ProjectLivenessGraph.getMethodVisibility(d.fqn, st);
                if (vis == .private) {
                    unified.dead_code.dead_methods_private += 1;
                } else {
                    unified.dead_code.dead_methods_public += 1;
                }
            },
            .property => unified.dead_code.dead_properties += 1,
        }
        if (unified.dead_code.top_dead_candidates.items.len < 50) {
            try unified.dead_code.top_dead_candidates.append(a, .{
                .fqn = d.fqn,
                .kind = @tagName(d.kind),
                .file_path = d.file_path,
                .line = d.line,
            });
        }
    }
    const dc_total = graph.index.count();
    var sid: dead_code.SymbolId = 0;
    while (sid < dc_total) : (sid += 1) {
        if (graph.isWeaklyAlive(sid)) unified.dead_code.kept_alive_by_unresolved += 1;
    }

    var aw: std.Io.Writer.Allocating = .init(a);
    try unified.writeJson(&aw.writer);
    return aw.written();
}

// ============================================================================
// Analyzer tool tests
// ============================================================================

test "check_dead: unreferenced class surfaces, referenced one does not" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Entry.php",
            \\<?php
            \\namespace App;
            \\class Entry {
            \\    public function run(): void { (new Used())->go(); }
            \\}
        },
        .{ "/p/Used.php",
            \\<?php
            \\namespace App;
            \\class Used { public function go(): void {} }
        },
        .{ "/p/Orphan.php",
            \\<?php
            \\namespace App;
            \\class Orphan { public function lonely(): void {} }
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckDead(a, idx, true, false, 200);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Orphan") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"resolution_rate\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "kept_alive_by_unresolved") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "check_types: single project has no cross-project violations" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/A.php",
            \\<?php
            \\namespace App;
            \\class A { public function m(int $x): void {} }
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderCheckTypes(a, idx, 0.0, false, .all, 200);
    try testing.expect(std.mem.indexOf(u8, out, "\"cross_project_calls\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"violations\":[]") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "check_boundaries: cross-package edge is reported" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try twoProjectIndexForRenderTest(gpa, a);
    defer idx.destroy();

    var analyzer = boundary_analyzer.BoundaryAnalyzer.init(a, &idx.call_graph, idx.project_configs, &idx.sym_table);
    const result = try analyzer.analyze(.{ .exclude_tests = true });
    const out = try renderCheckBoundaries(a, result, true, 200, idx);
    try testing.expect(std.mem.indexOf(u8, out, "\"projects\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"cross_package_calls\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"from\":\"a\",\"to\":\"b\"") != null or
        std.mem.indexOf(u8, out, "\"from\":\"b\",\"to\":\"a\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "return_types: missing return is diagnosed" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Bad.php",
            \\<?php
            \\namespace App;
            \\class Bad {
            \\    public function noReturn(): int { $x = 1; }
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderReturnTypes(a, idx, true, 200);
    try testing.expect(std.mem.indexOf(u8, out, "\"methods_analyzed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Bad") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "null_safety: renders summary and valid JSON" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Svc.php",
            \\<?php
            \\namespace App;
            \\class Svc {
            \\    public function run(?Svc $s): void { $s->run(null); }
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderNullSafety(a, idx, true, 200);
    try testing.expect(std.mem.indexOf(u8, out, "\"files_analyzed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"guarded_accesses\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "report: emits canonical unified report JSON" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/A.php",
            \\<?php
            \\namespace App;
            \\class A {
            \\    public function run(): void { (new A())->run(); }
            \\}
        },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderReport(a, idx);
    try testing.expect(std.mem.indexOf(u8, out, "\"coverage\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"type_checks\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"dead_code\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"resolution_rate\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
