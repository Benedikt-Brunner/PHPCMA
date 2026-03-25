const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");
const parallel = @import("parallel.zig");
const config_parser = @import("config.zig");
const composer = @import("composer.zig");
const framework_stubs = @import("framework_stubs.zig");
const type_violation_analyzer = @import("type_violation_analyzer.zig");
const main_mod = @import("main.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ProjectConfig = types.ProjectConfig;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

// ============================================================================
// Corpus path — skips gracefully if not present
// ============================================================================

fn getCorpusConfig(alloc: std.mem.Allocator) ?[]const u8 {
    const root = std.posix.getenv("PHPCMA_CORPUS_ROOT") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.phpcma.json", .{root}) catch return null;
}

fn corpusAvailable() bool {
    const config_path = getCorpusConfig(std.heap.c_allocator) orelse return false;
    defer std.heap.c_allocator.free(config_path);
    std.fs.accessAbsolute(config_path, .{}) catch return false;
    return true;
}

// ============================================================================
// Shared pipeline runner
// ============================================================================

const PipelineResult = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    sym_table: *SymbolTable,
    call_graph: *ProjectCallGraph,
    file_count: usize,
    project_configs: []ProjectConfig,
    file_contexts: *std.StringHashMap(FileContext),
    file_sources: *std.StringHashMap([]const u8),

    fn deinit(self: *PipelineResult) void {
        self.call_graph.deinit();
        self.sym_table.deinit();
        var it = self.file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        self.file_contexts.deinit();
        self.file_sources.deinit();
        self.allocator.destroy(self.file_sources);
        self.allocator.destroy(self.file_contexts);
        self.allocator.destroy(self.call_graph);
        self.allocator.destroy(self.sym_table);
        _ = self.arena.deinit();
        std.heap.c_allocator.destroy(self.arena);
    }
};

fn runPipeline() !PipelineResult {
    const arena = try std.heap.c_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(std.heap.c_allocator);
    const allocator = arena.allocator();

    // Pass 1: Parse .phpcma.json and discover files
    const config_path = getCorpusConfig(allocator) orelse return error.CorpusNotConfigured;
    var phpcma_config = try config_parser.parseConfigFile(allocator, config_path);
    _ = &phpcma_config;

    const project_configs = try config_parser.parseDiscoveredProjects(allocator, &phpcma_config);
    const files = try config_parser.discoverFilesFromConfigs(allocator, project_configs);

    // Pass 2: Collect symbols (parallel)
    const sym_table = try allocator.create(SymbolTable);
    sym_table.* = SymbolTable.init(allocator);

    const file_contexts = try allocator.create(std.StringHashMap(FileContext));
    file_contexts.* = std.StringHashMap(FileContext).init(allocator);

    const file_sources = try allocator.create(std.StringHashMap([]const u8));
    file_sources.* = std.StringHashMap([]const u8).init(allocator);

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        sym_table,
        file_contexts,
        file_sources,
        &main_mod.collectSymbolsFromSource,
    );

    // Register framework API stubs
    try framework_stubs.registerFrameworkStubs(allocator, sym_table);

    // Pass 3: Resolve inheritance
    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    const call_graph = try allocator.create(ProjectCallGraph);
    call_graph.* = ProjectCallGraph.init(allocator, sym_table);

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        file_sources,
        file_contexts,
        sym_table,
        call_graph,
    );

    return PipelineResult{
        .allocator = allocator,
        .arena = arena,
        .sym_table = sym_table,
        .call_graph = call_graph,
        .file_count = files.len,
        .project_configs = project_configs,
        .file_contexts = file_contexts,
        .file_sources = file_sources,
    };
}

// ============================================================================
// Test: Symbol table minimum counts
// ============================================================================

test "corpus: shopware-plugins symbol table minimum counts" {
    if (!corpusAvailable()) {
        std.debug.print("SKIP: corpus not found. Set PHPCMA_CORPUS_ROOT env var.\n", .{});
        return;
    }

    var result = try runPipeline();
    defer result.deinit();

    const stats = result.sym_table.getStats();

    // Hard minimum thresholds — these should never decrease
    try std.testing.expect(result.file_count >= 4000);
    try std.testing.expect(stats.class_count >= 3700);
    try std.testing.expect(stats.interface_count >= 80);
    try std.testing.expect(stats.method_count >= 15000);
    try std.testing.expect(stats.property_count >= 2500);

    std.debug.print(
        \\Corpus stats:
        \\  Files:      {d}
        \\  Classes:    {d}
        \\  Interfaces: {d}
        \\  Methods:    {d}
        \\  Properties: {d}
        \\
    , .{
        result.file_count,
        stats.class_count,
        stats.interface_count,
        stats.method_count,
        stats.property_count,
    });
}

// ============================================================================
// Test: Resolution rate floor
// ============================================================================

test "corpus: shopware-plugins resolution rate floor" {
    if (!corpusAvailable()) {
        std.debug.print("SKIP: corpus not found. Set PHPCMA_CORPUS_ROOT env var.\n", .{});
        return;
    }

    var result = try runPipeline();
    defer result.deinit();

    const rate = result.call_graph.getResolutionRate();

    // Floor: currently ~31.4%, allow small variance downward
    try std.testing.expect(rate >= 30.0);

    std.debug.print("Resolution rate: {d:.1}%\n", .{rate});
}

// ============================================================================
// Test: No crashes (pipeline completes without error/panic)
// ============================================================================

test "corpus: shopware-plugins no crashes" {
    if (!corpusAvailable()) {
        std.debug.print("SKIP: corpus not found. Set PHPCMA_CORPUS_ROOT env var.\n", .{});
        return;
    }

    // If runPipeline returns without error, no panic occurred
    var result = try runPipeline();
    defer result.deinit();

    // Verify we actually processed files (not an empty run)
    try std.testing.expect(result.file_count > 0);
    try std.testing.expect(result.call_graph.total_calls > 0);
}

// ============================================================================
// Test: Performance ceiling
// ============================================================================

test "corpus: shopware-plugins performance ceiling" {
    if (!corpusAvailable()) {
        std.debug.print("SKIP: corpus not found. Set PHPCMA_CORPUS_ROOT env var.\n", .{});
        return;
    }

    var timer = try std.time.Timer.start();

    var result = try runPipeline();
    defer result.deinit();

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // In ReleaseFast ~0.3s; in Debug mode ~5s. Ceiling accounts for Debug builds.
    try std.testing.expect(elapsed_s < 30.0);

    std.debug.print("Pipeline time: {d:.3}s\n", .{elapsed_s});
}

// ============================================================================
// Test: check-types violation count consistency
// ============================================================================

test "corpus: shopware-plugins check-types produces consistent violation count" {
    if (!corpusAvailable()) {
        std.debug.print("SKIP: corpus not found. Set PHPCMA_CORPUS_ROOT env var.\n", .{});
        return;
    }

    var pipeline = try runPipeline();
    defer pipeline.deinit();

    var tva = type_violation_analyzer.TypeViolationAnalyzer.init(
        pipeline.allocator,
        pipeline.call_graph,
        pipeline.project_configs,
        pipeline.sym_table,
    );
    const tva_result = try tva.analyze();

    // Store expected count with ±10% tolerance
    // Current baseline: we just assert it's within a reasonable range
    // and print the actual count so it can be pinned down
    const total = tva_result.total_violations;

    std.debug.print(
        \\check-types results:
        \\  Total violations: {d}
        \\  Errors:           {d}
        \\  Warnings:         {d}
        \\  Cross-project calls: {d}
        \\
    , .{
        total,
        tva_result.error_count,
        tva_result.warning_count,
        tva_result.total_cross_project_calls,
    });

    // The analysis must have actually run and found violations
    // (interface compliance violations from declaration-level checks)
    try std.testing.expect(total > 0);

    // Violation count within expected range: baseline ~95, allow ±10%
    const expected: usize = 95;
    const lower = expected - expected / 10; // 85
    const upper = expected + expected / 10; // 104
    try std.testing.expect(total >= lower);
    try std.testing.expect(total <= upper);
}
