const std = @import("std");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;
const ClassSymbol = types.ClassSymbol;
const MethodSymbol = types.MethodSymbol;
const TemplateParam = types.TemplateParam;

// ============================================================================
// Generic Type Substitution Engine
// ============================================================================

/// A mapping from template parameter names to concrete types
pub const TypeSubstitution = struct {
    bindings: std.StringHashMap(TypeInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeSubstitution {
        return .{
            .bindings = std.StringHashMap(TypeInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeSubstitution) void {
        self.bindings.deinit();
    }

    pub fn bind(self: *TypeSubstitution, param_name: []const u8, concrete_type: TypeInfo) !void {
        try self.bindings.put(param_name, concrete_type);
    }

    pub fn get(self: *const TypeSubstitution, param_name: []const u8) ?TypeInfo {
        return self.bindings.get(param_name);
    }
};

/// Build a substitution map from a class's template params and the concrete type args.
///
/// Given: class Collection<T> and usage Collection<User>,
/// this produces: { "T" -> TypeInfo(User) }
pub fn buildSubstitution(
    allocator: std.mem.Allocator,
    template_params: []const TemplateParam,
    type_args: []const TypeInfo,
) !TypeSubstitution {
    var sub = TypeSubstitution.init(allocator);
    const len = @min(template_params.len, type_args.len);
    for (0..len) |i| {
        try sub.bind(template_params[i].name, type_args[i]);
    }
    return sub;
}

/// Apply a substitution to a type, replacing template parameter references.
///
/// Example: If sub has { T -> User }, then:
///   - TypeInfo("T") -> TypeInfo("User")
///   - TypeInfo("?T") -> TypeInfo("?User")
///   - TypeInfo("Collection<T>") -> TypeInfo("Collection<User>")
pub fn substituteType(
    allocator: std.mem.Allocator,
    type_info: TypeInfo,
    sub: *const TypeSubstitution,
) !TypeInfo {
    switch (type_info.kind) {
        .simple => {
            // Check if this simple type is a template parameter
            if (sub.get(type_info.base_type)) |concrete| {
                return concrete;
            }
            return type_info;
        },
        .nullable => {
            // Check if the nullable base type is a template parameter
            if (sub.get(type_info.base_type)) |concrete| {
                // Wrap in nullable
                return TypeInfo{
                    .kind = .nullable,
                    .base_type = concrete.base_type,
                    .type_parts = &.{},
                    .type_params = concrete.type_params,
                    .is_builtin = concrete.is_builtin,
                };
            }
            return type_info;
        },
        .generic => {
            // Recursively substitute type parameters
            var new_params: std.ArrayListUnmanaged(TypeInfo) = .empty;
            for (type_info.type_params) |param| {
                try new_params.append(allocator, try substituteType(allocator, param, sub));
            }
            // Also check if the base type itself is a template param
            const new_base = if (sub.get(type_info.base_type)) |concrete|
                concrete.base_type
            else
                type_info.base_type;
            return TypeInfo{
                .kind = .generic,
                .base_type = new_base,
                .type_parts = &.{},
                .type_params = try new_params.toOwnedSlice(allocator),
                .is_builtin = false,
            };
        },
        .union_type => {
            // Substitute each part of the union
            var new_parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (type_info.type_parts) |part| {
                if (sub.get(part)) |concrete| {
                    try new_parts.append(allocator, concrete.base_type);
                } else {
                    try new_parts.append(allocator, part);
                }
            }
            return TypeInfo{
                .kind = .union_type,
                .base_type = type_info.base_type,
                .type_parts = try new_parts.toOwnedSlice(allocator),
                .is_builtin = false,
            };
        },
        else => return type_info,
    }
}

/// Resolve a method call on a generic type, substituting template parameters.
///
/// Given: $collection (typed as Collection<User>) calling ->first(),
/// and Collection has @template T with first() returning ?T,
/// this returns ?User.
pub fn resolveGenericMethodReturn(
    allocator: std.mem.Allocator,
    class: *const ClassSymbol,
    method: *const MethodSymbol,
    caller_type: TypeInfo,
) !?TypeInfo {
    // The caller type must be generic with type args
    if (caller_type.kind != .generic or caller_type.type_params.len == 0) {
        // Not a generic invocation — return the method's return type as-is
        return method.effectiveReturnType();
    }

    // Build substitution from class template params + caller type args
    const template_params = if (class.template_params.len > 0)
        class.template_params
    else
        return method.effectiveReturnType();

    var sub = try buildSubstitution(allocator, template_params, caller_type.type_params);
    defer sub.deinit();

    // Also add method-level template params if present
    for (method.template_params) |tpl| {
        // Method-level templates don't get substituted from the caller type;
        // they'd need their own inference from arguments. For now, skip.
        _ = tpl;
    }

    // Substitute in the return type
    const return_type = method.effectiveReturnType() orelse return null;
    return try substituteType(allocator, return_type, &sub);
}

/// Build a substitution from a class's @extends annotation.
///
/// Given: class UserCollection extends Collection<User>
/// with Collection having @template T,
/// this produces { "T" -> User } for the parent class scope.
pub fn buildExtendsSubstitution(
    allocator: std.mem.Allocator,
    parent_class: *const ClassSymbol,
    generic_extends: TypeInfo,
) !TypeSubstitution {
    return buildSubstitution(allocator, parent_class.template_params, generic_extends.type_params);
}

// ============================================================================
// Tests
// ============================================================================

test "simple generic resolution: Collection<User>::first() returns ?User" {
    const allocator = std.testing.allocator;

    // Collection has @template T, first() returns ?T
    const tpl = [_]TemplateParam{.{ .name = "T", .bound = null }};

    var class = ClassSymbol.init(allocator, "App\\Collection");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "first",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .nullable,
            .base_type = "T",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Collection",
        .file_path = "test.php",
    });

    // Caller type: Collection<User>
    const user_param = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "App\\User",
        .type_parts = &.{},
        .is_builtin = false,
    }};
    const caller_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Collection",
        .type_parts = &.{},
        .type_params = &user_param,
        .is_builtin = false,
    };

    const method = class.methods.getPtr("first").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.kind == .nullable);
    try std.testing.expectEqualStrings("App\\User", result.?.base_type);
    class.deinit();
}

test "nested generics: Repository<Collection<User>>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tpl = [_]TemplateParam{.{ .name = "T", .bound = null }};

    var class = ClassSymbol.init(allocator, "App\\Repository");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "get",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .simple,
            .base_type = "T",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Repository",
        .file_path = "test.php",
    });

    // Caller type: Repository<Collection<User>>
    const inner_param = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "App\\User",
        .type_parts = &.{},
        .is_builtin = false,
    }};
    const outer_param = [_]TypeInfo{TypeInfo{
        .kind = .generic,
        .base_type = "App\\Collection",
        .type_parts = &.{},
        .type_params = &inner_param,
        .is_builtin = false,
    }};
    const caller_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Repository",
        .type_parts = &.{},
        .type_params = &outer_param,
        .is_builtin = false,
    };

    const method = class.methods.getPtr("get").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    try std.testing.expect(result != null);
    // T resolves to Collection<User>
    try std.testing.expect(result.?.kind == .generic);
    try std.testing.expectEqualStrings("App\\Collection", result.?.base_type);
    try std.testing.expect(result.?.type_params.len == 1);
    try std.testing.expectEqualStrings("App\\User", result.?.type_params[0].base_type);
}

test "@template on class with bound" {
    const allocator = std.testing.allocator;

    const tpl = [_]TemplateParam{.{ .name = "T", .bound = "App\\Model" }};

    var class = ClassSymbol.init(allocator, "App\\Repository");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "save",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .simple,
            .base_type = "T",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Repository",
        .file_path = "test.php",
    });

    // Caller type: Repository<Product>
    const product_param = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "App\\Product",
        .type_parts = &.{},
        .is_builtin = false,
    }};
    const caller_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Repository",
        .type_parts = &.{},
        .type_params = &product_param,
        .is_builtin = false,
    };

    const method = class.methods.getPtr("save").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("App\\Product", result.?.base_type);
    class.deinit();
}

test "@extends with type param: child inherits parent generic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parent: Collection<T>
    const parent_tpl = [_]TemplateParam{.{ .name = "T", .bound = null }};
    var parent = ClassSymbol.init(allocator, "App\\Collection");
    parent.template_params = &parent_tpl;

    // Child: UserCollection extends Collection<User>
    // generic_extends = Collection<User>
    const user_param = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "App\\User",
        .type_parts = &.{},
        .is_builtin = false,
    }};
    const generic_ext = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Collection",
        .type_parts = &.{},
        .type_params = &user_param,
        .is_builtin = false,
    };

    var sub = try buildExtendsSubstitution(allocator, &parent, generic_ext);
    defer sub.deinit();

    // T should resolve to User
    const resolved = sub.get("T");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("App\\User", resolved.?.base_type);
}

test "generic method call substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tpl = [_]TemplateParam{
        .{ .name = "K", .bound = null },
        .{ .name = "V", .bound = null },
    };

    var class = ClassSymbol.init(allocator, "App\\Map");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "get",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .nullable,
            .base_type = "V",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Map",
        .file_path = "test.php",
    });

    // Caller: Map<string, User>
    const params = [_]TypeInfo{
        TypeInfo{
            .kind = .simple,
            .base_type = "string",
            .type_parts = &.{},
            .is_builtin = true,
        },
        TypeInfo{
            .kind = .simple,
            .base_type = "App\\User",
            .type_parts = &.{},
            .is_builtin = false,
        },
    };
    const caller_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Map",
        .type_parts = &.{},
        .type_params = &params,
        .is_builtin = false,
    };

    const method = class.methods.getPtr("get").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.kind == .nullable);
    try std.testing.expectEqualStrings("App\\User", result.?.base_type);
}

test "incompatible generic param: too few args degrades gracefully" {
    const allocator = std.testing.allocator;

    // Class expects 2 template params but caller provides 1
    const tpl = [_]TemplateParam{
        .{ .name = "K", .bound = null },
        .{ .name = "V", .bound = null },
    };

    var class = ClassSymbol.init(allocator, "App\\Map");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "getValue",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .simple,
            .base_type = "V",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Map",
        .file_path = "test.php",
    });

    // Caller provides only K, not V
    const params = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "string",
        .type_parts = &.{},
        .is_builtin = true,
    }};
    const caller_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Map",
        .type_parts = &.{},
        .type_params = &params,
        .is_builtin = false,
    };

    const method = class.methods.getPtr("getValue").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    // V is not bound, so substitution returns the raw "V" type
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("V", result.?.base_type);
    class.deinit();
}

test "raw usage graceful degradation: non-generic call on generic class" {
    const allocator = std.testing.allocator;

    const tpl = [_]TemplateParam{.{ .name = "T", .bound = null }};

    var class = ClassSymbol.init(allocator, "App\\Collection");
    class.template_params = &tpl;
    try class.addMethod(.{
        .name = "first",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = TypeInfo{
            .kind = .nullable,
            .base_type = "T",
            .type_parts = &.{},
            .is_builtin = false,
        },
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Collection",
        .file_path = "test.php",
    });

    // Caller type is simple (not generic) — raw usage
    const caller_type = TypeInfo{
        .kind = .simple,
        .base_type = "App\\Collection",
        .type_parts = &.{},
        .is_builtin = false,
    };

    const method = class.methods.getPtr("first").?;
    const result = try resolveGenericMethodReturn(allocator, &class, method, caller_type);

    // Should return the raw ?T type without substitution
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.kind == .nullable);
    try std.testing.expectEqualStrings("T", result.?.base_type);
    class.deinit();
}

test "buildSubstitution maps template params to type args" {
    const allocator = std.testing.allocator;

    const tpl = [_]TemplateParam{
        .{ .name = "T", .bound = null },
        .{ .name = "V", .bound = null },
    };
    const args = [_]TypeInfo{
        TypeInfo{ .kind = .simple, .base_type = "int", .type_parts = &.{}, .is_builtin = true },
        TypeInfo{ .kind = .simple, .base_type = "string", .type_parts = &.{}, .is_builtin = true },
    };

    var sub = try buildSubstitution(allocator, &tpl, &args);
    defer sub.deinit();

    const t_val = sub.get("T");
    try std.testing.expect(t_val != null);
    try std.testing.expectEqualStrings("int", t_val.?.base_type);

    const v_val = sub.get("V");
    try std.testing.expect(v_val != null);
    try std.testing.expectEqualStrings("string", v_val.?.base_type);
}

test "substituteType replaces template param in generic type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sub = TypeSubstitution.init(allocator);
    try sub.bind("T", TypeInfo{
        .kind = .simple,
        .base_type = "App\\User",
        .type_parts = &.{},
        .is_builtin = false,
    });

    // Type: Collection<T>
    const t_param = [_]TypeInfo{TypeInfo{
        .kind = .simple,
        .base_type = "T",
        .type_parts = &.{},
        .is_builtin = false,
    }};
    const generic_type = TypeInfo{
        .kind = .generic,
        .base_type = "App\\Collection",
        .type_parts = &.{},
        .type_params = &t_param,
        .is_builtin = false,
    };

    const result = try substituteType(allocator, generic_type, &sub);

    try std.testing.expect(result.kind == .generic);
    try std.testing.expectEqualStrings("App\\Collection", result.base_type);
    try std.testing.expect(result.type_params.len == 1);
    try std.testing.expectEqualStrings("App\\User", result.type_params[0].base_type);
}
