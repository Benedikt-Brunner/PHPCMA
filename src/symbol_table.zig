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

    // Inheritance resolution state
    inheritance_resolved: bool,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .classes = std.StringHashMap(ClassSymbol).init(allocator),
            .interfaces = std.StringHashMap(InterfaceSymbol).init(allocator),
            .traits = std.StringHashMap(TraitSymbol).init(allocator),
            .functions = std.StringHashMap(FunctionSymbol).init(allocator),
            .allocator = allocator,
            .inheritance_resolved = false,
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
        self.inheritance_resolved = false;
    }

    pub fn addInterface(self: *SymbolTable, iface: InterfaceSymbol) !void {
        try self.interfaces.put(iface.fqcn, iface);
        self.inheritance_resolved = false;
    }

    pub fn addTrait(self: *SymbolTable, trait: TraitSymbol) !void {
        try self.traits.put(trait.fqcn, trait);
        self.inheritance_resolved = false;
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
        if (self.classes.getPtr(class_fqcn)) |class| {
            // If inheritance is resolved, use all_methods
            if (self.inheritance_resolved) {
                return class.all_methods.get(method_name);
            }
            // Otherwise, just check direct methods
            if (class.methods.getPtr(method_name)) |m| {
                return m;
            }
        }
        return null;
    }

    /// Resolve a property access
    pub fn resolveProperty(self: *const SymbolTable, class_fqcn: []const u8, property_name: []const u8) ?*const PropertySymbol {
        if (self.classes.getPtr(class_fqcn)) |class| {
            if (self.inheritance_resolved) {
                return class.all_properties.get(property_name);
            }
            if (class.properties.getPtr(property_name)) |p| {
                return p;
            }
        }
        return null;
    }

    /// Check if a type exists (class, interface, or trait)
    pub fn typeExists(self: *const SymbolTable, fqcn: []const u8) bool {
        return self.classes.contains(fqcn) or
            self.interfaces.contains(fqcn) or
            self.traits.contains(fqcn);
    }

    // ========================================================================
    // Inheritance Resolution
    // ========================================================================

    /// Resolve all inheritance relationships
    /// This must be called after all symbols are collected
    pub fn resolveInheritance(self: *SymbolTable) !void {
        if (self.inheritance_resolved) return;

        // Get classes in topological order (parents before children)
        const sorted = try self.topologicalSortClasses();
        defer self.allocator.free(sorted);

        // Resolve each class in order
        for (sorted) |fqcn| {
            try self.resolveClassInheritance(fqcn);
        }

        self.inheritance_resolved = true;
    }

    /// Topologically sort classes so parents come before children
    fn topologicalSortClasses(self: *SymbolTable) ![]const []const u8 {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();
        var in_progress = std.StringHashMap(void).init(self.allocator);
        defer in_progress.deinit();

        var it = self.classes.keyIterator();
        while (it.next()) |fqcn| {
            try self.topologicalVisit(fqcn.*, &result, &visited, &in_progress);
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn topologicalVisit(
        self: *SymbolTable,
        fqcn: []const u8,
        result: *std.ArrayListUnmanaged([]const u8),
        visited: *std.StringHashMap(void),
        in_progress: *std.StringHashMap(void),
    ) !void {
        if (visited.contains(fqcn)) return;
        if (in_progress.contains(fqcn)) {
            // Cycle detected - just skip
            return;
        }

        try in_progress.put(fqcn, {});

        // Visit parent first
        if (self.classes.get(fqcn)) |class| {
            if (class.extends) |parent_fqcn| {
                try self.topologicalVisit(parent_fqcn, result, visited, in_progress);
            }
        }

        _ = in_progress.remove(fqcn);
        try visited.put(fqcn, {});
        try result.append(self.allocator, fqcn);
    }

    /// Resolve inheritance for a single class
    fn resolveClassInheritance(self: *SymbolTable, fqcn: []const u8) !void {
        const class = self.classes.getPtr(fqcn) orelse return;

        // Build parent chain (with cycle detection)
        var chain: std.ArrayListUnmanaged([]const u8) = .empty;
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        try seen.put(fqcn, {});
        var current_fqcn = class.extends;
        while (current_fqcn) |parent_fqcn| {
            if (seen.contains(parent_fqcn)) break; // Cycle detected
            try chain.append(self.allocator, parent_fqcn);
            try seen.put(parent_fqcn, {});
            if (self.classes.get(parent_fqcn)) |parent| {
                current_fqcn = parent.extends;
            } else {
                break;
            }
        }
        class.parent_chain = try chain.toOwnedSlice(self.allocator);

        // Copy parent methods and properties
        if (class.extends) |parent_fqcn| {
            if (self.classes.getPtr(parent_fqcn)) |parent| {
                // Copy parent's all_methods
                var method_it = parent.all_methods.iterator();
                while (method_it.next()) |entry| {
                    // Only copy if not overridden
                    if (!class.methods.contains(entry.key_ptr.*)) {
                        try class.all_methods.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }

                // Copy parent's all_properties
                var prop_it = parent.all_properties.iterator();
                while (prop_it.next()) |entry| {
                    if (!class.properties.contains(entry.key_ptr.*)) {
                        try class.all_properties.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }
        }

        // Apply traits
        for (class.uses) |trait_fqcn| {
            try self.applyTrait(class, trait_fqcn);
        }

        // Add own methods (override inherited)
        var own_method_it = class.methods.iterator();
        while (own_method_it.next()) |entry| {
            try class.all_methods.put(entry.key_ptr.*, entry.value_ptr);
        }

        // Add own properties
        var own_prop_it = class.properties.iterator();
        while (own_prop_it.next()) |entry| {
            try class.all_properties.put(entry.key_ptr.*, entry.value_ptr);
        }
    }

    /// Apply trait methods and properties to a class
    fn applyTrait(self: *SymbolTable, class: *ClassSymbol, trait_fqcn: []const u8) !void {
        const trait = self.traits.get(trait_fqcn) orelse return;

        // Copy trait methods (unless already defined)
        var method_it = trait.methods.iterator();
        while (method_it.next()) |entry| {
            if (!class.all_methods.contains(entry.key_ptr.*)) {
                try class.all_methods.put(entry.key_ptr.*, entry.value_ptr);
            }
        }

        // Copy trait properties
        var prop_it = trait.properties.iterator();
        while (prop_it.next()) |entry| {
            if (!class.all_properties.contains(entry.key_ptr.*)) {
                try class.all_properties.put(entry.key_ptr.*, entry.value_ptr);
            }
        }
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

    pub fn printStats(self: *const SymbolTable, file: std.fs.File) !void {
        const stats = self.getStats();
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;
        try writer.print(
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
        try writer.flush();
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

test "SymbolTable inheritance resolution - simple inheritance" {
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

    // Create child class with no own methods
    var child = ClassSymbol.init(allocator, "App\\UserService");
    child.extends = "App\\BaseService";
    try table.addClass(child);

    try table.resolveInheritance();

    // Child should have parent's method
    const method = table.resolveMethod("App\\UserService", "doSomething");
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("doSomething", method.?.name);
}

test "SymbolTable inheritance resolution - method override" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var parent = ClassSymbol.init(allocator, "App\\Base");
    try parent.addMethod(.{
        .name = "render",
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
        .containing_class = "App\\Base",
        .file_path = "base.php",
    });
    try table.addClass(parent);

    var child = ClassSymbol.init(allocator, "App\\Child");
    child.extends = "App\\Base";
    try child.addMethod(.{
        .name = "render",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 20,
        .end_line = 25,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\Child",
        .file_path = "child.php",
    });
    try table.addClass(child);

    try table.resolveInheritance();

    // Child's version should win (override)
    const method = table.resolveMethod("App\\Child", "render");
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("App\\Child", method.?.containing_class);
}

test "SymbolTable inheritance resolution - deep chain (A extends B extends C)" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // C (root ancestor) with method
    var class_c = ClassSymbol.init(allocator, "App\\C");
    try class_c.addMethod(.{
        .name = "baseMethod",
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
        .containing_class = "App\\C",
        .file_path = "",
    });
    try table.addClass(class_c);

    // B extends C
    var class_b = ClassSymbol.init(allocator, "App\\B");
    class_b.extends = "App\\C";
    try class_b.addMethod(.{
        .name = "middleMethod",
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
        .containing_class = "App\\B",
        .file_path = "",
    });
    try table.addClass(class_b);

    // A extends B
    var class_a = ClassSymbol.init(allocator, "App\\A");
    class_a.extends = "App\\B";
    try table.addClass(class_a);

    try table.resolveInheritance();

    // A should have both baseMethod (from C) and middleMethod (from B)
    try std.testing.expect(table.resolveMethod("App\\A", "baseMethod") != null);
    try std.testing.expect(table.resolveMethod("App\\A", "middleMethod") != null);

    // Verify parent chain for A
    const class_a_ptr = table.getClass("App\\A").?;
    try std.testing.expectEqual(@as(usize, 2), class_a_ptr.parent_chain.len);
}

test "SymbolTable inheritance resolution - diamond via traits" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Two traits with methods
    var trait_a = TraitSymbol.init(allocator, "App\\TraitA");
    try trait_a.addMethod(.{
        .name = "helperA",
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
        .containing_class = "App\\TraitA",
        .file_path = "",
    });
    try table.addTrait(trait_a);

    var trait_b = TraitSymbol.init(allocator, "App\\TraitB");
    try trait_b.addMethod(.{
        .name = "helperB",
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
        .containing_class = "App\\TraitB",
        .file_path = "",
    });
    try table.addTrait(trait_b);

    // Parent uses TraitA
    var parent = ClassSymbol.init(allocator, "App\\Parent");
    parent.uses = &.{"App\\TraitA"};
    try table.addClass(parent);

    // Child extends Parent, also uses TraitB
    var child = ClassSymbol.init(allocator, "App\\Child");
    child.extends = "App\\Parent";
    child.uses = &.{"App\\TraitB"};
    try table.addClass(child);

    try table.resolveInheritance();

    // Child should have both trait methods
    try std.testing.expect(table.resolveMethod("App\\Child", "helperA") != null);
    try std.testing.expect(table.resolveMethod("App\\Child", "helperB") != null);
}

test "SymbolTable inheritance resolution - trait method override" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Trait with a method
    var trait = TraitSymbol.init(allocator, "App\\MyTrait");
    try trait.addMethod(.{
        .name = "action",
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
        .containing_class = "App\\MyTrait",
        .file_path = "",
    });
    try table.addTrait(trait);

    // Class uses trait but overrides the method
    var class = ClassSymbol.init(allocator, "App\\MyClass");
    class.uses = &.{"App\\MyTrait"};
    try class.addMethod(.{
        .name = "action",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{},
        .return_type = null,
        .phpdoc_return = null,
        .start_line = 20,
        .end_line = 25,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "App\\MyClass",
        .file_path = "",
    });
    try table.addClass(class);

    try table.resolveInheritance();

    // Class's own method should win over trait method
    const method = table.resolveMethod("App\\MyClass", "action");
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("App\\MyClass", method.?.containing_class);
}

test "SymbolTable inheritance resolution - interface methods" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Interface with a method
    var iface = InterfaceSymbol.init(allocator, "App\\Renderable");
    try iface.addMethod(.{
        .name = "render",
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
        .containing_class = "App\\Renderable",
        .file_path = "",
    });
    try table.addInterface(iface);

    // Class implements interface
    var class = ClassSymbol.init(allocator, "App\\Widget");
    class.implements = &.{"App\\Renderable"};
    try class.addMethod(.{
        .name = "render",
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
        .containing_class = "App\\Widget",
        .file_path = "",
    });
    try table.addClass(class);

    try table.resolveInheritance();

    // Interface method should exist
    const iface_method = table.getInterface("App\\Renderable").?.methods.getPtr("render");
    try std.testing.expect(iface_method != null);

    // Class has its own implementation
    const class_method = table.resolveMethod("App\\Widget", "render");
    try std.testing.expect(class_method != null);
    try std.testing.expectEqualStrings("App\\Widget", class_method.?.containing_class);
}

test "SymbolTable inheritance resolution - cycle detection" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // A extends B, B extends A — circular inheritance
    var class_a = ClassSymbol.init(allocator, "App\\CycleA");
    class_a.extends = "App\\CycleB";
    try class_a.addMethod(.{
        .name = "methodA",
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
        .containing_class = "App\\CycleA",
        .file_path = "",
    });
    try table.addClass(class_a);

    var class_b = ClassSymbol.init(allocator, "App\\CycleB");
    class_b.extends = "App\\CycleA";
    try class_b.addMethod(.{
        .name = "methodB",
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
        .containing_class = "App\\CycleB",
        .file_path = "",
    });
    try table.addClass(class_b);

    // Should NOT crash — cycle is detected and skipped
    try table.resolveInheritance();

    // Both classes should still have their own methods
    try std.testing.expect(table.resolveMethod("App\\CycleA", "methodA") != null);
    try std.testing.expect(table.resolveMethod("App\\CycleB", "methodB") != null);
}

test "SymbolTable inheritance resolution - properties inherited" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var parent = ClassSymbol.init(allocator, "App\\BaseEntity");
    try parent.addProperty(.{
        .name = "id",
        .visibility = .protected,
        .is_static = false,
        .is_readonly = false,
        .declared_type = null,
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 5,
    });
    try parent.addProperty(.{
        .name = "createdAt",
        .visibility = .protected,
        .is_static = false,
        .is_readonly = false,
        .declared_type = null,
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 6,
    });
    try table.addClass(parent);

    var child = ClassSymbol.init(allocator, "App\\User");
    child.extends = "App\\BaseEntity";
    try child.addProperty(.{
        .name = "email",
        .visibility = .private,
        .is_static = false,
        .is_readonly = false,
        .declared_type = null,
        .phpdoc_type = null,
        .default_value_type = null,
        .line = 10,
    });
    try table.addClass(child);

    try table.resolveInheritance();

    // Child should have its own + inherited properties
    const user = table.getClass("App\\User").?;
    try std.testing.expect(user.all_properties.contains("id"));
    try std.testing.expect(user.all_properties.contains("createdAt"));
    try std.testing.expect(user.all_properties.contains("email"));
    try std.testing.expectEqual(@as(usize, 3), user.all_properties.count());
}

test "SymbolTable inheritance resolution - topological sort order" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Add classes in reverse order (child first, then parent)
    // to verify topological sort processes parents before children
    var child = ClassSymbol.init(allocator, "App\\Child");
    child.extends = "App\\Mid";
    try table.addClass(child);

    var mid = ClassSymbol.init(allocator, "App\\Mid");
    mid.extends = "App\\Root";
    try table.addClass(mid);

    var root = ClassSymbol.init(allocator, "App\\Root");
    try root.addMethod(.{
        .name = "rootMethod",
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
        .containing_class = "App\\Root",
        .file_path = "",
    });
    try table.addClass(root);

    try table.resolveInheritance();

    // Even though child was added first, topological sort should ensure
    // Root is resolved before Mid, Mid before Child
    try std.testing.expect(table.resolveMethod("App\\Child", "rootMethod") != null);
    try std.testing.expect(table.resolveMethod("App\\Mid", "rootMethod") != null);

    // Verify parent chain
    const child_ptr = table.getClass("App\\Child").?;
    try std.testing.expectEqual(@as(usize, 2), child_ptr.parent_chain.len);
}
