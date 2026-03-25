const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const main_mod = @import("main.zig");
const json_util = @import("json_util.zig");

const SymbolTable = symbol_table.SymbolTable;
const FileContext = types.FileContext;
const TypeInfo = types.TypeInfo;
const Visibility = types.Visibility;

const max_file_size = 10 * 1024 * 1024;

extern fn tree_sitter_php() callconv(.c) *ts.Language;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file_paths = parseArgs(allocator) catch |err| {
        printUsage();
        return err;
    };

    if (file_paths.len == 0) {
        printUsage();
        return error.InvalidArguments;
    }

    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    const parser = ts.Parser.create();
    defer parser.destroy();

    const php_lang = tree_sitter_php();
    try parser.setLanguage(php_lang);

    for (file_paths) |file_path| {
        const source = std.fs.cwd().readFileAlloc(allocator, file_path, max_file_size) catch |err| {
            std.log.warn("failed to read {s}: {}", .{ file_path, err });
            continue;
        };
        defer allocator.free(source);

        const tree = parser.parseString(source, null) orelse {
            std.log.warn("failed to parse {s}", .{file_path});
            continue;
        };
        defer tree.destroy();

        var file_ctx = FileContext.init(allocator, file_path);
        defer file_ctx.deinit();

        main_mod.collectSymbolsFromSource(allocator, &sym_table, &file_ctx, source, php_lang, tree) catch |err| {
            std.log.warn("symbol collection failed for {s}: {}", .{ file_path, err });
            continue;
        };
    }

    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout.writer(&buf);
    const writer = &w.interface;

    try writeSymbolTableJson(allocator, writer, &sym_table);
    try writer.flush();
}

fn printUsage() void {
    std.debug.print(
        "Usage: phpcma-symbol-dump [--file-list <path>] <file1.php> [file2.php ...]\n" ++
            "Outputs PHPCMA symbol tables as JSON for differential comparison.\n",
        .{},
    );
}

fn parseArgs(allocator: std.mem.Allocator) ![]const []const u8 {
    const args = try std.process.argsAlloc(allocator);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--file-list")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            try appendFilesFromList(allocator, args[i], &files);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--file-list=")) {
            const list_path = arg["--file-list=".len..];
            try appendFilesFromList(allocator, list_path, &files);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidArguments;
        }

        try files.append(allocator, try allocator.dupe(u8, arg));
    }

    return files.toOwnedSlice(allocator);
}

fn appendFilesFromList(
    allocator: std.mem.Allocator,
    list_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, list_path, max_file_size);
    defer allocator.free(content);

    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        try files.append(allocator, try allocator.dupe(u8, trimmed));
    }
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortedMapKeys(allocator: std.mem.Allocator, map: anytype) ![]const []const u8 {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = map.keyIterator();
    while (it.next()) |key| {
        try keys.append(allocator, key.*);
    }

    const owned = try keys.toOwnedSlice(allocator);
    std.sort.heap([]const u8, owned, {}, lessThanStrings);
    return owned;
}

fn visibilityToString(v: Visibility) []const u8 {
    return switch (v) {
        .public => "public",
        .protected => "protected",
        .private => "private",
    };
}

fn formatType(allocator: std.mem.Allocator, type_info: ?TypeInfo) !?[]const u8 {
    if (type_info) |ti| {
        var copy = ti;
        return try copy.format(allocator);
    }
    return null;
}

fn writeKey(writer: anytype, key: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeAll(": ");
}

const writeJsonString = json_util.writeJsonString;

fn writeJsonBool(writer: anytype, value: bool) !void {
    if (value) {
        try writer.writeAll("true");
    } else {
        try writer.writeAll("false");
    }
}

fn writeOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |str| {
        try writeJsonString(writer, str);
    } else {
        try writer.writeAll("null");
    }
}

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}

fn writeParametersJson(allocator: std.mem.Allocator, writer: anytype, params: []const types.ParameterInfo) !void {
    try writer.writeByte('[');
    for (params, 0..) |param, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeByte('{');

        try writeKey(writer, "name");
        try writeJsonString(writer, param.name);
        try writer.writeAll(", ");

        try writeKey(writer, "type");
        try writeOptionalString(writer, try formatType(allocator, param.type_info));
        try writer.writeAll(", ");

        try writeKey(writer, "has_default");
        try writeJsonBool(writer, param.has_default);
        try writer.writeAll(", ");

        try writeKey(writer, "is_variadic");
        try writeJsonBool(writer, param.is_variadic);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeMethodsJson(allocator: std.mem.Allocator, writer: anytype, methods: anytype) !void {
    const method_names = try sortedMapKeys(allocator, methods);

    try writer.writeByte('[');
    for (method_names, 0..) |method_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const method = methods.get(method_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "name");
        try writeJsonString(writer, method.name);
        try writer.writeAll(", ");

        try writeKey(writer, "visibility");
        try writeJsonString(writer, visibilityToString(method.visibility));
        try writer.writeAll(", ");

        try writeKey(writer, "is_static");
        try writeJsonBool(writer, method.is_static);
        try writer.writeAll(", ");

        try writeKey(writer, "is_abstract");
        try writeJsonBool(writer, method.is_abstract);
        try writer.writeAll(", ");

        try writeKey(writer, "return_type");
        try writeOptionalString(writer, try formatType(allocator, method.return_type));
        try writer.writeAll(", ");

        try writeKey(writer, "params");
        try writeParametersJson(allocator, writer, method.parameters);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writePropertiesJson(allocator: std.mem.Allocator, writer: anytype, properties: anytype) !void {
    const property_names = try sortedMapKeys(allocator, properties);

    try writer.writeByte('[');
    for (property_names, 0..) |property_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const property = properties.get(property_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "name");
        try writeJsonString(writer, property.name);
        try writer.writeAll(", ");

        try writeKey(writer, "visibility");
        try writeJsonString(writer, visibilityToString(property.visibility));
        try writer.writeAll(", ");

        try writeKey(writer, "type");
        try writeOptionalString(writer, try formatType(allocator, property.declared_type));
        try writer.writeAll(", ");

        try writeKey(writer, "is_static");
        try writeJsonBool(writer, property.is_static);
        try writer.writeAll(", ");

        try writeKey(writer, "is_readonly");
        try writeJsonBool(writer, property.is_readonly);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeClassesJson(allocator: std.mem.Allocator, writer: anytype, sym_table: *const SymbolTable) !void {
    const class_names = try sortedMapKeys(allocator, sym_table.classes);

    try writer.writeByte('[');
    for (class_names, 0..) |class_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const class = sym_table.classes.get(class_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "fqcn");
        try writeJsonString(writer, class.fqcn);
        try writer.writeAll(", ");

        try writeKey(writer, "file");
        try writeJsonString(writer, class.file_path);
        try writer.writeAll(", ");

        try writeKey(writer, "is_abstract");
        try writeJsonBool(writer, class.is_abstract);
        try writer.writeAll(", ");

        try writeKey(writer, "is_final");
        try writeJsonBool(writer, class.is_final);
        try writer.writeAll(", ");

        try writeKey(writer, "extends");
        try writeOptionalString(writer, class.extends);
        try writer.writeAll(", ");

        try writeKey(writer, "implements");
        try writeStringArray(writer, class.implements);
        try writer.writeAll(", ");

        try writeKey(writer, "methods");
        try writeMethodsJson(allocator, writer, class.methods);
        try writer.writeAll(", ");

        try writeKey(writer, "properties");
        try writePropertiesJson(allocator, writer, class.properties);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeInterfacesJson(allocator: std.mem.Allocator, writer: anytype, sym_table: *const SymbolTable) !void {
    const interface_names = try sortedMapKeys(allocator, sym_table.interfaces);

    try writer.writeByte('[');
    for (interface_names, 0..) |interface_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const iface = sym_table.interfaces.get(interface_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "fqcn");
        try writeJsonString(writer, iface.fqcn);
        try writer.writeAll(", ");

        try writeKey(writer, "file");
        try writeJsonString(writer, iface.file_path);
        try writer.writeAll(", ");

        try writeKey(writer, "methods");
        try writeMethodsJson(allocator, writer, iface.methods);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeTraitsJson(allocator: std.mem.Allocator, writer: anytype, sym_table: *const SymbolTable) !void {
    const trait_names = try sortedMapKeys(allocator, sym_table.traits);

    try writer.writeByte('[');
    for (trait_names, 0..) |trait_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const trait = sym_table.traits.get(trait_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "fqcn");
        try writeJsonString(writer, trait.fqcn);
        try writer.writeAll(", ");

        try writeKey(writer, "file");
        try writeJsonString(writer, trait.file_path);
        try writer.writeAll(", ");

        try writeKey(writer, "methods");
        try writeMethodsJson(allocator, writer, trait.methods);
        try writer.writeAll(", ");

        try writeKey(writer, "properties");
        try writePropertiesJson(allocator, writer, trait.properties);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeFunctionsJson(allocator: std.mem.Allocator, writer: anytype, sym_table: *const SymbolTable) !void {
    const function_names = try sortedMapKeys(allocator, sym_table.functions);

    try writer.writeByte('[');
    for (function_names, 0..) |function_name, i| {
        if (i > 0) try writer.writeAll(", ");
        const func = sym_table.functions.get(function_name).?;

        try writer.writeByte('{');

        try writeKey(writer, "name");
        try writeJsonString(writer, func.name);
        try writer.writeAll(", ");

        try writeKey(writer, "fqn");
        try writeJsonString(writer, func.fqn);
        try writer.writeAll(", ");

        try writeKey(writer, "file");
        try writeJsonString(writer, func.file_path);
        try writer.writeAll(", ");

        try writeKey(writer, "return_type");
        try writeOptionalString(writer, try formatType(allocator, func.return_type));
        try writer.writeAll(", ");

        try writeKey(writer, "params");
        try writeParametersJson(allocator, writer, func.parameters);

        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeSymbolTableJson(allocator: std.mem.Allocator, writer: anytype, sym_table: *const SymbolTable) !void {
    try writer.writeAll("{\n  ");
    try writeKey(writer, "classes");
    try writeClassesJson(allocator, writer, sym_table);
    try writer.writeAll(",\n  ");
    try writeKey(writer, "interfaces");
    try writeInterfacesJson(allocator, writer, sym_table);
    try writer.writeAll(",\n  ");
    try writeKey(writer, "traits");
    try writeTraitsJson(allocator, writer, sym_table);
    try writer.writeAll(",\n  ");
    try writeKey(writer, "functions");
    try writeFunctionsJson(allocator, writer, sym_table);
    try writer.writeAll("\n}\n");
}
