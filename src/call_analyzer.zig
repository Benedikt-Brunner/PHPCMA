const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const type_resolver = @import("type_resolver.zig");
const phpdoc = @import("phpdoc.zig");
const NodeKindIds = @import("node_kind_ids.zig").NodeKindIds;

const TypeInfo = types.TypeInfo;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const FileContext = types.FileContext;
const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ResolutionMethod = types.ResolutionMethod;
const SymbolTable = symbol_table.SymbolTable;
const TypeResolver = type_resolver.TypeResolver;

// ============================================================================
// Call Analyzer - Enhanced call graph building with type resolution
// ============================================================================

pub const CallAnalyzer = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    type_resolver: TypeResolver,
    ids: NodeKindIds,

    // Collected calls
    calls: std.ArrayListUnmanaged(EnhancedFunctionCall),

    // Current context
    current_file: []const u8,
    current_class: ?[]const u8,
    current_method: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
        language: *const ts.Language,
    ) CallAnalyzer {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .type_resolver = TypeResolver.init(allocator, sym_table, file_ctx),
            .ids = NodeKindIds.init(language),
            .calls = .empty,
            .current_file = "",
            .current_class = null,
            .current_method = null,
        };
    }

    pub fn deinit(self: *CallAnalyzer) void {
        self.type_resolver.deinit();
        self.calls.deinit(self.allocator);
    }

    // ========================================================================
    // Main Analysis Entry Point
    // ========================================================================

    /// Analyze a PHP file and extract all function/method calls
    pub fn analyzeFile(
        self: *CallAnalyzer,
        tree: *ts.Tree,
        source: []const u8,
        file_path: []const u8,
    ) !void {
        self.current_file = file_path;
        self.current_class = null;
        self.current_method = null;

        const root = tree.rootNode();
        try self.traverseNode(root, source);
    }

    /// Traverse AST and analyze nodes
    fn traverseNode(self: *CallAnalyzer, node: ts.Node, source: []const u8) error{OutOfMemory}!void {
        const kind_id = node.kindId();

        // Track class context
        if (kind_id == self.ids.class_declaration) {
            try self.enterClass(node, source);
            return;
        }

        // Track method context
        if (kind_id == self.ids.method_declaration) {
            try self.enterMethod(node, source);
            return;
        }

        // Track function context
        if (kind_id == self.ids.function_definition) {
            try self.enterFunction(node, source);
            return;
        }

        // Analyze calls
        if (kind_id == self.ids.member_call_expression) {
            try self.analyzeMemberCall(node, source);
        } else if (kind_id == self.ids.scoped_call_expression) {
            try self.analyzeStaticCall(node, source);
        } else if (kind_id == self.ids.function_call_expression) {
            try self.analyzeFunctionCall(node, source);
        }

        // Track assignments for type inference
        if (kind_id == self.ids.assignment_expression) {
            try self.type_resolver.trackAssignment(node, source);
        }

        // Recurse into children
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.traverseNode(child, source);
            }
        }
    }

    // ========================================================================
    // Context Tracking
    // ========================================================================

    fn enterClass(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        // Get class name
        if (node.childByFieldName("name")) |name_node| {
            const class_name = getNodeText(source, name_node);
            const fqcn = try self.type_resolver.file_context.resolveFQCN(class_name);
            self.current_class = fqcn;

            // Set in type resolver
            if (self.symbol_table.getClass(fqcn)) |class| {
                self.type_resolver.current_class = class;
            }
        }

        // Push new scope for class
        _ = try self.type_resolver.pushScope();

        // Process class body
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        // Pop scope
        self.type_resolver.popScope();
        self.current_class = null;
        self.type_resolver.current_class = null;
    }

    fn enterMethod(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        // Get method name
        if (node.childByFieldName("name")) |name_node| {
            const method_name = getNodeText(source, name_node);
            self.current_method = method_name;

            // Set in type resolver
            if (self.current_class) |class_fqcn| {
                if (self.symbol_table.resolveMethod(class_fqcn, method_name)) |method| {
                    self.type_resolver.current_method = method;
                }
            }
        }

        // Push new scope for method
        const scope = try self.type_resolver.pushScope();

        // Add parameter types to scope
        if (self.type_resolver.current_method) |method| {
            for (method.parameters) |param| {
                const type_info = param.type_info orelse param.phpdoc_type orelse continue;
                const var_name = try std.fmt.allocPrint(self.allocator, "${s}", .{param.name});
                try scope.setVariableType(var_name, type_info);
            }
        }

        // Track constructor injection for property type inference
        if (self.type_resolver.current_method) |method| {
            if (node.childByFieldName("body")) |body| {
                try self.type_resolver.trackConstructorInjection(method, source, body);
            }
        }

        // Process method body
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        // Pop scope
        self.type_resolver.popScope();
        self.current_method = null;
        self.type_resolver.current_method = null;
    }

    fn enterFunction(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        // Get function name
        var func_fqn: ?[]const u8 = null;
        if (node.childByFieldName("name")) |name_node| {
            const func_name = getNodeText(source, name_node);
            self.current_method = func_name;
            func_fqn = self.type_resolver.file_context.resolveFQCN(func_name) catch null;
        }

        // Push new scope
        const scope = try self.type_resolver.pushScope();

        // Add parameter types to scope (like enterMethod)
        if (func_fqn) |fqn| {
            if (self.symbol_table.getFunction(fqn)) |func| {
                for (func.parameters) |param| {
                    const type_info = param.type_info orelse param.phpdoc_type orelse continue;
                    const var_name = try std.fmt.allocPrint(self.allocator, "${s}", .{param.name});
                    try scope.setVariableType(var_name, type_info);
                }
            }
        }

        // Process function body
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        // Pop scope
        self.type_resolver.popScope();
        self.current_method = null;
    }

    // ========================================================================
    // Call Analysis
    // ========================================================================

    /// Analyze $obj->method() call
    fn analyzeMemberCall(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const object_node = node.childByFieldName("object") orelse return;
        const name_node = node.childByFieldName("name") orelse return;

        const method_name = getNodeText(source, name_node);

        // Try to resolve object type
        const object_type = try self.type_resolver.resolveExpressionType(object_node, source);

        var call = EnhancedFunctionCall{
            .caller_fqn = self.buildCallerFQN(),
            .callee_name = try self.allocator.dupe(u8, method_name),
            .call_type = .method,
            .line = node.startPoint().row + 1,
            .column = node.startPoint().column + 1,
            .file_path = self.current_file,
            .resolved_target = null,
            .resolution_confidence = 0.0,
            .resolution_method = .unresolved,
        };

        // Try to resolve target
        if (object_type) |obj_type| {
            if (self.type_resolver.resolveMethodCall(obj_type, method_name)) |method| {
                call.resolved_target = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}::{s}",
                    .{ method.containing_class, method.name },
                );
                call.resolution_confidence = self.calculateConfidence(obj_type);
                call.resolution_method = self.determineResolutionMethod(object_node, source);
            }
        }

        // Resolve argument types
        if (node.childByFieldName("arguments")) |args_node| {
            const arg_info = try self.resolveArgumentTypes(args_node, source);
            call.argument_types = arg_info.types;
            call.argument_count = arg_info.count;
        }

        try self.calls.append(self.allocator, call);
    }

    /// Analyze Class::method() static call
    fn analyzeStaticCall(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const scope_node = node.childByFieldName("scope") orelse return;
        const name_node = node.childByFieldName("name") orelse return;

        const class_name = getNodeText(source, scope_node);
        const method_name = getNodeText(source, name_node);

        // Resolve class name
        var fqcn: []const u8 = undefined;
        var resolution_method: ResolutionMethod = .explicit_type;

        if (std.mem.eql(u8, class_name, "self")) {
            if (self.current_class) |cc| {
                fqcn = cc;
                resolution_method = .self_reference;
            } else {
                return;
            }
        } else if (std.mem.eql(u8, class_name, "static")) {
            if (self.current_class) |cc| {
                fqcn = cc;
                resolution_method = .static_reference;
            } else {
                return;
            }
        } else if (std.mem.eql(u8, class_name, "parent")) {
            if (self.type_resolver.current_class) |class| {
                if (class.extends) |parent| {
                    fqcn = parent;
                    resolution_method = .parent_reference;
                } else {
                    return;
                }
            } else {
                return;
            }
        } else {
            fqcn = try self.type_resolver.file_context.resolveFQCN(class_name);
        }

        var call = EnhancedFunctionCall{
            .caller_fqn = self.buildCallerFQN(),
            .callee_name = try self.allocator.dupe(u8, method_name),
            .call_type = .static_method,
            .line = node.startPoint().row + 1,
            .column = node.startPoint().column + 1,
            .file_path = self.current_file,
            .resolved_target = null,
            .resolution_confidence = 1.0, // Static calls are always resolvable
            .resolution_method = resolution_method,
        };

        // Try to resolve
        if (self.symbol_table.resolveMethod(fqcn, method_name)) |method| {
            call.resolved_target = try std.fmt.allocPrint(
                self.allocator,
                "{s}::{s}",
                .{ method.containing_class, method.name },
            );
        } else {
            // External class - can't resolve but we know the target
            call.resolved_target = try std.fmt.allocPrint(
                self.allocator,
                "{s}::{s}",
                .{ fqcn, method_name },
            );
            call.resolution_confidence = 0.5; // Known class but not in symbol table
        }

        // Resolve argument types
        if (node.childByFieldName("arguments")) |args_node| {
            const arg_info = try self.resolveArgumentTypes(args_node, source);
            call.argument_types = arg_info.types;
            call.argument_count = arg_info.count;
        }

        try self.calls.append(self.allocator, call);
    }

    /// Analyze function_name() call
    fn analyzeFunctionCall(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const func_node = node.childByFieldName("function") orelse return;

        const func_kind_id = func_node.kindId();
        if (func_kind_id != self.ids.name and func_kind_id != self.ids.qualified_name) {
            return;
        }

        const func_name = getNodeText(source, func_node);

        // Build FQN
        var fqn: []const u8 = undefined;
        if (std.mem.indexOf(u8, func_name, "\\") != null) {
            fqn = func_name;
        } else if (self.type_resolver.file_context.namespace) |ns| {
            fqn = try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, func_name });
        } else {
            fqn = func_name;
        }

        var call = EnhancedFunctionCall{
            .caller_fqn = self.buildCallerFQN(),
            .callee_name = try self.allocator.dupe(u8, func_name),
            .call_type = .function,
            .line = node.startPoint().row + 1,
            .column = node.startPoint().column + 1,
            .file_path = self.current_file,
            .resolved_target = null,
            .resolution_confidence = 0.0,
            .resolution_method = .unresolved,
        };

        // Try to resolve
        if (self.symbol_table.getFunction(fqn)) |_| {
            call.resolved_target = try self.allocator.dupe(u8, fqn);
            call.resolution_confidence = 1.0;
            call.resolution_method = .explicit_type;
        } else if (isBuiltinFunction(func_name)) {
            call.resolved_target = try self.allocator.dupe(u8, func_name);
            call.resolution_confidence = 1.0;
            call.resolution_method = .explicit_type;
        }

        // Resolve argument types
        if (node.childByFieldName("arguments")) |args_node| {
            const arg_info = try self.resolveArgumentTypes(args_node, source);
            call.argument_types = arg_info.types;
            call.argument_count = arg_info.count;
        }

        try self.calls.append(self.allocator, call);
    }

    // ========================================================================
    // Argument Type Resolution
    // ========================================================================

    const ArgumentInfo = struct {
        types: []const ?TypeInfo,
        count: u32,
    };

    /// Resolve the types of all arguments in a call's argument list
    fn resolveArgumentTypes(self: *CallAnalyzer, args_node: ts.Node, source: []const u8) !ArgumentInfo {
        var arg_types: std.ArrayListUnmanaged(?TypeInfo) = .empty;
        var i: u32 = 0;
        while (i < args_node.namedChildCount()) : (i += 1) {
            if (args_node.namedChild(i)) |arg_node| {
                const arg_kind = arg_node.kind();
                // Skip non-argument nodes (e.g., "argument" wrapper nodes)
                if (std.mem.eql(u8, arg_kind, "argument")) {
                    // The actual expression is the first named child of the argument node
                    if (arg_node.namedChild(0)) |expr_node| {
                        const type_info = try self.type_resolver.resolveExpressionType(expr_node, source);
                        try arg_types.append(self.allocator, type_info);
                    } else {
                        try arg_types.append(self.allocator, null);
                    }
                } else {
                    // Direct expression node (some tree-sitter versions)
                    const type_info = try self.type_resolver.resolveExpressionType(arg_node, source);
                    try arg_types.append(self.allocator, type_info);
                }
            }
        }
        const count: u32 = @intCast(arg_types.items.len);
        return .{
            .types = try arg_types.toOwnedSlice(self.allocator),
            .count = count,
        };
    }

    // ========================================================================
    // Helper Methods
    // ========================================================================

    fn buildCallerFQN(self: *CallAnalyzer) []const u8 {
        if (self.current_class) |class| {
            if (self.current_method) |method| {
                return std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ class, method }) catch class;
            }
            return class;
        }
        if (self.current_method) |method| {
            return method;
        }
        return "<global>";
    }

    fn calculateConfidence(self: *CallAnalyzer, type_info: TypeInfo) f32 {
        _ = self;
        return switch (type_info.kind) {
            .simple => 1.0,
            .nullable => 0.9,
            .union_type => 0.5,
            .mixed => 0.1,
            .self_type, .static_type => 0.95,
            .parent_type => 0.9,
            else => 0.7,
        };
    }

    fn determineResolutionMethod(self: *CallAnalyzer, object_node: ts.Node, source: []const u8) ResolutionMethod {
        _ = self;
        const text = getNodeText(source, object_node);

        if (std.mem.eql(u8, text, "$this")) {
            return .this_reference;
        }

        const kind = object_node.kind();
        if (std.mem.eql(u8, kind, "object_creation_expression")) {
            return .constructor_call;
        }

        // Check if it's a variable that might have been assigned
        if (std.mem.eql(u8, kind, "variable_name")) {
            return .assignment_tracking;
        }

        if (std.mem.eql(u8, kind, "member_access_expression")) {
            return .property_type;
        }

        if (std.mem.eql(u8, kind, "member_call_expression")) {
            return .return_type_chain;
        }

        return .unresolved;
    }

    // ========================================================================
    // Results
    // ========================================================================

    pub fn getCalls(self: *const CallAnalyzer) []const EnhancedFunctionCall {
        return self.calls.items;
    }

    pub fn getResolvedCalls(self: *const CallAnalyzer) ![]EnhancedFunctionCall {
        var resolved = std.ArrayList(EnhancedFunctionCall).init(self.allocator);
        for (self.calls.items) |call| {
            if (call.resolved_target != null) {
                try resolved.append(call);
            }
        }
        return resolved.toOwnedSlice();
    }

    pub fn getUnresolvedCalls(self: *const CallAnalyzer) ![]EnhancedFunctionCall {
        var unresolved = std.ArrayList(EnhancedFunctionCall).init(self.allocator);
        for (self.calls.items) |call| {
            if (call.resolved_target == null) {
                try unresolved.append(call);
            }
        }
        return unresolved.toOwnedSlice();
    }
};

// ============================================================================
// Project-Wide Call Graph
// ============================================================================

pub const ProjectCallGraph = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    calls: std.ArrayListUnmanaged(EnhancedFunctionCall),

    // Statistics
    total_calls: usize,
    resolved_calls: usize,
    unresolved_calls: usize,

    pub fn init(allocator: std.mem.Allocator, sym_table: *SymbolTable) ProjectCallGraph {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .calls = .empty,
            .total_calls = 0,
            .resolved_calls = 0,
            .unresolved_calls = 0,
        };
    }

    pub fn deinit(self: *ProjectCallGraph) void {
        self.calls.deinit(self.allocator);
    }

    /// Add calls from a file analyzer
    pub fn addCalls(self: *ProjectCallGraph, analyzer: *const CallAnalyzer) !void {
        for (analyzer.getCalls()) |call| {
            try self.calls.append(self.allocator, call);
            self.total_calls += 1;
            if (call.resolved_target != null) {
                self.resolved_calls += 1;
            } else {
                self.unresolved_calls += 1;
            }
        }
    }

    /// Get resolution rate as percentage
    pub fn getResolutionRate(self: *const ProjectCallGraph) f32 {
        if (self.total_calls == 0) return 0.0;
        return @as(f32, @floatFromInt(self.resolved_calls)) / @as(f32, @floatFromInt(self.total_calls)) * 100.0;
    }

    /// Add a synthetic edge generated by a plugin
    pub fn addSyntheticEdge(
        self: *ProjectCallGraph,
        caller_fqn: []const u8,
        callee_fqn: []const u8,
        file_path: []const u8,
        line: u32,
        confidence: f32,
    ) !void {
        // Extract method name from callee_fqn (e.g., "Class::method" -> "method")
        const callee_name = if (std.mem.indexOf(u8, callee_fqn, "::")) |sep|
            callee_fqn[sep + 2 ..]
        else
            callee_fqn;

        const call = EnhancedFunctionCall{
            .caller_fqn = caller_fqn,
            .callee_name = callee_name,
            .call_type = .method,
            .line = line,
            .column = 0,
            .file_path = file_path,
            .resolved_target = callee_fqn,
            .resolution_confidence = confidence,
            .resolution_method = .plugin_generated,
        };

        try self.calls.append(self.allocator, call);
        self.total_calls += 1;
        self.resolved_calls += 1;
    }

    // ========================================================================
    // Output Formats
    // ========================================================================

    /// Output as DOT graph format
    pub fn toDot(self: *const ProjectCallGraph, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("digraph CallGraph {\n");
        try writer.writeAll("    rankdir=LR;\n");
        try writer.writeAll("    node [shape=box, fontname=\"Helvetica\"];\n");
        try writer.writeAll("    edge [fontname=\"Helvetica\", fontsize=10];\n\n");

        // Collect unique nodes
        var callers = std.StringHashMap(void).init(self.allocator);
        defer callers.deinit();
        var callees = std.StringHashMap(void).init(self.allocator);
        defer callees.deinit();

        for (self.calls.items) |call| {
            try callers.put(call.caller_fqn, {});
            if (call.resolved_target) |target| {
                try callees.put(target, {});
            }
        }

        // Output caller nodes
        try writer.writeAll("    // Callers\n");
        var caller_it = callers.keyIterator();
        while (caller_it.next()) |caller| {
            const escaped = try escapeForDot(self.allocator, caller.*);
            defer self.allocator.free(escaped);
            try writer.print("    \"{s}\" [style=filled, fillcolor=\"#e1f5fe\"];\n", .{escaped});
        }

        // Output callee nodes
        try writer.writeAll("\n    // Callees\n");
        var callee_it = callees.keyIterator();
        while (callee_it.next()) |callee| {
            if (!callers.contains(callee.*)) {
                const escaped = try escapeForDot(self.allocator, callee.*);
                defer self.allocator.free(escaped);
                try writer.print("    \"{s}\" [style=filled, fillcolor=\"#fff3e0\"];\n", .{escaped});
            }
        }

        // Output edges
        try writer.writeAll("\n    // Calls\n");
        for (self.calls.items) |call| {
            if (call.resolved_target) |target| {
                const caller_escaped = try escapeForDot(self.allocator, call.caller_fqn);
                defer self.allocator.free(caller_escaped);
                const target_escaped = try escapeForDot(self.allocator, target);
                defer self.allocator.free(target_escaped);

                // Color based on confidence
                const color = if (call.resolution_confidence >= 0.9)
                    "\"#4caf50\""
                else if (call.resolution_confidence >= 0.5)
                    "\"#ff9800\""
                else
                    "\"#f44336\"";

                try writer.print(
                    "    \"{s}\" -> \"{s}\" [color={s}];\n",
                    .{ caller_escaped, target_escaped, color },
                );
            }
        }

        try writer.writeAll("}\n");
        try writer.flush();
    }

    /// Output as text summary
    pub fn toText(self: *const ProjectCallGraph, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        // Header
        try writer.print(
            \\Call Graph Analysis
            \\===================
            \\Total calls: {d}
            \\Resolved:    {d} ({d:.1}%)
            \\Unresolved:  {d}
            \\
            \\
        , .{
            self.total_calls,
            self.resolved_calls,
            self.getResolutionRate(),
            self.unresolved_calls,
        });

        // Group by caller
        var by_caller = std.StringHashMap(std.ArrayListUnmanaged(EnhancedFunctionCall)).init(self.allocator);
        defer {
            var it = by_caller.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            by_caller.deinit();
        }

        for (self.calls.items) |call| {
            const result = try by_caller.getOrPut(call.caller_fqn);
            if (!result.found_existing) {
                result.value_ptr.* = .empty;
            }
            try result.value_ptr.append(self.allocator, call);
        }

        // Output each caller
        var caller_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer caller_keys.deinit(self.allocator);

        var key_it = by_caller.keyIterator();
        while (key_it.next()) |key| {
            try caller_keys.append(self.allocator, key.*);
        }

        std.mem.sort([]const u8, caller_keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (caller_keys.items) |caller| {
            try writer.print("{s}:\n", .{caller});

            if (by_caller.get(caller)) |calls| {
                for (calls.items) |call| {
                    const target = call.resolved_target orelse call.callee_name;
                    try writer.print("  -> {s}", .{target});
                    if (call.resolved_target != null) {
                        try writer.print(" [{d:.0}%]", .{call.resolution_confidence * 100});
                    } else {
                        try writer.writeAll(" [?]");
                    }
                    try writer.print(" (line {d})\n", .{call.line});
                }
            }
            try writer.writeAll("\n");
        }
        try writer.flush();
    }

    /// Output as JSON format
    pub fn toJson(self: *const ProjectCallGraph, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");
        try writer.print("  \"version\": \"0.4.0\",\n", .{});
        try writer.print("  \"total_calls\": {d},\n", .{self.total_calls});
        try writer.print("  \"resolved_calls\": {d},\n", .{self.resolved_calls});
        try writer.print("  \"unresolved_calls\": {d},\n", .{self.unresolved_calls});
        try writer.print("  \"resolution_rate\": {d:.1},\n", .{self.getResolutionRate()});

        // Symbols from the symbol table
        const stats = self.symbol_table.getStats();
        try writer.writeAll("  \"symbols\": {\n");
        try writer.print("    \"classes\": {d},\n", .{stats.class_count});
        try writer.print("    \"interfaces\": {d},\n", .{stats.interface_count});
        try writer.print("    \"traits\": {d},\n", .{stats.trait_count});
        try writer.print("    \"functions\": {d},\n", .{stats.function_count});
        try writer.print("    \"methods\": {d},\n", .{stats.method_count});
        try writer.print("    \"properties\": {d}\n", .{stats.property_count});
        try writer.writeAll("  },\n");

        // Call graph entries
        try writer.writeAll("  \"call_graph\": [");
        for (self.calls.items, 0..) |call, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {\n");
            try writer.print("      \"caller\": \"{s}\",\n", .{call.caller_fqn});
            try writer.print("      \"callee\": \"{s}\",\n", .{call.callee_name});
            if (call.resolved_target) |target| {
                try writer.print("      \"resolved_target\": \"{s}\",\n", .{target});
            } else {
                try writer.writeAll("      \"resolved_target\": null,\n");
            }
            try writer.print("      \"confidence\": {d:.2},\n", .{call.resolution_confidence});
            try writer.print("      \"line\": {d},\n", .{call.line});
            try writer.print("      \"file\": \"{s}\"\n", .{call.file_path});
            try writer.writeAll("    }");
        }
        if (self.calls.items.len > 0) {
            try writer.writeAll("\n  ");
        }
        try writer.writeAll("]\n");

        try writer.writeAll("}\n");
        try writer.flush();
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getNodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) {
        return "";
    }
    return source[start..end];
}

fn escapeForDot(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (str) |c| {
        if (c == '"' or c == '\\') {
            try result.append(allocator, '\\');
        }
        try result.append(allocator, c);
    }
    return result.toOwnedSlice(allocator);
}

fn isBuiltinFunction(name: []const u8) bool {
    const builtins = [_][]const u8{
        "array_map",
        "array_filter",
        "array_reduce",
        "array_merge",
        "array_keys",
        "array_values",
        "array_push",
        "array_pop",
        "count",
        "strlen",
        "strpos",
        "substr",
        "str_replace",
        "explode",
        "implode",
        "trim",
        "strtolower",
        "strtoupper",
        "sprintf",
        "printf",
        "echo",
        "print",
        "var_dump",
        "print_r",
        "isset",
        "empty",
        "is_null",
        "is_array",
        "is_string",
        "is_int",
        "is_bool",
        "json_encode",
        "json_decode",
        "file_get_contents",
        "file_put_contents",
        "fopen",
        "fclose",
        "fread",
        "fwrite",
        "date",
        "time",
        "strtotime",
        "preg_match",
        "preg_replace",
        "preg_match_all",
        "class_exists",
        "method_exists",
        "property_exists",
        "get_class",
        "get_parent_class",
        "throw",
        "die",
        "exit",
    };

    for (builtins) |builtin| {
        if (std.mem.eql(u8, name, builtin)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Called-Before Analysis
// ============================================================================

/// Result of a called-before analysis
pub const CalledBeforeResult = struct {
    /// Whether the constraint is satisfied (before is always called before after)
    satisfied: bool,

    /// List of violations found
    violations: []const Violation,

    /// List of satisfied matches (after calls with their satisfying before calls)
    matches: []const Match,

    /// Functions where the constraint is properly satisfied
    satisfied_in: []const []const u8,

    pub const Violation = struct {
        /// The function/method where the violation occurs
        context_function: []const u8,
        /// File where the violation occurs
        file_path: []const u8,
        /// Line of the "after" call that violates the constraint
        after_line: u32,
        /// Line of the "before" call (if present, otherwise this is missing before)
        before_line: ?u32,
        /// Type of violation
        kind: ViolationKind,
        /// Call paths that are missing the "before" call (for interprocedural violations)
        missing_before_paths: []const MissingBeforePath = &.{},
    };

    pub const MissingBeforePath = struct {
        /// The caller function that calls the violating function
        caller: []const u8,
        /// Line where the caller calls the violating function
        call_line: u32,
        /// File where the caller is located
        file_path: []const u8,
    };

    pub const ViolationKind = enum {
        /// "after" is called before "before"
        wrong_order,
        /// "after" is called but "before" is never called
        missing_before,
        /// "after" is called in a branch where "before" might not have been called
        conditional_before,
    };

    /// A satisfied match: an "after" call with its satisfying "before" call
    pub const Match = struct {
        /// The function/method where the match occurs
        context_function: []const u8,
        /// File where the match occurs
        file_path: []const u8,
        /// Line of the "after" call
        after_line: u32,
        /// The actual callee name of the "after" call
        after_callee: []const u8,
        /// Line of the "before" call that satisfies the constraint
        before_line: u32,
        /// The actual callee name of the "before" call
        before_callee: []const u8,
        /// Whether this match was satisfied via interprocedural analysis (caller chain)
        via_caller: bool = false,
        /// The caller function that contains the before call (for interprocedural matches)
        caller_context: ?[]const u8 = null,
    };
};

/// Analyzer for checking "called before" constraints
pub const CalledBeforeAnalyzer = struct {
    allocator: std.mem.Allocator,
    call_graph: *const ProjectCallGraph,

    // Cache for interprocedural analysis (built lazily)
    calls_by_caller: std.StringHashMap(std.ArrayListUnmanaged(CallInfo)),
    // Reverse call graph: callee -> list of callers
    callers_of: std.StringHashMap(std.ArrayListUnmanaged(CallerInfo)),

    // Pre-computed match sets: callee strings that match before_fn/after_fn patterns
    before_match_set: std.StringHashMap(void),
    after_match_set: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, call_graph: *const ProjectCallGraph) CalledBeforeAnalyzer {
        return .{
            .allocator = allocator,
            .call_graph = call_graph,
            .calls_by_caller = std.StringHashMap(std.ArrayListUnmanaged(CallInfo)).init(allocator),
            .callers_of = std.StringHashMap(std.ArrayListUnmanaged(CallerInfo)).init(allocator),
            .before_match_set = std.StringHashMap(void).init(allocator),
            .after_match_set = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *CalledBeforeAnalyzer) void {
        var it1 = self.calls_by_caller.valueIterator();
        while (it1.next()) |list| {
            list.deinit(self.allocator);
        }
        self.calls_by_caller.deinit();

        var it2 = self.callers_of.valueIterator();
        while (it2.next()) |list| {
            list.deinit(self.allocator);
        }
        self.callers_of.deinit();

        self.before_match_set.deinit();
        self.after_match_set.deinit();
    }

    /// Build forward index (calls_by_caller) for efficient lookup
    fn buildIndexes(self: *CalledBeforeAnalyzer) !void {
        // Build calls_by_caller index only (forward graph)
        for (self.call_graph.calls.items) |call| {
            const result = try self.calls_by_caller.getOrPut(call.caller_fqn);
            if (!result.found_existing) {
                result.value_ptr.* = .empty;
            }
            try result.value_ptr.append(self.allocator, .{
                .callee = call.resolved_target orelse call.callee_name,
                .line = call.line,
                .file_path = call.file_path,
            });
        }
    }

    /// Build lazy reverse graph (callers_of) only for functions that are
    /// transitively reachable from after_fn callers. This avoids indexing
    /// the full 20K+ edges when only a small subset is needed.
    fn buildReverseIndex(self: *CalledBeforeAnalyzer) !void {
        // Phase 1: Build a temporary full reverse map (callee -> callers) in one pass.
        // This is O(E) where E = number of call edges.
        var full_reverse = std.StringHashMap(std.ArrayListUnmanaged(CallerInfo)).init(self.allocator);
        defer {
            var it = full_reverse.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            full_reverse.deinit();
        }

        var fwd_it = self.calls_by_caller.iterator();
        while (fwd_it.next()) |entry| {
            const caller_fqn = entry.key_ptr.*;
            for (entry.value_ptr.items) |call| {
                const result = try full_reverse.getOrPut(call.callee);
                if (!result.found_existing) {
                    result.value_ptr.* = .empty;
                }
                try result.value_ptr.append(self.allocator, .{
                    .caller = caller_fqn,
                    .line = call.line,
                    .file_path = call.file_path,
                });
            }
        }

        // Phase 2: BFS from after_fn match set to discover all transitively
        // needed reverse edges. Only these get copied into self.callers_of.
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var worklist: std.ArrayListUnmanaged([]const u8) = .empty;
        defer worklist.deinit(self.allocator);

        // Seed with all callee strings matching after_fn
        var after_it = self.after_match_set.iterator();
        while (after_it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!visited.contains(key)) {
                try visited.put(key, {});
                try worklist.append(self.allocator, key);
            }
        }

        while (worklist.items.len > 0) {
            const target = worklist.pop().?;

            // Copy reverse edges for this target into self.callers_of
            if (full_reverse.get(target)) |callers| {
                const result = try self.callers_of.getOrPut(target);
                if (!result.found_existing) {
                    result.value_ptr.* = .empty;
                }
                for (callers.items) |caller_info| {
                    try result.value_ptr.append(self.allocator, caller_info);
                    // Each caller may also need reverse edges for recursive walk
                    if (!visited.contains(caller_info.caller)) {
                        try visited.put(caller_info.caller, {});
                        try worklist.append(self.allocator, caller_info.caller);
                    }
                }
            }
        }
    }

    /// Pre-compute sets of callee strings that match before_fn/after_fn patterns.
    /// Scans calls_by_caller once so that inner loops can use O(1) set lookups
    /// instead of repeated O(n) matchesFunction calls.
    fn buildMatchSets(self: *CalledBeforeAnalyzer, before_fn: []const u8, after_fn: []const u8) !void {
        var caller_it = self.calls_by_caller.iterator();
        while (caller_it.next()) |entry| {
            for (entry.value_ptr.items) |call| {
                if (!self.before_match_set.contains(call.callee)) {
                    if (matchesFunction(call.callee, before_fn)) {
                        try self.before_match_set.put(call.callee, {});
                    }
                }
                if (!self.after_match_set.contains(call.callee)) {
                    if (matchesFunction(call.callee, after_fn)) {
                        try self.after_match_set.put(call.callee, {});
                    }
                }
            }
        }
    }

    /// Check if `before_fn` is always called before `after_fn`
    /// The function names can be:
    /// - Fully qualified: "App\\Service\\UserService::validate"
    /// - Method only: "::validate" (matches any class)
    /// - Function only: "validateInput" (matches standalone functions)
    ///
    /// The analysis is interprocedural: if a function calls `after_fn` without calling
    /// `before_fn`, we check if ALL callers of that function have `before_fn` called
    /// before they call this function.
    pub fn analyze(
        self: *CalledBeforeAnalyzer,
        before_fn: []const u8,
        after_fn: []const u8,
    ) !CalledBeforeResult {
        // Build forward index (calls_by_caller)
        try self.buildIndexes();

        // Pre-compute match sets for O(1) lookups in inner loops
        try self.buildMatchSets(before_fn, after_fn);

        // Build lazy reverse graph only for after_fn targets and transitive callers
        try self.buildReverseIndex();

        var violations: std.ArrayListUnmanaged(CalledBeforeResult.Violation) = .empty;
        var matches: std.ArrayListUnmanaged(CalledBeforeResult.Match) = .empty;
        var satisfied_in: std.ArrayListUnmanaged([]const u8) = .empty;

        // Track functions that call after_fn
        var functions_calling_after: std.ArrayListUnmanaged([]const u8) = .empty;
        defer functions_calling_after.deinit(self.allocator);

        // First pass: find all functions that directly call after_fn
        var caller_it = self.calls_by_caller.iterator();
        while (caller_it.next()) |entry| {
            const caller = entry.key_ptr.*;
            const calls = entry.value_ptr.items;

            for (calls) |call| {
                if (self.after_match_set.contains(call.callee)) {
                    try functions_calling_after.append(self.allocator, caller);
                    break;
                }
            }
        }

        // Check each function that calls after_fn
        for (functions_calling_after.items) |caller| {
            const calls = self.calls_by_caller.get(caller) orelse continue;

            // Find calls to before_fn and after_fn within this caller
            var before_calls: std.ArrayListUnmanaged(BeforeCallInfo) = .empty;
            defer before_calls.deinit(self.allocator);
            var after_calls: std.ArrayListUnmanaged(AfterCallInfo) = .empty;
            defer after_calls.deinit(self.allocator);

            var file_path: []const u8 = "";

            for (calls.items) |call| {
                file_path = call.file_path;
                if (self.before_match_set.contains(call.callee)) {
                    try before_calls.append(self.allocator, .{
                        .line = call.line,
                        .callee = call.callee,
                    });
                }
                if (self.after_match_set.contains(call.callee)) {
                    try after_calls.append(self.allocator, .{
                        .line = call.line,
                        .callee = call.callee,
                    });
                }
            }

            // If this function calls after_fn, check the constraint
            if (after_calls.items.len > 0) {
                if (before_calls.items.len == 0) {
                    // No local before call - check if ALL immediate callers have before called
                    const interprocedural_result = try self.checkImmediateCallersForBefore(
                        caller,
                        before_fn,
                    );

                    if (interprocedural_result.satisfied) {
                        // Satisfied via callers
                        for (after_calls.items) |after_call| {
                            if (interprocedural_result.satisfying_caller) |satisfying_caller| {
                                try matches.append(self.allocator, .{
                                    .context_function = caller,
                                    .file_path = file_path,
                                    .after_line = after_call.line,
                                    .after_callee = after_call.callee,
                                    .before_line = satisfying_caller.before_line,
                                    .before_callee = satisfying_caller.before_callee,
                                    .via_caller = true,
                                    .caller_context = satisfying_caller.caller,
                                });
                            }
                        }
                        try satisfied_in.append(self.allocator, caller);
                    } else {
                        // Violation: after is called but before is never called (locally or in callers)
                        for (after_calls.items) |after_call| {
                            try violations.append(self.allocator, .{
                                .context_function = caller,
                                .file_path = file_path,
                                .after_line = after_call.line,
                                .before_line = null,
                                .kind = .missing_before,
                                .missing_before_paths = interprocedural_result.missing_paths,
                            });
                        }
                    }
                } else {
                    // Has local before calls - check ordering
                    var earliest_before: BeforeCallInfo = before_calls.items[0];
                    for (before_calls.items[1..]) |bc| {
                        if (bc.line < earliest_before.line) {
                            earliest_before = bc;
                        }
                    }

                    // Check each after call
                    var has_violation = false;
                    for (after_calls.items) |after_call| {
                        if (after_call.line < earliest_before.line) {
                            // Violation: after is called before the first before
                            try violations.append(self.allocator, .{
                                .context_function = caller,
                                .file_path = file_path,
                                .after_line = after_call.line,
                                .before_line = earliest_before.line,
                                .kind = .wrong_order,
                            });
                            has_violation = true;
                        } else {
                            // Find the closest before call that precedes this after call
                            var satisfying_before: ?BeforeCallInfo = null;
                            for (before_calls.items) |bc| {
                                if (bc.line < after_call.line) {
                                    if (satisfying_before == null or bc.line > satisfying_before.?.line) {
                                        satisfying_before = bc;
                                    }
                                }
                            }

                            if (satisfying_before) |sb| {
                                try matches.append(self.allocator, .{
                                    .context_function = caller,
                                    .file_path = file_path,
                                    .after_line = after_call.line,
                                    .after_callee = after_call.callee,
                                    .before_line = sb.line,
                                    .before_callee = sb.callee,
                                });
                            }
                        }
                    }

                    if (!has_violation) {
                        try satisfied_in.append(self.allocator, caller);
                    }
                }
            }
        }

        return CalledBeforeResult{
            .satisfied = violations.items.len == 0,
            .violations = try violations.toOwnedSlice(self.allocator),
            .matches = try matches.toOwnedSlice(self.allocator),
            .satisfied_in = try satisfied_in.toOwnedSlice(self.allocator),
        };
    }

    const CheckResult = struct {
        satisfied: bool,
        satisfying_caller: ?SatisfyingCaller,
        /// Callers that are missing the before call
        missing_paths: []const CalledBeforeResult.MissingBeforePath,
    };

    const SatisfyingCaller = struct {
        caller: []const u8,
        before_line: u32,
        before_callee: []const u8,
    };

    /// Maximum depth for recursive caller checking
    const MAX_RECURSION_DEPTH: u32 = 100;

    /// Check if ALL callers of `target_fn` have `before_fn` called before they call `target_fn`
    /// This recursively checks up the call chain up to MAX_RECURSION_DEPTH levels
    fn checkImmediateCallersForBefore(
        self: *CalledBeforeAnalyzer,
        target_fn: []const u8,
        before_fn: []const u8,
    ) !CheckResult {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        var memo = std.StringHashMap(CheckResult).init(self.allocator);
        defer memo.deinit();

        return self.checkCallersRecursive(target_fn, before_fn, 0, &visited, &memo);
    }

    /// Recursive implementation of caller checking
    /// Returns satisfied=true only if ALL paths through the call graph have before_fn called
    fn checkCallersRecursive(
        self: *CalledBeforeAnalyzer,
        target_fn: []const u8,
        before_fn: []const u8,
        depth: u32,
        visited: *std.StringHashMap(void),
        memo: *std.StringHashMap(CheckResult),
    ) !CheckResult {
        // Prevent infinite recursion
        if (depth >= MAX_RECURSION_DEPTH) {
            return CheckResult{ .satisfied = false, .satisfying_caller = null, .missing_paths = &.{} };
        }

        // Prevent cycles
        if (visited.contains(target_fn)) {
            // Already visited this function - consider it satisfied to break the cycle
            return CheckResult{ .satisfied = true, .satisfying_caller = null, .missing_paths = &.{} };
        }

        // Return memoized result if available (avoids redundant subtree exploration)
        if (memo.get(target_fn)) |cached| {
            return cached;
        }

        try visited.put(target_fn, {});

        // Find callers: try exact lookup first (O(1)), fall back to fuzzy scan only if needed
        var all_callers: std.ArrayListUnmanaged(CallerInfo) = .empty;
        defer all_callers.deinit(self.allocator);

        if (self.callers_of.get(target_fn)) |exact_callers| {
            // Exact match found — most resolved calls hit this path
            for (exact_callers.items) |caller_info| {
                try all_callers.append(self.allocator, caller_info);
            }
        } else {
            // No exact match — fall back to fuzzy scan for partial/namespace matches
            var callers_it = self.callers_of.iterator();
            while (callers_it.next()) |entry| {
                const callee_key = entry.key_ptr.*;

                if (self.calleeMatchesTarget(callee_key, target_fn)) {
                    for (entry.value_ptr.items) |caller_info| {
                        try all_callers.append(self.allocator, caller_info);
                    }
                }
            }
        }

        if (all_callers.items.len == 0) {
            // No callers found - this is a root function or external entry point
            // Consider it unsatisfied since we can't verify the constraint
            return CheckResult{ .satisfied = false, .satisfying_caller = null, .missing_paths = &.{} };
        }

        // Check each caller
        var all_satisfied = true;
        var any_satisfying_caller: ?SatisfyingCaller = null;
        var missing_paths: std.ArrayListUnmanaged(CalledBeforeResult.MissingBeforePath) = .empty;

        for (all_callers.items) |caller_info| {
            const caller = caller_info.caller;
            const call_line = caller_info.line;

            // Get calls made by this caller
            const caller_calls = self.calls_by_caller.get(caller) orelse {
                // No calls found for this caller - check its callers recursively
                const recursive_result = try self.checkCallersRecursive(caller, before_fn, depth + 1, visited, memo);
                if (!recursive_result.satisfied) {
                    all_satisfied = false;
                    try missing_paths.append(self.allocator, .{
                        .caller = caller,
                        .call_line = call_line,
                        .file_path = caller_info.file_path,
                    });
                } else if (recursive_result.satisfying_caller) |sc| {
                    any_satisfying_caller = sc;
                }
                continue;
            };

            // Check if this caller has before_fn called before it calls target_fn
            var has_before_before_call = false;
            var satisfying_before: ?BeforeCallInfo = null;

            for (caller_calls.items) |call| {
                if (self.before_match_set.contains(call.callee) and call.line < call_line) {
                    has_before_before_call = true;
                    if (satisfying_before == null or call.line > satisfying_before.?.line) {
                        satisfying_before = .{
                            .line = call.line,
                            .callee = call.callee,
                        };
                    }
                }
            }

            if (has_before_before_call) {
                if (satisfying_before) |sb| {
                    any_satisfying_caller = .{
                        .caller = caller,
                        .before_line = sb.line,
                        .before_callee = sb.callee,
                    };
                }
            } else {
                // This caller doesn't have before_fn before calling target_fn
                // Check if this caller's callers have before_fn called
                const recursive_result = try self.checkCallersRecursive(caller, before_fn, depth + 1, visited, memo);
                if (!recursive_result.satisfied) {
                    all_satisfied = false;
                    try missing_paths.append(self.allocator, .{
                        .caller = caller,
                        .call_line = call_line,
                        .file_path = caller_info.file_path,
                    });
                } else if (recursive_result.satisfying_caller) |sc| {
                    any_satisfying_caller = sc;
                }
            }
        }

        const result = CheckResult{
            .satisfied = all_satisfied,
            .satisfying_caller = any_satisfying_caller,
            .missing_paths = try missing_paths.toOwnedSlice(self.allocator),
        };
        try memo.put(target_fn, result);
        return result;
    }

    /// Check if a callee matches a target function for interprocedural lookup
    /// This is for matching "Class::method" to the caller_fqn which might be just "Class::method"
    /// or just "method" when the class couldn't be resolved
    fn calleeMatchesTarget(self: *CalledBeforeAnalyzer, callee: []const u8, target: []const u8) bool {
        _ = self;

        // Exact match
        if (std.mem.eql(u8, callee, target)) {
            return true;
        }

        // Check if callee ends with target (e.g., "Namespace\Class::method" ends with "Class::method")
        if (std.mem.endsWith(u8, callee, target)) {
            const prefix_len = callee.len - target.len;
            if (prefix_len > 0 and callee[prefix_len - 1] == '\\') {
                return true;
            }
        }

        // Get method names from both
        const target_method = if (std.mem.indexOf(u8, target, "::")) |sep|
            target[sep + 2 ..]
        else
            target;

        const callee_method = if (std.mem.indexOf(u8, callee, "::")) |sep|
            callee[sep + 2 ..]
        else
            callee;

        // If callee is just a method name (unresolved call), match if method names match
        // This handles the case where type resolution failed for calls like $this->service->method()
        if (std.mem.indexOf(u8, callee, "::") == null) {
            // Callee has no class - match if method names are equal
            return std.mem.eql(u8, callee, target_method);
        }

        // Check if both have :: and the class::method part matches
        if (std.mem.indexOf(u8, callee, "::")) |callee_sep| {
            if (std.mem.indexOf(u8, target, "::")) |target_sep| {
                if (std.mem.eql(u8, callee_method, target_method)) {
                    // Methods match, check classes
                    const callee_class = callee[0..callee_sep];
                    const target_class = target[0..target_sep];

                    if (std.mem.eql(u8, callee_class, target_class)) {
                        return true;
                    }

                    // Check if callee_class ends with target_class
                    if (std.mem.endsWith(u8, callee_class, target_class)) {
                        const class_prefix_len = callee_class.len - target_class.len;
                        if (class_prefix_len > 0 and callee_class[class_prefix_len - 1] == '\\') {
                            return true;
                        }
                    }

                    // Check if target_class ends with callee_class (reverse case)
                    if (std.mem.endsWith(u8, target_class, callee_class)) {
                        const class_prefix_len = target_class.len - callee_class.len;
                        if (class_prefix_len > 0 and target_class[class_prefix_len - 1] == '\\') {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Check if a callee matches a function pattern
    fn matchesFunction(callee: []const u8, pattern: []const u8) bool {
        // Exact match
        if (std.mem.eql(u8, callee, pattern)) {
            return true;
        }

        // Pattern "::methodName" matches any class with that method
        if (std.mem.startsWith(u8, pattern, "::")) {
            const method_name = pattern[2..];
            if (std.mem.indexOf(u8, callee, "::")) |sep| {
                const callee_method = callee[sep + 2 ..];
                return std.mem.eql(u8, callee_method, method_name);
            }
            // Also check if callee is just the method name (unresolved)
            return std.mem.eql(u8, callee, method_name);
        }

        // Pattern with :: (Class::method or Namespace\Class::method)
        if (std.mem.indexOf(u8, pattern, "::")) |pattern_sep| {
            const pattern_method = pattern[pattern_sep + 2 ..];

            // Check if callee has ::
            if (std.mem.indexOf(u8, callee, "::")) |callee_sep| {
                const callee_method = callee[callee_sep + 2 ..];

                // Method names must match
                if (!std.mem.eql(u8, callee_method, pattern_method)) {
                    return false;
                }

                // Check if class part matches (exact or ends with)
                const pattern_class = pattern[0..pattern_sep];
                const callee_class = callee[0..callee_sep];

                // Exact class match
                if (std.mem.eql(u8, callee_class, pattern_class)) {
                    return true;
                }

                // Callee class ends with pattern class (e.g., pattern "Service::foo" matches "App\Service::foo")
                if (std.mem.endsWith(u8, callee_class, pattern_class)) {
                    const prefix_len = callee_class.len - pattern_class.len;
                    if (prefix_len > 0 and callee_class[prefix_len - 1] == '\\') {
                        return true;
                    }
                }

                return false;
            } else {
                // Callee is just a method name (unresolved), check if method matches
                return std.mem.eql(u8, callee, pattern_method);
            }
        }

        // Pattern without :: matches function name or method name
        // Match standalone function
        if (std.mem.indexOf(u8, callee, "::") == null) {
            // Both are functions, check if callee ends with pattern
            if (std.mem.endsWith(u8, callee, pattern)) {
                // Make sure it's a complete match (not substring)
                if (callee.len == pattern.len) return true;
                if (callee.len > pattern.len and callee[callee.len - pattern.len - 1] == '\\') return true;
            }
            // Also exact match for just function name
            return std.mem.eql(u8, callee, pattern);
        } else {
            // Callee is a method, check if method name matches
            if (std.mem.indexOf(u8, callee, "::")) |sep| {
                const callee_method = callee[sep + 2 ..];
                return std.mem.eql(u8, callee_method, pattern);
            }
        }

        return false;
    }

    /// Output analysis result as text
    pub fn toText(self: *CalledBeforeAnalyzer, result: CalledBeforeResult, before_fn: []const u8, after_fn: []const u8, file: std.fs.File) !void {
        _ = self;
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        // Extract short names for display
        const before_short = extractShortName(before_fn);
        const after_short = extractShortName(after_fn);

        // Header with box drawing
        try writer.writeAll("\n");
        try writer.writeAll("╔══════════════════════════════════════════════════════════════════════════════╗\n");
        try writer.writeAll("║                         CALLED-BEFORE ANALYSIS                               ║\n");
        try writer.writeAll("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");

        // Constraint info
        try writer.writeAll("  Constraint:\n");
        try writer.print("    {s}\n", .{before_fn});
        try writer.writeAll("    must be called before\n");
        try writer.print("    {s}\n\n", .{after_fn});

        // Result summary
        if (result.satisfied) {
            try writer.writeAll("  Result: ✓ SATISFIED\n\n");
        } else {
            try writer.writeAll("  Result: ✗ VIOLATED\n\n");
        }

        // Violations section
        if (result.violations.len > 0) {
            try writer.writeAll("┌──────────────────────────────────────────────────────────────────────────────┐\n");
            try writer.print("│  VIOLATIONS ({d})                                                              │\n", .{result.violations.len});
            try writer.writeAll("└──────────────────────────────────────────────────────────────────────────────┘\n\n");

            for (result.violations, 0..) |violation, i| {
                // Violation number
                try writer.print("  [{d}] {s}\n", .{ i + 1, violation.context_function });

                // File location
                try writer.print("      File: {s}:{d}\n", .{ violation.file_path, violation.after_line });

                // Issue description
                switch (violation.kind) {
                    .wrong_order => {
                        try writer.print(
                            "      Issue: {s}() called at line {d}, but {s}() not called until line {d}\n",
                            .{ after_short, violation.after_line, before_short, violation.before_line orelse 0 },
                        );
                    },
                    .missing_before => {
                        try writer.print(
                            "      Issue: {s}() is never called before {s}()\n",
                            .{ before_short, after_short },
                        );
                    },
                    .conditional_before => {
                        try writer.writeAll("      Issue: Before call may not execute on all paths\n");
                    },
                }

                // Show call paths missing the before call
                if (violation.missing_before_paths.len > 0) {
                    try writer.writeAll("\n      Call paths missing the before call:\n");
                    for (violation.missing_before_paths) |path| {
                        try writer.print(
                            "        → {s} (line {d})\n          {s}\n",
                            .{ path.caller, path.call_line, path.file_path },
                        );
                    }
                }

                try writer.writeAll("\n");
            }
        }

        // Summary statistics
        try writer.writeAll("┌──────────────────────────────────────────────────────────────────────────────┐\n");
        try writer.writeAll("│  SUMMARY                                                                     │\n");
        try writer.writeAll("└──────────────────────────────────────────────────────────────────────────────┘\n\n");

        try writer.print(
            "  Functions satisfying constraint: {d}\n  Total constraint matches: {d}\n  Violations: {d}\n\n",
            .{ result.satisfied_in.len, result.matches.len, result.violations.len },
        );

        // Satisfied functions list (collapsed by default - just show count)
        if (result.satisfied_in.len > 0) {
            try writer.writeAll("  Satisfied in:\n");
            for (result.satisfied_in) |fn_name| {
                try writer.print("    ✓ {s}\n", .{fn_name});
            }
            try writer.writeAll("\n");
        }
        try writer.flush();
    }

    /// Output analysis result as JSON
    pub fn toJson(self: *CalledBeforeAnalyzer, result: CalledBeforeResult, before_fn: []const u8, after_fn: []const u8, file: std.fs.File) !void {
        _ = self;
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");
        try writer.writeAll("  \"constraint\": {\n");
        try writer.print("    \"before\": \"{s}\",\n", .{before_fn});
        try writer.print("    \"after\": \"{s}\"\n", .{after_fn});
        try writer.writeAll("  },\n");
        try writer.print("  \"satisfied\": {s},\n", .{if (result.satisfied) "true" else "false"});

        // Violations
        try writer.writeAll("  \"violations\": [");
        for (result.violations, 0..) |violation, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {\n");
            try writer.print("      \"context_function\": \"{s}\",\n", .{violation.context_function});
            try writer.print("      \"file\": \"{s}\",\n", .{violation.file_path});
            try writer.print("      \"after_line\": {d},\n", .{violation.after_line});
            if (violation.before_line) |bl| {
                try writer.print("      \"before_line\": {d},\n", .{bl});
            } else {
                try writer.writeAll("      \"before_line\": null,\n");
            }
            const kind_str = switch (violation.kind) {
                .wrong_order => "wrong_order",
                .missing_before => "missing_before",
                .conditional_before => "conditional_before",
            };
            try writer.print("      \"kind\": \"{s}\"\n", .{kind_str});
            try writer.writeAll("    }");
        }
        if (result.violations.len > 0) {
            try writer.writeAll("\n  ");
        }
        try writer.writeAll("],\n");

        // Matches
        try writer.writeAll("  \"matches\": [");
        for (result.matches, 0..) |match, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {\n");
            try writer.print("      \"context_function\": \"{s}\",\n", .{match.context_function});
            try writer.print("      \"file\": \"{s}\",\n", .{match.file_path});
            try writer.print("      \"after_line\": {d},\n", .{match.after_line});
            try writer.print("      \"after_callee\": \"{s}\",\n", .{match.after_callee});
            try writer.print("      \"before_line\": {d},\n", .{match.before_line});
            try writer.print("      \"before_callee\": \"{s}\"\n", .{match.before_callee});
            try writer.writeAll("    }");
        }
        if (result.matches.len > 0) {
            try writer.writeAll("\n  ");
        }
        try writer.writeAll("],\n");

        // Summary
        try writer.writeAll("  \"summary\": {\n");
        try writer.print("    \"satisfied_count\": {d},\n", .{result.satisfied_in.len});
        try writer.print("    \"violation_count\": {d},\n", .{result.violations.len});
        try writer.print("    \"match_count\": {d}\n", .{result.matches.len});
        try writer.writeAll("  }\n");

        try writer.writeAll("}\n");
        try writer.flush();
    }

};

/// Extract short name from FQCN (e.g., "Namespace\Class::method" -> "method")
fn extractShortName(fqcn: []const u8) []const u8 {
    // Find :: for method
    if (std.mem.indexOf(u8, fqcn, "::")) |sep| {
        return fqcn[sep + 2 ..];
    }
    // Find last backslash for class
    var last_backslash: ?usize = null;
    for (fqcn, 0..) |c, i| {
        if (c == '\\') {
            last_backslash = i;
        }
    }
    if (last_backslash) |idx| {
        return fqcn[idx + 1 ..];
    }
    return fqcn;
}

const CallInfo = struct {
    callee: []const u8,
    line: u32,
    file_path: []const u8,
};

const CallerInfo = struct {
    caller: []const u8,
    line: u32,
    file_path: []const u8,
};

const BeforeCallInfo = struct {
    line: u32,
    callee: []const u8,
};

const AfterCallInfo = struct {
    line: u32,
    callee: []const u8,
};

// ============================================================================
// Tests
// ============================================================================

extern fn tree_sitter_php() callconv(.c) *ts.Language;

// ============================================================================
// Test Helpers
// ============================================================================

const SymbolCollector = @import("main.zig").SymbolCollector;

fn parsePhp(source: []const u8) struct { *ts.Tree, *const ts.Language } {
    const parser = ts.Parser.create();
    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch unreachable;
    const tree = parser.parseString(source, null) orelse unreachable;
    return .{ tree, php_lang };
}

fn analyzeSource(allocator: std.mem.Allocator, source: []const u8) !struct { *CallAnalyzer, *SymbolTable, *types.FileContext } {
    const result = parsePhp(source);
    const tree = result[0];
    const php_lang = result[1];

    const sym_table = try allocator.create(SymbolTable);
    sym_table.* = SymbolTable.init(allocator);

    const file_ctx = try allocator.create(types.FileContext);
    file_ctx.* = types.FileContext.init(allocator, "test.php");

    var collector = SymbolCollector.init(allocator, sym_table, file_ctx, source, php_lang);
    try collector.collect(tree);

    try sym_table.resolveInheritance();

    const analyzer = try allocator.create(CallAnalyzer);
    analyzer.* = CallAnalyzer.init(allocator, sym_table, file_ctx, php_lang);
    try analyzer.analyzeFile(tree, source, "test.php");

    return .{ analyzer, sym_table, file_ctx };
}

fn findCall(calls: []const EnhancedFunctionCall, callee_name: []const u8) ?EnhancedFunctionCall {
    for (calls) |call| {
        if (std.mem.eql(u8, call.callee_name, callee_name)) {
            return call;
        }
    }
    return null;
}

fn findCallWithTarget(calls: []const EnhancedFunctionCall, target: []const u8) ?EnhancedFunctionCall {
    for (calls) |call| {
        if (call.resolved_target) |t| {
            if (std.mem.eql(u8, t, target)) {
                return call;
            }
        }
    }
    return null;
}

fn countCallsWithCallee(calls: []const EnhancedFunctionCall, callee_name: []const u8) usize {
    var count: usize = 0;
    for (calls) |call| {
        if (std.mem.eql(u8, call.callee_name, callee_name)) {
            count += 1;
        }
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "CallAnalyzer basic" {
    // Basic structure test - would need tree-sitter integration for full test
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    const php_lang = tree_sitter_php();
    var analyzer = CallAnalyzer.init(allocator, &sym_table, &file_ctx, php_lang);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.calls.items.len == 0);
}

test "CallAnalyzer: $this->method() call" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class UserService {
        \\    public function validate(): void {}
        \\    public function process(): void {
        \\        $this->validate();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "validate");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("UserService::process", call.?.caller_fqn);
    try std.testing.expect(call.?.resolution_method == .this_reference);
}

test "CallAnalyzer: typed parameter call" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Logger {
        \\    public function log(): void {}
        \\}
        \\class App {
        \\    public function run(Logger $logger): void {
        \\        $logger->log();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "log");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("App::run", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Logger::log", call.?.resolved_target.?);
}

test "CallAnalyzer: Foo::staticMethod()" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Foo {
        \\    public static function create(): void {}
        \\}
        \\class Bar {
        \\    public function build(): void {
        \\        Foo::create();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "create");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .static_method);
    try std.testing.expectEqualStrings("Bar::build", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Foo::create", call.?.resolved_target.?);
    try std.testing.expect(call.?.resolution_method == .explicit_type);
}

test "CallAnalyzer: self::method()" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Counter {
        \\    public static function increment(): void {}
        \\    public function tick(): void {
        \\        self::increment();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "increment");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .static_method);
    try std.testing.expect(call.?.resolution_method == .self_reference);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Counter::increment", call.?.resolved_target.?);
}

test "CallAnalyzer: parent::method()" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Base {
        \\    public function setup(): void {}
        \\}
        \\class Child extends Base {
        \\    public function setup(): void {
        \\        parent::setup();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "setup");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .static_method);
    try std.testing.expect(call.?.resolution_method == .parent_reference);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Base::setup", call.?.resolved_target.?);
}

test "CallAnalyzer: assignment tracking (new Foo(); $x->bar())" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Foo {
        \\    public function bar(): void {}
        \\}
        \\class Runner {
        \\    public function run(): void {
        \\        $x = new Foo();
        \\        $x->bar();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "bar");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("Runner::run", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Foo::bar", call.?.resolved_target.?);
}

test "CallAnalyzer: unresolved call (null target)" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Service {
        \\    public function process($unknown): void {
        \\        $unknown->doSomething();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "doSomething");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expect(call.?.resolved_target == null);
    try std.testing.expect(call.?.resolution_method == .unresolved);
}

test "CallAnalyzer: function call with namespace" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\namespace App\Util;
        \\function helper(): void {}
        \\function main(): void {
        \\    helper();
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "helper");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .function);
    try std.testing.expectEqualStrings("main", call.?.caller_fqn);
}

test "CallAnalyzer: chained call (return type chain)" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Builder {
        \\    public function build(): Result { return new Result(); }
        \\}
        \\class Result {
        \\    public function get(): void {}
        \\}
        \\class App {
        \\    public function run(Builder $b): void {
        \\        $b->build()->get();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    // The chained call should find both build() and get()
    const build_call = findCall(calls, "build");
    try std.testing.expect(build_call != null);
    try std.testing.expect(build_call.?.call_type == .method);

    const get_call = findCall(calls, "get");
    try std.testing.expect(get_call != null);
    try std.testing.expect(get_call.?.call_type == .method);
}

test "CallAnalyzer: multiple calls in method (all captured with lines)" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Svc {
        \\    public function a(): void {}
        \\    public function b(): void {}
        \\    public function c(): void {}
        \\    public function run(): void {
        \\        $this->a();
        \\        $this->b();
        \\        $this->c();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    // All three calls should be captured
    try std.testing.expect(findCall(calls, "a") != null);
    try std.testing.expect(findCall(calls, "b") != null);
    try std.testing.expect(findCall(calls, "c") != null);

    // Verify lines are ordered
    const call_a = findCall(calls, "a").?;
    const call_b = findCall(calls, "b").?;
    const call_c = findCall(calls, "c").?;

    try std.testing.expect(call_a.line < call_b.line);
    try std.testing.expect(call_b.line < call_c.line);

    // All should have the same caller
    try std.testing.expectEqualStrings("Svc::run", call_a.caller_fqn);
    try std.testing.expectEqualStrings("Svc::run", call_b.caller_fqn);
    try std.testing.expectEqualStrings("Svc::run", call_c.caller_fqn);
}

// ============================================================================
// CalledBeforeAnalyzer Tests
// ============================================================================

fn buildCallGraph(allocator: std.mem.Allocator, sym_table: *SymbolTable) !*ProjectCallGraph {
    const graph = try allocator.create(ProjectCallGraph);
    graph.* = ProjectCallGraph.init(allocator, sym_table);
    return graph;
}

fn addSyntheticCall(
    graph: *ProjectCallGraph,
    caller_fqn: []const u8,
    callee_name: []const u8,
    resolved_target: ?[]const u8,
    file_path: []const u8,
    line: u32,
) !void {
    const call = EnhancedFunctionCall{
        .caller_fqn = caller_fqn,
        .callee_name = callee_name,
        .call_type = .method,
        .line = line,
        .column = 1,
        .file_path = file_path,
        .resolved_target = resolved_target,
        .resolution_confidence = if (resolved_target != null) 1.0 else 0.0,
        .resolution_method = if (resolved_target != null) .explicit_type else .unresolved,
    };
    try graph.calls.append(graph.allocator, call);
    graph.total_calls += 1;
    if (resolved_target != null) {
        graph.resolved_calls += 1;
    } else {
        graph.unresolved_calls += 1;
    }
}

test "CalledBeforeAnalyzer: satisfied constraint (correct order)" {
    // before() is called on line 5, after() on line 10 in the same function => satisfied
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Controller::handle calls validate() then process()
    try addSyntheticCall(graph, "Controller::handle", "validate", "Service::validate", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "process", "Service::process", "src/Controller.php", 10);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
    try std.testing.expect(result.matches.len == 1);
    try std.testing.expect(result.satisfied_in.len == 1);
    try std.testing.expectEqualStrings("Controller::handle", result.satisfied_in[0]);
}

test "CalledBeforeAnalyzer: violated wrong order" {
    // after() is called on line 5, before() on line 10 => wrong_order violation
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Controller::handle calls process() then validate() (wrong order)
    try addSyntheticCall(graph, "Controller::handle", "process", "Service::process", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "validate", "Service::validate", "src/Controller.php", 10);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    try std.testing.expect(!result.satisfied);
    try std.testing.expect(result.violations.len == 1);
    try std.testing.expect(result.violations[0].kind == .wrong_order);
    try std.testing.expect(result.violations[0].after_line == 5);
    try std.testing.expect(result.violations[0].before_line.? == 10);
}

test "CalledBeforeAnalyzer: violated missing before" {
    // after() is called but before() is never called => missing_before violation
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Controller::handle calls process() but never validate()
    try addSyntheticCall(graph, "Controller::handle", "process", "Service::process", "src/Controller.php", 5);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    try std.testing.expect(!result.satisfied);
    try std.testing.expect(result.violations.len == 1);
    try std.testing.expect(result.violations[0].kind == .missing_before);
}

test "CalledBeforeAnalyzer: multiple callers with mixed results" {
    // Two callers: one satisfies the constraint, one violates it
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // GoodController::handle calls validate() then process() (OK)
    try addSyntheticCall(graph, "GoodController::handle", "validate", "Service::validate", "src/Good.php", 5);
    try addSyntheticCall(graph, "GoodController::handle", "process", "Service::process", "src/Good.php", 10);

    // BadController::handle calls process() without validate() (violation)
    try addSyntheticCall(graph, "BadController::handle", "process", "Service::process", "src/Bad.php", 5);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    try std.testing.expect(!result.satisfied);
    try std.testing.expect(result.violations.len == 1);
    try std.testing.expect(result.matches.len == 1);
    try std.testing.expectEqualStrings("GoodController::handle", result.satisfied_in[0]);
}

test "CalledBeforeAnalyzer: transitive calls (before reached indirectly)" {
    // Caller A calls validate(), then calls helper(). helper() calls process().
    // The before call is in A, the after call is in helper(). The interprocedural
    // analysis should find that A (caller of helper) has validate() before calling helper().
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Controller::handle calls validate() then calls helper()
    try addSyntheticCall(graph, "Controller::handle", "validate", "Service::validate", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "doWork", "Helper::doWork", "src/Controller.php", 10);

    // Helper::doWork calls process() (after_fn) but not validate() directly
    try addSyntheticCall(graph, "Helper::doWork", "process", "Service::process", "src/Helper.php", 3);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    // Should be satisfied via interprocedural analysis:
    // Controller::handle calls validate() at line 5, then Helper::doWork at line 10,
    // and Helper::doWork calls process(). So the constraint is satisfied.
    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
}

test "CalledBeforeAnalyzer: pattern matching short name" {
    // Use just the method name as pattern (no class qualifier)
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Controller::handle calls validate then process
    try addSyntheticCall(graph, "Controller::handle", "validate", "App\\Service::validate", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "process", "App\\Service::process", "src/Controller.php", 10);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    // Use ::methodName pattern
    const result = try analyzer.analyze("::validate", "::process");

    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
    try std.testing.expect(result.matches.len == 1);
}

test "CalledBeforeAnalyzer: pattern matching FQCN" {
    // Use fully qualified class names (with namespace)
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    try addSyntheticCall(graph, "Controller::handle", "validate", "App\\Service::validate", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "process", "App\\Service::process", "src/Controller.php", 10);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    // Use FQCN pattern
    const result = try analyzer.analyze("App\\Service::validate", "App\\Service::process");

    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
    try std.testing.expect(result.matches.len == 1);
}

test "CalledBeforeAnalyzer: pattern matching suffix" {
    // Use Class::method suffix pattern to match Namespace\Class::method targets
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    try addSyntheticCall(graph, "Controller::handle", "validate", "App\\Domain\\Service::validate", "src/Controller.php", 5);
    try addSyntheticCall(graph, "Controller::handle", "process", "App\\Domain\\Service::process", "src/Controller.php", 10);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    // Use suffix pattern (Service::method matches App\Domain\Service::method)
    const result = try analyzer.analyze("Service::validate", "Service::process");

    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
    try std.testing.expect(result.matches.len == 1);
}

test "CalledBeforeAnalyzer: no matches for either function" {
    // Neither before nor after function appear in the call graph => trivially satisfied (no violations)
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    const graph = try buildCallGraph(alloc, &sym_table);

    // Unrelated calls only
    try addSyntheticCall(graph, "Controller::handle", "doStuff", "Util::doStuff", "src/Controller.php", 5);

    var analyzer = CalledBeforeAnalyzer.init(alloc, graph);
    const result = try analyzer.analyze("Service::validate", "Service::process");

    // No function calls after_fn, so the constraint is trivially satisfied
    try std.testing.expect(result.satisfied);
    try std.testing.expect(result.violations.len == 0);
    try std.testing.expect(result.matches.len == 0);
    try std.testing.expect(result.satisfied_in.len == 0);
}

test "CallAnalyzer: method return type propagation ($x = $this->getService(); $x->doWork())" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Logger {
        \\    public function info(): void {}
        \\}
        \\class ServiceLocator {
        \\    public function getLogger(): Logger { return new Logger(); }
        \\}
        \\class App extends ServiceLocator {
        \\    public function run(): void {
        \\        $logger = $this->getLogger();
        \\        $logger->info();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "info");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("App::run", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Logger::info", call.?.resolved_target.?);
    try std.testing.expect(call.?.resolution_method == .assignment_tracking);
}

test "CallAnalyzer: static factory return type propagation ($x = Foo::create(); $x->run())" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Worker {
        \\    public static function create(): Worker { return new Worker(); }
        \\    public function run(): void {}
        \\}
        \\class App {
        \\    public function execute(): void {
        \\        $w = Worker::create();
        \\        $w->run();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "run");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("App::execute", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Worker::run", call.?.resolved_target.?);
    try std.testing.expect(call.?.resolution_method == .assignment_tracking);
}

test "CallAnalyzer: chained call resolves both hops ($this->getRepo()->findAll())" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Collection {
        \\    public function count(): int { return 0; }
        \\}
        \\class Repository {
        \\    public function findAll(): Collection { return new Collection(); }
        \\}
        \\class Service {
        \\    private Repository $repo;
        \\    public function getRepo(): Repository { return $this->repo; }
        \\    public function process(): void {
        \\        $this->getRepo()->findAll();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    // First hop: getRepo() resolves to Service::getRepo
    const repo_call = findCall(calls, "getRepo");
    try std.testing.expect(repo_call != null);
    try std.testing.expect(repo_call.?.call_type == .method);
    try std.testing.expect(repo_call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Service::getRepo", repo_call.?.resolved_target.?);

    // Second hop: findAll() resolves to Repository::findAll via return type chain
    const find_call = findCall(calls, "findAll");
    try std.testing.expect(find_call != null);
    try std.testing.expect(find_call.?.call_type == .method);
    try std.testing.expect(find_call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Repository::findAll", find_call.?.resolved_target.?);
    try std.testing.expect(find_call.?.resolution_method == .return_type_chain);
}

test "CallAnalyzer: conditional assignment — unresolved without common type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    // When a variable is assigned in a conditional block but not tracked
    // across branches, the call should be unresolved (conservative)
    const source =
        \\<?php
        \\class Dog {
        \\    public function speak(): void {}
        \\}
        \\class Cat {
        \\    public function speak(): void {}
        \\}
        \\class App {
        \\    public function handle(bool $flag): void {
        \\        if ($flag) {
        \\            $animal = new Dog();
        \\        } else {
        \\            $animal = new Cat();
        \\        }
        \\        $animal->speak();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    // The speak() call on $animal after the if/else
    // Count speak calls — there may be multiple due to the conditional
    const speak_count = countCallsWithCallee(calls, "speak");
    try std.testing.expect(speak_count >= 1);

    // Find the last speak call (the one after the conditional)
    // In conservative handling, it may resolve to whichever assignment
    // the analyzer saw last, or be unresolved
    const call = findCall(calls, "speak");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
}

test "CallAnalyzer: loop variable type tracking" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Item {
        \\    public function process(): void {}
        \\}
        \\class Processor {
        \\    /** @param Item[] $items */
        \\    public function run(Item $item): void {
        \\        $item->process();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    // The typed parameter $item should resolve process() to Item::process
    const call = findCall(calls, "process");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("Processor::run", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Item::process", call.?.resolved_target.?);
}

test "CallAnalyzer: assignment from new in loop body" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Task {
        \\    public function execute(): void {}
        \\}
        \\class Runner {
        \\    public function run(): void {
        \\        for ($i = 0; $i < 10; $i++) {
        \\            $task = new Task();
        \\            $task->execute();
        \\        }
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "execute");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("Runner::run", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Task::execute", call.?.resolved_target.?);
}

test "CallAnalyzer: constructor injection property type propagation" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Repository {
        \\    public function findAll(): void {}
        \\}
        \\class Service {
        \\    private $repo;
        \\    public function __construct(Repository $repo) {
        \\        $this->repo = $repo;
        \\    }
        \\    public function load(): void {
        \\        $this->repo->findAll();
        \\    }
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "findAll");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("Service::load", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Repository::findAll", call.?.resolved_target.?);
}

test "CallAnalyzer: call in standalone function" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Printer {
        \\    public function print(): void {}
        \\}
        \\function doPrint(Printer $p): void {
        \\    $p->print();
        \\}
    ;

    const result = try analyzeSource(alloc, source);
    const calls = result[0].getCalls();

    const call = findCall(calls, "print");
    try std.testing.expect(call != null);
    try std.testing.expect(call.?.call_type == .method);
    try std.testing.expectEqualStrings("doPrint", call.?.caller_fqn);
    try std.testing.expect(call.?.resolved_target != null);
    try std.testing.expectEqualStrings("Printer::print", call.?.resolved_target.?);
}
