const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Global I/O handle (Zig 0.16 std.Io model)
// ============================================================================

/// Process-wide I/O handle, set once in `main` from `std.process.Init`.
/// Used by filesystem and stream operations across modules so that the
/// zero-argument CLI action callbacks (and other helpers) can perform I/O
/// without threading `io` through every signature.
///
/// In test builds it defaults to the test runner's threaded I/O so that
/// unit tests exercising filesystem/stream helpers work without an explicit
/// `main`-time initialization.
pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;

/// Monotonic elapsed-time timer, a drop-in replacement for the removed
/// `std.time.Timer` under the Zig 0.16 `std.Io` clock model. Uses the global
/// `io` handle and the monotonic (`.awake`) clock.
pub const Timer = struct {
    start_ts: std.Io.Timestamp,

    /// Start a new timer at the current monotonic time.
    pub fn start() Timer {
        return .{ .start_ts = std.Io.Clock.now(.awake, io) };
    }

    /// Nanoseconds elapsed since the timer was started (or last reset).
    pub fn read(self: *Timer) u64 {
        const now = std.Io.Clock.now(.awake, io);
        return @intCast(self.start_ts.durationTo(now).nanoseconds);
    }

    /// Reset the timer's start point to now.
    pub fn reset(self: *Timer) void {
        self.start_ts = std.Io.Clock.now(.awake, io);
    }

    /// Return elapsed nanoseconds and reset the start point to now.
    pub fn lap(self: *Timer) u64 {
        const now = std.Io.Clock.now(.awake, io);
        const elapsed: u64 = @intCast(self.start_ts.durationTo(now).nanoseconds);
        self.start_ts = now;
        return elapsed;
    }
};

// ============================================================================
// Type Information
// ============================================================================

/// Represents a PHP type (simple, nullable, union, etc.)
pub const TypeInfo = struct {
    kind: Kind,
    base_type: []const u8, // For simple/nullable: the type name (FQCN or builtin)
    type_parts: []const []const u8, // For union/intersection types
    type_params: []const TypeInfo = &.{}, // For generic types: Collection<User> -> [User]
    is_builtin: bool,

    pub const Kind = enum {
        simple, // Single type: "Foo" or "int"
        nullable, // ?Foo
        union_type, // Foo|Bar
        intersection, // Foo&Bar
        array_type, // array, int[], Foo[]
        generic, // Collection<User>, Repository<Product>
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
        // Framework stubs fold large type catalogs through this at comptime;
        // raise the backwards-branch quota so that evaluation does not abort.
        @setEvalBranchQuota(100000);
        for (builtins) |builtin_name| {
            if (std.mem.eql(u8, type_name, builtin_name)) return true;
        }
        return false;
    }

    pub fn simple(allocator: std.mem.Allocator, type_name: []const u8) !TypeInfo {
        _ = allocator;
        return .{
            .kind = .simple,
            .base_type = type_name,
            .type_parts = &.{},
            .is_builtin = isBuiltin(type_name),
        };
    }

    pub fn nullable(allocator: std.mem.Allocator, type_name: []const u8) !TypeInfo {
        _ = allocator;
        return .{
            .kind = .nullable,
            .base_type = type_name,
            .type_parts = &.{},
            .is_builtin = isBuiltin(type_name),
        };
    }

    pub fn format(self: *const TypeInfo, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.kind) {
            .nullable => std.fmt.allocPrint(allocator, "?{s}", .{self.base_type}),
            .union_type => blk: {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (self.type_parts, 0..) |part, i| {
                    if (i > 0) try result.appendSlice(allocator, "|");
                    try result.appendSlice(allocator, part);
                }
                break :blk try result.toOwnedSlice(allocator);
            },
            .intersection => blk: {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                for (self.type_parts, 0..) |part, i| {
                    if (i > 0) try result.appendSlice(allocator, "&");
                    try result.appendSlice(allocator, part);
                }
                break :blk try result.toOwnedSlice(allocator);
            },
            .generic => blk: {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                try result.appendSlice(allocator, self.base_type);
                try result.append(allocator, '<');
                for (self.type_params, 0..) |param, i| {
                    if (i > 0) try result.appendSlice(allocator, ", ");
                    const param_str = try param.format(allocator);
                    try result.appendSlice(allocator, param_str);
                }
                try result.append(allocator, '>');
                break :blk try result.toOwnedSlice(allocator);
            },
            .array_type => std.fmt.allocPrint(allocator, "{s}[]", .{self.base_type}),
            else => allocator.dupe(u8, self.base_type),
        };
    }
};

/// True for a bare `array`/`iterable` type that carries no element information.
fn isBareCollection(t: TypeInfo) bool {
    return (t.kind == .simple or t.kind == .array_type) and
        (std.mem.eql(u8, t.base_type, "array") or std.mem.eql(u8, t.base_type, "iterable"));
}

/// True for a native `mixed` type. Generic methods commonly declare `: mixed`
/// natively while the PHPDoc carries the precise (often template) type, so we
/// defer to the docblock in that case.
fn isMixedType(t: TypeInfo) bool {
    return t.kind == .mixed or std.mem.eql(u8, t.base_type, "mixed");
}

/// Choose the effective return type, preferring the native hint but deferring to
/// the PHPDoc type when the native one carries no useful information: a bare
/// `array`/`iterable` (e.g. `: array` alongside `@return Foo[]`) so the element
/// type survives, or a bare `mixed` (e.g. `: mixed` alongside `@return TElement`)
/// so generic/template return types survive.
fn effectiveReturn(native: ?TypeInfo, doc: ?TypeInfo) ?TypeInfo {
    if (native) |n| {
        if (isBareCollection(n) or isMixedType(n)) {
            if (doc) |d| return d;
        }
        return n;
    }
    return doc;
}

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
    /// Visibility of a promoted property (only meaningful when `is_promoted`).
    promoted_visibility: Visibility = .public,
    /// Whether a promoted property is declared `readonly` (only meaningful when
    /// `is_promoted`).
    promoted_readonly: bool = false,
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

    // Generic type parameters (@template T, @template V of SomeClass)
    template_params: []const TemplateParam = &.{},

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
        return effectiveReturn(self.return_type, self.phpdoc_return);
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

/// A generic type parameter declared via `@template Name [of Bound] [= Default]`.
///
/// Two consumers read this struct with different needs, so both fields are kept:
///   - `fallback` (local resolver): the FQCN to use when no subclass binds the
///     parameter — the default if present, otherwise the bound — already
///     resolved against the declaring file's imports.
///   - `bound` (generics.zig): the raw `@template T of SomeClass` bound.
/// Both default to null so each producer can set only the field it populates.
pub const TemplateParam = struct {
    name: []const u8, // e.g., "T", "V"
    fallback: ?[]const u8 = null,
    bound: ?[]const u8 = null, // e.g., "SomeClass" for @template T of SomeClass
};

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

    // Generics (from class-level PHPDoc). Superset of both branches' fields,
    // all defaulted so producers set only what they populate:
    //   - local resolver: template_params (ordered) + extends_type_args
    //   - generics.zig:   template_params + generic_extends + generic_implements
    template_params: []const TemplateParam = &.{}, // @template names declared on this class, in order
    extends_type_args: []const []const u8 = &.{}, // concrete/template args bound to the parent via @extends Base<...>
    generic_extends: ?TypeInfo = null, // @extends Collection<User>
    generic_implements: []const TypeInfo = &.{}, // @implements Repository<User>

    // Members (directly declared). This is immutable Tier-1 (raw) data; the
    // local resolver's inherited view lives in the Tier-2 `ResolvedView`
    // (keyed by FQCN, never mutates these raw symbols).
    methods: std.StringHashMap(MethodSymbol),
    properties: std.StringHashMap(PropertySymbol),

    // Resolved members including inherited (populated by
    // `SymbolTable.resolveInheritance`). The origin-side analyzers
    // (dead_code, type checks, framework_stubs) read these directly; the
    // local MCP path uses `ResolvedView` instead. Both can coexist.
    all_methods: std.StringHashMap(*const MethodSymbol),
    all_properties: std.StringHashMap(*const PropertySymbol),
    parent_chain: []const []const u8 = &.{}, // Ordered list of ancestors (nearest first)

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
            .template_params = &.{},
            .extends_type_args = &.{},
            .methods = std.StringHashMap(MethodSymbol).init(allocator),
            .properties = std.StringHashMap(PropertySymbol).init(allocator),
            .all_methods = std.StringHashMap(*const MethodSymbol).init(allocator),
            .all_properties = std.StringHashMap(*const PropertySymbol).init(allocator),
            .parent_chain = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClassSymbol) void {
        if (self.parent_chain.len > 0) {
            self.allocator.free(self.parent_chain);
        }
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

    /// Get a directly-declared method (raw, not inherited). For the inherited
    /// view use `ResolvedView.resolveMethod`.
    pub fn getMethod(self: *const ClassSymbol, name: []const u8) ?*const MethodSymbol {
        return self.methods.getPtr(name);
    }

    /// Get a directly-declared property (raw, not inherited). For the inherited
    /// view use `ResolvedView.resolveProperty`.
    pub fn getProperty(self: *const ClassSymbol, name: []const u8) ?*const PropertySymbol {
        return self.properties.getPtr(name);
    }

    /// Index of the template parameter named `name`, or null if this class
    /// declares no such `@template`.
    pub fn templateIndexOf(self: *const ClassSymbol, name: []const u8) ?usize {
        for (self.template_params, 0..) |tp, i| {
            if (std.mem.eql(u8, tp.name, name)) return i;
        }
        return null;
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
        return effectiveReturn(self.return_type, self.phpdoc_return);
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
    pub fn resolveFQCN(self: *const FileContext, type_name: []const u8) error{OutOfMemory}![]const u8 {
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

        // Check for qualified name like Foo\Bar where Foo is imported.
        if (std.mem.indexOf(u8, type_name, "\\")) |sep| {
            const first_part = type_name[0..sep];
            if (self.use_statements.get(first_part)) |use_stmt| {
                // Combine the imported namespace with the rest of the path:
                // `use App\Foo;` + `Foo\Bar` -> `App\Foo\Bar`.
                return std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}",
                    .{ use_stmt.fqcn, type_name[sep..] },
                ) catch type_name;
            }
            // A qualified name with no matching import is relative to the current
            // namespace (PHP: `Sub\Bar` in namespace `App` -> `App\Sub\Bar`).
            if (self.namespace) |ns| {
                return std.fmt.allocPrint(
                    self.allocator,
                    "{s}\\{s}",
                    .{ ns, type_name },
                ) catch type_name;
            }
            return type_name;
        }

        // Unqualified name with no import: resolve against the current namespace.
        // (PHP resolves unqualified class names to the current namespace; global
        // classes must be referenced as `\Foo` or imported — both handled above.)
        if (self.namespace) |ns| {
            return std.fmt.allocPrint(
                self.allocator,
                "{s}\\{s}",
                .{ ns, type_name },
            ) catch type_name;
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
    interface_single_impl, // DI-bound: interface-typed property with exactly one in-project implementor
    di_config_binding, // DI-bound via services.yaml interface->concrete binding (Phase B)
    interface_contract, // resolved to an interface's own (abstract) method declaration; runtime implementor unknown
    return_type_chain, // From return type of previous call
    plugin_generated, // Synthetic edge from plugin (e.g., event dispatch -> handler)
    unresolved,
};

/// Why an instance-method call stayed unresolved, captured at analysis time
/// (the post-hoc name bridge can only count name collisions, not causes). Lets
/// "low resolution rate" be attributed to concrete, fixable receiver shapes vs.
/// genuinely external receivers. `.none` means the call resolved.
pub const UnresolvedReason = enum {
    none, // resolved (or not an instance call)
    recv_param_untyped, // receiver is a parameter of the current method with no type hint
    recv_local, // receiver is a local var (not a param) we couldn't track
    recv_var, // receiver is a variable we couldn't type (no method context)
    recv_property, // $obj->prop->m(): property type unknown
    recv_chain, // $a->b()->m(): previous instance-call return type unknown
    recv_static_chain, // Foo::bar()->m(): static-call return type unknown
    recv_func_chain, // helper()->m(): function return type unknown
    recv_subscript, // $arr[..]->m(): element type unknown
    recv_other, // some other receiver node kind
    recv_type_external, // receiver type RESOLVED but not in-project (e.g. vendor/core)
    method_not_found_external_ancestor, // in-project receiver, but extends/uses an external base/trait (method likely inherited from core)
    method_not_found_pure, // in-project receiver with no external ancestor, method still missing (genuine engine gap or magic __call)
};

pub const EnhancedFunctionCall = struct {
    // Original call info
    caller_fqn: []const u8, // FQN of the calling function/method
    owns_caller_fqn: bool = false,
    callee_name: []const u8, // Name of the called function/method
    owns_callee_name: bool = false,
    call_type: CallType,
    line: u32,
    column: u32,
    file_path: []const u8,

    // Call-site shape
    arg_count: u32 = 0, // Number of arguments passed at the call site
    /// Per-positional-argument resolved type, in source order; an element is
    /// null where the argument expression's type could not be resolved (same
    /// partiality as receiver resolution). Empty when no arguments. Used by the
    /// type-aware `impact` breaking-change analysis.
    arg_types: []const ?TypeInfo = &.{},
    owns_arg_types: bool = false,
    /// True when the call site uses any PHP named argument (`f(name: $x)`).
    /// Named arguments bind to parameters by name, not position, so the
    /// positional `arg_count`/`arg_types` cannot be soundly checked against a
    /// parameter list — consumers must skip positional arg analysis for these.
    has_named_args: bool = false,
    /// True when the call site is a PHP 8.1 first-class callable reference
    /// (`f(...)`, `Foo::bar(...)`, `$o->m(...)`). This does not invoke the
    /// callee; it creates a Closure referencing it. The `(...)` placeholder is
    /// not an argument, so `arg_count` is 0 and positional arity/type checks are
    /// meaningless — consumers must skip invocation-arity analysis for these.
    is_first_class_callable: bool = false,
    /// How the call's *result* is consumed at this site. Drives return-type
    /// narrowing analysis (dereferencing a now-nullable result is breaking).
    result_used: ResultUse = .ignored,

    // Resolution info
    resolved_target: ?[]const u8, // FQCN of resolved method
    owns_resolved_target: bool = false,
    resolution_confidence: f32,
    resolution_method: ResolutionMethod,
    unresolved_reason: UnresolvedReason = .none, // diagnostic: why an unresolved instance call failed
    receiver_type: ?[]const u8 = null, // diagnostic: resolved receiver FQCN, when known (for method-not-found samples)
    unresolved_detail: ?[]const u8 = null, // diagnostic: fine-grained sub-reason (e.g. recv_local RHS shape, recv_chain inner status)

    pub const CallType = enum {
        function,
        method,
        static_method,
    };

    /// How a call expression's result is consumed at the call site.
    pub const ResultUse = enum {
        ignored, // result discarded (statement-level call)
        assigned, // result stored in a variable / property
        member_access, // result immediately dereferenced (->m, ::m, [i]) — null-narrowing risk
        passed, // result passed as an argument or returned upward
    };

    pub fn qualifiedCallName(self: *const EnhancedFunctionCall, allocator: std.mem.Allocator) ![]const u8 {
        if (self.resolved_target) |target| {
            return allocator.dupe(u8, target);
        }
        return allocator.dupe(u8, self.callee_name);
    }

    /// Free any heap data this call owns (set by the parallel analysis path,
    /// which duplicates call strings into the caller allocator). Single-threaded
    /// analysis leaves the `owns_*` flags false, so this is a no-op there.
    pub fn deinitOwned(self: *const EnhancedFunctionCall, allocator: std.mem.Allocator) void {
        if (self.owns_caller_fqn) allocator.free(self.caller_fqn);
        if (self.owns_callee_name) allocator.free(self.callee_name);
        if (self.owns_resolved_target) {
            if (self.resolved_target) |target| allocator.free(target);
        }
        if (self.owns_arg_types and self.arg_types.len > 0) {
            allocator.free(self.arg_types);
        }
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
    plugins: []const []const u8, // enabled analysis plugins for this project
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) ProjectConfig {
        return .{
            .root_path = root_path,
            .composer_path = "",
            .autoload_psr4 = std.StringHashMap([]const []const u8).init(allocator),
            .autoload_psr0 = std.StringHashMap([]const []const u8).init(allocator),
            .autoload_classmap = &.{},
            .autoload_files = &.{},
            .plugins = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProjectConfig) void {
        self.autoload_psr4.deinit();
        self.autoload_psr0.deinit();
    }
};

// ============================================================================
// Tests: FileContext.resolveFQCN
// ============================================================================

test "resolveFQCN: already qualified strips leading backslash" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();

    const result = try ctx.resolveFQCN("\\App\\Models\\User");
    try std.testing.expectEqualStrings("App\\Models\\User", result);
}

test "resolveFQCN: builtin types unchanged" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();
    ctx.namespace = "App";

    const result = try ctx.resolveFQCN("string");
    try std.testing.expectEqualStrings("string", result);
}

test "resolveFQCN: use statement exact match" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();
    ctx.namespace = "App";

    try ctx.addUseStatement(.{ .fqcn = "Vendor\\Lib\\Logger", .alias = null, .kind = .class });

    const result = try ctx.resolveFQCN("Logger");
    try std.testing.expectEqualStrings("Vendor\\Lib\\Logger", result);
}

test "resolveFQCN: use statement with alias" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();
    ctx.namespace = "App";

    try ctx.addUseStatement(.{ .fqcn = "Vendor\\Lib\\Logger", .alias = "Log", .kind = .class });

    const result = try ctx.resolveFQCN("Log");
    try std.testing.expectEqualStrings("Vendor\\Lib\\Logger", result);
}

test "resolveFQCN: qualified name with imported prefix" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();
    ctx.namespace = "App";

    try ctx.addUseStatement(.{ .fqcn = "Vendor\\Foo", .alias = null, .kind = .class });

    const result = try ctx.resolveFQCN("Foo\\Bar");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Vendor\\Foo\\Bar", result);
}

test "resolveFQCN: namespace prepend when no use match" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();
    ctx.namespace = "App\\Services";

    const result = try ctx.resolveFQCN("UserService");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("App\\Services\\UserService", result);
}

test "resolveFQCN: no namespace no use returns unchanged" {
    const allocator = std.testing.allocator;
    var ctx = FileContext.init(allocator, "test.php");
    defer ctx.deinit();

    const result = try ctx.resolveFQCN("SomeClass");
    try std.testing.expectEqualStrings("SomeClass", result);
}
