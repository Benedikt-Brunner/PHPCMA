const std = @import("std");
const ts = @import("tree-sitter");

const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");
const symbol_collector = @import("symbol_collector.zig");
const plugin_interface = @import("plugins/plugin_interface.zig");
const plugin_registry = @import("plugins/plugin_registry.zig");
const references = @import("references.zig");
const di_config = @import("di_config.zig");
const composer = @import("composer.zig");
const framework_stubs = @import("framework_stubs.zig");

const SymbolTable = symbol_table.SymbolTable;
const ResolvedView = symbol_table.ResolvedView;
const FileContext = types.FileContext;
const ProjectConfig = types.ProjectConfig;
const CallAnalyzer = call_analyzer.CallAnalyzer;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const SymbolCollector = symbol_collector.SymbolCollector;

// Function defined in the compiled C files (tree-sitter-php grammar).
extern fn tree_sitter_php() callconv(.c) *ts.Language;

const max_file_size = 1024 * 1024 * 10;

// ============================================================================
// FileUnit — Tier-1 per-file parse cache
// ============================================================================
//
// Holds the cached parse of one file: its source bytes and the live tree-sitter
// `Tree`. Parsing is the dominant cost, so keeping the tree alive lets the
// wholesale derived rebuild re-walk it (for symbol collection AND call analysis)
// without re-parsing. On change, the tree is destroyed, the arena reset, and the
// file re-read + re-parsed in isolation.
//
// Ownership: `path` is the index-owned (gpa) hash-map key and is NOT in `arena`
// (so it survives an arena reset). `source` lives in `arena`. The `Tree` is a C
// resource and must be `.destroy()`-ed explicitly.
pub const FileUnit = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8, // borrowed: the gpa-owned files-map key
    source: []const u8, // in arena
    tree: *ts.Tree,
    mtime: i96,
    size: u64,
};

// ============================================================================
// ProjectIndex
// ============================================================================
//
// The in-memory analysis backbone shared by the CLI and the MCP server. It keeps
// a persistent two-tier cache:
//
//   Tier-1 (per file, expensive): file I/O + tree-sitter parse, cached in
//     `files` as `FileUnit`s. Only changed files are re-read/re-parsed.
//   Tier-2 (global join): the symbol table, inheritance/trait `ResolvedView`,
//     and call graph, rebuilt WHOLESALE from the cached trees on every change
//     (correct by construction — no stale cross-file edges). All Tier-2 state
//     lives in `derived_arena`, which is reset on each rebuild.
//
// Determinism: collection and call analysis iterate `file_order` (a sorted view
// of the file set) so duplicate-FQCN "last writer wins" and order-sensitive
// property inference are reproducible — a prerequisite for the
// `incremental == from-scratch` differential guarantee.
//
// Lifetime notes:
//   - The index lives behind a pointer (stable addresses for `sym_table` etc.,
//     which `ProjectCallGraph`/`FileContext` reference).
//   - `project_configs` is borrowed and must outlive the index.
//   - Persistent derived strings/pointers live in `derived_arena` or borrow the
//     stable `FileUnit.path`/`FileUnit.source`; call edges may borrow `source`,
//     which is safe because the call graph is regenerated wholesale on any change
//     while unchanged sources persist.
pub const ProjectIndex = struct {
    gpa: std.mem.Allocator,
    parser: *ts.Parser,
    project_configs: []ProjectConfig, // borrowed

    // Tier-1 cache.
    files: std.StringHashMap(*FileUnit), // keys are gpa-owned
    file_order: [][]const u8, // sorted, gpa-owned slice of borrowed keys
    di_yaml: std.StringHashMap([]const u8), // services.yaml path -> content (gpa-owned key+value)

    // Tier-2 derived state (all in derived_arena, rebuilt wholesale).
    derived_arena: std.heap.ArenaAllocator,
    sym_table: SymbolTable,
    file_contexts: std.StringHashMap(FileContext),
    file_sources: std.StringHashMap([]const u8), // path -> source (borrowed), for plugins
    call_graph: ProjectCallGraph,
    resolved: ?*ResolvedView, // own arena; null only mid-rebuild

    // When true, `buildDerived` injects the framework API stub catalog
    // (Shopware/Symfony/Doctrine/PSR) into the symbol table so vendor-only
    // symbols resolve. Real project loads enable this; the pure in-memory
    // call-graph unit tests disable it to keep symbol counts deterministic.
    register_stubs: bool,

    // ------------------------------------------------------------------------
    // Construction / teardown
    // ------------------------------------------------------------------------

    /// Build a fresh index by reading + parsing every file once, then doing one
    /// wholesale derived build. Caller owns the result and must call `destroy`.
    pub fn create(
        gpa: std.mem.Allocator,
        files: []const []const u8,
        project_configs: []ProjectConfig,
    ) !*ProjectIndex {
        const self = try initShell(gpa, project_configs);
        errdefer self.destroy();

        for (files) |path| {
            self.addFileFromDisk(path) catch continue; // skip unreadable/unparseable
        }
        self.discoverDiConfigs() catch {}; // DI configs are best-effort
        try self.rebuildFileOrder();
        try self.buildDerived();
        return self;
    }

    fn initShell(gpa: std.mem.Allocator, project_configs: []ProjectConfig) !*ProjectIndex {
        const self = try gpa.create(ProjectIndex);
        errdefer gpa.destroy(self);

        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(tree_sitter_php());

        self.* = .{
            .gpa = gpa,
            .parser = parser,
            .project_configs = project_configs,
            .files = std.StringHashMap(*FileUnit).init(gpa),
            .file_order = &.{},
            .di_yaml = std.StringHashMap([]const u8).init(gpa),
            .derived_arena = .init(gpa),
            .sym_table = undefined,
            .file_contexts = undefined,
            .file_sources = undefined,
            .call_graph = undefined,
            .resolved = null,
            .register_stubs = true,
        };
        return self;
    }

    pub fn destroy(self: *ProjectIndex) void {
        const gpa = self.gpa;
        if (self.resolved) |v| v.destroy();

        var it = self.files.iterator();
        while (it.next()) |entry| {
            const unit = entry.value_ptr.*;
            unit.tree.destroy();
            unit.arena.deinit();
            gpa.destroy(unit);
            gpa.free(entry.key_ptr.*); // same slice as unit.path
        }
        self.files.deinit();
        if (self.file_order.len > 0) gpa.free(self.file_order);

        var yit = self.di_yaml.iterator();
        while (yit.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.di_yaml.deinit();

        self.derived_arena.deinit();
        self.parser.destroy();
        gpa.destroy(self);
    }

    // ------------------------------------------------------------------------
    // Incremental updates
    // ------------------------------------------------------------------------

    /// Reconcile the cached file set against a freshly-discovered `new_files`
    /// list: drop removed files, add new ones, and re-parse changed ones (by
    /// mtime+size). Rebuilds the derived state only if anything changed. Use for
    /// explicit reloads where files may have been added/deleted.
    pub fn refresh(self: *ProjectIndex, new_files: []const []const u8) !bool {
        var wanted = std.StringHashMap(void).init(self.gpa);
        defer wanted.deinit();
        for (new_files) |p| try wanted.put(p, {});

        var changed = false;

        // Remove files no longer present (collect first; don't mutate while iterating).
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.gpa);
        var it = self.files.keyIterator();
        while (it.next()) |k| {
            if (!wanted.contains(k.*)) try to_remove.append(self.gpa, k.*);
        }
        for (to_remove.items) |path| {
            self.removeFile(path);
            changed = true;
        }

        // Add new files and re-parse changed ones.
        for (new_files) |path| {
            if (self.files.get(path)) |unit| {
                const st = std.Io.Dir.cwd().statFile(types.io, path, .{}) catch {
                    self.removeFile(path);
                    changed = true;
                    continue;
                };
                if (st.mtime.nanoseconds != unit.mtime or st.size != unit.size) {
                    self.reparseUnit(unit) catch {
                        self.removeFile(path);
                        changed = true;
                        continue;
                    };
                    changed = true;
                }
            } else {
                const before = self.files.count();
                self.addFileFromDisk(path) catch continue;
                if (self.files.count() != before) changed = true;
            }
        }

        if (changed) {
            try self.rebuildFileOrder();
            try self.buildDerived();
        }
        return changed;
    }

    /// Poll mtimes of the currently-cached files and re-parse any that changed
    /// (or drop any that vanished). Does not discover newly-added files — use
    /// `refresh` for structural changes. Rebuilds derived state if anything
    /// changed. Cheap enough to call before serving a query.
    pub fn pollEdits(self: *ProjectIndex) !bool {
        var changed = false;
        var structural = false;
        for (self.file_order) |path| {
            const unit = self.files.get(path) orelse continue;
            const st = std.Io.Dir.cwd().statFile(types.io, path, .{}) catch {
                self.removeFile(path);
                changed = true;
                structural = true;
                continue;
            };
            if (st.mtime.nanoseconds != unit.mtime or st.size != unit.size) {
                self.reparseUnit(unit) catch {
                    self.removeFile(path);
                    structural = true;
                };
                changed = true;
            }
        }
        if (structural) try self.rebuildFileOrder();
        if (changed) try self.buildDerived();
        return changed;
    }

    // ------------------------------------------------------------------------
    // Tier-1 file cache management
    // ------------------------------------------------------------------------

    fn addFileFromDisk(self: *ProjectIndex, path: []const u8) !void {
        if (self.files.contains(path)) return;

        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);

        const unit = try self.gpa.create(FileUnit);
        errdefer self.gpa.destroy(unit);

        unit.* = .{
            .arena = .init(self.gpa),
            .path = key,
            .source = "",
            .tree = undefined,
            .mtime = 0,
            .size = 0,
        };
        errdefer unit.arena.deinit();

        try self.loadUnitFromDisk(unit);
        errdefer unit.tree.destroy();

        try self.files.put(key, unit);
    }

    fn removeFile(self: *ProjectIndex, path: []const u8) void {
        if (self.files.fetchRemove(path)) |kv| {
            const unit = kv.value;
            unit.tree.destroy();
            unit.arena.deinit();
            self.gpa.destroy(unit);
            self.gpa.free(kv.key); // same slice as unit.path
        }
    }

    /// Read + parse a unit's source from disk and record its mtime/size.
    fn loadUnitFromDisk(self: *ProjectIndex, unit: *FileUnit) !void {
        const a = unit.arena.allocator();
        const source = try std.Io.Dir.cwd().readFileAlloc(types.io, unit.path, a, .limited(max_file_size));
        const st = try std.Io.Dir.cwd().statFile(types.io, unit.path, .{});
        try self.setUnitSourceOwned(unit, source);
        unit.mtime = st.mtime.nanoseconds;
        unit.size = st.size;
    }

    fn reparseUnit(self: *ProjectIndex, unit: *FileUnit) !void {
        unit.tree.destroy();
        _ = unit.arena.reset(.retain_capacity); // path is gpa-owned, unaffected
        try self.loadUnitFromDisk(unit);
    }

    /// Parse `source` (already owned by `unit.arena`) into a fresh tree.
    fn setUnitSourceOwned(self: *ProjectIndex, unit: *FileUnit, source: []const u8) !void {
        const tree = self.parser.parseString(source, null) orelse return error.ParseFailed;
        unit.source = source;
        unit.tree = tree;
    }

    fn rebuildFileOrder(self: *ProjectIndex) !void {
        const list = try self.gpa.alloc([]const u8, self.files.count());
        var i: usize = 0;
        var it = self.files.keyIterator();
        while (it.next()) |k| : (i += 1) list[i] = k.*;
        std.mem.sort([]const u8, list, {}, lessThanStr);
        if (self.file_order.len > 0) self.gpa.free(self.file_order);
        self.file_order = list;
    }

    // ------------------------------------------------------------------------
    // Tier-2 wholesale derived build
    // ------------------------------------------------------------------------

    /// Rebuild all derived state (symbol table, resolved view, call graph) from
    /// the cached trees. Wholesale and deterministic; never re-parses.
    fn buildDerived(self: *ProjectIndex) !void {
        // Tear down previous derived state before resetting its arena.
        if (self.resolved) |v| {
            v.destroy();
            self.resolved = null;
        }
        _ = self.derived_arena.reset(.retain_capacity);
        const a = self.derived_arena.allocator();

        self.sym_table = SymbolTable.init(a);
        self.file_contexts = std.StringHashMap(FileContext).init(a);
        self.file_sources = std.StringHashMap([]const u8).init(a);

        // Pass A: collect raw symbols from cached trees (deterministic order).
        for (self.file_order) |path| {
            const unit = self.files.get(path) orelse continue;

            var file_ctx = FileContext.init(a, unit.path);
            for (self.project_configs) |*cfg| {
                if (std.mem.startsWith(u8, unit.path, cfg.root_path)) {
                    file_ctx.project_config = cfg;
                    break;
                }
            }

            var collector = SymbolCollector.init(a, &self.sym_table, &file_ctx, unit.source);
            collector.collect(unit.tree) catch {};

            try self.file_contexts.put(unit.path, file_ctx);
            try self.file_sources.put(unit.path, unit.source);
        }

        // Pass A2: inject framework API stubs (Shopware/Symfony/Doctrine) into
        // the raw symbol table BEFORE any inheritance/resolution pass, so both
        // the Tier-2 ResolvedView and the legacy `all_methods` view (and call
        // analysis) see the same world. Only registers classes/interfaces that
        // user/vendor code did not already define. Allocated in `derived_arena`
        // so it is reclaimed on every wholesale rebuild.
        if (self.register_stubs) {
            try framework_stubs.registerFrameworkStubs(a, &self.sym_table);
        }

        // Pass B: resolve inheritance/traits (Tier-2 view, never mutates raw).
        self.resolved = try ResolvedView.build(self.gpa, &self.sym_table);
        self.sym_table.resolved = self.resolved;

        // Pass B2: fold DI config (services.yaml) interface->concrete bindings
        // into the resolved view BEFORE call analysis so interface-typed calls
        // resolve to the container-injected concrete (Phase B DI-aware
        // resolution).
        try self.loadDiBindings(a);

        // Pass B3: populate the legacy Tier-2 inheritance view
        // (ClassSymbol.all_methods/all_properties). The local MCP path uses
        // ResolvedView, but the origin analyzers (dead_code, type/return/null
        // checks, boundary, report) read all_methods/all_properties directly.
        // Building both here lets one index feed both the MCP tools and the
        // CLI. Idempotent and arena-backed.
        try self.sym_table.resolveInheritance();

        // Pass C: type-directed call analysis over cached trees (deterministic).
        self.call_graph = ProjectCallGraph.init(a, &self.sym_table);
        for (self.file_order) |path| {
            const unit = self.files.get(path) orelse continue;
            const file_ctx_ptr = self.file_contexts.getPtr(unit.path) orelse continue;
            var analyzer = CallAnalyzer.init(a, &self.sym_table, file_ctx_ptr);
            defer analyzer.deinit();
            analyzer.analyzeFile(unit.tree, unit.source, unit.path) catch continue;
            try self.call_graph.addCalls(&analyzer);
        }

        // Pass D: run enabled plugins, folding their synthetic edges into the
        // call graph. Running here (rather than as a separate post-step) means
        // plugin edges are regenerated on every rebuild, so incremental reloads
        // stay byte-identical to from-scratch builds.
        try self.runPlugins(a);
    }

    /// Collect the active plugin set from every project config (union, sorted
    /// for determinism) and apply each plugin's synthetic edges to the call
    /// graph. Plugins observe only the real (non-synthetic) calls: edges are
    /// collected first and appended afterwards, so plugins never react to one
    /// another's output and the result is order-independent.
    fn runPlugins(self: *ProjectIndex, a: std.mem.Allocator) !void {
        // Build the deduplicated, sorted set of enabled plugin names.
        var enabled = std.StringHashMap(void).init(a);
        for (self.project_configs) |cfg| {
            for (cfg.plugins) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len == 0) continue;
                try enabled.put(trimmed, {});
            }
        }
        if (enabled.count() == 0) return;

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = enabled.keyIterator();
        while (it.next()) |k| try names.append(a, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThanStr);

        // Snapshot of the real calls; stable for the whole loop because we defer
        // all appends until after every plugin has run.
        const base_calls = self.call_graph.calls.items;

        var all_edges: std.ArrayListUnmanaged(plugin_interface.SyntheticEdge) = .empty;
        for (names.items) |name| {
            const plugin = plugin_registry.getPlugin(name) orelse continue;
            const ctx = plugin_interface.PluginContext{
                .allocator = a,
                .sym_table = &self.sym_table,
                .calls = base_calls,
                .file_sources = &self.file_sources,
                .project_configs = self.project_configs,
            };
            const edges = plugin.analyze(&ctx) catch continue;
            try all_edges.appendSlice(a, edges);
        }

        for (all_edges.items) |edge| {
            try self.call_graph.addSyntheticEdge(
                edge.caller_fqn,
                edge.callee_fqn,
                edge.file_path,
                edge.line,
                edge.confidence,
            );
        }
    }

    /// Parse every cached DI config (services.yaml) and register its global
    /// interface->concrete bindings into the resolved view. Parsed in sorted
    /// path order for determinism; a later file's binding for the same interface
    /// overrides an earlier one. Bindings to classes not in-project are dropped
    /// by `addExplicitBinding`. Parse uses `a` (derived arena) for scratch;
    /// `addExplicitBinding` dups the kept strings into the view's own arena.
    fn loadDiBindings(self: *ProjectIndex, a: std.mem.Allocator) !void {
        const view = self.resolved orelse return;
        if (self.di_yaml.count() == 0) return;

        // Deterministic order: sort the config paths.
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = self.di_yaml.keyIterator();
        while (it.next()) |k| try paths.append(a, k.*);
        std.mem.sort([]const u8, paths.items, {}, lessThanStr);

        for (paths.items) |path| {
            const content = self.di_yaml.get(path) orelse continue;
            const bindings = di_config.parseServicesYaml(a, content) catch continue;
            for (bindings) |b| {
                view.addExplicitBinding(b.interface_fqcn, b.concrete_fqcn) catch {};
            }
        }
    }

    /// Discover Symfony DI config files (`services.yaml`/`services.yml`) under
    /// each project root and cache their contents in `di_yaml`. Bounded, skips
    /// vendor/.git/node_modules, and tolerates unreadable files. Called once on
    /// a full disk build (in-memory test builds inject yaml via `addInMemory`).
    pub fn discoverDiConfigs(self: *ProjectIndex) !void {
        for (self.project_configs) |*cfg| {
            if (cfg.root_path.len == 0) continue;
            collectDiConfigsInDir(self, cfg.root_path, 0) catch continue;
        }
    }

    fn collectDiConfigsInDir(self: *ProjectIndex, dir_path: []const u8, depth: u32) !void {
        if (depth > 50) return;
        var dir = std.Io.Dir.openDirAbsolute(types.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(types.io);

        var it = dir.iterate();
        while (try it.next(types.io)) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, "vendor") or
                    std.mem.eql(u8, entry.name, ".git") or
                    std.mem.eql(u8, entry.name, "node_modules") or
                    std.mem.eql(u8, entry.name, "var"))
                {
                    continue;
                }
                const sub = try std.fs.path.join(self.gpa, &.{ dir_path, entry.name });
                defer self.gpa.free(sub);
                try collectDiConfigsInDir(self, sub, depth + 1);
            } else if (entry.kind == .file) {
                if (!std.mem.eql(u8, entry.name, "services.yaml") and
                    !std.mem.eql(u8, entry.name, "services.yml"))
                {
                    continue;
                }
                const full = try std.fs.path.join(self.gpa, &.{ dir_path, entry.name });
                errdefer self.gpa.free(full);
                if (self.di_yaml.contains(full)) {
                    self.gpa.free(full);
                    continue;
                }
                const content = std.Io.Dir.cwd().readFileAlloc(
                    types.io,
                    full,
                    self.gpa,
                    .limited(max_file_size),
                ) catch {
                    self.gpa.free(full);
                    continue;
                };
                try self.di_yaml.put(full, content);
            }
        }
    }

    /// Find all non-call references to `target_fqcn` across the project: type
    /// hints, `new`, `extends`/`implements`, `::class`/static refs, `use`
    /// imports, and exact-FQN string literals. FQN-scoped, so a sibling-
    /// namespace class with the same short name is never matched. Results are
    /// allocated with `allocator` (caller owns) and ordered by file then line.
    pub fn collectReferences(
        self: *ProjectIndex,
        allocator: std.mem.Allocator,
        target_fqcn: []const u8,
    ) ![]references.Reference {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        var out: std.ArrayListUnmanaged(references.Reference) = .empty;
        for (self.file_order) |path| {
            const unit = self.files.get(path) orelse continue;
            const file_ctx = self.file_contexts.getPtr(path) orelse continue;
            try references.collectFile(
                allocator,
                scratch.allocator(),
                unit.tree,
                unit.source,
                file_ctx,
                unit.path,
                target_fqcn,
                &out,
            );
        }
        std.mem.sort(references.Reference, out.items, {}, refLessThan);
        return out.toOwnedSlice(allocator);
    }
};

fn refLessThan(_: void, a: references.Reference, b: references.Reference) bool {
    const c = std.mem.order(u8, a.file_path, b.file_path);
    if (c != .eq) return c == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ============================================================================
// Tests
// ============================================================================
//
// The differential gate: an incremental rebuild (edit a file, re-parse only it,
// rebuild derived) must produce byte-identical analysis to a from-scratch build
// of the mutated file set. We exercise this purely in-memory — parsing/collection
// /resolution/call-analysis need no I/O — so the test is hermetic and fast.

const testing = std.testing;

/// Test-only: build an index from in-memory (path, source) pairs without disk.
/// Exposed for cross-module tests (e.g. `query.zig`).
pub fn createInMemoryForTest(gpa: std.mem.Allocator, sources: []const [2][]const u8) !*ProjectIndex {
    return createInMemory(gpa, sources);
}

/// Test-only: like `createInMemoryForTest` but with caller-supplied project
/// configs (borrowed; must outlive the index). Lets boundary/cross-project tests
/// place files into distinct projects via each config's `root_path`.
pub fn createInMemoryWithConfigsForTest(
    gpa: std.mem.Allocator,
    sources: []const [2][]const u8,
    configs: []ProjectConfig,
) !*ProjectIndex {
    const self = try ProjectIndex.initShell(gpa, configs);
    errdefer self.destroy();
    self.register_stubs = false; // pure call-graph tests: no framework noise
    for (sources) |pair| {
        try addInMemory(self, pair[0], pair[1]);
    }
    try self.rebuildFileOrder();
    try self.buildDerived();
    return self;
}

/// Test-only: build an index from in-memory (path, source) pairs without disk.
fn createInMemory(gpa: std.mem.Allocator, sources: []const [2][]const u8) !*ProjectIndex {
    const self = try ProjectIndex.initShell(gpa, &.{});
    errdefer self.destroy();
    self.register_stubs = false; // pure call-graph tests: no framework noise
    for (sources) |pair| {
        try addInMemory(self, pair[0], pair[1]);
    }
    try self.rebuildFileOrder();
    try self.buildDerived();
    return self;
}

/// Test-only: add a file with in-memory source (no disk, no io, mtime=0). A
/// `.yaml`/`.yml` path is cached as a DI config instead of being parsed as PHP,
/// so DI-aware resolution can be exercised without disk.
fn addInMemory(self: *ProjectIndex, path: []const u8, source: []const u8) !void {
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) {
        const k = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(k);
        const v = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(v);
        try self.di_yaml.put(k, v);
        return;
    }
    const key = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(key);
    const unit = try self.gpa.create(FileUnit);
    errdefer self.gpa.destroy(unit);
    unit.* = .{ .arena = .init(self.gpa), .path = key, .source = "", .tree = undefined, .mtime = 0, .size = 0 };
    errdefer unit.arena.deinit();
    const owned = try unit.arena.allocator().dupe(u8, source);
    try self.setUnitSourceOwned(unit, owned);
    errdefer unit.tree.destroy();
    try self.files.put(key, unit);
}

/// Test-only: simulate an edit by re-parsing a unit from a new in-memory source.
fn editInMemory(self: *ProjectIndex, path: []const u8, source: []const u8) !void {
    const unit = self.files.get(path).?;
    unit.tree.destroy();
    _ = unit.arena.reset(.retain_capacity);
    const owned = try unit.arena.allocator().dupe(u8, source);
    try self.setUnitSourceOwned(unit, owned);
}

/// Produce a deterministic, content-based snapshot of the analysis result so two
/// indexes can be compared for equivalence regardless of pointer/iteration order.
fn canonicalize(gpa: std.mem.Allocator, index: *ProjectIndex) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Classes + their resolved (inherited) methods, sorted.
    var class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer class_names.deinit(gpa);
    var cit = index.sym_table.classes.keyIterator();
    while (cit.next()) |k| try class_names.append(gpa, k.*);
    std.mem.sort([]const u8, class_names.items, {}, lessThanStr);

    try buf.appendSlice(gpa, "== classes ==\n");
    for (class_names.items) |fqcn| {
        try buf.print(gpa, "{s}\n", .{fqcn});
        if (index.resolved.?.getClass(fqcn)) |rc| {
            var methods: std.ArrayListUnmanaged([]const u8) = .empty;
            defer methods.deinit(gpa);
            var mit = rc.all_methods.keyIterator();
            while (mit.next()) |m| try methods.append(gpa, m.*);
            std.mem.sort([]const u8, methods.items, {}, lessThanStr);
            for (methods.items) |m| {
                const ms = rc.all_methods.get(m).?;
                try buf.print(gpa, "  m {s} <- {s}\n", .{ m, ms.containing_class });
            }
        }
    }

    // Call edges, sorted by a canonical tuple.
    try buf.appendSlice(gpa, "== edges ==\n");
    var edges: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (edges.items) |e| gpa.free(e);
        edges.deinit(gpa);
    }
    for (index.call_graph.calls.items) |c| {
        // Compact, deterministic rendering of the captured argument types so the
        // type-aware `impact` fields are covered by the differential guarantee.
        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(gpa);
        for (c.arg_types, 0..) |maybe_t, i| {
            if (i != 0) try args_buf.append(gpa, ',');
            if (maybe_t) |t| {
                const ts_text = try t.format(gpa);
                defer gpa.free(ts_text);
                try args_buf.appendSlice(gpa, ts_text);
            } else {
                try args_buf.append(gpa, '?');
            }
        }
        const line = try std.fmt.allocPrint(gpa, "{s} -> {s} [{s}] {s}:{d} conf={d:.3} ru={s} args=[{s}]", .{
            c.caller_fqn,
            if (c.resolved_target) |t| t else c.callee_name,
            @tagName(c.resolution_method),
            c.file_path,
            c.line,
            c.resolution_confidence,
            @tagName(c.result_used),
            args_buf.items,
        });
        try edges.append(gpa, line);
    }
    std.mem.sort([]u8, edges.items, {}, lessThanU8);
    for (edges.items) |e| try buf.print(gpa, "{s}\n", .{e});

    return buf.toOwnedSlice(gpa);
}

fn lessThanU8(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "incremental == from-scratch (edit a base class)" {
    const gpa = testing.allocator;

    const base_v1 =
        \\<?php
        \\namespace App;
        \\class Base {
        \\    public function init() { $this->setup(); }
        \\    public function setup() {}
        \\}
    ;
    const base_v2 =
        \\<?php
        \\namespace App;
        \\class Base {
        \\    public function init() { $this->setup(); $this->extra(); }
        \\    public function setup() {}
        \\    public function extra() {}
        \\}
    ;
    const child =
        \\<?php
        \\namespace App;
        \\class Child extends Base {
        \\    public function run() { $this->init(); }
        \\}
    ;
    const trait_file =
        \\<?php
        \\namespace App;
        \\trait Logs { public function log() {} }
        \\class Service { use Logs; public function go() { $this->log(); } }
    ;

    // Incremental: build v1, then edit Base -> v2, re-parse only Base, rebuild.
    var incremental = try createInMemory(gpa, &.{
        .{ "App/Base.php", base_v1 },
        .{ "App/Child.php", child },
        .{ "App/Service.php", trait_file },
    });
    defer incremental.destroy();
    try editInMemory(incremental, "App/Base.php", base_v2);
    try incremental.rebuildFileOrder();
    try incremental.buildDerived();

    // From-scratch: build the mutated file set directly.
    var scratch = try createInMemory(gpa, &.{
        .{ "App/Base.php", base_v2 },
        .{ "App/Child.php", child },
        .{ "App/Service.php", trait_file },
    });
    defer scratch.destroy();

    const a = try canonicalize(gpa, incremental);
    defer gpa.free(a);
    const b = try canonicalize(gpa, scratch);
    defer gpa.free(b);

    try testing.expectEqualStrings(b, a);

    // Sanity: the edit actually took effect (Child sees inherited extra()).
    try testing.expect(incremental.resolved.?.resolveMethod("App\\Child", "extra") != null);
}

test "incremental == from-scratch (add and remove a file)" {
    const gpa = testing.allocator;

    const a_php =
        \\<?php
        \\namespace App;
        \\class A { public function a() {} }
    ;
    const b_php =
        \\<?php
        \\namespace App;
        \\class B extends A { public function b() { $this->a(); } }
    ;
    const c_php =
        \\<?php
        \\namespace App;
        \\class C { public function c() {} }
    ;

    // Incremental: start with A+C, drop C, add B (which extends A).
    var incremental = try createInMemory(gpa, &.{
        .{ "App/A.php", a_php },
        .{ "App/C.php", c_php },
    });
    defer incremental.destroy();
    incremental.removeFile("App/C.php");
    try addInMemory(incremental, "App/B.php", b_php);
    try incremental.rebuildFileOrder();
    try incremental.buildDerived();

    // From-scratch with the final file set.
    var scratch = try createInMemory(gpa, &.{
        .{ "App/A.php", a_php },
        .{ "App/B.php", b_php },
    });
    defer scratch.destroy();

    const x = try canonicalize(gpa, incremental);
    defer gpa.free(x);
    const y = try canonicalize(gpa, scratch);
    defer gpa.free(y);

    try testing.expectEqualStrings(y, x);
    try testing.expect(incremental.sym_table.getClass("App\\C") == null);
    try testing.expect(incremental.sym_table.getClass("App\\B") != null);
}

const FoundCall = struct {
    resolved_target: ?[]const u8,
    resolution_method: types.ResolutionMethod,
    resolution_confidence: f32,
};

/// Test helper: find the resolved target + resolution method of the call from
/// `caller` to a method named `callee_short`. Returns null if absent.
fn findCall(index: *ProjectIndex, caller: []const u8, callee_short: []const u8) ?FoundCall {
    for (index.call_graph.calls.items) |c| {
        if (std.mem.eql(u8, c.caller_fqn, caller) and std.mem.eql(u8, c.callee_name, callee_short)) {
            return .{
                .resolved_target = c.resolved_target,
                .resolution_method = c.resolution_method,
                .resolution_confidence = c.resolution_confidence,
            };
        }
    }
    return null;
}

test "impact: argument types and result use captured at call sites" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/User.php",
            \\<?php
            \\namespace App;
            \\class User {}
        },
        .{ "App/Repo.php",
            \\<?php
            \\namespace App;
            \\class Repo {
            \\    public function save(User $u): User { return $u; }
            \\    public function name(): string { return "x"; }
            \\}
        },
        .{ "App/Client.php",
            \\<?php
            \\namespace App;
            \\class Client {
            \\    public function run(Repo $r, User $u): void {
            \\        $saved = $r->save($u);
            \\        $r->save($u)->name();
            \\    }
            \\}
        },
    });
    defer index.destroy();

    // Find both `save` calls from Client::run.
    var assigned_ok = false;
    var deref_ok = false;
    for (index.call_graph.calls.items) |c| {
        if (!std.mem.eql(u8, c.caller_fqn, "App\\Client::run")) continue;
        if (!std.mem.eql(u8, c.callee_name, "save")) continue;
        // The single positional arg `$u` resolves to App\User.
        try testing.expectEqual(@as(usize, 1), c.arg_types.len);
        try testing.expect(c.arg_types[0] != null);
        try testing.expectEqualStrings("App\\User", c.arg_types[0].?.base_type);
        switch (c.result_used) {
            .assigned => assigned_ok = true, // $saved = $r->save($u)
            .member_access => deref_ok = true, // $r->save($u)->name()
            else => {},
        }
    }
    try testing.expect(assigned_ok);
    try testing.expect(deref_ok);
}

test "DI-aware: interface-typed property resolves to single implementor" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/NotifierInterface.php",
            \\<?php
            \\namespace App;
            \\interface NotifierInterface { public function send(string $m): void; }
        },
        .{ "App/EmailNotifier.php",
            \\<?php
            \\namespace App;
            \\class EmailNotifier implements NotifierInterface {
            \\    public function send(string $m): void {}
            \\}
        },
        .{ "App/SignupService.php",
            \\<?php
            \\namespace App;
            \\class SignupService {
            \\    public function __construct(private readonly NotifierInterface $notifier) {}
            \\    public function register(): void { $this->notifier->send('hi'); }
            \\}
        },
    });
    defer index.destroy();

    // The single implementor exists in the interface index.
    try testing.expect(index.resolved.?.singleImplementor("App\\NotifierInterface") != null);
    try testing.expectEqualStrings("App\\EmailNotifier", index.resolved.?.singleImplementor("App\\NotifierInterface").?);

    // The interface-typed call resolves to the concrete implementor, tagged
    // distinctly so callers can see it was DI-bound (not exact).
    const call = findCall(index, "App\\SignupService::register", "send") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\EmailNotifier::send", call.resolved_target.?);
    try testing.expectEqual(types.ResolutionMethod.interface_single_impl, call.resolution_method);
}

test "interface with two implementors resolves to the interface contract" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/NotifierInterface.php",
            \\<?php
            \\namespace App;
            \\interface NotifierInterface { public function send(string $m): void; }
        },
        .{ "App/EmailNotifier.php",
            \\<?php
            \\namespace App;
            \\class EmailNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SmsNotifier.php",
            \\<?php
            \\namespace App;
            \\class SmsNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SignupService.php",
            \\<?php
            \\namespace App;
            \\class SignupService {
            \\    public function __construct(private readonly NotifierInterface $notifier) {}
            \\    public function register(): void { $this->notifier->send('hi'); }
            \\}
        },
    });
    defer index.destroy();

    // Two implementors -> ambiguous -> not in the single-implementor index.
    try testing.expect(index.resolved.?.singleImplementor("App\\NotifierInterface") == null);

    // With no single implementor and no DI binding, the call resolves to the
    // interface's own (abstract) contract method rather than being falsely
    // bound to either concrete class.
    const call = findCall(index, "App\\SignupService::register", "send") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\NotifierInterface::send", call.resolved_target.?);
    try testing.expectEqual(types.ResolutionMethod.interface_contract, call.resolution_method);
}

test "DI-aware Phase B: services.yaml binding resolves a multi-implementor interface" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/NotifierInterface.php",
            \\<?php
            \\namespace App;
            \\interface NotifierInterface { public function send(string $m): void; }
        },
        .{ "App/EmailNotifier.php",
            \\<?php
            \\namespace App;
            \\class EmailNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SmsNotifier.php",
            \\<?php
            \\namespace App;
            \\class SmsNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SignupService.php",
            \\<?php
            \\namespace App;
            \\class SignupService {
            \\    public function __construct(private readonly NotifierInterface $notifier) {}
            \\    public function register(): void { $this->notifier->send('hi'); }
            \\}
        },
        // The container binds the (ambiguous) interface to SmsNotifier.
        .{ "config/services.yaml",
            \\services:
            \\    App\NotifierInterface: '@App\SmsNotifier'
        },
    });
    defer index.destroy();

    // The explicit binding is recorded and wins over the (absent) single-impl.
    try testing.expectEqualStrings("App\\SmsNotifier", index.resolved.?.explicitImplementor("App\\NotifierInterface").?);
    try testing.expect(index.resolved.?.singleImplementor("App\\NotifierInterface") == null);

    // The interface-typed call resolves to the DI-bound concrete, tagged
    // `di_config_binding` so callers can see it came from container config.
    const call = findCall(index, "App\\SignupService::register", "send") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\SmsNotifier::send", call.resolved_target.?);
    try testing.expectEqual(types.ResolutionMethod.di_config_binding, call.resolution_method);
}

test "DI-aware Phase B: explicit binding overrides the single implementor" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/NotifierInterface.php",
            \\<?php
            \\namespace App;
            \\interface NotifierInterface { public function send(string $m): void; }
        },
        // Two implementors: EmailNotifier (the would-be sole impl if SmsNotifier
        // weren't present) and SmsNotifier. The binding picks SmsNotifier.
        .{ "App/EmailNotifier.php",
            \\<?php
            \\namespace App;
            \\class EmailNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SmsNotifier.php",
            \\<?php
            \\namespace App;
            \\class SmsNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SignupService.php",
            \\<?php
            \\namespace App;
            \\class SignupService {
            \\    public function __construct(private readonly NotifierInterface $notifier) {}
            \\    public function register(): void { $this->notifier->send('hi'); }
            \\}
        },
        .{ "config/services.yaml",
            \\services:
            \\    _defaults:
            \\        bind:
            \\            App\NotifierInterface: '@App\SmsNotifier'
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\SignupService::register", "send") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\SmsNotifier::send", call.resolved_target.?);
    try testing.expectEqual(types.ResolutionMethod.di_config_binding, call.resolution_method);
}

test "DI-aware Phase B: binding to an unknown concrete is ignored" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/NotifierInterface.php",
            \\<?php
            \\namespace App;
            \\interface NotifierInterface { public function send(string $m): void; }
        },
        .{ "App/EmailNotifier.php",
            \\<?php
            \\namespace App;
            \\class EmailNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SmsNotifier.php",
            \\<?php
            \\namespace App;
            \\class SmsNotifier implements NotifierInterface { public function send(string $m): void {} }
        },
        .{ "App/SignupService.php",
            \\<?php
            \\namespace App;
            \\class SignupService {
            \\    public function __construct(private readonly NotifierInterface $notifier) {}
            \\    public function register(): void { $this->notifier->send('hi'); }
            \\}
        },
        // Concrete is not in-project; the binding must be dropped (no false edge).
        .{ "config/services.yaml",
            \\services:
            \\    App\NotifierInterface: '@App\Vendor\ExternalNotifier'
        },
    });
    defer index.destroy();

    try testing.expect(index.resolved.?.explicitImplementor("App\\NotifierInterface") == null);
    // The unknown-concrete binding is dropped, so the call is not falsely bound
    // to a concrete; it falls back to the interface's own contract method.
    const call = findCall(index, "App\\SignupService::register", "send") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\NotifierInterface::send", call.resolved_target.?);
    try testing.expectEqual(types.ResolutionMethod.interface_contract, call.resolution_method);
}

test "constructor-promoted property resolves a concrete method call" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Logger.php",
            \\<?php
            \\namespace App;
            \\class Logger { public function log(string $m): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function __construct(private readonly Logger $logger) {}
            \\    public function go(): void { $this->logger->log('x'); }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "log") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Logger::log", call.resolved_target.?);
    // Concrete (non-interface) resolution is full confidence.
    try testing.expectEqual(@as(f32, 1.0), call.resolution_confidence);
}

test "inline @var seeds a local's type so its method call resolves" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Logger.php",
            \\<?php
            \\namespace App;
            \\class Logger { public function log(string $m): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function go(): void {
            \\        /** @var Logger $logger */
            \\        $logger = $this->container->get('logger');
            \\        $logger->log('x');
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "log") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Logger::log", call.resolved_target.?);
}

test "inline @var with a fully-qualified name resolves" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Sub/Logger.php",
            \\<?php
            \\namespace App\Sub;
            \\class Logger { public function log(string $m): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function go(): void {
            \\        /** @var \App\Sub\Logger $logger */
            \\        $logger = make();
            \\        $logger->log('x');
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "log") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\Sub\\Logger::log", call.resolved_target.?);
}

test "native union/intersection/array member types resolve to FQCNs" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/User.php",
            \\<?php
            \\namespace App;
            \\class User {}
        },
        .{ "App/Admin.php",
            \\<?php
            \\namespace App;
            \\class Admin {}
        },
        .{ "App/Repo.php",
            \\<?php
            \\namespace App;
            \\use App\Other\Token;
            \\class Repo {
            \\    public User|Admin $cached;
            \\    public function find(User|Admin $u, Token $t): User|Admin {}
            \\}
        },
    });
    defer index.destroy();

    const repo = index.sym_table.getClass("App\\Repo") orelse return error.ClassMissing;

    // Property union type parts are FQCN-resolved (not short "User"/"Admin").
    const prop = repo.getProperty("cached") orelse return error.PropMissing;
    const pt = prop.declared_type orelse return error.NoType;
    try testing.expectEqual(types.TypeInfo.Kind.union_type, pt.kind);
    try testing.expectEqual(@as(usize, 2), pt.type_parts.len);
    try testing.expectEqualStrings("App\\User", pt.type_parts[0]);
    try testing.expectEqualStrings("App\\Admin", pt.type_parts[1]);

    // Return union type parts are likewise resolved.
    const m = repo.getMethod("find") orelse return error.MethodMissing;
    const rt = m.return_type orelse return error.NoReturn;
    try testing.expectEqual(types.TypeInfo.Kind.union_type, rt.kind);
    try testing.expectEqualStrings("App\\User", rt.type_parts[0]);
    try testing.expectEqualStrings("App\\Admin", rt.type_parts[1]);

    // A parameter typed via an imported alias resolves through the use table.
    const tok = m.getParameterType("t") orelse return error.NoParam;
    try testing.expectEqualStrings("App\\Other\\Token", tok.base_type);
}

test "inline @var naming a different variable does not mistype the LHS" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Logger.php",
            \\<?php
            \\namespace App;
            \\class Logger { public function log(string $m): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function go(): void {
            \\        /** @var Logger $other */
            \\        $logger = make();
            \\        $logger->log('x');
            \\    }
            \\}
        },
    });
    defer index.destroy();

    // The @var targets $other, not $logger, so $logger stays untyped -> no edge.
    const call = findCall(index, "App\\Service::go", "log") orelse return error.CallMissing;
    try testing.expect(call.resolved_target == null);
}

test "fluent self/static return keeps the chain typed" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Builder.php",
            \\<?php
            \\namespace App;
            \\class Builder {
            \\    public function withA(): self { return $this; }
            \\    public function withB(): static { return $this; }
            \\    public function build(): string { return ''; }
            \\}
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function go(): void {
            \\        $b = new Builder();
            \\        $b->withA()->withB()->build();
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "build") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Builder::build", call.resolved_target.?);
}

test "generic collection: @extends Base<Concrete> substitutes the element type" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Item.php",
            \\<?php
            \\namespace App;
            \\class Item { public function run(): void {} }
        },
        .{ "App/Collection.php",
            \\<?php
            \\namespace App;
            \\/**
            \\ * @template TElement
            \\ */
            \\class Collection {
            \\    /** @return TElement|null */
            \\    public function first() { return null; }
            \\}
        },
        .{ "App/ItemCollection.php",
            \\<?php
            \\namespace App;
            \\/**
            \\ * @extends Collection<Item>
            \\ */
            \\#[SomeAttribute]
            \\class ItemCollection extends Collection {}
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function __construct(private readonly ItemCollection $items) {}
            \\    public function go(): void {
            \\        $this->items->first()->run();
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "run") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Item::run", call.resolved_target.?);
}

test "generic collection: multi-level inheritance with template default resolves" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Entity.php",
            \\<?php
            \\namespace App;
            \\class Entity { public function id(): void {} }
        },
        .{ "App/Collection.php",
            \\<?php
            \\namespace App;
            \\/**
            \\ * @template TElement
            \\ * @template TKey of array-key = array-key
            \\ */
            \\class Collection {
            \\    /** @return TElement|null */
            \\    public function first() { return null; }
            \\}
        },
        .{ "App/EntityCollection.php",
            \\<?php
            \\namespace App;
            \\/**
            \\ * @template TElement of Entity
            \\ * @extends Collection<TElement, string>
            \\ */
            \\class EntityCollection extends Collection {}
        },
        .{ "App/ProductCollection.php",
            \\<?php
            \\namespace App;
            \\/**
            \\ * @template TElement of Entity = Entity
            \\ * @extends EntityCollection<TElement>
            \\ */
            \\class ProductCollection extends EntityCollection {}
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function __construct(private readonly ProductCollection $products) {}
            \\    public function go(): void {
            \\        $this->products->first()->id();
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "id") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Entity::id", call.resolved_target.?);
}

test "foreach over a @return Foo[] method binds the loop variable" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Item.php",
            \\<?php
            \\namespace App;
            \\class Item { public function run(): void {} }
        },
        .{ "App/Repo.php",
            \\<?php
            \\namespace App;
            \\class Repo {
            \\    /** @return Item[] */
            \\    public function all(): array { return []; }
            \\}
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function __construct(private readonly Repo $repo) {}
            \\    public function go(): void {
            \\        foreach ($this->repo->all() as $item) {
            \\            $item->run();
            \\        }
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "run") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Item::run", call.resolved_target.?);
}

test "foreach over an inline @var Foo[] local binds the loop variable" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Item.php",
            \\<?php
            \\namespace App;
            \\class Item { public function run(): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    public function go(): void {
            \\        /** @var Item[] $items */
            \\        $items = make();
            \\        foreach ($items as $item) {
            \\            $item->run();
            \\        }
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "run") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\Item::run", call.resolved_target.?);
}

test "foreach with key => value typing binds the value variable" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Item.php",
            \\<?php
            \\namespace App;
            \\class Item { public function run(): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    /** @return iterable<Item> */
            \\    public function items(): iterable { return []; }
            \\    public function go(): void {
            \\        foreach ($this->items() as $k => $item) {
            \\            $item->run();
            \\        }
            \\    }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "run") orelse return error.CallMissing;
    try testing.expectEqualStrings("App\\Item::run", call.resolved_target.?);
}

test "non-promoted ctor injection types an untyped property" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Logger.php",
            \\<?php
            \\namespace App;
            \\class Logger { public function log(string $m): void {} }
        },
        .{ "App/Service.php",
            \\<?php
            \\namespace App;
            \\class Service {
            \\    private $logger;
            \\    public function __construct(Logger $logger) { $this->logger = $logger; }
            \\    public function go(): void { $this->logger->log('x'); }
            \\}
        },
    });
    defer index.destroy();

    const call = findCall(index, "App\\Service::go", "log") orelse return error.CallMissing;
    try testing.expect(call.resolved_target != null);
    try testing.expectEqualStrings("App\\Logger::log", call.resolved_target.?);
}

/// Test helper: true if a plugin-generated (synthetic) edge `caller -> callee`
/// (callee given as a full FQN) exists in the graph.
fn hasSynthetic(index: *ProjectIndex, caller: []const u8, callee_fqn: []const u8) bool {
    for (index.call_graph.calls.items) |c| {
        if (c.resolution_method != .plugin_generated) continue;
        if (!std.mem.eql(u8, c.caller_fqn, caller)) continue;
        if (c.resolved_target) |t| {
            if (std.mem.eql(u8, t, callee_fqn)) return true;
        }
    }
    return false;
}

test "symfony-events: class-level #[AsMessageHandler(handles:, method:)]" {
    const gpa = testing.allocator;
    var cfg = types.ProjectConfig.init(gpa, "");
    defer cfg.deinit();
    cfg.plugins = &.{"symfony-events"};
    var configs = [_]types.ProjectConfig{cfg};

    var index = try createInMemoryWithConfigsForTest(gpa, &.{
        .{ "App/SendEmail.php",
            \\<?php
            \\namespace App;
            \\class SendEmail {}
        },
        .{ "App/Handler.php",
            \\<?php
            \\namespace App;
            \\#[AsMessageHandler(handles: SendEmail::class, method: 'handleIt')]
            \\class Handler { public function handleIt(SendEmail $m): void {} }
        },
        .{ "App/Producer.php",
            \\<?php
            \\namespace App;
            \\class Producer {
            \\    public function __construct(private readonly Bus $bus) {}
            \\    public function run(): void { $this->bus->dispatch(new SendEmail()); }
            \\}
        },
    }, &configs);
    defer index.destroy();

    // The class routes SendEmail to the named method `handleIt` (not __invoke).
    try testing.expect(hasSynthetic(index, "App\\Producer::run", "App\\Handler::handleIt"));
}

test "symfony-events: #[AsEventListener(event:, method:)]" {
    const gpa = testing.allocator;
    var cfg = types.ProjectConfig.init(gpa, "");
    defer cfg.deinit();
    cfg.plugins = &.{"symfony-events"};
    var configs = [_]types.ProjectConfig{cfg};

    var index = try createInMemoryWithConfigsForTest(gpa, &.{
        .{ "App/UserCreated.php",
            \\<?php
            \\namespace App;
            \\class UserCreated {}
        },
        .{ "App/Listener.php",
            \\<?php
            \\namespace App;
            \\#[AsEventListener(event: UserCreated::class, method: 'onCreated')]
            \\class Listener { public function onCreated(UserCreated $e): void {} }
        },
        .{ "App/Producer.php",
            \\<?php
            \\namespace App;
            \\class Producer {
            \\    public function __construct(private readonly Dispatcher $d) {}
            \\    public function run(): void { $this->d->dispatch(new UserCreated()); }
            \\}
        },
    }, &configs);
    defer index.destroy();

    try testing.expect(hasSynthetic(index, "App\\Producer::run", "App\\Listener::onCreated"));
}

fn countRefKind(refs: []const references.Reference, kind: references.ReferenceKind) usize {
    var n: usize = 0;
    for (refs) |r| {
        if (r.kind == kind) n += 1;
    }
    return n;
}

test "references: FQN-scoped, sibling-namespace twin is never matched" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Foo/Bar.php",
            \\<?php
            \\namespace App\Foo;
            \\class Bar {}
        },
        .{ "App/Other/Bar.php",
            \\<?php
            \\namespace App\Other;
            \\class Bar {}
        },
        .{ "App/Consumer.php",
            \\<?php
            \\namespace App;
            \\use App\Foo\Bar;
            \\class Consumer {
            \\    public function make(Bar $b): Bar {
            \\        $x = new Bar();
            \\        $n = Bar::class;
            \\        return $b;
            \\    }
            \\}
        },
        .{ "App/OtherConsumer.php",
            \\<?php
            \\namespace App;
            \\use App\Other\Bar;
            \\class OtherConsumer {
            \\    public function make(Bar $b): void {}
            \\}
        },
    });
    defer index.destroy();

    const refs = try index.collectReferences(gpa, "App\\Foo\\Bar");
    defer gpa.free(refs);

    // use + 2 type hints (param + return) + new + ::class, all in Consumer.php.
    try testing.expectEqual(@as(usize, 1), countRefKind(refs, .use_import));
    try testing.expectEqual(@as(usize, 2), countRefKind(refs, .type_hint));
    try testing.expectEqual(@as(usize, 1), countRefKind(refs, .instantiation));
    try testing.expectEqual(@as(usize, 1), countRefKind(refs, .class_const));
    for (refs) |r| {
        try testing.expect(std.mem.endsWith(u8, r.file_path, "Consumer.php"));
        try testing.expect(!std.mem.endsWith(u8, r.file_path, "OtherConsumer.php"));
    }

    // The sibling twin has its own (disjoint) references.
    const other = try index.collectReferences(gpa, "App\\Other\\Bar");
    defer gpa.free(other);
    try testing.expectEqual(@as(usize, 1), countRefKind(other, .use_import));
    try testing.expectEqual(@as(usize, 1), countRefKind(other, .type_hint));
    for (other) |r| try testing.expect(std.mem.endsWith(u8, r.file_path, "OtherConsumer.php"));
}

test "references: extends, implements, static ref, and string literal" {
    const gpa = testing.allocator;
    var index = try createInMemory(gpa, &.{
        .{ "App/Base.php",
            \\<?php
            \\namespace App;
            \\class Base { const V = 1; }
        },
        .{ "App/Contract.php",
            \\<?php
            \\namespace App;
            \\interface Contract {}
        },
        .{ "App/Child.php",
            \\<?php
            \\namespace App;
            \\class Child extends Base implements Contract {
            \\    public function go(): int { return Base::V; }
            \\    public function id(): string { return 'App\Base'; }
            \\}
        },
    });
    defer index.destroy();

    const base_refs = try index.collectReferences(gpa, "App\\Base");
    defer gpa.free(base_refs);
    try testing.expectEqual(@as(usize, 1), countRefKind(base_refs, .extends));
    try testing.expectEqual(@as(usize, 1), countRefKind(base_refs, .static_ref));
    try testing.expectEqual(@as(usize, 1), countRefKind(base_refs, .string_literal));

    const iface_refs = try index.collectReferences(gpa, "App\\Contract");
    defer gpa.free(iface_refs);
    try testing.expectEqual(@as(usize, 1), countRefKind(iface_refs, .implements));
}

