const std = @import("std");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;
const TemplateParam = types.TemplateParam;

// ============================================================================
// PHPDoc Parser
// ============================================================================

/// Parsed PHPDoc block
pub const DocBlock = struct {
    description: ?[]const u8,
    params: std.StringHashMap(TypeInfo), // @param Type $name -> name -> Type
    return_type: ?TypeInfo, // @return Type
    var_type: ?TypeInfo, // @var Type
    throws: []const TypeInfo, // @throws Exception
    deprecated: bool,
    inheritdoc: bool,

    // Generic type annotations
    template_params: []const TemplateParam, // @template T, @template T of Foo
    generic_extends: ?TypeInfo, // @extends Collection<User>
    generic_implements: []const TypeInfo, // @implements Repository<User>

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DocBlock {
        return .{
            .description = null,
            .params = std.StringHashMap(TypeInfo).init(allocator),
            .return_type = null,
            .var_type = null,
            .throws = &.{},
            .deprecated = false,
            .inheritdoc = false,
            .template_params = &.{},
            .generic_extends = null,
            .generic_implements = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DocBlock) void {
        self.params.deinit();
    }

    pub fn getParamType(self: *const DocBlock, param_name: []const u8) ?TypeInfo {
        // Remove $ prefix if present
        const name = if (param_name.len > 0 and param_name[0] == '$')
            param_name[1..]
        else
            param_name;
        return self.params.get(name);
    }
};

/// Parse a PHPDoc comment string
pub fn parsePhpDoc(allocator: std.mem.Allocator, comment: []const u8) !DocBlock {
    var doc = DocBlock.init(allocator);
    var throws_list: std.ArrayListUnmanaged(TypeInfo) = .empty;
    errdefer throws_list.deinit(allocator);
    var template_list: std.ArrayListUnmanaged(TemplateParam) = .empty;
    errdefer template_list.deinit(allocator);
    var generic_impl_list: std.ArrayListUnmanaged(TypeInfo) = .empty;
    errdefer generic_impl_list.deinit(allocator);

    // Split into lines and process
    var lines = std.mem.splitSequence(u8, comment, "\n");
    while (lines.next()) |raw_line| {
        const line = trimDocLine(raw_line);
        if (line.len == 0) continue;

        // Check for annotations
        if (std.mem.startsWith(u8, line, "@param")) {
            if (try parseParamAnnotation(allocator, line)) |result| {
                try doc.params.put(result.name, result.type_info);
            }
        } else if (std.mem.startsWith(u8, line, "@return")) {
            doc.return_type = try parseTypeAnnotation(allocator, line["@return".len..]);
        } else if (std.mem.startsWith(u8, line, "@var")) {
            doc.var_type = try parseTypeAnnotation(allocator, line["@var".len..]);
        } else if (std.mem.startsWith(u8, line, "@throws") or std.mem.startsWith(u8, line, "@exception")) {
            const rest = if (std.mem.startsWith(u8, line, "@throws"))
                line["@throws".len..]
            else
                line["@exception".len..];
            if (try parseTypeAnnotation(allocator, rest)) |t| {
                try throws_list.append(allocator, t);
            }
        } else if (std.mem.startsWith(u8, line, "@template")) {
            if (parseTemplateAnnotation(allocator, line)) |tpl| {
                try template_list.append(allocator, tpl);
            }
        } else if (std.mem.startsWith(u8, line, "@extends") or std.mem.startsWith(u8, line, "@phpstan-extends") or std.mem.startsWith(u8, line, "@psalm-extends")) {
            const rest = if (std.mem.startsWith(u8, line, "@phpstan-extends"))
                line["@phpstan-extends".len..]
            else if (std.mem.startsWith(u8, line, "@psalm-extends"))
                line["@psalm-extends".len..]
            else
                line["@extends".len..];
            doc.generic_extends = try parseTypeAnnotation(allocator, rest);
        } else if (std.mem.startsWith(u8, line, "@implements") or std.mem.startsWith(u8, line, "@phpstan-implements") or std.mem.startsWith(u8, line, "@psalm-implements")) {
            const rest = if (std.mem.startsWith(u8, line, "@phpstan-implements"))
                line["@phpstan-implements".len..]
            else if (std.mem.startsWith(u8, line, "@psalm-implements"))
                line["@psalm-implements".len..]
            else
                line["@implements".len..];
            if (try parseTypeAnnotation(allocator, rest)) |t| {
                try generic_impl_list.append(allocator, t);
            }
        } else if (std.mem.startsWith(u8, line, "@deprecated")) {
            doc.deprecated = true;
        } else if (std.mem.startsWith(u8, line, "@inheritdoc") or std.mem.startsWith(u8, line, "{@inheritdoc}")) {
            doc.inheritdoc = true;
        }
    }

    doc.throws = try throws_list.toOwnedSlice(allocator);
    doc.template_params = try template_list.toOwnedSlice(allocator);
    doc.generic_implements = try generic_impl_list.toOwnedSlice(allocator);
    return doc;
}

/// Parse @param Type $name annotation
fn parseParamAnnotation(allocator: std.mem.Allocator, line: []const u8) !?struct { name: []const u8, type_info: TypeInfo } {
    // Skip "@param" and whitespace
    var rest = std.mem.trimStart(u8, line["@param".len..], " \t");

    // Parse type
    const type_info = try parseTypeAnnotation(allocator, rest) orelse return null;

    // Find variable name (starts with $)
    rest = std.mem.trimStart(u8, rest, " \t");

    // Skip past type to find $name
    var i: usize = 0;
    var depth: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c == '<' or c == '(' or c == '{') {
            depth += 1;
        } else if (c == '>' or c == ')' or c == '}') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and (c == ' ' or c == '\t')) {
            break;
        }
    }

    rest = std.mem.trimStart(u8, rest[i..], " \t");

    // Find $varname
    if (rest.len > 0 and rest[0] == '$') {
        // Find end of variable name
        var end: usize = 1;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}

        const var_name = rest[1..end]; // Without $
        return .{ .name = try allocator.dupe(u8, var_name), .type_info = type_info };
    }

    return null;
}

/// Parse @template annotation: @template T or @template T of SomeClass
fn parseTemplateAnnotation(allocator: std.mem.Allocator, line: []const u8) ?TemplateParam {
    // Skip "@template" and whitespace
    var rest = std.mem.trimStart(u8, line["@template".len..], " \t");
    if (rest.len == 0) return null;

    // Parse template name (single identifier)
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
    if (end == 0) return null;

    const name = rest[0..end];
    rest = std.mem.trimStart(u8, rest[end..], " \t");

    // Check for "of" bound
    var bound: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "of ") or std.mem.startsWith(u8, rest, "of\t")) {
        rest = std.mem.trimStart(u8, rest[2..], " \t");
        // Parse bound type name
        var bound_end: usize = 0;
        while (bound_end < rest.len and rest[bound_end] != ' ' and rest[bound_end] != '\t' and rest[bound_end] != '\n') : (bound_end += 1) {}
        if (bound_end > 0) {
            bound = allocator.dupe(u8, rest[0..bound_end]) catch return null;
        }
    }

    return .{
        .name = allocator.dupe(u8, name) catch return null,
        .bound = bound,
    };
}

/// Parse a type annotation (the type part after @return, @var, etc.)
fn parseTypeAnnotation(allocator: std.mem.Allocator, rest: []const u8) !?TypeInfo {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len == 0) return null;

    // Find end of type (space, end of line, or description start)
    var end: usize = 0;
    var depth: usize = 0;
    while (end < trimmed.len) : (end += 1) {
        const c = trimmed[end];
        if (c == '<' or c == '(' or c == '{' or c == '[') {
            depth += 1;
        } else if (c == '>' or c == ')' or c == '}' or c == ']') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and (c == ' ' or c == '\t' or c == '\n')) {
            break;
        }
    }

    if (end == 0) return null;

    const type_str = trimmed[0..end];
    return try parseTypeString(allocator, type_str);
}

/// Parse a type string into TypeInfo
pub fn parseTypeString(allocator: std.mem.Allocator, type_str: []const u8) !TypeInfo {
    const trimmed = std.mem.trim(u8, type_str, " \t");
    if (trimmed.len == 0) {
        return TypeInfo{
            .kind = .mixed,
            .base_type = "mixed",
            .type_parts = &.{},
            .is_builtin = true,
        };
    }

    // Check for nullable prefix
    if (trimmed[0] == '?') {
        const inner = trimmed[1..];
        return TypeInfo{
            .kind = .nullable,
            .base_type = try allocator.dupe(u8, inner),
            .type_parts = &.{},
            .is_builtin = TypeInfo.isBuiltin(inner),
        };
    }

    // Check for union type (contains |)
    if (std.mem.indexOf(u8, trimmed, "|")) |_| {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, trimmed, '|');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len > 0) {
                try parts.append(allocator, try allocator.dupe(u8, p));
            }
        }
        return TypeInfo{
            .kind = .union_type,
            .base_type = try allocator.dupe(u8, trimmed),
            .type_parts = try parts.toOwnedSlice(allocator),
            .is_builtin = false,
        };
    }

    // Check for intersection type (contains &)
    if (std.mem.indexOf(u8, trimmed, "&")) |_| {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, trimmed, '&');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len > 0) {
                try parts.append(allocator, try allocator.dupe(u8, p));
            }
        }
        return TypeInfo{
            .kind = .intersection,
            .base_type = try allocator.dupe(u8, trimmed),
            .type_parts = try parts.toOwnedSlice(allocator),
            .is_builtin = false,
        };
    }

    // Check for array syntax (Type[] or array<Type>)
    if (std.mem.endsWith(u8, trimmed, "[]")) {
        const inner = trimmed[0 .. trimmed.len - 2];
        return TypeInfo{
            .kind = .array_type,
            .base_type = try allocator.dupe(u8, inner),
            .type_parts = &.{},
            .is_builtin = false,
        };
    }

    // Check for generic type syntax: Name<Params>
    if (std.mem.indexOf(u8, trimmed, "<")) |angle_pos| {
        // Find matching '>'
        if (std.mem.lastIndexOf(u8, trimmed, ">")) |close_pos| {
            const base = std.mem.trim(u8, trimmed[0..angle_pos], " \t");
            const params_str = trimmed[angle_pos + 1 .. close_pos];

            // Special case: array<Key, Value> stays as array_type
            if (std.mem.eql(u8, base, "array") or std.mem.eql(u8, base, "Array")) {
                return TypeInfo{
                    .kind = .array_type,
                    .base_type = try allocator.dupe(u8, trimmed),
                    .type_parts = &.{},
                    .is_builtin = true,
                };
            }

            // Parse generic type params (comma-separated, respecting nesting)
            var param_list: std.ArrayListUnmanaged(TypeInfo) = .empty;
            errdefer param_list.deinit(allocator);

            var depth: usize = 0;
            var start: usize = 0;
            for (params_str, 0..) |c, i| {
                if (c == '<') {
                    depth += 1;
                } else if (c == '>') {
                    if (depth > 0) depth -= 1;
                } else if (c == ',' and depth == 0) {
                    const param_str = std.mem.trim(u8, params_str[start..i], " \t");
                    if (param_str.len > 0) {
                        try param_list.append(allocator, try parseTypeString(allocator, param_str));
                    }
                    start = i + 1;
                }
            }
            // Last param
            const last_param = std.mem.trim(u8, params_str[start..], " \t");
            if (last_param.len > 0) {
                try param_list.append(allocator, try parseTypeString(allocator, last_param));
            }

            return TypeInfo{
                .kind = .generic,
                .base_type = try allocator.dupe(u8, base),
                .type_parts = &.{},
                .type_params = try param_list.toOwnedSlice(allocator),
                .is_builtin = false,
            };
        }
    }

    // Check for special types
    if (std.mem.eql(u8, trimmed, "void")) {
        return TypeInfo{
            .kind = .void_type,
            .base_type = "void",
            .type_parts = &.{},
            .is_builtin = true,
        };
    }

    if (std.mem.eql(u8, trimmed, "never")) {
        return TypeInfo{
            .kind = .never,
            .base_type = "never",
            .type_parts = &.{},
            .is_builtin = true,
        };
    }

    if (std.mem.eql(u8, trimmed, "mixed")) {
        return TypeInfo{
            .kind = .mixed,
            .base_type = "mixed",
            .type_parts = &.{},
            .is_builtin = true,
        };
    }

    if (std.mem.eql(u8, trimmed, "self")) {
        return TypeInfo{
            .kind = .self_type,
            .base_type = "self",
            .type_parts = &.{},
            .is_builtin = false,
        };
    }

    if (std.mem.eql(u8, trimmed, "static")) {
        return TypeInfo{
            .kind = .static_type,
            .base_type = "static",
            .type_parts = &.{},
            .is_builtin = false,
        };
    }

    if (std.mem.eql(u8, trimmed, "parent")) {
        return TypeInfo{
            .kind = .parent_type,
            .base_type = "parent",
            .type_parts = &.{},
            .is_builtin = false,
        };
    }

    // Simple type
    return TypeInfo{
        .kind = .simple,
        .base_type = try allocator.dupe(u8, trimmed),
        .type_parts = &.{},
        .is_builtin = TypeInfo.isBuiltin(trimmed),
    };
}

/// Extract the last type argument from a generic type string like
/// `Collection<Foo>` -> "Foo", `array<int, Foo>` -> "Foo", `iterable<Foo>` ->
/// "Foo". Returns null when there is no `<...>` or it is empty. Nesting is
/// respected so `array<int, Collection<Foo>>` yields "Collection<Foo>".
fn lastGenericArg(type_str: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, type_str, '<') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, type_str, '>') orelse return null;
    if (close <= open + 1) return null;
    const inner = type_str[open + 1 .. close];

    // Split on the top-level comma (depth 0) and take the final segment.
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

/// Resolve a parsed docblock type's class-like names to their FQCNs using `fc`
/// (the declaring file's namespace + imports), so they match symbol-table keys.
/// Collection-shaped types (`Foo[]`, `array<Foo>`, `iterable<Foo>`,
/// `Collection<Foo>`) are normalized to an `array_type` whose `base_type` is the
/// FQCN of the element, which is what foreach element typing and chains consume.
/// Builtins and special types (self/static/parent/void/...) pass through.
pub fn resolveTypeFqcn(allocator: std.mem.Allocator, fc: *const types.FileContext, info: TypeInfo) !TypeInfo {
    switch (info.kind) {
        .simple, .nullable => {
            // A generic written without `[]` (e.g. `Collection<Foo>`) parses as a
            // simple type whose name carries `<...>`. Treat it as a collection of
            // its last type argument.
            if (std.mem.indexOfScalar(u8, info.base_type, '<') != null) {
                if (lastGenericArg(info.base_type)) |elem| {
                    const resolved = try fc.resolveFQCN(elem);
                    return TypeInfo{
                        .kind = .array_type,
                        .base_type = try allocator.dupe(u8, resolved),
                        .type_parts = &.{},
                        .is_builtin = false,
                    };
                }
                return info;
            }
            if (!info.is_builtin) {
                const resolved = try fc.resolveFQCN(info.base_type);
                return TypeInfo{
                    .kind = info.kind,
                    .base_type = try allocator.dupe(u8, resolved),
                    .type_parts = info.type_parts,
                    .is_builtin = false,
                };
            }
            return info;
        },
        .generic => {
            // A generic such as `Collection<Item>` is treated as a collection of
            // its last type argument; resolve that element to its FQCN and expose
            // it as an `array_type` so collection-element navigation keeps working.
            if (info.type_params.len > 0) {
                const elem = info.type_params[info.type_params.len - 1];
                const resolved = try fc.resolveFQCN(elem.base_type);
                return TypeInfo{
                    .kind = .array_type,
                    .base_type = try allocator.dupe(u8, resolved),
                    .type_parts = &.{},
                    .is_builtin = false,
                };
            }
            return info;
        },
        .array_type => {
            // `array<...>` generic: element is the last type argument.
            if (lastGenericArg(info.base_type)) |elem| {
                const resolved = try fc.resolveFQCN(elem);
                return TypeInfo{
                    .kind = .array_type,
                    .base_type = try allocator.dupe(u8, resolved),
                    .type_parts = &.{},
                    .is_builtin = false,
                };
            }
            // Bare `array`/`iterable` carry no element type.
            if (TypeInfo.isBuiltin(info.base_type)) return info;
            // `Foo[]`: base_type is the element name; resolve it.
            const resolved = try fc.resolveFQCN(info.base_type);
            return TypeInfo{
                .kind = .array_type,
                .base_type = try allocator.dupe(u8, resolved),
                .type_parts = &.{},
                .is_builtin = false,
            };
        },
        else => return info,
    }
}

/// Trim PHPDoc line (remove leading *, whitespace, etc.)
fn trimDocLine(line: []const u8) []const u8 {
    var result = std.mem.trim(u8, line, " \t\r");

    // Remove leading /** or */
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

/// Check if a comment is a PHPDoc comment (starts with /**)
pub fn isPhpDoc(comment: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, comment, " \t\n\r");
    return std.mem.startsWith(u8, trimmed, "/**");
}

/// Extract inline @var annotation: /** @var Type */
pub fn parseInlineVar(allocator: std.mem.Allocator, comment: []const u8) !?TypeInfo {
    const named = try parseInlineVarNamed(allocator, comment) orelse return null;
    return named.type_info;
}

/// Inline `@var` annotation, including the optional target variable name.
pub const InlineVar = struct {
    type_info: TypeInfo,
    /// Variable named by the annotation (without the leading `$`), if present:
    /// `/** @var Foo $x */` -> "x"; `/** @var Foo */` -> null.
    var_name: ?[]const u8,
};

/// Extract an inline `@var` annotation together with the variable it targets.
/// Both `/** @var Type */` and `/** @var Type $name */` forms are supported; the
/// type may itself precede or follow the variable name in some codebases
/// (`@var $name Type`), which is handled too.
pub fn parseInlineVarNamed(allocator: std.mem.Allocator, comment: []const u8) !?InlineVar {
    if (!isPhpDoc(comment)) return null;

    var lines = std.mem.splitSequence(u8, comment, "\n");
    while (lines.next()) |raw_line| {
        const line = trimDocLine(raw_line);
        if (!std.mem.startsWith(u8, line, "@var")) continue;

        const rest = std.mem.trim(u8, line["@var".len..], " \t");
        // Pull out the first `$name` token (if any) and the first non-`$` token
        // as the type, regardless of their order.
        var var_name: ?[]const u8 = null;
        var type_str: ?[]const u8 = null;
        var it = std.mem.tokenizeAny(u8, rest, " \t");
        while (it.next()) |tok| {
            if (tok.len > 0 and tok[0] == '$') {
                if (var_name == null) var_name = tok[1..];
            } else if (type_str == null) {
                type_str = tok;
            }
            if (var_name != null and type_str != null) break;
        }

        const ts_str = type_str orelse return null;
        const type_info = try parseTypeString(allocator, ts_str);
        return InlineVar{
            .type_info = type_info,
            .var_name = if (var_name) |n| try allocator.dupe(u8, n) else null,
        };
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

fn testAllocator() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "parse simple @param" {
    // Parsed TypeInfo/strings are arena-allocated in production; mirror that here
    // so the test frees everything wholesale (TypeInfo has no deinit).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * Some description
        \\ * @param string $name The user's name
        \\ * @param int $age
        \\ * @return bool
        \\ */
    );

    try std.testing.expect(doc.params.contains("name"));
    try std.testing.expect(doc.params.contains("age"));
    try std.testing.expect(doc.return_type != null);
    try std.testing.expectEqualStrings("bool", doc.return_type.?.base_type);
}

test "parse nullable type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const type_info = try parseTypeString(allocator, "?string");

    try std.testing.expect(type_info.kind == .nullable);
    try std.testing.expectEqualStrings("string", type_info.base_type);
}

test "parse union type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const type_info = try parseTypeString(allocator, "string|int|null");

    try std.testing.expect(type_info.kind == .union_type);
    try std.testing.expect(type_info.type_parts.len == 3);
}

test "parse array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const type_info = try parseTypeString(allocator, "User[]");

    try std.testing.expect(type_info.kind == .array_type);
    try std.testing.expectEqualStrings("User", type_info.base_type);
}

test "parseInlineVarNamed: typed + named, named-first, and unnamed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const named = (try parseInlineVarNamed(a, "/** @var \\App\\Foo $x the foo */")).?;
    try std.testing.expectEqualStrings("Foo", named.type_info.base_type[named.type_info.base_type.len - 3 ..]);
    try std.testing.expectEqualStrings("x", named.var_name.?);

    const swapped = (try parseInlineVarNamed(a, "/** @var $y Bar */")).?;
    try std.testing.expectEqualStrings("Bar", swapped.type_info.base_type);
    try std.testing.expectEqualStrings("y", swapped.var_name.?);

    const unnamed = (try parseInlineVarNamed(a, "/** @var Baz */")).?;
    try std.testing.expectEqualStrings("Baz", unnamed.type_info.base_type);
    try std.testing.expect(unnamed.var_name == null);

    try std.testing.expect((try parseInlineVarNamed(a, "// not a docblock")) == null);
}

test "lastGenericArg: extracts the element type, respecting nesting" {
    try std.testing.expectEqualStrings("Foo", lastGenericArg("Collection<Foo>").?);
    try std.testing.expectEqualStrings("Foo", lastGenericArg("array<int, Foo>").?);
    try std.testing.expectEqualStrings("Collection<Foo>", lastGenericArg("array<int, Collection<Foo>>").?);
    try std.testing.expect(lastGenericArg("Foo") == null);
    try std.testing.expect(lastGenericArg("array<>") == null);
}

test "resolveTypeFqcn: Foo[] and Collection<Foo> normalize to array_type element FQCN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fc = types.FileContext.init(a, "test.php");
    defer fc.deinit();
    fc.namespace = "App";

    const arr = try resolveTypeFqcn(a, &fc, try parseTypeString(a, "Item[]"));
    try std.testing.expect(arr.kind == .array_type);
    try std.testing.expectEqualStrings("App\\Item", arr.base_type);

    const gen = try resolveTypeFqcn(a, &fc, try parseTypeString(a, "Collection<Item>"));
    try std.testing.expect(gen.kind == .array_type);
    try std.testing.expectEqualStrings("App\\Item", gen.base_type);

    // Bare array has no element type -> passes through unchanged.
    const bare = try resolveTypeFqcn(a, &fc, try parseTypeString(a, "array"));
    try std.testing.expect(bare.kind == .simple);
    try std.testing.expectEqualStrings("array", bare.base_type);
}

test "parse simple type string" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "string");

    try std.testing.expect(type_info.kind == .simple);
    try std.testing.expectEqualStrings("string", type_info.base_type);
    try std.testing.expect(type_info.is_builtin);
}

test "parse intersection type" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "Countable&Traversable");

    try std.testing.expect(type_info.kind == .intersection);
    try std.testing.expect(type_info.type_parts.len == 2);
    try std.testing.expectEqualStrings("Countable", type_info.type_parts[0]);
    try std.testing.expectEqualStrings("Traversable", type_info.type_parts[1]);
}

test "parse special types: void, never, mixed, self, static, parent" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();

    const void_t = try parseTypeString(allocator, "void");
    try std.testing.expect(void_t.kind == .void_type);
    try std.testing.expect(void_t.is_builtin);

    const never_t = try parseTypeString(allocator, "never");
    try std.testing.expect(never_t.kind == .never);
    try std.testing.expect(never_t.is_builtin);

    const mixed_t = try parseTypeString(allocator, "mixed");
    try std.testing.expect(mixed_t.kind == .mixed);
    try std.testing.expect(mixed_t.is_builtin);

    const self_t = try parseTypeString(allocator, "self");
    try std.testing.expect(self_t.kind == .self_type);
    try std.testing.expect(!self_t.is_builtin);

    const static_t = try parseTypeString(allocator, "static");
    try std.testing.expect(static_t.kind == .static_type);
    try std.testing.expect(!static_t.is_builtin);

    const parent_t = try parseTypeString(allocator, "parent");
    try std.testing.expect(parent_t.kind == .parent_type);
    try std.testing.expect(!parent_t.is_builtin);
}

test "parse FQCN type" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "App\\Models\\User");

    try std.testing.expect(type_info.kind == .simple);
    try std.testing.expectEqualStrings("App\\Models\\User", type_info.base_type);
    try std.testing.expect(!type_info.is_builtin);
}

test "parse @param with alias and description" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * @param string $userName The user's display name
        \\ * @param int $maxRetries Maximum number of retries allowed
        \\ */
    );

    try std.testing.expect(doc.params.contains("userName"));
    const name_type = doc.params.get("userName").?;
    try std.testing.expectEqualStrings("string", name_type.base_type);

    try std.testing.expect(doc.params.contains("maxRetries"));
    const retries_type = doc.params.get("maxRetries").?;
    try std.testing.expectEqualStrings("int", retries_type.base_type);
}

test "parse complex generics type" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "array<string,int>");

    try std.testing.expect(type_info.kind == .array_type);
    try std.testing.expect(type_info.is_builtin);
}

test "parse generic type Collection<User>" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "Collection<User>");

    try std.testing.expect(type_info.kind == .generic);
    try std.testing.expectEqualStrings("Collection", type_info.base_type);
    try std.testing.expect(type_info.type_params.len == 1);
    try std.testing.expectEqualStrings("User", type_info.type_params[0].base_type);
    try std.testing.expect(!type_info.is_builtin);
}

test "parse nested generic type Repository<Collection<User>>" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "Repository<Collection<User>>");

    try std.testing.expect(type_info.kind == .generic);
    try std.testing.expectEqualStrings("Repository", type_info.base_type);
    try std.testing.expect(type_info.type_params.len == 1);
    try std.testing.expect(type_info.type_params[0].kind == .generic);
    try std.testing.expectEqualStrings("Collection", type_info.type_params[0].base_type);
    try std.testing.expect(type_info.type_params[0].type_params.len == 1);
    try std.testing.expectEqualStrings("User", type_info.type_params[0].type_params[0].base_type);
}

test "parse @template annotation" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * @template T
        \\ * @template V of SomeClass
        \\ */
    );

    try std.testing.expect(doc.template_params.len == 2);
    try std.testing.expectEqualStrings("T", doc.template_params[0].name);
    try std.testing.expect(doc.template_params[0].bound == null);
    try std.testing.expectEqualStrings("V", doc.template_params[1].name);
    try std.testing.expect(doc.template_params[1].bound != null);
    try std.testing.expectEqualStrings("SomeClass", doc.template_params[1].bound.?);
}

test "parse @extends with generic param" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * @extends Collection<User>
        \\ */
    );

    try std.testing.expect(doc.generic_extends != null);
    try std.testing.expect(doc.generic_extends.?.kind == .generic);
    try std.testing.expectEqualStrings("Collection", doc.generic_extends.?.base_type);
    try std.testing.expect(doc.generic_extends.?.type_params.len == 1);
    try std.testing.expectEqualStrings("User", doc.generic_extends.?.type_params[0].base_type);
}

test "parse @phpstan-extends and @psalm-extends" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc1 = try parsePhpDoc(allocator,
        \\/**
        \\ * @phpstan-extends Repository<Product>
        \\ */
    );
    try std.testing.expect(doc1.generic_extends != null);
    try std.testing.expect(doc1.generic_extends.?.kind == .generic);
    try std.testing.expectEqualStrings("Repository", doc1.generic_extends.?.base_type);

    const doc2 = try parsePhpDoc(allocator,
        \\/**
        \\ * @psalm-extends Repository<Product>
        \\ */
    );
    try std.testing.expect(doc2.generic_extends != null);
    try std.testing.expect(doc2.generic_extends.?.kind == .generic);
    try std.testing.expectEqualStrings("Repository", doc2.generic_extends.?.base_type);
}

test "parse @implements with generic param" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * @implements Repository<User>
        \\ */
    );

    try std.testing.expect(doc.generic_implements.len == 1);
    try std.testing.expect(doc.generic_implements[0].kind == .generic);
    try std.testing.expectEqualStrings("Repository", doc.generic_implements[0].base_type);
    try std.testing.expect(doc.generic_implements[0].type_params.len == 1);
    try std.testing.expectEqualStrings("User", doc.generic_implements[0].type_params[0].base_type);
}

test "parse multi-annotation docblock" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();
    const doc = try parsePhpDoc(allocator,
        \\/**
        \\ * Process a user request.
        \\ *
        \\ * @param string $action The action to perform
        \\ * @param int $userId The user ID
        \\ * @return bool Whether the action succeeded
        \\ * @throws RuntimeException If processing fails
        \\ * @deprecated
        \\ */
    );

    try std.testing.expect(doc.params.contains("action"));
    try std.testing.expect(doc.params.contains("userId"));
    try std.testing.expect(doc.return_type != null);
    try std.testing.expectEqualStrings("bool", doc.return_type.?.base_type);
    try std.testing.expect(doc.throws.len == 1);
    try std.testing.expectEqualStrings("RuntimeException", doc.throws[0].base_type);
    try std.testing.expect(doc.deprecated);
}

test "parse @inheritdoc" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();

    const doc1 = try parsePhpDoc(allocator,
        \\/**
        \\ * @inheritdoc
        \\ */
    );
    try std.testing.expect(doc1.inheritdoc);

    const doc2 = try parsePhpDoc(allocator,
        \\/**
        \\ * {@inheritdoc}
        \\ */
    );
    try std.testing.expect(doc2.inheritdoc);
}

test "parse @deprecated" {
    var arena = testAllocator();
    defer arena.deinit();
    const doc = try parsePhpDoc(arena.allocator(),
        \\/**
        \\ * @deprecated Use newMethod() instead
        \\ */
    );
    try std.testing.expect(doc.deprecated);
}

test "parse inline @var" {
    var arena = testAllocator();
    defer arena.deinit();
    const result = try parseInlineVar(arena.allocator(), "/** @var string */");

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.kind == .simple);
    try std.testing.expectEqualStrings("string", result.?.base_type);
}

test "parse empty docblock" {
    var arena = testAllocator();
    defer arena.deinit();
    const doc = try parsePhpDoc(arena.allocator(),
        \\/**
        \\ */
    );

    try std.testing.expect(!doc.deprecated);
    try std.testing.expect(!doc.inheritdoc);
    try std.testing.expect(doc.return_type == null);
    try std.testing.expect(doc.var_type == null);
    try std.testing.expect(doc.throws.len == 0);
    try std.testing.expect(doc.params.count() == 0);
}

test "parse malformed docblock" {
    var arena = testAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();

    // @param with no variable name
    const doc1 = try parsePhpDoc(allocator,
        \\/**
        \\ * @param string
        \\ */
    );
    try std.testing.expect(doc1.params.count() == 0);

    // @return with no type
    const doc2 = try parsePhpDoc(allocator,
        \\/**
        \\ * @return
        \\ */
    );
    try std.testing.expect(doc2.return_type == null);
}

test "parse @throws annotation" {
    var arena = testAllocator();
    defer arena.deinit();
    const doc = try parsePhpDoc(arena.allocator(),
        \\/**
        \\ * @throws InvalidArgumentException
        \\ * @throws RuntimeException
        \\ */
    );

    try std.testing.expect(doc.throws.len == 2);
    try std.testing.expectEqualStrings("InvalidArgumentException", doc.throws[0].base_type);
    try std.testing.expectEqualStrings("RuntimeException", doc.throws[1].base_type);
}

