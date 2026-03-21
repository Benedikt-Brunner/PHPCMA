const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const cfg_mod = @import("cfg.zig");
const symbol_table = @import("symbol_table.zig");

const TypeInfo = types.TypeInfo;
const MethodSymbol = types.MethodSymbol;
const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const CFG = cfg_mod.CFG;
const BasicBlock = cfg_mod.BasicBlock;
const CfgBuilder = cfg_mod.CfgBuilder;

// ============================================================================
// Return Type Checker — verifies method return values against declared types
// ============================================================================

pub const Diagnostic = struct {
    kind: Kind,
    file_path: []const u8,
    method_name: []const u8,
    class_name: []const u8,
    line: u32,
    declared_type: []const u8,
    actual_type: []const u8,

    pub const Kind = enum {
        return_type_mismatch,
        missing_return,
        return_null_non_nullable,
        void_with_value,
    };

    pub fn format(self: *const Diagnostic, allocator: std.mem.Allocator) ![]const u8 {
        const kind_str = switch (self.kind) {
            .return_type_mismatch => "return type mismatch",
            .missing_return => "missing return",
            .return_null_non_nullable => "return null in non-nullable",
            .void_with_value => "void method returns value",
        };
        return std.fmt.allocPrint(allocator, "{s}:{d}: {s}: {s}::{s} — declared {s}, got {s}", .{
            self.file_path,
            self.line,
            kind_str,
            self.class_name,
            self.method_name,
            self.declared_type,
            self.actual_type,
        });
    }
};

pub const CheckResult = struct {
    diagnostics: []const Diagnostic,
    methods_analyzed: u32,
    methods_verified: u32,
    methods_uncertain: u32,
};

pub const ReturnTypeChecker = struct {
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    language: *const ts.Language,
    methods_analyzed: u32,
    methods_verified: u32,
    methods_uncertain: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        language: *const ts.Language,
    ) ReturnTypeChecker {
        return .{
            .allocator = allocator,
            .sym_table = sym_table,
            .diagnostics = .empty,
            .language = language,
            .methods_analyzed = 0,
            .methods_verified = 0,
            .methods_uncertain = 0,
        };
    }

    pub fn deinit(self: *ReturnTypeChecker) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn result(self: *const ReturnTypeChecker) CheckResult {
        return .{
            .diagnostics = self.diagnostics.items,
            .methods_analyzed = self.methods_analyzed,
            .methods_verified = self.methods_verified,
            .methods_uncertain = self.methods_uncertain,
        };
    }

    pub fn analyzeMethod(
        self: *ReturnTypeChecker,
        method: *const MethodSymbol,
        class_name: []const u8,
        source: []const u8,
        tree: *ts.Tree,
    ) !void {
        self.methods_analyzed += 1;

        const declared = method.effectiveReturnType() orelse {
            self.methods_uncertain += 1;
            return;
        };

        if (method.is_abstract) {
            self.methods_verified += 1;
            return;
        }

        const method_node = findMethodNode(tree.rootNode(), method.start_byte, method.end_byte) orelse {
            self.methods_uncertain += 1;
            return;
        };

        const body = method_node.childByFieldName("body") orelse {
            self.methods_verified += 1;
            return;
        };

        const is_void = declared.kind == .void_type or std.mem.eql(u8, declared.base_type, "void");
        const is_never = declared.kind == .never or std.mem.eql(u8, declared.base_type, "never");

        const diag_count_before = self.diagnostics.items.len;

        // Step 1: Find all return statements in the method body AST.
        var return_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
        defer return_nodes.deinit(self.allocator);
        collectReturnStatements(body, &return_nodes, self.allocator);

        // Step 2: Check each return statement.
        for (return_nodes.items) |ret_node| {
            const has_value = ret_node.namedChildCount() > 0;
            const line = ret_node.startPoint().row + 1;

            if (is_void) {
                if (has_value) {
                    const actual = if (ret_node.namedChild(0)) |expr|
                        inferLiteralType(expr, source) orelse "expression"
                    else
                        "expression";
                    try self.diagnostics.append(self.allocator, .{
                        .kind = .void_with_value,
                        .file_path = method.file_path,
                        .method_name = method.name,
                        .class_name = class_name,
                        .line = line,
                        .declared_type = "void",
                        .actual_type = actual,
                    });
                }
            } else {
                if (has_value) {
                    if (ret_node.namedChild(0)) |expr| {
                        if (inferLiteralType(expr, source)) |actual| {
                            if (!isTypeCompatible(declared, actual)) {
                                const declared_str = declared.format(self.allocator) catch "?";
                                try self.diagnostics.append(self.allocator, .{
                                    .kind = .return_type_mismatch,
                                    .file_path = method.file_path,
                                    .method_name = method.name,
                                    .class_name = class_name,
                                    .line = line,
                                    .declared_type = declared_str,
                                    .actual_type = actual,
                                });
                            }

                            if (std.mem.eql(u8, actual, "null") and declared.kind != .nullable and
                                declared.kind != .mixed and !std.mem.eql(u8, declared.base_type, "mixed"))
                            {
                                const declared_str = declared.format(self.allocator) catch "?";
                                try self.diagnostics.append(self.allocator, .{
                                    .kind = .return_null_non_nullable,
                                    .file_path = method.file_path,
                                    .method_name = method.name,
                                    .class_name = class_name,
                                    .line = line,
                                    .declared_type = declared_str,
                                    .actual_type = "null",
                                });
                            }
                        }
                    }
                } else {
                    const declared_str = declared.format(self.allocator) catch "?";
                    try self.diagnostics.append(self.allocator, .{
                        .kind = .missing_return,
                        .file_path = method.file_path,
                        .method_name = method.name,
                        .class_name = class_name,
                        .line = line,
                        .declared_type = declared_str,
                        .actual_type = "void",
                    });
                }
            }
        }

        // Step 3: Use CFG to check if all code paths return.
        if (!is_void and !is_never) {
            var builder = CfgBuilder.init(self.allocator, self.language);
            defer builder.deinit();
            var method_cfg = builder.buildFromBody(body) catch {
                self.methods_uncertain += 1;
                return;
            };
            defer method_cfg.deinit();

            if (!allPathsReturn(&method_cfg)) {
                const declared_str = declared.format(self.allocator) catch "?";
                try self.diagnostics.append(self.allocator, .{
                    .kind = .missing_return,
                    .file_path = method.file_path,
                    .method_name = method.name,
                    .class_name = class_name,
                    .line = method.end_line,
                    .declared_type = declared_str,
                    .actual_type = "void",
                });
            }
        }

        if (self.diagnostics.items.len == diag_count_before) {
            self.methods_verified += 1;
        }
    }

    pub fn toText(self: *const ReturnTypeChecker, writer: std.fs.File) !void {
        const res = self.result();

        const header = try std.fmt.allocPrint(self.allocator,
            \\Return Type Verification
            \\========================
            \\Methods analyzed: {d}
            \\Methods verified: {d}
            \\Methods uncertain: {d}
            \\Diagnostics: {d}
            \\
        , .{ res.methods_analyzed, res.methods_verified, res.methods_uncertain, res.diagnostics.len });
        try writer.writeAll(header);

        if (res.diagnostics.len > 0) {
            try writer.writeAll("\n");
        }

        for (res.diagnostics) |diag| {
            const line = try diag.format(self.allocator);
            try writer.writeAll(line);
            try writer.writeAll("\n");
        }
    }
};

// ============================================================================
// CFG Analysis
// ============================================================================

fn allPathsReturn(method_cfg: *const CFG) bool {
    const block_count = method_cfg.blocks.items.len;
    if (block_count == 0) return true;

    var reachable = std.StaticBitSet(1024).initEmpty();
    var stack: [256]u32 = undefined;
    var stack_len: usize = 0;
    stack[0] = method_cfg.entry;
    stack_len = 1;
    reachable.set(method_cfg.entry);

    while (stack_len > 0) {
        stack_len -= 1;
        const blk_id = stack[stack_len];
        const blk = method_cfg.getBlock(blk_id);
        for (blk.successors.items) |succ| {
            if (!reachable.isSet(succ)) {
                reachable.set(succ);
                if (stack_len < stack.len) {
                    stack[stack_len] = succ;
                    stack_len += 1;
                }
            }
        }
    }

    for (method_cfg.blocks.items, 0..) |blk, i| {
        if (!reachable.isSet(i)) continue;
        if (blk.successors.items.len == 0) {
            if (blk.terminator != .return_stmt and blk.terminator != .throw_stmt) {
                return false;
            }
        }
    }

    return true;
}

// ============================================================================
// AST Helpers
// ============================================================================

fn collectReturnStatements(node: ts.Node, results: *std.ArrayListUnmanaged(ts.Node), allocator: std.mem.Allocator) void {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "return_statement")) {
        results.append(allocator, node) catch {};
        return;
    }
    if (std.mem.eql(u8, kind, "function_definition") or
        std.mem.eql(u8, kind, "anonymous_function_creation_expression") or
        std.mem.eql(u8, kind, "arrow_function"))
    {
        return;
    }
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        if (node.child(i)) |child| {
            collectReturnStatements(child, results, allocator);
        }
    }
}

fn findMethodNode(node: ts.Node, start_byte: u32, end_byte: u32) ?ts.Node {
    if (node.startByte() == start_byte and node.endByte() == end_byte) {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "method_declaration") or std.mem.eql(u8, kind, "function_definition")) {
            return node;
        }
    }
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (node.namedChild(i)) |child| {
            if (findMethodNode(child, start_byte, end_byte)) |found| return found;
        }
    }
    return null;
}

// ============================================================================
// Type Compatibility
// ============================================================================

fn isTypeCompatible(declared: TypeInfo, actual: []const u8) bool {
    if (declared.kind == .mixed or std.mem.eql(u8, declared.base_type, "mixed")) return true;
    if (declared.kind == .nullable and std.mem.eql(u8, actual, "null")) return true;

    if (declared.kind == .union_type) {
        for (declared.type_parts) |part| {
            if (typeNameMatches(part, actual)) return true;
        }
        return false;
    }

    if (typeNameMatches(declared.base_type, actual)) return true;
    if (isNumericAlias(declared.base_type, actual)) return true;

    return false;
}

fn typeNameMatches(declared: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, declared, actual)) return true;
    if (std.mem.endsWith(u8, actual, declared)) {
        if (actual.len > declared.len and actual[actual.len - declared.len - 1] == '\\') return true;
    }
    if (std.mem.endsWith(u8, declared, actual)) {
        if (declared.len > actual.len and declared[declared.len - actual.len - 1] == '\\') return true;
    }
    return false;
}

fn isNumericAlias(a: []const u8, b: []const u8) bool {
    if ((std.mem.eql(u8, a, "int") and std.mem.eql(u8, b, "integer")) or
        (std.mem.eql(u8, a, "integer") and std.mem.eql(u8, b, "int")))
        return true;
    if ((std.mem.eql(u8, a, "float") and std.mem.eql(u8, b, "double")) or
        (std.mem.eql(u8, a, "double") and std.mem.eql(u8, b, "float")))
        return true;
    if ((std.mem.eql(u8, a, "bool") and std.mem.eql(u8, b, "boolean")) or
        (std.mem.eql(u8, a, "boolean") and std.mem.eql(u8, b, "bool")))
        return true;
    return false;
}

// ============================================================================
// Literal Type Inference
// ============================================================================

fn inferLiteralType(node: ts.Node, source: []const u8) ?[]const u8 {
    const kind = node.kind();

    if (std.mem.eql(u8, kind, "integer")) return "int";
    if (std.mem.eql(u8, kind, "float")) return "float";
    if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "encapsed_string")) return "string";
    if (std.mem.eql(u8, kind, "boolean")) return "bool";
    if (std.mem.eql(u8, kind, "null")) return "null";
    if (std.mem.eql(u8, kind, "array_creation_expression")) return "array";
    if (std.mem.eql(u8, kind, "heredoc") or std.mem.eql(u8, kind, "nowdoc")) return "string";

    if (std.mem.eql(u8, kind, "unary_op_expression")) {
        if (node.namedChild(0)) |operand| {
            const op_kind = operand.kind();
            if (std.mem.eql(u8, op_kind, "integer")) return "int";
            if (std.mem.eql(u8, op_kind, "float")) return "float";
        }
    }

    if (std.mem.eql(u8, kind, "object_creation_expression")) {
        if (node.namedChild(0)) |class_node| {
            const class_kind = class_node.kind();
            if (std.mem.eql(u8, class_kind, "name") or std.mem.eql(u8, class_kind, "qualified_name")) {
                const start = class_node.startByte();
                const end = class_node.endByte();
                if (start < source.len and end <= source.len and start < end) {
                    return source[start..end];
                }
            }
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

extern fn tree_sitter_php() callconv(.c) *ts.Language;

fn testParse(source: []const u8) ?*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(tree_sitter_php()) catch return null;
    return parser.parseString(source, null);
}

const TestCtx = struct {
    sym_table: SymbolTable,
    file_ctx: FileContext,
    checker: ReturnTypeChecker,

    fn deinit(self: *TestCtx) void {
        self.checker.deinit();
        self.file_ctx.deinit();
        self.sym_table.deinit();
    }
};

fn setupAndCheck(allocator: std.mem.Allocator, source: []const u8) !TestCtx {
    const lang = tree_sitter_php();
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    var ctx = TestCtx{
        .sym_table = SymbolTable.init(allocator),
        .file_ctx = FileContext.init(allocator, "test.php"),
        .checker = undefined,
    };

    const main_mod = @import("main.zig");
    var collector = main_mod.SymbolCollector.init(allocator, &ctx.sym_table, &ctx.file_ctx, source, lang);
    try collector.collect(tree);

    ctx.checker = ReturnTypeChecker.init(allocator, &ctx.sym_table, lang);

    var class_it = ctx.sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const class = entry.value_ptr;
        var method_it = class.methods.iterator();
        while (method_it.next()) |m_entry| {
            const method = m_entry.value_ptr;
            try ctx.checker.analyzeMethod(method, class.fqcn, source, tree);
        }
    }

    return ctx;
}

fn countDiagnostics(result: CheckResult, kind: Diagnostic.Kind) u32 {
    var count: u32 = 0;
    for (result.diagnostics) |d| {
        if (d.kind == kind) count += 1;
    }
    return count;
}

test "simple return matches declared type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        return 42;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    const res = ctx.checker.result();
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 1), res.methods_analyzed);
}

test "return type mismatch" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        return "hello";
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expect(countDiagnostics(ctx.checker.result(), .return_type_mismatch) >= 1);
}

test "return null in non-nullable type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        return null;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expect(countDiagnostics(ctx.checker.result(), .return_null_non_nullable) >= 1);
}

test "return null in nullable passes" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): ?int {
        \\        return null;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "void method with return value" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): void {
        \\        return 42;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expect(countDiagnostics(ctx.checker.result(), .void_with_value) >= 1);
}

test "missing return in non-void method" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        $x = 1;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expect(countDiagnostics(ctx.checker.result(), .missing_return) >= 1);
}

test "multiple return paths all valid" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(bool $x): int {
        \\        if ($x) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "if/else branches both return" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(bool $flag): string {
        \\        if ($flag) {
        \\            return "yes";
        \\        } else {
        \\            return "no";
        \\        }
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "try/catch paths" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        try {
        \\            return 1;
        \\        } catch (\Exception $e) {
        \\            return 0;
        \\        }
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "early return pattern" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(int $x): int {
        \\        if ($x < 0) {
        \\            return -1;
        \\        }
        \\        return $x;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "abstract method not checked" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php abstract class Foo {
        \\    abstract public function bar(): int;
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    const res = ctx.checker.result();
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 1), res.methods_verified);
}

test "void method with bare return passes" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): void {
        \\        $x = 1;
        \\        return;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "method without return type is uncertain" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar() {
        \\        return 42;
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    const res = ctx.checker.result();
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 1), res.methods_uncertain);
}

test "complex expression degrades to uncertain" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        return $this->compute();
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 0), ctx.checker.result().diagnostics.len);
}

test "string return for int declared type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    public function bar(): int {
        \\        return "not an int";
        \\    }
        \\}
    ;
    var ctx = try setupAndCheck(alloc, source);
    defer ctx.deinit();
    try std.testing.expect(countDiagnostics(ctx.checker.result(), .return_type_mismatch) >= 1);
}
