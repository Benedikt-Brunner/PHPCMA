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

        // Method call $obj->method() (and nullsafe $obj?->method())
        if (std.mem.eql(u8, kind, "member_call_expression") or
            std.mem.eql(u8, kind, "nullsafe_member_call_expression"))
        {
            return self.resolveMethodCallType(node, source);
        }

        // `(<expr>)->m()`: unwrap the parentheses and resolve the inner type.
        if (std.mem.eql(u8, kind, "parenthesized_expression")) {
            if (node.namedChild(0)) |inner| return self.resolveExpressionType(inner, source);
            return null;
        }

        // `clone $x`: the result has the same type as the cloned expression.
        if (std.mem.eql(u8, kind, "clone_expression")) {
            if (node.namedChild(0)) |inner| return self.resolveExpressionType(inner, source);
            return null;
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

        // Resolve via the full DI/interface-aware path so chained calls on
        // interface- or DI-typed receivers (`$repo->find()->getName()`) keep
        // their type across hops, not just concrete-class receivers.
        if (self.resolveMethodCall(object_type, method_name)) |res| {
            const ret = res.method.effectiveReturnType() orelse return null;
            // Generic methods declare template returns (`@return TElement`);
            // substitute the receiver's concrete binding so collection accessors
            // (`$products->first()`) keep navigating to the element type.
            const substituted = try self.substituteTemplateReturn(ret, res.method.containing_class, object_type.base_type);
            // Fluent APIs declare `self`/`static`/`$this` returns; normalize them
            // to the receiver's concrete type so builder chains keep their type
            // across hops (`$x->setA()->setB()` stays typed as `X`).
            return try self.normalizeSelfReturn(substituted, object_type.base_type);
        }

        return null;
    }

    /// If `ret` is (or contains) a template parameter of `declaring_fqcn`, map it
    /// to the concrete type bound by the receiver's generic inheritance and
    /// return the substituted type. Non-template returns pass through unchanged.
    fn substituteTemplateReturn(
        self: *TypeResolver,
        ret: TypeInfo,
        declaring_fqcn: []const u8,
        receiver_fqcn: []const u8,
    ) error{OutOfMemory}!TypeInfo {
        const declaring = self.symbol_table.getClass(declaring_fqcn) orelse return ret;
        if (declaring.template_params.len == 0) return ret;

        switch (ret.kind) {
            .simple, .nullable => {
                const idx = declaring.templateIndexOf(ret.base_type) orelse return ret;
                const concrete = self.resolveTemplateConcrete(receiver_fqcn, declaring_fqcn, idx) orelse return ret;
                return TypeInfo{
                    .kind = ret.kind,
                    .base_type = try self.allocator.dupe(u8, concrete),
                    .type_parts = &.{},
                    .is_builtin = TypeInfo.isBuiltin(concrete),
                };
            },
            .union_type => {
                var has_null = false;
                var concrete: ?[]const u8 = null;
                for (ret.type_parts) |part| {
                    if (std.mem.eql(u8, part, "null")) {
                        has_null = true;
                        continue;
                    }
                    if (declaring.templateIndexOf(part)) |idx| {
                        if (self.resolveTemplateConcrete(receiver_fqcn, declaring_fqcn, idx)) |c| {
                            concrete = c;
                        }
                    }
                }
                const c = concrete orelse return ret;
                return TypeInfo{
                    .kind = if (has_null) .nullable else .simple,
                    .base_type = try self.allocator.dupe(u8, c),
                    .type_parts = &.{},
                    .is_builtin = TypeInfo.isBuiltin(c),
                };
            },
            else => return ret,
        }
    }

    /// Resolve `declaring_fqcn`'s template parameter at `var_index` to a concrete
    /// FQCN, given a `receiver_fqcn` that (transitively) extends it. Walks the
    /// `@extends Base<...>` bindings from the declaring class back down to the
    /// receiver, following template parameters through each level and falling
    /// back to a parameter's declared default when no subclass binds it.
    fn resolveTemplateConcrete(
        self: *TypeResolver,
        receiver_fqcn: []const u8,
        declaring_fqcn: []const u8,
        var_index: usize,
    ) ?[]const u8 {
        var chain: [33][]const u8 = undefined;
        var len: usize = 0;
        var cur = receiver_fqcn;
        while (true) {
            if (len >= chain.len) return null;
            chain[len] = cur;
            len += 1;
            if (std.mem.eql(u8, cur, declaring_fqcn)) break;
            const c = self.symbol_table.getClass(cur) orelse return null;
            cur = c.extends orelse return null;
        }

        // Walk from the declaring class (chain[len-1]) down toward the receiver
        // (chain[0]), translating the template index at each inheritance hop.
        var idx = var_index;
        var i: usize = len - 1;
        while (i > 0) : (i -= 1) {
            const child = self.symbol_table.getClass(chain[i - 1]) orelse return null;
            if (idx >= child.extends_type_args.len) {
                const cls = self.symbol_table.getClass(chain[i]) orelse return null;
                if (idx < cls.template_params.len) return cls.template_params[idx].fallback;
                return null;
            }
            const arg = child.extends_type_args[idx];
            if (child.templateIndexOf(arg)) |j| {
                idx = j;
                continue;
            }
            return arg;
        }

        // Reached the receiver and the parameter is still symbolic: use its
        // declared default/bound (e.g. `@template TElement of Foo = Foo`).
        const recv = self.symbol_table.getClass(chain[0]) orelse return null;
        if (idx < recv.template_params.len) return recv.template_params[idx].fallback;
        return null;
    }

    /// Map a `self`/`static`/`$this` return type to `receiver_fqcn` (the concrete
    /// type the method was called on). Any other return type is passed through.
    fn normalizeSelfReturn(self: *TypeResolver, ret: TypeInfo, receiver_fqcn: []const u8) error{OutOfMemory}!TypeInfo {
        const is_self_ref = switch (ret.kind) {
            .self_type, .static_type => true,
            .simple => std.mem.eql(u8, ret.base_type, "self") or
                std.mem.eql(u8, ret.base_type, "static") or
                std.mem.eql(u8, ret.base_type, "$this"),
            else => false,
        };
        if (!is_self_ref) return ret;
        return TypeInfo{
            .kind = .simple,
            .base_type = try self.allocator.dupe(u8, receiver_fqcn),
            .type_parts = &.{},
            .is_builtin = false,
        };
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
            const ret = method.effectiveReturnType() orelse return null;
            // `Foo::make(): static` (named-constructor pattern) normalizes to Foo.
            return try self.normalizeSelfReturn(ret, fqcn);
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
            // A preceding inline `/** @var T $var */` is hand-written ground truth
            // — devs add it precisely where inference fails — so it wins over the
            // RHS type when present.
            if (try self.inlineVarTypeFor(node, var_name, source)) |type_info| {
                if (self.currentScope()) |scope| {
                    try scope.setVariableType(var_name, type_info);
                }
            } else if (try self.resolveExpressionType(rhs, source)) |type_info| {
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

    /// If the statement containing `assign_node` is immediately preceded by an
    /// inline `/** @var T $var */` whose target is `var_name` (or unnamed),
    /// return the FQCN-normalized type `T`. The annotation is read from the
    /// current file's context, so relative names resolve correctly.
    fn inlineVarTypeFor(self: *TypeResolver, assign_node: ts.Node, var_name: []const u8, source: []const u8) error{OutOfMemory}!?TypeInfo {
        const stmt = assign_node.parent() orelse return null; // expression_statement
        const prev = stmt.prevNamedSibling() orelse return null;
        if (!std.mem.eql(u8, prev.kind(), "comment")) return null;

        const comment = getNodeText(source, prev);
        const named = (try phpdoc.parseInlineVarNamed(self.allocator, comment)) orelse return null;

        // If the annotation names a variable, it must match the assignment LHS.
        if (named.var_name) |n| {
            const bare = if (var_name.len > 0 and var_name[0] == '$') var_name[1..] else var_name;
            if (!std.mem.eql(u8, n, bare)) return null;
        }

        return try self.normalizeDocType(named.type_info);
    }

    /// Resolve a class-like docblock type's `base_type` to its FQCN using the
    /// current file's namespace + imports (incl. `Foo[]`/`Collection<Foo>`
    /// element types). Builtins and special types pass through unchanged.
    fn normalizeDocType(self: *TypeResolver, info: TypeInfo) error{OutOfMemory}!TypeInfo {
        return phpdoc.resolveTypeFqcn(self.allocator, self.file_context, info);
    }

    // ========================================================================
    // foreach loop-variable typing
    // ========================================================================

    /// Resolve the element type bound to a foreach value variable, given the
    /// `foreach (<iter> as ...)` iterable expression node. Returns null unless
    /// the iterable resolves to a collection with a known element type.
    pub fn foreachElementType(self: *TypeResolver, iter_node: ts.Node, source: []const u8) error{OutOfMemory}!?TypeInfo {
        const iter_type = (try self.resolveExpressionType(iter_node, source)) orelse return null;
        return self.elementType(iter_type);
    }

    /// Element type of a collection-shaped type. `Foo[]`/`array<Foo>`/
    /// `iterable<Foo>`/`Collection<Foo>` are normalized to `array_type` at
    /// collection time (base_type = element FQCN), so the array case carries the
    /// answer directly. Bare `array`/`iterable` (no element) yield null.
    fn elementType(self: *TypeResolver, t: TypeInfo) ?TypeInfo {
        _ = self;
        if (t.kind != .array_type) return null;
        if (TypeInfo.isBuiltin(t.base_type)) return null; // bare array/iterable
        if (std.mem.indexOfScalar(u8, t.base_type, '<') != null) return null; // unresolved generic
        return TypeInfo{
            .kind = .simple,
            .base_type = t.base_type,
            .type_parts = &.{},
            .is_builtin = false,
        };
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

    /// How an interface-typed call was bound to a concrete method, so the caller
    /// can set confidence and tag the edge accordingly.
    pub const BindingKind = enum {
        /// Direct resolution against the declared (concrete) type.
        direct,
        /// DI config (services.yaml) interface -> concrete binding (Phase B).
        di_config,
        /// Sole in-project implementor of the interface (Phase A).
        single_impl,
        /// The declared type is an interface and the call resolved to its own
        /// (abstract) method declaration. The concrete runtime implementor is
        /// unknown (multiple, or none, in-project), but the contract is real.
        interface_contract,
    };

    /// Outcome of resolving a method call: the target method plus how it was
    /// bound (for confidence + edge tagging).
    pub const MethodResolution = struct {
        method: *const MethodSymbol,
        binding: BindingKind,
    };

    /// Resolve a method call to its target FQCN
    pub fn resolveMethodCall(
        self: *TypeResolver,
        object_type: ?TypeInfo,
        method_name: []const u8,
    ) ?MethodResolution {
        const type_info = object_type orelse return null;

        // Handle special types
        if (type_info.kind == .self_type or type_info.kind == .static_type) {
            if (self.current_class) |class| {
                return self.wrap(self.symbol_table.resolveMethod(class.fqcn, method_name), .direct);
            }
            return null;
        }

        if (type_info.kind == .parent_type) {
            if (self.current_class) |class| {
                if (class.extends) |parent| {
                    return self.wrap(self.symbol_table.resolveMethod(parent, method_name), .direct);
                }
            }
            return null;
        }

        // Direct resolution against the declared type (class or interface).
        if (self.symbol_table.resolveMethod(type_info.base_type, method_name)) |m| {
            return self.wrap(m, .direct);
        }

        // DI-aware (Phase B): the declared type is an interface explicitly bound
        // to a concrete in DI config (services.yaml). Authoritative even when
        // several implementors exist, so it takes precedence over the
        // single-implementor heuristic below.
        if (self.symbol_table.explicitBinding(type_info.base_type)) |concrete| {
            if (self.symbol_table.resolveMethod(concrete, method_name)) |m| {
                return self.wrap(m, .di_config);
            }
        }

        // DI-aware (Phase A): the declared type is an interface (no class match)
        // with exactly one in-project implementor — resolve to its method.
        if (self.symbol_table.singleImplementor(type_info.base_type)) |impl| {
            if (self.symbol_table.resolveMethod(impl, method_name)) |m| {
                return self.wrap(m, .single_impl);
            }
        }

        // Contract fallback: the declared type is an interface with several (or
        // zero) in-project implementors and no DI binding. The concrete runtime
        // target is unknown, but the method is declared on the interface (or a
        // parent interface), so resolve to that abstract declaration — a real,
        // navigable edge to the contract.
        if (self.symbol_table.resolveInterfaceMethod(type_info.base_type, method_name)) |m| {
            return self.wrap(m, .interface_contract);
        }

        return null;
    }

    fn wrap(self: *TypeResolver, method: ?*const MethodSymbol, binding: BindingKind) ?MethodResolution {
        _ = self;
        return .{ .method = method orelse return null, .binding = binding };
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
