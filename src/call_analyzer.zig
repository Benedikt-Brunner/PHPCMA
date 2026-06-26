const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const type_resolver = @import("type_resolver.zig");
const phpdoc = @import("phpdoc.zig");

const TypeInfo = types.TypeInfo;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const FileContext = types.FileContext;
const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ResolutionMethod = types.ResolutionMethod;
const UnresolvedReason = types.UnresolvedReason;
const SymbolTable = symbol_table.SymbolTable;
const TypeResolver = type_resolver.TypeResolver;

// ============================================================================
// Call Analyzer - Enhanced call graph building with type resolution
// ============================================================================

pub const CallAnalyzer = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    type_resolver: TypeResolver,

    // Collected calls
    calls: std.ArrayListUnmanaged(EnhancedFunctionCall),

    // Current context
    current_file: []const u8,
    current_class: ?[]const u8,
    current_method: ?[]const u8,

    // When set (env PHPCMA_DIAG), record a fine-grained `unresolved_detail`
    // sub-reason per unresolved instance call. Off by default to avoid the
    // per-call AST walk on normal loads.
    diag_enabled: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
    ) CallAnalyzer {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .type_resolver = TypeResolver.init(allocator, sym_table, file_ctx),
            .calls = .empty,
            .current_file = "",
            .current_class = null,
            .current_method = null,
            .diag_enabled = std.c.getenv("PHPCMA_DIAG") != null,
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
        const kind = node.kind();

        // Track class context
        if (std.mem.eql(u8, kind, "class_declaration")) {
            try self.enterClass(node, source);
            return;
        }

        // Track method context
        if (std.mem.eql(u8, kind, "method_declaration")) {
            try self.enterMethod(node, source);
            return;
        }

        // Track function context
        if (std.mem.eql(u8, kind, "function_definition")) {
            try self.enterFunction(node, source);
            return;
        }

        // Analyze calls
        if (std.mem.eql(u8, kind, "member_call_expression")) {
            try self.analyzeMemberCall(node, source);
        } else if (std.mem.eql(u8, kind, "scoped_call_expression")) {
            try self.analyzeStaticCall(node, source);
        } else if (std.mem.eql(u8, kind, "function_call_expression")) {
            try self.analyzeFunctionCall(node, source);
        }

        // Track assignments for type inference
        if (std.mem.eql(u8, kind, "assignment_expression")) {
            try self.type_resolver.trackAssignment(node, source);
        }

        // foreach binds its loop variable to the iterable's element type in a
        // pushed scope; handle it explicitly (and skip default recursion).
        if (std.mem.eql(u8, kind, "foreach_statement")) {
            try self.enterForeach(node, source);
            return;
        }

        // catch (FooException $e) binds `$e` to the caught type in a pushed
        // scope so `$e->...()` calls resolve (or attribute to the real type).
        if (std.mem.eql(u8, kind, "catch_clause")) {
            try self.enterCatch(node, source);
            return;
        }

        // Closures get their own scope: typed params are bound, and `use`
        // captures (plus outer locals) resolve via the parent scope chain.
        if (std.mem.eql(u8, kind, "anonymous_function") or
            std.mem.eql(u8, kind, "arrow_function"))
        {
            try self.enterClosure(node, source);
            return;
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
            const fqcn = self.type_resolver.file_context.resolveFQCN(class_name);
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
        if (node.childByFieldName("name")) |name_node| {
            const func_name = getNodeText(source, name_node);
            self.current_method = func_name;
        }

        // Push new scope
        _ = try self.type_resolver.pushScope();

        // Process function body
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        // Pop scope
        self.type_resolver.popScope();
        self.current_method = null;
    }

    /// Handle `foreach (<iter> as [$k =>] $v)`: bind `$v` to the iterable's
    /// element type in a pushed scope, then analyze the body so calls on the
    /// loop variable resolve. Falls back to an untyped binding when the element
    /// type is unknown (so inner traversal still happens).
    fn enterForeach(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const iter_node = node.namedChild(0);

        // Analyze the iterable expression itself first (it may contain calls,
        // e.g. `foreach ($this->repo->findAll() as $x)`).
        if (iter_node) |it| try self.traverseNode(it, source);

        // Resolve the element type from the iterable, if possible.
        const elem_type: ?TypeInfo = if (iter_node) |it|
            try self.type_resolver.foreachElementType(it, source)
        else
            null;

        const scope = try self.type_resolver.pushScope();

        // Bind the value variable (namedChild(1) is the value, a `pair` for
        // `$k => $v`, or a `by_ref` wrapper). Destructuring (list_literal) is
        // skipped.
        if (elem_type) |et| {
            if (foreachValueVar(node)) |value_node| {
                const var_name = getNodeText(source, value_node);
                try scope.setVariableType(var_name, et);
            }
        }

        // Analyze the loop body within the pushed scope.
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        self.type_resolver.popScope();
    }

    /// Handle `catch (T $e) { ... }`: bind `$e` to the caught type in a pushed
    /// scope, then analyze the body. Only single (non-union) catch types are
    /// bound — a `A|B` catch leaves the receiver ambiguous, so we skip it.
    fn enterCatch(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const scope = try self.type_resolver.pushScope();

        if (node.childByFieldName("name")) |name_node| {
            if (node.childByFieldName("type")) |type_list| {
                if (type_list.namedChildCount() == 1) {
                    if (type_list.namedChild(0)) |type_node| {
                        const fqcn = self.type_resolver.file_context.resolveFQCN(getNodeText(source, type_node));
                        const type_info = try TypeInfo.simple(self.allocator, fqcn);
                        const var_name = getNodeText(source, name_node);
                        try scope.setVariableType(var_name, type_info);
                    }
                }
            }
        }

        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        self.type_resolver.popScope();
    }

    /// Handle a closure (`function (...) use (...) {}` or `fn (...) => ...`):
    /// push a scope whose parent is the current one (so `use` captures and
    /// outer locals still resolve), bind the closure's own typed parameters,
    /// then analyze the body.
    fn enterClosure(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const scope = try self.type_resolver.pushScope();

        if (node.childByFieldName("parameters")) |params| {
            var i: u32 = 0;
            while (i < params.namedChildCount()) : (i += 1) {
                const param = params.namedChild(i) orelse continue;
                const pk = param.kind();
                if (!std.mem.eql(u8, pk, "simple_parameter") and
                    !std.mem.eql(u8, pk, "variadic_parameter")) continue;
                const type_node = param.childByFieldName("type") orelse continue;
                const name_node = param.childByFieldName("name") orelse continue;
                const type_info = (try self.typeInfoFromTypeNode(type_node, source)) orelse continue;
                try scope.setVariableType(getNodeText(source, name_node), type_info);
            }
        }

        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body, source);
        }

        self.type_resolver.popScope();
    }

    /// Build an FQCN-resolved `TypeInfo` from a declared-type node (the `type`
    /// field of a parameter), mirroring the symbol collector so closure-param
    /// types match symbol-table keys.
    fn typeInfoFromTypeNode(self: *CallAnalyzer, type_node: ts.Node, source: []const u8) !?TypeInfo {
        const text = getNodeText(source, type_node);
        if (text.len == 0) return null;
        var info = try phpdoc.parseTypeString(self.allocator, text);
        if ((info.kind == .simple or info.kind == .nullable) and !info.is_builtin) {
            const resolved = self.type_resolver.file_context.resolveFQCN(info.base_type);
            info.base_type = try self.allocator.dupe(u8, resolved);
        }
        return info;
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
            .arg_count = countCallArgs(node),
            .arg_types = try resolveCallArgTypes(self, node, source),
            .result_used = detectResultUse(node),
            .resolved_target = null,
            .resolution_confidence = 0.0,
            .resolution_method = .unresolved,
        };

        // Try to resolve target
        if (object_type) |obj_type| {
            if (self.type_resolver.resolveMethodCall(obj_type, method_name)) |res| {
                const method = res.method;
                call.resolved_target = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}::{s}",
                    .{ method.containing_class, method.name },
                );
                switch (res.binding) {
                    .di_config => {
                        // DI-bound via an explicit services.yaml mapping: not a
                        // concrete type match but config-authoritative, so high
                        // (but sub-1.0) confidence and a distinct tag.
                        call.resolution_confidence = 0.85;
                        call.resolution_method = .di_config_binding;
                    },
                    .single_impl => {
                        // DI-bound via a single-implementor interface: real but
                        // inferred, so flag it distinctly with reduced confidence.
                        call.resolution_confidence = 0.6;
                        call.resolution_method = .interface_single_impl;
                    },
                    .interface_contract => {
                        // Resolved to the interface's own abstract method. The
                        // concrete runtime implementor is unknown (several or
                        // none), so lower confidence than a single-implementor
                        // bind, but the contract edge is real and navigable.
                        call.resolution_confidence = 0.5;
                        call.resolution_method = .interface_contract;
                    },
                    .direct => {
                        call.resolution_confidence = self.calculateConfidence(obj_type);
                        call.resolution_method = self.determineResolutionMethod(object_node, source);
                    },
                }
            } else if (self.symbol_table.typeExists(obj_type.base_type)) {
                // Receiver type is in-project but no method bound. Split the
                // ones that extend/use an external base or trait (method likely
                // inherited from non-indexed core — not fixable here) from the
                // pure in-project misses (a genuine inheritance/trait/magic gap).
                call.receiver_type = try self.allocator.dupe(u8, obj_type.base_type);
                call.unresolved_reason = if (self.hasExternalAncestor(obj_type.base_type))
                    .method_not_found_external_ancestor
                else
                    .method_not_found_pure;
            } else {
                // Receiver type resolved to an external/vendor type (out of
                // scope without indexing it). Record the FQCN so downstream
                // metrics can attribute the call to the concrete external class.
                call.unresolved_reason = .recv_type_external;
                call.receiver_type = try self.allocator.dupe(u8, obj_type.base_type);
            }
        } else {
            // Receiver type could not be inferred at all: bucket by the receiver
            // expression shape so the dominant fixable pattern is visible.
            call.unresolved_reason = self.classifyNullReceiver(object_node, source);
            if (call.unresolved_reason == .recv_local) {
                call.receiver_type = try self.allocator.dupe(u8, getNodeText(source, object_node));
            }
            if (self.diag_enabled) {
                call.unresolved_detail = switch (call.unresolved_reason) {
                    .recv_local => self.localRhsDetail(object_node, source),
                    .recv_chain => self.chainDetail(object_node, source),
                    else => null,
                };
            }
        }

        try self.calls.append(self.allocator, call);
    }

    /// Diagnostic: for a `recv_local` receiver `$v`, find the assignment that
    /// fed it within the enclosing function and report the RHS node kind, so we
    /// can see why tracking failed (chain root, alias, external `new`, or no
    /// local assignment at all — i.e. closure `use`/by-ref/global). Returns a
    /// static label; never allocates.
    fn localRhsDetail(self: *CallAnalyzer, object_node: ts.Node, source: []const u8) ?[]const u8 {
        _ = self;
        const var_name = getNodeText(source, object_node);
        const fn_body = enclosingBody(object_node) orelse return "no_enclosing_fn";
        const call_byte = object_node.startByte();

        var best: ?ts.Node = null;
        var best_byte: u32 = 0;
        findLatestAssignment(fn_body, source, var_name, call_byte, &best, &best_byte);

        const rhs = (best orelse return "no_local_assign").childByFieldName("right") orelse return "no_local_assign";
        return rhsKindLabel(rhs.kind());
    }

    /// Diagnostic: for a `recv_chain` receiver `$a->b()`, report the shape of
    /// the *inner* receiver `$a`, so we know where chains bottom out (a local,
    /// a property, `$this`, another chain, etc.). Static label; no allocation.
    fn chainDetail(self: *CallAnalyzer, object_node: ts.Node, source: []const u8) ?[]const u8 {
        _ = self;
        const inner = object_node.childByFieldName("object") orelse return "chain:unknown";
        const k = inner.kind();
        if (std.mem.eql(u8, k, "variable_name")) {
            const t = getNodeText(source, inner);
            return if (std.mem.eql(u8, t, "$this")) "chain:this" else "chain:var";
        }
        if (std.mem.eql(u8, k, "member_access_expression")) return "chain:property";
        if (std.mem.eql(u8, k, "member_call_expression") or
            std.mem.eql(u8, k, "nullsafe_member_call_expression")) return "chain:member_call";
        if (std.mem.eql(u8, k, "scoped_call_expression")) return "chain:static_call";
        if (std.mem.eql(u8, k, "function_call_expression")) return "chain:func_call";
        if (std.mem.eql(u8, k, "subscript_expression")) return "chain:subscript";
        return "chain:other";
    }

    /// Classify an unresolved call whose receiver type could not be inferred,
    /// by the receiver's syntactic shape. A bare `$var` is split into an
    /// untyped parameter of the current method (needs a type hint upstream) vs.
    /// a local the resolver failed to track (an assignment-coverage gap).
    fn classifyNullReceiver(self: *CallAnalyzer, object_node: ts.Node, source: []const u8) UnresolvedReason {
        const k = object_node.kind();
        if (std.mem.eql(u8, k, "variable_name")) {
            const var_text = getNodeText(source, object_node);
            const name = if (var_text.len > 0 and var_text[0] == '$') var_text[1..] else var_text;
            if (self.type_resolver.current_method) |m| {
                for (m.parameters) |p| {
                    if (std.mem.eql(u8, p.name, name)) return .recv_param_untyped;
                }
            }
            return .recv_local;
        }
        if (std.mem.eql(u8, k, "member_access_expression")) return .recv_property;
        if (std.mem.eql(u8, k, "member_call_expression")) return .recv_chain;
        if (std.mem.eql(u8, k, "nullsafe_member_call_expression")) return .recv_chain;
        if (std.mem.eql(u8, k, "scoped_call_expression")) return .recv_static_chain;
        if (std.mem.eql(u8, k, "function_call_expression")) return .recv_func_chain;
        if (std.mem.eql(u8, k, "subscript_expression")) return .recv_subscript;
        return .recv_other;
    }

    /// True if `fqcn` extends a class or uses a trait that is not in-project
    /// (i.e. vendor/core), so a missing method is plausibly inherited from
    /// non-indexed code rather than being a resolver defect.
    fn hasExternalAncestor(self: *CallAnalyzer, fqcn: []const u8) bool {
        if (self.symbol_table.resolved) |view| {
            if (view.getClass(fqcn)) |rc| {
                for (rc.parent_chain) |anc| {
                    if (!self.symbol_table.typeExists(anc)) return true;
                }
            }
        }
        if (self.symbol_table.classes.getPtr(fqcn)) |class| {
            for (class.uses) |trait_fqcn| {
                if (!self.symbol_table.traits.contains(trait_fqcn)) return true;
            }
        }
        return false;
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
            fqcn = self.type_resolver.file_context.resolveFQCN(class_name);
        }

        var call = EnhancedFunctionCall{
            .caller_fqn = self.buildCallerFQN(),
            .callee_name = try self.allocator.dupe(u8, method_name),
            .call_type = .static_method,
            .line = node.startPoint().row + 1,
            .column = node.startPoint().column + 1,
            .file_path = self.current_file,
            .arg_count = countCallArgs(node),
            .arg_types = try resolveCallArgTypes(self, node, source),
            .result_used = detectResultUse(node),
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

        try self.calls.append(self.allocator, call);
    }

    /// Analyze function_name() call
    fn analyzeFunctionCall(self: *CallAnalyzer, node: ts.Node, source: []const u8) !void {
        const func_node = node.childByFieldName("function") orelse return;

        const func_kind = func_node.kind();
        if (!std.mem.eql(u8, func_kind, "name") and !std.mem.eql(u8, func_kind, "qualified_name")) {
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
            .arg_count = countCallArgs(node),
            .arg_types = try resolveCallArgTypes(self, node, source),
            .result_used = detectResultUse(node),
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

        try self.calls.append(self.allocator, call);
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
    pub fn toDot(self: *const ProjectCallGraph, file: std.Io.File) !void {
        try file.writeStreamingAll(types.io, "digraph CallGraph {\n");
        try file.writeStreamingAll(types.io, "    rankdir=LR;\n");
        try file.writeStreamingAll(types.io, "    node [shape=box, fontname=\"Helvetica\"];\n");
        try file.writeStreamingAll(types.io, "    edge [fontname=\"Helvetica\", fontsize=10];\n\n");

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
        try file.writeStreamingAll(types.io, "    // Callers\n");
        var caller_it = callers.keyIterator();
        while (caller_it.next()) |caller| {
            const escaped = try escapeForDot(self.allocator, caller.*);
            defer self.allocator.free(escaped);
            const msg = try std.fmt.allocPrint(self.allocator, "    \"{s}\" [style=filled, fillcolor=\"#e1f5fe\"];\n", .{escaped});
            defer self.allocator.free(msg);
            try file.writeStreamingAll(types.io, msg);
        }

        // Output callee nodes
        try file.writeStreamingAll(types.io, "\n    // Callees\n");
        var callee_it = callees.keyIterator();
        while (callee_it.next()) |callee| {
            if (!callers.contains(callee.*)) {
                const escaped = try escapeForDot(self.allocator, callee.*);
                defer self.allocator.free(escaped);
                const msg = try std.fmt.allocPrint(self.allocator, "    \"{s}\" [style=filled, fillcolor=\"#fff3e0\"];\n", .{escaped});
                defer self.allocator.free(msg);
                try file.writeStreamingAll(types.io, msg);
            }
        }

        // Output edges
        try file.writeStreamingAll(types.io, "\n    // Calls\n");
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

                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "    \"{s}\" -> \"{s}\" [color={s}];\n",
                    .{ caller_escaped, target_escaped, color },
                );
                defer self.allocator.free(msg);
                try file.writeStreamingAll(types.io, msg);
            }
        }

        try file.writeStreamingAll(types.io, "}\n");
    }

    /// Output as text summary
    pub fn toText(self: *const ProjectCallGraph, file: std.Io.File) !void {
        // Header
        const header = try std.fmt.allocPrint(self.allocator,
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
        defer self.allocator.free(header);
        try file.writeStreamingAll(types.io, header);

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
            const caller_msg = try std.fmt.allocPrint(self.allocator, "{s}:\n", .{caller});
            defer self.allocator.free(caller_msg);
            try file.writeStreamingAll(types.io, caller_msg);

            if (by_caller.get(caller)) |calls| {
                for (calls.items) |call| {
                    const target = call.resolved_target orelse call.callee_name;
                    const confidence_str = if (call.resolved_target != null)
                        try std.fmt.allocPrint(self.allocator, " [{d:.0}%]", .{call.resolution_confidence * 100})
                    else
                        try self.allocator.dupe(u8, " [?]");
                    defer self.allocator.free(confidence_str);

                    const call_msg = try std.fmt.allocPrint(
                        self.allocator,
                        "  -> {s}{s} (line {d})\n",
                        .{ target, confidence_str, call.line },
                    );
                    defer self.allocator.free(call_msg);
                    try file.writeStreamingAll(types.io, call_msg);
                }
            }
            try file.writeStreamingAll(types.io, "\n");
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Count the arguments passed at a call expression node by inspecting its
/// "arguments" child and counting `argument` nodes (ignoring punctuation and
/// comments). Returns 0 when no arguments node is present.
fn countCallArgs(node: ts.Node) u32 {
    const args_node = node.childByFieldName("arguments") orelse return 0;
    var count: u32 = 0;
    var i: u32 = 0;
    const n = args_node.namedChildCount();
    while (i < n) : (i += 1) {
        const child = args_node.namedChild(i) orelse continue;
        if (std.mem.eql(u8, child.kind(), "argument")) count += 1;
    }
    return count;
}

/// The value expression of an `argument` node (skipping the optional `name:`
/// label and `reference_modifier`, which always precede the value). Returns null
/// for spread (`...$x`) and placeholder (first-class callable `...`) args, whose
/// positional type can't be attributed.
fn argumentValueNode(arg: ts.Node) ?ts.Node {
    const cnt = arg.namedChildCount();
    if (cnt == 0) return null;
    const c = arg.namedChild(cnt - 1) orelse return null;
    const k = c.kind();
    if (std.mem.eql(u8, k, "variadic_unpacking") or std.mem.eql(u8, k, "argument_placeholder")) return null;
    return c;
}

/// Resolve the type of each positional argument at a call site, in source order.
/// Mirrors `countCallArgs` iteration; each element is null where the argument's
/// type could not be resolved (the same partiality as receiver resolution).
fn resolveCallArgTypes(self: *CallAnalyzer, node: ts.Node, source: []const u8) ![]const ?TypeInfo {
    const args_node = node.childByFieldName("arguments") orelse return &.{};
    var list: std.ArrayListUnmanaged(?TypeInfo) = .empty;
    var i: u32 = 0;
    const n = args_node.namedChildCount();
    while (i < n) : (i += 1) {
        const child = args_node.namedChild(i) orelse continue;
        if (!std.mem.eql(u8, child.kind(), "argument")) continue;
        const expr = argumentValueNode(child) orelse {
            try list.append(self.allocator, null);
            continue;
        };
        const t = self.type_resolver.resolveExpressionType(expr, source) catch null;
        try list.append(self.allocator, t);
    }
    return list.toOwnedSlice(self.allocator);
}

/// Classify how a call expression's result is consumed, from its parent node.
/// `member_access` (the result is immediately dereferenced) is the case that
/// makes narrowing a return type to nullable a breaking change.
fn detectResultUse(node: ts.Node) types.EnhancedFunctionCall.ResultUse {
    const parent = node.parent() orelse return .ignored;
    const pk = parent.kind();
    if (std.mem.eql(u8, pk, "member_access_expression") or
        std.mem.eql(u8, pk, "member_call_expression") or
        std.mem.eql(u8, pk, "nullsafe_member_access_expression") or
        std.mem.eql(u8, pk, "nullsafe_member_call_expression") or
        std.mem.eql(u8, pk, "scoped_call_expression") or
        std.mem.eql(u8, pk, "scoped_property_access_expression") or
        std.mem.eql(u8, pk, "class_constant_access_expression") or
        std.mem.eql(u8, pk, "subscript_expression"))
    {
        return .member_access;
    }
    if (std.mem.eql(u8, pk, "assignment_expression")) return .assigned;
    if (std.mem.eql(u8, pk, "argument")) return .passed;
    if (std.mem.eql(u8, pk, "return_statement")) return .passed;
    return .ignored;
}

fn getNodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) {
        return "";
    }
    return source[start..end];
}

/// Nearest enclosing function/method/closure body (`compound_statement`) of a
/// node, by walking parents. Used by recv_local diagnostics to scope the
/// assignment search. Returns null at file scope.
fn enclosingBody(node: ts.Node) ?ts.Node {
    var cur: ?ts.Node = node.parent();
    while (cur) |n| : (cur = n.parent()) {
        const k = n.kind();
        if (std.mem.eql(u8, k, "method_declaration") or
            std.mem.eql(u8, k, "function_definition") or
            std.mem.eql(u8, k, "anonymous_function") or
            std.mem.eql(u8, k, "arrow_function"))
        {
            return n.childByFieldName("body");
        }
    }
    return null;
}

/// DFS `scope` for the latest `$var = ...` assignment that lexically precedes
/// `before_byte`, recording the winning `assignment_expression` node into
/// `best`. "Latest before the call" approximates the value live at the call.
fn findLatestAssignment(
    scope: ts.Node,
    source: []const u8,
    var_name: []const u8,
    before_byte: u32,
    best: *?ts.Node,
    best_byte: *u32,
) void {
    if (std.mem.eql(u8, scope.kind(), "assignment_expression")) {
        if (scope.childByFieldName("left")) |lhs| {
            if (std.mem.eql(u8, lhs.kind(), "variable_name") and
                std.mem.eql(u8, getNodeText(source, lhs), var_name))
            {
                const b = scope.startByte();
                if (b < before_byte and (best.* == null or b > best_byte.*)) {
                    best.* = scope;
                    best_byte.* = b;
                }
            }
        }
    }
    var i: u32 = 0;
    while (i < scope.namedChildCount()) : (i += 1) {
        if (scope.namedChild(i)) |child| {
            findLatestAssignment(child, source, var_name, before_byte, best, best_byte);
        }
    }
}

/// Map an assignment RHS node kind to a stable diagnostic label.
fn rhsKindLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "member_call_expression") or
        std.mem.eql(u8, kind, "nullsafe_member_call_expression")) return "rhs:member_call";
    if (std.mem.eql(u8, kind, "scoped_call_expression")) return "rhs:static_call";
    if (std.mem.eql(u8, kind, "function_call_expression")) return "rhs:func_call";
    if (std.mem.eql(u8, kind, "object_creation_expression")) return "rhs:new";
    if (std.mem.eql(u8, kind, "variable_name")) return "rhs:var_alias";
    if (std.mem.eql(u8, kind, "member_access_expression")) return "rhs:property";
    if (std.mem.eql(u8, kind, "subscript_expression")) return "rhs:subscript";
    if (std.mem.eql(u8, kind, "conditional_expression")) return "rhs:ternary";
    if (std.mem.eql(u8, kind, "cast_expression")) return "rhs:cast";
    if (std.mem.eql(u8, kind, "parenthesized_expression")) return "rhs:paren";
    if (std.mem.eql(u8, kind, "binary_expression")) return "rhs:binary";
    if (std.mem.eql(u8, kind, "clone_expression")) return "rhs:clone";
    if (std.mem.eql(u8, kind, "match_expression")) return "rhs:match";
    return "rhs:other";
}

/// The value `variable_name` node of a `foreach_statement`. namedChild(0) is the
/// iterable; namedChild(1) is the binding: a bare `variable_name` (`as $v`), a
/// `pair` (`as $k => $v`, value is its 2nd child), or a `by_ref` wrapper
/// (`as &$v`). Returns null for list destructuring (`as [$a, $b]`).
fn foreachValueVar(node: ts.Node) ?ts.Node {
    const bind = node.namedChild(1) orelse return null;
    const k = bind.kind();
    if (std.mem.eql(u8, k, "variable_name")) return bind;
    if (std.mem.eql(u8, k, "by_ref")) {
        const inner = bind.namedChild(0) orelse return null;
        return if (std.mem.eql(u8, inner.kind(), "variable_name")) inner else null;
    }
    if (std.mem.eql(u8, k, "pair")) {
        const v = bind.namedChild(1) orelse return null;
        if (std.mem.eql(u8, v.kind(), "variable_name")) return v;
        if (std.mem.eql(u8, v.kind(), "by_ref")) {
            const inner = v.namedChild(0) orelse return null;
            return if (std.mem.eql(u8, inner.kind(), "variable_name")) inner else null;
        }
        return null;
    }
    return null;
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

    pub fn init(allocator: std.mem.Allocator, call_graph: *const ProjectCallGraph) CalledBeforeAnalyzer {
        return .{
            .allocator = allocator,
            .call_graph = call_graph,
            .calls_by_caller = std.StringHashMap(std.ArrayListUnmanaged(CallInfo)).init(allocator),
            .callers_of = std.StringHashMap(std.ArrayListUnmanaged(CallerInfo)).init(allocator),
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
    }

    /// Build indexes for efficient lookup
    fn buildIndexes(self: *CalledBeforeAnalyzer) !void {
        // Build calls_by_caller index and reverse call graph
        for (self.call_graph.calls.items) |call| {
            // Add to calls_by_caller
            const result = try self.calls_by_caller.getOrPut(call.caller_fqn);
            if (!result.found_existing) {
                result.value_ptr.* = .empty;
            }
            try result.value_ptr.append(self.allocator, .{
                .callee = call.resolved_target orelse call.callee_name,
                .line = call.line,
                .file_path = call.file_path,
            });

            // Build reverse call graph (callers_of)
            const callee = call.resolved_target orelse call.callee_name;
            const reverse_result = try self.callers_of.getOrPut(callee);
            if (!reverse_result.found_existing) {
                reverse_result.value_ptr.* = .empty;
            }
            try reverse_result.value_ptr.append(self.allocator, .{
                .caller = call.caller_fqn,
                .line = call.line,
                .file_path = call.file_path,
            });
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
        // Build indexes for efficient lookup
        try self.buildIndexes();

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
                if (self.matchesFunction(call.callee, after_fn)) {
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
                if (self.matchesFunction(call.callee, before_fn)) {
                    try before_calls.append(self.allocator, .{
                        .line = call.line,
                        .callee = call.callee,
                    });
                }
                if (self.matchesFunction(call.callee, after_fn)) {
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

        return self.checkCallersRecursive(target_fn, before_fn, 0, &visited);
    }

    /// Recursive implementation of caller checking
    /// Returns satisfied=true only if ALL paths through the call graph have before_fn called
    fn checkCallersRecursive(
        self: *CalledBeforeAnalyzer,
        target_fn: []const u8,
        before_fn: []const u8,
        depth: u32,
        visited: *std.StringHashMap(void),
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
        try visited.put(target_fn, {});

        // Find callers by iterating through all keys and matching
        // because the exact key format might differ (with/without full namespace)
        var all_callers: std.ArrayListUnmanaged(CallerInfo) = .empty;
        defer all_callers.deinit(self.allocator);

        var callers_it = self.callers_of.iterator();
        while (callers_it.next()) |entry| {
            const callee_key = entry.key_ptr.*;

            // Check if this callee matches the target function
            if (self.calleeMatchesTarget(callee_key, target_fn)) {
                for (entry.value_ptr.items) |caller_info| {
                    try all_callers.append(self.allocator, caller_info);
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
                const recursive_result = try self.checkCallersRecursive(caller, before_fn, depth + 1, visited);
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
                if (self.matchesFunction(call.callee, before_fn) and call.line < call_line) {
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
                const recursive_result = try self.checkCallersRecursive(caller, before_fn, depth + 1, visited);
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

        return CheckResult{
            .satisfied = all_satisfied,
            .satisfying_caller = any_satisfying_caller,
            .missing_paths = try missing_paths.toOwnedSlice(self.allocator),
        };
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
    fn matchesFunction(self: *CalledBeforeAnalyzer, callee: []const u8, pattern: []const u8) bool {
        _ = self;

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
    pub fn toText(self: *CalledBeforeAnalyzer, result: CalledBeforeResult, before_fn: []const u8, after_fn: []const u8, file: std.Io.File) !void {
        // Extract short names for display
        const before_short = extractShortName(before_fn);
        const after_short = extractShortName(after_fn);

        // Header with box drawing
        try file.writeStreamingAll(types.io, "\n");
        try file.writeStreamingAll(types.io, "╔══════════════════════════════════════════════════════════════════════════════╗\n");
        try file.writeStreamingAll(types.io, "║                         CALLED-BEFORE ANALYSIS                               ║\n");
        try file.writeStreamingAll(types.io, "╚══════════════════════════════════════════════════════════════════════════════╝\n\n");

        // Constraint info
        try file.writeStreamingAll(types.io, "  Constraint:\n");
        const before_msg = try std.fmt.allocPrint(self.allocator, "    {s}\n", .{before_fn});
        defer self.allocator.free(before_msg);
        try file.writeStreamingAll(types.io, before_msg);
        try file.writeStreamingAll(types.io, "    must be called before\n");
        const after_msg = try std.fmt.allocPrint(self.allocator, "    {s}\n\n", .{after_fn});
        defer self.allocator.free(after_msg);
        try file.writeStreamingAll(types.io, after_msg);

        // Result summary
        if (result.satisfied) {
            try file.writeStreamingAll(types.io, "  Result: ✓ SATISFIED\n\n");
        } else {
            try file.writeStreamingAll(types.io, "  Result: ✗ VIOLATED\n\n");
        }

        // Violations section
        if (result.violations.len > 0) {
            try file.writeStreamingAll(types.io, "┌──────────────────────────────────────────────────────────────────────────────┐\n");
            const violations_header = try std.fmt.allocPrint(
                self.allocator,
                "│  VIOLATIONS ({d})                                                              │\n",
                .{result.violations.len},
            );
            defer self.allocator.free(violations_header);
            // Truncate and pad to fit
            try file.writeStreamingAll(types.io, try self.formatBoxLine(violations_header));
            try file.writeStreamingAll(types.io, "└──────────────────────────────────────────────────────────────────────────────┘\n\n");

            for (result.violations, 0..) |violation, i| {
                // Violation number
                const num_msg = try std.fmt.allocPrint(self.allocator, "  [{d}] {s}\n", .{ i + 1, violation.context_function });
                defer self.allocator.free(num_msg);
                try file.writeStreamingAll(types.io, num_msg);

                // File location
                const loc_msg = try std.fmt.allocPrint(self.allocator, "      File: {s}:{d}\n", .{ violation.file_path, violation.after_line });
                defer self.allocator.free(loc_msg);
                try file.writeStreamingAll(types.io, loc_msg);

                // Issue description
                switch (violation.kind) {
                    .wrong_order => {
                        const order_msg = try std.fmt.allocPrint(
                            self.allocator,
                            "      Issue: {s}() called at line {d}, but {s}() not called until line {d}\n",
                            .{ after_short, violation.after_line, before_short, violation.before_line orelse 0 },
                        );
                        defer self.allocator.free(order_msg);
                        try file.writeStreamingAll(types.io, order_msg);
                    },
                    .missing_before => {
                        const missing_msg = try std.fmt.allocPrint(
                            self.allocator,
                            "      Issue: {s}() is never called before {s}()\n",
                            .{ before_short, after_short },
                        );
                        defer self.allocator.free(missing_msg);
                        try file.writeStreamingAll(types.io, missing_msg);
                    },
                    .conditional_before => {
                        try file.writeStreamingAll(types.io, "      Issue: Before call may not execute on all paths\n");
                    },
                }

                // Show call paths missing the before call
                if (violation.missing_before_paths.len > 0) {
                    try file.writeStreamingAll(types.io, "\n      Call paths missing the before call:\n");
                    for (violation.missing_before_paths) |path| {
                        const path_msg = try std.fmt.allocPrint(
                            self.allocator,
                            "        → {s} (line {d})\n          {s}\n",
                            .{ path.caller, path.call_line, path.file_path },
                        );
                        defer self.allocator.free(path_msg);
                        try file.writeStreamingAll(types.io, path_msg);
                    }
                }

                try file.writeStreamingAll(types.io, "\n");
            }
        }

        // Summary statistics
        try file.writeStreamingAll(types.io, "┌──────────────────────────────────────────────────────────────────────────────┐\n");
        try file.writeStreamingAll(types.io, "│  SUMMARY                                                                     │\n");
        try file.writeStreamingAll(types.io, "└──────────────────────────────────────────────────────────────────────────────┘\n\n");

        const summary_msg = try std.fmt.allocPrint(
            self.allocator,
            "  Functions satisfying constraint: {d}\n  Total constraint matches: {d}\n  Violations: {d}\n\n",
            .{ result.satisfied_in.len, result.matches.len, result.violations.len },
        );
        defer self.allocator.free(summary_msg);
        try file.writeStreamingAll(types.io, summary_msg);

        // Satisfied functions list (collapsed by default - just show count)
        if (result.satisfied_in.len > 0) {
            try file.writeStreamingAll(types.io, "  Satisfied in:\n");
            for (result.satisfied_in) |fn_name| {
                const msg = try std.fmt.allocPrint(self.allocator, "    ✓ {s}\n", .{fn_name});
                defer self.allocator.free(msg);
                try file.writeStreamingAll(types.io, msg);
            }
            try file.writeStreamingAll(types.io, "\n");
        }
    }

    /// Format a line to fit in a box (80 chars wide with borders)
    fn formatBoxLine(self: *CalledBeforeAnalyzer, line: []const u8) ![]const u8 {
        _ = self;
        // For now just return the input - the caller handles formatting
        return line;
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

test "CallAnalyzer basic" {
    // Basic structure test - would need tree-sitter integration for full test
    const allocator = std.testing.allocator;
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_ctx = types.FileContext.init(allocator, "test.php");
    defer file_ctx.deinit();

    var analyzer = CallAnalyzer.init(allocator, &sym_table, &file_ctx);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.calls.items.len == 0);
}
