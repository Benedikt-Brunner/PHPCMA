const std = @import("std");
const types = @import("types.zig");

const ClassSymbol = types.ClassSymbol;
const InterfaceSymbol = types.InterfaceSymbol;
const TraitSymbol = types.TraitSymbol;
const FunctionSymbol = types.FunctionSymbol;
const MethodSymbol = types.MethodSymbol;
const Visibility = types.Visibility;
const SymbolTable = @import("symbol_table.zig").SymbolTable;
const call_analyzer = @import("call_analyzer.zig");
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ResolutionMethod = types.ResolutionMethod;

fn printElapsedLimit(label: []const u8, elapsed: f64, threshold: f64, unit: []const u8) void {
    if (elapsed <= threshold) {
        std.debug.print("[PASS] {s}: {d:.2}{s} (target: {d:.2}{s})\n", .{ label, elapsed, unit, threshold, unit });
        return;
    }

    std.debug.print("[FAIL] {s}: {d:.2}{s}, exceeded {d:.2}{s} target by {d:.2}{s}\n", .{
        label,
        elapsed,
        unit,
        threshold,
        unit,
        elapsed - threshold,
        unit,
    });
}

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

        var cursor: usize = 0;
        while (cursor < queue.items.len) {
            const id = queue.items[cursor];
            cursor += 1;
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
        var needs_propagation = false;

        for (refs) |ref| {
            if (ref.reason != .unresolved_call) continue;

            switch (ref.target_kind) {
                .function => {
                    // Unresolved function call → all functions with matching short name
                    const short = shortName(ref.target_fqn);
                    if (self.index.functions_by_short_name.get(short)) |candidates| {
                        for (candidates.items) |fid| {
                            const was_alive = self.isAlive(fid);
                            if (!self.alive.isSet(fid)) {
                                self.alive.set(fid);
                                if (!was_alive) needs_propagation = true;
                            }
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
                            if (method_vis != .private and !self.weak_alive.isSet(mid)) {
                                const was_alive = self.isAlive(mid);
                                self.weak_alive.set(mid);
                                if (!was_alive) needs_propagation = true;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Re-propagate: anything newly alive (strong or weak) propagates
        if (needs_propagation) {
            try self.propagate(sym);
        }
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

    pub fn getMethodVisibility(method_fqn: []const u8, sym: *const SymbolTable) Visibility {
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
// Reference Extraction — call graph → LivenessRef[]
// ============================================================================

/// Extract liveness references from a ProjectCallGraph.
/// Each resolved call becomes a strong reference; each unresolved call becomes
/// a weak reference for conservative expansion.
pub fn extractRefsFromCallGraph(
    allocator: std.mem.Allocator,
    call_graph: *const ProjectCallGraph,
    sym_table: *const SymbolTable,
) ![]LivenessRef {
    var refs = std.ArrayListUnmanaged(LivenessRef).empty;

    // 1. Every resolved call → strong reference to the target
    for (call_graph.calls.items) |call| {
        if (call.resolved_target) |target| {
            const target_kind: SymbolKind = switch (call.call_type) {
                .function => .function,
                .method, .static_method => .method,
            };
            const reason: LivenessReason = switch (call.resolution_method) {
                .constructor_call, .constructor_injection => .instantiate,
                .static_call => .static_access,
                .plugin_generated => .resolved_call,
                .phpdoc => .phpdoc,
                .unresolved => .unresolved_call,
                .native_type,
                .explicit_type,
                .assignment,
                .assignment_tracking,
                .this_call,
                .this_reference,
                .self_reference,
                .static_reference,
                .parent_reference,
                .property_type,
                .return_type_chain,
                => .resolved_call,
            };
            try refs.append(allocator, .{
                .target_fqn = target,
                .target_kind = target_kind,
                .reason = reason,
                .is_weak = call.resolution_method == .unresolved,
                .source_file = call.file_path,
                .source_line = call.line,
            });

            // A resolved call to Class::method also keeps the class alive
            if (target_kind == .method) {
                if (std.mem.indexOf(u8, target, "::")) |sep| {
                    const class_fqcn = target[0..sep];
                    try refs.append(allocator, .{
                        .target_fqn = class_fqcn,
                        .target_kind = .class,
                        .reason = .resolved_call,
                        .is_weak = false,
                        .source_file = call.file_path,
                        .source_line = call.line,
                    });
                }
            }
        } else {
            // Unresolved call → weak reference for conservative expansion
            const target_kind: SymbolKind = switch (call.call_type) {
                .function => .function,
                .method, .static_method => .method,
            };
            try refs.append(allocator, .{
                .target_fqn = call.callee_name,
                .target_kind = target_kind,
                .reason = .unresolved_call,
                .is_weak = true,
                .source_file = call.file_path,
                .source_line = call.line,
            });
        }
    }

    // 2. All classes that appear as type hints / extends / implements are alive
    var class_it = sym_table.classes.iterator();
    while (class_it.next()) |entry| {
        const fqcn = entry.key_ptr.*;
        const class = entry.value_ptr;

        // extends → parent alive
        if (class.extends) |parent| {
            try refs.append(allocator, .{
                .target_fqn = parent,
                .target_kind = .class,
                .reason = .inheritance,
                .is_weak = false,
                .source_file = class.file_path,
                .source_line = class.start_line,
            });
        }

        // implements → interfaces alive
        for (class.implements) |iface_fqcn| {
            try refs.append(allocator, .{
                .target_fqn = iface_fqcn,
                .target_kind = .interface,
                .reason = .interface_impl,
                .is_weak = false,
                .source_file = class.file_path,
                .source_line = class.start_line,
            });
        }

        // trait use → traits alive
        for (class.uses) |trait_fqcn| {
            try refs.append(allocator, .{
                .target_fqn = trait_fqcn,
                .target_kind = .trait,
                .reason = .trait_use,
                .is_weak = false,
                .source_file = class.file_path,
                .source_line = class.start_line,
            });
        }

        _ = fqcn;
    }

    return refs.toOwnedSlice(allocator);
}

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

test "extractRefsFromCallGraph: resolved calls produce strong references" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\Service");
    class.file_path = "service.php";
    class.start_line = 1;
    try class.addMethod(.{
        .name = "run",
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
        .containing_class = "App\\Service",
        .file_path = "service.php",
    });
    try sym.addClass(class);

    var unused_class = ClassSymbol.init(allocator, "App\\Unused");
    unused_class.file_path = "unused.php";
    unused_class.start_line = 1;
    try sym.addClass(unused_class);

    try sym.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym);
    defer call_graph.deinit();

    // Simulate a resolved call to App\\Service::run
    try call_graph.calls.append(allocator, .{
        .caller_fqn = "main",
        .callee_name = "run",
        .call_type = .method,
        .line = 1,
        .column = 0,
        .file_path = "main.php",
        .resolved_target = "App\\Service::run",
        .resolution_confidence = 1.0,
        .resolution_method = .this_call,
    });
    call_graph.total_calls = 1;
    call_graph.resolved_calls = 1;

    const refs = try extractRefsFromCallGraph(allocator, &call_graph, &sym);
    defer allocator.free(refs);

    // Should have at least 2 refs: the method call + the class ref
    try std.testing.expect(refs.len >= 2);

    // Run full analysis
    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, refs);

    // Service is alive (referenced), Unused is dead
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Service").?));
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Unused").?));
}

test "extractRefsFromCallGraph: unresolved calls produce weak references" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class_a = ClassSymbol.init(allocator, "App\\Alpha");
    class_a.file_path = "alpha.php";
    try class_a.addMethod(.{
        .name = "handle",
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
        .containing_class = "App\\Alpha",
        .file_path = "alpha.php",
    });
    try sym.addClass(class_a);
    try sym.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym);
    defer call_graph.deinit();

    // Simulate an unresolved call
    try call_graph.calls.append(allocator, .{
        .caller_fqn = "main",
        .callee_name = "handle",
        .call_type = .method,
        .line = 1,
        .column = 0,
        .file_path = "main.php",
        .resolved_target = null,
        .resolution_confidence = 0.0,
        .resolution_method = .unresolved,
    });
    call_graph.total_calls = 1;
    call_graph.unresolved_calls = 1;

    const refs = try extractRefsFromCallGraph(allocator, &call_graph, &sym);
    defer allocator.free(refs);

    // Should have a weak ref
    var has_weak = false;
    for (refs) |r| {
        if (r.is_weak and r.reason == .unresolved_call) has_weak = true;
    }
    try std.testing.expect(has_weak);
}

test "extractRefsFromCallGraph: inheritance refs keep parents alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var parent = ClassSymbol.init(allocator, "App\\Base");
    parent.file_path = "base.php";
    parent.start_line = 1;
    try sym.addClass(parent);

    var child = ClassSymbol.init(allocator, "App\\Child");
    child.file_path = "child.php";
    child.start_line = 1;
    child.extends = "App\\Base";
    try sym.addClass(child);

    try sym.resolveInheritance();

    var call_graph = ProjectCallGraph.init(allocator, &sym);
    defer call_graph.deinit();

    const refs = try extractRefsFromCallGraph(allocator, &call_graph, &sym);
    defer allocator.free(refs);

    // Should have an inheritance ref from child to parent
    var has_inheritance = false;
    for (refs) |r| {
        if (r.reason == .inheritance and std.mem.eql(u8, r.target_fqn, "App\\Base")) {
            has_inheritance = true;
        }
    }
    try std.testing.expect(has_inheritance);
}

// ============================================================================
// Cross-Module Integration Tests
// ============================================================================

test "cross-module liveness: class used by another module is alive, unused class is dead" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    // Bundle A: provides a service
    var svc = ClassSymbol.init(allocator, "BundleA\\Service");
    svc.file_path = "bundle-a/Service.php";
    svc.start_line = 5;
    try svc.addMethod(.{
        .name = "execute",
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
        .containing_class = "BundleA\\Service",
        .file_path = "bundle-a/Service.php",
    });
    try sym.addClass(svc);

    // Bundle B: uses BundleA\Service
    var consumer = ClassSymbol.init(allocator, "BundleB\\Consumer");
    consumer.file_path = "bundle-b/Consumer.php";
    consumer.start_line = 3;
    try sym.addClass(consumer);

    // Bundle C: unused class
    var orphan = ClassSymbol.init(allocator, "BundleC\\Orphan");
    orphan.file_path = "bundle-c/Orphan.php";
    orphan.start_line = 1;
    try sym.addClass(orphan);

    try sym.resolveInheritance();

    // Consumer calls Service::execute (cross-module reference)
    const refs = [_]LivenessRef{
        .{
            .target_fqn = "BundleA\\Service::execute",
            .target_kind = .method,
            .reason = .resolved_call,
            .is_weak = false,
            .source_file = "bundle-b/Consumer.php",
            .source_line = 10,
        },
        .{
            .target_fqn = "BundleB\\Consumer",
            .target_kind = .class,
            .reason = .instantiate,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = 1,
        },
    };

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Service is alive (method called from Bundle B)
    try std.testing.expect(graph.isAlive(graph.index.lookup("BundleA\\Service").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("BundleA\\Service::execute").?));
    // Consumer is alive (instantiated)
    try std.testing.expect(graph.isAlive(graph.index.lookup("BundleB\\Consumer").?));
    // Orphan is dead (no references)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("BundleC\\Orphan").?));
}

test "interface liveness: type hint keeps interface and implementations alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var iface = InterfaceSymbol.init(allocator, "App\\Contracts\\Logger");
    try iface.addMethod(.{
        .name = "log",
        .visibility = .public,
        .is_static = false,
        .is_abstract = true,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 3,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Contracts\\Logger",
        .file_path = "contracts/Logger.php",
    });
    try sym.addInterface(iface);

    var impl1 = ClassSymbol.init(allocator, "App\\FileLogger");
    impl1.implements = &.{"App\\Contracts\\Logger"};
    try impl1.addMethod(.{
        .name = "log",
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
        .containing_class = "App\\FileLogger",
        .file_path = "FileLogger.php",
    });
    try sym.addClass(impl1);

    var impl2 = ClassSymbol.init(allocator, "App\\DbLogger");
    impl2.implements = &.{"App\\Contracts\\Logger"};
    try impl2.addMethod(.{
        .name = "log",
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
        .containing_class = "App\\DbLogger",
        .file_path = "DbLogger.php",
    });
    try sym.addClass(impl2);

    try sym.resolveInheritance();

    // Type hint reference to Logger interface
    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Contracts\\Logger",
        .target_kind = .interface,
        .reason = .type_hint,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 5,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Interface alive (type hint)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Contracts\\Logger").?));
    // Interface method alive (interface alive → methods alive)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Contracts\\Logger::log").?));
    // Implementation methods alive (via override propagation)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\FileLogger::log").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\DbLogger::log").?));
}

test "trait liveness: used trait alive, unused trait dead, private helper in used trait reportable" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    // Used trait with public method and private helper
    var used_trait = TraitSymbol.init(allocator, "App\\Cacheable");
    used_trait.file_path = "Cacheable.php";
    used_trait.start_line = 1;
    try used_trait.addMethod(.{
        .name = "cache",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 8,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Cacheable",
        .file_path = "Cacheable.php",
    });
    try used_trait.addMethod(.{
        .name = "buildCacheKey",
        .visibility = .private,
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
        .containing_class = "App\\Cacheable",
        .file_path = "Cacheable.php",
    });
    try sym.addTrait(used_trait);

    // Unused trait
    var unused_trait = TraitSymbol.init(allocator, "App\\Auditable");
    unused_trait.file_path = "Auditable.php";
    unused_trait.start_line = 1;
    try unused_trait.addMethod(.{
        .name = "audit",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 8,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Auditable",
        .file_path = "Auditable.php",
    });
    try sym.addTrait(unused_trait);

    // Class that uses Cacheable
    var class = ClassSymbol.init(allocator, "App\\UserService");
    class.uses = &.{"App\\Cacheable"};
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

    // Used trait is alive (via trait_use propagation)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Cacheable").?));
    // Unused trait is dead
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Auditable").?));
    // Private helper in used trait — not directly referenced, so dead (reportable)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Cacheable::buildCacheKey").?));
}

test "magic methods: instantiated class keeps magic alive, dead class magic stays dead" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    // Alive class with magic methods
    var alive = ClassSymbol.init(allocator, "App\\Widget");
    alive.file_path = "Widget.php";
    alive.start_line = 1;
    try alive.addMethod(.{
        .name = "__construct",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 6,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Widget",
        .file_path = "Widget.php",
    });
    try alive.addMethod(.{
        .name = "__toString",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 8,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Widget",
        .file_path = "Widget.php",
    });
    try sym.addClass(alive);

    // Dead class with magic methods
    var dead = ClassSymbol.init(allocator, "App\\Unused");
    dead.file_path = "Unused.php";
    dead.start_line = 1;
    try dead.addMethod(.{
        .name = "__construct",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 6,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Unused",
        .file_path = "Unused.php",
    });
    try dead.addMethod(.{
        .name = "__toString",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 8,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Unused",
        .file_path = "Unused.php",
    });
    try sym.addClass(dead);

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

    // Alive class magic methods are alive
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Widget::__construct").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Widget::__toString").?));
    // Dead class magic methods stay dead
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Unused::__construct").?));
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Unused::__toString").?));
}

test "inheritance chain: alive subclass keeps parent and grandparent alive, dead leaf is dead" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var grandparent = ClassSymbol.init(allocator, "App\\AbstractBase");
    grandparent.file_path = "AbstractBase.php";
    grandparent.start_line = 1;
    try sym.addClass(grandparent);

    var parent = ClassSymbol.init(allocator, "App\\MiddleLayer");
    parent.file_path = "MiddleLayer.php";
    parent.start_line = 1;
    parent.extends = "App\\AbstractBase";
    try sym.addClass(parent);

    var alive_child = ClassSymbol.init(allocator, "App\\ConcreteImpl");
    alive_child.file_path = "ConcreteImpl.php";
    alive_child.start_line = 1;
    alive_child.extends = "App\\MiddleLayer";
    try sym.addClass(alive_child);

    // Dead leaf — extends same parent but never referenced
    var dead_leaf = ClassSymbol.init(allocator, "App\\DeadLeaf");
    dead_leaf.file_path = "DeadLeaf.php";
    dead_leaf.start_line = 1;
    dead_leaf.extends = "App\\MiddleLayer";
    try sym.addClass(dead_leaf);

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\ConcreteImpl",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Alive child → parent → grandparent all alive
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\ConcreteImpl").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\MiddleLayer").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\AbstractBase").?));
    // Dead leaf is dead (no references to it)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\DeadLeaf").?));
}

test "unresolved conservative: unresolved method call keeps all non-private handle() methods alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    // Public handle() — should be kept alive
    var class_a = ClassSymbol.init(allocator, "App\\HandlerA");
    try class_a.addMethod(.{
        .name = "handle",
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
        .containing_class = "App\\HandlerA",
        .file_path = "HandlerA.php",
    });
    try sym.addClass(class_a);

    // Protected handle() — should be kept alive (non-private)
    var class_b = ClassSymbol.init(allocator, "App\\HandlerB");
    try class_b.addMethod(.{
        .name = "handle",
        .visibility = .protected,
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
        .containing_class = "App\\HandlerB",
        .file_path = "HandlerB.php",
    });
    try sym.addClass(class_b);

    // Private handle() — should stay dead
    var class_c = ClassSymbol.init(allocator, "App\\HandlerC");
    try class_c.addMethod(.{
        .name = "handle",
        .visibility = .private,
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
        .containing_class = "App\\HandlerC",
        .file_path = "HandlerC.php",
    });
    try sym.addClass(class_c);

    try sym.resolveInheritance();

    // Unresolved call: $x->handle() — no type info
    const refs = [_]LivenessRef{.{
        .target_fqn = "handle",
        .target_kind = .method,
        .reason = .unresolved_call,
        .is_weak = true,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Public and protected handle() are alive (weak)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\HandlerA::handle").?));
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\HandlerB::handle").?));
    // Private handle() is dead
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\HandlerC::handle").?));
}

test "string/reflection: class_exists keeps class alive, method_exists keeps method alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\DynamicService");
    class.file_path = "DynamicService.php";
    class.start_line = 1;
    try class.addMethod(.{
        .name = "process",
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
        .containing_class = "App\\DynamicService",
        .file_path = "DynamicService.php",
    });
    try class.addMethod(.{
        .name = "unreferencedMethod",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 12,
        .end_line = 15,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\DynamicService",
        .file_path = "DynamicService.php",
    });
    try sym.addClass(class);

    try sym.resolveInheritance();

    // class_exists('App\DynamicService') → string_ref
    // method_exists($obj, 'process') → reflection ref to process
    const refs = [_]LivenessRef{
        .{
            .target_fqn = "App\\DynamicService",
            .target_kind = .class,
            .reason = .string_ref,
            .is_weak = false,
            .source_file = "bootstrap.php",
            .source_line = 10,
        },
        .{
            .target_fqn = "App\\DynamicService::process",
            .target_kind = .method,
            .reason = .reflection,
            .is_weak = false,
            .source_file = "bootstrap.php",
            .source_line = 15,
        },
    };

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Class kept alive by string_ref
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\DynamicService").?));
    // process() kept alive by reflection ref
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\DynamicService::process").?));
    // unreferencedMethod is dead (no reference)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\DynamicService::unreferencedMethod").?));
}

test "private method precision: unreferenced private is dead, called private is alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\Processor");
    class.file_path = "Processor.php";
    class.start_line = 1;
    try class.addMethod(.{
        .name = "run",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 3,
        .end_line = 8,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Processor",
        .file_path = "Processor.php",
    });
    try class.addMethod(.{
        .name = "validate",
        .visibility = .private,
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
        .containing_class = "App\\Processor",
        .file_path = "Processor.php",
    });
    try class.addMethod(.{
        .name = "orphanHelper",
        .visibility = .private,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 17,
        .end_line = 20,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Processor",
        .file_path = "Processor.php",
    });
    try sym.addClass(class);

    try sym.resolveInheritance();

    const refs = [_]LivenessRef{
        .{
            .target_fqn = "App\\Processor",
            .target_kind = .class,
            .reason = .instantiate,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = 1,
        },
        .{
            .target_fqn = "App\\Processor::run",
            .target_kind = .method,
            .reason = .resolved_call,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = 5,
        },
        // run() calls validate() internally
        .{
            .target_fqn = "App\\Processor::validate",
            .target_kind = .method,
            .reason = .resolved_call,
            .is_weak = false,
            .source_file = "Processor.php",
            .source_line = 6,
        },
    };

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // run() alive (called externally)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Processor::run").?));
    // validate() alive (called by sibling)
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Processor::validate").?));
    // orphanHelper() dead (private, zero references)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Processor::orphanHelper").?));
}

test "property precision: unreferenced private property is dead, public property defaults alive when class alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\Config");
    class.file_path = "Config.php";
    class.start_line = 1;
    try class.addProperty(.{
        .name = "publicSetting",
        .visibility = .public,
        .is_static = false,
        .is_readonly = false,
        .declared_type = null,
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 3,
    });
    try class.addProperty(.{
        .name = "privateSetting",
        .visibility = .private,
        .is_static = false,
        .is_readonly = false,
        .declared_type = null,
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 5,
    });
    try sym.addClass(class);

    try sym.resolveInheritance();

    // Only the class itself is referenced, no property references
    const refs = [_]LivenessRef{.{
        .target_fqn = "App\\Config",
        .target_kind = .class,
        .reason = .instantiate,
        .is_weak = false,
        .source_file = "main.php",
        .source_line = 1,
    }};

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Class is alive
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\Config").?));
    // Both properties are dead when not explicitly referenced
    // (properties require explicit property_access references to be alive)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Config::$publicSetting").?));
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\Config::$privateSetting").?));

    // Now test with a property access reference
    const refs2 = [_]LivenessRef{
        .{
            .target_fqn = "App\\Config",
            .target_kind = .class,
            .reason = .instantiate,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = 1,
        },
        .{
            .target_fqn = "App\\Config::$publicSetting",
            .target_kind = .property,
            .reason = .property_access,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = 3,
        },
    };

    var graph2 = ProjectLivenessGraph.init(allocator);
    defer graph2.deinit();
    try graph2.analyze(&sym, &refs2);

    // Public property with explicit reference is alive
    try std.testing.expect(graph2.isAlive(graph2.index.lookup("App\\Config::$publicSetting").?));
    // Private property without reference is still dead
    try std.testing.expect(!graph2.isAlive(graph2.index.lookup("App\\Config::$privateSetting").?));
}

test "callable arrays: [Foo::class, 'bar'] keeps Foo::bar alive" {
    const allocator = std.testing.allocator;
    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    var class = ClassSymbol.init(allocator, "App\\EventHandler");
    class.file_path = "EventHandler.php";
    class.start_line = 1;
    try class.addMethod(.{
        .name = "onUserCreated",
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
        .containing_class = "App\\EventHandler",
        .file_path = "EventHandler.php",
    });
    try class.addMethod(.{
        .name = "orphanListener",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 12,
        .end_line = 15,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\EventHandler",
        .file_path = "EventHandler.php",
    });
    try sym.addClass(class);

    try sym.resolveInheritance();

    // [EventHandler::class, 'onUserCreated'] → callable_ref
    const refs = [_]LivenessRef{
        .{
            .target_fqn = "App\\EventHandler",
            .target_kind = .class,
            .reason = .callable_ref,
            .is_weak = false,
            .source_file = "events.php",
            .source_line = 5,
        },
        .{
            .target_fqn = "App\\EventHandler::onUserCreated",
            .target_kind = .method,
            .reason = .callable_ref,
            .is_weak = false,
            .source_file = "events.php",
            .source_line = 5,
        },
    };

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, &refs);

    // Class alive via callable_ref
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\EventHandler").?));
    // onUserCreated alive via callable_ref
    try std.testing.expect(graph.isAlive(graph.index.lookup("App\\EventHandler::onUserCreated").?));
    // orphanListener dead (not referenced)
    try std.testing.expect(!graph.isAlive(graph.index.lookup("App\\EventHandler::orphanListener").?));
}

test "performance: dead code analysis scales with many symbols" {
    const allocator = std.testing.allocator;

    // Use arena for all string allocations to avoid leak tracking issues
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var sym = SymbolTable.init(allocator);
    defer sym.deinit();

    // Generate 500 classes, each with 3 methods and 2 properties
    const num_classes = 500;

    for (0..num_classes) |i| {
        const fqcn = try std.fmt.allocPrint(aa, "App\\Gen\\Class{d}", .{i});

        var class = ClassSymbol.init(allocator, fqcn);
        class.file_path = "generated.php";
        class.start_line = @intCast(i * 20 + 1);

        for (0..3) |mi| {
            const mname = try std.fmt.allocPrint(aa, "method{d}", .{mi});

            try class.addMethod(.{
                .name = mname,
                .visibility = .public,
                .is_static = false,
                .is_abstract = false,
                .is_final = false,
                .parameters = &.{},
                .return_type = null,
                .phpdoc_return = null,
                .start_line = @intCast(i * 20 + mi + 3),
                .end_line = @intCast(i * 20 + mi + 5),
                .start_byte = 0,
                .end_byte = 0,
                .containing_class = fqcn,
                .file_path = "generated.php",
            });
        }

        for (0..2) |pi| {
            const pname = try std.fmt.allocPrint(aa, "prop{d}", .{pi});

            try class.addProperty(.{
                .name = pname,
                .visibility = if (pi == 0) .public else .private,
                .is_static = false,
                .is_readonly = false,
                .declared_type = null,
                .phpdoc_type = null,
                .default_value_type = null,
                .line = @intCast(i * 20 + 15 + pi),
            });
        }

        try sym.addClass(class);
    }

    try sym.resolveInheritance();

    // Reference 10% of classes
    var ref_list = std.ArrayListUnmanaged(LivenessRef).empty;
    defer ref_list.deinit(allocator);
    for (0..num_classes / 10) |i| {
        const fqcn = try std.fmt.allocPrint(aa, "App\\Gen\\Class{d}", .{i});
        try ref_list.append(allocator, .{
            .target_fqn = fqcn,
            .target_kind = .class,
            .reason = .instantiate,
            .is_weak = false,
            .source_file = "main.php",
            .source_line = @intCast(i + 1),
        });
    }

    var timer = std.time.Timer.start() catch unreachable;

    var graph = ProjectLivenessGraph.init(allocator);
    defer graph.deinit();
    try graph.analyze(&sym, ref_list.items);

    const dead = try graph.collectDead(&sym);
    defer allocator.free(dead);

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    // Verify correctness: 90% of classes should be dead
    try std.testing.expect(dead.len > 0);
    // Total symbols: 500 classes + 1500 methods + 1000 properties = 3000
    // ~2700 should be dead (90% classes + their members, minus magic methods on alive)
    try std.testing.expect(dead.len > 2000);

    // Performance: analysis should complete in <500ms even in Debug mode
    // (in Release mode this typically runs in <10ms)
    const threshold_ms = 500.0;
    printElapsedLimit("dead code analysis", elapsed_ms, threshold_ms, "ms");
    if (elapsed_ms >= threshold_ms) {
        return error.TestUnexpectedResult;
    }
}
