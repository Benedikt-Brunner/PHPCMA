const std = @import("std");
const ts = @import("tree-sitter");

const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const phpdoc = @import("phpdoc.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const FunctionSymbol = types.FunctionSymbol;

// ============================================================================
// Symbol Collector - Extracts symbols from PHP files (Pass 2)
// ============================================================================

pub const SymbolCollector = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    file_context: *FileContext,
    source: []const u8,

    // Current context
    current_namespace: ?[]const u8 = null,
    current_class_fqcn: ?[]const u8 = null,
    // Template parameter names of the class currently being processed, used to
    // keep `@return TElement`/`@param TElement` from being resolved to a bogus
    // FQCN (they are class generics, not real types).
    current_template_params: []const []const u8 = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
        source: []const u8,
    ) SymbolCollector {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .file_context = file_ctx,
            .source = source,
        };
    }

    pub fn collect(self: *SymbolCollector, tree: *ts.Tree) !void {
        const root = tree.rootNode();
        try self.traverseNode(root);
    }

    fn traverseNode(self: *SymbolCollector, node: ts.Node) error{OutOfMemory}!void {
        const kind = node.kind();

        if (std.mem.eql(u8, kind, "namespace_definition")) {
            try self.handleNamespace(node);
            return;
        }

        if (std.mem.eql(u8, kind, "namespace_use_declaration")) {
            try self.handleUseStatement(node);
        }

        if (std.mem.eql(u8, kind, "class_declaration")) {
            try self.handleClass(node);
            return;
        }

        if (std.mem.eql(u8, kind, "interface_declaration")) {
            try self.handleInterface(node);
            return;
        }

        if (std.mem.eql(u8, kind, "trait_declaration")) {
            try self.handleTrait(node);
            return;
        }

        if (std.mem.eql(u8, kind, "function_definition")) {
            try self.handleFunction(node);
            return;
        }

        // Recurse
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.traverseNode(child);
            }
        }
    }

    fn handleNamespace(self: *SymbolCollector, node: ts.Node) !void {
        if (node.childByFieldName("name")) |name_node| {
            const ns = getNodeText(self.source, name_node);
            self.current_namespace = try self.allocator.dupe(u8, ns);
            self.file_context.namespace = self.current_namespace;
        }

        // Process namespace body
        if (node.childByFieldName("body")) |body| {
            try self.traverseNode(body);
        }

        // Also traverse direct children
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (!std.mem.eql(u8, child_kind, "namespace_name") and
                    !std.mem.eql(u8, child_kind, "name") and
                    !std.mem.eql(u8, child_kind, "compound_statement"))
                {
                    try self.traverseNode(child);
                }
            }
        }
    }

    fn handleUseStatement(self: *SymbolCollector, node: ts.Node) !void {
        // Parse use statements like: use App\Service\UserService;
        // or: use App\Service\UserService as US;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "namespace_use_clause")) {
                    try self.parseUseClause(child);
                }
            }
        }
    }

    fn parseUseClause(self: *SymbolCollector, node: ts.Node) !void {
        var fqcn: ?[]const u8 = null;
        var alias: ?[]const u8 = null;

        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "qualified_name") or std.mem.eql(u8, child_kind, "name")) {
                    fqcn = getNodeText(self.source, child);
                } else if (std.mem.eql(u8, child_kind, "namespace_aliasing_clause")) {
                    if (child.namedChild(0)) |alias_node| {
                        alias = getNodeText(self.source, alias_node);
                    }
                }
            }
        }

        if (fqcn) |name| {
            const key = if (alias) |a|
                try self.allocator.dupe(u8, a)
            else blk: {
                // Extract short name from FQCN
                if (std.mem.lastIndexOf(u8, name, "\\")) |idx| {
                    break :blk try self.allocator.dupe(u8, name[idx + 1 ..]);
                }
                break :blk try self.allocator.dupe(u8, name);
            };

            const use_stmt = types.UseStatement{
                .fqcn = try self.allocator.dupe(u8, name),
                .alias = if (alias) |a| try self.allocator.dupe(u8, a) else null,
                .kind = .class,
            };
            try self.file_context.use_statements.put(key, use_stmt);
        }
    }

    fn handleClass(self: *SymbolCollector, node: ts.Node) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const class_name = getNodeText(self.source, name_node);

        // Build FQCN
        const fqcn = if (self.current_namespace) |ns|
            try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, class_name })
        else
            try self.allocator.dupe(u8, class_name);

        var class = ClassSymbol.init(self.allocator, fqcn);
        class.file_path = self.file_context.file_path;
        class.start_line = node.startPoint().row + 1;

        // Get extends and implements by iterating children (tree-sitter-php uses child nodes not fields)
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "base_clause")) {
                    try self.parseExtendsClause(child, &class);
                } else if (std.mem.eql(u8, child_kind, "class_interface_clause")) {
                    try self.parseImplementsClause(child, &class);
                } else if (std.mem.eql(u8, child_kind, "abstract_modifier")) {
                    class.is_abstract = true;
                } else if (std.mem.eql(u8, child_kind, "final_modifier")) {
                    class.is_final = true;
                } else if (std.mem.eql(u8, child_kind, "readonly_modifier")) {
                    class.is_readonly = true;
                }
            }
        }

        // Parse class-level PHPDoc generics (@template / @extends Base<...>)
        // before the body so method return/param typing can recognize template
        // parameter names.
        try self.parseClassGenerics(node, &class);
        self.current_template_params = templateNames(self.allocator, class.template_params) catch &.{};

        // Store current class context
        self.current_class_fqcn = fqcn;

        // Process class body
        if (node.childByFieldName("body")) |body| {
            try self.processClassBody(body, &class);
        }

        try self.symbol_table.addClass(class);
        self.current_class_fqcn = null;
        self.current_template_params = &.{};
    }

    /// Parse `@template`, `@extends`/`@template-extends`/`@phpstan-extends` from
    /// the class's preceding PHPDoc and store the generic metadata on `class`.
    fn parseClassGenerics(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        const prev = precedingDocComment(node) orelse return;
        const comment = getNodeText(self.source, prev);
        if (!phpdoc.isPhpDoc(comment)) return;

        var template_list: std.ArrayListUnmanaged(types.TemplateParam) = .empty;
        // First pass: collect @template declarations so @extends arg parsing can
        // tell template names apart from real types. Local type aliases
        // (@phpstan-type/@psalm-type) are recorded too — with no fallback — so
        // `@return <Alias>` stays symbolic instead of resolving to a bogus FQCN
        // (e.g. EntitySearchResult's `template-type<>` alias), which would
        // otherwise masquerade as an external receiver type.
        var lines = std.mem.splitSequence(u8, comment, "\n");
        while (lines.next()) |raw_line| {
            const line = trimDocCommentLine(raw_line);
            if (stripTag(line, "@template") orelse stripTag(line, "@phpstan-template") orelse stripTag(line, "@psalm-template")) |tmpl| {
                try template_list.append(self.allocator, try self.parseTemplateParam(tmpl));
            } else if (stripTag(line, "@phpstan-type") orelse stripTag(line, "@psalm-type")) |alias| {
                try template_list.append(self.allocator, .{ .name = try self.aliasName(alias), .fallback = null });
            }
        }
        class.template_params = try template_list.toOwnedSlice(self.allocator);

        // Second pass: @extends parent type arguments.
        lines = std.mem.splitSequence(u8, comment, "\n");
        while (lines.next()) |raw_line| {
            const line = trimDocCommentLine(raw_line);
            const ext = stripTag(line, "@extends") orelse
                stripTag(line, "@template-extends") orelse
                stripTag(line, "@phpstan-extends") orelse
                stripTag(line, "@psalm-extends") orelse continue;
            class.extends_type_args = try self.parseGenericArgs(ext, class.template_params);
            break;
        }
    }

    /// Extract the leading identifier of a `@phpstan-type Name ...` body.
    fn aliasName(self: *SymbolCollector, body: []const u8) ![]const u8 {
        const rest = std.mem.trim(u8, body, " \t");
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
        return self.allocator.dupe(u8, rest[0..end]);
    }

    /// Parse a single `@template Name [of Bound] [= Default]` body.
    fn parseTemplateParam(self: *SymbolCollector, body: []const u8) !types.TemplateParam {
        var rest = std.mem.trim(u8, body, " \t");
        // Name is the leading identifier.
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
        const name = try self.allocator.dupe(u8, rest[0..end]);
        rest = std.mem.trim(u8, rest[end..], " \t");

        var bound: ?[]const u8 = null;
        var default: ?[]const u8 = null;
        if (std.mem.startsWith(u8, rest, "of ")) {
            rest = std.mem.trim(u8, rest[3..], " \t");
            const tok_end = tokenEnd(rest);
            bound = rest[0..tok_end];
            rest = std.mem.trim(u8, rest[tok_end..], " \t");
        }
        if (std.mem.startsWith(u8, rest, "=")) {
            rest = std.mem.trim(u8, rest[1..], " \t");
            const tok_end = tokenEnd(rest);
            default = rest[0..tok_end];
        }

        const fallback_raw = default orelse bound;
        const fallback: ?[]const u8 = if (fallback_raw) |f| blk: {
            if (f.len == 0 or types.TypeInfo.isBuiltin(f)) break :blk null;
            break :blk try self.allocator.dupe(u8, self.file_context.resolveFQCN(f));
        } else null;

        return .{ .name = name, .fallback = fallback };
    }

    /// Parse the type-argument list of `Base<Arg1, Arg2>` (the text after the
    /// `@extends`/`@implements` tag). Each argument that is one of the class's
    /// own template names or a builtin is kept verbatim; other class-like names
    /// are resolved to FQCNs so they match symbol-table keys.
    fn parseGenericArgs(
        self: *SymbolCollector,
        text: []const u8,
        template_params: []const types.TemplateParam,
    ) ![]const []const u8 {
        const open = std.mem.indexOfScalar(u8, text, '<') orelse return &.{};
        const close = std.mem.lastIndexOfScalar(u8, text, '>') orelse return &.{};
        if (close <= open + 1) return &.{};
        const inner = text[open + 1 .. close];

        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        var depth: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c: u8 = if (at_end) ',' else inner[i];
            switch (c) {
                '<', '(', '{', '[' => depth += 1,
                '>', ')', '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    const arg = std.mem.trim(u8, inner[start..i], " \t");
                    if (arg.len > 0) {
                        try args.append(self.allocator, try self.normalizeGenericArg(arg, template_params));
                    }
                    start = i + 1;
                },
                else => {},
            }
        }
        return try args.toOwnedSlice(self.allocator);
    }

    fn normalizeGenericArg(
        self: *SymbolCollector,
        arg: []const u8,
        template_params: []const types.TemplateParam,
    ) ![]const u8 {
        for (template_params) |tp| {
            if (std.mem.eql(u8, tp.name, arg)) return try self.allocator.dupe(u8, arg);
        }
        if (types.TypeInfo.isBuiltin(arg)) return try self.allocator.dupe(u8, arg);
        // Strip any nested generics on the arg itself (e.g. `Foo<Bar>` -> `Foo`).
        const base = if (std.mem.indexOfScalar(u8, arg, '<')) |lt| arg[0..lt] else arg;
        return try self.allocator.dupe(u8, self.file_context.resolveFQCN(base));
    }

    fn parseExtendsClause(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const parent_name = getNodeText(self.source, child);
                    class.extends = try self.allocator.dupe(u8, self.file_context.resolveFQCN(parent_name));
                    break;
                }
            }
        }
    }

    /// Collect every parent named in an interface's `base_clause` (interfaces
    /// may extend multiple), FQCN-resolved.
    fn parseInterfaceExtends(self: *SymbolCollector, node: ts.Node, iface: *types.InterfaceSymbol) !void {
        var extends_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const parent_name = getNodeText(self.source, child);
                    const fqcn = self.file_context.resolveFQCN(parent_name);
                    try extends_list.append(self.allocator, try self.allocator.dupe(u8, fqcn));
                }
            }
        }
        iface.extends = try extends_list.toOwnedSlice(self.allocator);
    }

    fn parseImplementsClause(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        var implements_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const iface_name = getNodeText(self.source, child);
                    const fqcn = self.file_context.resolveFQCN(iface_name);
                    try implements_list.append(self.allocator, try self.allocator.dupe(u8, fqcn));
                }
            }
        }
        class.implements = try implements_list.toOwnedSlice(self.allocator);
    }

    fn processClassBody(self: *SymbolCollector, body: ts.Node, class: *ClassSymbol) !void {
        var i: u32 = 0;
        while (i < body.namedChildCount()) : (i += 1) {
            if (body.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "method_declaration")) {
                    try self.handleMethod(child, class);
                } else if (std.mem.eql(u8, child_kind, "property_declaration")) {
                    try self.handleProperty(child, class);
                } else if (std.mem.eql(u8, child_kind, "use_declaration")) {
                    try self.handleTraitUse(child, class);
                }
            }
        }
    }

    fn handleMethod(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const method_name = getNodeText(self.source, name_node);

        var method = MethodSymbol{
            .name = try self.allocator.dupe(u8, method_name),
            .visibility = .public,
            .is_static = false,
            .is_abstract = false,
            .is_final = false,
            .parameters = &.{},
            .return_type = null,
            .phpdoc_return = null,
            .start_line = node.startPoint().row + 1,
            .end_line = node.endPoint().row + 1,
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
            .containing_class = class.fqcn,
            .file_path = self.file_context.file_path,
        };

        // Parse modifiers
        try self.parseMethodModifiers(node, &method);

        // Parse parameters
        if (node.childByFieldName("parameters")) |params| {
            method.parameters = try self.parseParameters(params);
        }

        // Constructor property promotion: `public function __construct(private
        // readonly Foo $foo)` declares a real `$this->foo` property. Register
        // it so property-typed method calls (`$this->foo->bar()`) resolve.
        if (std.mem.eql(u8, method_name, "__construct")) {
            for (method.parameters) |param| {
                if (!param.is_promoted) continue;
                try class.addProperty(.{
                    .name = try self.allocator.dupe(u8, param.name),
                    .visibility = .private,
                    .is_static = false,
                    .is_readonly = false,
                    .declared_type = param.type_info,
                    .phpdoc_type = param.phpdoc_type,
                    .default_value_type = null,
                    .line = method.start_line,
                });
            }
        }

        // Parse return type
        if (node.childByFieldName("return_type")) |ret| {
            method.return_type = try self.parseTypeNode(ret);
        }

        // Parse PHPDoc if present
        try self.parseMethodPhpDoc(node, &method);

        try class.addMethod(method);
    }

    fn parseMethodModifiers(self: *const SymbolCollector, node: ts.Node, method: *MethodSymbol) !void {
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "visibility_modifier")) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        method.visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        method.visibility = .protected;
                    }
                } else if (std.mem.eql(u8, child_kind, "static_modifier")) {
                    method.is_static = true;
                } else if (std.mem.eql(u8, child_kind, "abstract_modifier")) {
                    method.is_abstract = true;
                } else if (std.mem.eql(u8, child_kind, "final_modifier")) {
                    method.is_final = true;
                }
            }
        }
    }

    fn parseParameters(self: *SymbolCollector, params_node: ts.Node) ![]const types.ParameterInfo {
        var params: std.ArrayListUnmanaged(types.ParameterInfo) = .empty;

        var i: u32 = 0;
        while (i < params_node.namedChildCount()) : (i += 1) {
            if (params_node.namedChild(i)) |param| {
                const param_kind = param.kind();
                if (std.mem.eql(u8, param_kind, "simple_parameter") or
                    std.mem.eql(u8, param_kind, "variadic_parameter") or
                    std.mem.eql(u8, param_kind, "property_promotion_parameter"))
                {
                    if (try self.parseParameter(param)) |p| {
                        try params.append(self.allocator, p);
                    }
                }
            }
        }

        return params.toOwnedSlice(self.allocator);
    }

    fn parseParameter(self: *SymbolCollector, node: ts.Node) !?types.ParameterInfo {
        var param = types.ParameterInfo{
            .name = "",
            .type_info = null,
            .phpdoc_type = null,
            .has_default = false,
            .is_variadic = std.mem.eql(u8, node.kind(), "variadic_parameter"),
            .is_by_reference = false, // TODO: parse & references
            .is_promoted = std.mem.eql(u8, node.kind(), "property_promotion_parameter"),
        };

        // Get name
        if (node.childByFieldName("name")) |name_node| {
            const name_text = getNodeText(self.source, name_node);
            // Remove $ prefix
            param.name = if (name_text.len > 0 and name_text[0] == '$')
                try self.allocator.dupe(u8, name_text[1..])
            else
                try self.allocator.dupe(u8, name_text);
        } else {
            return null;
        }

        // Get type
        if (node.childByFieldName("type")) |type_node| {
            param.type_info = try self.parseTypeNode(type_node);
        }

        // Check for default value
        if (node.childByFieldName("default_value")) |_| {
            param.has_default = true;
        }

        return param;
    }

    fn parseTypeNode(self: *SymbolCollector, node: ts.Node) !?types.TypeInfo {
        const type_text = getNodeText(self.source, node);
        if (type_text.len == 0) return null;
        var info = try phpdoc.parseTypeString(self.allocator, type_text);
        // Resolve class-like base types to their FQCN using this file's
        // namespace + use statements, so they match symbol-table keys (which
        // are FQCNs). Builtins and special types (self/static/parent) are left
        // untouched. This is what makes `$this->prop->m()` resolvable.
        switch (info.kind) {
            .simple, .nullable => {
                if (!info.is_builtin) info.base_type = try self.resolveTypeToken(info.base_type);
            },
            // Union/intersection: resolve each class-like member so type-directed
            // matching (find_by_type, conformance) sees FQCNs, not file-local
            // short names. `type_parts` is duped here into a fresh slice.
            .union_type, .intersection => {
                const resolved = try self.allocator.alloc([]const u8, info.type_parts.len);
                for (info.type_parts, 0..) |part, i| {
                    resolved[i] = try self.resolveTypeToken(part);
                }
                info.type_parts = resolved;
            },
            // `Foo[]` stores the element name in `base_type` (and is not builtin);
            // resolve it. The `array<...>` form is left as-is (builtin-tagged).
            .array_type => {
                if (!info.is_builtin) info.base_type = try self.resolveTypeToken(info.base_type);
            },
            else => {},
        }
        return info;
    }

    /// Resolve one type token to its FQCN, leaving builtins and the special
    /// `self`/`static`/`parent` types untouched. Always returns an
    /// allocator-owned copy.
    fn resolveTypeToken(self: *SymbolCollector, token: []const u8) ![]const u8 {
        if (types.TypeInfo.isBuiltin(token) or
            std.mem.eql(u8, token, "self") or
            std.mem.eql(u8, token, "static") or
            std.mem.eql(u8, token, "parent"))
        {
            return self.allocator.dupe(u8, token);
        }
        return self.allocator.dupe(u8, self.file_context.resolveFQCN(token));
    }

    /// True when `info` refers to one of the current class's template parameters
    /// (directly, as a nullable, or as a member of a union), so it should be left
    /// symbolic rather than resolved to an FQCN.
    fn isTemplateType(self: *const SymbolCollector, info: types.TypeInfo) bool {
        if (self.current_template_params.len == 0) return false;
        switch (info.kind) {
            .simple, .nullable => return self.isTemplateName(baseToken(info.base_type)),
            .union_type => {
                for (info.type_parts) |part| {
                    if (self.isTemplateName(baseToken(part))) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn isTemplateName(self: *const SymbolCollector, name: []const u8) bool {
        for (self.current_template_params) |tp| {
            if (std.mem.eql(u8, tp, name)) return true;
        }
        return false;
    }

    /// True when `info` is a collection-shaped type (`X[]`, `list<X>`,
    /// `Collection<X>`, `Traversable<X>`, `array<K, X>`, ...) whose element type
    /// is one of the current class's template parameters.
    fn isTemplateCollection(self: *const SymbolCollector, info: types.TypeInfo) bool {
        if (self.current_template_params.len == 0) return false;
        if (info.kind != .simple and info.kind != .array_type) return false;
        if (lastGenericArgName(info.base_type)) |elem| {
            return self.isTemplateName(baseToken(elem));
        }
        // `X[]` parses to an array_type whose base_type is the bare element name.
        if (info.kind == .array_type) {
            return self.isTemplateName(baseToken(info.base_type));
        }
        return false;
    }

    fn parseMethodPhpDoc(self: *SymbolCollector, node: ts.Node, method: *MethodSymbol) !void {
        // Look for preceding comment node, skipping any attribute list (e.g.
        // `#[Route(...)]`) that sits between the docblock and the declaration.
        if (precedingDocComment(node)) |prev| {
            {
                const comment = getNodeText(self.source, prev);
                if (phpdoc.isPhpDoc(comment)) {
                    const doc = try phpdoc.parsePhpDoc(self.allocator, comment);
                    // Resolve class-like names (incl. `Foo[]`/`Collection<Foo>`
                    // element types) to FQCNs in this file's context, so return
                    // types match symbol-table keys and feed chain/foreach typing.
                    if (doc.return_type) |rt| {
                        // A bare template parameter (`@return TElement`) must not
                        // be resolved to a (bogus) FQCN — it is substituted later
                        // against the receiver's concrete generic binding.
                        if (self.isTemplateType(rt)) {
                            method.phpdoc_return = rt;
                        } else if (self.isTemplateCollection(rt)) {
                            // `@return Traversable<TElement>` / `list<TElement>`:
                            // the element is an unbound template, so collapse to a
                            // bare array rather than fabricating an element FQCN.
                            method.phpdoc_return = .{ .kind = .array_type, .base_type = "array", .type_parts = &.{}, .is_builtin = true };
                        } else {
                            method.phpdoc_return = try phpdoc.resolveTypeFqcn(self.allocator, self.file_context, rt);
                        }
                    }
                    // Could also update parameter types from PHPDoc here
                }
            }
        }
    }

    fn handleProperty(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        // Property declaration can have multiple properties
        var declared_type: ?types.TypeInfo = null;
        var visibility: types.Visibility = .public;
        var is_static = false;
        var is_readonly = false;

        // Parse type and modifiers from the declaration
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "visibility_modifier")) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        visibility = .protected;
                    }
                } else if (std.mem.eql(u8, child_kind, "static_modifier")) {
                    is_static = true;
                } else if (std.mem.eql(u8, child_kind, "readonly_modifier")) {
                    is_readonly = true;
                } else if (std.mem.eql(u8, child_kind, "named_type") or
                    std.mem.eql(u8, child_kind, "optional_type") or
                    std.mem.eql(u8, child_kind, "union_type"))
                {
                    declared_type = try self.parseTypeNode(child);
                } else if (std.mem.eql(u8, child_kind, "property_element")) {
                    // Get property name
                    if (child.namedChild(0)) |name_node| {
                        const name_text = getNodeText(self.source, name_node);
                        const prop_name = if (name_text.len > 0 and name_text[0] == '$')
                            name_text[1..]
                        else
                            name_text;

                        const prop = PropertySymbol{
                            .name = try self.allocator.dupe(u8, prop_name),
                            .visibility = visibility,
                            .is_static = is_static,
                            .is_readonly = is_readonly,
                            .declared_type = declared_type,
                            .phpdoc_type = null,
                            .default_value_type = null,
                            .line = node.startPoint().row + 1,
                        };
                        try class.addProperty(prop);
                    }
                }
            }
        }
    }

    fn handleTraitUse(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        var traits: std.ArrayListUnmanaged([]const u8) = .empty;

        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const trait_name = getNodeText(self.source, child);
                    const fqcn = self.file_context.resolveFQCN(trait_name);
                    try traits.append(self.allocator, try self.allocator.dupe(u8, fqcn));
                }
            }
        }

        // Append to existing uses
        const old_uses = class.uses;
        var new_uses: std.ArrayListUnmanaged([]const u8) = .empty;
        for (old_uses) |u| {
            try new_uses.append(self.allocator, u);
        }
        for (traits.items) |t| {
            try new_uses.append(self.allocator, t);
        }
        class.uses = try new_uses.toOwnedSlice(self.allocator);
    }

    fn handleInterface(self: *SymbolCollector, node: ts.Node) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const iface_name = getNodeText(self.source, name_node);

        const fqcn = if (self.current_namespace) |ns|
            try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, iface_name })
        else
            try self.allocator.dupe(u8, iface_name);

        var iface = types.InterfaceSymbol.init(self.allocator, fqcn);
        iface.file_path = self.file_context.file_path;
        iface.start_line = node.startPoint().row + 1;
        iface.end_line = node.endPoint().row + 1;

        // Parse `extends` (interfaces use a `base_clause` and may extend several
        // parents). FQCN-resolved against this file's namespace + use table.
        {
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                if (node.namedChild(i)) |child| {
                    if (std.mem.eql(u8, child.kind(), "base_clause")) {
                        try self.parseInterfaceExtends(child, &iface);
                    }
                }
            }
        }

        // Process interface body for method signatures
        if (node.childByFieldName("body")) |body| {
            var i: u32 = 0;
            while (i < body.namedChildCount()) : (i += 1) {
                if (body.namedChild(i)) |child| {
                    if (std.mem.eql(u8, child.kind(), "method_declaration")) {
                        try self.handleInterfaceMethod(child, &iface);
                    }
                }
            }
        }

        try self.symbol_table.addInterface(iface);
    }

    fn handleInterfaceMethod(self: *SymbolCollector, node: ts.Node, iface: *types.InterfaceSymbol) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const method_name = getNodeText(self.source, name_node);

        var method = MethodSymbol{
            .name = try self.allocator.dupe(u8, method_name),
            .visibility = .public,
            .is_static = false,
            .is_abstract = true,
            .is_final = false,
            .parameters = &.{},
            .return_type = null,
            .phpdoc_return = null,
            .start_line = node.startPoint().row + 1,
            .end_line = node.endPoint().row + 1,
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
            .containing_class = iface.fqcn,
            .file_path = self.file_context.file_path,
        };

        if (node.childByFieldName("parameters")) |params| {
            method.parameters = try self.parseParameters(params);
        }

        if (node.childByFieldName("return_type")) |ret| {
            method.return_type = try self.parseTypeNode(ret);
        }

        try iface.addMethod(method);
    }

    fn handleTrait(self: *SymbolCollector, node: ts.Node) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const trait_name = getNodeText(self.source, name_node);

        const fqcn = if (self.current_namespace) |ns|
            try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, trait_name })
        else
            try self.allocator.dupe(u8, trait_name);

        var trait = types.TraitSymbol.init(self.allocator, fqcn);
        trait.file_path = self.file_context.file_path;

        // Process trait body
        if (node.childByFieldName("body")) |body| {
            var i: u32 = 0;
            while (i < body.namedChildCount()) : (i += 1) {
                if (body.namedChild(i)) |child| {
                    const child_kind = child.kind();
                    if (std.mem.eql(u8, child_kind, "method_declaration")) {
                        try self.handleTraitMethod(child, &trait);
                    } else if (std.mem.eql(u8, child_kind, "property_declaration")) {
                        try self.handleTraitProperty(child, &trait);
                    }
                }
            }
        }

        try self.symbol_table.addTrait(trait);
    }

    fn handleTraitMethod(self: *SymbolCollector, node: ts.Node, trait: *types.TraitSymbol) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const method_name = getNodeText(self.source, name_node);

        var method = MethodSymbol{
            .name = try self.allocator.dupe(u8, method_name),
            .visibility = .public,
            .is_static = false,
            .is_abstract = false,
            .is_final = false,
            .parameters = &.{},
            .return_type = null,
            .phpdoc_return = null,
            .start_line = node.startPoint().row + 1,
            .end_line = node.endPoint().row + 1,
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
            .containing_class = trait.fqcn,
            .file_path = self.file_context.file_path,
        };

        try self.parseMethodModifiers(node, &method);

        if (node.childByFieldName("parameters")) |params| {
            method.parameters = try self.parseParameters(params);
        }

        if (node.childByFieldName("return_type")) |ret| {
            method.return_type = try self.parseTypeNode(ret);
        }

        try trait.addMethod(method);
    }

    fn handleTraitProperty(self: *SymbolCollector, node: ts.Node, trait: *types.TraitSymbol) !void {
        var declared_type: ?types.TypeInfo = null;
        var visibility: types.Visibility = .public;
        var is_static = false;

        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "visibility_modifier")) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        visibility = .protected;
                    }
                } else if (std.mem.eql(u8, child_kind, "static_modifier")) {
                    is_static = true;
                } else if (std.mem.eql(u8, child_kind, "named_type") or
                    std.mem.eql(u8, child_kind, "optional_type"))
                {
                    declared_type = try self.parseTypeNode(child);
                } else if (std.mem.eql(u8, child_kind, "property_element")) {
                    if (child.namedChild(0)) |name_node| {
                        const name_text = getNodeText(self.source, name_node);
                        const prop_name = if (name_text.len > 0 and name_text[0] == '$')
                            name_text[1..]
                        else
                            name_text;

                        const prop = PropertySymbol{
                            .name = try self.allocator.dupe(u8, prop_name),
                            .visibility = visibility,
                            .is_static = is_static,
                            .is_readonly = false,
                            .declared_type = declared_type,
                            .phpdoc_type = null,
                            .default_value_type = null,
                            .line = node.startPoint().row + 1,
                        };
                        try trait.addProperty(prop);
                    }
                }
            }
        }
    }

    fn handleFunction(self: *SymbolCollector, node: ts.Node) !void {
        const name_node = node.childByFieldName("name") orelse return;
        const func_name = getNodeText(self.source, name_node);

        const fqn = if (self.current_namespace) |ns|
            try std.fmt.allocPrint(self.allocator, "{s}\\{s}", .{ ns, func_name })
        else
            try self.allocator.dupe(u8, func_name);

        var func = FunctionSymbol{
            .name = try self.allocator.dupe(u8, func_name),
            .fqn = fqn,
            .namespace = self.current_namespace,
            .parameters = &.{},
            .return_type = null,
            .phpdoc_return = null,
            .start_line = node.startPoint().row + 1,
            .end_line = node.endPoint().row + 1,
            .file_path = self.file_context.file_path,
        };

        if (node.childByFieldName("parameters")) |params| {
            func.parameters = try self.parseParameters(params);
        }

        if (node.childByFieldName("return_type")) |ret| {
            func.return_type = try self.parseTypeNode(ret);
        }

        try self.symbol_table.addFunction(func);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn getNodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) {
        return "";
    }
    return source[start..end];
}

/// Trim a single PHPDoc comment line: strip surrounding whitespace and a leading
/// `/**`, `*/`, `/*`, or `*` decoration so tag matching sees the bare content.
fn trimDocCommentLine(line: []const u8) []const u8 {
    var result = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, result, "/**")) {
        result = result[3..];
    } else if (std.mem.startsWith(u8, result, "/*")) {
        result = result[2..];
    } else if (std.mem.startsWith(u8, result, "*/")) {
        result = "";
    } else if (std.mem.startsWith(u8, result, "*")) {
        result = result[1..];
    }
    return std.mem.trim(u8, result, " \t");
}

/// If `line` starts with `tag` followed by whitespace (or is exactly `tag`),
/// return the trimmed remainder; otherwise null.
fn stripTag(line: []const u8, tag: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, tag)) return null;
    if (line.len == tag.len) return "";
    const next = line[tag.len];
    if (next != ' ' and next != '\t') return null;
    return std.mem.trim(u8, line[tag.len..], " \t");
}

/// End index of the leading type token in `s`, respecting `<...>`/`(...)` nesting
/// and stopping at the first top-level whitespace or `=`.
fn tokenEnd(s: []const u8) usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '<', '(', '{', '[' => depth += 1,
            '>', ')', '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            ' ', '\t' => if (depth == 0) return i,
            '=' => if (depth == 0) return i,
            else => {},
        }
    }
    return s.len;
}

/// Find the PHPDoc comment node preceding a declaration, skipping any
/// `attribute_list` nodes (`#[Package(...)]`, `#[Route(...)]`, ...) that
/// tree-sitter places between the docblock and the declaration.
fn precedingDocComment(node: ts.Node) ?ts.Node {
    var prev = node.prevSibling();
    while (prev) |p| {
        const kind = p.kind();
        if (std.mem.eql(u8, kind, "attribute_list")) {
            prev = p.prevSibling();
            continue;
        }
        if (std.mem.eql(u8, kind, "comment")) return p;
        return null;
    }
    return null;
}

/// The bare type name of a token: drops any trailing `<...>` generic suffix.
fn baseToken(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '<')) |lt| return name[0..lt];
    return name;
}

/// The last top-level type argument of `Foo<A, B>` (-> "B"), respecting nesting,
/// or null when there is no `<...>`.
fn lastGenericArgName(type_str: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, type_str, '<') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, type_str, '>') orelse return null;
    if (close <= open + 1) return null;
    const inner = type_str[open + 1 .. close];
    var depth: usize = 0;
    var last_start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        switch (inner[i]) {
            '<', '(', '{', '[' => depth += 1,
            '>', ')', '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                last_start = i + 1;
            },
            else => {},
        }
    }
    const arg = std.mem.trim(u8, inner[last_start..], " \t");
    return if (arg.len == 0) null else arg;
}

/// Duplicate just the template parameter names into a fresh slice.
fn templateNames(allocator: std.mem.Allocator, params: []const types.TemplateParam) ![]const []const u8 {
    if (params.len == 0) return &.{};
    const names = try allocator.alloc([]const u8, params.len);
    for (params, 0..) |p, i| names[i] = p.name;
    return names;
}
