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
// Detects Symfony EventDispatcher patterns and creates synthetic edges
// from dispatch() calls to event subscriber handler methods
// ============================================================================

/// Plugin instance
pub const plugin = Plugin{
    .name = "symfony-events",
    .description = "Detects Symfony EventDispatcher patterns and creates synthetic edges from dispatch() to subscriber handlers",
    .version = "1.0.0",
    .analyzeFn = analyze,
};

/// Event to handler mapping
const EventHandlerMapping = struct {
    /// The event class FQCN (e.g., "App\\Event\\UserCreatedEvent")
    event_class: []const u8,
    /// The subscriber class FQCN
    subscriber_class: []const u8,
    /// The handler method name
    handler_method: []const u8,
    /// Priority (higher = earlier execution)
    priority: i32,
};

/// Main analysis function
fn analyze(ctx: *const PluginContext) anyerror![]const SyntheticEdge {
    var edges: std.ArrayListUnmanaged(SyntheticEdge) = .empty;

    // Step 1: Build event -> handlers mapping from EventSubscriberInterface implementations
    const event_mappings = try buildEventMappings(ctx);

    // Step 2: Find all dispatch() calls
    const dispatch_calls = try ctx.findCallsTo(null, "dispatch");

    // Step 3: For each dispatch call, link to handlers based on event type
    for (dispatch_calls) |dispatch_call| {
        // Try to extract event class from the dispatch call arguments
        // For now, we use a heuristic based on the caller context
        const event_class = try extractEventClassFromCall(ctx, dispatch_call);

        if (event_class) |ec| {
            // Find all handlers for this specific event
            for (event_mappings) |mapping| {
                if (eventClassMatches(ec, mapping.event_class)) {
                    const callee_fqn = try std.fmt.allocPrint(
                        ctx.allocator,
                        "{s}::{s}",
                        .{ mapping.subscriber_class, mapping.handler_method },
                    );

                    const reason = try std.fmt.allocPrint(
                        ctx.allocator,
                        "Symfony event: {s} -> {s}",
                        .{ ec, mapping.handler_method },
                    );

                    try edges.append(ctx.allocator, .{
                        .caller_fqn = dispatch_call.caller_fqn,
                        .callee_fqn = callee_fqn,
                        .file_path = dispatch_call.file_path,
                        .line = dispatch_call.line,
                        .confidence = 0.95, // High confidence for exact event match
                        .reason = reason,
                        .plugin_name = "symfony-events",
                    });
                }
            }
        } else {
            // Couldn't determine event type - skip for now
            // A more aggressive approach would link to ALL handlers with low confidence
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

    const allocator = std.testing.allocator;
    const mappings = try extractMappingsFromSource(allocator, source, "App\\Subscriber");
    defer allocator.free(mappings);

    try std.testing.expectEqual(@as(usize, 2), mappings.len);
    try std.testing.expectEqualStrings("UserCreatedEvent", mappings[0].event_class);
    try std.testing.expectEqualStrings("onUserCreated", mappings[0].handler_method);
}
