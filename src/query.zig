//! Flexible graph-query evaluator for the MCP `query` tool.
//!
//! The agent submits a small JSON query AST (see `docs/mcp-design.md` §8) and we
//! evaluate it server-side over the in-RAM `ProjectIndex`, returning a JSON
//! result. The design goal is for the agent to "build" its own analyses by
//! composing primitives instead of us shipping a fixed catalogue of canned
//! questions.
//!
//! Pipeline: `start` (seed node set) → optional `traverse` (directed BFS over
//! call edges) → optional `where` (node-level predicate on the frontier) →
//! `select` (projection: nodes | edges | count | paths).
//!
//! Safety: every traversal is bounded. `max_depth` is clamped to a ceiling,
//! the number of visited nodes is capped, and result lists are capped by
//! `limit` (also ceiling-clamped). A `truncated` flag is set whenever any cap
//! bites, so the agent never gets a silently-partial answer it mistakes for
//! complete. No regex (single-threaded loop) — only `*`/`?` globs.

const std = @import("std");

const types = @import("types.zig");
const project_index = @import("project_index.zig");
const symbol_table = @import("symbol_table.zig");

const ProjectIndex = project_index.ProjectIndex;
const SymbolTable = symbol_table.SymbolTable;

// ============================================================================
// Cost caps (server-enforced; never trusted from the agent)
// ============================================================================

pub const max_depth_ceiling: u32 = 25;
pub const max_nodes_visited: usize = 100_000;
pub const limit_ceiling: usize = 1000;
pub const default_limit: usize = 200;
pub const default_max_depth: u32 = 5;

pub const QueryError = error{
    InvalidQuery,
    OutOfMemory,
};

// ============================================================================
// AST
// ============================================================================

pub const NodeKind = enum {
    class,
    interface,
    trait,
    method,
    function,
    external, // appears as a call endpoint but has no definition in the project

    fn label(self: NodeKind) []const u8 {
        return @tagName(self);
    }

    fn parse(s: []const u8) ?NodeKind {
        inline for (@typeInfo(NodeKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

const Direction = enum { callers, callees };

const Select = enum { nodes, edges, count, paths };

/// Node-level predicate (used by `start.match` and `where`).
const Predicate = struct {
    kind: ?NodeKind = null,
    name_glob: ?[]const u8 = null,
    namespace_prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,

    fn isEmpty(self: Predicate) bool {
        return self.kind == null and self.name_glob == null and
            self.namespace_prefix == null and self.file == null;
    }

    fn matches(self: Predicate, node: NodeInfo) bool {
        if (self.kind) |k| {
            if (node.kind != k) return false;
        }
        if (self.name_glob) |g| {
            if (!globMatch(g, node.fqn)) return false;
        }
        if (self.namespace_prefix) |p| {
            const ns = node.namespace orelse "";
            if (!std.mem.startsWith(u8, ns, p) and !std.mem.startsWith(u8, node.fqn, p))
                return false;
        }
        if (self.file) |f| {
            const path = node.file orelse return false;
            if (std.mem.indexOf(u8, path, f) == null) return false;
        }
        return true;
    }
};

const EdgeFilter = struct {
    min_confidence: f32 = 0.0,
    include_synthetic: bool = true,
    /// Include "may-call" name-bridge edges (unresolved instance calls expanded
    /// to same-named method definitions). On by default so the tool is useful on
    /// imperfectly-resolved graphs; set false (or min_confidence > 0) for the
    /// exact-only graph.
    include_bridged: bool = true,
    /// Include unresolved calls with no in-project candidate (terminal
    /// pseudo-nodes named by the bare callee). Off by default.
    include_unresolved: bool = false,
    /// Drop edges whose *caller* lives in a test file (see `isTestFile`). Off by
    /// default; set true so caller/impact surveys reflect production usage only.
    exclude_tests: bool = false,
};

/// Heuristic: does this file path belong to test code? Used to separate
/// production callers from test-only callers (PHPUnit, integration suites).
/// Case-insensitive; matches common PHP test conventions.
pub fn isTestFile(path: []const u8) bool {
    if (path.len == 0) return false;
    // Path-segment markers: /test/, /tests/, /Test/, /Tests/.
    if (containsCiSegment(path, "test")) return true;
    if (containsCiSegment(path, "tests")) return true;
    // Filename suffixes: *Test.php, *.unit.php, *.integration.php.
    if (endsWithCi(path, "test.php")) return true;
    if (endsWithCi(path, ".unit.php")) return true;
    if (endsWithCi(path, ".integration.php")) return true;
    return false;
}

/// True if `needle` appears as a `/`-delimited path segment in `haystack`
/// (case-insensitive).
fn containsCiSegment(haystack: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= haystack.len) : (i += 1) {
        if (i == haystack.len or haystack[i] == '/') {
            const seg = haystack[start..i];
            if (seg.len == needle.len and std.ascii.eqlIgnoreCase(seg, needle)) return true;
            start = i + 1;
        }
    }
    return false;
}

fn endsWithCi(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

const Traverse = struct {
    direction: Direction,
    min_depth: u32 = 1,
    max_depth: u32 = default_max_depth,
    edge_filter: EdgeFilter = .{},
};

const Start = union(enum) {
    fqn: []const u8,
    match: Predicate,
};

const Query = struct {
    start: Start,
    traverse: ?Traverse = null,
    where_pred: ?Predicate = null,
    select: Select = .nodes,
    limit: usize = default_limit,
};

// ============================================================================
// Node / edge model (built per query in the per-message arena)
// ============================================================================

const NodeInfo = struct {
    fqn: []const u8,
    kind: NodeKind,
    namespace: ?[]const u8,
    file: ?[]const u8,
};

/// How an edge's `to` endpoint was determined.
const EdgeResolution = enum {
    exact, // the analyzer resolved the callee type (resolved_target set)
    name_bridge, // unresolved instance call expanded to a same-named method def
    external, // unresolved with no in-project candidate (pseudo-node endpoint)
    external_receiver, // receiver type resolved to a non-indexed (vendor/core)
    // class: definitively external, NOT a fixable in-project ambiguity, so it is
    // deliberately never name-bridged (see edge construction).

    fn label(self: EdgeResolution) []const u8 {
        return @tagName(self);
    }
};

/// Why an edge is unresolved (i.e. carries no receiver-type evidence), derived
/// from how it was built. `null` for exact edges. Turns a silent "0 callers"
/// into an actionable signal:
///   - `single_candidate`  : one in-project same-named method exists; the type
///                           wasn't inferred (often a DI-injected interface with
///                           a single implementor — see milestone 2.1).
///   - `ambiguous_bridge`  : several same-named methods; the bridge can't tell
///                           which (sibling-namespace twins, overloads).
///   - `no_candidate`      : no in-project method by that name — an external/
///                           vendor call, or a dynamic/variable callee.
///   - `external_receiver` : the receiver type WAS resolved but is a non-indexed
///                           (vendor/core) class, so the call is definitively
///                           external. These are split out from the name-bridge
///                           buckets so common accessors (getId, getName, …) on
///                           core objects don't masquerade as fixable in-project
///                           `ambiguous_bridge` candidates.
fn unresolvedReason(e: Edge) ?[]const u8 {
    return switch (e.resolution) {
        .exact => null,
        .name_bridge => if (e.candidate_count > 1) "ambiguous_bridge" else "single_candidate",
        .external => "no_candidate",
        .external_receiver => "external_receiver",
    };
}

const Edge = struct {
    from: []const u8,
    to: []const u8,
    raw_callee: []const u8, // the bare method name at the callsite
    confidence: f32,
    synthetic: bool,
    resolved: bool,
    resolution: EdgeResolution,
    candidate_count: usize, // # of bridge candidates (1 for exact/external)
    line: u32,
    column: u32,
    file: []const u8,
    is_test: bool, // caller file is test code (see isTestFile)

    fn passes(self: Edge, filter: EdgeFilter) bool {
        if (self.synthetic and !filter.include_synthetic) return false;
        if (self.is_test and filter.exclude_tests) return false;
        switch (self.resolution) {
            .exact => return self.confidence >= filter.min_confidence,
            // Bridges carry no receiver-type evidence (confidence 0.0), so a
            // positive min_confidence threshold also excludes them — that's the
            // exact-only escape hatch.
            .name_bridge => return filter.include_bridged and self.confidence >= filter.min_confidence,
            // External endpoints (no candidate) and external-receiver calls
            // (resolved-but-vendor receiver) are both terminal, unresolved, and
            // carry no receiver-type evidence we can act on, so they share the
            // `include_unresolved` gate.
            .external, .external_receiver => return filter.include_unresolved and self.confidence >= filter.min_confidence,
        }
    }
};

/// The query-time graph: a node table keyed by FQN plus forward/reverse
/// adjacency (indices into `edges`). Everything is allocated in the caller's
/// arena and discarded after the query.
const Graph = struct {
    a: std.mem.Allocator,
    nodes: std.StringHashMap(NodeInfo),
    edges: []Edge,
    fwd: std.StringHashMap(std.ArrayListUnmanaged(usize)), // from -> edge idxs
    rev: std.StringHashMap(std.ArrayListUnmanaged(usize)), // to   -> edge idxs
    methods_by_name: std.StringHashMap(std.ArrayListUnmanaged([]const u8)), // short name -> sorted FQNs

    fn nodeInfo(self: *const Graph, fqn: []const u8) NodeInfo {
        return self.nodes.get(fqn) orelse .{
            .fqn = fqn,
            .kind = .external,
            .namespace = namespaceOf(fqn),
            .file = null,
        };
    }
};

fn namespaceOf(fqn: []const u8) ?[]const u8 {
    // Strip a trailing ::member, then take the namespace portion of the FQCN.
    const class_part = if (std.mem.indexOf(u8, fqn, "::")) |i| fqn[0..i] else fqn;
    if (std.mem.lastIndexOf(u8, class_part, "\\")) |sep| return class_part[0..sep];
    return null;
}

fn buildGraph(a: std.mem.Allocator, index: *const ProjectIndex) !Graph {
    var g = Graph{
        .a = a,
        .nodes = std.StringHashMap(NodeInfo).init(a),
        .edges = &.{},
        .fwd = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(a),
        .rev = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(a),
        .methods_by_name = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(a),
    };

    const st = &index.sym_table;

    // Containers + their methods.
    var class_it = st.classes.iterator();
    while (class_it.next()) |e| {
        const c = e.value_ptr;
        try putNode(&g, c.fqcn, .class, c.namespace, c.file_path);
        try putMethods(&g, c.fqcn, c.namespace, c.file_path, &c.methods);
    }
    var iface_it = st.interfaces.iterator();
    while (iface_it.next()) |e| {
        const c = e.value_ptr;
        try putNode(&g, c.fqcn, .interface, c.namespace, c.file_path);
        try putMethods(&g, c.fqcn, c.namespace, c.file_path, &c.methods);
    }
    var trait_it = st.traits.iterator();
    while (trait_it.next()) |e| {
        const c = e.value_ptr;
        try putNode(&g, c.fqcn, .trait, c.namespace, c.file_path);
        try putMethods(&g, c.fqcn, c.namespace, c.file_path, &c.methods);
    }
    var fn_it = st.functions.iterator();
    while (fn_it.next()) |e| {
        const f = e.value_ptr;
        try putNode(&g, f.fqn, .function, f.namespace, f.file_path);
    }

    // Sort each name-bridge candidate list for deterministic BFS/path output.
    var mit = g.methods_by_name.valueIterator();
    while (mit.next()) |list| std.mem.sort([]const u8, list.items, {}, lessThanStr);

    // Edges from the call graph. Resolved calls become exact edges; unresolved
    // instance calls are expanded into "may-call" name-bridge edges to every
    // same-named method definition (confidence 0.0, flagged); anything else is a
    // terminal external pseudo-node.
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    const calls = index.call_graph.calls.items;
    for (calls) |call| {
        const synthetic = call.resolution_method == .plugin_generated;
        const caller_is_test = isTestFile(call.file_path);
        if (call.resolved_target) |target| {
            try addEdge(&g, a, &edges, .{
                .from = call.caller_fqn,
                .to = target,
                .raw_callee = call.callee_name,
                .confidence = call.resolution_confidence,
                .synthetic = synthetic,
                .resolved = true,
                .resolution = .exact,
                .candidate_count = 1,
                .line = call.line,
                .column = call.column,
                .file = call.file_path,
                .is_test = caller_is_test,
            });
            continue;
        }

        // Unresolved, but the receiver type WAS resolved to a non-indexed
        // (vendor/core) class: the call is definitively external. Emit a terminal
        // edge and deliberately skip name-bridging — otherwise common accessors
        // (getId, getName, count, …) on core objects would masquerade as fixable
        // in-project `ambiguous_bridge` candidates, inflating that bucket. The
        // endpoint carries the concrete receiver FQCN when known.
        if (call.unresolved_reason == .recv_type_external) {
            const endpoint = if (call.receiver_type) |rt|
                try std.fmt.allocPrint(a, "{s}::{s}", .{ rt, call.callee_name })
            else
                call.callee_name;
            try addEdge(&g, a, &edges, .{
                .from = call.caller_fqn,
                .to = endpoint,
                .raw_callee = call.callee_name,
                .confidence = 0.0,
                .synthetic = synthetic,
                .resolved = false,
                .resolution = .external_receiver,
                .candidate_count = 1,
                .line = call.line,
                .column = call.column,
                .file = call.file_path,
                .is_test = caller_is_test,
            });
            continue;
        }

        // Unresolved. Bridge instance-method calls by name when candidates exist.
        const candidates: ?[]const []const u8 = if (call.call_type == .method)
            (if (g.methods_by_name.get(call.callee_name)) |l| l.items else null)
        else
            null;

        if (candidates) |targets| {
            for (targets) |target| {
                try addEdge(&g, a, &edges, .{
                    .from = call.caller_fqn,
                    .to = target,
                    .raw_callee = call.callee_name,
                    .confidence = 0.0,
                    .synthetic = synthetic,
                    .resolved = false,
                    .resolution = .name_bridge,
                    .candidate_count = targets.len,
                    .line = call.line,
                    .column = call.column,
                    .file = call.file_path,
                    .is_test = caller_is_test,
                });
            }
        } else {
            try addEdge(&g, a, &edges, .{
                .from = call.caller_fqn,
                .to = call.callee_name,
                .raw_callee = call.callee_name,
                .confidence = 0.0,
                .synthetic = synthetic,
                .resolved = false,
                .resolution = .external,
                .candidate_count = 1,
                .line = call.line,
                .column = call.column,
                .file = call.file_path,
                .is_test = caller_is_test,
            });
        }
    }
    g.edges = try edges.toOwnedSlice(a);
    return g;
}

fn addEdge(g: *Graph, a: std.mem.Allocator, edges: *std.ArrayListUnmanaged(Edge), edge: Edge) !void {
    const i = edges.items.len;
    try edges.append(a, edge);
    try appendAdj(&g.fwd, a, edge.from, i);
    try appendAdj(&g.rev, a, edge.to, i);
}

fn putNode(g: *Graph, fqn: []const u8, kind: NodeKind, ns: ?[]const u8, file: []const u8) !void {
    try g.nodes.put(fqn, .{
        .fqn = fqn,
        .kind = kind,
        .namespace = ns,
        .file = if (file.len > 0) file else null,
    });
}

fn putMethods(
    g: *Graph,
    fqcn: []const u8,
    ns: ?[]const u8,
    file: []const u8,
    methods: *const std.StringHashMap(types.MethodSymbol),
) !void {
    var it = methods.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr;
        const fqn = try std.fmt.allocPrint(g.a, "{s}::{s}", .{ fqcn, m.name });
        const mfile = if (m.file_path.len > 0) m.file_path else file;
        try putNode(g, fqn, .method, ns, mfile);

        // Index by short method name for name-bridge expansion.
        const gop = try g.methods_by_name.getOrPut(m.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(g.a, fqn);
    }
}

fn appendAdj(
    map: *std.StringHashMap(std.ArrayListUnmanaged(usize)),
    a: std.mem.Allocator,
    key: []const u8,
    idx: usize,
) !void {
    const gop = try map.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, idx);
}

// ============================================================================
// Glob matcher (`*` = any run, `?` = one char). No regex by design.
// ============================================================================

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = t;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ============================================================================
// Parsing the JSON query AST
// ============================================================================

fn parseQuery(v: std.json.Value) QueryError!Query {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidQuery,
    };

    const start_v = obj.get("start") orelse return error.InvalidQuery;
    const start = try parseStart(start_v);

    var q = Query{ .start = start };

    if (obj.get("traverse")) |tv| q.traverse = try parseTraverse(tv);
    if (obj.get("where")) |wv| q.where_pred = try parsePredicate(wv);
    if (obj.get("select")) |sv| {
        const s = asString(sv) orelse return error.InvalidQuery;
        q.select = parseSelect(s) orelse return error.InvalidQuery;
    }
    if (obj.get("limit")) |lv| {
        const n = asInt(lv) orelse return error.InvalidQuery;
        if (n < 0) return error.InvalidQuery;
        q.limit = @min(@as(usize, @intCast(n)), limit_ceiling);
        if (q.limit == 0) q.limit = default_limit;
    }
    return q;
}

fn parseStart(v: std.json.Value) QueryError!Start {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidQuery,
    };
    if (obj.get("fqn")) |fv| {
        const s = asString(fv) orelse return error.InvalidQuery;
        return .{ .fqn = s };
    }
    if (obj.get("match")) |mv| {
        return .{ .match = try parsePredicate(mv) };
    }
    // Lenient: treat the start object itself as a predicate.
    const pred = try parsePredicate(v);
    if (pred.isEmpty()) return error.InvalidQuery;
    return .{ .match = pred };
}

fn parsePredicate(v: std.json.Value) QueryError!Predicate {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidQuery,
    };
    var p = Predicate{};
    if (obj.get("kind")) |kv| {
        const s = asString(kv) orelse return error.InvalidQuery;
        p.kind = NodeKind.parse(s) orelse return error.InvalidQuery;
    }
    if (obj.get("name")) |nv| p.name_glob = asString(nv) orelse return error.InvalidQuery;
    if (obj.get("namespace_prefix")) |nv|
        p.namespace_prefix = asString(nv) orelse return error.InvalidQuery;
    if (obj.get("file")) |fv| p.file = asString(fv) orelse return error.InvalidQuery;
    return p;
}

fn parseTraverse(v: std.json.Value) QueryError!Traverse {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidQuery,
    };
    const dir_v = obj.get("direction") orelse return error.InvalidQuery;
    const dir_s = asString(dir_v) orelse return error.InvalidQuery;
    const direction: Direction = if (std.mem.eql(u8, dir_s, "callers"))
        .callers
    else if (std.mem.eql(u8, dir_s, "callees"))
        .callees
    else
        return error.InvalidQuery;

    var t = Traverse{ .direction = direction };
    if (obj.get("min_depth")) |mv| {
        const n = asInt(mv) orelse return error.InvalidQuery;
        if (n < 0) return error.InvalidQuery;
        t.min_depth = @intCast(@min(n, @as(i64, max_depth_ceiling)));
    }
    if (obj.get("max_depth")) |mv| {
        const n = asInt(mv) orelse return error.InvalidQuery;
        if (n < 0) return error.InvalidQuery;
        t.max_depth = @intCast(@min(n, @as(i64, max_depth_ceiling)));
    }
    t.max_depth = @min(t.max_depth, max_depth_ceiling);
    if (t.min_depth > t.max_depth) t.min_depth = t.max_depth;
    if (obj.get("edge_filter")) |ev| t.edge_filter = try parseEdgeFilter(ev);
    return t;
}

fn parseEdgeFilter(v: std.json.Value) QueryError!EdgeFilter {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidQuery,
    };
    var f = EdgeFilter{};
    if (obj.get("min_confidence")) |cv| {
        const x = asFloat(cv) orelse return error.InvalidQuery;
        f.min_confidence = @floatCast(std.math.clamp(x, 0.0, 1.0));
    }
    if (obj.get("include_synthetic")) |bv| f.include_synthetic = asBool(bv) orelse return error.InvalidQuery;
    if (obj.get("include_bridged")) |bv| f.include_bridged = asBool(bv) orelse return error.InvalidQuery;
    if (obj.get("include_unresolved")) |bv| f.include_unresolved = asBool(bv) orelse return error.InvalidQuery;
    if (obj.get("exclude_tests")) |bv| f.exclude_tests = asBool(bv) orelse return error.InvalidQuery;
    return f;
}

fn parseSelect(s: []const u8) ?Select {
    if (std.mem.eql(u8, s, "nodes")) return .nodes;
    if (std.mem.eql(u8, s, "edges")) return .edges;
    if (std.mem.eql(u8, s, "count")) return .count;
    if (std.mem.eql(u8, s, "paths")) return .paths;
    return null;
}

fn asString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
fn asInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}
fn asFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}
fn asBool(v: std.json.Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

// ============================================================================
// Evaluation
// ============================================================================

const Reached = struct {
    fqn: []const u8,
    depth: u32,
    parent: ?usize, // index into the reached list (for path reconstruction)
};

const EvalResult = struct {
    all: []Reached, // full BFS-order node list (with parent links)
    frontier: []usize, // indices into `all`: nodes within [min_depth, max_depth] passing `where`
    edges: []Edge, // edges actually traversed (deduped on render)
    nodes_visited: usize,
    truncated: bool,
};

/// Public entry point. Parses `query_value` and evaluates it against `index`,
/// returning a JSON result string allocated in `a`.
pub fn run(a: std.mem.Allocator, index: *const ProjectIndex, query_value: std.json.Value) QueryError![]const u8 {
    const q = try parseQuery(query_value);
    var g = try buildGraph(a, index);

    // Seed set.
    var seeds: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (q.start) {
        .fqn => |f| {
            if (g.nodes.contains(f) or g.fwd.contains(f) or g.rev.contains(f))
                try seeds.append(a, f);
        },
        .match => |pred| {
            var it = g.nodes.iterator();
            while (it.next()) |e| {
                if (pred.matches(e.value_ptr.*)) try seeds.append(a, e.key_ptr.*);
            }
        },
    }

    const ev = try evaluate(a, &g, q, seeds.items);
    return try render(a, &g, q, ev);
}

fn evaluate(a: std.mem.Allocator, g: *Graph, q: Query, seeds: []const []const u8) QueryError!EvalResult {
    var reached: std.ArrayListUnmanaged(Reached) = .empty;
    var traversed: std.ArrayListUnmanaged(Edge) = .empty;
    var truncated = false;

    // No traversal: the seed set *is* the result (depth 0).
    if (q.traverse == null) {
        var frontier0: std.ArrayListUnmanaged(usize) = .empty;
        for (seeds) |s| {
            if (q.where_pred) |wp| {
                if (!wp.matches(g.nodeInfo(s))) continue;
            }
            const idx = reached.items.len;
            try reached.append(a, .{ .fqn = s, .depth = 0, .parent = null });
            try frontier0.append(a, idx);
        }
        return .{
            .all = reached.items,
            .frontier = frontier0.items,
            .edges = traversed.items,
            .nodes_visited = seeds.len,
            .truncated = false,
        };
    }

    const t = q.traverse.?;

    // BFS with first-seen depth (and a parent pointer for path reconstruction).
    var seen = std.StringHashMap(usize).init(a); // fqn -> index into reached
    var queue: std.ArrayListUnmanaged(usize) = .empty;
    var visited: usize = 0;

    for (seeds) |s| {
        if (seen.contains(s)) continue;
        const idx = reached.items.len;
        try reached.append(a, .{ .fqn = s, .depth = 0, .parent = null });
        try seen.put(s, idx);
        try queue.append(a, idx);
    }

    var head: usize = 0;
    outer: while (head < queue.items.len) : (head += 1) {
        const cur_idx = queue.items[head];
        const cur = reached.items[cur_idx];
        if (cur.depth >= t.max_depth) continue;

        const adj_map = switch (t.direction) {
            .callees => &g.fwd,
            .callers => &g.rev,
        };
        const list = adj_map.get(cur.fqn) orelse continue;
        for (list.items) |ei| {
            const edge = g.edges[ei];
            if (!edge.passes(t.edge_filter)) continue;
            const next = switch (t.direction) {
                .callees => edge.to,
                .callers => edge.from,
            };
            try traversed.append(a, edge);
            if (seen.get(next)) |_| continue;

            visited += 1;
            if (visited > max_nodes_visited) {
                truncated = true;
                break :outer;
            }
            const idx = reached.items.len;
            try reached.append(a, .{ .fqn = next, .depth = cur.depth + 1, .parent = cur_idx });
            try seen.put(next, idx);
            try queue.append(a, idx);
        }
    }

    // Frontier filter: keep nodes whose depth is within [min_depth, max_depth]
    // and (if present) satisfy `where`. Store indices into `reached` so paths
    // can be reconstructed via parent links.
    var frontier: std.ArrayListUnmanaged(usize) = .empty;
    for (reached.items, 0..) |r, i| {
        if (r.depth < t.min_depth or r.depth > t.max_depth) continue;
        if (q.where_pred) |wp| {
            if (!wp.matches(g.nodeInfo(r.fqn))) continue;
        }
        try frontier.append(a, i);
    }

    return .{
        .all = reached.items,
        .frontier = frontier.items,
        .edges = traversed.items,
        .nodes_visited = visited,
        .truncated = truncated,
    };
}

// ============================================================================
// Rendering (deterministic JSON)
// ============================================================================

fn lessThanStr(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn render(a: std.mem.Allocator, g: *Graph, q: Query, ev: EvalResult) QueryError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = &buf;

    try w.appendSlice(a, "{\"select\":\"");
    try w.appendSlice(a, @tagName(q.select));
    try w.appendSlice(a, "\",");

    switch (q.select) {
        .count => try renderCount(a, w, g, q, ev),
        .nodes => try renderNodes(a, w, g, q, ev),
        .edges => try renderEdges(a, w, q, ev),
        .paths => try renderPaths(a, w, q, ev),
    }

    try w.print(a, ",\"nodes_visited\":{d}", .{ev.nodes_visited});
    try w.print(a, ",\"truncated\":{s}}}", .{if (ev.truncated) "true" else "false"});
    return buf.items;
}

fn renderCount(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), g: *Graph, q: Query, ev: EvalResult) QueryError!void {
    _ = g;
    _ = q;
    // Distinct frontier nodes.
    var seen = std.StringHashMap(void).init(a);
    var n: usize = 0;
    for (ev.frontier) |fi| {
        const gop = try seen.getOrPut(ev.all[fi].fqn);
        if (gop.found_existing) continue;
        n += 1;
    }
    try w.print(a, "\"count\":{d}", .{n});
}

fn renderNodes(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), g: *Graph, q: Query, ev: EvalResult) QueryError!void {
    // Dedup by fqn (keep shallowest depth seen).
    var seen = std.StringHashMap(void).init(a);
    var items: std.ArrayListUnmanaged(Reached) = .empty;
    for (ev.frontier) |fi| {
        const r = ev.all[fi];
        const gop = try seen.getOrPut(r.fqn);
        if (gop.found_existing) continue;
        try items.append(a, r);
    }
    std.mem.sort(Reached, items.items, {}, struct {
        fn lt(_: void, l: Reached, r: Reached) bool {
            return std.mem.lessThan(u8, l.fqn, r.fqn);
        }
    }.lt);

    const total = items.items.len;
    const shown = @min(total, q.limit);

    try w.print(a, "\"count\":{d},\"nodes\":[", .{total});
    for (items.items[0..shown], 0..) |r, i| {
        if (i != 0) try w.appendSlice(a, ",");
        const info = g.nodeInfo(r.fqn);
        try w.appendSlice(a, "{\"fqn\":");
        try appendJsonString(a, w, r.fqn);
        try w.print(a, ",\"kind\":\"{s}\",\"depth\":{d}", .{ info.kind.label(), r.depth });
        if (info.file) |f| {
            try w.appendSlice(a, ",\"file\":");
            try appendJsonString(a, w, f);
        }
        try w.appendSlice(a, "}");
    }
    try w.appendSlice(a, "]");
    if (shown < total) try w.appendSlice(a, ",\"limited\":true");
}

fn renderEdges(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), q: Query, ev: EvalResult) QueryError!void {
    // Dedup edges by (from,to,line,column); sort deterministically.
    var seen = std.StringHashMap(void).init(a);
    var items: std.ArrayListUnmanaged(Edge) = .empty;
    for (ev.edges) |e| {
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}\x00{d}", .{ e.from, e.to, e.line, e.column });
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) continue;
        try items.append(a, e);
    }
    std.mem.sort(Edge, items.items, {}, struct {
        fn lt(_: void, l: Edge, r: Edge) bool {
            const c = std.mem.order(u8, l.from, r.from);
            if (c != .eq) return c == .lt;
            const c2 = std.mem.order(u8, l.to, r.to);
            if (c2 != .eq) return c2 == .lt;
            if (l.line != r.line) return l.line < r.line;
            return l.column < r.column;
        }
    }.lt);

    const total = items.items.len;
    const shown = @min(total, q.limit);
    try w.print(a, "\"count\":{d},\"edges\":[", .{total});
    for (items.items[0..shown], 0..) |e, i| {
        if (i != 0) try w.appendSlice(a, ",");
        try w.appendSlice(a, "{\"from\":");
        try appendJsonString(a, w, e.from);
        try w.appendSlice(a, ",\"to\":");
        try appendJsonString(a, w, e.to);
        try w.print(a, ",\"confidence\":{d:.2},\"resolved\":{s},\"resolution\":\"{s}\",\"synthetic\":{s},\"line\":{d},\"column\":{d}", .{
            e.confidence,
            if (e.resolved) "true" else "false",
            e.resolution.label(),
            if (e.synthetic) "true" else "false",
            e.line,
            e.column,
        });
        try w.print(a, ",\"is_test\":{s}", .{if (e.is_test) "true" else "false"});
        if (unresolvedReason(e)) |reason| {
            try w.print(a, ",\"unresolved_reason\":\"{s}\"", .{reason});
        }
        if (e.resolution == .name_bridge) {
            try w.print(a, ",\"raw_callee\":", .{});
            try appendJsonString(a, w, e.raw_callee);
            try w.print(a, ",\"candidate_count\":{d}", .{e.candidate_count});
        }
        if (e.file.len > 0) {
            try w.appendSlice(a, ",\"file\":");
            try appendJsonString(a, w, e.file);
        }
        try w.appendSlice(a, "}");
    }
    try w.appendSlice(a, "]");
    if (shown < total) try w.appendSlice(a, ",\"limited\":true");
}

fn renderPaths(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), q: Query, ev: EvalResult) QueryError!void {
    // One shortest path per frontier node, reconstructed via parent links
    // (BFS first-seen ⇒ shortest). The seed end is the path's first element.
    // Sorted shortest-first, then lexicographically by the endpoint FQN; capped
    // at `limit` (never full enumeration — a diamond has exponentially many).
    const FrontierRef = struct { idx: usize, depth: u32, fqn: []const u8 };
    var refs: std.ArrayListUnmanaged(FrontierRef) = .empty;
    for (ev.frontier) |fi| {
        try refs.append(a, .{ .idx = fi, .depth = ev.all[fi].depth, .fqn = ev.all[fi].fqn });
    }
    std.mem.sort(FrontierRef, refs.items, {}, struct {
        fn lt(_: void, l: FrontierRef, r: FrontierRef) bool {
            if (l.depth != r.depth) return l.depth < r.depth;
            return std.mem.lessThan(u8, l.fqn, r.fqn);
        }
    }.lt);

    const total = refs.items.len;
    const shown = @min(total, q.limit);

    try w.print(a, "\"count\":{d},\"paths\":[", .{total});
    for (refs.items[0..shown], 0..) |ref, i| {
        if (i != 0) try w.appendSlice(a, ",");
        // Walk parent links to the seed, collecting FQNs, then emit reversed.
        var chain: std.ArrayListUnmanaged([]const u8) = .empty;
        var cur: ?usize = ref.idx;
        while (cur) |ci| {
            try chain.append(a, ev.all[ci].fqn);
            cur = ev.all[ci].parent;
        }
        try w.appendSlice(a, "[");
        var j: usize = chain.items.len;
        var first = true;
        while (j > 0) {
            j -= 1;
            if (!first) try w.appendSlice(a, ",");
            first = false;
            try appendJsonString(a, w, chain.items[j]);
        }
        try w.appendSlice(a, "]");
    }
    try w.appendSlice(a, "]");
    if (shown < total) try w.appendSlice(a, ",\"limited\":true");
}

fn appendJsonString(a: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
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
// Tests
// ============================================================================

const testing = std.testing;

/// Run a JSON query string against an index, returning the JSON result string.
fn runQueryStr(a: std.mem.Allocator, index: *const ProjectIndex, json: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    return run(a, index, parsed.value);
}

const caller_php =
    \\<?php
    \\namespace App;
    \\class Caller {
    \\    public function run(): void {
    \\        $this->dep->log();
    \\        \App\Logger::ping();
    \\    }
    \\}
;
const logger_php =
    \\<?php
    \\namespace App;
    \\class Logger {
    \\    public function log(): void {}
    \\    public function ping(): void {}
    \\}
;

test "query: name-bridge connects an unresolved instance call to the method def" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Caller.php", caller_php },
        .{ "/p/Logger.php", logger_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Callers of App\Logger::log should reach App\Caller::run via the bridge.
    const out = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Logger::log"},
        \\ "traverse":{"direction":"callers","max_depth":2},"select":"nodes"}
    );
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Caller::run") != null);
}

test "query: external-receiver call is labeled, not name-bridged" {
    const gpa = testing.allocator;
    // `$this->product` resolves to a non-indexed vendor class; `getId` collides
    // with an in-project method of the same name. The edge must be tagged
    // external_receiver (terminal, vendor endpoint) rather than bridged to the
    // in-project App\Entity::getId.
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
    const a = arena.allocator();

    const out = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Service::run"},
        \\ "traverse":{"direction":"callees","max_depth":1,
        \\ "edge_filter":{"include_unresolved":true}},"select":"edges"}
    );
    // Tagged as external_receiver, with the vendor FQCN as the endpoint…
    try testing.expect(std.mem.indexOf(u8, out, "\"resolution\":\"external_receiver\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"unresolved_reason\":\"external_receiver\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Vendor\\\\Product::getId") != null);
    // …and never bridged to the colliding in-project method.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Entity::getId") == null);
    try testing.expect(std.mem.indexOf(u8, out, "name_bridge") == null);
}

test "query: exact static edge vs name-bridge, and exact-only filter" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Caller.php", caller_php },
        .{ "/p/Logger.php", logger_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Default filter (bridges on): both the exact ping edge and the bridged log
    // edge appear.
    const both = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Caller::run"},
        \\ "traverse":{"direction":"callees","max_depth":1},"select":"edges"}
    );
    try testing.expect(std.mem.indexOf(u8, both, "App\\\\Logger::ping") != null);
    try testing.expect(std.mem.indexOf(u8, both, "App\\\\Logger::log") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"resolution\":\"exact\"") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"resolution\":\"name_bridge\"") != null);

    // Exact-only escape hatch: min_confidence 0.5 drops zero-confidence bridges.
    const exact = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Caller::run"},
        \\ "traverse":{"direction":"callees","max_depth":1,
        \\ "edge_filter":{"min_confidence":0.5}},"select":"edges"}
    );
    try testing.expect(std.mem.indexOf(u8, exact, "App\\\\Logger::ping") != null);
    try testing.expect(std.mem.indexOf(u8, exact, "App\\\\Logger::log") == null);
}

test "isTestFile: classifier truth table" {
    // Production paths.
    try testing.expect(!isTestFile("src/Service/UserService.php"));
    try testing.expect(!isTestFile("/p/Logger.php"));
    try testing.expect(!isTestFile(""));
    try testing.expect(!isTestFile("src/Contest/Entry.php")); // "Contest" is not a "test" segment
    // Path-segment markers (case-insensitive).
    try testing.expect(isTestFile("src/test/Foo.php"));
    try testing.expect(isTestFile("module/Tests/Integration/Foo.php"));
    try testing.expect(isTestFile("/abs/Test/Helper.php"));
    // Filename suffix conventions.
    try testing.expect(isTestFile("src/Service/UserServiceTest.php"));
    try testing.expect(isTestFile("src/Service/UserService.unit.php"));
    try testing.expect(isTestFile("src/Service/UserService.integration.php"));
}

test "query: exclude_tests drops test-only callers" {
    const gpa = testing.allocator;
    // Two callers of App\Logger::log: one in production, one in a test file.
    const prod_caller =
        \\<?php
        \\namespace App;
        \\class ProdCaller {
        \\    public function run(Logger $l): void { $l->log(); }
        \\}
    ;
    const test_caller =
        \\<?php
        \\namespace App;
        \\class LoggerTest {
        \\    public function testLog(Logger $l): void { $l->log(); }
        \\}
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/src/ProdCaller.php", prod_caller },
        .{ "/p/tests/LoggerTest.php", test_caller },
        .{ "/p/Logger.php", logger_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Without exclude_tests: both callers reach Logger::log.
    const both = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Logger::log"},
        \\ "traverse":{"direction":"callers","max_depth":2},"select":"nodes"}
    );
    try testing.expect(std.mem.indexOf(u8, both, "App\\\\ProdCaller::run") != null);
    try testing.expect(std.mem.indexOf(u8, both, "App\\\\LoggerTest::testLog") != null);

    // With exclude_tests: only the production caller remains.
    const prod_only = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Logger::log"},
        \\ "traverse":{"direction":"callers","max_depth":2,
        \\ "edge_filter":{"exclude_tests":true}},"select":"nodes"}
    );
    try testing.expect(std.mem.indexOf(u8, prod_only, "App\\\\ProdCaller::run") != null);
    try testing.expect(std.mem.indexOf(u8, prod_only, "App\\\\LoggerTest::testLog") == null);
}

test "query: duplicate method names bridge to all candidates" {
    const gpa = testing.allocator;
    const other_php =
        \\<?php
        \\namespace App;
        \\class OtherLogger { public function log(): void {} }
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Caller.php", caller_php },
        .{ "/p/Logger.php", logger_php },
        .{ "/p/OtherLogger.php", other_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Caller::run"},
        \\ "traverse":{"direction":"callees","max_depth":1},"select":"edges"}
    );
    // The unresolved log() call bridges to both definitions, flagged with count.
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\Logger::log") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App\\\\OtherLogger::log") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"candidate_count\":2") != null);
}

test "query: count and glob match" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Caller.php", caller_php },
        .{ "/p/Logger.php", logger_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Match all methods named *::log via glob; no traverse → the node itself.
    const out = try runQueryStr(a,
        idx,
        \\{"start":{"match":{"kind":"method","name":"*::log"}},"select":"count"}
    );
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":1") != null);
}

test "globMatch basics" {
    try testing.expect(globMatch("*::save", "App\\X::save"));
    try testing.expect(globMatch("App\\*", "App\\Y::m"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));
    try testing.expect(!globMatch("*::save", "App\\X::load"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("exact", "exact"));
}

test "query: cyclic graph terminates and depth bounds the frontier" {
    const gpa = testing.allocator;
    const chain_php =
        \\<?php
        \\namespace App;
        \\class Chain {
        \\    public function m0(): void { $this->m1(); }
        \\    public function m1(): void { $this->m2(); }
        \\    public function m2(): void { $this->m3(); }
        \\    public function m3(): void {}
        \\}
    ;
    const cyclic_php =
        \\<?php
        \\namespace App;
        \\class Cyclic {
        \\    public function a(): void { $this->b(); }
        \\    public function b(): void { $this->a(); }
        \\}
    ;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Chain.php", chain_php },
        .{ "/p/Cyclic.php", cyclic_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // max_depth bounds the frontier: from m0 with max_depth 2 we reach m1,m2 but
    // not m3.
    const bounded = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Chain::m0"},
        \\ "traverse":{"direction":"callees","min_depth":1,"max_depth":2},"select":"nodes"}
    );
    try testing.expect(std.mem.indexOf(u8, bounded, "App\\\\Chain::m1") != null);
    try testing.expect(std.mem.indexOf(u8, bounded, "App\\\\Chain::m2") != null);
    try testing.expect(std.mem.indexOf(u8, bounded, "App\\\\Chain::m3") == null);

    // A cycle must terminate (BFS dedups visited nodes). Large max_depth, no hang.
    const cyc = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Cyclic::a"},
        \\ "traverse":{"direction":"callees","max_depth":20},"select":"count"}
    );
    // From seed `a` (depth 0, excluded) only `b` is reached (depth 1); the edge
    // back to `a` is dropped because it's already seen — so the BFS terminates.
    try testing.expect(std.mem.indexOf(u8, cyc, "\"count\":1") != null);
}

test "query: limit caps result list and sets limited flag" {
    const gpa = testing.allocator;
    const idx = try project_index.createInMemoryForTest(gpa, &.{
        .{ "/p/Caller.php", caller_php },
        .{ "/p/Logger.php", logger_php },
    });
    defer idx.destroy();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Caller::run reaches both Logger::ping and Logger::log; limit 1 caps it.
    const out = try runQueryStr(a,
        idx,
        \\{"start":{"fqn":"App\\Caller::run"},
        \\ "traverse":{"direction":"callees","max_depth":1},"select":"nodes","limit":1}
    );
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"limited\":true") != null);
}
