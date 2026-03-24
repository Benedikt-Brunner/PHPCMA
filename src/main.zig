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
const generics = @import("generics.zig");
const call_analyzer = @import("call_analyzer.zig");
const boundary_analyzer = @import("boundary_analyzer.zig");
const type_violation_analyzer = @import("type_violation_analyzer.zig");
const return_type_checker = @import("return_type_checker.zig");
const null_safety = @import("null_safety.zig");
const NodeKindIds = @import("node_kind_ids.zig").NodeKindIds;
const parallel = @import("parallel.zig");

// Report module
const report = @import("report.zig");

// Framework stubs
const framework_stubs = @import("framework_stubs.zig");

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

pub const SymbolCollector = struct {
    allocator: std.mem.Allocator,
    symbol_table: *SymbolTable,
    file_context: *FileContext,
    source: []const u8,
    ids: NodeKindIds,

    // Current context
    current_namespace: ?[]const u8 = null,
    current_class_fqcn: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        sym_table: *SymbolTable,
        file_ctx: *FileContext,
        source: []const u8,
        language: *const ts.Language,
    ) SymbolCollector {
        return .{
            .allocator = allocator,
            .symbol_table = sym_table,
            .file_context = file_ctx,
            .source = source,
            .ids = NodeKindIds.init(language),
        };
    }

    pub fn collect(self: *SymbolCollector, tree: *ts.Tree) !void {
        const root = tree.rootNode();
        try self.traverseNode(root);
    }

    fn traverseNode(self: *SymbolCollector, node: ts.Node) error{OutOfMemory}!void {
        const kind_id = node.kindId();

        if (kind_id == self.ids.namespace_definition) {
            try self.handleNamespace(node);
            return;
        }

        if (kind_id == self.ids.namespace_use_declaration) {
            try self.handleUseStatement(node);
        }

        if (kind_id == self.ids.class_declaration) {
            try self.handleClass(node);
            return;
        }

        if (kind_id == self.ids.interface_declaration) {
            try self.handleInterface(node);
            return;
        }

        if (kind_id == self.ids.trait_declaration) {
            try self.handleTrait(node);
            return;
        }

        if (kind_id == self.ids.function_definition) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id != self.ids.namespace_name and
                    child_kind_id != self.ids.name and
                    child_kind_id != self.ids.compound_statement)
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
                if (child.kindId() == self.ids.namespace_use_clause) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.qualified_name or child_kind_id == self.ids.name) {
                    fqcn = getNodeText(self.source, child);
                } else if (child_kind_id == self.ids.namespace_aliasing_clause) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.base_clause) {
                    try self.parseExtendsClause(child, &class);
                } else if (child_kind_id == self.ids.class_interface_clause) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.name or child_kind_id == self.ids.qualified_name) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.name or child_kind_id == self.ids.qualified_name) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.method_declaration) {
                    try self.handleMethod(child, class);
                } else if (child_kind_id == self.ids.property_declaration) {
                    try self.handleProperty(child, class);
                } else if (child_kind_id == self.ids.use_declaration) {
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

        // For constructors, add promoted parameters as class properties
        if (std.mem.eql(u8, method_name, "__construct")) {
            for (method.parameters) |param| {
                if (!param.is_promoted) continue;
                const type_info = param.type_info orelse param.phpdoc_type;

                // Parse visibility from the property_promotion_parameter node
                var visibility: types.Visibility = .public;
                var is_readonly = false;
                if (node.childByFieldName("parameters")) |params| {
                    var pi: u32 = 0;
                    while (pi < params.namedChildCount()) : (pi += 1) {
                        if (params.namedChild(pi)) |pnode| {
                            if (pnode.kindId() == self.ids.property_promotion_parameter) {
                                // Match by name
                                if (pnode.childByFieldName("name")) |name_n| {
                                    const raw = getNodeText(self.source, name_n);
                                    const pname = if (raw.len > 0 and raw[0] == '$') raw[1..] else raw;
                                    if (std.mem.eql(u8, pname, param.name)) {
                                        // Extract visibility and readonly from children
                                        var ci: u32 = 0;
                                        while (ci < pnode.childCount()) : (ci += 1) {
                                            if (pnode.child(ci)) |ch| {
                                                const ck = ch.kindId();
                                                if (ck == self.ids.visibility_modifier) {
                                                    visibility = types.Visibility.fromString(getNodeText(self.source, ch));
                                                } else if (ck == self.ids.readonly_modifier) {
                                                    is_readonly = true;
                                                }
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                try class.addProperty(.{
                    .name = param.name,
                    .visibility = visibility,
                    .is_static = false,
                    .is_readonly = is_readonly,
                    .declared_type = type_info,
                    .phpdoc_type = null,
                    .default_value_type = null,
                    .line = node.startPoint().row + 1,
                });
            }
        }

        try class.addMethod(method);
    }

    fn parseMethodModifiers(self: *const SymbolCollector, node: ts.Node, method: *MethodSymbol) !void {
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            if (node.child(i)) |child| {
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.visibility_modifier) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        method.visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        method.visibility = .protected;
                    }
                } else if (child_kind_id == self.ids.static_modifier) {
                    method.is_static = true;
                } else if (child_kind_id == self.ids.abstract_modifier) {
                    method.is_abstract = true;
                } else if (child_kind_id == self.ids.final_modifier) {
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
                const param_kind_id = param.kindId();
                if (param_kind_id == self.ids.simple_parameter or
                    param_kind_id == self.ids.variadic_parameter or
                    param_kind_id == self.ids.property_promotion_parameter)
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
        const node_kind_id = node.kindId();
        var param = types.ParameterInfo{
            .name = "",
            .type_info = null,
            .phpdoc_type = null,
            .has_default = false,
            .is_variadic = node_kind_id == self.ids.variadic_parameter,
            .is_by_reference = false, // TODO: parse & references
            .is_promoted = node_kind_id == self.ids.property_promotion_parameter,
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
            if (prev.kindId() == self.ids.comment) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.visibility_modifier) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        visibility = .protected;
                    }
                } else if (child_kind_id == self.ids.static_modifier) {
                    is_static = true;
                } else if (child_kind_id == self.ids.readonly_modifier) {
                    is_readonly = true;
                } else if (child_kind_id == self.ids.named_type or
                    child_kind_id == self.ids.optional_type or
                    child_kind_id == self.ids.union_type)
                {
                    declared_type = try self.parseTypeNode(child);
                } else if (child_kind_id == self.ids.property_element) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.name or child_kind_id == self.ids.qualified_name) {
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
                    if (child.kindId() == self.ids.method_declaration) {
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
                    const child_kind_id = child.kindId();
                    if (child_kind_id == self.ids.method_declaration) {
                        try self.handleTraitMethod(child, &trait);
                    } else if (child_kind_id == self.ids.property_declaration) {
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
                const child_kind_id = child.kindId();
                if (child_kind_id == self.ids.visibility_modifier) {
                    const text = getNodeText(self.source, child);
                    if (std.mem.eql(u8, text, "private")) {
                        visibility = .private;
                    } else if (std.mem.eql(u8, text, "protected")) {
                        visibility = .protected;
                    }
                } else if (child_kind_id == self.ids.static_modifier) {
                    is_static = true;
                } else if (child_kind_id == self.ids.named_type or
                    child_kind_id == self.ids.optional_type)
                {
                    declared_type = try self.parseTypeNode(child);
                } else if (child_kind_id == self.ids.property_element) {
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
// Public API for parallel processing
// ============================================================================

/// Wrapper for SymbolCollector that can be called from parallel.zig.
pub fn collectSymbolsFromSource(
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable,
    file_ctx: *FileContext,
    source: []const u8,
    language: *const ts.Language,
    tree: *ts.Tree,
) error{OutOfMemory}!void {
    var collector = SymbolCollector.init(allocator, sym_table, file_ctx, source, language);
    try collector.collect(tree);
}

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

var report_config = struct {
    composer: []const u8 = "",
    config: []const u8 = "",
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
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var check_boundaries_config = struct {
    config: []const u8 = "", // Path to .phpcma.json (required for monorepo mode)
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
}{};

var check_types_config = struct {
    config: []const u8 = "", // Path to .phpcma.json (required for monorepo mode)
    output: []const u8 = "",
    format: []const u8 = "text",
    verbose: bool = false,
    strict: bool = false,
    min_confidence: f64 = 0.0,
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
                                .help = "Output format: text, json, or dot (default: text)",
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
                                .help = "Output format: text, json, or dot (default: text)",
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
                                .long_name = "format",
                                .help = "Output format: text or json (default: text)",
                                .value_ref = r.mkRef(&called_before_config.format),
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
                    .{
                        .name = "check-boundaries",
                        .description = .{ .one_line = "Detect cross-project boundary calls in a monorepo" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json",
                                .value_ref = r.mkRef(&check_boundaries_config.config),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&check_boundaries_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text, json, or dot (default: text)",
                                .value_ref = r.mkRef(&check_boundaries_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&check_boundaries_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCheckBoundaries },
                        },
                    },
                    .{
                        .name = "check-types",
                        .description = .{ .one_line = "Analyze type violations at cross-project call sites" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json",
                                .value_ref = r.mkRef(&check_types_config.config),
                                .required = true,
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&check_types_config.output),
                            },
                            .{
                                .long_name = "format",
                                .help = "Output format: text or json (default: text)",
                                .value_ref = r.mkRef(&check_types_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&check_types_config.verbose),
                            },
                            .{
                                .long_name = "strict",
                                .help = "Strict mode: treat warnings as errors",
                                .value_ref = r.mkRef(&check_types_config.strict),
                            },
                            .{
                                .long_name = "min-confidence",
                                .help = "Minimum resolution confidence to report (0.0-1.0)",
                                .value_ref = r.mkRef(&check_types_config.min_confidence),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeCheckTypes },
                        },
                    },
                    .{
                        .name = "report",
                        .description = .{ .one_line = "Generate a unified analysis report (text, JSON, SARIF, or Checkstyle)" },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "composer",
                                .short_alias = 'c',
                                .help = "Path to composer.json (single project mode)",
                                .value_ref = r.mkRef(&report_config.composer),
                            },
                            .{
                                .long_name = "config",
                                .short_alias = 'g',
                                .help = "Path to .phpcma.json (monorepo mode)",
                                .value_ref = r.mkRef(&report_config.config),
                            },
                            .{
                                .long_name = "output",
                                .short_alias = 'o',
                                .help = "Output file (default: stdout)",
                                .value_ref = r.mkRef(&report_config.output),
                            },
                            .{
                                .long_name = "format",
                                .short_alias = 'f',
                                .help = "Output format: text, json, sarif, or checkstyle (default: text)",
                                .value_ref = r.mkRef(&report_config.format),
                            },
                            .{
                                .long_name = "verbose",
                                .short_alias = 'v',
                                .help = "Verbose output",
                                .value_ref = r.mkRef(&report_config.verbose),
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = analyzeReport },
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
    var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source, php_lang);
    try collector.collect(tree);

    // Analyze calls
    var analyzer = CallAnalyzer.init(allocator, &sym_table, &file_ctx, php_lang);
    defer analyzer.deinit();
    try analyzer.analyzeFile(tree, source, file_config.file);

    // Build project call graph
    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();
    try call_graph.addCalls(&analyzer);

    // Output
    const stdout: std.fs.File = std.fs.File.stdout();

    if (file_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(file_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, file_config.format, "json")) {
            try call_graph.toJson(out_file);
        } else if (std.mem.eql(u8, file_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{file_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, file_config.format, "json")) {
            try call_graph.toJson(stdout);
        } else if (std.mem.eql(u8, file_config.format, "dot")) {
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

    const stdout: std.fs.File = std.fs.File.stdout();

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

    // Pass 2: Collect symbols from all files (parallel)
    if (project_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
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

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    // Wrap config in a single-element slice for parallelSymbolCollect
    var configs_array = try allocator.alloc(ProjectConfig, 1);
    configs_array[0] = config;

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        configs_array,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (project_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeAll("\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (project_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel, reusing cached sources)
    if (project_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Output results
    if (project_config.verbose) {
        try stdout.writeAll("\n");
    }

    if (project_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(project_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, project_config.format, "json")) {
            try call_graph.toJson(out_file);
        } else if (std.mem.eql(u8, project_config.format, "dot")) {
            try call_graph.toDot(out_file);
        } else {
            try call_graph.toText(out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{project_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, project_config.format, "json")) {
            try call_graph.toJson(stdout);
        } else if (std.mem.eql(u8, project_config.format, "dot")) {
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

    const stdout: std.fs.File = std.fs.File.stdout();

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

    // Pass 2: Collect symbols from all files (parallel)
    if (called_before_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg2 = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg2);
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

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (called_before_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (called_before_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg2 = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg2);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

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

        if (std.mem.eql(u8, called_before_config.format, "json")) {
            try cb_analyzer.toJson(result, called_before_config.before, called_before_config.after, out_file);
        } else {
            try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{called_before_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, called_before_config.format, "json")) {
            try cb_analyzer.toJson(result, called_before_config.before, called_before_config.after, stdout);
        } else {
            try cb_analyzer.toText(result, called_before_config.before, called_before_config.after, stdout);
        }
    }

    // Exit with error code if constraint is violated
    if (!result.satisfied) {
        std.process.exit(1);
    }
}

fn analyzeCheckBoundaries() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout: std.fs.File = std.fs.File.stdout();

    // Pass 1: Parse .phpcma.json and discover files
    if (check_boundaries_config.verbose) {
        try stdout.writeAll("Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
    }

    var phpcma_config = config_parser.parseConfigFile(allocator, check_boundaries_config.config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    if (check_boundaries_config.verbose) {
        try config_parser.printConfig(&phpcma_config, stdout);
        try stdout.writeAll("\n");
    }

    const project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    const files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    if (check_boundaries_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files from {d} projects\n\n", .{ files.len, project_configs.len });
        try stdout.writeAll(msg);
    }

    // Pass 2: Collect symbols (parallel)
    if (check_boundaries_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
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

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (check_boundaries_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeAll("\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (check_boundaries_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (check_boundaries_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Boundary analysis
    if (check_boundaries_config.verbose) {
        try stdout.writeAll("Pass 5: Analyzing cross-project boundaries...\n\n");
    }

    var ba = boundary_analyzer.BoundaryAnalyzer.init(allocator, &call_graph, project_configs, &sym_table);
    const result = try ba.analyze();

    // Output results
    if (check_boundaries_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(check_boundaries_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, check_boundaries_config.format, "json")) {
            try ba.toJson(&result, out_file);
        } else if (std.mem.eql(u8, check_boundaries_config.format, "dot")) {
            try ba.toDot(&result, out_file);
        } else {
            try ba.toText(&result, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{check_boundaries_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, check_boundaries_config.format, "json")) {
            try ba.toJson(&result, stdout);
        } else if (std.mem.eql(u8, check_boundaries_config.format, "dot")) {
            try ba.toDot(&result, stdout);
        } else {
            try ba.toText(&result, stdout);
        }
    }
}

fn analyzeCheckTypes() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout: std.fs.File = std.fs.File.stdout();

    // Pass 1: Parse .phpcma.json and discover files
    if (check_types_config.verbose) {
        try stdout.writeAll("Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
    }

    var phpcma_config = config_parser.parseConfigFile(allocator, check_types_config.config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    if (check_types_config.verbose) {
        try config_parser.printConfig(&phpcma_config, stdout);
        try stdout.writeAll("\n");
    }

    const project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    const files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
        try stdout.writeAll(msg);
        return;
    };

    if (check_types_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files from {d} projects\n\n", .{ files.len, project_configs.len });
        try stdout.writeAll(msg);
    }

    // Pass 2: Collect symbols (parallel)
    if (check_types_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
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

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    if (check_types_config.verbose) {
        try sym_table.printStats(stdout);
        try stdout.writeAll("\n");
    }

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (check_types_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Analyze calls (parallel)
    if (check_types_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 4: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 5: Type violation analysis
    if (check_types_config.verbose) {
        try stdout.writeAll("Pass 5: Analyzing cross-project type violations...\n\n");
    }

    var tva = type_violation_analyzer.TypeViolationAnalyzer.init(allocator, &call_graph, project_configs, &sym_table);
    tva.min_confidence = @floatCast(check_types_config.min_confidence);
    tva.strict = check_types_config.strict;
    const result = try tva.analyze();

    // Output results
    if (check_types_config.output.len > 0) {
        const out_file = try std.fs.cwd().createFile(check_types_config.output, .{});
        defer out_file.close();

        if (std.mem.eql(u8, check_types_config.format, "json")) {
            try tva.toJson(&result, out_file);
        } else {
            try tva.toText(&result, out_file);
        }
        const msg = try std.fmt.allocPrint(allocator, "Output written to: {s}\n", .{check_types_config.output});
        try stdout.writeAll(msg);
    } else {
        if (std.mem.eql(u8, check_types_config.format, "json")) {
            try tva.toJson(&result, stdout);
        } else {
            try tva.toText(&result, stdout);
        }
    }

    // Exit with error code if there are errors (or warnings in strict mode)
    if (result.error_count > 0) {
        std.process.exit(1);
    }
    if (check_types_config.strict and result.warning_count > 0) {
        std.process.exit(1);
    }
}

fn analyzeReport() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer _ = arena.deinit();
    const allocator = arena.allocator();

    const stdout: std.fs.File = std.fs.File.stdout();

    // Validate input
    const has_composer = report_config.composer.len > 0;
    const has_config = report_config.config.len > 0;

    if (!has_composer and !has_config) {
        try stdout.writeAll("Error: Either --composer (-c) or --config (-g) must be specified\n");
        return;
    }

    if (has_composer and has_config) {
        try stdout.writeAll("Error: Cannot use both --composer (-c) and --config (-g) at the same time\n");
        return;
    }

    // Discover files
    var project_configs: []ProjectConfig = undefined;
    var files: []const []const u8 = undefined;

    if (has_config) {
        if (report_config.verbose) {
            try stdout.writeAll("Pass 1: Discovering files from .phpcma.json (monorepo mode)...\n");
        }

        var phpcma_config = config_parser.parseConfigFile(allocator, report_config.config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing .phpcma.json: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };

        if (report_config.verbose) {
            try config_parser.printConfig(&phpcma_config, stdout);
            try stdout.writeAll("\n");
        }

        project_configs = config_parser.parseDiscoveredProjects(allocator, &phpcma_config) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing projects: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };

        files = config_parser.discoverFilesFromConfigs(allocator, project_configs) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error discovering files: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };
    } else {
        if (report_config.verbose) {
            try stdout.writeAll("Pass 1: Discovering files from composer.json...\n");
        }

        const single_config = composer.parseComposerJson(allocator, report_config.composer) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Error parsing composer.json: {}\n", .{err});
            try stdout.writeAll(msg);
            return;
        };

        var configs_array = try allocator.alloc(ProjectConfig, 1);
        configs_array[0] = single_config;
        project_configs = configs_array;
        files = try composer.discoverFiles(allocator, &single_config);
    }

    if (report_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "Discovered {d} PHP files\n\n", .{files.len});
        try stdout.writeAll(msg);
    }

    // Pass 2: Collect symbols
    if (report_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 2: Collecting symbols ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
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

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer file_sources.deinit();

    try parallel.parallelSymbolCollect(
        allocator,
        files,
        project_configs,
        &sym_table,
        &file_contexts,
        &file_sources,
        &collectSymbolsFromSource,
    );

    // Register framework API stubs (Shopware/Symfony/Doctrine)
    try framework_stubs.registerFrameworkStubs(allocator, &sym_table);

    // Pass 3: Resolve inheritance
    if (report_config.verbose) {
        try stdout.writeAll("Pass 3: Resolving inheritance...\n");
    }

    try sym_table.resolveInheritance();

    // Pass 4: Return type checking
    if (report_config.verbose) {
        try stdout.writeAll("Pass 4: Checking return types...\n");
    }

    const php_lang = tree_sitter_php();
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(php_lang);

    var rt_checker = return_type_checker.ReturnTypeChecker.init(allocator, &sym_table, php_lang);
    defer rt_checker.deinit();

    // Iterate all classes, find methods by file, parse and check
    var class_it = sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const class = entry.value_ptr;
        var method_it = class.methods.iterator();
        while (method_it.next()) |m_entry| {
            const method = m_entry.value_ptr;
            const file_path = method.file_path;
            if (file_sources.get(file_path)) |source| {
                const tree = parser.parseString(source, null) orelse continue;
                defer tree.destroy();
                try rt_checker.analyzeMethod(method, class.fqcn, source, tree);
            }
        }
    }

    if (report_config.verbose) {
        const rt_result = rt_checker.result();
        const msg = try std.fmt.allocPrint(allocator, "  Methods analyzed: {d}, verified: {d}, uncertain: {d}, diagnostics: {d}\n\n", .{
            rt_result.methods_analyzed, rt_result.methods_verified, rt_result.methods_uncertain, rt_result.diagnostics.len,
        });
        try stdout.writeAll(msg);
    }

    // Pass 5: Analyze calls
    if (report_config.verbose) {
        const thread_count = parallel.getThreadCount(files.len);
        const msg = try std.fmt.allocPrint(allocator, "Pass 5: Analyzing calls ({d} threads)...\n", .{thread_count});
        try stdout.writeAll(msg);
    }

    var call_graph = ProjectCallGraph.init(allocator, &sym_table);
    defer call_graph.deinit();

    try parallel.parallelCallAnalysis(
        allocator,
        files,
        &file_sources,
        &file_contexts,
        &sym_table,
        &call_graph,
    );

    // Pass 6: Null safety analysis (per-file)
    if (report_config.verbose) {
        try stdout.writeAll("Pass 6: Analyzing null safety...\n");
    }

    const ns_parser = ts.Parser.create();
    defer ns_parser.destroy();
    try ns_parser.setLanguage(php_lang);

    var total_guarded: u32 = 0;
    var total_unguarded: u32 = 0;
    var null_violations = std.ArrayListUnmanaged(report.Violation){};
    defer null_violations.deinit(allocator);

    for (files) |file_path| {
        const source = file_sources.get(file_path) orelse continue;
        const file_ctx_ptr = file_contexts.getPtr(file_path) orelse continue;

        const tree = ns_parser.parseString(source, null) orelse continue;
        defer tree.destroy();

        var analyzer = null_safety.NullSafetyAnalyzer.init(allocator, &sym_table, file_ctx_ptr, php_lang);
        defer analyzer.deinit();

        const result = analyzer.analyzeFile(tree, source) catch continue;

        total_guarded += result.guarded_accesses;
        total_unguarded += result.unguarded_accesses;

        for (result.violations) |v| {
            const severity: report.Violation.Severity = switch (v.severity) {
                .definite => .err,
                .possible => .warning,
                .guarded => .note,
            };
            try null_violations.append(allocator, .{
                .severity = severity,
                .category = "null-safety",
                .file_path = file_path,
                .line = v.line,
                .message = v.message,
            });
        }
    }

    if (report_config.verbose) {
        const msg = try std.fmt.allocPrint(allocator, "  Guarded: {d}, Unguarded: {d}, Violations: {d}\n\n", .{ total_guarded, total_unguarded, null_violations.items.len });
        try stdout.writeAll(msg);
    }

    // Pass 7: Generate unified report
    if (report_config.verbose) {
        try stdout.writeAll("Pass 7: Generating unified report...\n\n");
    }

    var unified_report = report.UnifiedReport.init(allocator);
    defer unified_report.deinit();
    unified_report.populate(&sym_table, &call_graph);
    unified_report.coverage.total_files = files.len;

    // Merge return type checker results into report
    const rt_result = rt_checker.result();
    unified_report.type_checks.return_types.pass += rt_result.methods_verified;
    unified_report.type_checks.return_types.fail += rt_result.diagnostics.len;
    unified_report.type_checks.return_types.unchecked += rt_result.methods_uncertain;

    // Emit checker diagnostics as violations
    for (rt_result.diagnostics) |diag| {
        try unified_report.addViolation(.{
            .severity = .warning,
            .category = "return-type-mismatch",
            .file_path = diag.file_path,
            .line = diag.line,
            .message = try diag.format(allocator),
        });
    }

    // Populate null safety results from real analysis
    unified_report.type_checks.null_safety.pass = total_guarded;
    unified_report.type_checks.null_safety.fail = total_unguarded;
    unified_report.type_checks.null_safety.unchecked = 0;

    // Add null safety violations
    for (null_violations.items) |v| {
        try unified_report.addViolation(v);
    }

    // Output
    const out_file = if (report_config.output.len > 0) blk: {
        break :blk try std.fs.cwd().createFile(report_config.output, .{});
    } else stdout;

    defer {
        if (report_config.output.len > 0) {
            out_file.close();
        }
    }

    if (std.mem.eql(u8, report_config.format, "json")) {
        try unified_report.toJson(out_file);
    } else if (std.mem.eql(u8, report_config.format, "sarif")) {
        try unified_report.toSarif(out_file);
    } else if (std.mem.eql(u8, report_config.format, "checkstyle")) {
        try unified_report.toCheckstyle(out_file);
    } else {
        try unified_report.toText(out_file);
    }

    if (report_config.output.len > 0) {
        const msg = try std.fmt.allocPrint(allocator, "Report written to: {s}\n", .{report_config.output});
        try stdout.writeAll(msg);
    }
}

// ============================================================================
// Tests - SymbolCollector
// ============================================================================

fn parsePhp(_: std.mem.Allocator, source: []const u8) struct { *ts.Tree, *const ts.Language } {
    const parser = ts.Parser.create();
    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch unreachable;
    const tree = parser.parseString(source, null) orelse unreachable;
    return .{ tree, php_lang };
}

fn collectFromSource(allocator: std.mem.Allocator, source: []const u8) !struct { SymbolTable, FileContext } {
    const result = parsePhp(allocator, source);
    const tree = result[0];
    const php_lang = result[1];

    var sym_table = SymbolTable.init(allocator);
    var file_ctx = FileContext.init(allocator, "test.php");

    var collector = SymbolCollector.init(allocator, &sym_table, &file_ctx, source, php_lang);
    try collector.collect(tree);

    return .{ sym_table, file_ctx };
}

test "SymbolCollector: class extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class UserService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("UserService", class.?.name);
}

test "SymbolCollector: namespaced class" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App\\Service; class UserService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\Service\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("UserService", class.?.name);
}

test "SymbolCollector: extends" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App; class BaseService {} class UserService extends BaseService {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expectEqualStrings("App\\BaseService", class.?.extends.?);
}

test "SymbolCollector: implements" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php namespace App; interface Loggable {} class UserService implements Loggable {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.implements.len == 1);
    try std.testing.expectEqualStrings("App\\Loggable", class.?.implements[0]);
}

test "SymbolCollector: method extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class Foo { public function doStuff(): void {} }";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("doStuff");
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("doStuff", method.?.name);
}

test "SymbolCollector: method modifiers" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    private static function secretStatic(): void {}
        \\    protected final function protFinal(): void {}
        \\    abstract public function mustImpl(): void;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);

    const m1 = class.?.methods.get("secretStatic");
    try std.testing.expect(m1 != null);
    try std.testing.expect(m1.?.visibility == .private);
    try std.testing.expect(m1.?.is_static == true);

    const m2 = class.?.methods.get("protFinal");
    try std.testing.expect(m2 != null);
    try std.testing.expect(m2.?.visibility == .protected);
    try std.testing.expect(m2.?.is_final == true);

    const m3 = class.?.methods.get("mustImpl");
    try std.testing.expect(m3 != null);
    try std.testing.expect(m3.?.is_abstract == true);
}

test "SymbolCollector: parameter parsing" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class Foo { public function bar(string $name, int $age = 0): void {} }";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("bar");
    try std.testing.expect(method != null);
    try std.testing.expect(method.?.parameters.len == 2);
    try std.testing.expectEqualStrings("name", method.?.parameters[0].name);
    try std.testing.expectEqualStrings("age", method.?.parameters[1].name);
    try std.testing.expect(method.?.parameters[1].has_default == true);
}

test "SymbolCollector: property extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    private string $name;
        \\    protected static int $count;
        \\    public readonly string $id;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);

    const p1 = class.?.properties.get("name");
    try std.testing.expect(p1 != null);
    try std.testing.expect(p1.?.visibility == .private);

    const p2 = class.?.properties.get("count");
    try std.testing.expect(p2 != null);
    try std.testing.expect(p2.?.is_static == true);
    try std.testing.expect(p2.?.visibility == .protected);

    const p3 = class.?.properties.get("id");
    try std.testing.expect(p3 != null);
    try std.testing.expect(p3.?.is_readonly == true);
}

test "SymbolCollector: constructor promotion" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Dto {
        \\    public function __construct(
        \\        private readonly string $name,
        \\        protected int $age,
        \\    ) {}
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Dto");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("__construct");
    try std.testing.expect(method != null);
    try std.testing.expect(method.?.parameters.len == 2);
    try std.testing.expect(method.?.parameters[0].is_promoted == true);
    try std.testing.expect(method.?.parameters[1].is_promoted == true);
}

test "SymbolCollector: interface extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Contract;
        \\interface UserRepositoryInterface {
        \\    public function find(int $id): ?object;
        \\    public function save(object $user): void;
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const iface = result[0].getInterface("App\\Contract\\UserRepositoryInterface");
    try std.testing.expect(iface != null);
    try std.testing.expect(iface.?.methods.count() == 2);
    try std.testing.expect(iface.?.methods.contains("find"));
    try std.testing.expect(iface.?.methods.contains("save"));
}

test "SymbolCollector: trait extraction" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Concern;
        \\trait Timestampable {
        \\    private string $createdAt;
        \\    public function getCreatedAt(): string { return $this->createdAt; }
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const trait = result[0].getTrait("App\\Concern\\Timestampable");
    try std.testing.expect(trait != null);
    try std.testing.expect(trait.?.methods.contains("getCreatedAt"));
    try std.testing.expect(trait.?.properties.contains("createdAt"));
}

test "SymbolCollector: trait use" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App;
        \\trait Loggable { public function log(): void {} }
        \\class UserService { use Loggable; }
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("App\\UserService");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.uses.len == 1);
    try std.testing.expectEqualStrings("App\\Loggable", class.?.uses[0]);
}

test "SymbolCollector: use statements" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Service;
        \\use App\Repository\UserRepository;
        \\use App\Entity\User as UserEntity;
        \\class UserService {}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const ctx = &result[1];
    const repo_use = ctx.use_statements.get("UserRepository");
    try std.testing.expect(repo_use != null);
    try std.testing.expectEqualStrings("App\\Repository\\UserRepository", repo_use.?.fqcn);

    // Aliased use statement: "use App\Entity\User as UserEntity"
    // The key in use_statements is the short name resolved from fqcn
    const user_use = ctx.use_statements.get("UserEntity");
    try std.testing.expect(user_use != null);
    try std.testing.expectEqualStrings("UserEntity", user_use.?.fqcn);
}

test "SymbolCollector: PHPDoc on method" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php class Foo {
        \\    /** @return string */
        \\    public function getName(): string { return ''; }
        \\}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("Foo");
    try std.testing.expect(class != null);
    const method = class.?.methods.get("getName");
    try std.testing.expect(method != null);
    // PHPDoc return type should be parsed
    try std.testing.expect(method.?.phpdoc_return != null);
    try std.testing.expectEqualStrings("string", method.?.phpdoc_return.?.base_type);
}

test "SymbolCollector: multiple classes in file" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App;
        \\class First { public function a(): void {} }
        \\class Second { public function b(): void {} }
        \\class Third {}
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    try std.testing.expect(result[0].getClass("App\\First") != null);
    try std.testing.expect(result[0].getClass("App\\Second") != null);
    try std.testing.expect(result[0].getClass("App\\Third") != null);
    try std.testing.expect(result[0].classes.count() == 3);
}

test "SymbolCollector: standalone function" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php namespace App\Util;
        \\function formatDate(string $date): string { return $date; }
    ;
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const func = result[0].getFunction("App\\Util\\formatDate");
    try std.testing.expect(func != null);
    try std.testing.expectEqualStrings("formatDate", func.?.name);
    try std.testing.expect(func.?.parameters.len == 1);
    try std.testing.expectEqualStrings("date", func.?.parameters[0].name);
}

test "SymbolCollector: empty class" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source = "<?php class EmptyClass {}";
    var result = try collectFromSource(alloc, source);
    _ = &result;

    const class = result[0].getClass("EmptyClass");
    try std.testing.expect(class != null);
    try std.testing.expect(class.?.methods.count() == 0);
    try std.testing.expect(class.?.properties.count() == 0);
    try std.testing.expect(class.?.extends == null);
    try std.testing.expect(class.?.implements.len == 0);
    try std.testing.expect(class.?.uses.len == 0);
}
