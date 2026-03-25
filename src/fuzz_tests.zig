const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");
const boundary_analyzer = @import("boundary_analyzer.zig");
const type_violation_analyzer = @import("type_violation_analyzer.zig");
const dead_code = @import("dead_code.zig");
const report = @import("report.zig");
const parallel = @import("parallel.zig");
const main_mod = @import("main.zig");
const phpdoc = @import("phpdoc.zig");
const config = @import("config.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const CallAnalyzer = call_analyzer.CallAnalyzer;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const BoundaryAnalyzer = boundary_analyzer.BoundaryAnalyzer;
const TypeViolationAnalyzer = type_violation_analyzer.TypeViolationAnalyzer;
const ProjectLivenessGraph = dead_code.ProjectLivenessGraph;
const UnifiedReport = report.UnifiedReport;
const ProjectConfig = types.ProjectConfig;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

// ============================================================================
// Fuzz Harness Infrastructure
// ============================================================================

/// Prepend '<?php ' to raw fuzz input bytes so tree-sitter parses them as PHP.
pub fn prepareFuzzPhpSource(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "<?php {s}", .{input});
}

/// Create a tree-sitter parser, set the PHP language, and parse the source.
/// Returns null if the parse fails (null tree).
pub fn parseFuzzTree(source: []const u8) ?*ts.Tree {
    const language = tree_sitter_php();
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language) catch return null;
    return parser.parseString(source, null);
}

/// Run the full analysis pipeline (symbol collection + inheritance + call analysis)
/// on fuzz input. Errors are returned (expected); panics/crashes are the bugs
/// we want to find.
pub fn runPipelineOnFuzzInput(alloc: std.mem.Allocator, source: []const u8, tree: *ts.Tree) !void {
    const language = tree_sitter_php();
    var project_configs = [_]ProjectConfig{ProjectConfig.init(alloc, "")};
    defer project_configs[0].deinit();

    // Symbol collection
    var sym_table = SymbolTable.init(alloc);
    defer sym_table.deinit();

    var file_ctx = FileContext.init(alloc, "fuzz_input.php");
    defer file_ctx.deinit();

    main_mod.collectSymbolsFromSource(alloc, &sym_table, &file_ctx, source, language, tree) catch return;

    // Inheritance resolution
    sym_table.resolveInheritance() catch return;

    // Call analysis
    var analyzer = CallAnalyzer.init(alloc, &sym_table, &file_ctx, language);
    defer analyzer.deinit();

    analyzer.analyzeFile(tree, source, "fuzz_input.php") catch return;

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    defer call_graph.deinit();
    call_graph.addCalls(&analyzer) catch return;

    // Type violation analysis (if symbols were discovered).
    const stats = sym_table.getStats();
    const symbol_count = stats.class_count + stats.interface_count + stats.trait_count +
        stats.function_count + stats.method_count + stats.property_count;
    if (symbol_count > 0) {
        var tva = TypeViolationAnalyzer.init(alloc, &call_graph, &project_configs, &sym_table);
        _ = tva.analyze() catch {};
    }

    // Boundary analysis (only when multiple namespaces appear in the input).
    if (hasMultipleNamespaces(alloc, &sym_table) catch false) {
        var ba = BoundaryAnalyzer.init(alloc, &call_graph, &project_configs, &sym_table);
        _ = ba.analyze() catch {};
    }

    // Dead code analysis (reference extraction + liveness graph).
    const refs = dead_code.extractRefsFromCallGraph(alloc, &call_graph, &sym_table) catch return;
    var liveness = ProjectLivenessGraph.init(alloc);
    defer liveness.deinit();
    liveness.analyze(&sym_table, refs) catch return;
    _ = liveness.collectDead(&sym_table) catch return;

    // Unified report generation in both text and JSON format.
    var unified_report = UnifiedReport.init(alloc);
    defer unified_report.deinit();
    unified_report.populate(&sym_table, &call_graph);
    unified_report.coverage.total_files = 1;

    const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer dev_null.close();
    unified_report.toText(dev_null) catch return;
    unified_report.toJson(dev_null) catch return;
}

fn hasMultipleNamespaces(alloc: std.mem.Allocator, sym_table: *const SymbolTable) !bool {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(alloc);

    var class_it = sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const ns = entry.value_ptr.namespace orelse "";
        try seen.put(alloc, ns, {});
        if (seen.count() > 1) return true;
    }

    var iface_it = sym_table.interfaces.iterator();
    while (iface_it.next()) |entry| {
        const ns = entry.value_ptr.namespace orelse "";
        try seen.put(alloc, ns, {});
        if (seen.count() > 1) return true;
    }

    var trait_it = sym_table.traits.iterator();
    while (trait_it.next()) |entry| {
        const ns = entry.value_ptr.namespace orelse "";
        try seen.put(alloc, ns, {});
        if (seen.count() > 1) return true;
    }

    var function_it = sym_table.functions.iterator();
    while (function_it.next()) |entry| {
        const ns = entry.value_ptr.namespace orelse "";
        try seen.put(alloc, ns, {});
        if (seen.count() > 1) return true;
    }

    return false;
}

fn writeTempPhpFileAbsolute(alloc: std.mem.Allocator, dir: std.fs.Dir, file_name: []const u8, source: []const u8) ![]const u8 {
    const file = try dir.createFile(file_name, .{});
    defer file.close();
    try file.writeAll(source);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(file_name, &path_buf);
    return try alloc.dupe(u8, path);
}

// ============================================================================
// Fuzz Test Entry Points
// ============================================================================

test "fuzz_php_pipeline" {
    try std.testing.fuzz({}, fuzzPhpPipeline, .{});
}

fn fuzzPhpPipeline(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try prepareFuzzPhpSource(alloc, input);

    const tree = parseFuzzTree(source) orelse return;
    defer tree.destroy();

    try runPipelineOnFuzzInput(alloc, source, tree);
}

test "fuzz: full pipeline never crashes" {
    try std.testing.fuzz({}, fuzzFullPipelineNeverCrashes, .{});
}

fn fuzzFullPipelineNeverCrashes(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = prepareFuzzPhpSource(alloc, input) catch return;
    const tree = parseFuzzTree(source) orelse return;
    defer tree.destroy();

    runPipelineOnFuzzInput(alloc, source, tree) catch return;
}

test "fuzz: parallel pipeline never crashes" {
    try std.testing.fuzz({}, fuzzParallelPipelineNeverCrashes, .{});
}

fn fuzzParallelPipelineNeverCrashes(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_file_count: usize = 2 + @as(usize, input.len % 4);
    var chunks = std.mem.splitScalar(u8, input, '\n');

    var file_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer file_paths.deinit(alloc);

    var i: usize = 0;
    while (i < target_file_count) : (i += 1) {
        const next_chunk = chunks.next() orelse input;
        const chunk = if (next_chunk.len > 0) next_chunk else input;
        const source_body = if (chunk.len > 0) chunk else "// fuzz empty";

        const source = std.fmt.allocPrint(alloc, "<?php {s}", .{source_body}) catch return;
        const file_name = std.fmt.allocPrint(alloc, "fuzz_{d}.php", .{i}) catch return;
        const abs_path = writeTempPhpFileAbsolute(alloc, tmp.dir, file_name, source) catch return;
        file_paths.append(alloc, abs_path) catch return;
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = tmp.dir.realpath(".", &root_buf) catch return;
    const root_path_owned = alloc.dupe(u8, root_path) catch return;

    var project_configs = [_]ProjectConfig{ProjectConfig.init(alloc, root_path_owned)};
    defer project_configs[0].deinit();

    var sym_table = SymbolTable.init(alloc);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(alloc);
    defer {
        var context_it = file_contexts.valueIterator();
        while (context_it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(alloc);
    defer file_sources.deinit();

    parallel.parallelSymbolCollect(
        alloc,
        file_paths.items,
        project_configs[0..],
        &sym_table,
        &file_contexts,
        &file_sources,
        &main_mod.collectSymbolsFromSource,
    ) catch return;

    sym_table.resolveInheritance() catch return;

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    defer call_graph.deinit();

    parallel.parallelCallAnalysis(
        alloc,
        file_paths.items,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    ) catch return;
}

test "fuzz: symbol collector never crashes" {
    try std.testing.fuzz({}, fuzzSymbolCollector, .{});
}

fn fuzzSymbolCollector(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = prepareFuzzPhpSource(alloc, input) catch return;

    const tree = parseFuzzTree(source) orelse return;
    defer tree.destroy();

    const language = tree_sitter_php();

    var sym_table = SymbolTable.init(alloc);
    defer sym_table.deinit();

    var file_ctx = FileContext.init(alloc, "fuzz_input.php");
    defer file_ctx.deinit();

    // This must not panic or segfault regardless of input.
    // OOM and other errors are expected — only crashes are bugs.
    main_mod.collectSymbolsFromSource(alloc, &sym_table, &file_ctx, source, language, tree) catch return;
}

// ============================================================================
// PHPDoc Parser Fuzz Tests
// ============================================================================

test "fuzz: PHPDoc parser never crashes" {
    try std.testing.fuzz({}, fuzzPhpDocParser, .{});
}

fn fuzzPhpDocParser(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Fuzz parseTypeString: treats input as a raw type expression
    _ = phpdoc.parseTypeString(alloc, input) catch {};

    // Fuzz parsePhpDoc: treats input as a PHPDoc comment body
    var doc = phpdoc.parsePhpDoc(alloc, input) catch return;
    doc.deinit();
}

// ============================================================================
// Config Parser Fuzz Tests
// ============================================================================

test "fuzz: config parser never crashes" {
    try std.testing.fuzz({}, fuzzConfigParser, .{});
}

fn fuzzConfigParser(_: void, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Treat raw input as JSON config file content
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch return;
    defer parsed.deinit();

    // Try parsing as phpcma settings
    var settings = config.parsePhpcmaSettings(alloc, parsed.value) catch return;
    settings.deinit(alloc);
}
