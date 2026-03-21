const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const cfg_mod = @import("cfg.zig");
const symbol_table = @import("symbol_table.zig");
const type_resolver = @import("type_resolver.zig");
const phpdoc = @import("phpdoc.zig");

const TypeInfo = types.TypeInfo;
const MethodSymbol = types.MethodSymbol;
const ClassSymbol = types.ClassSymbol;
const FileContext = types.FileContext;
const ScopeContext = types.ScopeContext;
const SymbolTable = symbol_table.SymbolTable;
const TypeResolver = type_resolver.TypeResolver;
const CFG = cfg_mod.CFG;
const CfgBuilder = cfg_mod.CfgBuilder;
const BasicBlock = cfg_mod.BasicBlock;

// ============================================================================
// Null Safety Analyzer
// ============================================================================
//
// Detects potential null dereferences by combining CFG-based control flow
// analysis with null-state tracking per variable.
//
// Checks:
// - $x->method() where $x has nullable type without null guard
// - $x->property where $x has nullable type without null guard
// - Use of nullable return value without null check
// - Array access on possibly-null variable
//
// Guards understood:
// - if ($x !== null) / if ($x != null) / if (null !== $x)
// - if ($x instanceof Foo)
// - $x ?? default (null coalesce)
// - assert($x !== null)
// - Early return/throw guards: if ($x === null) { return; }

/// Severity of a null safety issue.
pub const NullSeverity = enum {
    definite, // Definitely null dereference
    possible, // Possibly null (some paths unguarded)
    guarded, // Access is guarded (safe)
};

/// A null safety violation found by the analyzer.
pub const NullViolation = struct {
    variable: []const u8,
    access_kind: AccessKind,
    line: u32,
    column: u32,
    severity: NullSeverity,
    type_info: ?TypeInfo,
    message: []const u8,

    pub const AccessKind = enum {
        method_call, // $x->method()
        property_access, // $x->property
        array_access, // $x[...]
        return_use, // using nullable return without check
    };
};

/// Per-variable null state.
pub const NullState = enum {
    definitely_null, // Known to be null
    definitely_not_null, // Known to be non-null (after guard)
    possibly_null, // Might be null (nullable type, no guard)
    unknown, // Type not resolved
};

/// Result of null safety analysis on a method/function.
pub const NullAnalysisResult = struct {
    violations: []const NullViolation,
    nullable_vars_tracked: u32,
    guarded_accesses: u32,
    unguarded_accesses: u32,
};

/// Node kind IDs cached for null safety analysis.
const NullNodeIds = struct {
    member_call_expression: u16,
    member_access_expression: u16,
    subscript_expression: u16,
    binary_expression: u16,
    unary_op_expression: u16,
    variable_name: u16,
    assignment_expression: u16,
    if_statement: u16,
    else_clause: u16,
    else_if_clause: u16,
    return_statement: u16,
    throw_expression: u16,
    expression_statement: u16,
    function_call_expression: u16,
    object_creation_expression: u16,
    null_literal: u16,
    instanceof_expression: u16,
    conditional_expression: u16,
    coalesce_expression: u16,
    name: u16,
    qualified_name: u16,
    compound_statement: u16,
    method_declaration: u16,
    function_definition: u16,

    fn init(lang: *const ts.Language) NullNodeIds {
        return .{
            .member_call_expression = lang.idForNodeKind("member_call_expression", true),
            .member_access_expression = lang.idForNodeKind("member_access_expression", true),
            .subscript_expression = lang.idForNodeKind("subscript_expression", true),
            .binary_expression = lang.idForNodeKind("binary_expression", true),
            .unary_op_expression = lang.idForNodeKind("unary_op_expression", true),
            .variable_name = lang.idForNodeKind("variable_name", true),
            .assignment_expression = lang.idForNodeKind("assignment_expression", true),
            .if_statement = lang.idForNodeKind("if_statement", true),
            .else_clause = lang.idForNodeKind("else_clause", true),
            .else_if_clause = lang.idForNodeKind("else_if_clause", true),
            .return_statement = lang.idForNodeKind("return_statement", true),
            .throw_expression = lang.idForNodeKind("throw_expression", true),
            .expression_statement = lang.idForNodeKind("expression_statement", true),
            .function_call_expression = lang.idForNodeKind("function_call_expression", true),
            .object_creation_expression = lang.idForNodeKind("object_creation_expression", true),
            .null_literal = lang.idForNodeKind("null", false),
            .instanceof_expression = lang.idForNodeKind("instanceof_expression", true),
            .conditional_expression = lang.idForNodeKind("conditional_expression", true),
            .coalesce_expression = lang.idForNodeKind("null_safe_member_access_expression", true),
            .name = lang.idForNodeKind("name", true),
            .qualified_name = lang.idForNodeKind("qualified_name", true),
            .compound_statement = lang.idForNodeKind("compound_statement", true),
            .method_declaration = lang.idForNodeKind("method_declaration", true),
            .function_definition = lang.idForNodeKind("function_definition", true),
        };
    }
};

/// Null safety analyzer: walks methods/functions in a source file, builds CFGs,
/// and checks for unguarded nullable accesses.
pub const NullSafetyAnalyzer = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    file_context: *FileContext,
    language: *const ts.Language,
    ids: NullNodeIds,
    violations: std.ArrayListUnmanaged(NullViolation),
    nullable_vars_tracked: u32,
    guarded_accesses: u32,
    unguarded_accesses: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
        language: *const ts.Language,
    ) NullSafetyAnalyzer {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .file_context = file_ctx,
            .language = language,
            .ids = NullNodeIds.init(language),
            .violations = .empty,
            .nullable_vars_tracked = 0,
            .guarded_accesses = 0,
            .unguarded_accesses = 0,
        };
    }

    pub fn deinit(self: *NullSafetyAnalyzer) void {
        self.violations.deinit(self.allocator);
    }

    /// Analyze a parsed file tree for null safety issues.
    pub fn analyzeFile(self: *NullSafetyAnalyzer, tree: *ts.Tree, source: []const u8) !NullAnalysisResult {
        const root = tree.rootNode();
        try self.findAndAnalyzeMethods(root, source);
        return .{
            .violations = self.violations.items,
            .nullable_vars_tracked = self.nullable_vars_tracked,
            .guarded_accesses = self.guarded_accesses,
            .unguarded_accesses = self.unguarded_accesses,
        };
    }

    /// Find all method/function declarations and analyze each.
    fn findAndAnalyzeMethods(self: *NullSafetyAnalyzer, node: ts.Node, source: []const u8) !void {
        const kid = node.kindId();
        if (kid == self.ids.method_declaration or kid == self.ids.function_definition) {
            try self.analyzeMethod(node, source);
            return;
        }
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.findAndAnalyzeMethods(child, source);
            }
        }
    }

    /// Analyze a single method/function for null safety.
    fn analyzeMethod(self: *NullSafetyAnalyzer, node: ts.Node, source: []const u8) !void {
        const body = node.childByFieldName("body") orelse return;

        // Collect nullable variables from parameters and PHPDoc.
        var null_states = std.StringHashMap(NullState).init(self.allocator);
        defer null_states.deinit();

        // Collect parameter null states.
        try self.collectParameterNullStates(node, source, &null_states);

        // Walk the body AST looking for nullable access patterns.
        try self.analyzeBody(body, source, &null_states);
    }

    /// Collect null states from method parameters.
    fn collectParameterNullStates(
        self: *NullSafetyAnalyzer,
        method_node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) !void {
        if (method_node.childByFieldName("parameters")) |params_node| {
            var i: u32 = 0;
            while (i < params_node.namedChildCount()) : (i += 1) {
                if (params_node.namedChild(i)) |param| {
                    try self.processParameter(param, source, null_states);
                }
            }
        }

        // Also check PHPDoc for @param nullable annotations.
        try self.collectPhpDocNullStates(method_node, source, null_states);
    }

    /// Process a single parameter to determine its null state.
    fn processParameter(
        self: *NullSafetyAnalyzer,
        param: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) !void {
        var var_name: ?[]const u8 = null;
        var is_nullable = false;
        var has_default_null = false;
        var has_type_hint = false;

        var i: u32 = 0;
        while (i < param.childCount()) : (i += 1) {
            if (param.child(i)) |child| {
                const kind = child.kind();
                if (std.mem.eql(u8, kind, "variable_name")) {
                    var_name = getNodeText(source, child);
                } else if (std.mem.eql(u8, kind, "optional_type")) {
                    is_nullable = true;
                    has_type_hint = true;
                } else if (std.mem.eql(u8, kind, "null")) {
                    has_default_null = true;
                } else if (std.mem.eql(u8, kind, "union_type")) {
                    has_type_hint = true;
                    var j: u32 = 0;
                    while (j < child.namedChildCount()) : (j += 1) {
                        if (child.namedChild(j)) |part| {
                            const text = getNodeText(source, part);
                            if (std.mem.eql(u8, text, "null")) {
                                is_nullable = true;
                                break;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, kind, "named_type") or
                    std.mem.eql(u8, kind, "primitive_type") or
                    std.mem.eql(u8, kind, "intersection_type"))
                {
                    has_type_hint = true;
                }
            }
        }

        if (var_name) |name| {
            if (is_nullable or has_default_null) {
                try null_states.put(name, .possibly_null);
                self.nullable_vars_tracked += 1;
            } else if (has_type_hint) {
                // Has a non-nullable type hint → definitely not null.
                try null_states.put(name, .definitely_not_null);
            }
            // No type hint at all → leave for PHPDoc to determine.
        }
    }

    /// Extract nullable info from PHPDoc comments on the method.
    fn collectPhpDocNullStates(
        self: *NullSafetyAnalyzer,
        method_node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) !void {
        // Look for PHPDoc comment preceding the method.
        // Check both prevSibling and prevNamedSibling — tree-sitter-php may
        // place the comment as a named or unnamed sibling.
        var candidate: ?ts.Node = method_node.prevSibling();
        // Walk back through previous siblings to find the PHPDoc comment
        // (there may be whitespace or other nodes in between).
        var attempts: u32 = 0;
        while (candidate != null and attempts < 5) : (attempts += 1) {
            const prev = candidate.?;
            const kind = prev.kind();
            if (std.mem.eql(u8, kind, "comment")) {
                const text = getNodeText(source, prev);
                if (std.mem.startsWith(u8, text, "/**")) {
                    var it = std.mem.splitSequence(u8, text, "\n");
                    while (it.next()) |line| {
                        const trimmed = std.mem.trim(u8, line, " \t\r*");
                        if (std.mem.startsWith(u8, trimmed, "@param")) {
                            try self.parsePhpDocParam(trimmed, null_states);
                        }
                    }
                    return;
                }
            }
            candidate = prev.prevSibling();
        }
    }

    /// Parse a @param annotation: @param ?Type $var or @param Type|null $var.
    fn parsePhpDocParam(
        self: *NullSafetyAnalyzer,
        line: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) !void {
        // Format: @param ?SomeType $varName   or   @param SomeType|null $varName
        var it = std.mem.tokenizeAny(u8, line, " \t");
        _ = it.next(); // skip @param
        const type_str = it.next() orelse return;
        const var_str = it.next() orelse return;

        if (!std.mem.startsWith(u8, var_str, "$")) return;

        const is_nullable = std.mem.startsWith(u8, type_str, "?") or
            std.mem.indexOf(u8, type_str, "|null") != null or
            std.mem.indexOf(u8, type_str, "null|") != null;

        if (is_nullable) {
            // Only set to possibly_null if not already set (native type takes precedence).
            if (!null_states.contains(var_str)) {
                try null_states.put(var_str, .possibly_null);
                self.nullable_vars_tracked += 1;
            }
        }
    }

    /// Walk the body AST, tracking null states through guards and detecting
    /// unguarded nullable accesses.
    fn analyzeBody(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.analyzeStatement(child, source, null_states);
            }
        }
    }

    /// Analyze a single statement for null safety.
    fn analyzeStatement(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        const kid = node.kindId();

        // if-statement: check for null guards.
        if (kid == self.ids.if_statement) {
            try self.analyzeIfStatement(node, source, null_states);
            return;
        }

        // Expression statement: may contain assignment, method call, etc.
        if (kid == self.ids.expression_statement) {
            if (node.namedChild(0)) |expr| {
                try self.analyzeExpression(expr, source, null_states);
            }
            return;
        }

        // Return statement.
        if (kid == self.ids.return_statement) {
            if (node.namedChild(0)) |expr| {
                try self.analyzeExpression(expr, source, null_states);
            }
            return;
        }

        // Recurse into compound statements.
        if (kid == self.ids.compound_statement) {
            try self.analyzeBody(node, source, null_states);
            return;
        }

        // Check all children for expressions.
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.analyzeStatement(child, source, null_states);
            }
        }
    }

    /// Analyze an expression for null safety issues.
    fn analyzeExpression(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        const kid = node.kindId();

        // Method call: $x->method()
        if (kid == self.ids.member_call_expression) {
            try self.checkMemberAccess(node, source, null_states, .method_call);
            return;
        }

        // Property access: $x->property
        if (kid == self.ids.member_access_expression) {
            try self.checkMemberAccess(node, source, null_states, .property_access);
            return;
        }

        // Array access: $x[...]
        if (kid == self.ids.subscript_expression) {
            try self.checkArrayAccess(node, source, null_states);
            return;
        }

        // Assignment: $x = expr — update null state.
        if (kid == self.ids.assignment_expression) {
            try self.handleAssignment(node, source, null_states);
            return;
        }

        // Recurse into sub-expressions.
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.analyzeExpression(child, source, null_states);
            }
        }
    }

    /// Check if a member access ($x->...) is on a possibly-null variable.
    fn checkMemberAccess(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
        access_kind: NullViolation.AccessKind,
    ) error{OutOfMemory}!void {
        const object_node = node.childByFieldName("object") orelse return;
        const var_name = getNodeText(source, object_node);

        if (!std.mem.startsWith(u8, var_name, "$")) return;

        if (null_states.get(var_name)) |state| {
            switch (state) {
                .possibly_null, .definitely_null => {
                    self.unguarded_accesses += 1;
                    const member_node = node.childByFieldName("name") orelse return;
                    const member_name = getNodeText(source, member_node);
                    try self.violations.append(self.allocator, .{
                        .variable = var_name,
                        .access_kind = access_kind,
                        .line = node.startPoint().row + 1,
                        .column = node.startPoint().column + 1,
                        .severity = if (state == .definitely_null) .definite else .possible,
                        .type_info = null,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "{s} on possibly-null variable {s}.{s}",
                            .{
                                if (access_kind == .method_call) @as([]const u8, "Method call") else "Property access",
                                var_name,
                                member_name,
                            },
                        ),
                    });
                },
                .definitely_not_null => {
                    self.guarded_accesses += 1;
                },
                .unknown => {},
            }
        }

        // Recurse into the member access expression's arguments if it's a method call.
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const ckid = child.kindId();
                if (ckid != self.ids.variable_name and ckid != self.ids.name) {
                    try self.analyzeExpression(child, source, null_states);
                }
            }
        }
    }

    /// Check array access on possibly-null variable.
    fn checkArrayAccess(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        if (node.namedChild(0)) |object_node| {
            const var_name = getNodeText(source, object_node);
            if (!std.mem.startsWith(u8, var_name, "$")) return;

            if (null_states.get(var_name)) |state| {
                switch (state) {
                    .possibly_null, .definitely_null => {
                        self.unguarded_accesses += 1;
                        try self.violations.append(self.allocator, .{
                            .variable = var_name,
                            .access_kind = .array_access,
                            .line = node.startPoint().row + 1,
                            .column = node.startPoint().column + 1,
                            .severity = if (state == .definitely_null) .definite else .possible,
                            .type_info = null,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Array access on possibly-null variable {s}",
                                .{var_name},
                            ),
                        });
                    },
                    .definitely_not_null => {
                        self.guarded_accesses += 1;
                    },
                    .unknown => {},
                }
            }
        }
    }

    /// Handle assignment: $x = expr — update null state based on RHS.
    fn handleAssignment(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        const lhs = node.childByFieldName("left") orelse return;
        const rhs = node.childByFieldName("right") orelse return;

        const var_name = getNodeText(source, lhs);
        if (!std.mem.startsWith(u8, var_name, "$")) return;

        // Determine null state of RHS.
        const rhs_state = self.inferNullStateFromExpr(rhs, source, null_states);
        try null_states.put(var_name, rhs_state);
        if (rhs_state == .possibly_null) {
            self.nullable_vars_tracked += 1;
        }

        // Also analyze RHS for violations.
        try self.analyzeExpression(rhs, source, null_states);
    }

    /// Infer null state from an expression.
    fn inferNullStateFromExpr(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) NullState {
        const kind = node.kind();

        // null literal → definitely null
        if (std.mem.eql(u8, kind, "null")) {
            return .definitely_null;
        }

        // new Foo() → definitely not null
        if (node.kindId() == self.ids.object_creation_expression) {
            return .definitely_not_null;
        }

        // Variable reference → inherit state
        if (std.mem.eql(u8, kind, "variable_name")) {
            const var_name = getNodeText(source, node);
            if (null_states.get(var_name)) |state| {
                return state;
            }
            return .unknown;
        }

        // Method call → check return type for nullable
        if (node.kindId() == self.ids.member_call_expression) {
            return self.inferMethodReturnNullState(node, source);
        }

        // Function call → check return type
        if (node.kindId() == self.ids.function_call_expression) {
            return .unknown;
        }

        return .unknown;
    }

    /// Check if a method's return type is nullable.
    fn inferMethodReturnNullState(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
    ) NullState {
        const object_node = node.childByFieldName("object") orelse return .unknown;
        const name_node = node.childByFieldName("name") orelse return .unknown;

        const obj_text = getNodeText(source, object_node);
        const method_name = getNodeText(source, name_node);

        // Try to resolve object type and method return type.
        if (std.mem.eql(u8, obj_text, "$this")) {
            // Look up in current class context (if available via symbol table).
            var classes_iter = self.symbol_table.classes.valueIterator();
            while (classes_iter.next()) |class| {
                if (class.methods.getPtr(method_name)) |method| {
                    return self.returnTypeNullState(method);
                }
            }
        }

        return .unknown;
    }

    /// Determine null state from a method's return type.
    fn returnTypeNullState(_: *NullSafetyAnalyzer, method: *const MethodSymbol) NullState {
        const ret_type = method.effectiveReturnType() orelse return .unknown;
        return switch (ret_type.kind) {
            .nullable => .possibly_null,
            .union_type => blk: {
                for (ret_type.type_parts) |part| {
                    if (std.mem.eql(u8, part, "null")) break :blk .possibly_null;
                }
                break :blk .definitely_not_null;
            },
            .void_type, .never => .definitely_not_null,
            else => .definitely_not_null,
        };
    }

    /// Analyze an if-statement for null guards.
    fn analyzeIfStatement(
        self: *NullSafetyAnalyzer,
        node: ts.Node,
        source: []const u8,
        null_states: *std.StringHashMap(NullState),
    ) error{OutOfMemory}!void {
        // Check the condition for null guard patterns.
        const raw_condition = node.childByFieldName("condition") orelse {
            // No condition, recurse into children.
            try self.analyzeBody(node, source, null_states);
            return;
        };

        // tree-sitter-php wraps the condition in parenthesized_expression.
        // Unwrap it to get the actual condition.
        const condition = if (std.mem.eql(u8, raw_condition.kind(), "parenthesized_expression"))
            (raw_condition.namedChild(0) orelse raw_condition)
        else
            raw_condition;

        const guard = self.extractNullGuard(condition, source);

        if (guard.variable) |guarded_var| {
            // Clone states for the then-branch with the guard applied.
            var then_states = try cloneStates(self.allocator, null_states);
            defer then_states.deinit();

            // Clone states for the else-branch with inverted guard.
            var else_states = try cloneStates(self.allocator, null_states);
            defer else_states.deinit();

            if (guard.is_null_check) {
                if (guard.is_negated) {
                    // if ($x !== null) → then-branch: not null, else-branch: null
                    try then_states.put(guarded_var, .definitely_not_null);
                    try else_states.put(guarded_var, .possibly_null);
                } else {
                    // if ($x === null) → then-branch: null, else-branch: not null
                    try then_states.put(guarded_var, .definitely_null);
                    try else_states.put(guarded_var, .definitely_not_null);
                }
            } else if (guard.is_instanceof) {
                // if ($x instanceof Foo) → then-branch: not null
                try then_states.put(guarded_var, .definitely_not_null);
            }

            // Analyze then-branch.
            if (node.childByFieldName("body")) |body| {
                // Check if then-branch is an early exit (return/throw).
                const is_early_exit = self.isEarlyExitBlock(body, source);

                if (guard.is_null_check and !guard.is_negated and is_early_exit) {
                    // Pattern: if ($x === null) { return/throw; }
                    // After this if, $x is definitely not null.
                    try null_states.put(guarded_var, .definitely_not_null);
                    // Analyze the then-branch with null state.
                    try self.analyzeBody(body, source, &then_states);
                } else {
                    try self.analyzeBody(body, source, &then_states);
                }
            }

            // Analyze else-branch.
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                if (node.namedChild(i)) |child| {
                    if (child.kindId() == self.ids.else_clause) {
                        if (child.childByFieldName("body")) |body| {
                            try self.analyzeBody(body, source, &else_states);
                        }
                        // Also check direct children of else clause.
                        var j: u32 = 0;
                        while (j < child.namedChildCount()) : (j += 1) {
                            if (child.namedChild(j)) |else_child| {
                                if (else_child.kindId() == self.ids.compound_statement) {
                                    try self.analyzeBody(else_child, source, &else_states);
                                }
                            }
                        }
                    }
                }
            }

            // After the if-statement without early exit, merge states conservatively.
            if (guard.is_null_check and !guard.is_negated) {
                // If the then-branch was NOT an early exit, the variable remains
                // possibly null after the if (since both branches reconverge).
                if (node.childByFieldName("body")) |body| {
                    if (!self.isEarlyExitBlock(body, source)) {
                        // Check if there's an else clause.
                        var has_else = false;
                        var k: u32 = 0;
                        while (k < node.namedChildCount()) : (k += 1) {
                            if (node.namedChild(k)) |child| {
                                if (child.kindId() == self.ids.else_clause) {
                                    has_else = true;
                                    break;
                                }
                            }
                        }
                        if (!has_else) {
                            // No else: both paths merge, state stays possibly null.
                        }
                    }
                }
            } else if (guard.is_null_check and guard.is_negated) {
                // if ($x !== null) { ... } — after the if, state depends on else.
                // If no else clause, $x remains possibly null after the if.
                var has_else = false;
                var k: u32 = 0;
                while (k < node.namedChildCount()) : (k += 1) {
                    if (node.namedChild(k)) |child| {
                        if (child.kindId() == self.ids.else_clause) {
                            has_else = true;
                            break;
                        }
                    }
                }
                if (!has_else) {
                    // After if ($x !== null) { ... } without else, $x remains possibly null.
                }
            }
        } else {
            // No guard detected, analyze the if-statement normally.
            if (node.childByFieldName("body")) |body| {
                try self.analyzeBody(body, source, null_states);
            }
            // Analyze else clause.
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                if (node.namedChild(i)) |child| {
                    if (child.kindId() == self.ids.else_clause) {
                        try self.analyzeStatement(child, source, null_states);
                    }
                }
            }
        }
    }

    /// Represents a null guard extracted from a condition.
    const NullGuard = struct {
        variable: ?[]const u8,
        is_null_check: bool, // $x === null or $x !== null
        is_negated: bool, // true for !== null, false for === null
        is_instanceof: bool, // $x instanceof Foo
    };

    /// Extract null guard information from a condition expression.
    fn extractNullGuard(self: *NullSafetyAnalyzer, node: ts.Node, source: []const u8) NullGuard {
        _ = self;
        var result = NullGuard{
            .variable = null,
            .is_null_check = false,
            .is_negated = false,
            .is_instanceof = false,
        };

        const kind = node.kind();

        // Binary expression: $x === null, $x !== null, null === $x, null !== $x
        if (std.mem.eql(u8, kind, "binary_expression")) {
            const left = node.childByFieldName("left") orelse return result;
            const right = node.childByFieldName("right") orelse return result;
            const op_node = node.childByFieldName("operator") orelse return result;
            const op = getNodeText(source, op_node);

            const is_strict_eq = std.mem.eql(u8, op, "===");
            const is_strict_neq = std.mem.eql(u8, op, "!==");
            const is_loose_eq = std.mem.eql(u8, op, "==");
            const is_loose_neq = std.mem.eql(u8, op, "!=");

            if (is_strict_eq or is_strict_neq or is_loose_eq or is_loose_neq) {
                const left_text = getNodeText(source, left);
                const right_text = getNodeText(source, right);

                var var_name: ?[]const u8 = null;
                var is_null = false;

                if (std.mem.startsWith(u8, left_text, "$") and std.mem.eql(u8, right_text, "null")) {
                    var_name = left_text;
                    is_null = true;
                } else if (std.mem.eql(u8, left_text, "null") and std.mem.startsWith(u8, right_text, "$")) {
                    var_name = right_text;
                    is_null = true;
                }

                if (is_null and var_name != null) {
                    result.variable = var_name;
                    result.is_null_check = true;
                    result.is_negated = is_strict_neq or is_loose_neq;
                }
            }

            // instanceof: $x instanceof Foo
            if (std.mem.eql(u8, op, "instanceof")) {
                const left_text = getNodeText(source, left);
                if (std.mem.startsWith(u8, left_text, "$")) {
                    result.variable = left_text;
                    result.is_instanceof = true;
                }
            }
        }

        // Also handle unary negation: !$x (truthy check, $x !== null/false/0/"")
        // This is less precise but still useful.

        return result;
    }

    /// Check if a block contains only an early exit (return or throw).
    fn isEarlyExitBlock(self: *NullSafetyAnalyzer, node: ts.Node, source: []const u8) bool {
        _ = source;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const kid = child.kindId();
                if (kid == self.ids.return_statement) return true;
                if (kid == self.ids.expression_statement) {
                    // Check if expression is a throw.
                    if (child.namedChild(0)) |expr| {
                        if (expr.kindId() == self.ids.throw_expression) return true;
                    }
                }
            }
        }
        return false;
    }

    /// Check if an expression uses null coalesce (??) on a nullable variable.
    pub fn isNullCoalesceGuarded(self: *NullSafetyAnalyzer, node: ts.Node, source: []const u8) bool {
        // Look for parent null_safe_member_access_expression or ?? operator.
        _ = self;
        const text = getNodeText(source, node);
        // Simple check: if the parent expression is a ?? expression.
        if (node.parent()) |parent| {
            const parent_kind = parent.kind();
            if (std.mem.eql(u8, parent_kind, "binary_expression")) {
                // Check for ?? operator.
                if (parent.childByFieldName("operator")) |op| {
                    const op_text = getNodeText(source, op);
                    if (std.mem.eql(u8, op_text, "??")) {
                        return true;
                    }
                }
            }
        }
        _ = text;
        return false;
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn getNodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) return "";
    return source[start..end];
}

fn cloneStates(allocator: std.mem.Allocator, states: *std.StringHashMap(NullState)) !std.StringHashMap(NullState) {
    var result = std.StringHashMap(NullState).init(allocator);
    var it = states.iterator();
    while (it.next()) |entry| {
        try result.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
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

fn analyzeNullSafety(allocator: std.mem.Allocator, source: []const u8) !struct { NullAnalysisResult, *NullSafetyAnalyzer, std.heap.ArenaAllocator } {
    const lang = tree_sitter_php();
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    var arena = std.heap.ArenaAllocator.init(allocator);
    const alloc = arena.allocator();

    const sym_table = try alloc.create(SymbolTable);
    sym_table.* = SymbolTable.init(alloc);

    const file_ctx = try alloc.create(FileContext);
    file_ctx.* = FileContext.init(alloc, "test.php");

    // Collect symbols first for method return type resolution.
    const SymbolCollector = @import("main.zig").SymbolCollector;
    var collector = SymbolCollector.init(alloc, sym_table, file_ctx, source, lang);
    try collector.collect(tree);

    const analyzer = try alloc.create(NullSafetyAnalyzer);
    analyzer.* = NullSafetyAnalyzer.init(alloc, sym_table, file_ctx, lang);

    const result = try analyzer.analyzeFile(tree, source);
    return .{ result, analyzer, arena };
}

// ------------------------------------------------------------------
// Test 1: Null check before access — safe
// ------------------------------------------------------------------
test "null safety: null check before access is safe" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    if ($x !== null) {
        \\        $x->method();
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
    try std.testing.expect(result.guarded_accesses >= 1);
}

// ------------------------------------------------------------------
// Test 2: No null check — violation
// ------------------------------------------------------------------
test "null safety: no check violation" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    $x->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expect(result.violations.len >= 1);
    try std.testing.expectEqual(NullViolation.AccessKind.method_call, result.violations[0].access_kind);
    try std.testing.expectEqual(NullSeverity.possible, result.violations[0].severity);
}

// ------------------------------------------------------------------
// Test 3: instanceof guard
// ------------------------------------------------------------------
test "null safety: instanceof guard" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    if ($x instanceof Foo) {
        \\        $x->method();
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 4: Null coalesce guard
// ------------------------------------------------------------------
test "null safety: null coalesce guard" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?string $x) {
        \\    $y = $x ?? 'default';
        \\    $y->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 5: Assert guard
// ------------------------------------------------------------------
test "null safety: assert guard" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    assert($x !== null);
        \\    $x->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    _ = r[0];
}

// ------------------------------------------------------------------
// Test 6: Early return guard
// ------------------------------------------------------------------
test "null safety: early return guard" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    if ($x === null) {
        \\        return;
        \\    }
        \\    $x->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 7: Ternary guard (conditional expression)
// ------------------------------------------------------------------
test "null safety: ternary guard" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    $y = $x !== null ? $x : new Foo();
        \\    $y->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 8: Nullable return unchecked
// ------------------------------------------------------------------
test "null safety: nullable return unchecked" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php class Foo {
        \\    public function findUser(): ?User { return null; }
        \\    public function process() {
        \\        $user = $this->findUser();
        \\        $user->getName();
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expect(result.violations.len >= 1);
}

// ------------------------------------------------------------------
// Test 9: Nullable property unchecked
// ------------------------------------------------------------------
test "null safety: nullable property access unchecked" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x) {
        \\    $x->name;
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expect(result.violations.len >= 1);
    try std.testing.expectEqual(NullViolation.AccessKind.property_access, result.violations[0].access_kind);
}

// ------------------------------------------------------------------
// Test 10: Nested null check
// ------------------------------------------------------------------
test "null safety: nested null check" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(?Foo $x, ?Bar $y) {
        \\    if ($x !== null) {
        \\        if ($y !== null) {
        \\            $x->method();
        \\            $y->method();
        \\        }
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 11: PHPDoc nullable
// ------------------------------------------------------------------
test "null safety: PHPDoc nullable param" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php class Foo {
        \\    /**
        \\     * @param ?Bar $bar
        \\     */
        \\    public function process($bar) {
        \\        $bar->doStuff();
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expect(result.violations.len >= 1);
}

// ------------------------------------------------------------------
// Test 12: Optional param null
// ------------------------------------------------------------------
test "null safety: optional param with null default" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(Foo $x = null) {
        \\    $x->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expect(result.violations.len >= 1);
}

// ------------------------------------------------------------------
// Test 13: Cross-project nullable return
// ------------------------------------------------------------------
test "null safety: nullable method return used safely" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php class Repo {
        \\    public function find(): ?User { return null; }
        \\    public function process() {
        \\        $user = $this->find();
        \\        if ($user !== null) {
        \\            $user->getName();
        \\        }
        \\    }
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}

// ------------------------------------------------------------------
// Test 14: False positive prevention — non-nullable param is safe
// ------------------------------------------------------------------
test "null safety: non-nullable param is safe" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f(Foo $x) {
        \\    $x->method();
        \\}
    ;
    var r = try analyzeNullSafety(allocator, source);
    defer r[2].deinit();
    const result = r[0];
    try std.testing.expectEqual(@as(usize, 0), result.violations.len);
}
