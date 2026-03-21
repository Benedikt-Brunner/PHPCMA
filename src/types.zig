const std = @import("std");

// ============================================================================
// Type Information
// ============================================================================

/// Represents a PHP type (simple, nullable, union, etc.)
pub const TypeInfo = struct {
    kind: Kind,
    base_type: []const u8, // For simple/nullable: the type name (FQCN or builtin)
    type_parts: []const []const u8, // For union/intersection types
    is_builtin: bool,

    pub const Kind = enum {
        simple, // Single type: "Foo" or "int"
        nullable, // ?Foo
        union_type, // Foo|Bar
        intersection, // Foo&Bar
        array_type, // array, int[], Foo[]
        mixed,
        void_type,
        never,
        self_type, // self
        static_type, // static
        parent_type, // parent
    };

    pub const builtins = [_][]const u8{
        "int",     "integer", "float",  "double", "string", "bool",
        "boolean", "array",   "object", "null",   "mixed",  "void",
        "never",   "callable", "iterable", "resource",
    };

    pub fn isBuiltin(type_name: []const u8) bool {
        for (builtins) |builtin| {
            if (std.mem.eql(u8, type_name, builtin)) return true;
        }
        return false;
    }

    pub fn simple(allocator: std.mem.Allocator, type_name: []const u8) !TypeInfo {
        return .{
            .kind = .simple,
            .base_type = try allocator.dupe(u8, type_name),
            .type_parts = &.{},
            .is_builtin = isBuiltin(type_name),
        };
    }

    pub fn nullable(allocator: std.mem.Allocator, type_name: []const u8) !TypeInfo {
        return .{
            .kind = .nullable,
            .base_type = try allocator.dupe(u8, type_name),
            .type_parts = &.{},
            .is_builtin = isBuiltin(type_name),
        };
    }

    pub fn format(self: *const TypeInfo, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.kind) {
            .nullable => std.fmt.allocPrint(allocator, "?{s}", .{self.base_type}),
            .union_type => blk: {
                var result = std.ArrayList(u8).init(allocator);
                for (self.type_parts, 0..) |part, i| {
                    if (i > 0) try result.appendSlice("|");
                    try result.appendSlice(part);
                }
                break :blk try result.toOwnedSlice();
            },
            .intersection => blk: {
                var result = std.ArrayList(u8).init(allocator);
                for (self.type_parts, 0..) |part, i| {
                    if (i > 0) try result.appendSlice("&");
                    try result.appendSlice(part);
                }
                break :blk try result.toOwnedSlice();
            },
            .array_type => std.fmt.allocPrint(allocator, "{s}[]", .{self.base_type}),
            else => allocator.dupe(u8, self.base_type),
        };
    }
};

// ============================================================================
// Visibility
// ============================================================================

pub const Visibility = enum {
    public,
    protected,
    private,

    pub fn fromString(s: []const u8) Visibility {
        if (std.mem.eql(u8, s, "private")) return .private;
        if (std.mem.eql(u8, s, "protected")) return .protected;
        return .public;
    }
};

// ============================================================================
// Parameter Information
// ============================================================================

pub const ParameterInfo = struct {
    name: []const u8,
    type_info: ?TypeInfo,
    has_default: bool,
    is_variadic: bool,
    is_by_reference: bool,
    is_promoted: bool, // PHP 8.0 constructor property promotion
    phpdoc_type: ?TypeInfo, // From @param annotation
};

// ============================================================================
// Property Symbol
// ============================================================================

pub const PropertySymbol = struct {
    name: []const u8,
    visibility: Visibility,
    is_static: bool,
    is_readonly: bool,
    declared_type: ?TypeInfo, // Native PHP type
    phpdoc_type: ?TypeInfo, // From @var annotation
    default_value_type: ?TypeInfo, // Inferred from = new Foo()
    line: u32,

    /// Get the effective type (prefers native, falls back to PHPDoc)
    pub fn effectiveType(self: *const PropertySymbol) ?TypeInfo {
        return self.declared_type orelse self.phpdoc_type orelse self.default_value_type;
    }
};

// ============================================================================
// Method Symbol
// ============================================================================

pub const MethodSymbol = struct {
    name: []const u8,
    visibility: Visibility,
    is_static: bool,
    is_abstract: bool,
    is_final: bool,

    // Type information
    parameters: []const ParameterInfo,
    return_type: ?TypeInfo, // Native PHP return type
    phpdoc_return: ?TypeInfo, // From @return annotation

    // Location
    start_line: u32,
    end_line: u32,
    start_byte: u32,
    end_byte: u32,

    // Context
    containing_class: []const u8, // FQCN of declaring class
    file_path: []const u8,

    /// Get the effective return type (prefers native, falls back to PHPDoc)
    pub fn effectiveReturnType(self: *const MethodSymbol) ?TypeInfo {
        return self.return_type orelse self.phpdoc_return;
    }

    /// Get the qualified name (Class::method)
    pub fn qualifiedName(self: *const MethodSymbol, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}::{s}", .{ self.containing_class, self.name });
    }

    /// Get parameter type by name
    pub fn getParameterType(self: *const MethodSymbol, param_name: []const u8) ?TypeInfo {
        for (self.parameters) |param| {
            if (std.mem.eql(u8, param.name, param_name)) {
                return param.type_info orelse param.phpdoc_type;
            }
        }
        return null;
    }
};

// ============================================================================
// Class Symbol
// ============================================================================

pub const ClassSymbol = struct {
    fqcn: []const u8, // Fully qualified class name
    name: []const u8, // Short name
    namespace: ?[]const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,

    // Modifiers
    is_abstract: bool,
    is_final: bool,
    is_readonly: bool, // PHP 8.2+

    // Inheritance
    extends: ?[]const u8, // Parent class FQCN
    implements: []const []const u8, // Interface FQCNs
    uses: []const []const u8, // Trait FQCNs

    // Members (directly declared)
    methods: std.StringHashMap(MethodSymbol),
    properties: std.StringHashMap(PropertySymbol),

    // Resolved (computed after inheritance resolution)
    all_methods: std.StringHashMap(*const MethodSymbol), // Including inherited
    all_properties: std.StringHashMap(*const PropertySymbol),
    parent_chain: []const []const u8, // Ordered list of ancestors

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fqcn: []const u8) ClassSymbol {
        // Extract short name and namespace from FQCN
        var name: []const u8 = fqcn;
        var namespace: ?[]const u8 = null;

        if (std.mem.lastIndexOf(u8, fqcn, "\\")) |sep| {
            namespace = fqcn[0..sep];
            name = fqcn[sep + 1 ..];
        }

        return .{
            .fqcn = fqcn,
            .name = name,
            .namespace = namespace,
            .file_path = "",
            .start_line = 0,
            .end_line = 0,
            .is_abstract = false,
            .is_final = false,
            .is_readonly = false,
            .extends = null,
            .implements = &.{},
            .uses = &.{},
            .methods = std.StringHashMap(MethodSymbol).init(allocator),
            .properties = std.StringHashMap(PropertySymbol).init(allocator),
            .all_methods = std.StringHashMap(*const MethodSymbol).init(allocator),
            .all_properties = std.StringHashMap(*const PropertySymbol).init(allocator),
            .parent_chain = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClassSymbol) void {
        self.methods.deinit();
        self.properties.deinit();
        self.all_methods.deinit();
        self.all_properties.deinit();
    }

    pub fn addMethod(self: *ClassSymbol, method: MethodSymbol) !void {
        try self.methods.put(method.name, method);
    }

    pub fn addProperty(self: *ClassSymbol, property: PropertySymbol) !void {
        try self.properties.put(property.name, property);
    }

    /// Get a method (including inherited)
    pub fn getMethod(self: *const ClassSymbol, name: []const u8) ?*const MethodSymbol {
        return self.all_methods.get(name);
    }

    /// Get a property (including inherited)
    pub fn getProperty(self: *const ClassSymbol, name: []const u8) ?*const PropertySymbol {
        return self.all_properties.get(name);
    }
};

// ============================================================================
// Interface Symbol
// ============================================================================

pub const InterfaceSymbol = struct {
    fqcn: []const u8,
    name: []const u8,
    namespace: ?[]const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,

    extends: []const []const u8, // Parent interfaces
    methods: std.StringHashMap(MethodSymbol), // All methods are implicitly abstract

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fqcn: []const u8) InterfaceSymbol {
        var name: []const u8 = fqcn;
        var namespace: ?[]const u8 = null;

        if (std.mem.lastIndexOf(u8, fqcn, "\\")) |sep| {
            namespace = fqcn[0..sep];
            name = fqcn[sep + 1 ..];
        }

        return .{
            .fqcn = fqcn,
            .name = name,
            .namespace = namespace,
            .file_path = "",
            .start_line = 0,
            .end_line = 0,
            .extends = &.{},
            .methods = std.StringHashMap(MethodSymbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InterfaceSymbol) void {
        self.methods.deinit();
    }

    pub fn addMethod(self: *InterfaceSymbol, method: MethodSymbol) !void {
        try self.methods.put(method.name, method);
    }
};

// ============================================================================
// Trait Symbol
// ============================================================================

pub const TraitSymbol = struct {
    fqcn: []const u8,
    name: []const u8,
    namespace: ?[]const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,

    uses: []const []const u8, // Other traits this trait uses
    methods: std.StringHashMap(MethodSymbol),
    properties: std.StringHashMap(PropertySymbol),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fqcn: []const u8) TraitSymbol {
        var name: []const u8 = fqcn;
        var namespace: ?[]const u8 = null;

        if (std.mem.lastIndexOf(u8, fqcn, "\\")) |sep| {
            namespace = fqcn[0..sep];
            name = fqcn[sep + 1 ..];
        }

        return .{
            .fqcn = fqcn,
            .name = name,
            .namespace = namespace,
            .file_path = "",
            .start_line = 0,
            .end_line = 0,
            .uses = &.{},
            .methods = std.StringHashMap(MethodSymbol).init(allocator),
            .properties = std.StringHashMap(PropertySymbol).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraitSymbol) void {
        self.methods.deinit();
        self.properties.deinit();
    }

    pub fn addMethod(self: *TraitSymbol, method: MethodSymbol) !void {
        try self.methods.put(method.name, method);
    }

    pub fn addProperty(self: *TraitSymbol, prop: PropertySymbol) !void {
        try self.properties.put(prop.name, prop);
    }
};

// ============================================================================
// Function Symbol (standalone functions)
// ============================================================================

pub const FunctionSymbol = struct {
    fqn: []const u8, // Fully qualified name (namespace\function)
    name: []const u8,
    namespace: ?[]const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,

    parameters: []const ParameterInfo,
    return_type: ?TypeInfo,
    phpdoc_return: ?TypeInfo,

    pub fn effectiveReturnType(self: *const FunctionSymbol) ?TypeInfo {
        return self.return_type orelse self.phpdoc_return;
    }
};

// ============================================================================
// Use Statement (namespace imports)
// ============================================================================

pub const UseStatement = struct {
    fqcn: []const u8, // Full path being imported
    alias: ?[]const u8, // Optional alias
    kind: Kind,

    pub const Kind = enum {
        class,
        function,
        constant,
    };

    /// Get the name to use for resolution (alias or last part of FQCN)
    pub fn resolveName(self: *const UseStatement) []const u8 {
        if (self.alias) |a| return a;
        if (std.mem.lastIndexOf(u8, self.fqcn, "\\")) |sep| {
            return self.fqcn[sep + 1 ..];
        }
        return self.fqcn;
    }
};

// ============================================================================
// File Context (per-file state)
// ============================================================================

pub const FileContext = struct {
    file_path: []const u8,
    namespace: ?[]const u8,
    use_statements: std.StringHashMap(UseStatement),
    allocator: std.mem.Allocator,
    project_config: ?*const ProjectConfig,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) FileContext {
        return .{
            .file_path = file_path,
            .namespace = null,
            .use_statements = std.StringHashMap(UseStatement).init(allocator),
            .allocator = allocator,
            .project_config = null,
        };
    }

    pub fn deinit(self: *FileContext) void {
        self.use_statements.deinit();
    }

    /// Resolve a type name to FQCN using this file's namespace and use statements
    pub fn resolveFQCN(self: *const FileContext, type_name: []const u8) []const u8 {
        // Already fully qualified
        if (type_name.len > 0 and type_name[0] == '\\') {
            return type_name[1..]; // Remove leading backslash
        }

        // Check if it's a builtin type
        if (TypeInfo.isBuiltin(type_name)) {
            return type_name;
        }

        // Check use statements
        // First, check for exact match or alias
        if (self.use_statements.get(type_name)) |use_stmt| {
            return use_stmt.fqcn;
        }

        // Check for qualified name like Foo\Bar where Foo is imported
        if (std.mem.indexOf(u8, type_name, "\\")) |sep| {
            const first_part = type_name[0..sep];
            if (self.use_statements.get(first_part)) |use_stmt| {
                // Combine imported namespace with rest of path
                // TODO: allocate and combine
                _ = use_stmt;
            }
        }

        // Default: prepend current namespace
        if (self.namespace) |ns| {
            // Would need allocation to combine
            // For now, just return as-is (caller should handle)
            _ = ns;
        }

        return type_name;
    }

    pub fn addUseStatement(self: *FileContext, use_stmt: UseStatement) !void {
        const name = use_stmt.resolveName();
        try self.use_statements.put(name, use_stmt);
    }
};

// ============================================================================
// Scope Context (variable type tracking within a function)
// ============================================================================

pub const ScopeContext = struct {
    variables: std.StringHashMap(TypeInfo),
    parent_scope: ?*ScopeContext, // For nested closures
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*ScopeContext) ScopeContext {
        return .{
            .variables = std.StringHashMap(TypeInfo).init(allocator),
            .parent_scope = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScopeContext) void {
        self.variables.deinit();
    }

    pub fn setVariableType(self: *ScopeContext, var_name: []const u8, type_info: TypeInfo) !void {
        try self.variables.put(var_name, type_info);
    }

    pub fn getVariableType(self: *const ScopeContext, var_name: []const u8) ?TypeInfo {
        if (self.variables.get(var_name)) |t| return t;
        if (self.parent_scope) |parent| return parent.getVariableType(var_name);
        return null;
    }
};

// ============================================================================
// Enhanced Function Call (with resolution info)
// ============================================================================

pub const ResolutionConfidence = enum {
    exact, // Definitely this method
    likely, // High confidence (single implementation)
    possible, // One of several possible targets
    unresolved, // Could not determine
};

pub const ResolutionMethod = enum {
    native_type, // From PHP type hint
    explicit_type, // Explicit class name in static call
    phpdoc, // From @var/@param/@return
    assignment, // From $x = new Foo()
    assignment_tracking, // From tracking variable assignments
    constructor_injection, // From constructor parameter
    constructor_call, // new ClassName()
    this_call, // $this->method()
    this_reference, // $this reference
    self_reference, // self:: reference
    static_reference, // static:: reference
    parent_reference, // parent:: reference
    static_call, // Foo::method()
    property_type, // From property type declaration
    return_type_chain, // From return type of previous call
    plugin_generated, // Synthetic edge from plugin (e.g., event dispatch -> handler)
    unresolved,
};

pub const EnhancedFunctionCall = struct {
    // Original call info
    caller_fqn: []const u8, // FQN of the calling function/method
    callee_name: []const u8, // Name of the called function/method
    call_type: CallType,
    line: u32,
    column: u32,
    file_path: []const u8,

    // Resolution info
    resolved_target: ?[]const u8, // FQCN of resolved method
    resolution_confidence: f32,
    resolution_method: ResolutionMethod,

    pub const CallType = enum {
        function,
        method,
        static_method,
    };

    pub fn qualifiedCallName(self: *const EnhancedFunctionCall, allocator: std.mem.Allocator) ![]const u8 {
        if (self.resolved_target) |target| {
            return allocator.dupe(u8, target);
        }
        return allocator.dupe(u8, self.callee_name);
    }
};

// ============================================================================
// Project Configuration
// ============================================================================

pub const ProjectConfig = struct {
    root_path: []const u8,
    composer_path: []const u8,
    autoload_psr4: std.StringHashMap([]const []const u8), // namespace -> [paths]
    autoload_psr0: std.StringHashMap([]const []const u8),
    autoload_classmap: []const []const u8,
    autoload_files: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) ProjectConfig {
        return .{
            .root_path = root_path,
            .composer_path = "",
            .autoload_psr4 = std.StringHashMap([]const []const u8).init(allocator),
            .autoload_psr0 = std.StringHashMap([]const []const u8).init(allocator),
            .autoload_classmap = &.{},
            .autoload_files = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProjectConfig) void {
        self.autoload_psr4.deinit();
        self.autoload_psr0.deinit();
    }
};
