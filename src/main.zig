const std = @import("std");
const ts = @import("tree-sitter");
const cli = @import("cli");

// New module imports
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const composer = @import("composer.zig");
const config_parser = @import("config.zig");
const phpdoc = @import("phpdoc.zig");
const type_resolver = @import("type_resolver.zig");
const generics = @import("generics.zig");
const call_analyzer = @import("call_analyzer.zig");
// Local MCP-first pipeline
const symbol_collector = @import("symbol_collector.zig");
pub const SymbolCollector = symbol_collector.SymbolCollector;
const project_index = @import("project_index.zig");
const mcp_server = @import("mcp_server.zig");

// Batch analyzers (from origin/main)
const boundary_analyzer = @import("boundary_analyzer.zig");
const type_violation_analyzer = @import("type_violation_analyzer.zig");
const return_type_checker = @import("return_type_checker.zig");
const null_safety = @import("null_safety.zig");
const NodeKindIds = @import("node_kind_ids.zig").NodeKindIds;
const parallel = @import("parallel.zig");

// Report module
const report = @import("report.zig");

// Dead code analysis
const dead_code = @import("dead_code.zig");

// JSON utility
const json_util = @import("json_util.zig");

// Framework stubs
const framework_stubs = @import("framework_stubs.zig");

// Plugin imports
const plugin_interface = @import("plugins/plugin_interface.zig");
const plugin_registry = @import("plugins/plugin_registry.zig");

// Function defined in the compiled C files
extern fn tree_sitter_php() callconv(.c) *ts.Language;

const max_file_size = 1024 * 1024 * 10;

// Type aliases for convenience
const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const FunctionSymbol = types.FunctionSymbol;
const ProjectConfig = types.ProjectConfig;
const CallAnalyzer = call_analyzer.CallAnalyzer;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;

/// Adapter matching `parallel.CollectFn` so the batch analyzers can drive the
/// local (string-based) `SymbolCollector`. The `language` argument is accepted
/// for signature compatibility but unused (the local collector matches node
/// kinds by name rather than by id).
pub fn collectSymbolsFromSource(
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    file_ctx: *FileContext,
    source: []const u8,
    language: *const ts.Language,
    tree: *ts.Tree,
) error{OutOfMemory}!void {
    _ = language;
    var collector = SymbolCollector.init(allocator, sym_table, file_ctx, source);
    try collector.collect(tree);
}

// ============================================================================
// CLI Configuration and Main
// ============================================================================

var file_config = struct {
    file: []const u8 = "",
    output: []const u8 = "",
    format: []const u8 = "text",
}{};

var project_config = struct {
    composer: []const u8 = "",
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var report_config = struct {
    composer: []const u8 = "",
    config: []const u8 = "",
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var called_before_config = struct {
    plugins: []const u8 = "",
    composer: []const u8 = "",
    config: []const u8 = "", // Path to .phpcma.json for monorepo mode
    before: []const u8 = "",
    after: []const u8 = "",
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var mcp_config = struct {
    project: []const u8 = "", // Optional default project path for load_project
}{};

var check_boundaries_config = struct {
    config: []const u8 = "", // Path to .phpcma.json (required for monorepo mode)
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var check_types_config = struct {
    config: []const u8 = "", // Path to .phpcma.json (required for monorepo mode)
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
    strict: bool = false,
    min_confidence: f64 = 0.0,
    interface_scope: []const u8 = "all",
}{};

var check_dead_config = struct {
    composer: []const u8 = "",
    config: []const u8 = "",
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
    fail_on_dead: bool = false,
    include_public_methods: bool = false,
    include_public_properties: bool = false,
    show_reasons: bool = false,
    max_results: u32 = 0,
    group_by: []const u8 = "kind",
}{};

pub fn main(init: std.process.Init) !void {
    types.io = init.io;
    var r = cli.AppRunner.init(&init);
    defer r.deinit();

    const app = cli.App{
        .command = cli.Command{
            .name = "phpcma",
            .description = .{ .one_line = "PHP Call Map Analysis - Analyze function call graphs in PHP code" },
            .target = cli.CommandTarget{
                .subcommands = try r.allocCommands(&.{
                    .{
                        .name = "file",
                        .description = .{ .one_line = "Analyze a single PHP file" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "file",
                                .short_alias = 'f',
                                .help = "PHP file to analyse",
                                .value_ref = r.mkRef(&file_config.file),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&file_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text, json, or dot (default: text)",
                                .value_ref = r.mkRef(&file_config.format),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeFile },
                        },
                    },
                    .{
                        .name = "project",
                        .description = .{ .one_line = "Analyze an entire Composer project with type resolution" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "composer",
                                .short_alias = 'c',
                                .help = "Path to composer.json",
                                .value_ref = r.mkRef(&project_config.composer),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&project_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text, json, or dot (default: text)",
                                .value_ref = r.mkRef(&project_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&project_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeProject },
                        },
                    },
                    .{
                        .name = "called-before",
                        .description = .{ .one_line = "Check if one function is always called before another" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "composer",
                                .short_alias = 'c',
                                .help = "Path to composer.json (single project mode)",
                                .value_ref = r.mkRef(&called_before_config.composer),
                            },
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json (monorepo mode)",
                                .value_ref = r.mkRef(&called_before_config.config),
                            },
                            .{
                                .long_name = "before",
                                .short_alias = 'b',
                                .help = "Function that must be called first (e.g., '::validate' or 'App\\\\Service::init')",
                                .value_ref = r.mkRef(&called_before_config.before),
                                .required = true,
                            },
                            .{
                                .long_name = "after",
                                .short_alias = 'a',
                                .help = "Function that must be called after (e.g., '::save' or 'App\\\\Service::execute')",
                                .value_ref = r.mkRef(&called_before_config.after),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&called_before_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text or json (default: text)",
                                .value_ref = r.mkRef(&called_before_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&called_before_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCalledBefore },
                        },
                    },
                    .{
                        .name = "mcp",
                        .description = .{ .one_line = "Run an MCP server (stdio) exposing the analysis engine to agents" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "project",
                                .short_alias = 'P',
                                .help = "Default project path (composer.json or .phpcma.json) for load_project. If omitted, the server auto-discovers the project by walking up from its working directory",
                                .value_ref = r.mkRef(&mcp_config.project),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = runMcp },
                        },
                    },
                    .{
                        .name = "check-boundaries",
                        .description = .{ .one_line = "Detect cross-project boundary calls in a monorepo" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json",
                                .value_ref = r.mkRef(&check_boundaries_config.config),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&check_boundaries_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text, json, or dot (default: text)",
                                .value_ref = r.mkRef(&check_boundaries_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&check_boundaries_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCheckBoundaries },
                        },
                    },
                    .{
                        .name = "check-types",
                        .description = .{ .one_line = "Analyze type violations at cross-project call sites" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json",
                                .value_ref = r.mkRef(&check_types_config.config),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&check_types_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text or json (default: text)",
                                .value_ref = r.mkRef(&check_types_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&check_types_config.verbose),
                            },
                            .{
                                .long_name = "strict",
                                .help = "Strict mode: treat warnings as errors",
                                .value_ref = r.mkRef(&check_types_config.strict),
                            },
                            .{
                                .long_name = "min-confidence",
                                .help = "Minimum resolution confidence to report (0.0-1.0)",
                                .value_ref = r.mkRef(&check_types_config.min_confidence),
                            },
                            .{
                                .long_name = "interface-scope",
                                .help = "Interface compliance scope: all or cross-project (default: all)",
                                .value_ref = r.mkRef(&check_types_config.interface_scope),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCheckTypes },
                        },
                    },
                    .{
                        .name = "report",
                        .description = .{ .one_line = "Generate a unified analysis report (text, JSON, SARIF, or Checkstyle)" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "composer",
                                .short_alias = 'c',
                                .help = "Path to composer.json (single project mode)",
                                .value_ref = r.mkRef(&report_config.composer),
                            },
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json (monorepo mode)",
                                .value_ref = r.mkRef(&report_config.config),
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&report_config.output),
                            },
                            .{
                                .long_name = "format",
                                .short_alias = 'f',
                                .help = "Output format: text, json, sarif, or checkstyle (default: text)",
                                .value_ref = r.mkRef(&report_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&report_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeReport },
                        },
                    },
                    .{
                        .name = "check-dead",
                        .description = .{ .one_line = "Detect dead (unreferenced) code in a PHP project" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "composer",
                                .short_alias = 'c',
                                .help = "Path to composer.json (single project mode)",
                                .value_ref = r.mkRef(&check_dead_config.composer),
                            },
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json (monorepo mode)",
                                .value_ref = r.mkRef(&check_dead_config.config),
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&check_dead_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text, json, sarif, or checkstyle (default: text)",
                                .value_ref = r.mkRef(&check_dead_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&check_dead_config.verbose),
                            },
                            .{
                                .long_name = "fail-on-dead",
                                .help = "Exit with code 1 when dead code is found (default: exit 0 unless there is an analysis error)",
                                .value_ref = r.mkRef(&check_dead_config.fail_on_dead),
                            },
                            .{
                                .long_name = "include-public-methods",
                                .help = "Include public methods in dead code report (off by default)",
                                .value_ref = r.mkRef(&check_dead_config.include_public_methods),
                            },
                            .{
                                .long_name = "include-public-properties",
                                .help = "Include public properties in dead code report (off by default)",
                                .value_ref = r.mkRef(&check_dead_config.include_public_properties),
                            },
                            .{
                                .long_name = "show-reasons",
                                .help = "Show why symbols were kept alive",
                                .value_ref = r.mkRef(&check_dead_config.show_reasons),
                            },
                            .{
                                .long_name = "max-results",
                                .help = "Maximum number of dead symbols to report (default: unlimited)",
                                .value_ref = r.mkRef(&check_dead_config.max_results),
                            },
                            .{
                                .long_name = "group-by",
                                .help = "Group results by: module, file, or kind (default: kind)",
                                .value_ref = r.mkRef(&check_dead_config.group_by),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCheckDead },
                        },
                    },
                }),
            },
        },
    };
    try r.run(&app);
}

fn runMcp() !void {
    // The server runs a long-lived message loop, so use a persistent allocator
    // (the loaded index must outlive each per-message arena the handlers get).
    try mcp_server.run(types.io, std.heap.page_allocator, mcp_config.project);
}

fn analyzeFile() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    const source = std.Io.Dir.cwd().readFileAlloc(types.io, file_config.file, allocator, .limited(max_file_size)) catch {
        std.debug.print("File not found at path: {s}\n", .{file_config.file});
        return;
    };
    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    // Single-file analysis using the new modules
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = FileContext.init(allocator, file_config.file);
    defer file_ctx.deinit();

    // Collect symbols
    var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source);
    try collector.collect(tree);

    // Analyze calls
    var analyzer = CallAnalyzer.init(allocator, &sym_table, &file_ctx);
    defer analyzer.deinit();
    try analyzer.analyzeFile(tree, source, file_config.file);

    // Build project call graph
    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();
    try call_graph.addCalls(&analyzer);

    // Output
    const stdout = std.Io.File.stdout();

    if (file_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, file_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, file_config.format, "json")) {
            try call_graph.toJson(out_file);
        } else if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{file_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, file_config.format, "json")) {
            try call_graph.toJson(stdout);
        } else if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(stdout);
        } else {
            try call_graph.toText(stdout);
        }
    }
}

fn analyzeProject() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Pass 1: Parse composer.json and discover files
    if (project_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from composer.json...\n");
    }

    const config = composer.parseComposerJson(allocator, project_config.composer) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    if (project_config.verbose) {
        try composer.printConfig(&config, stdout);
    }

    const files = try composer.discoverFiles(allocator, &config);

    if (project_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "\nDiscovered {d} PHP files\n\n", .{files.len});
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols from all files (parallel)
    if (project_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    // Wrap config in a single-element slice for parallelSymbolCollect
    var configs_array = try allocator.alloc(ProjectConfig, 1);
    configs_array[0] = config;

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        configs_array,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (project_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (project_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel, reusing cached sources)
    if (project_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Output results
    if (project_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, project_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, project_config.format, "json")) {
            try call_graph.toJson(out_file);
        } else if (std.mem.eql(u8, project_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{project_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, project_config.format, "json")) {
            try call_graph.toJson(stdout);
        } else if (std.mem.eql(u8, project_config.format, "dot")) {
            try call_graph.toDot(stdout);
        } else {
            try call_graph.toText(stdout);
        }
    }
}

fn analyzeCalledBefore() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Validate that either -c or -g is provided (but not both or neither)
    const has_composer = called_before_config.composer.len > 0;
    const has_config = called_before_config.config.len > 0;

    if (!has_composer and !has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Either --composer (-c) or --config (-g) must be specified\n");
        return;
    }

    if (has_composer and has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Cannot use both --composer (-c) and --config (-g) at the same time\n");
        return;
    }

    // Pass 1: Parse configuration and discover files
    var project_configs: []ProjectConfig = undefined;
    var files: []const []const u8 = undefined;

    if (has_config) {
        // Monorepo mode: parse .phpcma.json
        if (called_before_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
        }

        var phpcma_config = config_parser.parseConfigFile(allocator, called_before_config.config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        if (called_before_config.verbose) {
            try config_parser.printConfig(&phpcma_config, stdout);
            try stdout.writeStreamingAll(types.io, "\n");
        }

        // Parse all discovered composer.json files
        project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        // Discover files from all projects
        files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };
    } else {
        // Single project mode: parse composer.json
        if (called_before_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from composer.json...\n");
        }

        const single_config = composer.parseComposerJson(allocator, called_before_config.composer) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        // Create a single-element slice
        var configs_array = try allocator.alloc(ProjectConfig, 1);
        configs_array[0] = single_config;
        project_configs = configs_array;

        files = try composer.discoverFiles(allocator, &single_config);
    }

    if (called_before_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files\n\n", .{files.len});
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols from all files (parallel)
    if (called_before_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg2 = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg2);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (called_before_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (called_before_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg2 = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg2);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Plugin execution (synthetic edges)
    if (called_before_config.plugins.len > 0) {
        if (called_before_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 5: Running plugins...\n");
        }

        // Create plugin context with all project configs
        const plugin_context = plugin_interface.PluginContext{
            .allocator = allocator,
            .sym_table = &sym_table,
            .calls = call_graph.calls.items,
            .file_sources = &file_sources,
            .project_configs = project_configs,
        };

        // Parse and run each enabled plugin
        var plugin_iter = std.mem.splitSequence(u8, called_before_config.plugins, ",");
        while (plugin_iter.next()) |plugin_name_raw| {
            const plugin_name = std.mem.trim(u8, plugin_name_raw, " ");
            if (plugin_name.len == 0) continue;

            if (plugin_registry.getPlugin(plugin_name)) |plugin| {
                if (called_before_config.verbose) {
                    const msg = try std.fmt.allocPrint(allocator, "  Running plugin: {s}\n", .{plugin.name});
                    try stdout.writeStreamingAll(types.io, msg);
                }

                const edges = plugin.analyze(&plugin_context) catch |err| {
                    const err_msg = try std.fmt.allocPrint(allocator, "  Plugin error: {}\n", .{err});
                    try stdout.writeStreamingAll(types.io, err_msg);
                    continue;
                };

                // Add synthetic edges to call graph
                for (edges) |edge| {
                    try call_graph.addSyntheticEdge(
                        edge.caller_fqn,
                        edge.callee_fqn,
                        edge.file_path,
                        edge.line,
                        edge.confidence,
                    );
                }

                if (called_before_config.verbose) {
                    const msg = try std.fmt.allocPrint(allocator, "    Added {d} synthetic edges\n", .{edges.len});
                    try stdout.writeStreamingAll(types.io, msg);
                }
            } else {
                const warn_msg = try std.fmt.allocPrint(allocator, "  Warning: Unknown plugin '{s}'\n", .{plugin_name});
                try stdout.writeStreamingAll(types.io, warn_msg);
            }
        }

        if (called_before_config.verbose) {
            try stdout.writeStreamingAll(types.io, "\n");
        }
    }

    // Pass 6: Called-before analysis
    if (called_before_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 6: Running called-before analysis...\n\n");
    }

    var cb_analyzer = call_analyzer.CalledBeforeAnalyzer.init(allocator, &call_graph);
    const result = try cb_analyzer.analyze(called_before_config.before, called_before_config.after);

    // Output results
    if (called_before_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, called_before_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, called_before_config.format, "json")) {
            try cb_analyzer.toJson(result, called_before_config.before, called_before_config.after, out_file);
        } else {
            try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{called_before_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, called_before_config.format, "json")) {
            try cb_analyzer.toJson(result, called_before_config.before, called_before_config.after, stdout);
        } else {
            try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, stdout);
        }
    }

    // Exit with error code if constraint is violated
    if (!result.satisfied) {
        std.process.exit(1);
    }
}

// ============================================================================
// Test aggregation
// ============================================================================
//
// Zig only compiles tests from files reachable through the test root's analysis.
// In test mode `main`/`runMcp` aren't analyzed, so transitively-imported modules
// (and their `test` blocks) would be silently skipped. Reference every source
// file here so `zig build test` actually runs the whole suite.
test {
    _ = @import("types.zig");
    _ = @import("symbol_table.zig");
    _ = @import("symbol_collector.zig");
    _ = @import("composer.zig");
    _ = @import("config.zig");
    _ = @import("phpdoc.zig");
    _ = @import("type_resolver.zig");
    _ = @import("call_analyzer.zig");
    _ = @import("project_index.zig");
    _ = @import("query.zig");
    _ = @import("references.zig");
    _ = @import("di_config.zig");
    _ = @import("boundary_analyzer.zig");
    _ = @import("mcp_server.zig");
    _ = @import("plugins/plugin_interface.zig");
    _ = @import("plugins/plugin_registry.zig");
    _ = @import("plugins/symfony_event_plugin.zig");
}

fn analyzeCheckBoundaries() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Pass 1: Parse .phpcma.json and discover files
    if (check_boundaries_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
    }

    var phpcma_config = config_parser.parseConfigFile(allocator, check_boundaries_config.config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    if (check_boundaries_config.verbose) {
        try config_parser.printConfig(&phpcma_config, stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    const project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    const files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    if (check_boundaries_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files from {d} projects\n\n", .{ files.len, project_configs.len });
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols (parallel)
    if (check_boundaries_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (check_boundaries_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (check_boundaries_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (check_boundaries_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Boundary analysis
    if (check_boundaries_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 5: Analyzing cross-project boundaries...\n\n");
    }

    var ba = boundary_analyzer.BoundaryAnalyzer.init(allocator, &call_graph, project_configs, &sym_table);
    const result = try ba.analyze(.{});

    // Output results
    if (check_boundaries_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, check_boundaries_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, check_boundaries_config.format, "json")) {
            try ba.toJson(&result, out_file);
        } else if (std.mem.eql(u8, check_boundaries_config.format, "dot")) {
            try ba.toDot(&result, out_file);
        } else {
            try ba.toText(&result, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{check_boundaries_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, check_boundaries_config.format, "json")) {
            try ba.toJson(&result, stdout);
        } else if (std.mem.eql(u8, check_boundaries_config.format, "dot")) {
            try ba.toDot(&result, stdout);
        } else {
            try ba.toText(&result, stdout);
        }
    }
}

fn analyzeCheckTypes() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Pass 1: Parse .phpcma.json and discover files
    if (check_types_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
    }

    var phpcma_config = config_parser.parseConfigFile(allocator, check_types_config.config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    if (check_types_config.verbose) {
        try config_parser.printConfig(&phpcma_config, stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    const project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    const files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
        try stdout.writeStreamingAll(types.io, msg);
        return;
    };

    if (check_types_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files from {d} projects\n\n", .{ files.len, project_configs.len });
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols (parallel)
    if (check_types_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (check_types_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (check_types_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (check_types_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Type violation analysis
    if (check_types_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 5: Analyzing cross-project type violations...\n\n");
    }

    var tva = type_violation_analyzer.TypeViolationAnalyzer.init(allocator, &call_graph, project_configs, &sym_table);
    tva.min_confidence = @floatCast(check_types_config.min_confidence);
    tva.strict = check_types_config.strict;
    tva.interface_scope = if (std.mem.eql(u8, check_types_config.interface_scope, "cross-project"))
        .cross_project
    else
        .all;
    const result = try tva.analyze();

    // Output results
    if (check_types_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, check_types_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, check_types_config.format, "json")) {
            try tva.toJson(&result, out_file);
        } else {
            try tva.toText(&result, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{check_types_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, check_types_config.format, "json")) {
            try tva.toJson(&result, stdout);
        } else {
            try tva.toText(&result, stdout);
        }
    }

    // Exit with error code if there are errors (or warnings in strict mode)
    if (result.error_count > 0) {
        std.process.exit(1);
    }
    if (check_types_config.strict and result.warning_count > 0) {
        std.process.exit(1);
    }
}

fn analyzeCheckDead() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Validate input
    const has_composer = check_dead_config.composer.len > 0;
    const has_config = check_dead_config.config.len > 0;

    if (!has_composer and !has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Either --composer (-c) or --config (-g) must be specified\n");
        return;
    }

    if (has_composer and has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Cannot use both --composer (-c) and --config (-g) at the same time\n");
        return;
    }

    // Pass 1: Discover files
    var project_configs: []ProjectConfig = undefined;
    var files: []const []const u8 = undefined;

    if (has_config) {
        if (check_dead_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
        }

        var phpcma_config = config_parser.parseConfigFile(allocator, check_dead_config.config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        if (check_dead_config.verbose) {
            try config_parser.printConfig(&phpcma_config, stdout);
            try stdout.writeStreamingAll(types.io, "\n");
        }

        project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };
    } else {
        if (check_dead_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from composer.json...\n");
        }

        const single_config = composer.parseComposerJson(allocator, check_dead_config.composer) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        var configs_array = try allocator.alloc(ProjectConfig, 1);
        configs_array[0] = single_config;
        project_configs = configs_array;
        files = try composer.discoverFiles(allocator, &single_config);
    }

    if (check_dead_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files\n\n", .{files.len});
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols
    if (check_dead_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    // Register framework API stubs
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (check_dead_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls
    if (check_dead_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Dead code analysis
    if (check_dead_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 5: Running dead code analysis...\n");
    }

    // Extract liveness references from call graph
    const refs = try dead_code.extractRefsFromCallGraph(allocator, &call_graph, &sym_table);
    defer allocator.free(refs);

    // Run liveness analysis
    var graph = dead_code.ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym_table, refs);

    // Collect dead symbols
    const dead_symbols = try graph.collectDead(&sym_table);
    defer allocator.free(dead_symbols);

    // Count statistics
    var dead_classes: usize = 0;
    var dead_interfaces: usize = 0;
    var dead_traits: usize = 0;
    var dead_functions: usize = 0;
    var dead_methods: usize = 0;
    var dead_properties: usize = 0;
    var dead_methods_private: usize = 0;
    var dead_methods_public: usize = 0;

    for (dead_symbols) |d| {
        switch (d.kind) {
            .class => dead_classes += 1,
            .interface => dead_interfaces += 1,
            .trait => dead_traits += 1,
            .function => dead_functions += 1,
            .method => {
                dead_methods += 1;
                const vis = dead_code.ProjectLivenessGraph.getMethodVisibility(d.fqn, &sym_table);
                if (vis == .private) {
                    dead_methods_private += 1;
                } else {
                    dead_methods_public += 1;
                }
            },
            .property => dead_properties += 1,
        }
    }

    // Count kept-alive symbols
    const total_symbols = graph.index.count();
    var kept_unresolved: usize = 0;
    var kept_string: usize = 0;
    var kept_structure: usize = 0;
    var sid: dead_code.SymbolId = 0;
    while (sid < total_symbols) : (sid += 1) {
        if (graph.isWeaklyAlive(sid)) {
            kept_unresolved += 1;
        }
    }
    // String/reflection and structural deps tracked as weak references
    kept_string = 0;
    kept_structure = 0;

    // Filter dead symbols based on config flags
    var filtered_dead = std.ArrayListUnmanaged(dead_code.DeadSymbol).empty;
    defer filtered_dead.deinit(allocator);

    for (dead_symbols) |d| {
        switch (d.kind) {
            .method => {
                const vis = dead_code.ProjectLivenessGraph.getMethodVisibility(d.fqn, &sym_table);
                if (vis != .private and !check_dead_config.include_public_methods) continue;
            },
            .property => {
                if (!check_dead_config.include_public_properties) {
                    // Check if property is public
                    const owner_fqn = if (std.mem.indexOf(u8, d.fqn, "::")) |sep| d.fqn[0..sep] else continue;
                    const raw_name = d.fqn[(std.mem.indexOf(u8, d.fqn, "::") orelse continue) + 2 ..];
                    const prop_name = if (raw_name.len > 0 and raw_name[0] == '$') raw_name[1..] else raw_name;
                    if (sym_table.classes.get(owner_fqn)) |class| {
                        if (class.properties.get(prop_name)) |prop| {
                            if (prop.visibility != .private) continue;
                        }
                    }
                }
            },
            else => {},
        }
        try filtered_dead.append(allocator, d);
    }

    // Apply max-results limit
    var results_to_show = filtered_dead.items;
    if (check_dead_config.max_results > 0 and results_to_show.len > check_dead_config.max_results) {
        results_to_show = results_to_show[0..check_dead_config.max_results];
    }

    if (check_dead_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "  Total symbols: {d}, Dead: {d}, Filtered: {d}\n\n", .{
            total_symbols, dead_symbols.len, results_to_show.len,
        });
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Output
    const out_file = if (check_dead_config.output.len > 0) blk: {
        break :blk try std.Io.Dir.cwd().createFile(types.io, check_dead_config.output, .{});
    } else stdout;

    defer {
        if (check_dead_config.output.len > 0) {
            out_file.close(types.io);
        }
    }

    if (std.mem.eql(u8, check_dead_config.format, "json")) {
        try writeDeadCodeJson(allocator, out_file, results_to_show, dead_classes, dead_interfaces, dead_traits, dead_functions, dead_methods, dead_properties, dead_methods_private, dead_methods_public, kept_unresolved, kept_string, kept_structure);
    } else if (std.mem.eql(u8, check_dead_config.format, "sarif")) {
        try writeDeadCodeSarif(out_file, results_to_show);
    } else if (std.mem.eql(u8, check_dead_config.format, "checkstyle")) {
        try writeDeadCodeCheckstyle(out_file, results_to_show);
    } else {
        try writeDeadCodeText(out_file, results_to_show, dead_classes, dead_interfaces, dead_traits, dead_functions, dead_methods, dead_properties, dead_methods_private, dead_methods_public, kept_unresolved, kept_string, kept_structure);
    }

    if (check_dead_config.output.len > 0) {
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{check_dead_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    }

    if (shouldFailOnDead(check_dead_config.fail_on_dead, filtered_dead.items.len)) {
        std.process.exit(1);
    }
}

fn shouldFailOnDead(fail_on_dead: bool, dead_count: usize) bool {
    return fail_on_dead and dead_count > 0;
}

fn writeDeadCodeText(
    file: std.Io.File,
    results: []const dead_code.DeadSymbol,
    dead_classes: usize,
    dead_interfaces: usize,
    dead_traits: usize,
    dead_functions: usize,
    dead_methods: usize,
    dead_properties: usize,
    dead_methods_private: usize,
    dead_methods_public: usize,
    kept_unresolved: usize,
    kept_string: usize,
    kept_structure: usize,
) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(types.io, &buf);
    const writer = &w.interface;

    try writer.writeAll("Dead Code Analysis\n");
    try writer.writeAll("==================\n");
    try writer.print("Dead classes:     {d}\n", .{dead_classes});
    try writer.print("Dead interfaces:   {d}\n", .{dead_interfaces});
    try writer.print("Dead traits:       {d}\n", .{dead_traits});
    try writer.print("Dead functions:    {d}\n", .{dead_functions});
    try writer.print("Dead methods:     {d} ({d} private, {d} public)\n", .{ dead_methods, dead_methods_private, dead_methods_public });
    try writer.print("Dead properties:  {d} (private only)\n\n", .{dead_properties});

    if (kept_unresolved > 0 or kept_string > 0 or kept_structure > 0) {
        try writer.writeAll("Conservatively kept alive:\n");
        try writer.print("  By unresolved calls:    {d} symbols\n", .{kept_unresolved});
        try writer.print("  By string/reflection:    {d} symbols\n", .{kept_string});
        try writer.print("  By structural deps:     {d} symbols\n\n", .{kept_structure});
    }

    if (results.len > 0) {
        try writer.writeAll("Definitely dead symbols:\n");
        for (results) |d| {
            const kind_str = switch (d.kind) {
                .class => "class",
                .interface => "interface",
                .trait => "trait",
                .function => "function",
                .method => "method",
                .property => "property",
            };
            try writer.print("  [DEAD] {s} ({s})\n", .{ d.fqn, kind_str });
            try writer.print("    at {s}:{d}\n", .{ d.file_path, d.line });
        }
    }

    try writer.flush();
}

fn writeDeadCodeJson(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    results: []const dead_code.DeadSymbol,
    dead_classes: usize,
    dead_interfaces: usize,
    dead_traits: usize,
    dead_functions: usize,
    dead_methods: usize,
    dead_properties: usize,
    dead_methods_private: usize,
    dead_methods_public: usize,
    kept_unresolved: usize,
    kept_string: usize,
    kept_structure: usize,
) !void {
    _ = allocator;
    var buf: [4096]u8 = undefined;
    var w = file.writer(types.io, &buf);
    const writer = &w.interface;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"dead_code\": {\n");
    try writer.print("    \"dead_classes\": {d},\n", .{dead_classes});
    try writer.print("    \"dead_interfaces\": {d},\n", .{dead_interfaces});
    try writer.print("    \"dead_traits\": {d},\n", .{dead_traits});
    try writer.print("    \"dead_functions\": {d},\n", .{dead_functions});
    try writer.print("    \"dead_methods\": {d},\n", .{dead_methods});
    try writer.print("    \"dead_properties\": {d},\n", .{dead_properties});
    try writer.print("    \"dead_methods_private\": {d},\n", .{dead_methods_private});
    try writer.print("    \"dead_methods_public\": {d},\n", .{dead_methods_public});
    try writer.print("    \"kept_alive_by_unresolved\": {d},\n", .{kept_unresolved});
    try writer.print("    \"kept_alive_by_string\": {d},\n", .{kept_string});
    try writer.print("    \"kept_alive_by_structure\": {d},\n", .{kept_structure});
    try writer.writeAll("    \"dead_symbols\": [");
    for (results, 0..) |d, i| {
        if (i > 0) try writer.writeAll(",");
        const kind_str = switch (d.kind) {
            .class => "class",
            .interface => "interface",
            .trait => "trait",
            .function => "function",
            .method => "method",
            .property => "property",
        };
        try writer.writeAll("\n      {\"fqn\": ");
        try json_util.writeJsonString(writer, d.fqn);
        try writer.writeAll(", \"kind\": ");
        try json_util.writeJsonString(writer, kind_str);
        try writer.writeAll(", \"file\": ");
        try json_util.writeJsonString(writer, d.file_path);
        try writer.print(", \"line\": {d}", .{d.line});
        try writer.writeAll("}");
    }
    if (results.len > 0) {
        try writer.writeAll("\n    ");
    }
    try writer.writeAll("]\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeDeadCodeSarif(file: std.Io.File, results: []const dead_code.DeadSymbol) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(types.io, &buf);
    const writer = &w.interface;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"$schema\": \"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json\",\n");
    try writer.writeAll("  \"version\": \"2.1.0\",\n");
    try writer.writeAll("  \"runs\": [{\n");
    try writer.writeAll("    \"tool\": {\n");
    try writer.writeAll("      \"driver\": {\n");
    try writer.writeAll("        \"name\": \"phpcma\",\n");
    try writer.writeAll("        \"version\": \"0.4.0\",\n");
    try writer.writeAll("        \"informationUri\": \"https://github.com/benedikt-brunner/phpcma\",\n");
    try writer.writeAll("        \"rules\": [\n");
    try writer.writeAll("          {\n");
    try writer.writeAll("            \"id\": \"phpcma/dead-code\",\n");
    try writer.writeAll("            \"shortDescription\": {\n");
    try writer.writeAll("              \"text\": \"Dead code detection\"\n");
    try writer.writeAll("            },\n");
    try writer.writeAll("            \"defaultConfiguration\": {\n");
    try writer.writeAll("              \"level\": \"warning\"\n");
    try writer.writeAll("            }\n");
    try writer.writeAll("          }\n");
    try writer.writeAll("        ]\n");
    try writer.writeAll("      }\n");
    try writer.writeAll("    },\n");

    try writer.writeAll("    \"results\": [");
    for (results, 0..) |d, i| {
        if (i > 0) try writer.writeAll(",");
        const kind_str = switch (d.kind) {
            .class => "class",
            .interface => "interface",
            .trait => "trait",
            .function => "function",
            .method => "method",
            .property => "property",
        };
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"ruleId\": \"phpcma/dead-code\",\n");
        try writer.writeAll("        \"level\": \"warning\",\n");
        try writer.writeAll("        \"message\": {\n");
        try writer.writeAll("          \"text\": ");
        // Build escaped message: "Dead <kind>: <fqn>"
        try writer.writeByte('"');
        try writer.print("Dead {s}: ", .{kind_str});
        for (d.fqn) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{X:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
        try writer.writeByte('"');
        try writer.writeAll("\n        },\n");
        try writer.writeAll("        \"locations\": [{\n");
        try writer.writeAll("          \"physicalLocation\": {\n");
        try writer.writeAll("            \"artifactLocation\": {\n");
        try writer.writeAll("              \"uri\": ");
        try json_util.writeJsonString(writer, d.file_path);
        try writer.writeAll("\n            },\n");
        try writer.writeAll("            \"region\": {\n");
        try writer.print("              \"startLine\": {d}\n", .{d.line});
        try writer.writeAll("            }\n");
        try writer.writeAll("          }\n");
        try writer.writeAll("        }]\n");
        try writer.writeAll("      }");
    }
    if (results.len > 0) {
        try writer.writeAll("\n    ");
    }
    try writer.writeAll("]\n");
    try writer.writeAll("  }]\n");
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeDeadCodeCheckstyle(file: std.Io.File, results: []const dead_code.DeadSymbol) !void {
    var buf: [4096]u8 = undefined;
    var w = file.writer(types.io, &buf);
    const writer = &w.interface;

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try writer.writeAll("<checkstyle version=\"4.3\">\n");

    if (results.len == 0) {
        try writer.writeAll("</checkstyle>\n");
        try writer.flush();
        return;
    }

    // Group by file
    var emitted: usize = 0;
    while (emitted < results.len) {
        const current_file = results[emitted].file_path;

        // Skip if already emitted
        var already_done = false;
        for (results[0..emitted]) |prev| {
            if (std.mem.eql(u8, prev.file_path, current_file)) {
                already_done = true;
                break;
            }
        }
        if (already_done) {
            emitted += 1;
            continue;
        }

        try writer.print("  <file name=\"{s}\">\n", .{current_file});

        for (results) |d| {
            if (!std.mem.eql(u8, d.file_path, current_file)) continue;
            const kind_str = switch (d.kind) {
                .class => "class",
                .interface => "interface",
                .trait => "trait",
                .function => "function",
                .method => "method",
                .property => "property",
            };
            try writer.print("    <error line=\"{d}\" column=\"1\" severity=\"warning\" message=\"Dead {s}: {s}\" source=\"phpcma.dead-code\"/>\n", .{
                d.line,
                kind_str,
                d.fqn,
            });
        }

        try writer.writeAll("  </file>\n");
        emitted += 1;
    }

    try writer.writeAll("</checkstyle>\n");
    try writer.flush();
}

fn analyzeReport() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.Io.File.stdout();

    // Validate input
    const has_composer = report_config.composer.len > 0;
    const has_config = report_config.config.len > 0;

    if (!has_composer and !has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Either --composer (-c) or --config (-g) must be specified\n");
        return;
    }

    if (has_composer and has_config) {
        try stdout.writeStreamingAll(types.io, "Error: Cannot use both --composer (-c) and --config (-g) at the same time\n");
        return;
    }

    // Discover files
    var project_configs: []ProjectConfig = undefined;
    var files: []const []const u8 = undefined;

    if (has_config) {
        if (report_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
        }

        var phpcma_config = config_parser.parseConfigFile(allocator, report_config.config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        if (report_config.verbose) {
            try config_parser.printConfig(&phpcma_config, stdout);
            try stdout.writeStreamingAll(types.io, "\n");
        }

        project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };
    } else {
        if (report_config.verbose) {
            try stdout.writeStreamingAll(types.io, "Pass 1: Discovering files from composer.json...\n");
        }

        const single_config = composer.parseComposerJson(allocator, report_config.composer) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
            try stdout.writeStreamingAll(types.io, msg);
            return;
        };

        var configs_array = try allocator.alloc(ProjectConfig, 1);
        configs_array[0] = single_config;
        project_configs = configs_array;
        files = try composer.discoverFiles(allocator, &single_config);
    }

    if (report_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files\n\n", .{files.len});
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 2: Collect symbols
    if (report_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (report_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Return type checking
    if (report_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 4: Checking return types...\n");
    }

    const php_lang = tree_sitter_php();
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(php_lang);

    var rt_checker = return_type_checker.ReturnTypeChecker.init(allocator, &sym_table, php_lang);
    defer rt_checker.deinit();

    // Iterate all classes, find methods by file, parse and check
    var class_it = sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const class = entry.value_ptr;
        var method_it = class.methods.iterator();
        while (method_it.next()) |m_entry| {
            const method = m_entry.value_ptr;
            const file_path = method.file_path;
            if (file_sources.get(file_path)) |source| {
                const tree = parser.parseString(source, null) orelse continue;
                defer tree.destroy();
                try rt_checker.analyzeMethod(method, class.fqcn, source, tree);
            }
        }
    }

    if (report_config.verbose) {
        const rt_result = rt_checker.result();
        const msg = try std.fmt.allocPrint(allocator, "  Methods analyzed: {d}, verified: {d}, uncertain: {d}, diagnostics: {d}\n\n", .{
            rt_result.methods_analyzed, rt_result.methods_verified, rt_result.methods_uncertain, rt_result.diagnostics.len,
        });
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 5: Analyze calls
    if (report_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 5: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeStreamingAll(types.io, msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 6: Null safety analysis (per-file)
    if (report_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 6: Analyzing null safety...\n");
    }

    const ns_parser = ts.Parser.create();
    defer ns_parser.destroy();
    try ns_parser.setLanguage(php_lang);

    var total_guarded: u32 = 0;
    var total_unguarded: u32 = 0;
    var null_violations: std.ArrayListUnmanaged(report.Violation) = .empty;
    defer null_violations.deinit(allocator);

    for (files) |file_path| {
        const source = file_sources.get(file_path) orelse continue;
        const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;

        const tree = ns_parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var analyzer = null_safety.NullSafetyAnalyzer.init(allocator, &sym_table, file_ctx_ptr, php_lang);
        defer analyzer.deinit();

        const result = analyzer.analyzeFile(tree, source) catch continue;

        total_guarded += result.guarded_accesses;
        total_unguarded += result.unguarded_accesses;

        for (result.violations) |v| {
            const severity: report.Violation.Severity = switch (v.severity) {
                .definite => .err,
                .possible => .warning,
                .guarded => .note,
            };
            try null_violations.append(allocator, .{
                .severity = severity,
                .category = "null-safety",
                .file_path = file_path,
                .line = v.line,
                .message = v.message,
            });
        }
    }

    if (report_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "  Guarded: {d}, Unguarded: {d}, Violations: {d}\n\n", .{ total_guarded, total_unguarded, null_violations.items.len });
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 7: Dead code analysis
    if (report_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 7: Running dead code analysis...\n");
    }

    const dc_refs = try dead_code.extractRefsFromCallGraph(allocator, &call_graph, &sym_table);
    defer allocator.free(dc_refs);

    var dc_graph = dead_code.ProjectLivenessGraph.init(allocator);
    defer dc_graph.deinit();
    try dc_graph.analyze(&sym_table, dc_refs);

    const dc_dead = try dc_graph.collectDead(&sym_table);
    defer allocator.free(dc_dead);

    if (report_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "  Dead symbols found: {d}\n\n", .{dc_dead.len});
        try stdout.writeStreamingAll(types.io, msg);
    }

    // Pass 8: Generate unified report
    if (report_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 8: Generating unified report...\n\n");
    }

    var unified_report = report.UnifiedReport.init(allocator);
    defer unified_report.deinit();
    unified_report.populate(&sym_table, &call_graph);
    unified_report.coverage.total_files = files.len;

    // Populate dead code section
    for (dc_dead) |d| {
        switch (d.kind) {
            .class => unified_report.dead_code.dead_classes += 1,
            .interface => unified_report.dead_code.dead_interfaces += 1,
            .trait => unified_report.dead_code.dead_traits += 1,
            .function => unified_report.dead_code.dead_functions += 1,
            .method => {
                unified_report.dead_code.dead_methods += 1;
                const vis = dead_code.ProjectLivenessGraph.getMethodVisibility(d.fqn, &sym_table);
                if (vis == .private) {
                    unified_report.dead_code.dead_methods_private += 1;
                } else {
                    unified_report.dead_code.dead_methods_public += 1;
                }
            },
            .property => unified_report.dead_code.dead_properties += 1,
        }

        // Add top candidates (limit to 50)
        if (unified_report.dead_code.top_dead_candidates.items.len < 50) {
            const kind_str = switch (d.kind) {
                .class => "class",
                .interface => "interface",
                .trait => "trait",
                .function => "function",
                .method => "method",
                .property => "property",
            };
            try unified_report.dead_code.top_dead_candidates.append(allocator, .{
                .fqn = d.fqn,
                .kind = kind_str,
                .file_path = d.file_path,
                .line = d.line,
            });
        }
    }

    // Count kept-alive-by-unresolved
    const dc_total = dc_graph.index.count();
    var dc_sid: dead_code.SymbolId = 0;
    while (dc_sid < dc_total) : (dc_sid += 1) {
        if (dc_graph.isWeaklyAlive(dc_sid)) {
            unified_report.dead_code.kept_alive_by_unresolved += 1;
        }
    }

    // Merge return type checker results into report
    const rt_result = rt_checker.result();
    unified_report.type_checks.return_types.pass += rt_result.methods_verified;
    unified_report.type_checks.return_types.fail += rt_result.diagnostics.len;
    unified_report.type_checks.return_types.unchecked += rt_result.methods_uncertain;

    // Emit checker diagnostics as violations
    for (rt_result.diagnostics) |diag| {
        try unified_report.addViolation(.{
            .severity = .warning,
            .category = "return-type-mismatch",
            .file_path = diag.file_path,
            .line = diag.line,
            .message = try diag.format(allocator),
        });
    }

    // Populate null safety results from real analysis
    unified_report.type_checks.null_safety.pass = total_guarded;
    unified_report.type_checks.null_safety.fail = total_unguarded;
    unified_report.type_checks.null_safety.unchecked = 0;

    // Add null safety violations
    for (null_violations.items) |v| {
        try unified_report.addViolation(v);
    }

    // Output
    const out_file = if (report_config.output.len > 0) blk: {
        break :blk try std.Io.Dir.cwd().createFile(types.io, report_config.output, .{});
    } else stdout;

    defer {
        if (report_config.output.len > 0) {
            out_file.close(types.io);
        }
    }

    if (std.mem.eql(u8, report_config.format, "json")) {
        try unified_report.toJson(out_file);
    } else if (std.mem.eql(u8, report_config.format, "sarif")) {
        try unified_report.toSarif(out_file);
    } else if (std.mem.eql(u8, report_config.format, "checkstyle")) {
        try unified_report.toCheckstyle(out_file);
    } else {
        try unified_report.toText(out_file);
    }

    if (report_config.output.len > 0) {
        const msg = try std.fmt.allocPrint(allocator, "Report written to: {s}\n", .{report_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    }
}

// ============================================================================
// Tests - SymbolCollector
// ============================================================================

fn parsePhp(_: std.mem.Allocator, source: []const u8) struct { *ts.Tree, *const ts.Language } {
    const parser = ts.Parser.create();
    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch unreachable;
    const tree = parser.parseString(source, null) orelse unreachable;
    return .{ tree, php_lang };
}

fn collectFromSource(allocator: std.mem.Allocator, source: []const u8) !struct { SymbolTable, FileContext } {
    const result = parsePhp(allocator, source);
    const tree = result[0];
    const php_lang = result[1];
    _ = php_lang;

    var sym_table = SymbolTable.init(allocator);
    var file_ctx = FileContext.init(allocator, "test.php");

    var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source);
    try collector.collect(tree);

    return .{ sym_table, file_ctx };
}

test "check-dead fail-on-dead exit semantics" {
    try std.testing.expect(!shouldFailOnDead(false, 0));
    try std.testing.expect(!shouldFailOnDead(false, 5));
    try std.testing.expect(!shouldFailOnDead(true, 0));
    try std.testing.expect(shouldFailOnDead(true, 1));
}

test "SymbolCollector: class extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class UserService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("UserService", class.?.name);
}

test "SymbolCollector: namespaced class" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App\\Service; class UserService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\Service\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("UserService", class.?.name);
}

test "SymbolCollector: extends" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App; class BaseService {} class UserService extends BaseService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("App\\BaseService", class.?.extends.?);
}

test "SymbolCollector: implements" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App; interface Loggable {} class UserService implements Loggable {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.implements.len == 1);
    try std.testing.expectEqualStrings("App\\Loggable", class.?.implements[0]);
}

test "SymbolCollector: method extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class Foo { public function doStuff(): void {} }";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("doStuff");
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("doStuff", method.?.name);
}

test "SymbolCollector: method modifiers" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    private static function secretStatic(): void {}
        \\    protected final function protFinal(): void {}
        \\    abstract public function mustImpl(): void;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);

    const m1 = class.?.methods.get("secretStatic");
    try std.testing.expect(m1 != null);
    try std.testing.expect(m1.?.visibility == .private);
    try std.testing.expect(m1.?.is_static == true);

    const m2 = class.?.methods.get("protFinal");
    try std.testing.expect(m2 != null);
    try std.testing.expect(m2.?.visibility == .protected);
    try std.testing.expect(m2.?.is_final == true);

    const m3 = class.?.methods.get("mustImpl");
    try std.testing.expect(m3 != null);
    try std.testing.expect(m3.?.is_abstract == true);
}

test "SymbolCollector: parameter parsing" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class Foo { public function bar(string $name, int $age = 0): void {} }";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("bar");
    try std.testing.expect(method != null);
    try std.testing.expect(method.?.parameters.len == 2);
    try std.testing.expectEqualStrings("name", method.?.parameters[0].name);
    try std.testing.expectEqualStrings("age", method.?.parameters[1].name);
    try std.testing.expect(method.?.parameters[1].has_default == true);
}

test "SymbolCollector: property extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    private string $name;
        \\    protected static int $count;
        \\    public readonly string $id;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);

    const p1 = class.?.properties.get("name");
    try std.testing.expect(p1 != null);
    try std.testing.expect(p1.?.visibility == .private);

    const p2 = class.?.properties.get("count");
    try std.testing.expect(p2 != null);
    try std.testing.expect(p2.?.is_static == true);
    try std.testing.expect(p2.?.visibility == .protected);

    const p3 = class.?.properties.get("id");
    try std.testing.expect(p3 != null);
    try std.testing.expect(p3.?.is_readonly == true);
}

test "SymbolCollector: constructor promotion" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Dto {
        \\    public function __construct(
        \\        private readonly string $name,
        \\        protected int $age,
        \\    ) {}
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Dto");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("__construct");
    try std.testing.expect(method != null);
    try std.testing.expect(method.?.parameters.len == 2);
    try std.testing.expect(method.?.parameters[0].is_promoted == true);
    try std.testing.expect(method.?.parameters[1].is_promoted == true);
}

test "SymbolCollector: interface extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Contract;
        \\interface UserRepositoryInterface {
        \\    public function find(int $id): ?object;
        \\    public function save(object $user): void;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const iface = result[0].getInterface("App\\Contract\\UserRepositoryInterface");
    try std.testing.expect(iface != null);
    try std.testing.expect(iface.?.methods.count() == 2);
    try std.testing.expect(iface.?.methods.contains("find"));
    try std.testing.expect(iface.?.methods.contains("save"));
}

test "SymbolCollector: trait extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Concern;
        \\trait Timestampable {
        \\    private string $createdAt;
        \\    public function getCreatedAt(): string { return $this->createdAt; }
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const trait = result[0].getTrait("App\\Concern\\Timestampable");
    try std.testing.expect(trait != null);
    try std.testing.expect(trait.?.methods.contains("getCreatedAt"));
    try std.testing.expect(trait.?.properties.contains("createdAt"));
}

test "SymbolCollector: trait use" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App;
        \\trait Loggable { public function log(): void {} }
        \\class UserService { use Loggable; }
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.uses.len == 1);
    try std.testing.expectEqualStrings("App\\Loggable", class.?.uses[0]);
}

test "SymbolCollector: use statements" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Service;
        \\use App\Repository\UserRepository;
        \\use App\Entity\User as UserEntity;
        \\class UserService {}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const ctx = &result[1];
    const repo_use = ctx.use_statements.get("UserRepository");
    try std.testing.expect(repo_use != null);
    try std.testing.expectEqualStrings("App\\Repository\\UserRepository", repo_use.?.fqcn);

    // Aliased use statement: "use App\Entity\User as UserEntity".
    // The map is keyed by the alias, and the alias must resolve to the full
    // imported FQCN (not the alias name itself) so later type resolution can
    // expand `UserEntity` to `App\Entity\User`.
    const user_use = ctx.use_statements.get("UserEntity");
    try std.testing.expect(user_use != null);
    try std.testing.expectEqualStrings("App\\Entity\\User", user_use.?.fqcn);
    try std.testing.expect(user_use.?.alias != null);
    try std.testing.expectEqualStrings("UserEntity", user_use.?.alias.?);
}

test "SymbolCollector: PHPDoc on method" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    /** @return string */
        \\    public function getName(): string { return ''; }
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("getName");
    try std.testing.expect(method != null);
    // PHPDoc return type should be parsed
    try std.testing.expect(method.?.phpdoc_return != null);
    try std.testing.expectEqualStrings("string", method.?.phpdoc_return.?.base_type);
}

test "SymbolCollector: multiple classes in file" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App;
        \\class First { public function a(): void {} }
        \\class Second { public function b(): void {} }
        \\class Third {}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    try std.testing.expect(result[0].getClass("App\\First") != null);
    try std.testing.expect(result[0].getClass("App\\Second") != null);
    try std.testing.expect(result[0].getClass("App\\Third") != null);
    try std.testing.expect(result[0].classes.count() == 3);
}

test "SymbolCollector: standalone function" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Util;
        \\function formatDate(string $date): string { return $date; }
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const func = result[0].getFunction("App\\Util\\formatDate");
    try std.testing.expect(func != null);
    try std.testing.expectEqualStrings("formatDate", func.?.name);
    try std.testing.expect(func.?.parameters.len == 1);
    try std.testing.expectEqualStrings("date", func.?.parameters[0].name);
}

test "SymbolCollector: empty class" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class EmptyClass {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("EmptyClass");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.methods.count() == 0);
    try std.testing.expect(class.?.properties.count() == 0);
    try std.testing.expect(class.?.extends == null);
    try std.testing.expect(class.?.implements.len == 0);
    try std.testing.expect(class.?.uses.len == 0);
}
