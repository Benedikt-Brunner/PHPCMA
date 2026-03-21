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

    for (results) |*r| {
        r.* = SymbolCollectResult.init(allocator);
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
            try sym_table.classes.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var iface_it = r.sym_table.interfaces.iterator();
        while (iface_it.next()) |entry| {
            try sym_table.interfaces.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var trait_it = r.sym_table.traits.iterator();
        while (trait_it.next()) |entry| {
            try sym_table.traits.put(entry.key_ptr.*, entry.value_ptr.*);
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
            try file_sources.put(entry.key_ptr.*, entry.value_ptr.*);
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
            result.calls.append(result.allocator, call) catch continue;
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

    for (results) |*r| {
        r.* = CallAnalysisResult.init(allocator);
    }

    const chunk_size = (files.len + num_threads - 1) / num_threads;

    var ctx = CallAnalysisContext{
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
