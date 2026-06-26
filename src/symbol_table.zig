const std = @import("std");
const types = @import("types.zig");

const ClassSymbol = types.ClassSymbol;
const InterfaceSymbol = types.InterfaceSymbol;
const TraitSymbol = types.TraitSymbol;
const FunctionSymbol = types.FunctionSymbol;
const MethodSymbol = types.MethodSymbol;
const PropertySymbol = types.PropertySymbol;
const TypeInfo = types.TypeInfo;

// ============================================================================
// Symbol Table - Global registry of all symbols
// ============================================================================

pub const SymbolTable = struct {
    classes: std.StringHashMap(ClassSymbol),
    interfaces: std.StringHashMap(InterfaceSymbol),
    traits: std.StringHashMap(TraitSymbol),
    functions: std.StringHashMap(FunctionSymbol),
    allocator: std.mem.Allocator,

    // Tier-2 derived view (inheritance/trait resolution). Non-owning: built and
    // owned elsewhere (e.g. `ProjectIndex`) and rebuilt wholesale on change.
    // `null` until a view is attached; lookups then fall back to raw members.
    resolved: ?*const ResolvedView = null,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .classes = std.StringHashMap(ClassSymbol).init(allocator),
            .interfaces = std.StringHashMap(InterfaceSymbol).init(allocator),
            .traits = std.StringHashMap(TraitSymbol).init(allocator),
            .functions = std.StringHashMap(FunctionSymbol).init(allocator),
            .allocator = allocator,
            .resolved = null,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        // Deinit all class symbols
        var class_it = self.classes.valueIterator();
        while (class_it.next()) |class| {
            @constCast(class).deinit();
        }
        self.classes.deinit();

        // Deinit all interface symbols
        var iface_it = self.interfaces.valueIterator();
        while (iface_it.next()) |iface| {
            @constCast(iface).deinit();
        }
        self.interfaces.deinit();

        // Deinit all trait symbols
        var trait_it = self.traits.valueIterator();
        while (trait_it.next()) |t| {
            @constCast(t).deinit();
        }
        self.traits.deinit();

        self.functions.deinit();
    }

    // ========================================================================
    // Adding symbols
    // ========================================================================

    pub fn addClass(self: *SymbolTable, class: ClassSymbol) !void {
        try self.classes.put(class.fqcn, class);
        self.resolved = null;
    }

    pub fn addInterface(self: *SymbolTable, iface: InterfaceSymbol) !void {
        try self.interfaces.put(iface.fqcn, iface);
        self.resolved = null;
    }

    pub fn addTrait(self: *SymbolTable, trait: TraitSymbol) !void {
        try self.traits.put(trait.fqcn, trait);
        self.resolved = null;
    }

    pub fn addFunction(self: *SymbolTable, func: FunctionSymbol) !void {
        try self.functions.put(func.fqn, func);
    }

    // ========================================================================
    // Looking up symbols
    // ========================================================================

    pub fn getClass(self: *const SymbolTable, fqcn: []const u8) ?*const ClassSymbol {
        return self.classes.getPtr(fqcn);
    }

    pub fn getClassMut(self: *SymbolTable, fqcn: []const u8) ?*ClassSymbol {
        return self.classes.getPtr(fqcn);
    }

    pub fn getInterface(self: *const SymbolTable, fqcn: []const u8) ?*const InterfaceSymbol {
        return self.interfaces.getPtr(fqcn);
    }

    pub fn getTrait(self: *const SymbolTable, fqcn: []const u8) ?*const TraitSymbol {
        return self.traits.getPtr(fqcn);
    }

    pub fn getFunction(self: *const SymbolTable, fqn: []const u8) ?*const FunctionSymbol {
        return self.functions.getPtr(fqn);
    }

    /// Resolve a method call to its target
    /// Returns the MethodSymbol if found, searching through inheritance
    pub fn resolveMethod(self: *const SymbolTable, class_fqcn: []const u8, method_name: []const u8) ?*const MethodSymbol {
        // Prefer the Tier-2 resolved view (includes inherited + trait methods).
        if (self.resolved) |view| {
            return view.resolveMethod(class_fqcn, method_name);
        }
        // No view attached yet: fall back to directly-declared methods.
        if (self.classes.getPtr(class_fqcn)) |class| {
            return class.methods.getPtr(method_name);
        }
        return null;
    }

    /// Resolve a property access
    pub fn resolveProperty(self: *const SymbolTable, class_fqcn: []const u8, property_name: []const u8) ?*const PropertySymbol {
        if (self.resolved) |view| {
            return view.resolveProperty(class_fqcn, property_name);
        }
        if (self.classes.getPtr(class_fqcn)) |class| {
            return class.properties.getPtr(property_name);
        }
        return null;
    }

    /// Resolve a method against an interface's own declarations, following
    /// parent interfaces (`extends`). Returns the abstract method declaration
    /// (a real, navigable node) so an interface-typed call resolves to the
    /// contract even when it has several — or zero — in-project implementors.
    /// Bounded recursion guarded by a small visited set.
    pub fn resolveInterfaceMethod(self: *const SymbolTable, iface_fqcn: []const u8, method_name: []const u8) ?*const MethodSymbol {
        var visited: [32][]const u8 = undefined;
        return self.resolveInterfaceMethodInner(iface_fqcn, method_name, &visited, 0);
    }

    fn resolveInterfaceMethodInner(
        self: *const SymbolTable,
        iface_fqcn: []const u8,
        method_name: []const u8,
        visited: *[32][]const u8,
        depth: usize,
    ) ?*const MethodSymbol {
        for (visited[0..depth]) |seen| {
            if (std.mem.eql(u8, seen, iface_fqcn)) return null;
        }
        const iface = self.interfaces.getPtr(iface_fqcn) orelse return null;
        if (iface.methods.getPtr(method_name)) |m| return m;
        if (depth >= visited.len) return null;
        visited[depth] = iface_fqcn;
        for (iface.extends) |parent_iface| {
            if (self.resolveInterfaceMethodInner(parent_iface, method_name, visited, depth + 1)) |m| return m;
        }
        return null;
    }

    /// Return the sole in-project implementor of an interface, if exactly one
    /// exists (Phase A DI-aware resolution). Requires the Tier-2 view.
    pub fn singleImplementor(self: *const SymbolTable, iface_fqcn: []const u8) ?[]const u8 {
        if (self.resolved) |view| return view.singleImplementor(iface_fqcn);
        return null;
    }

    /// Return the concrete class explicitly bound to an interface via DI config
    /// (services.yaml), if any (Phase B DI-aware resolution). Authoritative over
    /// `singleImplementor`. Requires the Tier-2 view.
    pub fn explicitBinding(self: *const SymbolTable, iface_fqcn: []const u8) ?[]const u8 {
        if (self.resolved) |view| return view.explicitImplementor(iface_fqcn);
        return null;
    }

    /// Check if a type exists (class, interface, or trait)
    pub fn typeExists(self: *const SymbolTable, fqcn: []const u8) bool {
        return self.classes.contains(fqcn) or
            self.interfaces.contains(fqcn) or
            self.traits.contains(fqcn);
    }

    // ========================================================================
    // Statistics and debugging
    // ========================================================================

    pub fn getStats(self: *const SymbolTable) Stats {
        var total_methods: usize = 0;
        var total_properties: usize = 0;

        var class_it = self.classes.valueIterator();
        while (class_it.next()) |class| {
            total_methods += class.methods.count();
            total_properties += class.properties.count();
        }

        var iface_it = self.interfaces.valueIterator();
        while (iface_it.next()) |iface| {
            total_methods += iface.methods.count();
        }

        var trait_it = self.traits.valueIterator();
        while (trait_it.next()) |t| {
            total_methods += t.methods.count();
            total_properties += t.properties.count();
        }

        return .{
            .class_count = self.classes.count(),
            .interface_count = self.interfaces.count(),
            .trait_count = self.traits.count(),
            .function_count = self.functions.count(),
            .method_count = total_methods,
            .property_count = total_properties,
        };
    }

    pub const Stats = struct {
        class_count: usize,
        interface_count: usize,
        trait_count: usize,
        function_count: usize,
        method_count: usize,
        property_count: usize,
    };

    pub fn printStats(self: *const SymbolTable, file: std.Io.File) !void {
        const stats = self.getStats();
        const msg = try std.fmt.allocPrint(self.allocator,
            \\Symbol Table Statistics:
            \\  Classes:    {d}
            \\  Interfaces: {d}
            \\  Traits:     {d}
            \\  Functions:  {d}
            \\  Methods:    {d}
            \\  Properties: {d}
            \\
        , .{
            stats.class_count,
            stats.interface_count,
            stats.trait_count,
            stats.function_count,
            stats.method_count,
            stats.property_count,
        });
        defer self.allocator.free(msg);
        try file.writeStreamingAll(types.io, msg);
    }
};

// ============================================================================
// ResolvedView — Tier-2 derived inheritance/trait resolution
// ============================================================================
//
// Built from the immutable Tier-1 `SymbolTable`, this holds the resolved view
// of each class (inherited + trait members, ancestor chain) in a separate
// structure keyed by FQCN. It never mutates the raw symbols, so it can be torn
// down and rebuilt wholesale (cheap, leak-free) whenever Tier-1 changes — the
// foundation for the MCP cache's invalidation story.
//
// All derived state lives in `arena`; the `*MethodSymbol`/`*PropertySymbol`
// pointers and FQCN keys are *borrowed* from the raw table, which must outlive
// the view.

/// Resolved members for a single class.
pub const ResolvedClass = struct {
    all_methods: std.StringHashMap(*const MethodSymbol),
    all_properties: std.StringHashMap(*const PropertySymbol),
    parent_chain: []const []const u8, // Ordered list of ancestors (nearest first)
};

pub const ResolvedView = struct {
    arena: std.heap.ArenaAllocator,
    classes: std.StringHashMap(ResolvedClass),
    /// Interface FQCN -> the sole in-project class implementing it. Only
    /// populated for interfaces with *exactly one* implementor (Phase A
    /// DI-aware resolution: an interface-typed property/param then resolves
    /// unambiguously to that concrete class). Borrowed FQCN strings.
    iface_single_impl: std.StringHashMap([]const u8),
    /// Interface FQCN -> concrete FQCN bound explicitly via DI config
    /// (services.yaml). Authoritative even when several implementors exist, so
    /// it is consulted *before* `iface_single_impl` (Phase B DI-aware
    /// resolution). Keys/values are owned by this view's arena.
    explicit_bindings: std.StringHashMap([]const u8),
    table: *const SymbolTable,

    /// Build the resolved view from a fully-collected raw table. Allocated
    /// behind a pointer (with its own arena) so it owns an independent,
    /// resettable lifetime. Caller owns the result and must call `destroy`.
    pub fn build(gpa: std.mem.Allocator, table: *const SymbolTable) !*ResolvedView {
        const self = try gpa.create(ResolvedView);
        errdefer gpa.destroy(self);

        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        self.table = table;
        self.classes = std.StringHashMap(ResolvedClass).init(a);
        self.iface_single_impl = std.StringHashMap([]const u8).init(a);
        self.explicit_bindings = std.StringHashMap([]const u8).init(a);

        // Topological order ensures a class's parent is resolved before it.
        const sorted = try topologicalSort(table, a);
        for (sorted) |fqcn| {
            try self.resolveClass(fqcn);
        }

        try self.buildInterfaceImplIndex();

        return self;
    }

    /// Build the interface -> single-implementor index. Counts how many
    /// in-project classes implement each interface; only interfaces with a
    /// unique implementor are recorded. Implemented-interface inheritance
    /// (`interface B extends A`) is followed so that a class implementing `B`
    /// also counts as an implementor of `A`.
    fn buildInterfaceImplIndex(self: *ResolvedView) !void {
        const a = self.arena.allocator();

        // interface FQCN -> implementor FQCN (or sentinel for "ambiguous").
        const ambiguous: []const u8 = "\x00ambiguous";
        var counts = std.StringHashMap([]const u8).init(a);
        defer counts.deinit();

        var class_it = self.table.classes.iterator();
        while (class_it.next()) |entry| {
            const class_fqcn = entry.key_ptr.*;
            const class = entry.value_ptr;
            for (class.implements) |iface_fqcn| {
                try self.recordImplementor(&counts, iface_fqcn, class_fqcn, ambiguous);
            }
        }

        var cit = counts.iterator();
        while (cit.next()) |entry| {
            if (entry.value_ptr.*.ptr == ambiguous.ptr) continue;
            try self.iface_single_impl.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Record `class_fqcn` as an implementor of `iface_fqcn` and, transitively,
    /// of every interface `iface_fqcn` extends. A second distinct implementor
    /// marks the interface ambiguous.
    fn recordImplementor(
        self: *ResolvedView,
        counts: *std.StringHashMap([]const u8),
        iface_fqcn: []const u8,
        class_fqcn: []const u8,
        ambiguous: []const u8,
    ) !void {
        const gop = try counts.getOrPut(iface_fqcn);
        if (!gop.found_existing) {
            gop.value_ptr.* = class_fqcn;
        } else if (gop.value_ptr.*.ptr != ambiguous.ptr and
            !std.mem.eql(u8, gop.value_ptr.*, class_fqcn))
        {
            gop.value_ptr.* = ambiguous;
        }

        // Follow parent interfaces so sub-interface implementors also count.
        if (self.table.interfaces.get(iface_fqcn)) |iface| {
            for (iface.extends) |parent_iface| {
                try self.recordImplementor(counts, parent_iface, class_fqcn, ambiguous);
            }
        }
    }

    /// Return the sole implementor of `iface_fqcn`, if exactly one exists.
    pub fn singleImplementor(self: *const ResolvedView, iface_fqcn: []const u8) ?[]const u8 {
        return self.iface_single_impl.get(iface_fqcn);
    }

    /// Register an explicit DI binding (interface -> concrete) from config.
    /// Strings are duped into this view's arena. A later binding for the same
    /// interface overrides an earlier one (Symfony "last definition wins").
    /// Only bindings whose concrete class is known in-project are recorded, so
    /// `explicitImplementor` never points at a method that can't be resolved.
    pub fn addExplicitBinding(self: *ResolvedView, iface_fqcn: []const u8, concrete_fqcn: []const u8) !void {
        if (self.table.classes.get(concrete_fqcn) == null) return;
        const a = self.arena.allocator();
        const gop = try self.explicit_bindings.getOrPut(iface_fqcn);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, iface_fqcn);
        }
        gop.value_ptr.* = try a.dupe(u8, concrete_fqcn);
    }

    /// Return the explicitly-bound concrete class for `iface_fqcn`, if any.
    pub fn explicitImplementor(self: *const ResolvedView, iface_fqcn: []const u8) ?[]const u8 {
        return self.explicit_bindings.get(iface_fqcn);
    }

    pub fn destroy(self: *ResolvedView) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Resolve a method including inherited + trait methods.
    pub fn resolveMethod(self: *const ResolvedView, class_fqcn: []const u8, method_name: []const u8) ?*const MethodSymbol {
        if (self.classes.getPtr(class_fqcn)) |rc| {
            return rc.all_methods.get(method_name);
        }
        return null;
    }

    /// Resolve a property including inherited + trait properties.
    pub fn resolveProperty(self: *const ResolvedView, class_fqcn: []const u8, property_name: []const u8) ?*const PropertySymbol {
        if (self.classes.getPtr(class_fqcn)) |rc| {
            return rc.all_properties.get(property_name);
        }
        return null;
    }

    pub fn getClass(self: *const ResolvedView, fqcn: []const u8) ?*const ResolvedClass {
        return self.classes.getPtr(fqcn);
    }

    /// Resolve one class. Mirrors the previous in-place algorithm exactly, but
    /// writes into a fresh `ResolvedClass` instead of mutating the raw symbol.
    fn resolveClass(self: *ResolvedView, fqcn: []const u8) !void {
        const a = self.arena.allocator();
        const class = self.table.classes.getPtr(fqcn) orelse return;

        var rc = ResolvedClass{
            .all_methods = std.StringHashMap(*const MethodSymbol).init(a),
            .all_properties = std.StringHashMap(*const PropertySymbol).init(a),
            .parent_chain = &.{},
        };

        // Build parent chain by walking `extends` up the raw table.
        var chain: std.ArrayListUnmanaged([]const u8) = .empty;
        var current_fqcn = class.extends;
        while (current_fqcn) |parent_fqcn| {
            try chain.append(a, parent_fqcn);
            if (self.table.classes.get(parent_fqcn)) |parent| {
                current_fqcn = parent.extends;
            } else {
                break;
            }
        }
        rc.parent_chain = try chain.toOwnedSlice(a);

        // Inherit from the (already-resolved) parent.
        if (class.extends) |parent_fqcn| {
            if (self.classes.getPtr(parent_fqcn)) |parent_rc| {
                var method_it = parent_rc.all_methods.iterator();
                while (method_it.next()) |entry| {
                    if (!class.methods.contains(entry.key_ptr.*)) {
                        try rc.all_methods.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
                var prop_it = parent_rc.all_properties.iterator();
                while (prop_it.next()) |entry| {
                    if (!class.properties.contains(entry.key_ptr.*)) {
                        try rc.all_properties.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }
        }

        // Apply traits (only where not already present).
        for (class.uses) |trait_fqcn| {
            if (self.table.traits.get(trait_fqcn)) |trait| {
                var method_it = trait.methods.iterator();
                while (method_it.next()) |entry| {
                    if (!rc.all_methods.contains(entry.key_ptr.*)) {
                        try rc.all_methods.put(entry.key_ptr.*, entry.value_ptr);
                    }
                }
                var prop_it = trait.properties.iterator();
                while (prop_it.next()) |entry| {
                    if (!rc.all_properties.contains(entry.key_ptr.*)) {
                        try rc.all_properties.put(entry.key_ptr.*, entry.value_ptr);
                    }
                }
            }
        }

        // Own members override inherited/trait ones.
        var own_method_it = class.methods.iterator();
        while (own_method_it.next()) |entry| {
            try rc.all_methods.put(entry.key_ptr.*, entry.value_ptr);
        }
        var own_prop_it = class.properties.iterator();
        while (own_prop_it.next()) |entry| {
            try rc.all_properties.put(entry.key_ptr.*, entry.value_ptr);
        }

        try self.classes.put(fqcn, rc);
    }

    /// Topologically sort classes so parents come before children.
    fn topologicalSort(table: *const SymbolTable, a: std.mem.Allocator) ![]const []const u8 {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        var visited = std.StringHashMap(void).init(a);
        defer visited.deinit();
        var in_progress = std.StringHashMap(void).init(a);
        defer in_progress.deinit();

        var it = table.classes.keyIterator();
        while (it.next()) |fqcn| {
            try topologicalVisit(table, fqcn.*, &result, &visited, &in_progress, a);
        }

        return result.toOwnedSlice(a);
    }

    fn topologicalVisit(
        table: *const SymbolTable,
        fqcn: []const u8,
        result: *std.ArrayListUnmanaged([]const u8),
        visited: *std.StringHashMap(void),
        in_progress: *std.StringHashMap(void),
        a: std.mem.Allocator,
    ) !void {
        if (visited.contains(fqcn)) return;
        if (in_progress.contains(fqcn)) {
            // Cycle detected - just skip
            return;
        }

        try in_progress.put(fqcn, {});

        // Visit parent first
        if (table.classes.get(fqcn)) |class| {
            if (class.extends) |parent_fqcn| {
                try topologicalVisit(table, parent_fqcn, result, visited, in_progress, a);
            }
        }

        _ = in_progress.remove(fqcn);
        try visited.put(fqcn, {});
        try result.append(a, fqcn);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SymbolTable basic operations" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Add a class
    var class = ClassSymbol.init(allocator, "App\\Service\\UserService");
    class.file_path = "src/Service/UserService.php";
    try table.addClass(class);

    // Lookup
    const found = table.getClass("App\\Service\\UserService");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("UserService", found.?.name);
}

test "SymbolTable inheritance resolution" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Create parent class with a method
    var parent = ClassSymbol.init(allocator, "App\\BaseService");
    try parent.addMethod(.{
        .name = "doSomething",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 10,
        .end_line = 15,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\BaseService",
        .file_path = "",
    });
    try table.addClass(parent);

    // Create child class
    var child = ClassSymbol.init(allocator, "App\\UserService");
    child.extends = "App\\BaseService";
    try table.addClass(child);

    // Build the Tier-2 resolved view and attach it.
    const view = try ResolvedView.build(allocator, &table);
    defer view.destroy();
    table.resolved = view;

    // Child should have parent's method
    const method = table.resolveMethod("App\\UserService", "doSomething");
    try std.testing.expect(method != null);
}

test "ResolvedView multi-level inheritance, override, traits, properties" {
    const allocator = std.testing.allocator;

    // Minimal MethodSymbol/PropertySymbol builders to keep the test readable.
    const M = struct {
        fn make(name: []const u8, owner: []const u8) types.MethodSymbol {
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
                .containing_class = owner,
                .file_path = "",
            };
        }
    };
    const P = struct {
        fn make(name: []const u8) types.PropertySymbol {
            return .{
                .name = name,
                .visibility = .public,
                .is_static = false,
                .is_readonly = false,
                .declared_type = null,
                .phpdoc_type = null,
                .default_value_type = null,
                .line = 0,
            };
        }
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Trait T: m_trait + p_trait
    var trait = TraitSymbol.init(allocator, "App\\T");
    try trait.addMethod(M.make("m_trait", "App\\T"));
    try trait.addProperty(P.make("p_trait"));
    try table.addTrait(trait);

    // A (base): m_base + p_base
    var a = ClassSymbol.init(allocator, "App\\A");
    try a.addMethod(M.make("m_base", "App\\A"));
    try a.addProperty(P.make("p_base"));
    try table.addClass(a);

    // B extends A, uses T, overrides m_base, adds m_b
    var b = ClassSymbol.init(allocator, "App\\B");
    b.extends = "App\\A";
    b.uses = &.{"App\\T"};
    try b.addMethod(M.make("m_base", "App\\B")); // override
    try b.addMethod(M.make("m_b", "App\\B"));
    try table.addClass(b);

    // C extends B, adds m_c
    var c = ClassSymbol.init(allocator, "App\\C");
    c.extends = "App\\B";
    try c.addMethod(M.make("m_c", "App\\C"));
    try table.addClass(c);

    const view = try ResolvedView.build(allocator, &table);
    defer view.destroy();
    table.resolved = view;

    // C sees inherited, trait, and own methods.
    try std.testing.expect(table.resolveMethod("App\\C", "m_base") != null);
    try std.testing.expect(table.resolveMethod("App\\C", "m_b") != null);
    try std.testing.expect(table.resolveMethod("App\\C", "m_c") != null);
    try std.testing.expect(table.resolveMethod("App\\C", "m_trait") != null);

    // Override resolves to the nearest definition (B, not A).
    const m_base = table.resolveMethod("App\\C", "m_base").?;
    try std.testing.expectEqualStrings("App\\B", m_base.containing_class);

    // Properties inherit (from A) and come via traits (from T into B, then C).
    try std.testing.expect(table.resolveProperty("App\\C", "p_base") != null);
    try std.testing.expect(table.resolveProperty("App\\B", "p_trait") != null);
    try std.testing.expect(table.resolveProperty("App\\C", "p_trait") != null);

    // No downward leakage: A does not see B's/C's members.
    try std.testing.expect(table.resolveMethod("App\\A", "m_b") == null);
    try std.testing.expect(table.resolveMethod("App\\A", "m_c") == null);

    // Parent chain ordered nearest-first.
    const rc_c = view.getClass("App\\C").?;
    try std.testing.expectEqual(@as(usize, 2), rc_c.parent_chain.len);
    try std.testing.expectEqualStrings("App\\B", rc_c.parent_chain[0]);
    try std.testing.expectEqualStrings("App\\A", rc_c.parent_chain[1]);
}
