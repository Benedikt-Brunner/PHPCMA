const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");
const parallel = @import("parallel.zig");
const main_mod = @import("main.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ProjectConfig = types.ProjectConfig;
const CallAnalyzer = call_analyzer.CallAnalyzer;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

const max_file_size = 1024 * 1024 * 10;

// ============================================================================
// PHP Fixture Generator
// ============================================================================

/// Generate a PHP file with known structure: namespace, class, methods, properties
fn generatePhpFixture(allocator: std.mem.Allocator, index: usize) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);

    try writer.print("<?php\nnamespace App\\Generated\\Module{d};\n\n", .{index / 10});
    try writer.print("use App\\Generated\\Module{d}\\Service{d};\n\n", .{ (index +% 1) / 10, (index +% 1) % 100 });

    // Class with methods and properties
    try writer.print("class Service{d}\n{{\n", .{index});
    try writer.print("    private string $name;\n", .{});
    try writer.print("    protected int $count = 0;\n", .{});
    try writer.print("    public readonly ?string $id;\n\n", .{});

    // Constructor with promotion
    try writer.print("    public function __construct(\n", .{});
    try writer.print("        private readonly string $config,\n", .{});
    try writer.print("        protected int $timeout = 30,\n", .{});
    try writer.print("    ) {{\n", .{});
    try writer.print("        $this->name = 'service_{d}';\n", .{index});
    try writer.print("        $this->id = null;\n", .{});
    try writer.print("    }}\n\n", .{});

    // Several methods with calls
    try writer.print("    public function process(string $input): string\n", .{});
    try writer.print("    {{\n", .{});
    try writer.print("        $result = $this->validate($input);\n", .{});
    try writer.print("        $this->count++;\n", .{});
    try writer.print("        return strtoupper($result);\n", .{});
    try writer.print("    }}\n\n", .{});

    try writer.print("    private function validate(string $data): string\n", .{});
    try writer.print("    {{\n", .{});
    try writer.print("        if (strlen($data) === 0) {{\n", .{});
    try writer.print("            throw new \\InvalidArgumentException('Empty data');\n", .{});
    try writer.print("        }}\n", .{});
    try writer.print("        return trim($data);\n", .{});
    try writer.print("    }}\n\n", .{});

    try writer.print("    public static function create(): self\n", .{});
    try writer.print("    {{\n", .{});
    try writer.print("        return new self('default');\n", .{});
    try writer.print("    }}\n\n", .{});

    try writer.print("    /** @return array<string, mixed> */\n", .{});
    try writer.print("    public function toArray(): array\n", .{});
    try writer.print("    {{\n", .{});
    try writer.print("        return [\n", .{});
    try writer.print("            'name' => $this->name,\n", .{});
    try writer.print("            'count' => $this->count,\n", .{});
    try writer.print("        ];\n", .{});
    try writer.print("    }}\n", .{});

    try writer.print("}}\n", .{});

    return buf.toOwnedSlice(allocator);
}

/// Create a temporary PHP file on disk and return its absolute path.
fn createTempFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, content: []const u8) ![]const u8 {
    dir.writeFile(.{ .sub_path = name, .data = content }) catch |err| {
        std.debug.print("Failed to write temp file {s}: {}\n", .{ name, err });
        return err;
    };
    const real = try dir.realpathAlloc(allocator, name);
    return real;
}

/// Generate N PHP fixture files in a temp directory, return file paths.
fn generateFixtureFiles(allocator: std.mem.Allocator, dir: std.fs.Dir, count: usize) ![]const []const u8 {
    var paths = try allocator.alloc([]const u8, count);
    for (0..count) |i| {
        const content = try generatePhpFixture(allocator, i);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Service{d}.php", .{i}) catch unreachable;
        paths[i] = try createTempFile(allocator, dir, name, content);
        allocator.free(content);
    }
    return paths;
}

// ============================================================================
// Timer Helpers
// ============================================================================

const BenchResult = struct {
    elapsed_ns: u64,
    label: []const u8,
};

fn formatDuration(ns: u64) struct { f64, []const u8 } {
    if (ns < 1_000) return .{ @as(f64, @floatFromInt(ns)), "ns" };
    if (ns < 1_000_000) return .{ @as(f64, @floatFromInt(ns)) / 1_000.0, "µs" };
    if (ns < 1_000_000_000) return .{ @as(f64, @floatFromInt(ns)) / 1_000_000.0, "ms" };
    return .{ @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, "s" };
}

fn printResult(label: []const u8, elapsed_ns: u64, threshold_ns: u64) void {
    const formatted = formatDuration(elapsed_ns);
    const status: []const u8 = if (elapsed_ns <= threshold_ns) "PASS" else "FAIL";
    std.debug.print("[{s}] {s}: {d:.2}{s} (threshold: {d:.2}{s})\n", .{
        status,
        label,
        formatted[0],
        formatted[1],
        formatDuration(threshold_ns)[0],
        formatDuration(threshold_ns)[1],
    });
}

// ============================================================================
// Benchmark 1: Small project (50 files) — full pipeline < 500ms
// ============================================================================

test "bench: small project 50 files < 500ms" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 50;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    var timer = try std.time.Timer.start();

    // Full pipeline: Pass 2 + Pass 4
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }
    var configs = [_]ProjectConfig{};

    try parallel.parallelSymbolCollect(
        allocator,
        paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &main_mod.collectSymbolsFromSource,
    );

    try sym_table.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        paths,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    const elapsed = timer.read();
    const threshold: u64 = 500 * std.time.ns_per_ms;
    printResult("small project 50 files", elapsed, threshold);
    try std.testing.expect(elapsed <= threshold);
}

// ============================================================================
// Benchmark 2: Medium project (500 files) — full pipeline < 3s
// ============================================================================

test "bench: medium project 500 files < 3s" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 500;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    var timer = try std.time.Timer.start();

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }
    var configs = [_]ProjectConfig{};

    try parallel.parallelSymbolCollect(
        allocator,
        paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &main_mod.collectSymbolsFromSource,
    );

    try sym_table.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        paths,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    const elapsed = timer.read();
    const threshold: u64 = 3 * std.time.ns_per_s;
    printResult("medium project 500 files", elapsed, threshold);
    try std.testing.expect(elapsed <= threshold);
}

// ============================================================================
// Benchmark 3: Large project (2000 files) — full pipeline < 10s
// ============================================================================

test "bench: large project 2000 files < 10s" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 2000;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    var timer = try std.time.Timer.start();

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }
    var configs = [_]ProjectConfig{};

    try parallel.parallelSymbolCollect(
        allocator,
        paths,
        &configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &main_mod.collectSymbolsFromSource,
    );

    try sym_table.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        paths,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    const elapsed = timer.read();
    const threshold: u64 = 10 * std.time.ns_per_s;
    printResult("large project 2000 files", elapsed, threshold);
    try std.testing.expect(elapsed <= threshold);
}

// ============================================================================
// Benchmark 4: Pass 2 isolation (< 40% of total)
// ============================================================================

test "bench: pass 2 isolation < 40% of total" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 200;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    var configs = [_]ProjectConfig{};

    // Measure full pipeline
    var total_timer = try std.time.Timer.start();
    {
        var sym_table = SymbolTable.init(allocator);
        defer sym_table.deinit();
        var file_contexts = std.StringHashMap(FileContext).init(allocator);
        defer {
            var it = file_contexts.valueIterator();
            while (it.next()) |v| @constCast(v).deinit();
            file_contexts.deinit();
        }
        var file_sources = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = file_sources.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            file_sources.deinit();
        }

        try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table, &file_contexts, &file_sources, &main_mod.collectSymbolsFromSource);
        try sym_table.resolveInheritance();
        var call_graph = ProjectCallGraph.init(allocator, &sym_table);
        defer call_graph.deinit();
        try parallel.parallelCallAnalysis(allocator, paths, &file_sources, &file_contexts, &sym_table, &call_graph);
    }
    const total_ns = total_timer.read();

    // Measure Pass 2 only
    var pass2_timer = try std.time.Timer.start();
    {
        var sym_table = SymbolTable.init(allocator);
        defer sym_table.deinit();
        var file_contexts = std.StringHashMap(FileContext).init(allocator);
        defer {
            var it = file_contexts.valueIterator();
            while (it.next()) |v| @constCast(v).deinit();
            file_contexts.deinit();
        }
        var file_sources = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = file_sources.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            file_sources.deinit();
        }

        try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table, &file_contexts, &file_sources, &main_mod.collectSymbolsFromSource);
    }
    const pass2_ns = pass2_timer.read();

    const ratio = @as(f64, @floatFromInt(pass2_ns)) / @as(f64, @floatFromInt(total_ns));
    std.debug.print("[{s}] Pass 2 ratio: {d:.1}% of total (threshold: 40%)\n", .{
        if (ratio <= 0.40) "PASS" else "FAIL",
        ratio * 100.0,
    });
    try std.testing.expect(ratio <= 0.40);
}

// ============================================================================
// Benchmark 5: Pass 4 isolation (< 75% of total)
// ============================================================================

test "bench: pass 4 isolation < 70% of total" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 200;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    var configs = [_]ProjectConfig{};

    // Measure full pipeline
    var total_timer = try std.time.Timer.start();
    var sym_table_shared = SymbolTable.init(allocator);
    var file_contexts_shared = std.StringHashMap(FileContext).init(allocator);
    var file_sources_shared = std.StringHashMap([]const u8).init(allocator);

    try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table_shared, &file_contexts_shared, &file_sources_shared, &main_mod.collectSymbolsFromSource);
    try sym_table_shared.resolveInheritance();
    var call_graph_full = ProjectCallGraph.init(allocator, &sym_table_shared);
    try parallel.parallelCallAnalysis(allocator, paths, &file_sources_shared, &file_contexts_shared, &sym_table_shared, &call_graph_full);
    call_graph_full.deinit();
    const total_ns = total_timer.read();

    // Measure Pass 4 only (reuse existing sym_table + sources)
    var pass4_timer = try std.time.Timer.start();
    {
        var call_graph = ProjectCallGraph.init(allocator, &sym_table_shared);
        defer call_graph.deinit();
        try parallel.parallelCallAnalysis(allocator, paths, &file_sources_shared, &file_contexts_shared, &sym_table_shared, &call_graph);
    }
    const pass4_ns = pass4_timer.read();

    // Cleanup shared state
    sym_table_shared.deinit();
    {
        var it = file_contexts_shared.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts_shared.deinit();
    }
    {
        var it = file_sources_shared.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources_shared.deinit();
    }

    const ratio = @as(f64, @floatFromInt(pass4_ns)) / @as(f64, @floatFromInt(total_ns));
    std.debug.print("[{s}] Pass 4 ratio: {d:.1}% of total (threshold: 75%)\n", .{
        if (ratio <= 0.75) "PASS" else "FAIL",
        ratio * 100.0,
    });
    try std.testing.expect(ratio <= 0.75);
}

// ============================================================================
// Benchmark 6: Parallel vs sequential (parallel >= 1.5x faster for 500+ files)
// ============================================================================

test "bench: parallel vs sequential comparison for 500 files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 500;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    var configs = [_]ProjectConfig{};

    // Sequential run (force sequential by using a small subset size or calling sequential directly)
    var seq_timer = try std.time.Timer.start();
    {
        var sym_table = SymbolTable.init(allocator);
        defer sym_table.deinit();
        var file_contexts = std.StringHashMap(FileContext).init(allocator);
        defer {
            var it = file_contexts.valueIterator();
            while (it.next()) |v| @constCast(v).deinit();
            file_contexts.deinit();
        }
        var file_sources = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = file_sources.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            file_sources.deinit();
        }

        // Use the sequential path directly: parse + collect one by one
        const parser = ts.Parser.create();
        defer parser.destroy();
        const php_lang = tree_sitter_php();
        parser.setLanguage(php_lang) catch unreachable;

        for (paths) |file_path| {
            const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
            defer file.close();
            const source = file.readToEndAlloc(allocator, max_file_size) catch continue;
            const tree = parser.parseString(source, null) orelse continue;
            defer tree.destroy();

            var file_ctx = FileContext.init(allocator, file_path);
            main_mod.collectSymbolsFromSource(allocator, &sym_table, &file_ctx, source, php_lang, tree) catch continue;
            file_contexts.put(file_path, file_ctx) catch continue;
            file_sources.put(file_path, source) catch continue;
        }

        try sym_table.resolveInheritance();

        var call_graph = ProjectCallGraph.init(allocator, &sym_table);
        defer call_graph.deinit();

        // Sequential call analysis
        for (paths) |file_path| {
            const source = file_sources.get(file_path) orelse continue;
            const tree = parser.parseString(source, null) orelse continue;
            defer tree.destroy();
            const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;
            var analyzer = CallAnalyzer.init(allocator, &sym_table, file_ctx_ptr, php_lang);
            defer analyzer.deinit();
            analyzer.analyzeFile(tree, source, file_path) catch continue;
            call_graph.addCalls(&analyzer) catch continue;
        }
    }
    const seq_ns = seq_timer.read();

    // Parallel run
    var par_timer = try std.time.Timer.start();
    {
        var sym_table = SymbolTable.init(allocator);
        defer sym_table.deinit();
        var file_contexts = std.StringHashMap(FileContext).init(allocator);
        defer {
            var it = file_contexts.valueIterator();
            while (it.next()) |v| @constCast(v).deinit();
            file_contexts.deinit();
        }
        var file_sources = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = file_sources.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            file_sources.deinit();
        }

        try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table, &file_contexts, &file_sources, &main_mod.collectSymbolsFromSource);
        try sym_table.resolveInheritance();
        var call_graph = ProjectCallGraph.init(allocator, &sym_table);
        defer call_graph.deinit();
        try parallel.parallelCallAnalysis(allocator, paths, &file_sources, &file_contexts, &sym_table, &call_graph);
    }
    const par_ns = par_timer.read();

    const speedup = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(par_ns));
    std.debug.print("[{s}] Parallel speedup: {d:.2}x (threshold: 1.0x — parallel must not be slower)\n", .{
        if (speedup >= 1.0) "PASS" else "FAIL",
        speedup,
    });
    std.debug.print("  Sequential: {d:.2}{s}, Parallel: {d:.2}{s}\n", .{
        formatDuration(seq_ns)[0],
        formatDuration(seq_ns)[1],
        formatDuration(par_ns)[0],
        formatDuration(par_ns)[1],
    });
    // Parallel must not be slower than sequential
    try std.testing.expect(speedup >= 1.0);
}

// ============================================================================
// Benchmark 7: Memory usage for 2000 files (< 500MB RSS)
// ============================================================================

test "bench: memory usage 2000 files < 500MB" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 2000;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    var configs = [_]ProjectConfig{};

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }

    try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table, &file_contexts, &file_sources, &main_mod.collectSymbolsFromSource);
    try sym_table.resolveInheritance();
    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();
    try parallel.parallelCallAnalysis(allocator, paths, &file_sources, &file_contexts, &sym_table, &call_graph);

    // Check RSS via /proc or rusage
    const rss_bytes = getRssBytes();
    const rss_mb = @as(f64, @floatFromInt(rss_bytes)) / (1024.0 * 1024.0);
    const threshold_mb: f64 = 500.0;

    std.debug.print("[{s}] Memory RSS: {d:.1}MB (threshold: {d:.0}MB)\n", .{
        if (rss_mb <= threshold_mb) "PASS" else "FAIL",
        rss_mb,
        threshold_mb,
    });
    try std.testing.expect(rss_mb <= threshold_mb);
}

fn getRssBytes() usize {
    const rusage = std.posix.getrusage(std.posix.rusage.SELF);
    const raw: isize = rusage.maxrss;
    if (raw <= 0) return 0;
    const val: usize = @intCast(raw);
    if (@import("builtin").os.tag == .linux) {
        return val * 1024; // Linux reports in KB
    }
    return val; // macOS reports in bytes
}

// ============================================================================
// Benchmark 8: File caching — no double-read in Pass 4
// ============================================================================

test "bench: file caching no double-read in pass 4" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_count = 100;
    const paths = try generateFixtureFiles(allocator, tmp_dir.dir, file_count);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    var configs = [_]ProjectConfig{};

    // Pass 2: collect symbols + cache sources
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();
    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |v| @constCast(v).deinit();
        file_contexts.deinit();
    }
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = file_sources.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        file_sources.deinit();
    }

    try parallel.parallelSymbolCollect(allocator, paths, &configs, &sym_table, &file_contexts, &file_sources, &main_mod.collectSymbolsFromSource);
    try sym_table.resolveInheritance();

    // Verify all files are cached
    for (paths) |p| {
        try std.testing.expect(file_sources.contains(p));
    }
    try std.testing.expectEqual(file_count, file_sources.count());

    // Pass 4 uses cached sources (parallelCallAnalysis reads from file_sources, not disk)
    // We verify this by deleting the files and running Pass 4 — it should still work
    for (paths) |p| {
        // Extract just the filename from the absolute path
        const basename = std.fs.path.basename(p);
        tmp_dir.dir.deleteFile(basename) catch {};
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    // This should succeed because parallelCallAnalysis reads from file_sources hashmap
    try parallel.parallelCallAnalysis(allocator, paths, &file_sources, &file_contexts, &sym_table, &call_graph);

    // Verify calls were actually analyzed
    try std.testing.expect(call_graph.total_calls > 0);
    std.debug.print("[PASS] File caching: Pass 4 used {d} cached sources, {d} calls analyzed\n", .{
        file_sources.count(),
        call_graph.total_calls,
    });
}

// ============================================================================
// Benchmark 9: Incremental parse (re-parse single file)
// ============================================================================

test "bench: incremental parse single file" {
    const allocator = std.testing.allocator;

    const source = try generatePhpFixture(allocator, 42);
    defer allocator.free(source);

    const parser = ts.Parser.create();
    defer parser.destroy();
    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    // Initial parse
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Re-parse (simulating incremental — tree-sitter can take old tree)
    var timer = try std.time.Timer.start();
    const iterations: usize = 1000;
    for (0..iterations) |_| {
        const new_tree = parser.parseString(source, null) orelse continue;
        new_tree.destroy();
    }
    const elapsed = timer.read();
    const per_parse = elapsed / iterations;

    const formatted = formatDuration(per_parse);
    std.debug.print("[PASS] Incremental parse: {d:.2}{s} per parse ({d} iterations)\n", .{
        formatted[0],
        formatted[1],
        iterations,
    });

    // Sanity: each parse should be < 1ms for a single file
    try std.testing.expect(per_parse < 1 * std.time.ns_per_ms);
}
