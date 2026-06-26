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
const call_analyzer = @import("call_analyzer.zig");
const symbol_collector = @import("symbol_collector.zig");
const SymbolCollector = symbol_collector.SymbolCollector;
const project_index = @import("project_index.zig");
const mcp_server = @import("mcp_server.zig");

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

var called_before_config = struct {
    composer: []const u8 = "",
    config: []const u8 = "", // Path to .phpcma.json for monorepo mode
    before: []const u8 = "",
    after: []const u8 = "",
    output: []const u8 = "",
    verbose: bool = false,
}{};

var mcp_config = struct {
    project: []const u8 = "", // Optional default project path for load_project
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
                                .help = "Output format: text or dot (default: text)",
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
                                .help = "Output format: text or dot (default: text)",
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
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
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

        if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{file_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(stdout);
        } else {
            try call_graph.toText(stdout);
        }
    }
}

fn analyzeProject() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
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

    // Passes 2-4: build the in-memory index (collect, resolve, call graph).
    var configs = [_]ProjectConfig{config};
    const index = try project_index.ProjectIndex.create(std.heap.page_allocator, files, &configs);
    defer index.destroy();

    if (project_config.verbose) {
        try index.sym_table.printStats(stdout);
        try stdout.writeStreamingAll(types.io, "\n");
    }

    // Output results
    if (project_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, project_config.output, .{});
        defer out_file.close(types.io);

        if (std.mem.eql(u8, project_config.format, "dot")) {
            try index.call_graph.toDot(out_file);
        } else {
            try index.call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{project_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        if (std.mem.eql(u8, project_config.format, "dot")) {
            try index.call_graph.toDot(stdout);
        } else {
            try index.call_graph.toText(stdout);
        }
    }
}

fn analyzeCalledBefore() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
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

    // Passes 2-5: build the in-memory index (collect, resolve, call graph) and
    // run config-enabled plugins (synthetic edges) as part of the derived build.
    // Active plugins are declared per project: `extra.phpcma.plugins` in a
    // composer.json, or a top-level `plugins` default in .phpcma.json.
    const index = try project_index.ProjectIndex.create(std.heap.page_allocator, files, project_configs);
    defer index.destroy();

    // Pass 6: Called-before analysis
    if (called_before_config.verbose) {
        try stdout.writeStreamingAll(types.io, "Pass 6: Running called-before analysis...\n\n");
    }

    var cb_analyzer = call_analyzer.CalledBeforeAnalyzer.init(allocator, &index.call_graph);
    const result = try cb_analyzer.analyze(called_before_config.before, called_before_config.after);

    // Output results
    if (called_before_config.output.len > 0) {
        const out_file = try std.Io.Dir.cwd().createFile(types.io, called_before_config.output, .{});
        defer out_file.close(types.io);
        try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, out_file);
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{called_before_config.output});
        try stdout.writeStreamingAll(types.io, msg);
    } else {
        try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, stdout);
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
