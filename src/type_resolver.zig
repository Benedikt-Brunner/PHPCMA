const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const phpdoc = @import("phpdoc.zig");
const generics = @import("generics.zig");

const TypeInfo = types.TypeInfo;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const FileContext = types.FileContext;
const ScopeContext = types.ScopeContext;
const SymbolTable = symbol_table.SymbolTable;

// ============================================================================
// Type Resolver - Infers types from AST nodes
// ============================================================================

pub const TypeResolver = struct {
    symbol_table: *SymbolTable,
    file_context: *FileContext,
    allocator: std.mem.Allocator,

    // Current context
    current_class: ?*const ClassSymbol,
    current_method: ?*const MethodSymbol,
    scope_stack: std.ArrayListUnmanaged(*ScopeContext),

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
    ) TypeResolver {
        return .{
            .symbol_table = sym_table,
            .file_context = file_ctx,
            .allocator = allocator,
            .current_class = null,
            .current_method = null,
            .scope_stack = .empty,
        };
    }

    pub fn deinit(self: *TypeResolver) void {
        for (self.scope_stack.items) |scope| {
            scope.deinit();
            self.allocator.destroy(scope);
        }
        self.scope_stack.deinit(self.allocator);
    }

    // ========================================================================
    // Scope Management
    // ========================================================================

    pub fn pushScope(self: *TypeResolver) !*ScopeContext {
        const parent = if (self.scope_stack.items.len > 0)
            self.scope_stack.items[self.scope_stack.items.len - 1]
        else
            null;

        const scope = try self.allocator.create(ScopeContext);
        scope.* = ScopeContext.init(self.allocator, parent);
        try self.scope_stack.append(self.allocator, scope);
        return scope;
    }

    pub fn popScope(self: *TypeResolver) void {
        if (self.scope_stack.pop()) |scope| {
            scope.deinit();
            self.allocator.destroy(scope);
        }
    }

    pub fn currentScope(self: *TypeResolver) ?*ScopeContext {
        if (self.scope_stack.items.len > 0) {
            return self.scope_stack.items[self.scope_stack.items.len - 1];
        }
        return null;
    }

    // ========================================================================
    // Type Resolution
    // ========================================================================

    /// Resolve the type of an expression node
    pub fn resolveExpressionType(self: *TypeResolver, node: ts.Node, source: []const u8) !?TypeInfo {
        const kind = node.kind();

        // Variable reference (handles $this, scope lookup, and parameter types)
        if (std.mem.eql(u8, kind, "variable_name")) {
            return self.resolveVariableType(node, source);
        }

        // new ClassName()
        if (std.mem.eql(u8, kind, "object_creation_expression")) {
            return self.resolveNewExpressionType(node, source);
        }

        // Method call $obj->method()
        if (std.mem.eql(u8, kind, "member_call_expression")) {
            return self.resolveMethodCallType(node, source);
        }

        // Static method call Class::method()
        if (std.mem.eql(u8, kind, "scoped_call_expression")) {
            return self.resolveStaticMethodCallType(node, source);
        }

        // Property access $obj->property
        if (std.mem.eql(u8, kind, "member_access_expression")) {
            return self.resolvePropertyAccessType(node, source);
        }

        // Function call
        if (std.mem.eql(u8, kind, "function_call_expression")) {
            return self.resolveFunctionCallType(node, source);
        }

        // Array creation
        if (std.mem.eql(u8, kind, "array_creation_expression")) {
            return TypeInfo{
                .kind = .array_type,
                .base_type = "array",
                .type_parts = &.{},
                .is_builtin = true,
            };
        }

        // String literal
        if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "encapsed_string")) {
            return try TypeInfo.simple(self.allocator, "string");
        }

        // Integer literal
        if (std.mem.eql(u8, kind, "integer")) {
            return try TypeInfo.simple(self.allocator, "int");
        }

        // Float literal
        if (std.mem.eql(u8, kind, "float")) {
            return try TypeInfo.simple(self.allocator, "float");
        }

        // Boolean literal
        if (std.mem.eql(u8, kind, "boolean")) {
            return try TypeInfo.simple(self.allocator, "bool");
        }

        // Null literal
        if (std.mem.eql(u8, kind, "null")) {
            return try TypeInfo.simple(self.allocator, "null");
        }

        return null;
    }

    /// Resolve $this type
    fn resolveThisType(self: *TypeResolver) ?TypeInfo {
        if (self.current_class) |class| {
            return TypeInfo{
                .kind = .simple,
                .base_type = class.fqcn,
                .type_parts = &.{},
                .is_builtin = false,
            };
        }
        return null;
    }

    /// Resolve variable type from scope or context
    fn resolveVariableType(self: *TypeResolver, node: ts.Node, source: []const u8) ?TypeInfo {
        const var_name = getNodeText(source, node);

        // Check for $this
        if (std.mem.eql(u8, var_name, "$this")) {
            return self.resolveThisType();
        }

        // Check current scope
        if (self.currentScope()) |scope| {
            if (scope.getVariableType(var_name)) |t| {
                return t;
            }
        }

        // Check if it's a parameter of current method
        if (self.current_method) |method| {
            const param_name = if (var_name.len > 0 and var_name[0] == '$')
                var_name[1..]
            else
                var_name;

            if (method.getParameterType(param_name)) |t| {
                return t;
            }
        }

        return null;
    }

    /// Resolve type of new ClassName() expression
    fn resolveNewExpressionType(self: *TypeResolver, node: ts.Node, source: []const u8) !?TypeInfo {
        // Get the class name node
        if (node.namedChild(0)) |class_node| {
            const class_kind = class_node.kind();
            if (std.mem.eql(u8, class_kind, "name") or std.mem.eql(u8, class_kind, "qualified_name")) {
                const class_name = getNodeText(source, class_node);
                const fqcn = try self.file_context.resolveFQCN(class_name);

                return TypeInfo{
                    .kind = .simple,
                    .base_type = try self.allocator.dupe(u8, fqcn),
                    .type_parts = &.{},
                    .is_builtin = false,
                };
            }
        }
        return null;
    }

    /// Resolve return type of a method call
    fn resolveMethodCallType(self: *TypeResolver, node: ts.Node, source: []const u8) error{OutOfMemory}!?TypeInfo {
        // Get object being called on
        const object_node = node.childByFieldName("object") orelse return null;
        const method_node = node.childByFieldName("name") orelse return null;

        // Resolve object type
        const object_type_opt = self.resolveExpressionType(object_node, source) catch return null;
        const object_type = object_type_opt orelse return null;

        // Get method name
        const method_name = getNodeText(source, method_node);

        // Look up method in symbol table
        if (self.symbol_table.resolveMethod(object_type.base_type, method_name)) |method| {
            // If the object type is generic and the class has template params,
            // use the generic substitution engine
            if (object_type.kind == .generic and object_type.type_params.len > 0) {
                if (self.symbol_table.getClass(object_type.base_type)) |class| {
                    if (class.template_params.len > 0) {
                        const ret = generics.resolveGenericMethodReturn(
                            self.allocator,
                            class,
                            method,
                            object_type,
                        ) catch return self.concretizeReturnType(method);
                        return ret;
                    }
                }
            }
            return self.concretizeReturnType(method);
        }

        return null;
    }

    /// Resolve return type of a static method call
    fn resolveStaticMethodCallType(self: *TypeResolver, node: ts.Node, source: []const u8) !?TypeInfo {
        // Get class name
        const scope_node = node.childByFieldName("scope") orelse return null;
        const method_node = node.childByFieldName("name") orelse return null;

        const class_name = getNodeText(source, scope_node);
        const method_name = getNodeText(source, method_node);

        // Handle special cases
        var fqcn: []const u8 = undefined;
        if (std.mem.eql(u8, class_name, "self") or std.mem.eql(u8, class_name, "static")) {
            if (self.current_class) |class| {
                fqcn = class.fqcn;
            } else {
                return null;
            }
        } else if (std.mem.eql(u8, class_name, "parent")) {
            if (self.current_class) |class| {
                if (class.extends) |parent| {
                    fqcn = parent;
                } else {
                    return null;
                }
            } else {
                return null;
            }
        } else {
            fqcn = try self.file_context.resolveFQCN(class_name);
        }

        // Look up method
        if (self.symbol_table.resolveMethod(fqcn, method_name)) |method| {
            return self.concretizeReturnType(method);
        }

        return null;
    }

    /// Concretize a method's effective return type using its containing_class as context
    fn concretizeReturnType(self: *TypeResolver, method: *const MethodSymbol) ?TypeInfo {
        const ret = method.effectiveReturnType() orelse return null;
        return self.concretizeSpecialType(ret, method.containing_class);
    }

    /// Resolve type of property access
    fn resolvePropertyAccessType(self: *TypeResolver, node: ts.Node, source: []const u8) error{OutOfMemory}!?TypeInfo {
        const object_node = node.childByFieldName("object") orelse return null;
        const name_node = node.childByFieldName("name") orelse return null;

        // Resolve object type
        const object_type_opt = self.resolveExpressionType(object_node, source) catch return null;
        const object_type = object_type_opt orelse return null;

        // Get property name
        const property_name = getNodeText(source, name_node);

        // Look up property in symbol table
        if (self.symbol_table.resolveProperty(object_type.base_type, property_name)) |prop| {
            return prop.effectiveType();
        }

        return null;
    }

    /// Resolve return type of a function call
    fn resolveFunctionCallType(self: *TypeResolver, node: ts.Node, source: []const u8) !?TypeInfo {
        const func_node = node.childByFieldName("function") orelse return null;

        const func_kind = func_node.kind();
        if (!std.mem.eql(u8, func_kind, "name") and !std.mem.eql(u8, func_kind, "qualified_name")) {
            return null;
        }

        const func_name = getNodeText(source, func_node);

        // Build FQN
        const fqn = if (std.mem.indexOf(u8, func_name, "\\") != null)
            func_name
        else if (self.file_context.namespace) |ns|
            try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, func_name })
        else
            func_name;

        // Look up function
        if (self.symbol_table.getFunction(fqn)) |func| {
            return func.effectiveReturnType();
        }

        return null;
    }

    // ========================================================================
    // Special Type Concretization
    // ========================================================================

    /// Concretize self/static/parent types to their concrete FQCN.
    /// Called when returning method/static-call return types so that
    /// downstream argument type checking compares concrete class names.
    fn concretizeSpecialType(self: *TypeResolver, type_info: TypeInfo, context_class_fqcn: []const u8) TypeInfo {
        return switch (type_info.kind) {
            .self_type, .static_type => TypeInfo{
                .kind = .simple,
                .base_type = context_class_fqcn,
                .type_parts = type_info.type_parts,
                .type_params = type_info.type_params,
                .is_builtin = false,
            },
            .parent_type => blk: {
                if (self.symbol_table.getClass(context_class_fqcn)) |class| {
                    if (class.extends) |parent_fqcn| {
                        break :blk TypeInfo{
                            .kind = .simple,
                            .base_type = parent_fqcn,
                            .type_parts = type_info.type_parts,
                            .type_params = type_info.type_params,
                            .is_builtin = false,
                        };
                    }
                }
                break :blk type_info;
            },
            .nullable => blk: {
                // For nullable types, concretize the inner type if it's a special reference
                const inner_kind = self.specialKindFromBaseName(type_info.base_type);
                if (inner_kind) |sk| {
                    const inner = TypeInfo{
                        .kind = sk,
                        .base_type = type_info.base_type,
                        .type_parts = &.{},
                        .is_builtin = false,
                    };
                    const concretized = self.concretizeSpecialType(inner, context_class_fqcn);
                    if (concretized.kind == .simple) {
                        break :blk TypeInfo{
                            .kind = .nullable,
                            .base_type = concretized.base_type,
                            .type_parts = type_info.type_parts,
                            .type_params = type_info.type_params,
                            .is_builtin = false,
                        };
                    }
                }
                break :blk type_info;
            },
            .union_type => blk: {
                // For union types, concretize any parts that are special types
                var needs_concretize = false;
                for (type_info.type_parts) |part| {
                    if (self.specialKindFromBaseName(part) != null) {
                        needs_concretize = true;
                        break;
                    }
                }
                if (!needs_concretize) break :blk type_info;

                const new_parts = self.allocator.alloc([]const u8, type_info.type_parts.len) catch break :blk type_info;
                for (type_info.type_parts, 0..) |part, i| {
                    if (self.specialKindFromBaseName(part)) |sk| {
                        const inner = TypeInfo{
                            .kind = sk,
                            .base_type = part,
                            .type_parts = &.{},
                            .is_builtin = false,
                        };
                        const concretized = self.concretizeSpecialType(inner, context_class_fqcn);
                        new_parts[i] = concretized.base_type;
                    } else {
                        new_parts[i] = part;
                    }
                }
                break :blk TypeInfo{
                    .kind = .union_type,
                    .base_type = type_info.base_type,
                    .type_parts = new_parts,
                    .type_params = type_info.type_params,
                    .is_builtin = type_info.is_builtin,
                };
            },
            .intersection => blk: {
                var needs_concretize = false;
                for (type_info.type_parts) |part| {
                    if (self.specialKindFromBaseName(part) != null) {
                        needs_concretize = true;
                        break;
                    }
                }
                if (!needs_concretize) break :blk type_info;

                const new_parts = self.allocator.alloc([]const u8, type_info.type_parts.len) catch break :blk type_info;
                for (type_info.type_parts, 0..) |part, i| {
                    if (self.specialKindFromBaseName(part)) |sk| {
                        const inner = TypeInfo{
                            .kind = sk,
                            .base_type = part,
                            .type_parts = &.{},
                            .is_builtin = false,
                        };
                        const concretized = self.concretizeSpecialType(inner, context_class_fqcn);
                        new_parts[i] = concretized.base_type;
                    } else {
                        new_parts[i] = part;
                    }
                }
                break :blk TypeInfo{
                    .kind = .intersection,
                    .base_type = type_info.base_type,
                    .type_parts = new_parts,
                    .type_params = type_info.type_params,
                    .is_builtin = type_info.is_builtin,
                };
            },
            else => type_info,
        };
    }

    /// Map a base_type string to its special Kind, if applicable
    fn specialKindFromBaseName(_: *TypeResolver, name: []const u8) ?TypeInfo.Kind {
        if (std.mem.eql(u8, name, "self")) return .self_type;
        if (std.mem.eql(u8, name, "static")) return .static_type;
        if (std.mem.eql(u8, name, "parent")) return .parent_type;
        return null;
    }

    // ========================================================================
    // Assignment Tracking
    // ========================================================================

    /// Track an assignment and update scope
    pub fn trackAssignment(self: *TypeResolver, node: ts.Node, source: []const u8) !void {
        const lhs = node.childByFieldName("left") orelse return;
        const rhs = node.childByFieldName("right") orelse return;

        const lhs_kind = lhs.kind();

        // Simple variable assignment: $var = ...
        if (std.mem.eql(u8, lhs_kind, "variable_name")) {
            const var_name = getNodeText(source, lhs);
            if (try self.resolveExpressionType(rhs, source)) |type_info| {
                if (self.currentScope()) |scope| {
                    try scope.setVariableType(var_name, type_info);
                }
            }
        }

        // Property assignment: $this->prop = ...
        if (std.mem.eql(u8, lhs_kind, "member_access_expression")) {
            try self.trackPropertyAssignment(lhs, rhs, source);
        }
    }

    /// Track property assignment for type inference
    fn trackPropertyAssignment(self: *TypeResolver, lhs: ts.Node, rhs: ts.Node, source: []const u8) !void {
        const object_node = lhs.childByFieldName("object") orelse return;
        const name_node = lhs.childByFieldName("name") orelse return;

        const object_text = getNodeText(source, object_node);

        // Only track $this->property assignments
        if (!std.mem.eql(u8, object_text, "$this")) return;

        const property_name = getNodeText(source, name_node);

        // Resolve the RHS type
        if (try self.resolveExpressionType(rhs, source)) |type_info| {
            // Store in current class if we're in one
            if (self.current_class) |class| {
                // Try to find the property and update its inferred type
                if (self.symbol_table.getClassMut(class.fqcn)) |mutable_class| {
                    if (mutable_class.properties.getPtr(property_name)) |prop| {
                        if (prop.declared_type == null and prop.phpdoc_type == null) {
                            prop.default_value_type = type_info;
                        }
                    }
                }
            }
        }
    }

    // ========================================================================
    // Constructor Parameter Tracking
    // ========================================================================

    /// Track constructor parameters for property type inference
    pub fn trackConstructorInjection(self: *TypeResolver, method: *const MethodSymbol, source: []const u8, body_node: ts.Node) !void {
        if (!std.mem.eql(u8, method.name, "__construct")) return;

        // Build a map of parameter name -> type
        var param_types = std.StringHashMap(TypeInfo).init(self.allocator);
        defer param_types.deinit();

        for (method.parameters) |param| {
            const type_info = param.type_info orelse param.phpdoc_type orelse continue;
            try param_types.put(param.name, type_info);
        }

        // Traverse constructor body looking for $this->prop = $param patterns
        try self.scanConstructorAssignments(body_node, &param_types, source);
    }

    fn scanConstructorAssignments(self: *TypeResolver, node: ts.Node, param_types: *std.StringHashMap(TypeInfo), source: []const u8) !void {
        // Traverse the AST looking for patterns like:
        // $this->repository = $repository;
        // Where $repository is a typed constructor parameter
        const kind = node.kind();

        if (std.mem.eql(u8, kind, "assignment_expression")) {
            const lhs = node.childByFieldName("left") orelse return;
            const rhs = node.childByFieldName("right") orelse return;

            // Check if LHS is $this->property
            if (std.mem.eql(u8, lhs.kind(), "member_access_expression")) {
                const obj_node = lhs.childByFieldName("object") orelse return;
                const name_node = lhs.childByFieldName("name") orelse return;

                const obj_text = getNodeText(source, obj_node);
                if (!std.mem.eql(u8, obj_text, "$this")) return;

                const prop_name = getNodeText(source, name_node);

                // Check if RHS is a variable that matches a typed parameter
                if (std.mem.eql(u8, rhs.kind(), "variable_name")) {
                    const rhs_text = getNodeText(source, rhs);
                    const param_name = if (rhs_text.len > 0 and rhs_text[0] == '$')
                        rhs_text[1..]
                    else
                        rhs_text;

                    if (param_types.get(param_name)) |type_info| {
                        // Update the property's type in the symbol table
                        if (self.current_class) |class| {
                            if (self.symbol_table.getClassMut(class.fqcn)) |mutable_class| {
                                if (mutable_class.properties.getPtr(prop_name)) |prop| {
                                    if (prop.declared_type == null and prop.phpdoc_type == null) {
                                        prop.default_value_type = type_info;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return;
        }

        // Recurse into children
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.scanConstructorAssignments(child, param_types, source);
            }
        }
    }

    // ========================================================================
    // Method Resolution
    // ========================================================================

    /// Resolve a method call to its target FQCN
    pub fn resolveMethodCall(
        self: *TypeResolver,
        object_type: ?TypeInfo,
        method_name: []const u8,
    ) ?*const MethodSymbol {
        const type_info = object_type orelse return null;

        // Handle special types
        if (type_info.kind == .self_type or type_info.kind == .static_type) {
            if (self.current_class) |class| {
                return self.symbol_table.resolveMethod(class.fqcn, method_name);
            }
            return null;
        }

        if (type_info.kind == .parent_type) {
            if (self.current_class) |class| {
                if (class.extends) |parent| {
                    return self.symbol_table.resolveMethod(parent, method_name);
                }
            }
            return null;
        }

        return self.symbol_table.resolveMethod(type_info.base_type, method_name);
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

// ============================================================================
// Tests
// ============================================================================

extern fn tree_sitter_php() callconv(.c) *ts.Language;

/// Helper: parse PHP source and return the tree (caller must destroy)
fn testParse(source: []const u8) ?*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch return null;
    return parser.parseString(source, null);
}

/// Helper: recursively find first node matching a given kind string
fn findNodeByKind(node: ts.Node, kind_str: []const u8) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), kind_str)) {
        return node;
    }
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (node.namedChild(i)) |child| {
            if (findNodeByKind(child, kind_str)) |found| {
                return found;
            }
        }
    }
    return null;
}

/// Helper: find all nodes matching a given kind string
fn findAllNodesByKind(allocator: std.mem.Allocator, node: ts.Node, kind_str: []const u8, results: *std.ArrayListUnmanaged(ts.Node)) !void {
    if (std.mem.eql(u8, node.kind(), kind_str)) {
        try results.append(allocator, node);
    }
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (node.namedChild(i)) |child| {
            try findAllNodesByKind(allocator, child, kind_str, results);
        }
    }
}

test "resolveThisType in class context" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();
    file_ctx.namespace = "App\\Service";

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Set up current class context
    const class = types.ClassSymbol.init(allocator, "App\\Service\\UserService");
    try sym_table.addClass(class);
    resolver.current_class = sym_table.getClass("App\\Service\\UserService");

    // Parse PHP with $this reference
    const source = "<?php $this->doSomething();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    // Find the variable_name node for $this
    const root = tree.rootNode();
    const var_node = findNodeByKind(root, "variable_name") orelse return error.NodeNotFound;
    const text = getNodeText(source, var_node);
    try std.testing.expectEqualStrings("$this", text);

    // Resolve type
    const type_info = try resolver.resolveExpressionType(var_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Service\\UserService", type_info.?.base_type);
}

test "resolveNewExpressionType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    var sym_table = SymbolTable.init(allocator);
    var file_ctx = types.FileContext.init(allocator, "test.php");
    file_ctx.namespace = "App";
    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);

    const source = "<?php $x = new Foo();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const new_node = findNodeByKind(root, "object_creation_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(new_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Foo", type_info.?.base_type);
    try std.testing.expect(!type_info.?.is_builtin);
}

test "variable type from assignment tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    var sym_table = SymbolTable.init(allocator);
    var file_ctx = types.FileContext.init(allocator, "test.php");
    file_ctx.namespace = "App";
    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);

    // Push a scope
    _ = try resolver.pushScope();

    const source = "<?php $x = new Foo();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();

    // Find assignment and track it
    const assign_node = findNodeByKind(root, "assignment_expression") orelse return error.NodeNotFound;
    try resolver.trackAssignment(assign_node, source);

    // Now resolve $x — find the variable_name node for $x
    var var_nodes: std.ArrayListUnmanaged(ts.Node) = .empty;
    defer var_nodes.deinit(allocator);
    try findAllNodesByKind(allocator, root, "variable_name", &var_nodes);

    // Find $x (not in the new expression context, but on the LHS)
    var x_node: ?ts.Node = null;
    for (var_nodes.items) |vn| {
        if (std.mem.eql(u8, getNodeText(source, vn), "$x")) {
            x_node = vn;
            break;
        }
    }
    const var_node = x_node orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(var_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Foo", type_info.?.base_type);
}

test "parameter type resolution" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Set up a method with a typed parameter
    const param = types.ParameterInfo{
        .name = "service",
        .type_info = TypeInfo{
            .kind = .simple,
            .base_type = "App\\UserService",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .has_default = false,
        .is_variadic = false,
        .is_by_reference = false,
        .is_promoted = false,
        .phpdoc_type = null,
    };

    const params = [_]types.ParameterInfo{param};

    const method = types.MethodSymbol{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &params,
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Controller",
        .file_path = "test.php",
    };

    resolver.current_method = &method;

    // Parse PHP with $service variable
    const source = "<?php $service->doWork();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const var_node = findNodeByKind(root, "variable_name") orelse return error.NodeNotFound;
    const text = getNodeText(source, var_node);
    try std.testing.expectEqualStrings("$service", text);

    const type_info = try resolver.resolveExpressionType(var_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\UserService", type_info.?.base_type);
}

test "method return type chain" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();
    file_ctx.namespace = "App";

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Set up class with a method that has a return type
    var class = types.ClassSymbol.init(allocator, "App\\Repository");
    try class.addMethod(.{
        .name = "findAll",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .simple,
            .base_type = "App\\Collection",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Repository",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    // Push a scope and set $repo type
    const scope = try resolver.pushScope();
    try scope.setVariableType("$repo", TypeInfo{
        .kind = .simple,
        .base_type = "App\\Repository",
        .type_parts = &.{},
        .is_builtin = false,
    });

    const source = "<?php $repo->findAll();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const call_node = findNodeByKind(root, "member_call_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(call_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Collection", type_info.?.base_type);
}

test "static call Foo::bar()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    var sym_table = SymbolTable.init(allocator);
    var file_ctx = types.FileContext.init(allocator, "test.php");
    file_ctx.namespace = "App";
    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);

    // Set up class with static method
    var class = types.ClassSymbol.init(allocator, "App\\Factory");
    try class.addMethod(.{
        .name = "create",
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .simple,
            .base_type = "App\\Product",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Factory",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    const source = "<?php Factory::create();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const call_node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(call_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Product", type_info.?.base_type);
}

test "self:: static:: parent:: references" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Set up parent class with method
    var parent_class = types.ClassSymbol.init(allocator, "App\\BaseService");
    try parent_class.addMethod(.{
        .name = "baseMethod",
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .simple,
            .base_type = "App\\Result",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\BaseService",
        .file_path = "test.php",
    });
    try sym_table.addClass(parent_class);

    // Set up current class with method, extending parent
    var class = types.ClassSymbol.init(allocator, "App\\UserService");
    class.extends = "App\\BaseService";
    try class.addMethod(.{
        .name = "getData",
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .simple,
            .base_type = "App\\Data",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\UserService",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    resolver.current_class = sym_table.getClass("App\\UserService");

    // Test self::getData()
    {
        const source = "<?php self::getData();";
        const tree = testParse(source) orelse return error.ParseFailed;
        defer tree.destroy();
        const root = tree.rootNode();
        const node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;
        const type_info = try resolver.resolveExpressionType(node, source);
        try std.testing.expect(type_info != null);
        try std.testing.expectEqualStrings("App\\Data", type_info.?.base_type);
    }

    // Test static::getData()
    {
        const source = "<?php static::getData();";
        const tree = testParse(source) orelse return error.ParseFailed;
        defer tree.destroy();
        const root = tree.rootNode();
        const node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;
        const type_info = try resolver.resolveExpressionType(node, source);
        try std.testing.expect(type_info != null);
        try std.testing.expectEqualStrings("App\\Data", type_info.?.base_type);
    }

    // Test parent::baseMethod()
    {
        const source = "<?php parent::baseMethod();";
        const tree = testParse(source) orelse return error.ParseFailed;
        defer tree.destroy();
        const root = tree.rootNode();
        const node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;
        const type_info = try resolver.resolveExpressionType(node, source);
        try std.testing.expect(type_info != null);
        try std.testing.expectEqualStrings("App\\Result", type_info.?.base_type);
    }
}

test "property access type" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();
    file_ctx.namespace = "App";

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Set up class with a typed property
    var class = types.ClassSymbol.init(allocator, "App\\User");
    try class.addProperty(.{
        .name = "email",
        .visibility = .public,
        .is_static = false,
        .is_readonly = false,
        .declared_type = TypeInfo{
            .kind = .simple,
            .base_type = "string",
            .type_parts = &.{},
            .is_builtin = true,
        },
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 5,
    });
    try sym_table.addClass(class);

    // Push a scope with $user typed
    const scope = try resolver.pushScope();
    try scope.setVariableType("$user", TypeInfo{
        .kind = .simple,
        .base_type = "App\\User",
        .type_parts = &.{},
        .is_builtin = false,
    });

    const source = "<?php $user->email;";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const access_node = findNodeByKind(root, "member_access_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(access_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("string", type_info.?.base_type);
    try std.testing.expect(type_info.?.is_builtin);
}

test "scope push/pop with nested closures" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Push outer scope
    const outer = try resolver.pushScope();
    try outer.setVariableType("$outer_var", TypeInfo{
        .kind = .simple,
        .base_type = "string",
        .type_parts = &.{},
        .is_builtin = true,
    });

    // Push inner scope (nested closure)
    const inner = try resolver.pushScope();
    try inner.setVariableType("$inner_var", TypeInfo{
        .kind = .simple,
        .base_type = "int",
        .type_parts = &.{},
        .is_builtin = true,
    });

    // Inner scope should see both variables (parent chain)
    const current = resolver.currentScope() orelse return error.NoScope;
    try std.testing.expect(current.getVariableType("$inner_var") != null);
    try std.testing.expectEqualStrings("int", current.getVariableType("$inner_var").?.base_type);
    try std.testing.expect(current.getVariableType("$outer_var") != null);
    try std.testing.expectEqualStrings("string", current.getVariableType("$outer_var").?.base_type);

    // Pop inner scope
    resolver.popScope();

    // Outer scope should only see outer variable
    const outer_current = resolver.currentScope() orelse return error.NoScope;
    try std.testing.expect(outer_current.getVariableType("$outer_var") != null);
    try std.testing.expect(outer_current.getVariableType("$inner_var") == null);
}

test "unresolvable variable returns null" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Push empty scope, no class context, no method context
    _ = try resolver.pushScope();

    const source = "<?php $unknown;";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const var_node = findNodeByKind(root, "variable_name") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(var_node, source);
    try std.testing.expect(type_info == null);
}

test "method returning self concretizes to containing class" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Class with a method returning self
    var class = types.ClassSymbol.init(allocator, "App\\Builder");
    try class.addMethod(.{
        .name = "build",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .self_type,
            .base_type = "self",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Builder",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    // Set up $builder variable
    const scope = try resolver.pushScope();
    try scope.setVariableType("$builder", TypeInfo{
        .kind = .simple,
        .base_type = "App\\Builder",
        .type_parts = &.{},
        .is_builtin = false,
    });

    const source = "<?php $builder->build();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const call_node = findNodeByKind(root, "member_call_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(call_node, source);
    try std.testing.expect(type_info != null);
    // Should be concretized to App\Builder, not "self"
    try std.testing.expectEqualStrings("App\\Builder", type_info.?.base_type);
    try std.testing.expectEqual(TypeInfo.Kind.simple, type_info.?.kind);
}

test "static method returning self concretizes to containing class" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Class with a static method returning self
    var class = types.ClassSymbol.init(allocator, "App\\Factory");
    try class.addMethod(.{
        .name = "create",
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .self_type,
            .base_type = "self",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Factory",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    resolver.current_class = sym_table.getClass("App\\Factory");

    const source = "<?php self::create();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;
    const type_info = try resolver.resolveExpressionType(node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Factory", type_info.?.base_type);
    try std.testing.expectEqual(TypeInfo.Kind.simple, type_info.?.kind);
}

test "method returning parent concretizes to parent class" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Parent class
    const parent_class = types.ClassSymbol.init(allocator, "App\\Base");
    try sym_table.addClass(parent_class);

    // Child class with a method returning parent
    var child_class = types.ClassSymbol.init(allocator, "App\\Child");
    child_class.extends = "App\\Base";
    try child_class.addMethod(.{
        .name = "getParent",
        .visibility = .public,
        .is_static = true,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .parent_type,
            .base_type = "parent",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Child",
        .file_path = "test.php",
    });
    try sym_table.addClass(child_class);

    resolver.current_class = sym_table.getClass("App\\Child");

    const source = "<?php self::getParent();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const node = findNodeByKind(root, "scoped_call_expression") orelse return error.NodeNotFound;
    const type_info = try resolver.resolveExpressionType(node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqualStrings("App\\Base", type_info.?.base_type);
    try std.testing.expectEqual(TypeInfo.Kind.simple, type_info.?.kind);
}

test "nullable self return type concretizes" {
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var resolver = TypeResolver.init(allocator, &sym_table, &file_ctx);
    defer resolver.deinit();

    // Class with a method returning ?self
    var class = types.ClassSymbol.init(allocator, "App\\Entity");
    try class.addMethod(.{
        .name = "findOrNull",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = TypeInfo{
            .kind = .nullable,
            .base_type = "self",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Entity",
        .file_path = "test.php",
    });
    try sym_table.addClass(class);

    const scope = try resolver.pushScope();
    try scope.setVariableType("$entity", TypeInfo{
        .kind = .simple,
        .base_type = "App\\Entity",
        .type_parts = &.{},
        .is_builtin = false,
    });

    const source = "<?php $entity->findOrNull();";
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    const root = tree.rootNode();
    const call_node = findNodeByKind(root, "member_call_expression") orelse return error.NodeNotFound;

    const type_info = try resolver.resolveExpressionType(call_node, source);
    try std.testing.expect(type_info != null);
    try std.testing.expectEqual(TypeInfo.Kind.nullable, type_info.?.kind);
    try std.testing.expectEqualStrings("App\\Entity", type_info.?.base_type);
}
