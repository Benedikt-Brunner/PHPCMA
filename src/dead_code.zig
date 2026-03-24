const std = @import("std");
const types = @import("types.zig");

const ClassSymbol = types.ClassSymbol;
const InterfaceSymbol = types.InterfaceSymbol;
const TraitSymbol = types.TraitSymbol;
const FunctionSymbol = types.FunctionSymbol;
const MethodSymbol = types.MethodSymbol;
const Visibility = types.Visibility;
const SymbolTable = @import("symbol_table.zig").SymbolTable;

// ============================================================================
// Symbol Identification
// ============================================================================

/// Compact identifier for a symbol in the liveness graph.
pub const SymbolId = u32;

pub const sentinel: SymbolId = std.math.maxInt(SymbolId);

/// What kind of declaration a symbol represents.
pub const SymbolKind = enum {
    class,
    interface,
    trait,
    function,
    method,
    property,
};

/// Fully-qualified key used to look up a SymbolId.
pub const SymbolKey = struct {
    kind: SymbolKind,
    fqn: []const u8,
};

// ============================================================================
// Liveness References (input facts)
// ============================================================================

/// Why a symbol was referenced — determines propagation strength.
pub const LivenessReason = enum {
    resolved_call,
    unresolved_call,
    instantiate,
    static_access,
    type_hint,
    phpdoc,
    attribute,
    string_ref,
    reflection,
    inheritance,
    interface_impl,
    trait_use,
    magic_method,
    callable_ref,
    property_access,
};

/// A single reference fact extracted from source code.
pub const LivenessRef = struct {
    target_fqn: []const u8,
    target_kind: SymbolKind,
    reason: LivenessReason,
    is_weak: bool,
    source_file: []const u8,
    source_line: u32,
};

// ============================================================================
// Symbol Index — maps names to SymbolIds
// ============================================================================

pub const SymbolIndex = struct {
    /// FQCN / FQN → SymbolId.
    fqn_to_id: std.StringHashMapUnmanaged(SymbolId),
    /// SymbolId → key (reverse map).
    id_to_key: std.ArrayListUnmanaged(SymbolKey),

    /// short method name → []SymbolId (for unresolved expansion).
    methods_by_short_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)),

    /// short function name → []SymbolId (for unresolved expansion).
    functions_by_short_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(SymbolId)),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolIndex {
        return .{
            .fqn_to_id = .empty,
            .id_to_key = .empty,
            .methods_by_short_name = .empty,
            .functions_by_short_name = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolIndex) void {
        self.fqn_to_id.deinit(self.allocator);
        self.id_to_key.deinit(self.allocator);
        {
            var it = self.methods_by_short_name.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            self.methods_by_short_name.deinit(self.allocator);
        }
        {
            var it = self.functions_by_short_name.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.allocator);
            }
            self.functions_by_short_name.deinit(self.allocator);
        }
    }

    /// Register a symbol and return its id.
    pub fn register(self: *SymbolIndex, kind: SymbolKind, fqn: []const u8) !SymbolId {
        const gop = try self.fqn_to_id.getOrPut(self.allocator, fqn);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: SymbolId = @intCast(self.id_to_key.items.len);
        gop.value_ptr.* = id;
        try self.id_to_key.append(self.allocator, .{ .kind = kind, .fqn = fqn });
        return id;
    }

    pub fn lookup(self: *const SymbolIndex, fqn: []const u8) ?SymbolId {
        return self.fqn_to_id.get(fqn);
    }

    pub fn getKey(self: *const SymbolIndex, id: SymbolId) SymbolKey {
        return self.id_to_key.items[id];
    }

    pub fn count(self: *const SymbolIndex) u32 {
        return @intCast(self.id_to_key.items.len);
    }

    /// Add a method id to the short-name index.
    fn addMethodShortName(self: *SymbolIndex, short_name: []const u8, id: SymbolId) !void {
        const gop = try self.methods_by_short_name.getOrPut(self.allocator, short_name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, id);
    }

    /// Add a function id to the short-name index.
    fn addFunctionShortName(self: *SymbolIndex, short_name: []const u8, id: SymbolId) !void {
        const gop = try self.functions_by_short_name.getOrPut(self.allocator, short_name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, id);
    }
};

// ============================================================================
// Hierarchy Index — pre-computed inheritance relationships
// ============================================================================

pub const HierarchyIndex = struct {
    /// class FQCN → list of direct child class FQCNs.
    class_children: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    /// interface FQCN → list of implementing class FQCNs.
    interface_implementors: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    /// trait FQCN → list of using class FQCNs.
    trait_users: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    /// method FQN (Class::method) → list of override FQNs.
    method_overrides: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HierarchyIndex {
        return .{
            .class_children = .empty,
            .interface_implementors = .empty,
            .trait_users = .empty,
            .method_overrides = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HierarchyIndex) void {
        deinitListMap(&self.class_children, self.allocator);
        deinitListMap(&self.interface_implementors, self.allocator);
        deinitListMap(&self.trait_users, self.allocator);
        deinitListMap(&self.method_overrides, self.allocator);
    }

    fn deinitListMap(map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)), allocator: std.mem.Allocator) void {
        var it = map.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        map.deinit(allocator);
    }

    fn appendToList(map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const gop = try map.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, value);
    }
};

// ============================================================================
// Dead Symbol Result
// ============================================================================

pub const DeadSymbol = struct {
    fqn: []const u8,
    kind: SymbolKind,
    file_path: []const u8,
    line: u32,
    is_weak: bool,
};

// ============================================================================
// ProjectLivenessGraph
// ============================================================================

pub const ProjectLivenessGraph = struct {
    index: SymbolIndex,
    hierarchy: HierarchyIndex,

    /// Bit per SymbolId — true means alive (strong evidence).
    alive: std.DynamicBitSetUnmanaged,
    /// Bit per SymbolId — true means alive via weak/unresolved evidence.
    weak_alive: std.DynamicBitSetUnmanaged,

    allocator: std.mem.Allocator,

    // Temporary allocations used during the algorithm
    alloc_buf: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) ProjectLivenessGraph {
        return .{
            .index = SymbolIndex.init(allocator),
            .hierarchy = HierarchyIndex.init(allocator),
            .alive = .{},
            .weak_alive = .{},
            .allocator = allocator,
            .alloc_buf = .empty,
        };
    }

    pub fn deinit(self: *ProjectLivenessGraph) void {
        self.index.deinit();
        self.hierarchy.deinit();
        self.alive.deinit(self.allocator);
        self.weak_alive.deinit(self.allocator);
        for (self.alloc_buf.items) |buf| self.allocator.free(buf);
        self.alloc_buf.deinit(self.allocator);
    }

    /// Helper: allocate a formatted string that lives as long as the graph.
    fn dupeStr(self: *ProjectLivenessGraph, s: []const u8) ![]const u8 {
        const d = try self.allocator.dupe(u8, s);
        try self.alloc_buf.append(self.allocator, d);
        return d;
    }

    fn fmtStr(self: *ProjectLivenessGraph, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const d = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.alloc_buf.append(self.allocator, d);
        return d;
    }

    // ====================================================================
    // Phase 1 — Index: build SymbolIndex + HierarchyIndex from SymbolTable
    // ====================================================================

    pub fn buildIndex(self: *ProjectLivenessGraph, sym: *const SymbolTable) !void {
        // Register classes
        var class_it = sym.classes.iterator();
        while (class_it.next()) |entry| {
            const fqcn = entry.key_ptr.*;
            const class = entry.value_ptr;
            _ = try self.index.register(.class, fqcn);

            // Register methods
            var method_it = class.methods.iterator();
            while (method_it.next()) |m| {
                const mfqn = try self.fmtStr("{s}::{s}", .{ fqcn, m.key_ptr.* });
                const mid = try self.index.register(.method, mfqn);
                try self.index.addMethodShortName(m.key_ptr.*, mid);
            }

            // Register properties
            var prop_it = class.properties.iterator();
            while (prop_it.next()) |p| {
                const pfqn = try self.fmtStr("{s}::${s}", .{ fqcn, p.key_ptr.* });
                _ = try self.index.register(.property, pfqn);
            }

            // Hierarchy: parent → child
            if (class.extends) |parent| {
                try HierarchyIndex.appendToList(&self.hierarchy.class_children, self.allocator, parent, fqcn);
            }

            // Hierarchy: interface → implementor
            for (class.implements) |iface_fqcn| {
                try HierarchyIndex.appendToList(&self.hierarchy.interface_implementors, self.allocator, iface_fqcn, fqcn);
            }

            // Hierarchy: trait → user
            for (class.uses) |trait_fqcn| {
                try HierarchyIndex.appendToList(&self.hierarchy.trait_users, self.allocator, trait_fqcn, fqcn);
            }
        }

        // Register interfaces
        var iface_it = sym.interfaces.iterator();
        while (iface_it.next()) |entry| {
            const fqcn = entry.key_ptr.*;
            const iface = entry.value_ptr;
            _ = try self.index.register(.interface, fqcn);

            var method_it = iface.methods.iterator();
            while (method_it.next()) |m| {
                const mfqn = try self.fmtStr("{s}::{s}", .{ fqcn, m.key_ptr.* });
                const mid = try self.index.register(.method, mfqn);
                try self.index.addMethodShortName(m.key_ptr.*, mid);
            }
        }

        // Register traits
        var trait_it = sym.traits.iterator();
        while (trait_it.next()) |entry| {
            const fqcn = entry.key_ptr.*;
            const t = entry.value_ptr;
            _ = try self.index.register(.trait, fqcn);

            var method_it = t.methods.iterator();
            while (method_it.next()) |m| {
                const mfqn = try self.fmtStr("{s}::{s}", .{ fqcn, m.key_ptr.* });
                const mid = try self.index.register(.method, mfqn);
                try self.index.addMethodShortName(m.key_ptr.*, mid);
            }

            var prop_it = t.properties.iterator();
            while (prop_it.next()) |p| {
                const pfqn = try self.fmtStr("{s}::${s}", .{ fqcn, p.key_ptr.* });
                _ = try self.index.register(.property, pfqn);
            }
        }

        // Register functions
        var func_it = sym.functions.iterator();
        while (func_it.next()) |entry| {
            const fqn = entry.key_ptr.*;
            const fid = try self.index.register(.function, fqn);

            // Short name index
            const short = if (std.mem.lastIndexOf(u8, fqn, "\\")) |sep| fqn[sep + 1 ..] else fqn;
            try self.index.addFunctionShortName(short, fid);
        }

        // Build method override index
        try self.buildMethodOverrides(sym);

        // Allocate bitsets
        const n = self.index.count();
        self.alive = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, n);
        self.weak_alive = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, n);
    }

    /// Build method_overrides: for each class method, if a parent/interface/trait
    /// declares the same method name, record the override relationship.
    fn buildMethodOverrides(self: *ProjectLivenessGraph, sym: *const SymbolTable) !void {
        var class_it = sym.classes.iterator();
        while (class_it.next()) |entry| {
            const fqcn = entry.key_ptr.*;
            const class = entry.value_ptr;

            var method_it = class.methods.iterator();
            while (method_it.next()) |m| {
                const method_name = m.key_ptr.*;
                const child_fqn = try self.fmtStr("{s}::{s}", .{ fqcn, method_name });

                // Check parent chain
                for (class.parent_chain) |parent_fqcn| {
                    if (sym.classes.get(parent_fqcn)) |parent| {
                        if (parent.methods.contains(method_name)) {
                            const parent_fqn = try self.fmtStr("{s}::{s}", .{ parent_fqcn, method_name });
                            try HierarchyIndex.appendToList(&self.hierarchy.method_overrides, self.allocator, parent_fqn, child_fqn);
                        }
                    }
                }

                // Check implemented interfaces
                for (class.implements) |iface_fqcn| {
                    if (sym.interfaces.get(iface_fqcn)) |iface| {
                        if (iface.methods.contains(method_name)) {
                            const iface_method_fqn = try self.fmtStr("{s}::{s}", .{ iface_fqcn, method_name });
                            try HierarchyIndex.appendToList(&self.hierarchy.method_overrides, self.allocator, iface_method_fqn, child_fqn);
                        }
                    }
                }

                // Check used traits
                for (class.uses) |trait_fqcn| {
                    if (sym.traits.get(trait_fqcn)) |t| {
                        if (t.methods.contains(method_name)) {
                            const trait_method_fqn = try self.fmtStr("{s}::{s}", .{ trait_fqcn, method_name });
                            try HierarchyIndex.appendToList(&self.hierarchy.method_overrides, self.allocator, trait_method_fqn, child_fqn);
                        }
                    }
                }
            }
        }
    }

    // ====================================================================
    // Phase 2 — Seed: mark directly-referenced symbols as alive
    // ====================================================================

    pub fn seed(self: *ProjectLivenessGraph, refs: []const LivenessRef, sym: *const SymbolTable) !void {
        for (refs) |ref| {
            const target_fqn = ref.target_fqn;
            if (self.index.lookup(target_fqn)) |id| {
                if (ref.is_weak) {
                    self.weak_alive.set(id);
                } else {
                    self.alive.set(id);
                }
            }
        }

        // Seed magic methods on alive classes
        try self.seedMagicMethods(sym);
    }

    const magic_methods = [_][]const u8{
        "__construct",
        "__destruct",
        "__toString",
        "__invoke",
        "__clone",
    };

    fn seedMagicMethods(self: *ProjectLivenessGraph, sym: *const SymbolTable) !void {
        var class_it = sym.classes.iterator();
        while (class_it.next()) |entry| {
            const fqcn = entry.key_ptr.*;
            const class_id = self.index.lookup(fqcn) orelse continue;
            if (!self.isAlive(class_id)) continue;

            const class = entry.value_ptr;
            for (&magic_methods) |magic| {
                if (class.methods.contains(magic)) {
                    const mfqn = try self.fmtStr("{s}::{s}", .{ fqcn, magic });
                    if (self.index.lookup(mfqn)) |mid| {
                        self.alive.set(mid);
                    }
                }
            }
        }
    }

    // ====================================================================
    // Phase 3 — Propagate: queue-based fixed-point
    // ====================================================================

    pub fn propagate(self: *ProjectLivenessGraph, sym: *const SymbolTable) !void {
        var queue = std.ArrayListUnmanaged(SymbolId).empty;
        defer queue.deinit(self.allocator);

        // Seed the queue with everything currently alive
        const n = self.index.count();
        var i: SymbolId = 0;
        while (i < n) : (i += 1) {
            if (self.isAlive(i)) {
                try queue.append(self.allocator, i);
            }
        }

        while (queue.items.len > 0) {
            const id = queue.orderedRemove(0);
            const key = self.index.getKey(id);

            switch (key.kind) {
                .method, .property => {
                    // Alive member → owning class/trait alive
                    const owner_fqn = ownerFqn(key.fqn);
                    if (owner_fqn) |ofqn| {
                        try self.markAndEnqueue(ofqn, &queue);
                    }
                },
                .class => {
                    try self.propagateClass(key.fqn, sym, &queue);
                },
                .interface => {
                    // Alive interface → mark all its method declarations alive
                    if (sym.interfaces.get(key.fqn)) |iface| {
                        var method_it = iface.methods.iterator();
                        while (method_it.next()) |m| {
                            const mfqn = try self.fmtStr("{s}::{s}", .{ key.fqn, m.key_ptr.* });
                            try self.markAndEnqueue(mfqn, &queue);
                        }
                    }
                },
                .trait => {
                    // Alive trait → mark all trait users alive
                    if (self.hierarchy.trait_users.get(key.fqn)) |users| {
                        for (users.items) |user_fqcn| {
                            try self.markAndEnqueue(user_fqcn, &queue);
                        }
                    }
                },
                .function => {},
            }

            // If this is a method, propagate to overrides
            if (key.kind == .method) {
                try self.propagateMethodOverrides(key.fqn, &queue);
            }
        }
    }

    fn propagateClass(self: *ProjectLivenessGraph, fqcn: []const u8, sym: *const SymbolTable, queue: *std.ArrayListUnmanaged(SymbolId)) !void {
        const class = sym.classes.get(fqcn) orelse return;

        // Alive class → parent class alive
        if (class.extends) |parent_fqcn| {
            try self.markAndEnqueue(parent_fqcn, queue);
        }

        // Alive class → implemented interfaces alive
        for (class.implements) |iface_fqcn| {
            try self.markAndEnqueue(iface_fqcn, queue);
        }

        // Alive class → used traits alive
        for (class.uses) |trait_fqcn| {
            try self.markAndEnqueue(trait_fqcn, queue);
        }

        // Mark magic methods on this class as alive
        for (&magic_methods) |magic| {
            if (class.methods.contains(magic)) {
                const mfqn = try self.fmtStr("{s}::{s}", .{ fqcn, magic });
                try self.markAndEnqueue(mfqn, queue);
            }
        }
    }

    fn propagateMethodOverrides(self: *ProjectLivenessGraph, method_fqn: []const u8, queue: *std.ArrayListUnmanaged(SymbolId)) !void {
        // If an interface/abstract method is alive → all implementations alive
        if (self.hierarchy.method_overrides.get(method_fqn)) |overrides| {
            for (overrides.items) |override_fqn| {
                try self.markAndEnqueue(override_fqn, queue);
            }
        }
    }

    fn markAndEnqueue(self: *ProjectLivenessGraph, fqn: []const u8, queue: *std.ArrayListUnmanaged(SymbolId)) !void {
        const id = self.index.lookup(fqn) orelse return;
        if (!self.isAlive(id)) {
            self.alive.set(id);
            try queue.append(self.allocator, id);
        }
    }

    // ====================================================================
    // Phase 4 — Unresolved expansion
    // ====================================================================

    pub fn expandUnresolved(self: *ProjectLivenessGraph, refs: []const LivenessRef, sym: *const SymbolTable) !void {
        for (refs) |ref| {
            if (ref.reason != .unresolved_call) continue;

            switch (ref.target_kind) {
                .function => {
                    // Unresolved function call → all functions with matching short name
                    const short = shortName(ref.target_fqn);
                    if (self.index.functions_by_short_name.get(short)) |candidates| {
                        for (candidates.items) |fid| {
                            self.alive.set(fid);
                        }
                    }
                },
                .method => {
                    // Unresolved method call → all non-private methods with matching short name (weak)
                    const short = methodShortName(ref.target_fqn);
                    if (self.index.methods_by_short_name.get(short)) |candidates| {
                        for (candidates.items) |mid| {
                            const key = self.index.getKey(mid);
                            // Check if method is non-private
                            const method_vis = getMethodVisibility(key.fqn, sym);
                            if (method_vis != .private) {
                                self.weak_alive.set(mid);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Re-propagate: anything newly alive (strong or weak) propagates
        try self.propagate(sym);
    }

    // ====================================================================
    // Query API
    // ====================================================================

    pub fn isAlive(self: *const ProjectLivenessGraph, id: SymbolId) bool {
        return self.alive.isSet(id) or self.weak_alive.isSet(id);
    }

    pub fn isStronglyAlive(self: *const ProjectLivenessGraph, id: SymbolId) bool {
        return self.alive.isSet(id);
    }

    pub fn isWeaklyAlive(self: *const ProjectLivenessGraph, id: SymbolId) bool {
        return self.weak_alive.isSet(id) and !self.alive.isSet(id);
    }

    /// Collect all dead symbols.
    pub fn collectDead(self: *const ProjectLivenessGraph, sym: *const SymbolTable) ![]DeadSymbol {
        var result = std.ArrayListUnmanaged(DeadSymbol).empty;
        const n = self.index.count();
        var i: SymbolId = 0;
        while (i < n) : (i += 1) {
            if (!self.isAlive(i)) {
                const key = self.index.getKey(i);
                const info = resolveLocation(key, sym);
                try result.append(self.allocator, .{
                    .fqn = key.fqn,
                    .kind = key.kind,
                    .file_path = info.file_path,
                    .line = info.line,
                    .is_weak = false,
                });
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    // ====================================================================
    // Top-level: run all 4 phases
    // ====================================================================

    pub fn analyze(self: *ProjectLivenessGraph, sym: *const SymbolTable, refs: []const LivenessRef) !void {
        try self.buildIndex(sym);
        try self.seed(refs, sym);
        try self.propagate(sym);
        try self.expandUnresolved(refs, sym);
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    /// Extract the owning class/trait FQCN from "Class::method" or "Class::$prop".
    fn ownerFqn(fqn: []const u8) ?[]const u8 {
        const sep = std.mem.indexOf(u8, fqn, "::") orelse return null;
        return fqn[0..sep];
    }

    /// Extract short name from FQCN (after last backslash).
    fn shortName(fqn: []const u8) []const u8 {
        return if (std.mem.lastIndexOf(u8, fqn, "\\")) |sep| fqn[sep + 1 ..] else fqn;
    }

    /// Extract method short name from "Class::method" → "method".
    fn methodShortName(fqn: []const u8) []const u8 {
        return if (std.mem.indexOf(u8, fqn, "::")) |sep| fqn[sep + 2 ..] else fqn;
    }

    fn getMethodVisibility(method_fqn: []const u8, sym: *const SymbolTable) Visibility {
        const sep = std.mem.indexOf(u8, method_fqn, "::") orelse return .public;
        const class_fqcn = method_fqn[0..sep];
        const method_name = method_fqn[sep + 2 ..];

        if (sym.classes.get(class_fqcn)) |class| {
            if (class.methods.get(method_name)) |m| return m.visibility;
        }
        if (sym.interfaces.get(class_fqcn)) |iface| {
            if (iface.methods.get(method_name)) |m| return m.visibility;
        }
        if (sym.traits.get(class_fqcn)) |t| {
            if (t.methods.get(method_name)) |m| return m.visibility;
        }
        return .public;
    }

    const LocationInfo = struct { file_path: []const u8, line: u32 };

    fn resolveLocation(key: SymbolKey, sym: *const SymbolTable) LocationInfo {
        switch (key.kind) {
            .class => {
                if (sym.classes.get(key.fqn)) |c| return .{ .file_path = c.file_path, .line = c.start_line };
            },
            .interface => {
                if (sym.interfaces.get(key.fqn)) |i| return .{ .file_path = i.file_path, .line = i.start_line };
            },
            .trait => {
                if (sym.traits.get(key.fqn)) |t| return .{ .file_path = t.file_path, .line = t.start_line };
            },
            .function => {
                if (sym.functions.get(key.fqn)) |f| return .{ .file_path = f.file_path, .line = f.start_line };
            },
            .method => {
                const owner = ownerFqn(key.fqn) orelse return .{ .file_path = "", .line = 0 };
                const method_name = methodShortName(key.fqn);
                if (sym.classes.get(owner)) |c| {
                    if (c.methods.get(method_name)) |m| return .{ .file_path = m.file_path, .line = m.start_line };
                }
                if (sym.interfaces.get(owner)) |i| {
                    if (i.methods.get(method_name)) |m| return .{ .file_path = m.file_path, .line = m.start_line };
                }
                if (sym.traits.get(owner)) |t| {
                    if (t.methods.get(method_name)) |m| return .{ .file_path = m.file_path, .line = m.start_line };
                }
            },
            .property => {
                const owner = ownerFqn(key.fqn) orelse return .{ .file_path = "", .line = 0 };
                // Strip "$" prefix from property name after "::"
                const raw_name = key.fqn[(std.mem.indexOf(u8, key.fqn, "::") orelse return .{ .file_path = "", .line = 0 }) + 2 ..];
                const prop_name = if (raw_name.len > 0 and raw_name[0] == '$') raw_name[1..] else raw_name;
                if (sym.classes.get(owner)) |c| {
                    if (c.properties.get(prop_name)) |p| return .{ .file_path = c.file_path, .line = p.line };
                }
            },
        }
        return .{ .file_path = "", .line = 0 };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "basic liveness: referenced class is alive, unreferenced is dead" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class_a = ClassSymbol.init(allocator, "App\\UsedClass");
    class_a.file_path = "used.php";
    class_a.start_line = 5;
    try sym.addClass(class_a);

    var class_b = ClassSymbol.init(allocator, "App\\UnusedClass");
    class_b.file_path = "unused.php";
    class_b.start_line = 10;
    try sym.addClass(class_b);

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\UsedClass",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // UsedClass is alive
    const used_id = graph.index.lookup("App\\UsedClass").?;
    try std.testing.expect(graph.isAlive(used_id));

    // UnusedClass is dead
    const unused_id = graph.index.lookup("App\\UnusedClass").?;
    try std.testing.expect(!graph.isAlive(unused_id));
}

test "propagation: alive member makes owning class alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\Service");
    try class.addMethod(.{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 10,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Service",
        .file_path = "service.php",
    });
    try sym.addClass(class);
    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Service::handle",
        .target_kind = .method,
        .reason = .resolved_call,
        .is_weak = false,
        .source_file = "caller.php",
        .source_line = 5,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Method is alive
    const method_id = graph.index.lookup("App\\Service::handle").?;
    try std.testing.expect(graph.isAlive(method_id));

    // Owning class is alive (propagated)
    const class_id = graph.index.lookup("App\\Service").?;
    try std.testing.expect(graph.isAlive(class_id));
}

test "propagation: alive class makes parent and interfaces alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    const parent = ClassSymbol.init(allocator, "App\\Base");
    try sym.addClass(parent);

    const iface = InterfaceSymbol.init(allocator, "App\\Renderable");
    try sym.addInterface(iface);

    var child = ClassSymbol.init(allocator, "App\\Widget");
    child.extends = "App\\Base";
    child.implements = &.{"App\\Renderable"};
    try sym.addClass(child);

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Widget",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Widget").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Base").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Renderable").?));
}

test "propagation: alive interface method marks all implementations alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var iface = InterfaceSymbol.init(allocator, "App\\Handler");
    try iface.addMethod(.{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = true,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 1,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Handler",
        .file_path = "handler.php",
    });
    try sym.addInterface(iface);

    var impl = ClassSymbol.init(allocator, "App\\ConcreteHandler");
    impl.implements = &.{"App\\Handler"};
    try impl.addMethod(.{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 10,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\ConcreteHandler",
        .file_path = "concrete.php",
    });
    try sym.addClass(impl);

    try sym.resolveInheritance();

    // Reference the interface method
    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Handler::handle",
        .target_kind = .method,
        .reason = .resolved_call,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Interface method alive
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Handler::handle").?));
    // Implementation method alive (via override propagation)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\ConcreteHandler::handle").?));
    // Implementation class alive (via member→owner propagation)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\ConcreteHandler").?));
}

test "propagation: magic methods on alive classes are alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\Entity");
    try class.addMethod(.{
        .name = "__construct",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 5,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Entity",
        .file_path = "entity.php",
    });
    try class.addMethod(.{
        .name = "__toString",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 15,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Entity",
        .file_path = "entity.php",
    });
    try class.addMethod(.{
        .name = "normalMethod",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 25,
        .end_line = 30,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Entity",
        .file_path = "entity.php",
    });
    try sym.addClass(class);
    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Entity",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Magic methods alive
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Entity::__construct").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Entity::__toString").?));
    // Normal unreferenced method is dead
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Entity::normalMethod").?));
}

test "unresolved expansion: unresolved method call marks candidates as weak alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class_a = ClassSymbol.init(allocator, "App\\ServiceA");
    try class_a.addMethod(.{
        .name = "process",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 10,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\ServiceA",
        .file_path = "a.php",
    });
    try sym.addClass(class_a);

    var class_b = ClassSymbol.init(allocator, "App\\ServiceB");
    try class_b.addMethod(.{
        .name = "process",
        .visibility = .private,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 10,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\ServiceB",
        .file_path = "b.php",
    });
    try sym.addClass(class_b);
    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "process",
        .target_kind = .method,
        .reason = .unresolved_call,
        .is_weak = true,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Public method is weak-alive
    const a_id = graph.index.lookup("App\\ServiceA::process").?;
    try std.testing.expect(graph.isAlive(a_id));

    // Private method is NOT alive (unresolved calls don't reach private)
    const b_id = graph.index.lookup("App\\ServiceB::process").?;
    try std.testing.expect(!graph.isAlive(b_id));
}

test "hierarchy: alive class propagates to trait" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var t = TraitSymbol.init(allocator, "App\\Loggable");
    try t.addMethod(.{
        .name = "log",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 5,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Loggable",
        .file_path = "loggable.php",
    });
    try sym.addTrait(t);

    var class = ClassSymbol.init(allocator, "App\\UserService");
    class.uses = &.{"App\\Loggable"};
    try sym.addClass(class);
    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\UserService",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\UserService").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Loggable").?));
}

test "cycle handling: circular inheritance does not infinite loop" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class_a = ClassSymbol.init(allocator, "App\\CycleA");
    class_a.extends = "App\\CycleB";
    try sym.addClass(class_a);

    var class_b = ClassSymbol.init(allocator, "App\\CycleB");
    class_b.extends = "App\\CycleA";
    try sym.addClass(class_b);

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\CycleA",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Both should be alive (CycleA referenced, CycleB is parent of CycleA)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\CycleA").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\CycleB").?));
}

test "collectDead returns only dead symbols" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var alive_class = ClassSymbol.init(allocator, "App\\Alive");
    alive_class.file_path = "alive.php";
    alive_class.start_line = 3;
    try sym.addClass(alive_class);

    var dead_class = ClassSymbol.init(allocator, "App\\Dead");
    dead_class.file_path = "dead.php";
    dead_class.start_line = 7;
    try sym.addClass(dead_class);

    var dead_func: FunctionSymbol = .{
        .fqn = "App\\unusedFunc",
        .name = "unusedFunc",
        .namespace = "App",
        .file_path = "funcs.php",
        .start_line = 15,
        .end_line = 20,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
    };
    try sym.addFunction(dead_func);
    _ = &dead_func;

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Alive",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    const dead = try graph.collectDead(&sym);
    defer allocator.free(dead);

    // Should contain the dead class and dead function, but not the alive class
    try std.testing.expectEqual(@as(usize, 2), dead.len);

    var found_dead_class = false;
    var found_dead_func = false;
    for (dead) |d| {
        if (std.mem.eql(u8, d.fqn, "App\\Dead")) found_dead_class = true;
        if (std.mem.eql(u8, d.fqn, "App\\unusedFunc")) found_dead_func = true;
    }
    try std.testing.expect(found_dead_class);
    try std.testing.expect(found_dead_func);
}
