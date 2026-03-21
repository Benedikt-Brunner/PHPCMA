const std = @import("std");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;

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
        } else if (std.mem.startsWith(u8, line, "@deprecated")) {
            doc.deprecated = true;
        } else if (std.mem.startsWith(u8, line, "@inheritdoc") or std.mem.startsWith(u8, line, "{@inheritdoc}")) {
            doc.inheritdoc = true;
        }
    }

    doc.throws = try throws_list.toOwnedSlice(allocator);
    return doc;
}

/// Parse @param Type $name annotation
fn parseParamAnnotation(allocator: std.mem.Allocator, line: []const u8) !?struct { name: []const u8, type_info: TypeInfo } {
    // Skip "@param" and whitespace
    var rest = std.mem.trimLeft(u8, line["@param".len..], " \t");

    // Parse type
    const type_info = try parseTypeAnnotation(allocator, rest) orelse return null;

    // Find variable name (starts with $)
    rest = std.mem.trimLeft(u8, rest, " \t");

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

    rest = std.mem.trimLeft(u8, rest[i..], " \t");

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

/// Parse a type annotation (the type part after @return, @var, etc.)
fn parseTypeAnnotation(allocator: std.mem.Allocator, rest: []const u8) !?TypeInfo {
    const trimmed = std.mem.trimLeft(u8, rest, " \t");
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

    // Check for generic array syntax array<Key, Value>
    if (std.mem.startsWith(u8, trimmed, "array<") or std.mem.startsWith(u8, trimmed, "Array<")) {
        // For now, just treat as array
        return TypeInfo{
            .kind = .array_type,
            .base_type = try allocator.dupe(u8, trimmed),
            .type_parts = &.{},
            .is_builtin = true,
        };
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
    const trimmed = std.mem.trimLeft(u8, comment, " \t\n\r");
    return std.mem.startsWith(u8, trimmed, "/**");
}

/// Extract inline @var annotation: /** @var Type */
pub fn parseInlineVar(allocator: std.mem.Allocator, comment: []const u8) !?TypeInfo {
    if (!isPhpDoc(comment)) return null;

    var lines = std.mem.splitSequence(u8, comment, "\n");
    while (lines.next()) |raw_line| {
        const line = trimDocLine(raw_line);
        if (std.mem.startsWith(u8, line, "@var")) {
            return try parseTypeAnnotation(allocator, line["@var".len..]);
        }
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
    var arena = testAllocator();
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
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "?string");

    try std.testing.expect(type_info.kind == .nullable);
    try std.testing.expectEqualStrings("string", type_info.base_type);
}

test "parse union type" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "string|int|null");

    try std.testing.expect(type_info.kind == .union_type);
    try std.testing.expect(type_info.type_parts.len == 3);
}

test "parse array type" {
    var arena = testAllocator();
    defer arena.deinit();
    const type_info = try parseTypeString(arena.allocator(), "User[]");

    try std.testing.expect(type_info.kind == .array_type);
    try std.testing.expectEqualStrings("User", type_info.base_type);
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
