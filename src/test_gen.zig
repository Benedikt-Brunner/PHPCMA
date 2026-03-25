const std = @import("std");

// ============================================================================
// PHP Code Generator for Property-Based Testing
// ============================================================================
//
// Generates random but valid PHP source code along with ground-truth
// expectations for the symbol table, call graph, inheritance, and dead-code
// analyses.  The generated PHP is guaranteed to be tree-sitter parseable.

// ============================================================================
// Data Structures
// ============================================================================

pub const PhpProjectSpec = struct {
    files: []const PhpFileSpec,
};

pub const PhpFileSpec = struct {
    namespace: ?[]const u8,
    use_statements: []const UseStatementSpec,
    classes: []const PhpClassSpec,
    functions: []const PhpFunctionSpec,
};

pub const UseStatementSpec = struct {
    fqcn: []const u8,
    alias: ?[]const u8,
};

pub const PhpClassSpec = struct {
    name: []const u8,
    namespace: ?[]const u8,
    extends: ?[]const u8,
    implements: []const []const u8,
    uses: []const []const u8,
    methods: []const PhpMethodSpec,
    properties: []const PhpPropertySpec,
    is_abstract: bool,
    is_final: bool,
};

pub const PhpMethodSpec = struct {
    name: []const u8,
    visibility: Visibility,
    is_static: bool,
    params: []const ParamSpec,
    return_type: ?[]const u8,
    body_calls: []const PhpCallSpec,
    body_assignments: []const AssignmentSpec,
};

pub const ParamSpec = struct {
    name: []const u8,
    type_name: ?[]const u8,
};

pub const AssignmentSpec = struct {
    var_name: []const u8,
    type_name: []const u8,
};

pub const PhpPropertySpec = struct {
    name: []const u8,
    visibility: Visibility,
    type_name: ?[]const u8,
    is_static: bool,
    is_readonly: bool,
};

pub const PhpCallSpec = struct {
    target_class: ?[]const u8,
    target_method: []const u8,
    via: CallVia,
    receiver_var_name: ?[]const u8,
};

pub const CallVia = enum {
    this,
    variable,
    static,
    new_call,
};

pub const Visibility = enum {
    public,
    protected,
    private,

    pub fn toPhp(self: Visibility) []const u8 {
        return switch (self) {
            .public => "public",
            .protected => "protected",
            .private => "private",
        };
    }
};

pub const PhpFunctionSpec = struct {
    name: []const u8,
    params: []const ParamSpec,
    return_type: ?[]const u8,
    body_calls: []const PhpCallSpec,
};

// ============================================================================
// Random Generation Config
// ============================================================================

pub const GenConfig = struct {
    num_files: u32 = 3,
    num_classes: u32 = 5,
    num_functions: u32 = 2,
    inheritance_depth: u32 = 2,
    interface_ratio: f32 = 0.2,
    call_density: u32 = 3,
    type_coverage_ratio: f32 = 0.8,
    methods_per_class: u32 = 3,
    properties_per_class: u32 = 2,
};

// ============================================================================
// Ground Truth Types
// ============================================================================

pub const SymbolKind = enum {
    class,
    interface,
    function,
    method,
    property,
};

pub const ExpectedSymbol = struct {
    fqn: []const u8,
    kind: SymbolKind,
    name: []const u8,
};

pub const ExpectedCall = struct {
    caller_fqn: []const u8,
    callee_name: []const u8,
    expected_target: ?[]const u8,
};

pub const ExpectedInheritance = struct {
    class_fqn: []const u8,
    parent_fqn: []const u8,
};

// ============================================================================
// PHP Code Generation
// ============================================================================

pub fn generatePhpFile(allocator: std.mem.Allocator, spec: PhpFileSpec) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("<?php\n\n");

    if (spec.namespace) |ns| {
        try w.print("namespace {s};\n\n", .{ns});
    }

    for (spec.use_statements) |use| {
        try w.print("use {s}", .{use.fqcn});
        if (use.alias) |alias| {
            try w.print(" as {s}", .{alias});
        }
        try w.writeAll(";\n");
    }
    if (spec.use_statements.len > 0) {
        try w.writeAll("\n");
    }

    for (spec.functions) |func| {
        try generateFunction(allocator, w, func);
        try w.writeAll("\n");
    }

    for (spec.classes) |class| {
        try generateClass(allocator, w, class);
        try w.writeAll("\n");
    }

    return try buf.toOwnedSlice(allocator);
}

fn generateClass(allocator: std.mem.Allocator, w: anytype, class: PhpClassSpec) !void {
    if (class.is_abstract) {
        try w.writeAll("abstract ");
    } else if (class.is_final) {
        try w.writeAll("final ");
    }

    try w.print("class {s}", .{class.name});

    if (class.extends) |parent| {
        try w.print(" extends {s}", .{parent});
    }

    if (class.implements.len > 0) {
        try w.writeAll(" implements ");
        for (class.implements, 0..) |iface, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}", .{iface});
        }
    }

    try w.writeAll("\n{\n");

    for (class.uses) |trait_name| {
        try w.print("    use {s};\n", .{trait_name});
    }
    if (class.uses.len > 0) {
        try w.writeAll("\n");
    }

    for (class.properties) |prop| {
        try w.print("    {s}", .{prop.visibility.toPhp()});
        if (prop.is_static) try w.writeAll(" static");
        if (prop.is_readonly) try w.writeAll(" readonly");
        if (prop.type_name) |t| {
            try w.print(" {s}", .{t});
        }
        try w.print(" ${s};\n", .{prop.name});
    }
    if (class.properties.len > 0) {
        try w.writeAll("\n");
    }

    for (class.methods) |method| {
        try generateMethod(allocator, w, method, class.is_abstract);
        try w.writeAll("\n");
    }

    try w.writeAll("}\n");
}

fn generateMethod(allocator: std.mem.Allocator, w: anytype, method: PhpMethodSpec, class_is_abstract: bool) !void {
    try w.print("    {s}", .{method.visibility.toPhp()});
    if (method.is_static) try w.writeAll(" static");

    try w.print(" function {s}(", .{method.name});

    for (method.params, 0..) |param, i| {
        if (i > 0) try w.writeAll(", ");
        if (param.type_name) |t| {
            try w.print("{s} ", .{t});
        }
        try w.print("${s}", .{param.name});
    }

    try w.writeAll(")");

    if (method.return_type) |rt| {
        try w.print(": {s}", .{rt});
    }

    if (class_is_abstract and method.body_calls.len == 0 and method.body_assignments.len == 0) {
        try w.writeAll(";\n");
        return;
    }

    try w.writeAll("\n    {\n");
    const body = try generateMethodBody(allocator, method);
    defer allocator.free(body);
    try w.writeAll(body);
    try w.writeAll("    }\n");
}

pub fn generateMethodBody(allocator: std.mem.Allocator, method: PhpMethodSpec) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    for (method.body_assignments) |assign| {
        try w.print("        ${s} = new {s}();\n", .{ assign.var_name, assign.type_name });
    }

    for (method.body_calls) |call| {
        try w.writeAll("        ");
        switch (call.via) {
            .this => {
                if (call.target_method.len > 0) {
                    try w.print("$this->{s}();\n", .{call.target_method});
                }
            },
            .variable => {
                if (call.receiver_var_name) |var_name| {
                    try w.print("${s}->{s}();\n", .{ var_name, call.target_method });
                }
            },
            .static => {
                if (call.target_class) |cls| {
                    try w.print("{s}::{s}();\n", .{ cls, call.target_method });
                }
            },
            .new_call => {
                if (call.target_class) |cls| {
                    try w.print("(new {s}())->{s}();\n", .{ cls, call.target_method });
                }
            },
        }
    }

    if (method.body_assignments.len == 0 and method.body_calls.len == 0) {
        try w.writeAll("        // no-op\n");
    }

    return try buf.toOwnedSlice(allocator);
}

fn generateFunction(_: std.mem.Allocator, w: anytype, func: PhpFunctionSpec) !void {
    try w.print("function {s}(", .{func.name});

    for (func.params, 0..) |param, i| {
        if (i > 0) try w.writeAll(", ");
        if (param.type_name) |t| {
            try w.print("{s} ", .{t});
        }
        try w.print("${s}", .{param.name});
    }

    try w.writeAll(")");

    if (func.return_type) |rt| {
        try w.print(": {s}", .{rt});
    }

    try w.writeAll("\n{\n");

    for (func.body_calls) |call| {
        try w.writeAll("    ");
        switch (call.via) {
            .static => {
                if (call.target_class) |cls| {
                    try w.print("{s}::{s}();\n", .{ cls, call.target_method });
                }
            },
            .new_call => {
                if (call.target_class) |cls| {
                    try w.print("(new {s}())->{s}();\n", .{ cls, call.target_method });
                }
            },
            .variable => {
                if (call.receiver_var_name) |var_name| {
                    try w.print("${s}->{s}();\n", .{ var_name, call.target_method });
                }
            },
            .this => {
                try w.print("{s}();\n", .{call.target_method});
            },
        }
    }

    if (func.body_calls.len == 0) {
        try w.writeAll("    // no-op\n");
    }

    try w.writeAll("}\n");
}

// ============================================================================
// Ground Truth Extraction
// ============================================================================

fn classFqn(allocator: std.mem.Allocator, namespace: ?[]const u8, name: []const u8) ![]const u8 {
    if (namespace) |ns| {
        return try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ ns, name });
    }
    return try allocator.dupe(u8, name);
}

pub fn expectedSymbols(allocator: std.mem.Allocator, project: PhpProjectSpec) ![]ExpectedSymbol {
    var symbols: std.ArrayListUnmanaged(ExpectedSymbol) = .empty;

    for (project.files) |file| {
        for (file.classes) |class| {
            const ns = class.namespace orelse file.namespace;
            const fqn = try classFqn(allocator, ns, class.name);

            try symbols.append(allocator, .{
                .fqn = fqn,
                .kind = .class,
                .name = class.name,
            });

            for (class.methods) |method| {
                const method_fqn = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ fqn, method.name });
                try symbols.append(allocator, .{
                    .fqn = method_fqn,
                    .kind = .method,
                    .name = method.name,
                });
            }

            for (class.properties) |prop| {
                const prop_fqn = try std.fmt.allocPrint(allocator, "{s}::${s}", .{ fqn, prop.name });
                try symbols.append(allocator, .{
                    .fqn = prop_fqn,
                    .kind = .property,
                    .name = prop.name,
                });
            }
        }

        for (file.functions) |func| {
            const fqn = try classFqn(allocator, file.namespace, func.name);
            try symbols.append(allocator, .{
                .fqn = fqn,
                .kind = .function,
                .name = func.name,
            });
        }
    }

    return try symbols.toOwnedSlice(allocator);
}

pub fn expectedCalls(allocator: std.mem.Allocator, project: PhpProjectSpec) ![]ExpectedCall {
    var calls: std.ArrayListUnmanaged(ExpectedCall) = .empty;

    for (project.files) |file| {
        for (file.classes) |class| {
            const ns = class.namespace orelse file.namespace;
            const class_fqn = try classFqn(allocator, ns, class.name);

            for (class.methods) |method| {
                const caller_fqn = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ class_fqn, method.name });

                for (method.body_calls) |call| {
                    const expected_target = try resolveCallTarget(allocator, call, class_fqn, ns);
                    try calls.append(allocator, .{
                        .caller_fqn = caller_fqn,
                        .callee_name = call.target_method,
                        .expected_target = expected_target,
                    });
                }
            }
        }

        for (file.functions) |func| {
            const caller_fqn = try classFqn(allocator, file.namespace, func.name);

            for (func.body_calls) |call| {
                const expected_target = try resolveCallTarget(allocator, call, null, file.namespace);
                try calls.append(allocator, .{
                    .caller_fqn = caller_fqn,
                    .callee_name = call.target_method,
                    .expected_target = expected_target,
                });
            }
        }
    }

    return try calls.toOwnedSlice(allocator);
}

fn resolveCallTarget(
    allocator: std.mem.Allocator,
    call: PhpCallSpec,
    class_fqn: ?[]const u8,
    namespace: ?[]const u8,
) !?[]const u8 {
    switch (call.via) {
        .this => {
            if (class_fqn) |cfqn| {
                return try std.fmt.allocPrint(allocator, "{s}::{s}", .{ cfqn, call.target_method });
            }
            return null;
        },
        .static, .new_call => {
            if (call.target_class) |cls| {
                const resolved_class = try classFqn(allocator, namespace, cls);
                return try std.fmt.allocPrint(allocator, "{s}::{s}", .{ resolved_class, call.target_method });
            }
            return null;
        },
        .variable => {
            return null;
        },
    }
}

pub fn expectedInheritance(allocator: std.mem.Allocator, project: PhpProjectSpec) ![]ExpectedInheritance {
    var result: std.ArrayListUnmanaged(ExpectedInheritance) = .empty;

    for (project.files) |file| {
        for (file.classes) |class| {
            if (class.extends) |parent| {
                const ns = class.namespace orelse file.namespace;
                const class_fqn = try classFqn(allocator, ns, class.name);
                const parent_fqn = try classFqn(allocator, ns, parent);

                try result.append(allocator, .{
                    .class_fqn = class_fqn,
                    .parent_fqn = parent_fqn,
                });
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

pub fn expectedAlive(allocator: std.mem.Allocator, project: PhpProjectSpec) ![][]const u8 {
    var alive: std.ArrayListUnmanaged([]const u8) = .empty;
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();

    // Collect all referenced symbols from calls
    for (project.files) |file| {
        for (file.classes) |class| {
            const ns = class.namespace orelse file.namespace;
            const class_fqn = try classFqn(allocator, ns, class.name);

            for (class.methods) |method| {
                for (method.body_calls) |call| {
                    const target = try resolveCallTarget(allocator, call, class_fqn, ns);
                    if (target) |t| {
                        try referenced.put(t, {});
                        // The class containing the target method is also alive
                        if (call.target_class) |cls| {
                            const tcls = try classFqn(allocator, ns, cls);
                            try referenced.put(tcls, {});
                        }
                        if (call.via == .this) {
                            try referenced.put(class_fqn, {});
                        }
                    }
                }

                for (method.body_assignments) |assign| {
                    const tcls = try classFqn(allocator, ns, assign.type_name);
                    try referenced.put(tcls, {});
                }
            }

            // Inheritance references
            if (class.extends) |parent| {
                const parent_fqn = try classFqn(allocator, ns, parent);
                try referenced.put(parent_fqn, {});
                try referenced.put(class_fqn, {});
            }
            for (class.implements) |iface| {
                const iface_fqn = try classFqn(allocator, ns, iface);
                try referenced.put(iface_fqn, {});
                try referenced.put(class_fqn, {});
            }
        }

        for (file.functions) |func| {
            for (func.body_calls) |call| {
                const target = try resolveCallTarget(allocator, call, null, file.namespace);
                if (target) |t| {
                    try referenced.put(t, {});
                    if (call.target_class) |cls| {
                        const tcls = try classFqn(allocator, file.namespace, cls);
                        try referenced.put(tcls, {});
                    }
                }
            }
        }
    }

    // Collect all symbols that are referenced
    const all_symbols = try expectedSymbols(allocator, project);
    for (all_symbols) |sym| {
        if (referenced.contains(sym.fqn)) {
            try alive.append(allocator, sym.fqn);
        }
    }

    return try alive.toOwnedSlice(allocator);
}

pub fn expectedDead(allocator: std.mem.Allocator, project: PhpProjectSpec) ![][]const u8 {
    var dead: std.ArrayListUnmanaged([]const u8) = .empty;

    const alive_list = try expectedAlive(allocator, project);
    var alive_set = std.StringHashMap(void).init(allocator);
    defer alive_set.deinit();
    for (alive_list) |a| {
        try alive_set.put(a, {});
    }

    const all_symbols = try expectedSymbols(allocator, project);
    for (all_symbols) |sym| {
        if (!alive_set.contains(sym.fqn)) {
            try dead.append(allocator, sym.fqn);
        }
    }

    return try dead.toOwnedSlice(allocator);
}

// ============================================================================
// Random Project Generation
// ============================================================================

const class_name_pool = [_][]const u8{
    "UserService",     "OrderManager",     "PaymentGateway",  "Logger",
    "Cache",           "Router",           "Validator",       "Formatter",
    "Repository",      "Controller",       "Middleware",      "EventHandler",
    "Serializer",      "Authenticator",    "Mailer",          "Queue",
    "DatabaseDriver",  "SessionManager",   "ConfigLoader",    "TaskRunner",
};

const method_name_pool = [_][]const u8{
    "handle",    "process",    "execute",   "validate",  "transform",
    "serialize", "deserialize", "connect",  "disconnect", "send",
    "receive",   "build",      "create",    "update",    "delete",
    "find",      "findAll",    "save",      "load",      "render",
};

const property_name_pool = [_][]const u8{
    "name",     "value",    "config",   "items",    "status",
    "count",    "logger",   "cache",    "driver",   "handler",
};

const type_pool = [_][]const u8{
    "string", "int", "float", "bool", "array", "void",
};

const namespace_pool = [_][]const u8{
    "App\\Services",      "App\\Models",    "App\\Controllers",
    "App\\Repositories",  "App\\Events",    "App\\Http",
};

pub fn generateRandomProject(allocator: std.mem.Allocator, rng: std.Random, config: GenConfig) !PhpProjectSpec {
    var files: std.ArrayListUnmanaged(PhpFileSpec) = .empty;

    // Create class names first so we can reference them
    var all_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var class_namespaces: std.ArrayListUnmanaged(?[]const u8) = .empty;

    const num_classes = @min(config.num_classes, class_name_pool.len);
    for (0..num_classes) |i| {
        try all_class_names.append(allocator, class_name_pool[i]);
        const ns = namespace_pool[rng.intRangeAtMost(usize, 0, namespace_pool.len - 1)];
        try class_namespaces.append(allocator, ns);
    }

    // Distribute classes across files
    const classes_per_file = @max(1, num_classes / config.num_files);
    var class_idx: usize = 0;

    for (0..config.num_files) |file_i| {
        var file_classes: std.ArrayListUnmanaged(PhpClassSpec) = .empty;
        var file_functions: std.ArrayListUnmanaged(PhpFunctionSpec) = .empty;
        var file_namespace: ?[]const u8 = null;

        const end = @min(class_idx + classes_per_file, all_class_names.items.len);
        if (file_i == config.num_files - 1) {
            // Last file gets remaining classes
            const actual_end = all_class_names.items.len;
            for (class_idx..actual_end) |ci| {
                const class = try generateRandomClass(
                    allocator,
                    rng,
                    config,
                    all_class_names.items[ci],
                    class_namespaces.items[ci],
                    all_class_names.items,
                    class_namespaces.items,
                    ci,
                );
                if (file_namespace == null) file_namespace = class_namespaces.items[ci];
                try file_classes.append(allocator, class);
            }
        } else {
            for (class_idx..end) |ci| {
                const class = try generateRandomClass(
                    allocator,
                    rng,
                    config,
                    all_class_names.items[ci],
                    class_namespaces.items[ci],
                    all_class_names.items,
                    class_namespaces.items,
                    ci,
                );
                if (file_namespace == null) file_namespace = class_namespaces.items[ci];
                try file_classes.append(allocator, class);
            }
        }
        class_idx = end;

        // Add standalone functions to the first file
        if (file_i == 0) {
            for (0..@min(config.num_functions, 2)) |fi| {
                const func = try generateRandomFunction(allocator, rng, config, fi, all_class_names.items, class_namespaces.items);
                try file_functions.append(allocator, func);
            }
        }

        try files.append(allocator, .{
            .namespace = file_namespace,
            .use_statements = &.{},
            .classes = try file_classes.toOwnedSlice(allocator),
            .functions = try file_functions.toOwnedSlice(allocator),
        });
    }

    return .{
        .files = try files.toOwnedSlice(allocator),
    };
}

fn generateRandomClass(
    allocator: std.mem.Allocator,
    rng: std.Random,
    config: GenConfig,
    name: []const u8,
    namespace: ?[]const u8,
    all_names: []const []const u8,
    all_namespaces: []const ?[]const u8,
    self_idx: usize,
) !PhpClassSpec {
    // Inheritance: maybe extend a previous class
    var extends: ?[]const u8 = null;
    if (self_idx > 0 and config.inheritance_depth > 0 and rng.float(f32) < 0.3) {
        const parent_idx = rng.intRangeAtMost(usize, 0, self_idx - 1);
        // Only extend if in same namespace (simplification)
        if (namespace != null and all_namespaces[parent_idx] != null) {
            if (std.mem.eql(u8, namespace.?, all_namespaces[parent_idx].?)) {
                extends = all_names[parent_idx];
            }
        }
    }

    const is_abstract = rng.float(f32) < 0.15;

    // Methods
    var methods: std.ArrayListUnmanaged(PhpMethodSpec) = .empty;
    const num_methods = @min(config.methods_per_class, method_name_pool.len);
    for (0..num_methods) |mi| {
        const method = try generateRandomMethod(allocator, rng, config, mi, name, namespace, all_names, all_namespaces);
        try methods.append(allocator, method);
    }

    // Properties
    var properties: std.ArrayListUnmanaged(PhpPropertySpec) = .empty;
    const num_props = @min(config.properties_per_class, property_name_pool.len);
    for (0..num_props) |pi| {
        const prop = generateRandomProperty(rng, config, pi);
        try properties.append(allocator, prop);
    }

    return .{
        .name = name,
        .namespace = namespace,
        .extends = extends,
        .implements = &.{},
        .uses = &.{},
        .methods = try methods.toOwnedSlice(allocator),
        .properties = try properties.toOwnedSlice(allocator),
        .is_abstract = is_abstract,
        .is_final = if (is_abstract) false else rng.float(f32) < 0.1,
    };
}

fn generateRandomMethod(
    allocator: std.mem.Allocator,
    rng: std.Random,
    config: GenConfig,
    method_idx: usize,
    class_name: []const u8,
    namespace: ?[]const u8,
    all_names: []const []const u8,
    all_namespaces: []const ?[]const u8,
) !PhpMethodSpec {
    _ = class_name;

    // Params
    var params: std.ArrayListUnmanaged(ParamSpec) = .empty;
    const num_params = rng.intRangeAtMost(usize, 0, 2);
    for (0..num_params) |pi| {
        const param_name = if (pi == 0) "arg1" else "arg2";
        const has_type = rng.float(f32) < config.type_coverage_ratio;
        try params.append(allocator, .{
            .name = param_name,
            .type_name = if (has_type) type_pool[rng.intRangeAtMost(usize, 0, type_pool.len - 1)] else null,
        });
    }

    // Return type
    const has_return = rng.float(f32) < config.type_coverage_ratio;
    const return_type: ?[]const u8 = if (has_return) type_pool[rng.intRangeAtMost(usize, 0, type_pool.len - 1)] else null;

    // Calls
    var body_calls: std.ArrayListUnmanaged(PhpCallSpec) = .empty;
    const num_calls = rng.intRangeAtMost(usize, 0, config.call_density);
    for (0..num_calls) |_| {
        const call = generateRandomCall(rng, namespace, all_names, all_namespaces);
        try body_calls.append(allocator, call);
    }

    // Visibility
    const vis_roll = rng.float(f32);
    const vis: Visibility = if (vis_roll < 0.7) .public else if (vis_roll < 0.9) .protected else .private;

    return .{
        .name = method_name_pool[method_idx],
        .visibility = vis,
        .is_static = rng.float(f32) < 0.15,
        .params = try params.toOwnedSlice(allocator),
        .return_type = return_type,
        .body_calls = try body_calls.toOwnedSlice(allocator),
        .body_assignments = &.{},
    };
}

fn generateRandomCall(
    rng: std.Random,
    namespace: ?[]const u8,
    all_names: []const []const u8,
    all_namespaces: []const ?[]const u8,
) PhpCallSpec {
    const target_method = method_name_pool[rng.intRangeAtMost(usize, 0, method_name_pool.len - 1)];
    const via_roll = rng.float(f32);

    if (via_roll < 0.4) {
        // $this-> call
        return .{
            .target_class = null,
            .target_method = target_method,
            .via = .this,
            .receiver_var_name = null,
        };
    } else if (via_roll < 0.7) {
        // Static call to a class in the same namespace
        const target_idx = rng.intRangeAtMost(usize, 0, all_names.len - 1);
        const target_ns = all_namespaces[target_idx];
        // Only reference by short name if same namespace
        if (namespace != null and target_ns != null and std.mem.eql(u8, namespace.?, target_ns.?)) {
            return .{
                .target_class = all_names[target_idx],
                .target_method = target_method,
                .via = .static,
                .receiver_var_name = null,
            };
        }
        // Fall back to $this
        return .{
            .target_class = null,
            .target_method = target_method,
            .via = .this,
            .receiver_var_name = null,
        };
    } else {
        // new Class()->method()
        const target_idx = rng.intRangeAtMost(usize, 0, all_names.len - 1);
        const target_ns = all_namespaces[target_idx];
        if (namespace != null and target_ns != null and std.mem.eql(u8, namespace.?, target_ns.?)) {
            return .{
                .target_class = all_names[target_idx],
                .target_method = target_method,
                .via = .new_call,
                .receiver_var_name = null,
            };
        }
        return .{
            .target_class = null,
            .target_method = target_method,
            .via = .this,
            .receiver_var_name = null,
        };
    }
}

fn generateRandomProperty(rng: std.Random, config: GenConfig, prop_idx: usize) PhpPropertySpec {
    const vis_roll = rng.float(f32);
    const vis: Visibility = if (vis_roll < 0.6) .public else if (vis_roll < 0.85) .protected else .private;
    const has_type = rng.float(f32) < config.type_coverage_ratio;

    return .{
        .name = property_name_pool[prop_idx],
        .visibility = vis,
        .type_name = if (has_type) type_pool[rng.intRangeAtMost(usize, 0, type_pool.len - 1)] else null,
        .is_static = rng.float(f32) < 0.1,
        .is_readonly = rng.float(f32) < 0.15,
    };
}

fn generateRandomFunction(
    allocator: std.mem.Allocator,
    rng: std.Random,
    config: GenConfig,
    func_idx: usize,
    all_names: []const []const u8,
    all_namespaces: []const ?[]const u8,
) !PhpFunctionSpec {
    const name = if (func_idx == 0) "helper_run" else "helper_init";

    var params: std.ArrayListUnmanaged(ParamSpec) = .empty;
    const has_type = rng.float(f32) < config.type_coverage_ratio;
    try params.append(allocator, .{
        .name = "input",
        .type_name = if (has_type) "string" else null,
    });

    var body_calls: std.ArrayListUnmanaged(PhpCallSpec) = .empty;
    if (config.call_density > 0 and all_names.len > 0) {
        const call = generateRandomCall(rng, all_namespaces[0], all_names, all_namespaces);
        // Only keep static/new_call for top-level functions
        if (call.via == .static or call.via == .new_call) {
            try body_calls.append(allocator, call);
        }
    }

    return .{
        .name = name,
        .params = try params.toOwnedSlice(allocator),
        .return_type = if (rng.float(f32) < config.type_coverage_ratio) "void" else null,
        .body_calls = try body_calls.toOwnedSlice(allocator),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "generatePhpFile: simple class with method" {
    const allocator = std.testing.allocator;

    const spec = PhpFileSpec{
        .namespace = "App\\Models",
        .use_statements = &.{},
        .classes = &.{PhpClassSpec{
            .name = "User",
            .namespace = null,
            .extends = null,
            .implements = &.{},
            .uses = &.{},
            .methods = &.{PhpMethodSpec{
                .name = "getName",
                .visibility = .public,
                .is_static = false,
                .params = &.{},
                .return_type = "string",
                .body_calls = &.{},
                .body_assignments = &.{},
            }},
            .properties = &.{PhpPropertySpec{
                .name = "name",
                .visibility = .private,
                .type_name = "string",
                .is_static = false,
                .is_readonly = false,
            }},
            .is_abstract = false,
            .is_final = false,
        }},
        .functions = &.{},
    };

    const php = try generatePhpFile(allocator, spec);
    defer allocator.free(php);

    try std.testing.expect(std.mem.indexOf(u8, php, "<?php") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "namespace App\\Models;") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "class User") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "public function getName()") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, ": string") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "private string $name;") != null);
}

test "generatePhpFile: class with inheritance and use" {
    const allocator = std.testing.allocator;

    const spec = PhpFileSpec{
        .namespace = "App\\Services",
        .use_statements = &.{UseStatementSpec{
            .fqcn = "App\\Models\\User",
            .alias = null,
        }},
        .classes = &.{PhpClassSpec{
            .name = "UserService",
            .namespace = null,
            .extends = "BaseService",
            .implements = &.{"ServiceInterface"},
            .uses = &.{"LogTrait"},
            .methods = &.{},
            .properties = &.{},
            .is_abstract = false,
            .is_final = true,
        }},
        .functions = &.{},
    };

    const php = try generatePhpFile(allocator, spec);
    defer allocator.free(php);

    try std.testing.expect(std.mem.indexOf(u8, php, "use App\\Models\\User;") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "final class UserService extends BaseService implements ServiceInterface") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "use LogTrait;") != null);
}

test "generatePhpFile: method with calls" {
    const allocator = std.testing.allocator;

    const spec = PhpFileSpec{
        .namespace = null,
        .use_statements = &.{},
        .classes = &.{PhpClassSpec{
            .name = "Handler",
            .namespace = null,
            .extends = null,
            .implements = &.{},
            .uses = &.{},
            .methods = &.{PhpMethodSpec{
                .name = "run",
                .visibility = .public,
                .is_static = false,
                .params = &.{ParamSpec{ .name = "input", .type_name = "string" }},
                .return_type = "void",
                .body_calls = &.{
                    PhpCallSpec{ .target_class = null, .target_method = "validate", .via = .this, .receiver_var_name = null },
                    PhpCallSpec{ .target_class = "Logger", .target_method = "info", .via = .static, .receiver_var_name = null },
                    PhpCallSpec{ .target_class = "Worker", .target_method = "process", .via = .new_call, .receiver_var_name = null },
                },
                .body_assignments = &.{AssignmentSpec{ .var_name = "svc", .type_name = "Service" }},
            }},
            .properties = &.{},
            .is_abstract = false,
            .is_final = false,
        }},
        .functions = &.{},
    };

    const php = try generatePhpFile(allocator, spec);
    defer allocator.free(php);

    try std.testing.expect(std.mem.indexOf(u8, php, "$this->validate()") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "Logger::info()") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "(new Worker())->process()") != null);
    try std.testing.expect(std.mem.indexOf(u8, php, "$svc = new Service()") != null);
}

test "expectedSymbols: returns correct symbols for project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project = PhpProjectSpec{
        .files = &.{PhpFileSpec{
            .namespace = "App",
            .use_statements = &.{},
            .classes = &.{PhpClassSpec{
                .name = "Foo",
                .namespace = null,
                .extends = null,
                .implements = &.{},
                .uses = &.{},
                .methods = &.{PhpMethodSpec{
                    .name = "bar",
                    .visibility = .public,
                    .is_static = false,
                    .params = &.{},
                    .return_type = null,
                    .body_calls = &.{},
                    .body_assignments = &.{},
                }},
                .properties = &.{PhpPropertySpec{
                    .name = "baz",
                    .visibility = .public,
                    .type_name = "int",
                    .is_static = false,
                    .is_readonly = false,
                }},
                .is_abstract = false,
                .is_final = false,
            }},
            .functions = &.{PhpFunctionSpec{
                .name = "helper",
                .params = &.{},
                .return_type = null,
                .body_calls = &.{},
            }},
        }},
    };

    const symbols = try expectedSymbols(allocator, project);

    try std.testing.expectEqual(@as(usize, 4), symbols.len);

    // Class
    try std.testing.expectEqualStrings("App\\Foo", symbols[0].fqn);
    try std.testing.expectEqual(SymbolKind.class, symbols[0].kind);

    // Method
    try std.testing.expectEqualStrings("App\\Foo::bar", symbols[1].fqn);
    try std.testing.expectEqual(SymbolKind.method, symbols[1].kind);

    // Property
    try std.testing.expectEqualStrings("App\\Foo::$baz", symbols[2].fqn);
    try std.testing.expectEqual(SymbolKind.property, symbols[2].kind);

    // Function
    try std.testing.expectEqualStrings("App\\helper", symbols[3].fqn);
    try std.testing.expectEqual(SymbolKind.function, symbols[3].kind);
}

test "expectedCalls: this and static calls resolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project = PhpProjectSpec{
        .files = &.{PhpFileSpec{
            .namespace = "App",
            .use_statements = &.{},
            .classes = &.{PhpClassSpec{
                .name = "Svc",
                .namespace = null,
                .extends = null,
                .implements = &.{},
                .uses = &.{},
                .methods = &.{PhpMethodSpec{
                    .name = "run",
                    .visibility = .public,
                    .is_static = false,
                    .params = &.{},
                    .return_type = null,
                    .body_calls = &.{
                        PhpCallSpec{ .target_class = null, .target_method = "validate", .via = .this, .receiver_var_name = null },
                        PhpCallSpec{ .target_class = "Helper", .target_method = "go", .via = .static, .receiver_var_name = null },
                    },
                    .body_assignments = &.{},
                }},
                .properties = &.{},
                .is_abstract = false,
                .is_final = false,
            }},
            .functions = &.{},
        }},
    };

    const calls = try expectedCalls(allocator, project);

    try std.testing.expectEqual(@as(usize, 2), calls.len);

    // $this->validate() resolves to App\Svc::validate
    try std.testing.expectEqualStrings("App\\Svc::run", calls[0].caller_fqn);
    try std.testing.expectEqualStrings("App\\Svc::validate", calls[0].expected_target.?);

    // Helper::go() resolves to App\Helper::go
    try std.testing.expectEqualStrings("App\\Helper::go", calls[1].expected_target.?);
}

test "expectedInheritance: parent chain extracted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project = PhpProjectSpec{
        .files = &.{PhpFileSpec{
            .namespace = "App",
            .use_statements = &.{},
            .classes = &.{
                PhpClassSpec{
                    .name = "Base",
                    .namespace = null,
                    .extends = null,
                    .implements = &.{},
                    .uses = &.{},
                    .methods = &.{},
                    .properties = &.{},
                    .is_abstract = true,
                    .is_final = false,
                },
                PhpClassSpec{
                    .name = "Child",
                    .namespace = null,
                    .extends = "Base",
                    .implements = &.{},
                    .uses = &.{},
                    .methods = &.{},
                    .properties = &.{},
                    .is_abstract = false,
                    .is_final = false,
                },
            },
            .functions = &.{},
        }},
    };

    const inh = try expectedInheritance(allocator, project);

    try std.testing.expectEqual(@as(usize, 1), inh.len);
    try std.testing.expectEqualStrings("App\\Child", inh[0].class_fqn);
    try std.testing.expectEqualStrings("App\\Base", inh[0].parent_fqn);
}

test "expectedDead: unreferenced symbols are dead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project = PhpProjectSpec{
        .files = &.{PhpFileSpec{
            .namespace = "App",
            .use_statements = &.{},
            .classes = &.{
                PhpClassSpec{
                    .name = "Used",
                    .namespace = null,
                    .extends = null,
                    .implements = &.{},
                    .uses = &.{},
                    .methods = &.{PhpMethodSpec{
                        .name = "action",
                        .visibility = .public,
                        .is_static = false,
                        .params = &.{},
                        .return_type = null,
                        .body_calls = &.{},
                        .body_assignments = &.{},
                    }},
                    .properties = &.{},
                    .is_abstract = false,
                    .is_final = false,
                },
                PhpClassSpec{
                    .name = "Caller",
                    .namespace = null,
                    .extends = null,
                    .implements = &.{},
                    .uses = &.{},
                    .methods = &.{PhpMethodSpec{
                        .name = "invoke",
                        .visibility = .public,
                        .is_static = false,
                        .params = &.{},
                        .return_type = null,
                        .body_calls = &.{PhpCallSpec{
                            .target_class = "Used",
                            .target_method = "action",
                            .via = .new_call,
                            .receiver_var_name = null,
                        }},
                        .body_assignments = &.{},
                    }},
                    .properties = &.{},
                    .is_abstract = false,
                    .is_final = false,
                },
            },
            .functions = &.{},
        }},
    };

    const dead = try expectedDead(allocator, project);

    // Caller::invoke makes Used::action alive, plus Used class alive.
    // Caller class itself has no references, and Caller::invoke has none either.
    // So dead should include: App\Caller, App\Caller::invoke
    var found_caller = false;
    var found_invoke = false;
    for (dead) |d| {
        if (std.mem.eql(u8, d, "App\\Caller")) found_caller = true;
        if (std.mem.eql(u8, d, "App\\Caller::invoke")) found_invoke = true;
    }
    try std.testing.expect(found_caller);
    try std.testing.expect(found_invoke);
}

test "generateRandomProject: produces non-empty project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const project = try generateRandomProject(allocator, rng, .{
        .num_files = 2,
        .num_classes = 4,
        .num_functions = 1,
        .methods_per_class = 2,
        .properties_per_class = 1,
    });

    try std.testing.expect(project.files.len > 0);

    // Verify we can generate PHP for each file
    for (project.files) |file| {
        const php = try generatePhpFile(allocator, file);
        try std.testing.expect(std.mem.indexOf(u8, php, "<?php") != null);
    }

    // Verify ground truth extraction works
    const symbols = try expectedSymbols(allocator, project);
    try std.testing.expect(symbols.len > 0);

    const calls = try expectedCalls(allocator, project);
    _ = calls;
    // Calls may be 0 depending on RNG, but the function should not error

    const alive = try expectedAlive(allocator, project);
    const dead = try expectedDead(allocator, project);

    // Every symbol is either alive or dead
    try std.testing.expectEqual(symbols.len, alive.len + dead.len);
}
