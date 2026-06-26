const std = @import("std");

// ============================================================================
// Symfony DI config (services.yaml) binding extractor — Goal 2.1 Phase B
// ============================================================================
//
// Phase A resolved interface-typed calls only when an interface had exactly one
// in-project implementor. The multi-implementor case stayed ambiguous because
// the *choice* of implementation lives in the DI container config, not the PHP
// type system. This module reads that config so the resolver can bind an
// interface to the concrete the container would inject.
//
// We extract the three global, unambiguous Symfony binding forms — i.e. ones
// that apply to *every* injection of an interface, not a single constructor:
//
//   1. Top-level service alias (the canonical "bind interface to impl"):
//        services:
//            App\NotifierInterface: '@App\EmailNotifier'
//
//   2. Long-form alias:
//        services:
//            App\NotifierInterface:
//                alias: App\EmailNotifier
//
//   3. Global typed bindings under `_defaults.bind`:
//        services:
//            _defaults:
//                bind:
//                    App\NotifierInterface: '@App\SmsNotifier'
//                    App\NotifierInterface $primary: '@App\EmailNotifier'
//
// Deliberately *not* treated as global bindings (they are scoped to one
// consumer's constructor, which the type-directed resolver cannot express):
//   - per-service `arguments:` (e.g. `App\Consumer: { arguments: {$x: '@Impl'} }`)
//   - per-service `bind:` (binds only within that one service)
//   - untyped `$var` bind keys (no interface to key on)
//
// This is a tolerant, indentation-aware scanner rather than a full YAML parser:
// services.yaml in practice is regular `key: value` mappings, and we only care
// about a small, well-defined slice of the grammar.

/// One interface -> concrete binding discovered in a DI config. FQCNs are
/// normalized (no leading backslash) to match symbol-table keys.
pub const Binding = struct {
    interface_fqcn: []const u8,
    concrete_fqcn: []const u8,
    line: u32,
};

/// Parse a services.yaml document, returning the global interface->concrete
/// bindings it declares. All returned slices are allocated with `allocator`
/// (caller owns). Malformed lines are skipped rather than failing the parse.
pub fn parseServicesYaml(allocator: std.mem.Allocator, content: []const u8) ![]Binding {
    var out: std.ArrayListUnmanaged(Binding) = .empty;
    errdefer out.deinit(allocator);

    const Frame = struct { indent: usize, key: []const u8 };
    var frames: std.ArrayListUnmanaged(Frame) = .empty;
    defer frames.deinit(allocator);

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = stripComment(stripCarriageReturn(raw_line));
        const indent = leadingSpaces(line);
        const body = std.mem.trim(u8, line, " \t");
        if (body.len == 0) continue;
        // Document markers / sequence items aren't part of the mapping grammar
        // we care about.
        if (std.mem.eql(u8, body, "---") or std.mem.eql(u8, body, "...")) continue;
        if (body[0] == '-') continue;

        // Drop ancestors at the same or deeper indentation; what remains is the
        // path of enclosing mapping keys for this line.
        while (frames.items.len > 0 and frames.items[frames.items.len - 1].indent >= indent) {
            _ = frames.pop();
        }

        const kv = splitKeyValue(body) orelse {
            // Not a `key:`/`key: value` line; ignore but keep the stack sane.
            continue;
        };
        const key = kv.key;
        const value = kv.value;

        try maybeRecord(allocator, &out, frames.items, Frame, key, value, line_no);

        try frames.append(allocator, .{ .indent = indent, .key = key });
    }

    return out.toOwnedSlice(allocator);
}

/// Decide whether the current line declares a global binding, given the stack of
/// enclosing keys, and append it if so.
fn maybeRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Binding),
    frames: anytype,
    comptime Frame: type,
    key: []const u8,
    value: []const u8,
    line_no: u32,
) !void {
    _ = Frame;
    const depth = frames.len;

    // Case 1: top-level service alias — `services:` > `Interface: '@Concrete'`.
    if (depth == 1 and eql(frames[0].key, "services")) {
        if (looksLikeFqcn(key) and serviceRef(value) != null) {
            try append(allocator, out, key, serviceRef(value).?, line_no);
        }
        return;
    }

    // Case 2: long-form alias — `services:` > `Interface:` > `alias: Concrete`.
    if (depth == 2 and eql(frames[0].key, "services") and eql(key, "alias")) {
        const iface = frames[1].key;
        if (looksLikeFqcn(iface)) {
            const concrete = serviceRef(value) orelse value;
            if (looksLikeFqcn(concrete)) {
                try append(allocator, out, iface, concrete, line_no);
            }
        }
        return;
    }

    // Case 3: global typed bind — `services:` > `_defaults:` > `bind:` > entry.
    if (depth == 3 and
        eql(frames[0].key, "services") and
        eql(frames[1].key, "_defaults") and
        eql(frames[2].key, "bind"))
    {
        // The bind key may be `Type`, `Type $var`, or `$var`. Extract the
        // leading type token (before any whitespace); skip untyped `$var` keys.
        const iface = bindKeyType(key) orelse return;
        if (looksLikeFqcn(iface)) {
            if (serviceRef(value)) |concrete| {
                try append(allocator, out, iface, concrete, line_no);
            }
        }
        return;
    }
}

fn append(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Binding),
    iface: []const u8,
    concrete: []const u8,
    line_no: u32,
) !void {
    try out.append(allocator, .{
        .interface_fqcn = try allocator.dupe(u8, normalizeFqcn(iface)),
        .concrete_fqcn = try allocator.dupe(u8, normalizeFqcn(concrete)),
        .line = line_no,
    });
}

// ----------------------------------------------------------------------------
// Lexical helpers
// ----------------------------------------------------------------------------

const KeyValue = struct { key: []const u8, value: []const u8 };

/// Split a `key: value` or `key:` line on the first colon. Returns null if there
/// is no colon (FQCNs use `\`, not `:`, so the first colon is the separator).
fn splitKeyValue(body: []const u8) ?KeyValue {
    const idx = std.mem.indexOfScalar(u8, body, ':') orelse return null;
    const key = std.mem.trim(u8, body[0..idx], " \t");
    const value = std.mem.trim(u8, body[idx + 1 ..], " \t");
    if (key.len == 0) return null;
    return .{ .key = key, .value = unquote(value) };
}

/// Interpret a YAML scalar that should be a service reference (`'@Foo'`,
/// `"@Foo"`, or `@Foo`). Returns the referenced id without the `@`, or null if
/// the value is not a service reference.
fn serviceRef(value: []const u8) ?[]const u8 {
    const v = unquote(value);
    if (v.len < 2 or v[0] != '@') return null;
    // `@@id` escapes a literal `@`; not a service reference.
    if (v[1] == '@') return null;
    return v[1..];
}

/// Strip a single layer of matching surrounding quotes.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '"' and s[s.len - 1] == '"'))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// The leading type token of a `bind` key (`Type $var` -> `Type`, `Type` ->
/// `Type`). Returns null for an untyped `$var` key.
fn bindKeyType(key: []const u8) ?[]const u8 {
    const k = unquote(key);
    const end = std.mem.indexOfAny(u8, k, " \t") orelse k.len;
    const tok = k[0..end];
    if (tok.len == 0 or tok[0] == '$') return null;
    return tok;
}

/// A heuristic for "this token names a class/interface": it contains a namespace
/// separator. This keeps non-class service ids (e.g. `'logger'`, parameters)
/// from being misread as bindings.
fn looksLikeFqcn(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\\') != null;
}

/// Normalize an FQCN to symbol-table form: drop a single leading backslash.
fn normalizeFqcn(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '\\') return s[1..];
    return s;
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn stripCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// Remove a trailing `#` comment. A `#` only starts a comment when at the start
/// of the (trimmed) content or preceded by whitespace, and when not inside a
/// quote. Service ids/refs we care about never contain `#`, so a single-pass
/// quote-aware scan suffices.
fn stripComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (c == '#' and !in_single and !in_double) {
            if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') {
                return line[0..i];
            }
        }
    }
    return line;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn findBinding(bindings: []const Binding, iface: []const u8) ?[]const u8 {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.interface_fqcn, iface)) return b.concrete_fqcn;
    }
    return null;
}

test "di: top-level service alias binds interface to concrete" {
    const yaml =
        \\services:
        \\    App\Notify\NotifierInterface: '@App\Notify\EmailNotifier'
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqualStrings("App\\Notify\\EmailNotifier", findBinding(b, "App\\Notify\\NotifierInterface").?);
}

test "di: long-form alias key" {
    const yaml =
        \\services:
        \\    App\Notify\NotifierInterface:
        \\        alias: App\Notify\SmsNotifier
        \\        public: true
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqualStrings("App\\Notify\\SmsNotifier", findBinding(b, "App\\Notify\\NotifierInterface").?);
}

test "di: _defaults.bind typed bindings (with and without arg name)" {
    const yaml =
        \\services:
        \\    _defaults:
        \\        autowire: true
        \\        bind:
        \\            App\Notify\NotifierInterface: '@App\Notify\EmailNotifier'
        \\            App\Log\LoggerInterface $audit: '@App\Log\AuditLogger'
        \\            $plainScalar: '%env(FOO)%'
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqualStrings("App\\Notify\\EmailNotifier", findBinding(b, "App\\Notify\\NotifierInterface").?);
    try testing.expectEqualStrings("App\\Log\\AuditLogger", findBinding(b, "App\\Log\\LoggerInterface").?);
}

test "di: per-service arguments and bind are NOT global bindings" {
    const yaml =
        \\services:
        \\    App\Consumer\OrderService:
        \\        arguments:
        \\            $notifier: '@App\Notify\SmsNotifier'
        \\        bind:
        \\            App\Notify\NotifierInterface: '@App\Notify\SmsNotifier'
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "di: non-class service ids and comments are ignored" {
    const yaml =
        \\# a comment line
        \\services:
        \\    _defaults:
        \\        autowire: true   # inline comment
        \\    logger: '@monolog.logger'      # not an FQCN key
        \\    App\Notify\NotifierInterface: '@App\Notify\EmailNotifier'  # bind
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqualStrings("App\\Notify\\EmailNotifier", findBinding(b, "App\\Notify\\NotifierInterface").?);
}

test "di: leading backslashes are normalized away" {
    const yaml =
        \\services:
        \\    \App\Notify\NotifierInterface: '@\App\Notify\EmailNotifier'
    ;
    const b = try parseServicesYaml(testing.allocator, yaml);
    defer freeBindings(testing.allocator, b);
    try testing.expectEqualStrings("App\\Notify\\EmailNotifier", findBinding(b, "App\\Notify\\NotifierInterface").?);
}

fn freeBindings(allocator: std.mem.Allocator, bindings: []Binding) void {
    for (bindings) |b| {
        allocator.free(b.interface_fqcn);
        allocator.free(b.concrete_fqcn);
    }
    allocator.free(bindings);
}
