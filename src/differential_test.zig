const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const main_mod = @import("main.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const ClassSymbol = types.ClassSymbol;
const InterfaceSymbol = types.InterfaceSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const Visibility = types.Visibility;
const TypeInfo = types.TypeInfo;
const SymbolCollector = main_mod.SymbolCollector;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

// ============================================================================
// JSON helpers — parse reflect.php output
// ============================================================================

const ReflectedClass = struct {
    fqcn: []const u8,
    is_enum: bool = false,
    is_abstract: bool = false,
    is_final: bool = false,
    extends: ?[]const u8 = null,
    implements: []const []const u8 = &.{},
    methods: []const ReflectedMethod = &.{},
    properties: []const ReflectedProperty = &.{},
};

const ReflectedMethod = struct {
    name: []const u8,
    visibility: []const u8 = "public",
    is_static: bool = false,
    is_abstract: bool = false,
    return_type: ?[]const u8 = null,
    params: []const ReflectedParam = &.{},
};

const ReflectedParam = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    has_default: bool = false,
    is_variadic: bool = false,
};

const ReflectedProperty = struct {
    name: []const u8,
    visibility: []const u8 = "public",
    type: ?[]const u8 = null,
    is_static: bool = false,
    is_readonly: bool = false,
};

const ReflectedOutput = struct {
    classes: []const ReflectedClass = &.{},
    interfaces: []const ReflectedInterface = &.{},
    traits: []const ReflectedTrait = &.{},
};

const ReflectedInterface = struct {
    fqcn: []const u8,
    methods: []const ReflectedMethod = &.{},
};

const ReflectedTrait = struct {
    fqcn: []const u8,
    methods: []const ReflectedMethod = &.{},
    properties: []const ReflectedProperty = &.{},
};

// ============================================================================
// Mismatch reporting
// ============================================================================

const MismatchKind = enum {
    class_missing_in_phpcma,
    class_missing_in_php,
    class_field_mismatch,
    method_missing_in_phpcma,
    method_missing_in_php,
    method_field_mismatch,
    property_missing_in_phpcma,
    property_missing_in_php,
    property_field_mismatch,
    implements_mismatch,
};

const Mismatch = struct {
    kind: MismatchKind,
    class: []const u8,
    detail: []const u8,
};

// ============================================================================
// Comparator
// ============================================================================

fn compareVisibility(phpcma_vis: Visibility, php_vis: []const u8) bool {
    return switch (phpcma_vis) {
        .public => std.mem.eql(u8, php_vis, "public"),
        .protected => std.mem.eql(u8, php_vis, "protected"),
        .private => std.mem.eql(u8, php_vis, "private"),
    };
}

fn isPhpdocOnlyType(type_info: ?TypeInfo) bool {
    // Native PHP types that reflection would know about
    _ = type_info;
    return false;
}

fn formatTypeForComparison(allocator: std.mem.Allocator, type_info: ?TypeInfo) !?[]const u8 {
    const ti = type_info orelse return null;
    return try ti.format(allocator);
}

fn splitTypeParts(allocator: std.mem.Allocator, type_str: []const u8, delimiter: u8) ![]const []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, type_str, delimiter);
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " ");
        if (part.len > 0) {
            try parts.append(allocator, part);
        }
    }

    std.mem.sort([]const u8, parts.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return try parts.toOwnedSlice(allocator);
}

fn canonicalizeTypeString(allocator: std.mem.Allocator, type_str: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, type_str, " ");
    if (trimmed.len == 0) return allocator.dupe(u8, trimmed);

    // Reflection may render nullable types as `T|null` while PHPCMA can render `?T`.
    if (trimmed[0] == '?' and trimmed.len > 1) {
        const nullable_union = try std.fmt.allocPrint(allocator, "{s}|null", .{trimmed[1..]});
        return canonicalizeTypeString(allocator, nullable_union);
    }

    if (std.mem.indexOfScalar(u8, trimmed, '|')) |_| {
        const parts = try splitTypeParts(allocator, trimmed, '|');
        return std.mem.join(allocator, "|", parts);
    }

    if (std.mem.indexOfScalar(u8, trimmed, '&')) |_| {
        const parts = try splitTypeParts(allocator, trimmed, '&');
        return std.mem.join(allocator, "&", parts);
    }

    return allocator.dupe(u8, trimmed);
}

fn compareType(allocator: std.mem.Allocator, phpcma_type: ?TypeInfo, php_type: ?[]const u8) !bool {
    const phpcma_str = try formatTypeForComparison(allocator, phpcma_type) orelse {
        return php_type == null;
    };
    const php_str = php_type orelse return false;

    const normalized_phpcma = try canonicalizeTypeString(allocator, phpcma_str);
    const normalized_php = try canonicalizeTypeString(allocator, php_str);
    return std.mem.eql(u8, normalized_phpcma, normalized_php);
}

fn implementsSetEqual(phpcma: []const []const u8, php: []const []const u8) bool {
    if (phpcma.len != php.len) return false;
    for (phpcma) |p| {
        var found = false;
        for (php) |q| {
            if (std.mem.eql(u8, p, q)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn compareClasses(
    allocator: std.mem.Allocator,
    sym_table: *const SymbolTable,
    reflected: []const ReflectedClass,
    mismatches: *std.ArrayListUnmanaged(Mismatch),
) !void {
    // Check each reflected class exists in PHPCMA
    for (reflected) |ref_class| {
        // PHPCMA does not model enums yet.
        if (ref_class.is_enum) continue;

        const phpcma_class = sym_table.getClass(ref_class.fqcn) orelse {
            try mismatches.append(allocator, .{
                .kind = .class_missing_in_phpcma,
                .class = ref_class.fqcn,
                .detail = "Class found by PHP reflection but not by PHPCMA",
            });
            continue;
        };

        // extends
        const phpcma_extends = phpcma_class.extends orelse "";
        const php_extends = ref_class.extends orelse "";
        if (!std.mem.eql(u8, phpcma_extends, php_extends)) {
            try mismatches.append(allocator, .{
                .kind = .class_field_mismatch,
                .class = ref_class.fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "extends: PHPCMA='{s}', PHP='{s}'",
                    .{ phpcma_extends, php_extends },
                ),
            });
        }

        // implements (order-independent)
        if (!implementsSetEqual(phpcma_class.implements, ref_class.implements)) {
            try mismatches.append(allocator, .{
                .kind = .implements_mismatch,
                .class = ref_class.fqcn,
                .detail = "implements set differs",
            });
        }

        // Methods
        try compareMethods(allocator, phpcma_class, ref_class.methods, ref_class.fqcn, mismatches);

        // Properties
        try compareProperties(allocator, phpcma_class, ref_class.properties, ref_class.fqcn, mismatches);
    }

    // Check PHPCMA classes not found in reflection
    var class_it = sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const fqcn = entry.key_ptr.*;
        var found = false;
        for (reflected) |ref_class| {
            if (std.mem.eql(u8, ref_class.fqcn, fqcn)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try mismatches.append(allocator, .{
                .kind = .class_missing_in_php,
                .class = fqcn,
                .detail = "Class found by PHPCMA but not by PHP reflection",
            });
        }
    }
}

fn compareMethods(
    allocator: std.mem.Allocator,
    phpcma_class: *const ClassSymbol,
    ref_methods: []const ReflectedMethod,
    class_fqcn: []const u8,
    mismatches: *std.ArrayListUnmanaged(Mismatch),
) !void {
    // Check each reflected method exists in PHPCMA
    for (ref_methods) |ref_method| {
        const phpcma_method = phpcma_class.methods.getPtr(ref_method.name) orelse {
            try mismatches.append(allocator, .{
                .kind = .method_missing_in_phpcma,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' found by PHP but not by PHPCMA",
                    .{ref_method.name},
                ),
            });
            continue;
        };

        // visibility
        if (!compareVisibility(phpcma_method.visibility, ref_method.visibility)) {
            try mismatches.append(allocator, .{
                .kind = .method_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' visibility: PHPCMA={s}, PHP={s}",
                    .{ ref_method.name, @tagName(phpcma_method.visibility), ref_method.visibility },
                ),
            });
        }

        // is_static
        if (phpcma_method.is_static != ref_method.is_static) {
            try mismatches.append(allocator, .{
                .kind = .method_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' is_static: PHPCMA={}, PHP={}",
                    .{ ref_method.name, phpcma_method.is_static, ref_method.is_static },
                ),
            });
        }

        // is_abstract
        if (phpcma_method.is_abstract != ref_method.is_abstract) {
            try mismatches.append(allocator, .{
                .kind = .method_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' is_abstract: PHPCMA={}, PHP={}",
                    .{ ref_method.name, phpcma_method.is_abstract, ref_method.is_abstract },
                ),
            });
        }

        // return_type — only compare native types (skip PHPDoc-only)
        if (phpcma_method.return_type) |_| {
            const types_match = try compareType(allocator, phpcma_method.return_type, ref_method.return_type);
            if (!types_match) {
                try mismatches.append(allocator, .{
                    .kind = .method_field_mismatch,
                    .class = class_fqcn,
                    .detail = try std.fmt.allocPrint(
                        allocator,
                        "Method '{s}' return_type: PHPCMA='{s}', PHP='{s}'",
                        .{
                            ref_method.name,
                            try formatTypeForComparison(allocator, phpcma_method.return_type) orelse "(none)",
                            ref_method.return_type orelse "(none)",
                        },
                    ),
                });
            }
        } else if (phpcma_method.phpdoc_return != null and ref_method.return_type == null) {
            // PHPDoc-only return type — PHPCMA knows it, PHP doesn't. This is expected, skip.
        } else if (ref_method.return_type != null and phpcma_method.return_type == null and phpcma_method.phpdoc_return == null) {
            try mismatches.append(allocator, .{
                .kind = .method_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' return_type: PHPCMA='(none)', PHP='{s}'",
                    .{ ref_method.name, ref_method.return_type.? },
                ),
            });
        }

        // param count
        if (phpcma_method.parameters.len != ref_method.params.len) {
            try mismatches.append(allocator, .{
                .kind = .method_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' param count: PHPCMA={d}, PHP={d}",
                    .{ ref_method.name, phpcma_method.parameters.len, ref_method.params.len },
                ),
            });
        } else {
            // Compare individual params
            for (phpcma_method.parameters, 0..) |phpcma_param, i| {
                const ref_param = ref_method.params[i];

                // param name
                if (!std.mem.eql(u8, phpcma_param.name, ref_param.name)) {
                    try mismatches.append(allocator, .{
                        .kind = .method_field_mismatch,
                        .class = class_fqcn,
                        .detail = try std.fmt.allocPrint(
                            allocator,
                            "Method '{s}' param {d} name: PHPCMA='{s}', PHP='{s}'",
                            .{ ref_method.name, i, phpcma_param.name, ref_param.name },
                        ),
                    });
                }

                // param type — only compare native types
                if (phpcma_param.type_info) |_| {
                    const param_types_match = try compareType(allocator, phpcma_param.type_info, ref_param.type);
                    if (!param_types_match) {
                        try mismatches.append(allocator, .{
                            .kind = .method_field_mismatch,
                            .class = class_fqcn,
                            .detail = try std.fmt.allocPrint(
                                allocator,
                                "Method '{s}' param '{s}' type: PHPCMA='{s}', PHP='{s}'",
                                .{
                                    ref_method.name,
                                    ref_param.name,
                                    try formatTypeForComparison(allocator, phpcma_param.type_info) orelse "(none)",
                                    ref_param.type orelse "(none)",
                                },
                            ),
                        });
                    }
                }

                if (phpcma_param.has_default != ref_param.has_default) {
                    try mismatches.append(allocator, .{
                        .kind = .method_field_mismatch,
                        .class = class_fqcn,
                        .detail = try std.fmt.allocPrint(
                            allocator,
                            "Method '{s}' param '{s}' has_default: PHPCMA={}, PHP={}",
                            .{ ref_method.name, ref_param.name, phpcma_param.has_default, ref_param.has_default },
                        ),
                    });
                }

                if (phpcma_param.is_variadic != ref_param.is_variadic) {
                    try mismatches.append(allocator, .{
                        .kind = .method_field_mismatch,
                        .class = class_fqcn,
                        .detail = try std.fmt.allocPrint(
                            allocator,
                            "Method '{s}' param '{s}' is_variadic: PHPCMA={}, PHP={}",
                            .{ ref_method.name, ref_param.name, phpcma_param.is_variadic, ref_param.is_variadic },
                        ),
                    });
                }
            }
        }
    }

    // Check PHPCMA methods not found in reflection
    var method_it = phpcma_class.methods.iterator();
    while (method_it.next()) |entry| {
        const name = entry.key_ptr.*;
        var found = false;
        for (ref_methods) |ref_method| {
            if (std.mem.eql(u8, ref_method.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try mismatches.append(allocator, .{
                .kind = .method_missing_in_php,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Method '{s}' found by PHPCMA but not by PHP reflection",
                    .{name},
                ),
            });
        }
    }
}

fn compareProperties(
    allocator: std.mem.Allocator,
    phpcma_class: *const ClassSymbol,
    ref_props: []const ReflectedProperty,
    class_fqcn: []const u8,
    mismatches: *std.ArrayListUnmanaged(Mismatch),
) !void {
    for (ref_props) |ref_prop| {
        const phpcma_prop = phpcma_class.properties.getPtr(ref_prop.name) orelse {
            try mismatches.append(allocator, .{
                .kind = .property_missing_in_phpcma,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Property '{s}' found by PHP but not by PHPCMA",
                    .{ref_prop.name},
                ),
            });
            continue;
        };

        // visibility
        if (!compareVisibility(phpcma_prop.visibility, ref_prop.visibility)) {
            try mismatches.append(allocator, .{
                .kind = .property_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Property '{s}' visibility: PHPCMA={s}, PHP={s}",
                    .{ ref_prop.name, @tagName(phpcma_prop.visibility), ref_prop.visibility },
                ),
            });
        }

        // type — only compare if PHPCMA has a native declared_type
        if (phpcma_prop.declared_type) |_| {
            const prop_types_match = try compareType(allocator, phpcma_prop.declared_type, ref_prop.type);
            if (!prop_types_match) {
                try mismatches.append(allocator, .{
                    .kind = .property_field_mismatch,
                    .class = class_fqcn,
                    .detail = try std.fmt.allocPrint(
                        allocator,
                        "Property '{s}' type: PHPCMA='{s}', PHP='{s}'",
                        .{
                            ref_prop.name,
                            try formatTypeForComparison(allocator, phpcma_prop.declared_type) orelse "(none)",
                            ref_prop.type orelse "(none)",
                        },
                    ),
                });
            }
        } else if (ref_prop.type != null and phpcma_prop.declared_type == null and phpcma_prop.phpdoc_type == null) {
            try mismatches.append(allocator, .{
                .kind = .property_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Property '{s}' type: PHPCMA='(none)', PHP='{s}'",
                    .{ ref_prop.name, ref_prop.type.? },
                ),
            });
        }

        // is_static
        if (phpcma_prop.is_static != ref_prop.is_static) {
            try mismatches.append(allocator, .{
                .kind = .property_field_mismatch,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Property '{s}' is_static: PHPCMA={}, PHP={}",
                    .{ ref_prop.name, phpcma_prop.is_static, ref_prop.is_static },
                ),
            });
        }
    }

    // Check PHPCMA properties not in reflection
    var prop_it = phpcma_class.properties.iterator();
    while (prop_it.next()) |entry| {
        const name = entry.key_ptr.*;
        var found = false;
        for (ref_props) |ref_prop| {
            if (std.mem.eql(u8, ref_prop.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try mismatches.append(allocator, .{
                .kind = .property_missing_in_php,
                .class = class_fqcn,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "Property '{s}' found by PHPCMA but not by PHP reflection",
                    .{name},
                ),
            });
        }
    }
}

// ============================================================================
// Test infrastructure
// ============================================================================

fn writeTempPhp(allocator: std.mem.Allocator, php_source: []const u8) ![]const u8 {
    const tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch return error.TempFileError;
    _ = tmp_dir;

    const path = try std.fmt.allocPrint(allocator, "/tmp/phpcma_diff_test_{d}.php", .{
        @as(u64, @intCast(std.time.milliTimestamp())),
    });

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(php_source);

    return path;
}

fn cleanupTempFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

fn phpAvailable() bool {
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "php", "--version" },
    }) catch return false;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return result.term.Exited == 0;
}

fn runReflect(allocator: std.mem.Allocator, file_path: []const u8) !ReflectedOutput {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "php", "scripts/reflect.php", file_path },
        .cwd = getProjectRoot(),
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("reflect.php failed (exit {d}):\n{s}\n", .{ result.term.Exited, result.stderr });
        allocator.free(result.stdout);
        return error.ReflectFailed;
    }

    return parseReflectJson(allocator, result.stdout);
}

fn getProjectRoot() []const u8 {
    // Walk up from the test binary location to find the project root
    // For zig build test, the cwd is the project root
    return ".";
}

fn parseReflectJson(allocator: std.mem.Allocator, json_str: []const u8) !ReflectedOutput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const root = parsed.value;

    var result: ReflectedOutput = .{};

    // Parse classes
    if (root.object.get("classes")) |classes_val| {
        const classes_arr = classes_val.array;
        var classes = try allocator.alloc(ReflectedClass, classes_arr.items.len);
        for (classes_arr.items, 0..) |item, i| {
            classes[i] = try parseReflectedClass(allocator, item);
        }
        result.classes = classes;
    }

    // Parse interfaces
    if (root.object.get("interfaces")) |ifaces_val| {
        const ifaces_arr = ifaces_val.array;
        var ifaces = try allocator.alloc(ReflectedInterface, ifaces_arr.items.len);
        for (ifaces_arr.items, 0..) |item, i| {
            ifaces[i] = try parseReflectedInterface(allocator, item);
        }
        result.interfaces = ifaces;
    }

    // Parse traits
    if (root.object.get("traits")) |traits_val| {
        const traits_arr = traits_val.array;
        var trait_list = try allocator.alloc(ReflectedTrait, traits_arr.items.len);
        for (traits_arr.items, 0..) |item, i| {
            trait_list[i] = try parseReflectedTrait(allocator, item);
        }
        result.traits = trait_list;
    }

    return result;
}

fn parseReflectedClass(allocator: std.mem.Allocator, val: std.json.Value) !ReflectedClass {
    const obj = val.object;
    var cls: ReflectedClass = .{
        .fqcn = (obj.get("fqcn") orelse return error.MissingField).string,
    };

    if (obj.get("is_enum")) |v| cls.is_enum = v.bool;
    if (obj.get("is_abstract")) |v| cls.is_abstract = v.bool;
    if (obj.get("is_final")) |v| cls.is_final = v.bool;
    if (obj.get("extends")) |v| {
        cls.extends = switch (v) {
            .string => |s| s,
            .null => null,
            else => null,
        };
    }

    if (obj.get("implements")) |v| {
        const arr = v.array;
        var list = try allocator.alloc([]const u8, arr.items.len);
        for (arr.items, 0..) |item, i| {
            list[i] = item.string;
        }
        cls.implements = list;
    }

    if (obj.get("methods")) |v| {
        cls.methods = try parseReflectedMethods(allocator, v);
    }

    if (obj.get("properties")) |v| {
        cls.properties = try parseReflectedProperties(allocator, v);
    }

    return cls;
}

fn parseReflectedInterface(allocator: std.mem.Allocator, val: std.json.Value) !ReflectedInterface {
    const obj = val.object;
    var iface: ReflectedInterface = .{
        .fqcn = (obj.get("fqcn") orelse return error.MissingField).string,
    };
    if (obj.get("methods")) |v| {
        iface.methods = try parseReflectedMethods(allocator, v);
    }
    return iface;
}

fn parseReflectedTrait(allocator: std.mem.Allocator, val: std.json.Value) !ReflectedTrait {
    const obj = val.object;
    var t: ReflectedTrait = .{
        .fqcn = (obj.get("fqcn") orelse return error.MissingField).string,
    };
    if (obj.get("methods")) |v| {
        t.methods = try parseReflectedMethods(allocator, v);
    }
    if (obj.get("properties")) |v| {
        t.properties = try parseReflectedProperties(allocator, v);
    }
    return t;
}

fn parseReflectedMethods(allocator: std.mem.Allocator, val: std.json.Value) ![]const ReflectedMethod {
    const arr = val.array;
    var methods = try allocator.alloc(ReflectedMethod, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const obj = item.object;
        var m: ReflectedMethod = .{
            .name = (obj.get("name") orelse return error.MissingField).string,
        };
        if (obj.get("visibility")) |v| m.visibility = v.string;
        if (obj.get("is_static")) |v| m.is_static = v.bool;
        if (obj.get("is_abstract")) |v| m.is_abstract = v.bool;
        if (obj.get("return_type")) |v| {
            m.return_type = switch (v) {
                .string => |s| s,
                .null => null,
                else => null,
            };
        }
        if (obj.get("params")) |params_val| {
            const params_arr = params_val.array;
            var params = try allocator.alloc(ReflectedParam, params_arr.items.len);
            for (params_arr.items, 0..) |p, j| {
                const pobj = p.object;
                params[j] = .{
                    .name = (pobj.get("name") orelse return error.MissingField).string,
                };
                if (pobj.get("type")) |t| {
                    params[j].type = switch (t) {
                        .string => |s| s,
                        .null => null,
                        else => null,
                    };
                }
                if (pobj.get("has_default")) |d| params[j].has_default = d.bool;
                if (pobj.get("is_variadic")) |v2| params[j].is_variadic = v2.bool;
            }
            m.params = params;
        }
        methods[i] = m;
    }
    return methods;
}

fn parseReflectedProperties(allocator: std.mem.Allocator, val: std.json.Value) ![]const ReflectedProperty {
    const arr = val.array;
    var props = try allocator.alloc(ReflectedProperty, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const obj = item.object;
        var p: ReflectedProperty = .{
            .name = (obj.get("name") orelse return error.MissingField).string,
        };
        if (obj.get("visibility")) |v| p.visibility = v.string;
        if (obj.get("type")) |v| {
            p.type = switch (v) {
                .string => |s| s,
                .null => null,
                else => null,
            };
        }
        if (obj.get("is_static")) |v| p.is_static = v.bool;
        if (obj.get("is_readonly")) |v| p.is_readonly = v.bool;
        props[i] = p;
    }
    return props;
}

// ============================================================================
// Run PHPCMA pipeline on source
// ============================================================================

fn runPhpcmaPipeline(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
) !*SymbolTable {
    const php_lang = tree_sitter_php();

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(php_lang);

    const tree = parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const sym_table = try allocator.create(SymbolTable);
    sym_table.* = SymbolTable.init(allocator);

    var file_ctx = FileContext.init(allocator, file_path);
    defer file_ctx.deinit();

    var collector = SymbolCollector.init(allocator, sym_table, &file_ctx, source, php_lang);
    try collector.collect(tree);

    return sym_table;
}

// ============================================================================
// Core differential test runner
// ============================================================================

fn runDifferentialTest(php_source: []const u8) !void {
    if (!phpAvailable()) {
        std.debug.print("SKIP: php not available\n", .{});
        return;
    }

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Write temp file
    const tmp_path = try writeTempPhp(arena_alloc, php_source);
    defer cleanupTempFile(tmp_path);

    // Run PHPCMA pipeline
    const sym_table = try runPhpcmaPipeline(arena_alloc, php_source, tmp_path);
    defer {
        sym_table.deinit();
        arena_alloc.destroy(sym_table);
    }

    // Run PHP reflection
    const reflected = try runReflect(arena_alloc, tmp_path);

    // Compare
    var mismatches: std.ArrayListUnmanaged(Mismatch) = .empty;
    try compareClasses(arena_alloc, sym_table, reflected.classes, &mismatches);

    if (mismatches.items.len > 0) {
        std.debug.print("\n=== DIFFERENTIAL TEST MISMATCHES ===\n", .{});
        for (mismatches.items) |m| {
            std.debug.print("  [{s}] {s}: {s}\n", .{
                @tagName(m.kind),
                m.class,
                m.detail,
            });
        }
        std.debug.print("=== {d} mismatch(es) found ===\n\n", .{mismatches.items.len});
        return error.DifferentialMismatch;
    }
}

fn runMultiFileDifferentialTest(files: []const struct { name: []const u8, source: []const u8 }) !void {
    if (!phpAvailable()) {
        std.debug.print("SKIP: php not available\n", .{});
        return;
    }

    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Write all temp files
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files) |f| {
        const path = try std.fmt.allocPrint(arena_alloc, "/tmp/phpcma_diff_test_{s}_{d}.php", .{
            f.name,
            @as(u64, @intCast(std.time.milliTimestamp())),
        });
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(f.source);
        try paths.append(arena_alloc, path);
    }
    defer {
        for (paths.items) |p| cleanupTempFile(p);
    }

    // Run PHPCMA on all files
    const php_lang = tree_sitter_php();
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(php_lang);

    var sym_table = SymbolTable.init(arena_alloc);
    defer sym_table.deinit();

    for (files, 0..) |f, i| {
        var file_ctx = FileContext.init(arena_alloc, paths.items[i]);
        defer file_ctx.deinit();

        const tree = parser.parseString(f.source, null) orelse return error.ParseFailed;
        defer tree.destroy();

        var collector = SymbolCollector.init(arena_alloc, &sym_table, &file_ctx, f.source, php_lang);
        try collector.collect(tree);
    }

    // Run PHP reflection on all files
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena_alloc, "php");
    try argv.append(arena_alloc, "scripts/reflect.php");
    for (paths.items) |p| {
        try argv.append(arena_alloc, p);
    }

    const result = try std.process.Child.run(.{
        .allocator = arena_alloc,
        .argv = argv.items,
        .cwd = getProjectRoot(),
    });

    if (result.term.Exited != 0) {
        std.debug.print("reflect.php failed (exit {d}):\n{s}\n", .{ result.term.Exited, result.stderr });
        return error.ReflectFailed;
    }

    const reflected = try parseReflectJson(arena_alloc, result.stdout);

    // Compare
    var mismatches: std.ArrayListUnmanaged(Mismatch) = .empty;
    try compareClasses(arena_alloc, &sym_table, reflected.classes, &mismatches);

    if (mismatches.items.len > 0) {
        std.debug.print("\n=== DIFFERENTIAL TEST MISMATCHES ({d} files) ===\n", .{files.len});
        for (mismatches.items) |m| {
            std.debug.print("  [{s}] {s}: {s}\n", .{
                @tagName(m.kind),
                m.class,
                m.detail,
            });
        }
        std.debug.print("=== {d} mismatch(es) found ===\n\n", .{mismatches.items.len});
        return error.DifferentialMismatch;
    }
}

fn phpVersionId(allocator: std.mem.Allocator) !u32 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "php", "-r", "echo PHP_VERSION_ID;" },
        .cwd = getProjectRoot(),
    });
    if (result.term.Exited != 0) return error.PhpUnavailable;

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    return std.fmt.parseInt(u32, trimmed, 10);
}

fn phpVersionAtLeast(required: u32) bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const version = phpVersionId(arena.allocator()) catch return false;
    return version >= required;
}

// ============================================================================
// Test: Single class with properties and methods
// ============================================================================

test "differential: single class with methods" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class UserService
        \\{
        \\    private $name;
        \\    protected $age;
        \\    public $active;
        \\
        \\    public function getName(): string
        \\    {
        \\        return $this->name;
        \\    }
        \\
        \\    public function setAge(int $age): void
        \\    {
        \\        $this->age = $age;
        \\    }
        \\
        \\    private static function create(string $name, int $age): self
        \\    {
        \\        $svc = new self();
        \\        $svc->name = $name;
        \\        $svc->age = $age;
        \\        return $svc;
        \\    }
        \\}
    );
}

// ============================================================================
// Test: Class with inheritance
// ============================================================================

test "differential: class with inheritance" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class Animal
        \\{
        \\    protected $name;
        \\
        \\    public function __construct(string $name)
        \\    {
        \\        $this->name = $name;
        \\    }
        \\
        \\    public function getName(): string
        \\    {
        \\        return $this->name;
        \\    }
        \\}
        \\
        \\class Dog extends Animal
        \\{
        \\    private $tricks;
        \\
        \\    public function speak(): string
        \\    {
        \\        return 'Woof!';
        \\    }
        \\
        \\    public function learnTrick(): void
        \\    {
        \\        $this->tricks++;
        \\    }
        \\}
    );
}

// ============================================================================
// Test: Class with interface
// ============================================================================

test "differential: class with interface" {
    try runDifferentialTest(
        \\<?php
        \\
        \\interface Renderable
        \\{
        \\    public function render(): string;
        \\}
        \\
        \\interface Countable2
        \\{
        \\    public function count(): int;
        \\}
        \\
        \\class HtmlWidget implements Renderable, Countable2
        \\{
        \\    private $items;
        \\
        \\    public function __construct(array $items)
        \\    {
        \\        $this->items = $items;
        \\    }
        \\
        \\    public function render(): string
        \\    {
        \\        return '<div>' . implode('', $this->items) . '</div>';
        \\    }
        \\
        \\    public function count(): int
        \\    {
        \\        return count($this->items);
        \\    }
        \\}
    );
}

test "differential: constructor property promotion with readonly" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class Foo {}
        \\class Bar {}
        \\
        \\class PromotionService
        \\{
        \\    public function __construct(
        \\        private readonly Foo $foo,
        \\        protected ?Bar $bar = null,
        \\    ) {}
        \\
        \\    public function foo(): Foo
        \\    {
        \\        return $this->foo;
        \\    }
        \\
        \\    public function bar(): ?Bar
        \\    {
        \\        return $this->bar;
        \\    }
        \\}
    );
}

test "differential: union types" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class UnionTypes
        \\{
        \\    public function convert(int|string $x): array|false
        \\    {
        \\        if (is_int($x)) {
        \\            return ['value' => $x];
        \\        }
        \\        return false;
        \\    }
        \\}
    );
}

test "differential: intersection types" {
    try runDifferentialTest(
        \\<?php
        \\
        \\interface Foo {}
        \\interface Bar {}
        \\class Both implements Foo, Bar {}
        \\
        \\class IntersectionTypes
        \\{
        \\    public function useBoth(Foo&Bar $value): void
        \\    {
        \\    }
        \\}
    );
}

test "differential: nullable types" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class NullableTypes
        \\{
        \\    public function map(?string $input): ?int
        \\    {
        \\        return $input === null ? null : strlen($input);
        \\    }
        \\}
    );
}

test "differential: mixed type" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class MixedTypes
        \\{
        \\    public function passThrough(mixed $value): mixed
        \\    {
        \\        return $value;
        \\    }
        \\}
    );
}

test "differential: never return type" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class NeverType
        \\{
        \\    public function fail(string $message): never
        \\    {
        \\        throw new RuntimeException($message);
        \\    }
        \\}
    );
}

test "differential: enum with methods syntax coverage" {
    try runDifferentialTest(
        \\<?php
        \\
        \\function declareEnumForSyntaxCoverage(): void
        \\{
        \\    enum Suit: string {
        \\        case Hearts = 'H';
        \\        case Spades = 'S';
        \\
        \\        public function color(): string
        \\        {
        \\            return $this === self::Hearts ? 'red' : 'black';
        \\        }
        \\    }
        \\}
        \\
        \\class EnumSyntaxCoverage
        \\{
        \\    public function touch(string $name): string
        \\    {
        \\        return $name;
        \\    }
        \\}
    );
}

test "differential: readonly classes" {
    if (!phpVersionAtLeast(80200)) {
        std.debug.print("SKIP: readonly classes require PHP 8.2+\n", .{});
        return;
    }

    try runDifferentialTest(
        \\<?php
        \\
        \\readonly class ValueObject
        \\{
        \\    public function id(): string
        \\    {
        \\        return 'id';
        \\    }
        \\}
    );
}

test "differential: first-class callables" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class FirstClassCallableExample
        \\{
        \\    public function build(): callable
        \\    {
        \\        return strlen(...);
        \\    }
        \\}
    );
}

test "differential: named arguments" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class NamedArgumentExample
        \\{
        \\    private static function greet(string $name): string
        \\    {
        \\        return $name;
        \\    }
        \\
        \\    public function call(): string
        \\    {
        \\        return self::greet(name: 'bar');
        \\    }
        \\}
    );
}

test "differential: attributes" {
    try runDifferentialTest(
        \\<?php
        \\
        \\#[\Attribute(\Attribute::TARGET_CLASS)]
        \\class Route
        \\{
        \\    public function __construct(public string $path) {}
        \\}
        \\
        \\#[Route('/api')]
        \\class Controller
        \\{
        \\    public function __construct(private string $name = 'api') {}
        \\
        \\    public function name(): string
        \\    {
        \\        return $this->name;
        \\    }
        \\}
    );
}

test "differential: abstract class with concrete and abstract methods" {
    try runDifferentialTest(
        \\<?php
        \\
        \\abstract class AbstractProcessor
        \\{
        \\    abstract protected function process(string $value): string;
        \\
        \\    public function run(string $value): string
        \\    {
        \\        return $this->process($value);
        \\    }
        \\}
    );
}

test "differential: interface extending multiple interfaces" {
    try runDifferentialTest(
        \\<?php
        \\
        \\interface Reads
        \\{
        \\    public function read(): string;
        \\}
        \\
        \\interface Writes
        \\{
        \\    public function write(string $value): void;
        \\}
        \\
        \\interface ReadWrite extends Reads, Writes {}
        \\
        \\class FileGateway implements Reads, Writes, ReadWrite
        \\{
        \\    public function read(): string
        \\    {
        \\        return 'ok';
        \\    }
        \\
        \\    public function write(string $value): void
        \\    {
        \\    }
        \\}
    );
}

test "differential: trait conflict resolution syntax coverage" {
    try runDifferentialTest(
        \\<?php
        \\
        \\function declareTraitConflictCoverage(): void
        \\{
        \\    trait TraitA {
        \\        public function foo(): string { return 'a'; }
        \\    }
        \\    trait TraitB {
        \\        public function foo(): string { return 'b'; }
        \\    }
        \\    class UsesTraits {
        \\        use TraitA, TraitB {
        \\            TraitA::foo insteadof TraitB;
        \\            TraitB::foo as fooFromB;
        \\        }
        \\    }
        \\}
        \\
        \\class TraitConflictCoverage
        \\{
        \\    public function run(): int
        \\    {
        \\        return 1;
        \\    }
        \\}
    );
}

test "differential: anonymous classes" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class BaseItem {}
        \\
        \\class AnonymousClassExample
        \\{
        \\    public function make(): object
        \\    {
        \\        return new class extends BaseItem {
        \\            public function id(): string
        \\            {
        \\                return 'x';
        \\            }
        \\        };
        \\    }
        \\}
    );
}

test "differential: static return type" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class StaticFactory
        \\{
        \\    public static function create(): static
        \\    {
        \\        return new static();
        \\    }
        \\}
    );
}

test "differential: self return type" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class SelfReturnType
        \\{
        \\    public function cloneSelf(): self
        \\    {
        \\        return clone $this;
        \\    }
        \\}
    );
}

test "differential: variadic parameters" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class VariadicExample
        \\{
        \\    public function collect(string ...$args): array
        \\    {
        \\        return $args;
        \\    }
        \\}
    );
}

test "differential: default parameter values with complex expressions" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class DefaultValues
        \\{
        \\    public const BASE_PORT = 8000;
        \\
        \\    public function connect(
        \\        string $host = 'localhost',
        \\        int $port = self::BASE_PORT + 1,
        \\        array $options = ['retries' => 2, 'secure' => false],
        \\    ): array {
        \\        return [$host, $port, $options];
        \\    }
        \\}
    );
}

test "differential: nested namespace declarations" {
    try runDifferentialTest(
        \\<?php
        \\
        \\namespace Outer;
        \\
        \\class OuterClass
        \\{
        \\    public function root(): string
        \\    {
        \\        return 'outer';
        \\    }
        \\}
        \\
        \\namespace Outer\Inner;
        \\
        \\class NestedNamespaceClass
        \\{
        \\    public function name(): string
        \\    {
        \\        return 'nested';
        \\    }
        \\}
    );
}

test "differential: multiple classes in single file" {
    try runDifferentialTest(
        \\<?php
        \\
        \\class FirstClass
        \\{
        \\    public function id(): string
        \\    {
        \\        return 'first';
        \\    }
        \\}
        \\
        \\class SecondClass
        \\{
        \\    public function id(): string
        \\    {
        \\        return 'second';
        \\    }
        \\}
    );
}

test "differential: typed class constants" {
    if (!phpVersionAtLeast(80300)) {
        std.debug.print("SKIP: typed class constants require PHP 8.3+\n", .{});
        return;
    }

    try runDifferentialTest(
        \\<?php
        \\
        \\class TypedConstantExample
        \\{
        \\    public const string NAME = 'foo';
        \\
        \\    public function getName(): string
        \\    {
        \\        return self::NAME;
        \\    }
        \\}
    );
}

test "differential: multi-file namespace class resolution" {
    try runMultiFileDifferentialTest(&.{
        .{ .name = "base", .source = 
        \\<?php
        \\
        \\namespace Shared;
        \\
        \\interface Contract
        \\{
        \\    public function id(): string;
        \\}
        },
        .{ .name = "impl", .source = 
        \\<?php
        \\
        \\namespace Shared;
        \\
        \\class Implementation implements Contract
        \\{
        \\    public function id(): string
        \\    {
        \\        return 'impl';
        \\    }
        \\}
        },
    });
}
