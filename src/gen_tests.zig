const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table_mod = @import("symbol_table.zig");
const main_mod = @import("main.zig");
const test_gen = @import("test_gen.zig");

const SymbolTable = symbol_table_mod.SymbolTable;
const FileContext = types.FileContext;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

// ============================================================================
// Helpers
// ============================================================================

fn parsePhp(source: []const u8) ?*ts.Tree {
    const language = tree_sitter_php();
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(language) catch return null;
    return parser.parseString(source, null);
}

/// Run the full pipeline (parse → collect symbols → resolve inheritance) on a
/// generated project and return the resulting SymbolTable.  The caller must
/// deinit the returned table.
fn analyzeProject(
    arena: std.mem.Allocator,
    project: test_gen.PhpProjectSpec,
) !SymbolTable {
    const language = tree_sitter_php();

    var sym_table = SymbolTable.init(arena);
    errdefer sym_table.deinit();

    for (project.files, 0..) |file, fi| {
        const source = try test_gen.generatePhpFile(arena, file);
        const tree = parsePhp(source) orelse continue;
        defer tree.destroy();

        const path = try std.fmt.allocPrint(arena, "gen_{d}.php", .{fi});
        var file_ctx = FileContext.init(arena, path);
        defer file_ctx.deinit();

        main_mod.collectSymbolsFromSource(arena, &sym_table, &file_ctx, source, language, tree) catch continue;
    }

    sym_table.resolveInheritance() catch {};
    return sym_table;
}

/// Normalize a project so each class's namespace matches its file's namespace.
/// generateRandomProject may assign different namespaces to classes within the
/// same file, but generatePhpFile only emits the file-level namespace.  The
/// parser therefore registers every class under the file namespace.  Align the
/// spec so expectedSymbols produces the same FQCNs as the parser.
fn normalizeNamespaces(alloc: std.mem.Allocator, project: test_gen.PhpProjectSpec) !test_gen.PhpProjectSpec {
    var files: std.ArrayListUnmanaged(test_gen.PhpFileSpec) = .empty;
    for (project.files) |file| {
        var classes: std.ArrayListUnmanaged(test_gen.PhpClassSpec) = .empty;
        for (file.classes) |class| {
            var cls = class;
            cls.namespace = file.namespace;
            try classes.append(alloc, cls);
        }
        var f = file;
        f.classes = try classes.toOwnedSlice(alloc);
        try files.append(alloc, f);
    }
    return .{ .files = try files.toOwnedSlice(alloc) };
}

// ============================================================================
// Property: all declared symbols are discovered
// ============================================================================

test "property: all declared symbols are discovered" {
    const seed_count: u64 = 500;

    for (0..seed_count) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const num_classes = rng.intRangeAtMost(u32, 10, 20);
        const num_files = rng.intRangeAtMost(u32, 2, 5);

        const raw_project = try test_gen.generateRandomProject(alloc, rng, .{
            .num_files = num_files,
            .num_classes = num_classes,
            .num_functions = 2,
            .methods_per_class = rng.intRangeAtMost(u32, 1, 5),
            .properties_per_class = rng.intRangeAtMost(u32, 1, 4),
        });
        const project = try normalizeNamespaces(alloc, raw_project);

        const expected = try test_gen.expectedSymbols(alloc, project);

        var sym_table = try analyzeProject(alloc, project);
        defer sym_table.deinit();

        // Every class in spec must appear in symbol table
        for (expected) |sym| {
            switch (sym.kind) {
                .class => {
                    if (sym_table.getClass(sym.fqn) == null) {
                        std.debug.print("seed={d}: class '{s}' missing from symbol table\n", .{ seed, sym.fqn });
                        return error.TestUnexpectedResult;
                    }
                },
                .method => {
                    // sym.fqn is "Ns\\Class::method", extract class and method
                    if (std.mem.indexOf(u8, sym.fqn, "::")) |sep| {
                        const class_fqn = sym.fqn[0..sep];
                        const method_name = sym.fqn[sep + 2 ..];
                        if (sym_table.getClass(class_fqn)) |class| {
                            if (!class.methods.contains(method_name)) {
                                std.debug.print("seed={d}: method '{s}' missing\n", .{ seed, sym.fqn });
                                return error.TestUnexpectedResult;
                            }
                        }
                    }
                },
                .property => {
                    // sym.fqn is "Ns\\Class::$prop"
                    if (std.mem.indexOf(u8, sym.fqn, "::$")) |sep| {
                        const class_fqn = sym.fqn[0..sep];
                        const prop_name = sym.fqn[sep + 3 ..];
                        if (sym_table.getClass(class_fqn)) |class| {
                            if (!class.properties.contains(prop_name)) {
                                std.debug.print("seed={d}: property '{s}' missing\n", .{ seed, sym.fqn });
                                return error.TestUnexpectedResult;
                            }
                        }
                    }
                },
                .interface => {
                    if (sym_table.getInterface(sym.fqn) == null) {
                        std.debug.print("seed={d}: interface '{s}' missing\n", .{ seed, sym.fqn });
                        return error.TestUnexpectedResult;
                    }
                },
                .function => {
                    if (sym_table.getFunction(sym.fqn) == null) {
                        std.debug.print("seed={d}: function '{s}' missing\n", .{ seed, sym.fqn });
                        return error.TestUnexpectedResult;
                    }
                },
            }
        }

        // No extra classes in symbol table that aren't in spec
        var class_it = sym_table.classes.keyIterator();
        while (class_it.next()) |fqcn| {
            var found = false;
            for (expected) |sym| {
                if (sym.kind == .class and std.mem.eql(u8, sym.fqn, fqcn.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("seed={d}: extra class '{s}' in symbol table\n", .{ seed, fqcn.* });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ============================================================================
// Property: symbol counts are exact across 500 random projects
// ============================================================================

test "property: symbol counts are exact across 500 random projects" {
    const seed_count: u64 = 500;

    for (0..seed_count) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const raw_project = try test_gen.generateRandomProject(alloc, rng, .{
            .num_files = rng.intRangeAtMost(u32, 2, 5),
            .num_classes = rng.intRangeAtMost(u32, 5, 15),
            .num_functions = 2,
            .methods_per_class = rng.intRangeAtMost(u32, 1, 5),
            .properties_per_class = rng.intRangeAtMost(u32, 1, 4),
        });
        const project = try normalizeNamespaces(alloc, raw_project);

        const expected = try test_gen.expectedSymbols(alloc, project);

        var sym_table = try analyzeProject(alloc, project);
        defer sym_table.deinit();

        // Count expected symbols by kind
        var expected_classes: usize = 0;
        var expected_functions: usize = 0;
        for (expected) |sym| {
            switch (sym.kind) {
                .class => expected_classes += 1,
                .function => expected_functions += 1,
                else => {},
            }
        }

        const actual_classes = sym_table.classes.count();
        const actual_functions = sym_table.functions.count();

        if (actual_classes != expected_classes) {
            std.debug.print("seed={d}: class count mismatch: expected {d}, got {d}\n", .{ seed, expected_classes, actual_classes });
            return error.TestUnexpectedResult;
        }

        if (actual_functions != expected_functions) {
            std.debug.print("seed={d}: function count mismatch: expected {d}, got {d}\n", .{ seed, expected_functions, actual_functions });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Property: inheritance chain is fully resolved
// ============================================================================

test "property: inheritance chain is fully resolved" {
    const seed_count: u64 = 500;

    for (0..seed_count) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        // Generate chains of depth 2-8
        const depth = rng.intRangeAtMost(u32, 2, 8);
        const project = try generateInheritanceChain(alloc, depth);

        var sym_table = try analyzeProject(alloc, project);
        defer sym_table.deinit();

        // Verify the deepest class has inherited all parent methods
        const leaf_fqn = try std.fmt.allocPrint(alloc, "App\\Chain\\Class{d}", .{depth - 1});
        const leaf = sym_table.getClass(leaf_fqn) orelse {
            std.debug.print("seed={d}: leaf class '{s}' not found\n", .{ seed, leaf_fqn });
            return error.TestUnexpectedResult;
        };

        // all_methods should include inherited methods
        // The root class (Class0) has a method "rootMethod"
        if (!leaf.all_methods.contains("rootMethod")) {
            std.debug.print("seed={d}: leaf class missing inherited 'rootMethod'\n", .{seed});
            return error.TestUnexpectedResult;
        }

        // parent_chain should have correct length (depth - 1 parents)
        if (leaf.parent_chain.len != depth - 1) {
            std.debug.print("seed={d}: parent_chain length: expected {d}, got {d}\n", .{ seed, depth - 1, leaf.parent_chain.len });
            return error.TestUnexpectedResult;
        }

        // parent_chain order: immediate parent first
        const immediate_parent = try std.fmt.allocPrint(alloc, "App\\Chain\\Class{d}", .{depth - 2});
        if (!std.mem.eql(u8, leaf.parent_chain[0], immediate_parent)) {
            std.debug.print("seed={d}: parent_chain[0] expected '{s}', got '{s}'\n", .{ seed, immediate_parent, leaf.parent_chain[0] });
            return error.TestUnexpectedResult;
        }
    }
}

/// Generate a linear inheritance chain: Class0 <- Class1 <- ... <- Class(depth-1)
fn generateInheritanceChain(alloc: std.mem.Allocator, depth: u32) !test_gen.PhpProjectSpec {
    var classes: std.ArrayListUnmanaged(test_gen.PhpClassSpec) = .empty;

    for (0..depth) |i| {
        const name = try std.fmt.allocPrint(alloc, "Class{d}", .{i});
        const extends: ?[]const u8 = if (i > 0)
            try std.fmt.allocPrint(alloc, "Class{d}", .{i - 1})
        else
            null;

        var methods: std.ArrayListUnmanaged(test_gen.PhpMethodSpec) = .empty;
        if (i == 0) {
            // Root class has a method to verify inheritance
            try methods.append(alloc, .{
                .name = "rootMethod",
                .visibility = .public,
                .is_static = false,
                .params = &.{},
                .return_type = null,
                .body_calls = &.{},
                .body_assignments = &.{},
            });
        }
        // Each class also has its own unique method
        const method_name = try std.fmt.allocPrint(alloc, "method{d}", .{i});
        try methods.append(alloc, .{
            .name = method_name,
            .visibility = .public,
            .is_static = false,
            .params = &.{},
            .return_type = null,
            .body_calls = &.{},
            .body_assignments = &.{},
        });

        try classes.append(alloc, .{
            .name = name,
            .namespace = "App\\Chain",
            .extends = extends,
            .implements = &.{},
            .uses = &.{},
            .methods = try methods.toOwnedSlice(alloc),
            .properties = &.{},
            .is_abstract = false,
            .is_final = false,
        });
    }

    var files: std.ArrayListUnmanaged(test_gen.PhpFileSpec) = .empty;
    try files.append(alloc, .{
        .namespace = "App\\Chain",
        .use_statements = &.{},
        .classes = try classes.toOwnedSlice(alloc),
        .functions = &.{},
    });

    return .{
        .files = try files.toOwnedSlice(alloc),
    };
}

// ============================================================================
// Property: namespace resolution is correct
// ============================================================================

test "property: namespace resolution is correct" {
    const seed_count: u64 = 500;

    for (0..seed_count) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const raw_project = try test_gen.generateRandomProject(alloc, rng, .{
            .num_files = rng.intRangeAtMost(u32, 2, 5),
            .num_classes = rng.intRangeAtMost(u32, 5, 15),
            .num_functions = 2,
            .methods_per_class = 2,
            .properties_per_class = 1,
        });
        const project = try normalizeNamespaces(alloc, raw_project);

        const expected = try test_gen.expectedSymbols(alloc, project);

        var sym_table = try analyzeProject(alloc, project);
        defer sym_table.deinit();

        // FQCN in symbol table must match namespace\ClassName from expected
        for (expected) |sym| {
            if (sym.kind != .class) continue;

            // The expected FQN should be namespace\ClassName
            if (sym_table.getClass(sym.fqn) == null) {
                std.debug.print("seed={d}: class '{s}' FQCN not found in symbol table\n", .{ seed, sym.fqn });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ============================================================================
// Property: idempotency — analyzing twice gives identical results
// ============================================================================

test "property: idempotency — analyzing twice gives identical results" {
    const seed_count: u64 = 500;

    for (0..seed_count) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const raw_project = try test_gen.generateRandomProject(alloc, rng, .{
            .num_files = rng.intRangeAtMost(u32, 2, 4),
            .num_classes = rng.intRangeAtMost(u32, 3, 10),
            .num_functions = 1,
            .methods_per_class = 2,
            .properties_per_class = 1,
        });
        const project = try normalizeNamespaces(alloc, raw_project);

        // First analysis
        var sym_table1 = try analyzeProject(alloc, project);
        defer sym_table1.deinit();

        // Second analysis
        var sym_table2 = try analyzeProject(alloc, project);
        defer sym_table2.deinit();

        // Same class count
        if (sym_table1.classes.count() != sym_table2.classes.count()) {
            std.debug.print("seed={d}: class count differs: {d} vs {d}\n", .{ seed, sym_table1.classes.count(), sym_table2.classes.count() });
            return error.TestUnexpectedResult;
        }

        // Same function count
        if (sym_table1.functions.count() != sym_table2.functions.count()) {
            std.debug.print("seed={d}: function count differs: {d} vs {d}\n", .{ seed, sym_table1.functions.count(), sym_table2.functions.count() });
            return error.TestUnexpectedResult;
        }

        // Same interface count
        if (sym_table1.interfaces.count() != sym_table2.interfaces.count()) {
            std.debug.print("seed={d}: interface count differs: {d} vs {d}\n", .{ seed, sym_table1.interfaces.count(), sym_table2.interfaces.count() });
            return error.TestUnexpectedResult;
        }

        // Same trait count
        if (sym_table1.traits.count() != sym_table2.traits.count()) {
            std.debug.print("seed={d}: trait count differs: {d} vs {d}\n", .{ seed, sym_table1.traits.count(), sym_table2.traits.count() });
            return error.TestUnexpectedResult;
        }

        // Every class in run 1 exists in run 2
        var it = sym_table1.classes.keyIterator();
        while (it.next()) |key| {
            if (!sym_table2.classes.contains(key.*)) {
                std.debug.print("seed={d}: class '{s}' in run 1 but not run 2\n", .{ seed, key.* });
                return error.TestUnexpectedResult;
            }
        }
    }
}
