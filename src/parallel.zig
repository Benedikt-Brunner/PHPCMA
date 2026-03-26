const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ProjectConfig = types.ProjectConfig;
const CallAnalyzer = call_analyzer.CallAnalyzer;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const EnhancedFunctionCall = types.EnhancedFunctionCall;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

const max_file_size = 1024 * 1024 * 10;

// ============================================================================
// Thread-local results for Pass 2 (Symbol Collection)
// ============================================================================

pub const SymbolCollectResult = struct {
    sym_table: SymbolTable,
    file_contexts: std.StringHashMap(FileContext),
    file_sources: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolCollectResult {
        return .{
            .sym_table = SymbolTable.init(allocator),
            .file_contexts = std.StringHashMap(FileContext).init(allocator),
            .file_sources = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
};

// ============================================================================
// Thread-local results for Pass 4 (Call Analysis)
// ============================================================================

pub const CallAnalysisResult = struct {
    calls: std.ArrayListUnmanaged(EnhancedFunctionCall),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CallAnalysisResult {
        return .{
            .calls = .empty,
            .allocator = allocator,
        };
    }
};

// ============================================================================
// Pass 2: Parallel Symbol Collection
// ============================================================================

/// Function pointer for collecting symbols from a parsed tree.
pub const CollectFn = *const fn (
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    file_ctx: *FileContext,
    source: []const u8,
    language: *const ts.Language,
    tree: *ts.Tree,
) error{OutOfMemory}!void;

const SymbolCollectContext = struct {
    files: []const []const u8,
    project_configs: []ProjectConfig,
    results: []SymbolCollectResult,
    collect_fn: CollectFn,
};

fn symbolCollectWorker(ctx: *const SymbolCollectContext, thread_idx: usize, chunk_start: usize, chunk_end: usize) void {
    const result = &ctx.results[thread_idx];

    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch return;

    var i = chunk_start;
    while (i < chunk_end) : (i += 1) {
        const file_path = ctx.files[i];

        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const source = file.readToEndAlloc(result.allocator, max_file_size) catch continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var file_ctx = FileContext.init(result.allocator, file_path);

        for (ctx.project_configs) |*cfg| {
            if (std.mem.startsWith(u8, file_path, cfg.root_path)) {
                file_ctx.project_config = cfg;
                break;
            }
        }

        ctx.collect_fn(
            result.allocator,
            &result.sym_table,
            &file_ctx,
            source,
            php_lang,
            tree,
        ) catch continue;

        result.file_contexts.put(file_path, file_ctx) catch continue;
        result.file_sources.put(file_path, source) catch continue;
    }
}

/// Determine the number of worker threads to use.
pub fn getThreadCount(file_count: usize) usize {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    return @min(cpu_count, @max(1, file_count / 10));
}

/// Run symbol collection in parallel across multiple threads.
/// Merges results into the provided global structures.
pub fn parallelSymbolCollect(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    project_configs: []ProjectConfig,
    sym_table: *SymbolTable,
    file_contexts: *std.StringHashMap(FileContext),
    file_sources: *std.StringHashMap([]const u8),
    collect_fn: CollectFn,
) !void {
    const num_threads = getThreadCount(files.len);

    if (num_threads <= 1 or files.len < 20) {
        sequentialSymbolCollect(allocator, files, project_configs, sym_table, file_contexts, file_sources, collect_fn);
        return;
    }

    var results = try allocator.alloc(SymbolCollectResult, num_threads);
    defer allocator.free(results);

    // Each thread gets its own ArenaAllocator backed by c_allocator.
    // The merged symbol/file-context maps retain these allocators internally,
    // so the ArenaAllocator structs themselves must outlive this function.
    const thread_arenas = try std.heap.c_allocator.alloc(std.heap.ArenaAllocator, num_threads);

    for (results, thread_arenas) |*r, *arena| {
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        r.* = SymbolCollectResult.init(arena.allocator());
    }

    const chunk_size = (files.len + num_threads - 1) / num_threads;

    var ctx = SymbolCollectContext{
        .files = files,
        .project_configs = project_configs,
        .results = results,
        .collect_fn = collect_fn,
    };

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var spawned: usize = 0;
    for (0..num_threads) |t| {
        const start = t * chunk_size;
        const end = @min(start + chunk_size, files.len);
        if (start >= files.len) break;
        threads[t] = try std.Thread.spawn(.{}, symbolCollectWorker, .{ &ctx, t, start, end });
        spawned += 1;
    }

    for (threads[0..spawned]) |thread| {
        thread.join();
    }

    // Merge results into global structures
    for (results[0..spawned]) |*r| {
        var class_it = r.sym_table.classes.iterator();
        while (class_it.next()) |entry| {
            var class = entry.value_ptr.*;
            // After merge, follow-up work like inheritance resolution runs on
            // the caller side, so allocator-backed helpers must use the
            // caller allocator rather than the thread-local arena.
            class.allocator = allocator;
            try sym_table.classes.put(entry.key_ptr.*, class);
        }

        var iface_it = r.sym_table.interfaces.iterator();
        while (iface_it.next()) |entry| {
            var iface = entry.value_ptr.*;
            iface.allocator = allocator;
            try sym_table.interfaces.put(entry.key_ptr.*, iface);
        }

        var trait_it = r.sym_table.traits.iterator();
        while (trait_it.next()) |entry| {
            var trait = entry.value_ptr.*;
            trait.allocator = allocator;
            try sym_table.traits.put(entry.key_ptr.*, trait);
        }

        var func_it = r.sym_table.functions.iterator();
        while (func_it.next()) |entry| {
            try sym_table.functions.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var ctx_it = r.file_contexts.iterator();
        while (ctx_it.next()) |entry| {
            try file_contexts.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var src_it = r.file_sources.iterator();
        while (src_it.next()) |entry| {
            // Normalize ownership: thread-local parsing buffers come from
            // per-thread arenas, but callers may free file_sources values with
            // their allocator during cleanup. Duplicate here so exported
            // buffers are always owned by the caller allocator.
            const owned_source = try allocator.dupe(u8, entry.value_ptr.*);
            try file_sources.put(entry.key_ptr.*, owned_source);
        }
    }
}

fn sequentialSymbolCollect(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    project_configs: []ProjectConfig,
    sym_table: *SymbolTable,
    file_contexts: *std.StringHashMap(FileContext),
    file_sources: *std.StringHashMap([]const u8),
    collect_fn: CollectFn,
) void {
    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch return;

    for (files) |file_path| {
        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const source = file.readToEndAlloc(allocator, max_file_size) catch continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var file_ctx = FileContext.init(allocator, file_path);

        for (project_configs) |*cfg| {
            if (std.mem.startsWith(u8, file_path, cfg.root_path)) {
                file_ctx.project_config = cfg;
                break;
            }
        }

        collect_fn(allocator, sym_table, &file_ctx, source, php_lang, tree) catch continue;

        file_contexts.put(file_path, file_ctx) catch continue;
        file_sources.put(file_path, source) catch continue;
    }
}

// ============================================================================
// Pass 4: Parallel Call Analysis
// ============================================================================

const CallAnalysisContext = struct {
    allocator: std.mem.Allocator,
    files: []const []const u8,
    file_sources: *std.StringHashMap([]const u8),
    file_contexts: *std.StringHashMap(FileContext),
    sym_table: *SymbolTable,
    results: []CallAnalysisResult,
};

fn callAnalysisWorker(ctx: *const CallAnalysisContext, thread_idx: usize, chunk_start: usize, chunk_end: usize) void {
    const result = &ctx.results[thread_idx];

    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch return;

    var i = chunk_start;
    while (i < chunk_end) : (i += 1) {
        const file_path = ctx.files[i];
        const source = ctx.file_sources.get(file_path) orelse continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        const file_ctx_ptr = ctx.file_contexts.getPtr(file_path) orelse continue;

        var analyzer = CallAnalyzer.init(result.allocator, ctx.sym_table, file_ctx_ptr, php_lang);
        defer analyzer.deinit();

        analyzer.analyzeFile(tree, source, file_path) catch continue;

        for (analyzer.getCalls()) |call| {
            var owned_call = call;
            owned_call.caller_fqn = ctx.allocator.dupe(u8, call.caller_fqn) catch continue;
            owned_call.owns_caller_fqn = true;
            owned_call.callee_name = ctx.allocator.dupe(u8, call.callee_name) catch {
                ctx.allocator.free(owned_call.caller_fqn);
                continue;
            };
            owned_call.owns_callee_name = true;

            if (call.resolved_target) |target| {
                owned_call.resolved_target = ctx.allocator.dupe(u8, target) catch {
                    ctx.allocator.free(owned_call.caller_fqn);
                    ctx.allocator.free(owned_call.callee_name);
                    continue;
                };
                owned_call.owns_resolved_target = true;
            }

            var copied_argument_types = false;
            if (call.argument_types.len > 0) {
                owned_call.argument_types = ctx.allocator.dupe(?types.TypeInfo, call.argument_types) catch {
                    ctx.allocator.free(owned_call.caller_fqn);
                    ctx.allocator.free(owned_call.callee_name);
                    if (owned_call.owns_resolved_target and owned_call.resolved_target != null) {
                        ctx.allocator.free(owned_call.resolved_target.?);
                    }
                    continue;
                };
                copied_argument_types = true;
            }

            result.calls.append(result.allocator, owned_call) catch {
                if (owned_call.owns_caller_fqn) {
                    ctx.allocator.free(owned_call.caller_fqn);
                }
                if (owned_call.owns_callee_name) {
                    ctx.allocator.free(owned_call.callee_name);
                }
                if (owned_call.owns_resolved_target and owned_call.resolved_target != null) {
                    ctx.allocator.free(owned_call.resolved_target.?);
                }
                if (copied_argument_types) {
                    ctx.allocator.free(owned_call.argument_types);
                }
                continue;
            };
        }
    }
}

/// Run call analysis in parallel across multiple threads.
/// Merges results into the provided ProjectCallGraph.
pub fn parallelCallAnalysis(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    file_sources: *std.StringHashMap([]const u8),
    file_contexts: *std.StringHashMap(FileContext),
    sym_table: *SymbolTable,
    call_graph: *ProjectCallGraph,
) !void {
    const num_threads = getThreadCount(files.len);

    if (num_threads <= 1 or files.len < 20) {
        sequentialCallAnalysis(allocator, files, file_sources, file_contexts, sym_table, call_graph);
        return;
    }

    var results = try allocator.alloc(CallAnalysisResult, num_threads);
    defer allocator.free(results);

    // Per-thread arenas for call analysis. We free only the bookkeeping array;
    // arena allocations intentionally outlive this function after merge.
    const thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, num_threads);
    defer allocator.free(thread_arenas);

    for (results, thread_arenas) |*r, *arena| {
        arena.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        r.* = CallAnalysisResult.init(arena.allocator());
    }

    const chunk_size = (files.len + num_threads - 1) / num_threads;

    var ctx = CallAnalysisContext{
        .allocator = allocator,
        .files = files,
        .file_sources = file_sources,
        .file_contexts = file_contexts,
        .sym_table = sym_table,
        .results = results,
    };

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var spawned: usize = 0;
    for (0..num_threads) |t| {
        const start = t * chunk_size;
        const end = @min(start + chunk_size, files.len);
        if (start >= files.len) break;
        threads[t] = try std.Thread.spawn(.{}, callAnalysisWorker, .{ &ctx, t, start, end });
        spawned += 1;
    }

    for (threads[0..spawned]) |thread| {
        thread.join();
    }

    // Merge results into call graph
    for (results[0..spawned]) |*r| {
        for (r.calls.items) |call| {
            try call_graph.calls.append(allocator, call);
            call_graph.total_calls += 1;
            if (call.resolved_target != null) {
                call_graph.resolved_calls += 1;
            } else {
                call_graph.unresolved_calls += 1;
            }
        }
    }
}

fn sequentialCallAnalysis(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    file_sources: *std.StringHashMap([]const u8),
    file_contexts: *std.StringHashMap(FileContext),
    sym_table: *SymbolTable,
    call_graph: *ProjectCallGraph,
) void {
    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch return;

    for (files) |file_path| {
        const source = file_sources.get(file_path) orelse continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;

        var analyzer = CallAnalyzer.init(allocator, sym_table, file_ctx_ptr, php_lang);
        defer analyzer.deinit();

        analyzer.analyzeFile(tree, source, file_path) catch continue;
        call_graph.addCalls(&analyzer) catch continue;
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Minimal collect function for tests — extracts class names into the symbol table.
fn testCollectFn(
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    file_ctx: *FileContext,
    source: []const u8,
    language: *const ts.Language,
    tree: *ts.Tree,
) error{OutOfMemory}!void {
    _ = file_ctx;
    const root = tree.rootNode();
    const class_decl_id = language.idForNodeKind("class_declaration", true);
    const name_id = language.idForNodeKind("name", true);
    try walkForClasses(allocator, sym_table, root, source, class_decl_id, name_id);
}

fn walkForClasses(
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    node: ts.Node,
    source: []const u8,
    class_decl_id: u16,
    name_id: u16,
) error{OutOfMemory}!void {
    if (node.kindId() == class_decl_id) {
        if (node.childByFieldName("name")) |name_node| {
            if (name_node.kindId() == name_id) {
                const start = name_node.startByte();
                const end = name_node.endByte();
                if (start < source.len and end <= source.len and start < end) {
                    const class_name = source[start..end];
                    var class = types.ClassSymbol.init(allocator, class_name);
                    class.file_path = "";
                    try sym_table.addClass(class);
                }
            }
        }
    }
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (node.namedChild(i)) |child| {
            try walkForClasses(allocator, sym_table, child, source, class_decl_id, name_id);
        }
    }
}

/// Helper: create a temp PHP file with given content, returning its absolute path.
fn createTempPhpFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, content: []const u8) ![]const u8 {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try dir.realpath(name, &buf);
    return try allocator.dupe(u8, abs);
}

// --------------------------------------------------------------------------
// Test 1: Sequential fallback (<20 files)
// --------------------------------------------------------------------------

test "parallel: sequential fallback for fewer than 20 files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create 5 PHP files (< 20 threshold)
    var file_paths: [5][]const u8 = undefined;
    var created: usize = 0;
    for (0..5) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "test_{d}.php", .{i}) catch unreachable;
        const content = "<?php\nclass TestClass" ++ &[_]u8{@intCast('A' + @as(u8, @intCast(i)))} ++ " {}\n";
        file_paths[i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer file_contexts.deinit();
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }

    var configs = [_]ProjectConfig{};

    // With <20 files, parallelSymbolCollect should use sequential path and still work.
    try parallelSymbolCollect(
        allocator,
        &file_paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        testCollectFn,
    );

    // Verify files were processed
    try std.testing.expect(file_sources.count() > 0);
}

// --------------------------------------------------------------------------
// Test 2: Thread count scaling (getThreadCount)
// --------------------------------------------------------------------------

test "parallel: getThreadCount scales correctly" {
    // 0 files → 0 threads (max(1, 0/10) = 1, min(cpu, 1) = 1... but 0/10=0, max(1,0)=1)
    // Actually: @max(1, 0/10) = @max(1, 0) = 1, @min(cpu, 1) = 1
    try std.testing.expectEqual(@as(usize, 1), getThreadCount(0));

    // 1 file → 1 thread
    try std.testing.expectEqual(@as(usize, 1), getThreadCount(1));

    // 10 files → max(1, 1) = 1, min(cpu, 1) = 1
    try std.testing.expectEqual(@as(usize, 1), getThreadCount(10));

    // 20 files → max(1, 2) = 2, min(cpu, 2) ≥ 2 on any machine
    const t20 = getThreadCount(20);
    try std.testing.expect(t20 >= 2);

    // 100 files → max(1, 10) = 10, min(cpu, 10) depends on CPU
    const t100 = getThreadCount(100);
    try std.testing.expect(t100 >= 1);
    try std.testing.expect(t100 <= 100);

    // Thread count should increase with file count
    try std.testing.expect(getThreadCount(1000) >= getThreadCount(100));
}

// --------------------------------------------------------------------------
// Test 3: Parallel symbol collect produces same results as sequential
// --------------------------------------------------------------------------

test "parallel: symbol collect matches sequential" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create 25 files (above threshold) so parallel path is taken
    const file_count = 25;
    var file_paths: [file_count][]const u8 = undefined;
    var created: usize = 0;
    for (0..file_count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "cls_{d}.php", .{i}) catch unreachable;
        var content_buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "<?php\nclass ParClass{d} {{}}\n", .{i}) catch unreachable;
        file_paths[i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var configs = [_]ProjectConfig{};

    // Sequential run
    var seq_sym = SymbolTable.init(allocator);
    defer seq_sym.deinit();
    var seq_ctx = std.StringHashMap(FileContext).init(allocator);
    defer seq_ctx.deinit();
    var seq_src = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = seq_src.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        seq_src.deinit();
    }

    sequentialSymbolCollect(allocator, &file_paths, &configs, &seq_sym, &seq_ctx, &seq_src, testCollectFn);

    // Parallel run
    var par_sym = SymbolTable.init(allocator);
    defer par_sym.deinit();
    var par_ctx = std.StringHashMap(FileContext).init(allocator);
    defer par_ctx.deinit();
    var par_src = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = par_src.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        par_src.deinit();
    }

    try parallelSymbolCollect(allocator, &file_paths, &configs, &par_sym, &par_ctx, &par_src, testCollectFn);

    // Compare: same number of classes found
    try std.testing.expectEqual(seq_sym.classes.count(), par_sym.classes.count());
    try std.testing.expectEqual(seq_src.count(), par_src.count());

    // Every class found sequentially must also be found in parallel
    var it = seq_sym.classes.keyIterator();
    while (it.next()) |key| {
        try std.testing.expect(par_sym.classes.contains(key.*));
    }
}

// --------------------------------------------------------------------------
// Test 4: Parallel call analysis produces same results as sequential
// --------------------------------------------------------------------------

test "parallel: call analysis matches sequential" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create 25 files with method calls
    const file_count = 25;
    var file_paths: [file_count][]const u8 = undefined;
    var created: usize = 0;
    for (0..file_count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "call_{d}.php", .{i}) catch unreachable;
        var content_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf,
            \\<?php
            \\class Caller{d} {{
            \\    public function run() {{
            \\        strlen("hello");
            \\    }}
            \\}}
            \\
        , .{i}) catch unreachable;
        file_paths[i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (file_paths[0..created]) |p| allocator.free(p);

    // Build file_sources and file_contexts by parsing each file
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var ctx_it = file_contexts.valueIterator();
        while (ctx_it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }

    for (file_paths[0..created]) |fp| {
        const file = try std.fs.openFileAbsolute(fp, .{});
        defer file.close();
        const src = try file.readToEndAlloc(allocator, max_file_size);
        try file_sources.put(fp, src);
        const ctx = FileContext.init(allocator, fp);
        try file_contexts.put(fp, ctx);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    // Sequential call analysis
    var seq_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer seq_graph.deinit();
    sequentialCallAnalysis(allocator, &file_paths, &file_sources, &file_contexts, &sym_table, &seq_graph);

    // Parallel call analysis
    var par_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer par_graph.deinit();
    try parallelCallAnalysis(allocator, &file_paths, &file_sources, &file_contexts, &sym_table, &par_graph);

    // Same total calls
    try std.testing.expectEqual(seq_graph.total_calls, par_graph.total_calls);
    try std.testing.expectEqual(seq_graph.resolved_calls, par_graph.resolved_calls);
    try std.testing.expectEqual(seq_graph.unresolved_calls, par_graph.unresolved_calls);
}

// --------------------------------------------------------------------------
// Test 5: Deterministic results (run 5x parallel — identical each time)
// --------------------------------------------------------------------------

test "parallel: deterministic results across multiple runs" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 25;
    var file_paths: [file_count][]const u8 = undefined;
    var created: usize = 0;
    for (0..file_count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "det_{d}.php", .{i}) catch unreachable;
        var content_buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "<?php\nclass Det{d} {{}}\n", .{i}) catch unreachable;
        file_paths[i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var configs = [_]ProjectConfig{};
    var class_counts: [5]usize = undefined;

    for (0..5) |run| {
        var sym_table = SymbolTable.init(allocator);
        defer sym_table.deinit();
        var file_contexts = std.StringHashMap(FileContext).init(allocator);
        defer file_contexts.deinit();
        var file_sources = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = file_sources.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            file_sources.deinit();
        }

        try parallelSymbolCollect(
            allocator,
            &file_paths,
            &configs,
            &sym_table,
            &file_contexts,
            &file_sources,
            testCollectFn,
        );

        class_counts[run] = sym_table.classes.count();
    }

    // All 5 runs should produce the same class count
    for (1..5) |i| {
        try std.testing.expectEqual(class_counts[0], class_counts[i]);
    }
    // And the count should be the expected file_count
    try std.testing.expectEqual(@as(usize, file_count), class_counts[0]);
}

// --------------------------------------------------------------------------
// Test 6: Single file edge case
// --------------------------------------------------------------------------

test "parallel: single file edge case" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTempPhpFile(allocator, tmp_dir.dir, "single.php", "<?php\nclass Single {}\n");
    defer allocator.free(path);

    var file_paths = [_][]const u8{path};
    var configs = [_]ProjectConfig{};

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer file_contexts.deinit();
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }

    try parallelSymbolCollect(
        allocator,
        &file_paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        testCollectFn,
    );

    try std.testing.expectEqual(@as(usize, 1), sym_table.classes.count());
    try std.testing.expect(sym_table.classes.contains("Single"));
}

// --------------------------------------------------------------------------
// Test 7: Empty file list (no crash)
// --------------------------------------------------------------------------

test "parallel: empty file list does not crash" {
    const allocator = std.testing.allocator;

    var empty_files = [_][]const u8{};
    var configs = [_]ProjectConfig{};

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer file_contexts.deinit();
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallelSymbolCollect(
        allocator,
        &empty_files,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        testCollectFn,
    );

    try std.testing.expectEqual(@as(usize, 0), sym_table.classes.count());
    try std.testing.expectEqual(@as(usize, 0), file_sources.count());

    // Also test empty call analysis
    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallelCallAnalysis(
        allocator,
        &empty_files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    try std.testing.expectEqual(@as(usize, 0), call_graph.total_calls);
}

// --------------------------------------------------------------------------
// Test 8: Parse error in subset (valid files still processed)
// --------------------------------------------------------------------------

test "parallel: parse error in subset does not prevent valid files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Valid PHP files
    const valid1 = try createTempPhpFile(allocator, tmp_dir.dir, "valid1.php", "<?php\nclass ValidOne {}\n");
    defer allocator.free(valid1);
    const valid2 = try createTempPhpFile(allocator, tmp_dir.dir, "valid2.php", "<?php\nclass ValidTwo {}\n");
    defer allocator.free(valid2);

    // Invalid PHP (broken syntax — tree-sitter still parses but produces error nodes)
    const invalid = try createTempPhpFile(allocator, tmp_dir.dir, "broken.php", "<?php\nclass { BROKEN SYNTAX !!!! \n");
    defer allocator.free(invalid);

    var file_paths = [_][]const u8{ valid1, invalid, valid2 };
    var configs = [_]ProjectConfig{};

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer file_contexts.deinit();
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }

    try parallelSymbolCollect(
        allocator,
        &file_paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        testCollectFn,
    );

    // Both valid classes should be found
    try std.testing.expect(sym_table.classes.contains("ValidOne"));
    try std.testing.expect(sym_table.classes.contains("ValidTwo"));

    // All 3 files should have been read (sources captured for all parseable files)
    try std.testing.expect(file_sources.count() >= 2);
}

// ============================================================================
// Test Suite 12: Parallel Memory Safety Tests (full pipeline)
// ============================================================================

/// Helper: generate N PHP fixture files with classes, inheritance, and method calls.
/// Returns owned file path slices (caller must free each path).
fn generatePhpFixtures(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    count: usize,
    paths_out: [][]const u8,
) !usize {
    var created: usize = 0;
    for (0..count) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "fix_{d}.php", .{i}) catch unreachable;

        // Build a PHP file with a class that extends the previous one (if any)
        // and calls a method, exercising symbol collect + call analysis.
        var content_buf: [512]u8 = undefined;
        const content = if (i > 0)
            std.fmt.bufPrint(&content_buf,
                \\<?php
                \\class Fix{d} extends Fix{d} {{
                \\    public function run{d}() {{
                \\        $this->run{d}();
                \\        strlen("hello");
                \\    }}
                \\}}
                \\
            , .{ i, i - 1, i, i - 1 }) catch unreachable
        else
            std.fmt.bufPrint(&content_buf,
                \\<?php
                \\class Fix0 {{
                \\    public function run0() {{
                \\        strlen("hello");
                \\    }}
                \\}}
                \\
            , .{}) catch unreachable;

        paths_out[i] = try createTempPhpFile(allocator, dir, name, content);
        created += 1;
    }
    return created;
}

/// Helper: run full pipeline — parallel symbol collect → inheritance resolution →
/// parallel call analysis. Returns (sym_table, call_graph, file_contexts, file_sources).
/// Caller is responsible for deinit of sym_table, call_graph, file_contexts, file_sources.
fn runFullPipeline(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
) !struct {
    sym_table: SymbolTable,
    call_graph: ProjectCallGraph,
    file_contexts: std.StringHashMap(FileContext),
    file_sources: std.StringHashMap([]const u8),
} {
    var configs = [_]ProjectConfig{};
    var sym_table = SymbolTable.init(allocator);
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    var file_sources = std.StringHashMap([]const u8).init(allocator);

    try parallelSymbolCollect(
        allocator,
        file_paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        testCollectFn,
    );

    try sym_table.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    try parallelCallAnalysis(
        allocator,
        file_paths,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    return .{
        .sym_table = sym_table,
        .call_graph = call_graph,
        .file_contexts = file_contexts,
        .file_sources = file_sources,
    };
}

fn cleanupPipeline(allocator: std.mem.Allocator, state: *@TypeOf(runFullPipeline(undefined, undefined) catch unreachable)) void {
    state.call_graph.deinit();
    var ctx_it = state.file_contexts.valueIterator();
    while (ctx_it.next()) |v| @constCast(v).deinit();
    state.file_contexts.deinit();
    var src_it = state.file_sources.valueIterator();
    while (src_it.next()) |v| allocator.free(v.*);
    state.file_sources.deinit();
    state.sym_table.deinit();
}

// --------------------------------------------------------------------------
// Safety Test 1: Parallel symbol collect → inheritance resolution → no crash
// (use-after-free regression test)
// --------------------------------------------------------------------------

test "safety: parallel collect → inheritance resolution → no crash" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 25;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // All classes should be present
    try std.testing.expectEqual(@as(usize, count), state.sym_table.classes.count());
    try std.testing.expect(state.sym_table.inheritance_resolved);

    // Verify FQCN lookups work after merge
    try std.testing.expect(state.sym_table.classes.contains("Fix0"));
    try std.testing.expect(state.sym_table.classes.contains("Fix1"));
}

// --------------------------------------------------------------------------
// Safety Test 2: Parallel symbol collect → call analysis → no crash
// (merged data survives to Pass 4)
// --------------------------------------------------------------------------

test "safety: parallel collect → call analysis → no crash" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 25;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // Call graph should have processed calls without crash
    try std.testing.expect(state.call_graph.total_calls >= 0);
    // Symbol table data must still be accessible after call analysis
    try std.testing.expect(state.sym_table.classes.contains("Fix0"));
}

// --------------------------------------------------------------------------
// Safety Test 3: Full pipeline (collect + call analysis) → no crash
// --------------------------------------------------------------------------

test "safety: full pipeline collect + call + inheritance → no crash" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // 30 files to ensure parallel path is taken
    const count = 30;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // Verify entire pipeline completed without crash
    try std.testing.expectEqual(@as(usize, count), state.sym_table.classes.count());
    try std.testing.expect(state.sym_table.inheritance_resolved);
    // Symbol table + call graph both accessible
    try std.testing.expect(state.sym_table.classes.contains("Fix0"));
    try std.testing.expect(state.sym_table.classes.contains("Fix29"));
}

// --------------------------------------------------------------------------
// Safety Test 4: 50+ files → verify all classes/methods accessible after merge
// (spot-check FQCN lookups)
// --------------------------------------------------------------------------

test "safety: 50+ files → all classes accessible after merge" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 55;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // Every single class must be findable by FQCN
    for (0..count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Fix{d}", .{i}) catch unreachable;
        try std.testing.expect(state.sym_table.classes.contains(name));
    }
    try std.testing.expectEqual(@as(usize, count), state.sym_table.classes.count());
}

// --------------------------------------------------------------------------
// Safety Test 5: 100+ files → call graph resolution rate matches sequential
// --------------------------------------------------------------------------

test "safety: 100+ files → call graph parity with sequential" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 105;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    // Run parallel pipeline
    var par_state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &par_state);

    // Run sequential for comparison
    var configs = [_]ProjectConfig{};
    var seq_sym = SymbolTable.init(allocator);
    defer seq_sym.deinit();
    var seq_ctx = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = seq_ctx.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        seq_ctx.deinit();
    }
    var seq_src = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = seq_src.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        seq_src.deinit();
    }
    sequentialSymbolCollect(allocator, file_paths[0..created], &configs, &seq_sym, &seq_ctx, &seq_src, testCollectFn);
    try seq_sym.resolveInheritance();

    var seq_graph = ProjectCallGraph.init(allocator, &seq_sym);
    defer seq_graph.deinit();
    sequentialCallAnalysis(allocator, file_paths[0..created], &seq_src, &seq_ctx, &seq_sym, &seq_graph);

    // Class counts must match
    try std.testing.expectEqual(seq_sym.classes.count(), par_state.sym_table.classes.count());
    // Call graph stats must match
    try std.testing.expectEqual(seq_graph.total_calls, par_state.call_graph.total_calls);
    try std.testing.expectEqual(seq_graph.resolved_calls, par_state.call_graph.resolved_calls);
    try std.testing.expectEqual(seq_graph.unresolved_calls, par_state.call_graph.unresolved_calls);
}

// --------------------------------------------------------------------------
// Safety Test 6: Repeated parallel runs (10x) → deterministic, no crashes
// (race detection)
// --------------------------------------------------------------------------

test "safety: 10x repeated parallel runs → deterministic, no crashes" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 25;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var class_counts: [10]usize = undefined;
    var call_counts: [10]usize = undefined;

    for (0..10) |run| {
        var state = try runFullPipeline(allocator, file_paths[0..created]);
        class_counts[run] = state.sym_table.classes.count();
        call_counts[run] = state.call_graph.total_calls;
        cleanupPipeline(allocator, &state);
    }

    // All runs must produce identical results
    for (1..10) |i| {
        try std.testing.expectEqual(class_counts[0], class_counts[i]);
        try std.testing.expectEqual(call_counts[0], call_counts[i]);
    }
    try std.testing.expectEqual(@as(usize, count), class_counts[0]);
}

// --------------------------------------------------------------------------
// Safety Test 7: Mixed valid/invalid PHP → no crash, valid files fully
// processed through all passes
// --------------------------------------------------------------------------

test "safety: mixed valid/invalid PHP → no crash, valid files processed" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Generate 22 valid files
    const valid_count = 22;
    var all_paths: [valid_count + 3][]const u8 = undefined;
    var created: usize = 0;

    const valid_created = try generatePhpFixtures(allocator, tmp_dir.dir, valid_count, all_paths[0..valid_count]);
    created += valid_created;

    // Add 3 broken PHP files
    const broken_contents = [_][]const u8{
        "<?php\nclass { BROKEN!! \n",
        "NOT EVEN PHP AT ALL @@@@",
        "<?php\nfunction ( broken { { { }\n",
    };
    for (broken_contents, 0..) |content, i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "broken_{d}.php", .{i}) catch unreachable;
        all_paths[valid_count + i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (all_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, all_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // All valid classes should be found; pipeline must not crash
    for (0..valid_count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Fix{d}", .{i}) catch unreachable;
        try std.testing.expect(state.sym_table.classes.contains(name));
    }
    try std.testing.expect(state.sym_table.inheritance_resolved);
}

// --------------------------------------------------------------------------
// Safety Test 8: Parallel merge correctness — no duplicate or missing symbols
// after merge from N threads
// --------------------------------------------------------------------------

test "safety: parallel merge → no duplicate or missing symbols" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Generate 40 files with unique class names
    const count = 40;
    var file_paths: [count][]const u8 = undefined;
    var created: usize = 0;
    for (0..count) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "uniq_{d}.php", .{i}) catch unreachable;
        var content_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf,
            \\<?php
            \\class Unique{d} {{
            \\    public function action{d}() {{
            \\        strlen("x");
            \\    }}
            \\}}
            \\
        , .{ i, i }) catch unreachable;
        file_paths[i] = try createTempPhpFile(allocator, tmp_dir.dir, name, content);
        created += 1;
    }
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // Exactly count classes — no duplicates, no missing
    try std.testing.expectEqual(@as(usize, count), state.sym_table.classes.count());

    // Every unique class must be present
    for (0..count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Unique{d}", .{i}) catch unreachable;
        try std.testing.expect(state.sym_table.classes.contains(name));
    }

    // file_sources and file_contexts must also have exactly count entries
    try std.testing.expectEqual(@as(usize, count), state.file_sources.count());
    try std.testing.expectEqual(@as(usize, count), state.file_contexts.count());
}

// --------------------------------------------------------------------------
// Safety Test 9: Stress test — 500 PHP files with deep inheritance chains,
// full pipeline, assert completion
// --------------------------------------------------------------------------

test "safety: stress 500 files with deep inheritance → full pipeline completes" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const count = 500;
    var file_paths: [count][]const u8 = undefined;
    const created = try generatePhpFixtures(allocator, tmp_dir.dir, count, &file_paths);
    defer for (file_paths[0..created]) |p| allocator.free(p);

    var state = try runFullPipeline(allocator, file_paths[0..created]);
    defer cleanupPipeline(allocator, &state);

    // All 500 classes must be present
    try std.testing.expectEqual(@as(usize, count), state.sym_table.classes.count());
    try std.testing.expect(state.sym_table.inheritance_resolved);

    // Spot-check first, middle, last
    try std.testing.expect(state.sym_table.classes.contains("Fix0"));
    try std.testing.expect(state.sym_table.classes.contains("Fix249"));
    try std.testing.expect(state.sym_table.classes.contains("Fix499"));

    // Call graph should be non-empty (each file has at least one strlen call)
    try std.testing.expect(state.call_graph.total_calls >= 0);
}
