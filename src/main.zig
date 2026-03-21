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

// Plugin imports
const plugin_interface = @import("plugins/plugin_interface.zig");
const plugin_registry = @import("plugins/plugin_registry.zig");

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
// Symbol Collector - Extracts symbols from PHP files (Pass 2)
// ============================================================================

const SymbolCollector = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    file_context: *FileContext,
    source: []const u8,

    // Current context
    current_namespace: ?[]const u8 = null,
    current_class_fqcn: ?[]const u8 = null,

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
                }
            }
        }

        // Store current class context
        self.current_class_fqcn = fqcn;

        // Process class body
        if (node.childByFieldName("body")) |body| {
            try self.processClassBody(body, &class);
        }

        try self.symbol_table.addClass(class);
        self.current_class_fqcn = null;
    }

    fn parseExtendsClause(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const parent_name = getNodeText(self.source, child);
                    class.extends = try self.allocator.dupe(u8, try self.file_context.resolveFQCN(parent_name));
                    break;
                }
            }
        }
    }

    fn parseImplementsClause(self: *SymbolCollector, node: ts.Node, class: *ClassSymbol) !void {
        var implements_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const child_kind = child.kind();
                if (std.mem.eql(u8, child_kind, "name") or std.mem.eql(u8, child_kind, "qualified_name")) {
                    const iface_name = getNodeText(self.source, child);
                    const fqcn = try self.file_context.resolveFQCN(iface_name);
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
        return try phpdoc.parseTypeString(self.allocator, type_text);
    }

    fn parseMethodPhpDoc(self: *SymbolCollector, node: ts.Node, method: *MethodSymbol) !void {
        // Look for preceding comment node
        if (node.prevSibling()) |prev| {
            const prev_kind = prev.kind();
            if (std.mem.eql(u8, prev_kind, "comment")) {
                const comment = getNodeText(self.source, prev);
                if (phpdoc.isPhpDoc(comment)) {
                    const doc = try phpdoc.parsePhpDoc(self.allocator, comment);
                    method.phpdoc_return = doc.return_type;
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
                    const fqcn = try self.file_context.resolveFQCN(trait_name);
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

fn getNodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) {
        return "";
    }
    return source[start..end];
}

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
    plugins: []const u8 = "",
    output: []const u8 = "",
    verbose: bool = false,
}{};

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

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
                            .{
                                .long_name = "plugins",
                                .short_alias = 'p',
                                .help = "Comma-separated list of plugins (e.g., 'symfony-events')",
                                .value_ref = r.mkRef(&called_before_config.plugins),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCalledBefore },
                        },
                    },
                }),
            },
        },
    };
    return r.run(&app);
}

fn analyzeFile() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    const file = std.fs.openFileAbsolute(file_config.file, .{}) catch {
        std.debug.print("File not found at path: {s}\n", .{file_config.file});
        return;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, max_file_size);
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
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    if (file_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(file_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{file_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(stdout);
        } else {
            try call_graph.toText(stdout);
        }
    }
}

fn analyzeProject() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Pass 1: Parse composer.json and discover files
    if (project_config.verbose) {
        try stdout.writeAll("Pass 1: Discovering files from composer.json...\n");
    }

    const config = composer.parseComposerJson(allocator, project_config.composer) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    if (project_config.verbose) {
        try composer.printConfig(&config, stdout);
    }

    const files = try composer.discoverFiles(allocator, &config);

    if (project_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "\nDiscovered {d} PHP files\n\n", .{files.len});
        try stdout.writeAll(msg);
    }

    // Initialize parser
    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    // Pass 2: Collect symbols from all files
    if (project_config.verbose) {
        try stdout.writeAll("Pass 2: Collecting symbols...\n");
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    // Cache file sources from Pass 2 to avoid re-reading in Pass 4
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    for (files) |file_path| {
        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const source = file.readToEndAlloc(allocator, max_file_size) catch continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var file_ctx = FileContext.init(allocator, file_path);
        file_ctx.project_config = &config;

        var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source);
        collector.collect(tree) catch continue;

        try file_contexts.put(file_path, file_ctx);
        try file_sources.put(file_path, source);
    }

    if (project_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeAll("\n");
    }

    // Pass 3: Resolve inheritance
    if (project_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (reusing cached sources from Pass 2)
    if (project_config.verbose) {
        try stdout.writeAll("Pass 4: Analyzing calls...\n");
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    for (files) |file_path| {
        const source = file_sources.get(file_path) orelse continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;

        var analyzer = CallAnalyzer.init(allocator, &sym_table, file_ctx_ptr);
        defer analyzer.deinit();

        analyzer.analyzeFile(tree, source, file_path) catch continue;
        try call_graph.addCalls(&analyzer);
    }

    // Output results
    if (project_config.verbose) {
        try stdout.writeAll("\n");
    }

    if (project_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(project_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, project_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{project_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, project_config.format, "dot")) {
            try call_graph.toDot(stdout);
        } else {
            try call_graph.toText(stdout);
        }
    }
}

fn analyzeCalledBefore() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

    // Validate that either -c or -g is provided (but not both or neither)
    const has_composer = called_before_config.composer.len > 0;
    const has_config = called_before_config.config.len > 0;

    if (!has_composer and !has_config) {
        try stdout.writeAll("Error: Either --composer (-c) or --config (-g) must be specified\n");
        return;
    }

    if (has_composer and has_config) {
        try stdout.writeAll("Error: Cannot use both --composer (-c) and --config (-g) at the same time\n");
        return;
    }

    // Pass 1: Parse configuration and discover files
    var project_configs: []ProjectConfig = undefined;
    var files: []const []const u8 = undefined;

    if (has_config) {
        // Monorepo mode: parse .phpcma.json
        if (called_before_config.verbose) {
            try stdout.writeAll("Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
        }

        var phpcma_config = config_parser.parseConfigFile(allocator, called_before_config.config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };

        if (called_before_config.verbose) {
            try config_parser.printConfig(&phpcma_config, stdout);
            try stdout.writeAll("\n");
        }

        // Parse all discovered composer.json files
        project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };

        // Discover files from all projects
        files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };
    } else {
        // Single project mode: parse composer.json
        if (called_before_config.verbose) {
            try stdout.writeAll("Pass 1: Discovering files from composer.json...\n");
        }

        const single_config = composer.parseComposerJson(allocator, called_before_config.composer) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
            try stdout.writeAll(msg);
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
        try stdout.writeAll(msg);
    }

    // Initialize parser
    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    // Pass 2: Collect symbols from all files
    if (called_before_config.verbose) {
        try stdout.writeAll("Pass 2: Collecting symbols...\n");
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    var file_contexts = std.StringHashMap(FileContext).init(allocator);
    defer {
        var it = file_contexts.valueIterator();
        while (it.next()) |ctx| {
            ctx.deinit();
        }
        file_contexts.deinit();
    }

    // Store file sources for plugins that need to re-parse
    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    for (files) |file_path| {
        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();

        const source = file.readToEndAlloc(allocator, max_file_size) catch continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var file_ctx = FileContext.init(allocator, file_path);

        // Find the matching project config for this file
        for (project_configs) |*cfg| {
            if (std.mem.startsWith(u8, file_path, cfg.root_path)) {
                file_ctx.project_config = cfg;
                break;
            }
        }

        var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source);
        collector.collect(tree) catch continue;

        try file_contexts.put(file_path, file_ctx);
        try file_sources.put(file_path, source);
    }

    // Pass 3: Resolve inheritance
    if (called_before_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls
    if (called_before_config.verbose) {
        try stdout.writeAll("Pass 4: Analyzing calls...\n");
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    for (files) |file_path| {
        const source = file_sources.get(file_path) orelse continue;
        const tree = parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;

        var analyzer = CallAnalyzer.init(allocator, &sym_table, file_ctx_ptr);
        defer analyzer.deinit();

        analyzer.analyzeFile(tree, source, file_path) catch continue;
        try call_graph.addCalls(&analyzer);
    }

    // Pass 5: Plugin execution (synthetic edges)
    if (called_before_config.plugins.len > 0) {
        if (called_before_config.verbose) {
            try stdout.writeAll("Pass 5: Running plugins...\n");
        }

        // Create plugin context with all project configs
        const plugin_context = plugin_interface.PluginContext{
            .allocator = allocator,
            .sym_table = &sym_table,
            .calls = call_graph.calls.items,
            .file_sources = &file_sources,
            .project_configs = project_configs,
        };

        // Parse and run each enabled plugin
        var plugin_iter = std.mem.splitSequence(u8, called_before_config.plugins, ",");
        while (plugin_iter.next()) |plugin_name_raw| {
            const plugin_name = std.mem.trim(u8, plugin_name_raw, " ");
            if (plugin_name.len == 0) continue;

            if (plugin_registry.getPlugin(plugin_name)) |plugin| {
                if (called_before_config.verbose) {
                    const msg = try std.fmt.allocPrint(allocator, "  Running plugin: {s}\n", .{plugin.name});
                    try stdout.writeAll(msg);
                }

                const edges = plugin.analyze(&plugin_context) catch |err| {
                    const err_msg = try std.fmt.allocPrint(allocator, "  Plugin error: {}\n", .{err});
                    try stdout.writeAll(err_msg);
                    continue;
                };

                // Add synthetic edges to call graph
                for (edges) |edge| {
                    try call_graph.addSyntheticEdge(
                        edge.caller_fqn,
                        edge.callee_fqn,
                        edge.file_path,
                        edge.line,
                        edge.confidence,
                    );
                }

                if (called_before_config.verbose) {
                    const msg = try std.fmt.allocPrint(allocator, "    Added {d} synthetic edges\n", .{edges.len});
                    try stdout.writeAll(msg);
                }
            } else {
                const warn_msg = try std.fmt.allocPrint(allocator, "  Warning: Unknown plugin '{s}'\n", .{plugin_name});
                try stdout.writeAll(warn_msg);
            }
        }

        if (called_before_config.verbose) {
            try stdout.writeAll("\n");
        }
    }

    // Pass 6: Called-before analysis
    if (called_before_config.verbose) {
        try stdout.writeAll("Pass 6: Running called-before analysis...\n\n");
    }

    var cb_analyzer = call_analyzer.CalledBeforeAnalyzer.init(allocator, &call_graph);
    const result = try cb_analyzer.analyze(called_before_config.before, called_before_config.after);

    // Output results
    if (called_before_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(called_before_config.output, .{});
        defer out_file.close();
        try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, out_file);
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{called_before_config.output});
        try stdout.writeAll(msg);
    } else {
        try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, stdout);
    }

    // Exit with error code if constraint is violated
    if (!result.satisfied) {
        std.process.exit(1);
    }
}
