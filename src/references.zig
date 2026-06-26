const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");

const FileContext = types.FileContext;

// ============================================================================
// Reference collection — "find all references to a class FQN".
//
// Calls are already modelled by the call graph; this complements it with the
// *non-call* occurrences a rename must touch: type hints, `new`, `extends`/
// `implements`, `::class` / static refs, `use` imports, and exact-FQN string
// literals. Everything is resolved to a fully-qualified name via the file's
// namespace + `use` table, so a reference to `App\Foo\Bar` never matches the
// sibling-namespace twin `App\Other\Bar` (the corruption risk plain text search
// can't avoid).
//
// Collection is target-scoped: the caller passes the FQN it cares about and we
// only materialize matching occurrences, so there is no global occurrence index
// to store or invalidate.
// ============================================================================

pub const ReferenceKind = enum {
    use_import, // use App\Foo\Bar;
    type_hint, // param/property/return type
    instantiation, // new Bar()
    extends, // class X extends Bar
    implements, // class X implements Bar
    class_const, // Bar::class
    static_ref, // Bar::CONST / Bar::method() (static scope)
    string_literal, // 'App\\Foo\\Bar' as a literal class-string

    pub fn label(self: ReferenceKind) []const u8 {
        return @tagName(self);
    }
};

pub const Reference = struct {
    kind: ReferenceKind,
    file_path: []const u8,
    line: u32,
    column: u32,
};

const Collector = struct {
    allocator: std.mem.Allocator, // owns the output references
    scratch: std.mem.Allocator, // transient (current-class FQCN, string work)
    source: []const u8,
    file_ctx: *const FileContext,
    file_path: []const u8,
    target: []const u8,
    current_class: ?[]const u8 = null,
    out: *std.ArrayListUnmanaged(Reference),

    fn record(self: *Collector, kind: ReferenceKind, node: ts.Node) !void {
        try self.out.append(self.allocator, .{
            .kind = kind,
            .file_path = self.file_path,
            .line = node.startPoint().row + 1,
            .column = node.startPoint().column + 1,
        });
    }

    /// Resolve a class-name node to its FQCN and, if it equals the target,
    /// record a reference of `kind` anchored at `anchor`.
    fn consider(self: *Collector, name_node: ts.Node, kind: ReferenceKind, anchor: ts.Node) !void {
        const text = nodeText(self.source, name_node);
        if (text.len == 0) return;

        // self/static resolve to the enclosing class; parent is not resolved.
        const resolved: []const u8 = if (std.mem.eql(u8, text, "self") or std.mem.eql(u8, text, "static"))
            (self.current_class orelse return)
        else if (std.mem.eql(u8, text, "parent"))
            return
        else if (types.TypeInfo.isBuiltin(text))
            return
        else
            self.file_ctx.resolveFQCN(text);

        if (std.mem.eql(u8, resolved, self.target)) {
            try self.record(kind, anchor);
        }
    }

    fn walk(self: *Collector, node: ts.Node) error{OutOfMemory}!void {
        const kind = node.kind();

        if (isClassLike(kind)) {
            const prev = self.current_class;
            if (node.childByFieldName("name")) |n| {
                const name = nodeText(self.source, n);
                self.current_class = if (self.file_ctx.namespace) |ns|
                    std.fmt.allocPrint(self.scratch, "{s}\\{s}", .{ ns, name }) catch name
                else
                    name;
            }
            try self.walkChildren(node);
            self.current_class = prev;
            return;
        }

        if (std.mem.eql(u8, kind, "named_type")) {
            if (firstNameChild(node)) |n| try self.consider(n, .type_hint, n);
            // No class-name descendants beyond the one name; still recurse for
            // safety (nested generics etc. are not produced by tree-sitter-php).
        } else if (std.mem.eql(u8, kind, "object_creation_expression")) {
            if (node.namedChild(0)) |c| {
                if (isNameKind(c.kind())) try self.consider(c, .instantiation, c);
            }
        } else if (std.mem.eql(u8, kind, "base_clause")) {
            try self.considerAllNames(node, .extends);
        } else if (std.mem.eql(u8, kind, "class_interface_clause")) {
            try self.considerAllNames(node, .implements);
        } else if (std.mem.eql(u8, kind, "class_constant_access_expression")) {
            if (node.namedChild(0)) |scope| {
                if (isNameKind(scope.kind()) or std.mem.eql(u8, scope.kind(), "relative_scope")) {
                    const constant = node.namedChild(1);
                    const is_class = if (constant) |cc| std.mem.eql(u8, nodeText(self.source, cc), "class") else false;
                    try self.consider(scope, if (is_class) .class_const else .static_ref, node);
                }
            }
        } else if (std.mem.eql(u8, kind, "scoped_call_expression")) {
            const scope = node.childByFieldName("scope") orelse node.namedChild(0);
            if (scope) |s| {
                if (isNameKind(s.kind()) or std.mem.eql(u8, s.kind(), "relative_scope")) {
                    try self.consider(s, .static_ref, node);
                }
            }
        } else if (std.mem.eql(u8, kind, "namespace_use_clause")) {
            if (firstNameChild(node)) |n| {
                // The use clause already names an FQCN (modulo a leading `\`).
                const text = nodeText(self.source, n);
                const fqcn = if (text.len > 0 and text[0] == '\\') text[1..] else text;
                if (std.mem.eql(u8, fqcn, self.target)) try self.record(.use_import, n);
            }
        } else if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "encapsed_string")) {
            try self.considerString(node);
        }

        try self.walkChildren(node);
    }

    fn walkChildren(self: *Collector, node: ts.Node) error{OutOfMemory}!void {
        var i: u32 = 0;
        const n = node.namedChildCount();
        while (i < n) : (i += 1) {
            if (node.namedChild(i)) |c| try self.walk(c);
        }
    }

    fn considerAllNames(self: *Collector, node: ts.Node, kind: ReferenceKind) !void {
        var i: u32 = 0;
        const n = node.namedChildCount();
        while (i < n) : (i += 1) {
            if (node.namedChild(i)) |c| {
                if (isNameKind(c.kind())) try self.consider(c, kind, c);
            }
        }
    }

    /// Exact-FQN string-literal match: `'App\\Foo\\Bar'` referencing a class by
    /// string (e.g. soft dependencies, container ids). Only an exact match to
    /// the target counts, so the sibling-twin is never hit.
    fn considerString(self: *Collector, node: ts.Node) !void {
        const raw = nodeText(self.source, node);
        if (raw.len < 2) return;
        const q = raw[0];
        if (q != '\'' and q != '"') return;
        if (raw[raw.len - 1] != q) return;
        var inner = raw[1 .. raw.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return;
        if (inner.len > 0 and inner[0] == '\\') inner = inner[1..];
        // Normalize escaped backslashes that appear in double-quoted strings.
        if (std.mem.eql(u8, inner, self.target)) {
            try self.record(.string_literal, node);
            return;
        }
        // Double-quoted `"App\\Foo"` carries doubled backslashes in source.
        if (std.mem.indexOf(u8, inner, "\\\\") != null) {
            const collapsed = collapseDoubleBackslash(self.scratch, inner) catch return;
            defer self.scratch.free(collapsed);
            if (std.mem.eql(u8, collapsed, self.target)) try self.record(.string_literal, node);
        }
    }
};

/// Collect references to `target_fqcn` within one parsed file, appending to
/// `out`. `file_ctx` must carry the file's namespace + use table.
pub fn collectFile(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    tree: *ts.Tree,
    source: []const u8,
    file_ctx: *const FileContext,
    file_path: []const u8,
    target_fqcn: []const u8,
    out: *std.ArrayListUnmanaged(Reference),
) !void {
    var c = Collector{
        .allocator = allocator,
        .scratch = scratch,
        .source = source,
        .file_ctx = file_ctx,
        .file_path = file_path,
        .target = target_fqcn,
        .out = out,
    };
    try c.walk(tree.rootNode());
}

fn collapseDoubleBackslash(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        try buf.append(allocator, s[i]);
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '\\') i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

fn isClassLike(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "class_declaration") or
        std.mem.eql(u8, kind, "interface_declaration") or
        std.mem.eql(u8, kind, "trait_declaration") or
        std.mem.eql(u8, kind, "enum_declaration");
}

fn isNameKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "name") or std.mem.eql(u8, kind, "qualified_name");
}

fn firstNameChild(node: ts.Node) ?ts.Node {
    var i: u32 = 0;
    const n = node.namedChildCount();
    while (i < n) : (i += 1) {
        if (node.namedChild(i)) |c| {
            if (isNameKind(c.kind())) return c;
        }
    }
    return null;
}

fn nodeText(source: []const u8, node: ts.Node) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) return "";
    return source[start..end];
}
