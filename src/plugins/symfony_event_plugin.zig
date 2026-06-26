const std = @import("std");
const plugin_interface = @import("plugin_interface.zig");
const types = @import("../types.zig");
const symbol_table = @import("../symbol_table.zig");
const ts = @import("tree-sitter");

const Plugin = plugin_interface.Plugin;
const PluginContext = plugin_interface.PluginContext;
const SyntheticEdge = plugin_interface.SyntheticEdge;

// ============================================================================
// Symfony Event Plugin
// Detects Symfony EventDispatcher and Messenger patterns and creates synthetic
// edges from dispatch() calls to the handler methods they ultimately invoke:
//   - EventDispatcher: dispatch(new SomeEvent()) -> subscriber handler methods
//   - Messenger:       dispatch(new SomeMessage()) -> message handler (__invoke
//                      or #[AsMessageHandler] method whose first parameter is
//                      type-hinted with the message class)
// ============================================================================

/// Plugin instance
pub const plugin = Plugin{
    .name = "symfony-events",
    .description = "Detects Symfony EventDispatcher and Messenger patterns and creates synthetic edges from dispatch() to subscriber/message handlers",
    .version = "1.1.0",
    .analyzeFn = analyze,
};

/// Event (or message) class -> handler method mapping
const EventHandlerMapping = struct {
    /// The event/message class FQCN (e.g., "App\\Event\\UserCreatedEvent")
    event_class: []const u8,
    /// The subscriber/handler class FQCN
    subscriber_class: []const u8,
    /// The handler method name
    handler_method: []const u8,
    /// Priority (higher = earlier execution)
    priority: i32,
    /// True for Symfony Messenger handlers, false for EventDispatcher subscribers
    is_message: bool = false,
};

/// Main analysis function
fn analyze(ctx: *const PluginContext) anyerror![]const SyntheticEdge {
    var edges: std.ArrayListUnmanaged(SyntheticEdge) = .empty;

    // Step 1: Build dispatched-class -> handler mappings. Both EventDispatcher
    // subscribers and Messenger handlers are keyed by the class passed to
    // dispatch(), so they share the same matching loop below.
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;
    for (try buildEventMappings(ctx)) |m| try mappings.append(ctx.allocator, m);
    for (try buildMessageHandlerMappings(ctx)) |m| try mappings.append(ctx.allocator, m);
    for (try buildEventListenerMappings(ctx)) |m| try mappings.append(ctx.allocator, m);

    // Step 2: Find all dispatch() calls (EventDispatcher and MessageBus share
    // the `dispatch` method name).
    const dispatch_calls = try ctx.findCallsTo(null, "dispatch");

    // Step 3: For each dispatch call, link to handlers based on the dispatched
    // event/message class.
    for (dispatch_calls) |dispatch_call| {
        // Try to extract the event/message class from the dispatch arguments.
        const event_class = try extractEventClassFromCall(ctx, dispatch_call) orelse continue;

        for (mappings.items) |mapping| {
            if (!eventClassMatches(event_class, mapping.event_class)) continue;

            const callee_fqn = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}::{s}",
                .{ mapping.subscriber_class, mapping.handler_method },
            );

            const reason = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}: {s} -> {s}",
                .{
                    if (mapping.is_message) "Symfony message" else "Symfony event",
                    event_class,
                    mapping.handler_method,
                },
            );

            try edges.append(ctx.allocator, .{
                .caller_fqn = dispatch_call.caller_fqn,
                .callee_fqn = callee_fqn,
                .file_path = dispatch_call.file_path,
                .line = dispatch_call.line,
                .confidence = 0.95, // High confidence for exact class match
                .reason = reason,
                .plugin_name = "symfony-events",
            });
        }
    }

    return edges.toOwnedSlice(ctx.allocator);
}

/// Build mapping from event classes to their handlers by analyzing EventSubscriberInterface implementations
fn buildEventMappings(ctx: *const PluginContext) ![]const EventHandlerMapping {
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;

    // Find all classes implementing EventSubscriberInterface
    // We check both the full Symfony FQCN and common aliases
    const interface_names = [_][]const u8{
        "Symfony\\Component\\EventDispatcher\\EventSubscriberInterface",
        "EventSubscriberInterface",
    };

    var it = ctx.sym_table.classes.iterator();
    while (it.next()) |entry| {
        const class = entry.value_ptr;

        // Check if this class implements EventSubscriberInterface
        var is_subscriber = false;
        for (class.implements) |iface| {
            for (interface_names) |target_iface| {
                if (std.mem.eql(u8, iface, target_iface) or
                    std.mem.endsWith(u8, iface, target_iface))
                {
                    is_subscriber = true;
                    break;
                }
            }
            if (is_subscriber) break;
        }

        if (!is_subscriber) continue;

        // Parse getSubscribedEvents to extract mappings
        const class_mappings = try parseSubscribedEventsForClass(ctx, class);
        for (class_mappings) |mapping| {
            try mappings.append(ctx.allocator, mapping);
        }
    }

    return mappings.toOwnedSlice(ctx.allocator);
}

/// Build mapping from message classes to their Messenger handler methods.
///
/// A class is treated as a message handler when it either implements a
/// `*MessageHandlerInterface`/`*MessageSubscriberInterface`, or carries the
/// `#[AsMessageHandler]` attribute (class-level → `__invoke`). Individual
/// methods annotated with `#[AsMessageHandler]` are also picked up. The handled
/// message class is taken from the type hint of the handler's first parameter.
fn buildMessageHandlerMappings(ctx: *const PluginContext) ![]const EventHandlerMapping {
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;

    const handler_ifaces = [_][]const u8{
        "MessageHandlerInterface",
        "MessageSubscriberInterface",
    };

    var it = ctx.sym_table.classes.iterator();
    while (it.next()) |entry| {
        const class = entry.value_ptr;
        const source = ctx.file_sources.get(class.file_path);

        // Class-level handler detection: marker interface or #[AsMessageHandler].
        var class_is_handler = false;
        for (class.implements) |iface| {
            for (handler_ifaces) |target| {
                if (std.mem.eql(u8, iface, target) or std.mem.endsWith(u8, iface, target)) {
                    class_is_handler = true;
                    break;
                }
            }
            if (class_is_handler) break;
        }

        // Class-level #[AsMessageHandler] args, if present. With explicit
        // `handles:`/`method:` named args, the class routes a specific message
        // to a named method (not necessarily __invoke) — this session's gap.
        var class_attr_args: ?[]const u8 = null;
        if (source) |s| {
            if (classAttributeRegion(s, class.name)) |region| {
                if (attributeArgs(region, "AsMessageHandler")) |args| {
                    class_is_handler = true;
                    class_attr_args = args;
                }
            }
        }

        // The handler method named by a class-level `method:` arg (so the
        // per-method loop doesn't also emit a default for it).
        var class_named_method: ?[]const u8 = null;
        if (class_attr_args) |args| {
            const handles = namedArgClassLike(args, "handles");
            const named_method = namedArgString(args, "method");
            if (handles) |hc| {
                const m = named_method orelse "__invoke";
                class_named_method = m;
                try mappings.append(ctx.allocator, .{
                    .event_class = try ctx.allocator.dupe(u8, hc),
                    .subscriber_class = class.fqcn,
                    .handler_method = try ctx.allocator.dupe(u8, m),
                    .priority = 0,
                    .is_message = true,
                });
            }
        }

        var method_it = class.methods.iterator();
        while (method_it.next()) |method_entry| {
            const method = method_entry.value_ptr;
            if (method.is_static or method.visibility != .public) continue;

            // Already emitted via a class-level `handles:`+`method:` mapping.
            if (class_named_method) |nm| {
                if (std.mem.eql(u8, nm, method.name)) continue;
            }

            // A method is a handler if the class is a handler and the method is
            // __invoke, or if the method itself is annotated #[AsMessageHandler].
            var is_handler_method = class_is_handler and std.mem.eql(u8, method.name, "__invoke");
            var handles_override: ?[]const u8 = null;
            if (source) |s| {
                if (methodAttributeRegion(s, method)) |region| {
                    if (attributeArgs(region, "AsMessageHandler")) |args| {
                        is_handler_method = true;
                        handles_override = namedArgClassLike(args, "handles");
                    }
                }
            }
            if (!is_handler_method) continue;

            // The handled message class: explicit `handles:` wins, else the
            // first-parameter type hint.
            const message_class = if (handles_override) |h|
                try ctx.allocator.dupe(u8, h)
            else
                (firstParameterType(ctx.allocator, method) catch null) orelse continue;

            try mappings.append(ctx.allocator, .{
                .event_class = message_class,
                .subscriber_class = class.fqcn,
                .handler_method = method.name,
                .priority = 0,
                .is_message = true,
            });
        }
    }

    return mappings.toOwnedSlice(ctx.allocator);
}

/// Build mappings from `#[AsEventListener]` attributes (Symfony 6.1+), both
/// class-level (defaults to `__invoke`) and method-level. The listened event is
/// taken from the `event:` named arg when present, otherwise (method-level) from
/// the handler's first parameter type hint.
fn buildEventListenerMappings(ctx: *const PluginContext) ![]const EventHandlerMapping {
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;

    var it = ctx.sym_table.classes.iterator();
    while (it.next()) |entry| {
        const class = entry.value_ptr;
        const source = ctx.file_sources.get(class.file_path) orelse continue;

        // Class-level #[AsEventListener(event:, method:)].
        if (classAttributeRegion(source, class.name)) |region| {
            if (attributeArgs(region, "AsEventListener")) |args| {
                if (namedArgClassLike(args, "event")) |ev| {
                    const m = namedArgString(args, "method") orelse "__invoke";
                    try mappings.append(ctx.allocator, .{
                        .event_class = try ctx.allocator.dupe(u8, ev),
                        .subscriber_class = class.fqcn,
                        .handler_method = try ctx.allocator.dupe(u8, m),
                        .priority = 0,
                    });
                }
            }
        }

        // Method-level #[AsEventListener] — the event may be named explicitly or
        // inferred from the first parameter type.
        var method_it = class.methods.iterator();
        while (method_it.next()) |method_entry| {
            const method = method_entry.value_ptr;
            if (method.is_static or method.visibility != .public) continue;
            const region = methodAttributeRegion(source, method) orelse continue;
            const args = attributeArgs(region, "AsEventListener") orelse continue;
            const ev = namedArgClassLike(args, "event") orelse
                (firstParameterType(ctx.allocator, method) catch null) orelse continue;
            try mappings.append(ctx.allocator, .{
                .event_class = try ctx.allocator.dupe(u8, ev),
                .subscriber_class = class.fqcn,
                .handler_method = method.name,
                .priority = 0,
            });
        }
    }

    return mappings.toOwnedSlice(ctx.allocator);
}

/// Return an owned copy of the first parameter's class type hint, or null when
/// the handler takes no parameters or the first parameter has no class type.
fn firstParameterType(allocator: std.mem.Allocator, method: *const types.MethodSymbol) !?[]const u8 {
    if (method.parameters.len == 0) return null;
    const ti = method.parameters[0].type_info orelse method.parameters[0].phpdoc_type orelse return null;
    if (ti.base_type.len == 0 or ti.is_builtin) return null;
    return try allocator.dupe(u8, ti.base_type);
}

/// The source region holding a class's own attributes/modifiers: from the
/// nearest `}`/`;`/`>` (end of the previous member or attribute group above it
/// is intentionally included) back-bounded to 400 bytes, up to the `class`
/// keyword. Returns null if the class can't be located.
fn classAttributeRegion(source: []const u8, class_name: []const u8) ?[]const u8 {
    const class_pos = findClassKeyword(source, class_name) orelse return null;
    const min_lo = if (class_pos > 400) class_pos - 400 else 0;
    var lo = class_pos;
    while (lo > min_lo) : (lo -= 1) {
        const c = source[lo - 1];
        if (c == '}' or c == ';') break;
    }
    return source[lo..class_pos];
}

/// True if `#[<attr>]` appears immediately above the `class <name>` declaration.
fn classHasAttribute(source: []const u8, class_name: []const u8, attr: []const u8) bool {
    const region = classAttributeRegion(source, class_name) orelse return false;
    return std.mem.indexOf(u8, region, attr) != null;
}

/// True if `#[<attr>]` appears in the attribute region of a method declaration.
/// Scans the span from the end of the previous member (the nearest `{`, `}` or
/// `;` before the method) up to this method's `function` keyword. That window
/// holds only this method's own attributes and modifiers, so attributes on a
/// neighbouring method never leak in. It works whether the parser nests the
/// attribute inside the method node or emits it as a preceding sibling.
fn methodHasAttribute(source: []const u8, method: *const types.MethodSymbol, attr: []const u8) bool {
    const region = methodAttributeRegion(source, method) orelse return false;
    return std.mem.indexOf(u8, region, attr) != null;
}

/// The source region holding one method's own attributes (see
/// `methodHasAttribute` for the windowing rationale). Returns null if empty.
fn methodAttributeRegion(source: []const u8, method: *const types.MethodSymbol) ?[]const u8 {
    const sb: usize = @min(method.start_byte, source.len);
    const min_lo = if (sb > 400) sb - 400 else 0;
    var lo = sb;
    while (lo > min_lo) : (lo -= 1) {
        const c = source[lo - 1];
        if (c == '}' or c == '{' or c == ';') break;
    }
    const fn_pos = std.mem.indexOfPos(u8, source, sb, "function") orelse @min(source.len, sb + 160);
    const hi = @min(fn_pos, source.len);
    if (lo >= hi) return null;
    return source[lo..hi];
}

// ---------------------------------------------------------------------------
// Attribute-argument parsing
//
// Symfony's routing attributes carry named arguments we care about:
//   #[AsMessageHandler(handles: SomeMessage::class, method: 'handleIt')]
//   #[AsEventListener(event: SomeEvent::class, method: 'onEvent')]
// These helpers extract those values from the attribute's argument list inside
// the source region where the attribute lives. They are deliberately lexical
// (string-scanning) — the same trade-off the rest of this plugin makes.
// ---------------------------------------------------------------------------

/// Return the argument list inside `#[<attr>(...)]` found within `region`.
/// Returns "" when the attribute is present without parentheses
/// (`#[AsMessageHandler]`), or null when the attribute is absent.
fn attributeArgs(region: []const u8, attr: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, region, search, attr)) |p| {
        var i = p + attr.len;
        while (i < region.len and (region[i] == ' ' or region[i] == '\t')) i += 1;
        if (i < region.len and region[i] == '(') {
            const close = matchParen(region, i) orelse return null;
            return region[i + 1 .. close];
        }
        // Attribute present with no argument list.
        if (i >= region.len or region[i] == ']' or region[i] == ',' or region[i] == '\n' or region[i] == '\r')
            return "";
        search = p + attr.len;
    }
    return null;
}

/// Index of the `)` matching the `(` at `open`, respecting nested parens and
/// single/double-quoted strings. Null if unbalanced.
fn matchParen(s: []const u8, open: usize) ?usize {
    var depth: i32 = 0;
    var i = open;
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Extract a class reference for named argument `name` from an attribute arg
/// list: handles both `name: Foo\Bar::class` (returns "Foo\Bar") and
/// `name: 'Foo\Bar'` / `name: "Foo\Bar"` (returns the unquoted string).
fn namedArgClassLike(args: []const u8, name: []const u8) ?[]const u8 {
    const v = namedArgRaw(args, name) orelse return null;
    if (std.mem.endsWith(u8, v, "::class")) {
        return std.mem.trim(u8, v[0 .. v.len - "::class".len], " \t");
    }
    return unquote(v);
}

/// Extract a quoted string value for named argument `name` (e.g. method names).
fn namedArgString(args: []const u8, name: []const u8) ?[]const u8 {
    const v = namedArgRaw(args, name) orelse return null;
    return unquote(v);
}

/// Return the raw (trimmed) token following `name:` up to the next top-level
/// comma or end of args. Null if the named argument is absent.
fn namedArgRaw(args: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, args, search, name)) |p| {
        // Must be a token boundary before `name` and a `:` (not `::`) after it.
        const before_ok = p == 0 or !isIdentChar(args[p - 1]);
        var i = p + name.len;
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
        if (before_ok and i < args.len and args[i] == ':' and
            (i + 1 >= args.len or args[i + 1] != ':'))
        {
            i += 1; // past ':'
            while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
            // Read until a top-level comma.
            const start = i;
            var quote: u8 = 0;
            while (i < args.len) : (i += 1) {
                const c = args[i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                    continue;
                }
                if (c == '\'' or c == '"') quote = c else if (c == ',') break;
            }
            return std.mem.trim(u8, args[start..i], " \t\r\n");
        }
        search = p + name.len;
    }
    return null;
}

/// Strip a single matching pair of surrounding single/double quotes, if present.
fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '\'' or v[0] == '"') and v[v.len - 1] == v[0]) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// Find the byte offset of the `class` keyword that declares `class_name`,
/// matched on an identifier boundary so `Foo` doesn't match `FooBar`.
fn findClassKeyword(source: []const u8, class_name: []const u8) ?usize {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source, search, "class ")) |p| {
        var i = p + "class ".len;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (std.mem.startsWith(u8, source[i..], class_name)) {
            const end = i + class_name.len;
            if (end >= source.len or !isIdentChar(source[end])) return p;
        }
        search = p + "class ".len;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Parse the getSubscribedEvents method of an EventSubscriber class
fn parseSubscribedEventsForClass(
    ctx: *const PluginContext,
    class: *const types.ClassSymbol,
) ![]const EventHandlerMapping {
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;

    // Look for getSubscribedEvents method
    var found_method = false;
    var method_it = class.methods.iterator();
    while (method_it.next()) |method_entry| {
        if (std.mem.eql(u8, method_entry.key_ptr.*, "getSubscribedEvents")) {
            found_method = true;
            break;
        }
    }

    if (!found_method) {
        // Fall back to heuristic: look for methods starting with "on" that could be handlers
        method_it = class.methods.iterator();
        while (method_it.next()) |method_entry| {
            const method = method_entry.value_ptr;
            if (method.visibility == .public and !method.is_static) {
                if (std.mem.startsWith(u8, method.name, "on")) {
                    // Heuristic: this could be an event handler
                    // We don't know the event class, so use a wildcard
                    try mappings.append(ctx.allocator, .{
                        .event_class = "*", // Wildcard
                        .subscriber_class = class.fqcn,
                        .handler_method = method.name,
                        .priority = 0,
                    });
                }
            }
        }
        return mappings.toOwnedSlice(ctx.allocator);
    }

    // If we have source code, we need to parse getSubscribedEvents to extract
    // the event->handler mapping. This requires re-parsing the source.
    // For now, we use a simpler approach: scan the source for patterns like
    // SomeEvent::class => 'onSomeEvent' or 'event.name' => 'onSomeEvent'

    if (ctx.file_sources.get(class.file_path)) |source| {
        const extracted = try extractMappingsFromSource(ctx.allocator, source, class.fqcn);
        for (extracted) |mapping| {
            try mappings.append(ctx.allocator, mapping);
        }
    }

    // If we couldn't parse the source, fall back to heuristics
    if (mappings.items.len == 0) {
        method_it = class.methods.iterator();
        while (method_it.next()) |method_entry| {
            const method = method_entry.value_ptr;
            if (method.visibility == .public and !method.is_static) {
                if (std.mem.startsWith(u8, method.name, "on")) {
                    try mappings.append(ctx.allocator, .{
                        .event_class = "*",
                        .subscriber_class = class.fqcn,
                        .handler_method = method.name,
                        .priority = 0,
                    });
                }
            }
        }
    }

    return mappings.toOwnedSlice(ctx.allocator);
}

/// Extract event mappings from PHP source by pattern matching
fn extractMappingsFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    subscriber_class: []const u8,
) ![]const EventHandlerMapping {
    var mappings: std.ArrayListUnmanaged(EventHandlerMapping) = .empty;

    // Find getSubscribedEvents method in source
    const method_start = std.mem.indexOf(u8, source, "getSubscribedEvents");
    if (method_start == null) return mappings.toOwnedSlice(allocator);

    // Find the return array (look for 'return [' or 'return array(')
    const return_start = std.mem.indexOfPos(u8, source, method_start.?, "return") orelse return mappings.toOwnedSlice(allocator);

    // Find end of return statement (next semicolon or closing bracket)
    const return_end = blk: {
        var depth: i32 = 0;
        var in_string = false;
        var i = return_start;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '\'' or c == '"') {
                in_string = !in_string;
            } else if (!in_string) {
                if (c == '[' or c == '(') depth += 1;
                if (c == ']' or c == ')') depth -= 1;
                if (c == ';' and depth <= 0) break :blk i;
            }
        }
        break :blk source.len;
    };

    const return_block = source[return_start..return_end];

    // Pattern 1: SomeEvent::class => 'onHandler' or SomeEvent::class => ['onHandler', priority]
    var pos: usize = 0;
    while (pos < return_block.len) {
        // Look for ::class pattern
        if (std.mem.indexOfPos(u8, return_block, pos, "::class")) |class_pos| {
            // Find event class name before ::class
            const event_class = blk: {
                var start = class_pos;
                while (start > 0 and (std.ascii.isAlphanumeric(return_block[start - 1]) or return_block[start - 1] == '\\' or return_block[start - 1] == '_')) {
                    start -= 1;
                }
                break :blk return_block[start..class_pos];
            };

            // Find handler name after => (in quotes)
            if (std.mem.indexOfPos(u8, return_block, class_pos, "=>")) |arrow_pos| {
                if (std.mem.indexOfPos(u8, return_block, arrow_pos, "'")) |quote_start| {
                    if (std.mem.indexOfPos(u8, return_block, quote_start + 1, "'")) |quote_end| {
                        const handler = return_block[quote_start + 1 .. quote_end];
                        if (handler.len > 0) {
                            try mappings.append(allocator, .{
                                .event_class = try allocator.dupe(u8, event_class),
                                .subscriber_class = subscriber_class,
                                .handler_method = try allocator.dupe(u8, handler),
                                .priority = 0,
                            });
                        }
                    }
                }
            }

            pos = class_pos + 7; // Move past "::class"
        } else {
            break;
        }
    }

    // Pattern 2: FQN-string keys — `'App\\Event\\Foo' => 'onFoo'`. Symfony lets
    // subscribers reference events they don't import (the documented
    // soft-dependency pattern), so the key is a quoted class-string, not
    // `::class`. We only treat quoted keys containing a namespace separator as
    // FQNs (plain event-name strings like `'kernel.request'` are not classes).
    var ap: usize = 0;
    while (std.mem.indexOfPos(u8, return_block, ap, "=>")) |arrow| {
        ap = arrow + 2;
        // Identify a quoted key immediately to the left of `=>`.
        var j = arrow;
        while (j > 0 and (return_block[j - 1] == ' ' or return_block[j - 1] == '\t')) j -= 1;
        if (j == 0) continue;
        const qchar = return_block[j - 1];
        if (qchar != '\'' and qchar != '"') continue;
        const key_end = j - 1; // index of closing quote
        const open_rel = std.mem.lastIndexOfScalar(u8, return_block[0..key_end], qchar) orelse continue;
        const key = return_block[open_rel + 1 .. key_end];
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, '\\') == null) continue; // not an FQN

        // Handler is the first quoted string after `=>` (handles both
        // `=> 'onFoo'` and `=> ['onFoo', 10]`).
        const hq_start = std.mem.indexOfAnyPos(u8, return_block, arrow + 2, "'\"") orelse continue;
        const hqc = return_block[hq_start];
        const hq_end = std.mem.indexOfScalarPos(u8, return_block, hq_start + 1, hqc) orelse continue;
        const handler = return_block[hq_start + 1 .. hq_end];
        if (handler.len == 0) continue;

        try mappings.append(allocator, .{
            .event_class = try allocator.dupe(u8, key),
            .subscriber_class = subscriber_class,
            .handler_method = try allocator.dupe(u8, handler),
            .priority = 0,
        });
    }

    return mappings.toOwnedSlice(allocator);
}

/// Try to extract the event class from a dispatch() call
fn extractEventClassFromCall(
    ctx: *const PluginContext,
    call: types.EnhancedFunctionCall,
) !?[]const u8 {
    // The dispatch call typically looks like:
    // $eventDispatcher->dispatch(new SomeEvent(...))
    // $this->eventDispatcher->dispatch($event)
    // $dispatcher->dispatch(new SomeEvent(), 'event.name')

    // We need to look at the source around the call site to find the event class
    if (ctx.file_sources.get(call.file_path)) |source| {
        // Find the line in source
        var line_count: u32 = 1;
        var line_start: usize = 0;
        var line_end: usize = source.len;

        for (source, 0..) |c, i| {
            if (c == '\n') {
                if (line_count == call.line) {
                    line_end = i;
                    break;
                }
                line_count += 1;
                line_start = i + 1;
            }
        }

        const line = source[line_start..line_end];

        // Look for "new SomeClass" pattern on this line
        if (std.mem.indexOf(u8, line, "new ")) |new_pos| {
            const after_new = line[new_pos + 4 ..];
            // Extract class name (until '(' or whitespace)
            var end_pos: usize = 0;
            while (end_pos < after_new.len and
                (std.ascii.isAlphanumeric(after_new[end_pos]) or
                    after_new[end_pos] == '\\' or
                    after_new[end_pos] == '_'))
            {
                end_pos += 1;
            }
            if (end_pos > 0) {
                return try ctx.allocator.dupe(u8, after_new[0..end_pos]);
            }
        }
    }

    return null;
}

/// Check if an event class matches a pattern
fn eventClassMatches(actual: []const u8, pattern: []const u8) bool {
    // Wildcard matches everything
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Exact match
    if (std.mem.eql(u8, actual, pattern)) return true;

    // Check if actual ends with pattern (handles namespace differences)
    if (std.mem.endsWith(u8, actual, pattern)) {
        // Make sure it's a namespace boundary
        const prefix_len = actual.len - pattern.len;
        if (prefix_len == 0) return true;
        if (actual[prefix_len - 1] == '\\') return true;
    }

    // Check if pattern ends with actual (reverse case)
    if (std.mem.endsWith(u8, pattern, actual)) {
        const prefix_len = pattern.len - actual.len;
        if (prefix_len == 0) return true;
        if (pattern[prefix_len - 1] == '\\') return true;
    }

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "eventClassMatches" {
    // Exact match
    try std.testing.expect(eventClassMatches("App\\Event\\UserCreated", "App\\Event\\UserCreated"));

    // Wildcard
    try std.testing.expect(eventClassMatches("App\\Event\\UserCreated", "*"));

    // Suffix match
    try std.testing.expect(eventClassMatches("App\\Event\\UserCreated", "UserCreated"));
    try std.testing.expect(eventClassMatches("App\\Event\\UserCreated", "Event\\UserCreated"));

    // No match
    try std.testing.expect(!eventClassMatches("App\\Event\\UserCreated", "OrderCreated"));
}

test "findClassKeyword matches on identifier boundary" {
    const src = "<?php\n#[AsMessageHandler]\nfinal class SendEmailHandler {}\n";
    const pos = findClassKeyword(src, "SendEmailHandler").?;
    try std.testing.expect(std.mem.startsWith(u8, src[pos..], "class SendEmailHandler"));
    // Must not match a longer identifier with the name as a prefix.
    try std.testing.expect(findClassKeyword("<?php class SendEmailHandlerExtra {}", "SendEmailHandler") == null);
}

test "classHasAttribute detects class-level attribute" {
    const src = "<?php\n#[AsMessageHandler]\nclass H { public function __invoke(M $m): void {} }";
    try std.testing.expect(classHasAttribute(src, "H", "AsMessageHandler"));
    try std.testing.expect(!classHasAttribute(src, "H", "AsEventListener"));
}

test "methodHasAttribute does not leak across neighbouring methods" {
    // A method-level attribute belongs only to the method it precedes.
    const src =
        "    #[AsMessageHandler]\n" ++ // 0
        "    public function handle(M $m): void {}\n" ++
        "    public function notAHandler(M $m): void {}\n";
    const handle_sb = std.mem.indexOf(u8, src, "#[AsMessageHandler]").?;
    const not_sb = std.mem.indexOf(u8, src, "public function notAHandler").?;

    var handle = makeMethod("handle");
    handle.start_byte = @intCast(handle_sb);
    var not_handler = makeMethod("notAHandler");
    not_handler.start_byte = @intCast(not_sb);

    try std.testing.expect(methodHasAttribute(src, &handle, "AsMessageHandler"));
    try std.testing.expect(!methodHasAttribute(src, &not_handler, "AsMessageHandler"));
}

test "firstParameterType ignores builtins and missing types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var with_class = makeMethod("__invoke");
    with_class.parameters = &.{.{
        .name = "message",
        .type_info = try types.TypeInfo.simple(a, "App\\Message\\SendEmail"),
        .has_default = false,
        .is_variadic = false,
        .is_by_reference = false,
        .is_promoted = false,
        .phpdoc_type = null,
    }};
    try std.testing.expectEqualStrings("App\\Message\\SendEmail", (try firstParameterType(a, &with_class)).?);

    var with_builtin = makeMethod("__invoke");
    with_builtin.parameters = &.{.{
        .name = "x",
        .type_info = try types.TypeInfo.simple(a, "string"),
        .has_default = false,
        .is_variadic = false,
        .is_by_reference = false,
        .is_promoted = false,
        .phpdoc_type = null,
    }};
    try std.testing.expect((try firstParameterType(a, &with_builtin)) == null);

    const no_params = makeMethod("__invoke");
    try std.testing.expect((try firstParameterType(a, &no_params)) == null);
}

/// Minimal MethodSymbol for unit tests (only fields the helpers read matter).
fn makeMethod(name: []const u8) types.MethodSymbol {
    return .{
        .name = name,
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 0,
        .end_line = 0,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\H",
        .file_path = "",
    };
}

test "attributeArgs + named-arg extraction (AsMessageHandler handles/method)" {
    const region = "    #[AsMessageHandler(handles: App\\Message\\SendEmail::class, method: 'handleIt')]\n";
    const args = attributeArgs(region, "AsMessageHandler").?;
    try std.testing.expectEqualStrings("App\\Message\\SendEmail", namedArgClassLike(args, "handles").?);
    try std.testing.expectEqualStrings("handleIt", namedArgString(args, "method").?);
    // A bare attribute (no parens) yields empty args, and absent attrs are null.
    try std.testing.expectEqualStrings("", attributeArgs("#[AsMessageHandler]\n", "AsMessageHandler").?);
    try std.testing.expect(attributeArgs(region, "AsEventListener") == null);
}

test "named arg accepts class-string form and ignores :: scope operator" {
    // handles as a quoted class-string (soft dependency) rather than ::class.
    const args = "event: 'App\\Event\\Foo', method: 'onFoo'";
    try std.testing.expectEqualStrings("App\\Event\\Foo", namedArgClassLike(args, "event").?);
    try std.testing.expectEqualStrings("onFoo", namedArgString(args, "method").?);
    // `method` substring inside another token must not false-match.
    try std.testing.expect(namedArgString("notmethod: 'x'", "method") == null);
}

test "extractMappingsFromSource handles FQN-string keys (soft dependency)" {
    const source =
        \\public static function getSubscribedEvents(): array
        \\{
        \\    return [
        \\        'App\Event\UserCreated' => 'onUserCreated',
        \\        'App\Event\OrderPlaced' => ['onOrderPlaced', 10],
        \\        'kernel.request' => 'onRequest',
        \\    ];
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const mappings = try extractMappingsFromSource(allocator, source, "App\\Subscriber");

    // Two FQN-string keys map; the plain event-name string is not a class.
    try std.testing.expectEqual(@as(usize, 2), mappings.len);
    try std.testing.expectEqualStrings("App\\Event\\UserCreated", mappings[0].event_class);
    try std.testing.expectEqualStrings("onUserCreated", mappings[0].handler_method);
    try std.testing.expectEqualStrings("App\\Event\\OrderPlaced", mappings[1].event_class);
    try std.testing.expectEqualStrings("onOrderPlaced", mappings[1].handler_method);
}

test "extractMappingsFromSource" {
    const source =
        \\public static function getSubscribedEvents(): array
        \\{
        \\    return [
        \\        UserCreatedEvent::class => 'onUserCreated',
        \\        OrderPlacedEvent::class => 'onOrderPlaced',
        \\    ];
        \\}
    ;

    // Mappings dupe their strings; use an arena so the test frees them wholesale.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const mappings = try extractMappingsFromSource(allocator, source, "App\\Subscriber");

    try std.testing.expectEqual(@as(usize, 2), mappings.len);
    try std.testing.expectEqualStrings("UserCreatedEvent", mappings[0].event_class);
    try std.testing.expectEqualStrings("onUserCreated", mappings[0].handler_method);
}
