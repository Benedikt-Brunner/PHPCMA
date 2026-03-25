const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");
const main_mod = @import("main.zig");
const phpdoc = @import("phpdoc.zig");
const config = @import("config.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const CallAnalyzer = call_analyzer.CallAnalyzer;

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
