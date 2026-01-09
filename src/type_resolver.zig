const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const phpdoc = @import("phpdoc.zig");

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

        // Variable reference
        if (std.mem.eql(u8, kind, "variable_name")) {
            return self.resolveVariableType(node, source);
        }

        // $this reference
        if (std.mem.eql(u8, kind, "variable_name")) {
            const text = getNodeText(source, node);
            if (std.mem.eql(u8, text, "$this")) {
                return self.resolveThisType();
            }
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
                const fqcn = self.file_context.resolveFQCN(class_name);

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
            return method.effectiveReturnType();
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
            fqcn = self.file_context.resolveFQCN(class_name);
        }

        // Look up method
        if (self.symbol_table.resolveMethod(fqcn, method_name)) |method| {
            return method.effectiveReturnType();
        }

        return null;
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
        _ = source;
        if (!std.mem.eql(u8, method.name, "__construct")) return;

        // Build a map of parameter name -> type
        var param_types = std.StringHashMap(TypeInfo).init(self.allocator);
        defer param_types.deinit();

        for (method.parameters) |param| {
            const type_info = param.type_info orelse param.phpdoc_type orelse continue;
            try param_types.put(param.name, type_info);
        }

        // Traverse constructor body looking for $this->prop = $param patterns
        try self.scanConstructorAssignments(body_node, &param_types);
    }

    fn scanConstructorAssignments(self: *TypeResolver, node: ts.Node, param_types: *std.StringHashMap(TypeInfo)) !void {
        // This would traverse the AST looking for patterns like:
        // $this->repository = $repository;
        // Where $repository is a typed constructor parameter
        _ = self;
        _ = node;
        _ = param_types;
        // Implementation would go here - for now we rely on property type declarations
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
