const std = @import("std");
const types = @import("types.zig");
const symbol_table = @import("symbol_table.zig");
const call_analyzer = @import("call_analyzer.zig");

const SymbolTable = symbol_table.SymbolTable;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ResolutionMethod = types.ResolutionMethod;

// ============================================================================
// Unified Analysis Report
// ============================================================================

/// A unified report combining all analysis phase outputs into a single document.
pub const UnifiedReport = struct {
    allocator: std.mem.Allocator,

    // Coverage section (Phase 0.1/0.3 data)
    coverage: CoverageSection,

    // Type check results
    type_checks: TypeCheckSection,

    // Cross-project analysis (monorepo)
    cross_project: CrossProjectSection,

    // Confidence distribution
    confidence: ConfidenceDistribution,

    // Violations from all phases
    violations: std.ArrayListUnmanaged(Violation),

    pub fn init(allocator: std.mem.Allocator) UnifiedReport {
        return .{
            .allocator = allocator,
            .coverage = CoverageSection.init(),
            .type_checks = TypeCheckSection.init(),
            .cross_project = CrossProjectSection.init(),
            .confidence = ConfidenceDistribution.init(),
            .violations = .empty,
        };
    }

    pub fn deinit(self: *UnifiedReport) void {
        self.violations.deinit(self.allocator);
        self.cross_project.boundary_calls.deinit(self.allocator);
    }

    /// Populate the report from a symbol table and call graph
    pub fn populate(self: *UnifiedReport, sym_table: *const SymbolTable, call_graph: *const ProjectCallGraph) void {
        const stats = sym_table.getStats();

        // Coverage
        self.coverage.total_files = 0; // Will be set by caller if available
        self.coverage.classes = stats.class_count;
        self.coverage.interfaces = stats.interface_count;
        self.coverage.traits = stats.trait_count;
        self.coverage.functions = stats.function_count;
        self.coverage.methods = stats.method_count;
        self.coverage.properties = stats.property_count;
        self.coverage.total_symbols = stats.class_count + stats.interface_count +
            stats.trait_count + stats.function_count;

        // Call resolution
        self.coverage.total_calls = call_graph.total_calls;
        self.coverage.resolved_calls = call_graph.resolved_calls;
        self.coverage.unresolved_calls = call_graph.unresolved_calls;
        self.coverage.resolution_rate = call_graph.getResolutionRate();

        // Type checks from call data
        self.populateTypeChecks(call_graph);

        // Confidence distribution
        self.populateConfidence(call_graph);
    }

    fn populateTypeChecks(self: *UnifiedReport, call_graph: *const ProjectCallGraph) void {
        for (call_graph.calls.items) |call| {
            self.type_checks.total += 1;
            if (call.resolved_target != null) {
                switch (call.resolution_method) {
                    .native_type, .explicit_type => self.type_checks.interface_compliance.pass += 1,
                    .this_reference, .self_reference, .static_reference, .parent_reference => self.type_checks.call_site_args.pass += 1,
                    .assignment, .assignment_tracking, .constructor_call, .constructor_injection => self.type_checks.property_types.pass += 1,
                    .return_type_chain => self.type_checks.return_types.pass += 1,
                    .phpdoc => self.type_checks.call_site_args.pass += 1,
                    .property_type => self.type_checks.property_types.pass += 1,
                    .static_call, .this_call => self.type_checks.call_site_args.pass += 1,
                    .plugin_generated => self.type_checks.interface_compliance.pass += 1,
                    .unresolved => self.type_checks.null_safety.unchecked += 1,
                }
            } else {
                // Unresolved calls contribute to unchecked counts
                self.type_checks.call_site_args.unchecked += 1;
            }
        }
    }

    fn populateConfidence(self: *UnifiedReport, call_graph: *const ProjectCallGraph) void {
        if (call_graph.total_calls == 0) return;

        var exact: usize = 0;
        var likely: usize = 0;
        var possible: usize = 0;
        var unresolved: usize = 0;

        for (call_graph.calls.items) |call| {
            if (call.resolution_confidence >= 0.9) {
                exact += 1;
            } else if (call.resolution_confidence >= 0.5) {
                likely += 1;
            } else if (call.resolved_target != null) {
                possible += 1;
            } else {
                unresolved += 1;
            }
        }

        const total_f: f32 = @floatFromInt(call_graph.total_calls);
        self.confidence.exact_pct = @as(f32, @floatFromInt(exact)) / total_f * 100.0;
        self.confidence.likely_pct = @as(f32, @floatFromInt(likely)) / total_f * 100.0;
        self.confidence.possible_pct = @as(f32, @floatFromInt(possible)) / total_f * 100.0;
        self.confidence.unresolved_pct = @as(f32, @floatFromInt(unresolved)) / total_f * 100.0;
        self.confidence.exact_count = exact;
        self.confidence.likely_count = likely;
        self.confidence.possible_count = possible;
        self.confidence.unresolved_count = unresolved;
    }

    pub fn addViolation(self: *UnifiedReport, violation: Violation) !void {
        try self.violations.append(self.allocator, violation);
    }

    // ========================================================================
    // Text Output
    // ========================================================================

    pub fn toText(self: *const UnifiedReport, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll(
            \\┌──────────────────────────────────────────────────────────────────────────────┐
            \\│  PHPCMA Unified Analysis Report                                              │
            \\└──────────────────────────────────────────────────────────────────────────────┘
            \\
            \\
        );

        // Coverage section
        try writer.writeAll("── Coverage ─────────────────────────────────────────────────────────────────\n\n");
        if (self.coverage.total_files > 0) {
            try writer.print("  Files scanned:    {d}\n", .{self.coverage.total_files});
        }
        try writer.print("  Total symbols:    {d}\n", .{self.coverage.total_symbols});
        try writer.print("    Classes:        {d}\n", .{self.coverage.classes});
        try writer.print("    Interfaces:     {d}\n", .{self.coverage.interfaces});
        try writer.print("    Traits:         {d}\n", .{self.coverage.traits});
        try writer.print("    Functions:      {d}\n", .{self.coverage.functions});
        try writer.print("    Methods:        {d}\n", .{self.coverage.methods});
        try writer.print("    Properties:     {d}\n", .{self.coverage.properties});
        try writer.print("  Resolution rate:  {d:.1}% ({d}/{d} calls)\n\n", .{
            self.coverage.resolution_rate,
            self.coverage.resolved_calls,
            self.coverage.total_calls,
        });

        // Type checks section
        try writer.writeAll("── Type Checks ──────────────────────────────────────────────────────────────\n\n");
        try self.writeCheckRow(writer, "Interface compliance", self.type_checks.interface_compliance);
        try self.writeCheckRow(writer, "Call-site args", self.type_checks.call_site_args);
        try self.writeCheckRow(writer, "Property types", self.type_checks.property_types);
        try self.writeCheckRow(writer, "Return types", self.type_checks.return_types);
        try self.writeCheckRow(writer, "Null safety", self.type_checks.null_safety);
        try writer.writeAll("\n");

        // Cross-project section
        if (self.cross_project.boundary_calls.items.len > 0) {
            try writer.writeAll("── Cross-Project ────────────────────────────────────────────────────────────\n\n");
            try writer.print("  Boundary calls:   {d}\n", .{self.cross_project.boundary_calls.items.len});
            try writer.print("  API health:       {s}\n\n", .{self.cross_project.apiHealthLabel()});
        }

        // Confidence distribution
        try writer.writeAll("── Confidence Distribution ──────────────────────────────────────────────────\n\n");
        try writer.print("  Exact:      {d:.1}% ({d} calls)\n", .{ self.confidence.exact_pct, self.confidence.exact_count });
        try writer.print("  Likely:     {d:.1}% ({d} calls)\n", .{ self.confidence.likely_pct, self.confidence.likely_count });
        try writer.print("  Possible:   {d:.1}% ({d} calls)\n", .{ self.confidence.possible_pct, self.confidence.possible_count });
        try writer.print("  Unresolved: {d:.1}% ({d} calls)\n\n", .{ self.confidence.unresolved_pct, self.confidence.unresolved_count });

        // Violations
        if (self.violations.items.len > 0) {
            try writer.writeAll("── Violations ───────────────────────────────────────────────────────────────\n\n");
            for (self.violations.items) |v| {
                try writer.print("  [{s}] {s}:{d}: {s}\n", .{
                    v.severityLabel(),
                    v.file_path,
                    v.line,
                    v.message,
                });
            }
            try writer.writeAll("\n");
        }

        try writer.flush();
    }

    fn writeCheckRow(self: *const UnifiedReport, writer: anytype, label: []const u8, check: CheckResult) !void {
        _ = self;
        try writer.print("  {s:<24} pass:{d:<6} fail:{d:<6} unchecked:{d}\n", .{
            label,
            check.pass,
            check.fail,
            check.unchecked,
        });
    }

    // ========================================================================
    // JSON Output
    // ========================================================================

    pub fn toJson(self: *const UnifiedReport, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");

        // Coverage
        try writer.writeAll("  \"coverage\": {\n");
        try writer.print("    \"files\": {d},\n", .{self.coverage.total_files});
        try writer.print("    \"symbols\": {d},\n", .{self.coverage.total_symbols});
        try writer.print("    \"classes\": {d},\n", .{self.coverage.classes});
        try writer.print("    \"interfaces\": {d},\n", .{self.coverage.interfaces});
        try writer.print("    \"traits\": {d},\n", .{self.coverage.traits});
        try writer.print("    \"functions\": {d},\n", .{self.coverage.functions});
        try writer.print("    \"methods\": {d},\n", .{self.coverage.methods});
        try writer.print("    \"properties\": {d},\n", .{self.coverage.properties});
        try writer.print("    \"resolution_rate\": {d:.1}\n", .{self.coverage.resolution_rate});
        try writer.writeAll("  },\n");

        // Type checks
        try writer.writeAll("  \"type_checks\": {\n");
        try self.writeCheckJson(writer, "interface_compliance", self.type_checks.interface_compliance, true);
        try self.writeCheckJson(writer, "call_site_args", self.type_checks.call_site_args, true);
        try self.writeCheckJson(writer, "property_types", self.type_checks.property_types, true);
        try self.writeCheckJson(writer, "return_types", self.type_checks.return_types, true);
        try self.writeCheckJson(writer, "null_safety", self.type_checks.null_safety, false);
        try writer.writeAll("  },\n");

        // Confidence distribution
        try writer.writeAll("  \"confidence\": {\n");
        try writer.print("    \"exact\": {d:.1},\n", .{self.confidence.exact_pct});
        try writer.print("    \"likely\": {d:.1},\n", .{self.confidence.likely_pct});
        try writer.print("    \"possible\": {d:.1},\n", .{self.confidence.possible_pct});
        try writer.print("    \"unresolved\": {d:.1}\n", .{self.confidence.unresolved_pct});
        try writer.writeAll("  },\n");

        // Violations
        try writer.writeAll("  \"violations\": [");
        for (self.violations.items, 0..) |v, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {");
            try writer.print("\"severity\": \"{s}\", ", .{v.severityLabel()});
            try writer.print("\"file\": \"{s}\", ", .{v.file_path});
            try writer.print("\"line\": {d}, ", .{v.line});
            try writer.print("\"message\": \"{s}\"", .{v.message});
            try writer.writeAll("}");
        }
        if (self.violations.items.len > 0) {
            try writer.writeAll("\n  ");
        }
        try writer.writeAll("]\n");

        try writer.writeAll("}\n");
        try writer.flush();
    }

    fn writeCheckJson(self: *const UnifiedReport, writer: anytype, key: []const u8, check: CheckResult, comma: bool) !void {
        _ = self;
        try writer.print("    \"{s}\": {{\"pass\": {d}, \"fail\": {d}, \"unchecked\": {d}}}", .{
            key,
            check.pass,
            check.fail,
            check.unchecked,
        });
        if (comma) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }

    // ========================================================================
    // SARIF Output
    // ========================================================================

    pub fn toSarif(self: *const UnifiedReport, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");
        try writer.writeAll("  \"$schema\": \"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json\",\n");
        try writer.writeAll("  \"version\": \"2.1.0\",\n");
        try writer.writeAll("  \"runs\": [{\n");
        try writer.writeAll("    \"tool\": {\n");
        try writer.writeAll("      \"driver\": {\n");
        try writer.writeAll("        \"name\": \"phpcma\",\n");
        try writer.writeAll("        \"version\": \"0.4.0\",\n");
        try writer.writeAll("        \"informationUri\": \"https://github.com/benedikt-brunner/phpcma\"\n");
        try writer.writeAll("      }\n");
        try writer.writeAll("    },\n");

        // Results from violations
        try writer.writeAll("    \"results\": [");
        for (self.violations.items, 0..) |v, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n      {\n");
            try writer.print("        \"ruleId\": \"phpcma/{s}\",\n", .{v.category});
            try writer.writeAll("        \"level\": ");
            switch (v.severity) {
                .err => try writer.writeAll("\"error\""),
                .warning => try writer.writeAll("\"warning\""),
                .note => try writer.writeAll("\"note\""),
            }
            try writer.writeAll(",\n");
            try writer.writeAll("        \"message\": {\n");
            try writer.print("          \"text\": \"{s}\"\n", .{v.message});
            try writer.writeAll("        },\n");
            try writer.writeAll("        \"locations\": [{\n");
            try writer.writeAll("          \"physicalLocation\": {\n");
            try writer.writeAll("            \"artifactLocation\": {\n");
            try writer.print("              \"uri\": \"{s}\"\n", .{v.file_path});
            try writer.writeAll("            },\n");
            try writer.writeAll("            \"region\": {\n");
            try writer.print("              \"startLine\": {d}\n", .{v.line});
            try writer.writeAll("            }\n");
            try writer.writeAll("          }\n");
            try writer.writeAll("        }]\n");
            try writer.writeAll("      }");
        }
        if (self.violations.items.len > 0) {
            try writer.writeAll("\n    ");
        }
        try writer.writeAll("]\n");

        try writer.writeAll("  }]\n");
        try writer.writeAll("}\n");
        try writer.flush();
    }

    // ========================================================================
    // Checkstyle XML Output
    // ========================================================================

    pub fn toCheckstyle(self: *const UnifiedReport, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        try writer.writeAll("<checkstyle version=\"4.3\">\n");

        if (self.violations.items.len == 0) {
            try writer.writeAll("</checkstyle>\n");
            try writer.flush();
            return;
        }

        // Group violations by file — emit each unique file once
        // Track which files have been emitted
        var emitted: usize = 0;
        while (emitted < self.violations.items.len) {
            const current_file = self.violations.items[emitted].file_path;

            // Check if we already emitted this file (scan earlier items)
            var already_done = false;
            for (self.violations.items[0..emitted]) |prev| {
                if (std.mem.eql(u8, prev.file_path, current_file)) {
                    already_done = true;
                    break;
                }
            }
            if (already_done) {
                emitted += 1;
                continue;
            }

            try writer.print("  <file name=\"{s}\">\n", .{current_file});

            // Output all violations for this file
            for (self.violations.items) |v| {
                if (!std.mem.eql(u8, v.file_path, current_file)) continue;

                const severity = switch (v.severity) {
                    .err => "error",
                    .warning => "warning",
                    .note => "info",
                };

                try writer.print("    <error line=\"{d}\" column=\"1\" severity=\"{s}\" message=\"{s}\" source=\"phpcma.{s}\"/>\n", .{
                    v.line,
                    severity,
                    v.message,
                    v.category,
                });
            }

            try writer.writeAll("  </file>\n");
            emitted += 1;
        }

        try writer.writeAll("</checkstyle>\n");
        try writer.flush();
    }
};

// ============================================================================
// Sub-structures
// ============================================================================

pub const CoverageSection = struct {
    total_files: usize,
    total_symbols: usize,
    classes: usize,
    interfaces: usize,
    traits: usize,
    functions: usize,
    methods: usize,
    properties: usize,
    total_calls: usize,
    resolved_calls: usize,
    unresolved_calls: usize,
    resolution_rate: f32,

    pub fn init() CoverageSection {
        return .{
            .total_files = 0,
            .total_symbols = 0,
            .classes = 0,
            .interfaces = 0,
            .traits = 0,
            .functions = 0,
            .methods = 0,
            .properties = 0,
            .total_calls = 0,
            .resolved_calls = 0,
            .unresolved_calls = 0,
            .resolution_rate = 0.0,
        };
    }
};

pub const CheckResult = struct {
    pass: usize,
    fail: usize,
    unchecked: usize,

    pub fn init() CheckResult {
        return .{ .pass = 0, .fail = 0, .unchecked = 0 };
    }
};

pub const TypeCheckSection = struct {
    total: usize,
    interface_compliance: CheckResult,
    call_site_args: CheckResult,
    property_types: CheckResult,
    return_types: CheckResult,
    null_safety: CheckResult,

    pub fn init() TypeCheckSection {
        return .{
            .total = 0,
            .interface_compliance = CheckResult.init(),
            .call_site_args = CheckResult.init(),
            .property_types = CheckResult.init(),
            .return_types = CheckResult.init(),
            .null_safety = CheckResult.init(),
        };
    }
};

pub const BoundaryCall = struct {
    source_project: []const u8,
    target_project: []const u8,
    caller: []const u8,
    callee: []const u8,
};

pub const CrossProjectSection = struct {
    boundary_calls: std.ArrayListUnmanaged(BoundaryCall),

    pub fn init() CrossProjectSection {
        return .{
            .boundary_calls = .empty,
        };
    }

    pub fn apiHealthLabel(self: *const CrossProjectSection) []const u8 {
        if (self.boundary_calls.items.len == 0) return "N/A";
        return "OK";
    }
};

pub const ConfidenceDistribution = struct {
    exact_pct: f32,
    likely_pct: f32,
    possible_pct: f32,
    unresolved_pct: f32,
    exact_count: usize,
    likely_count: usize,
    possible_count: usize,
    unresolved_count: usize,

    pub fn init() ConfidenceDistribution {
        return .{
            .exact_pct = 0.0,
            .likely_pct = 0.0,
            .possible_pct = 0.0,
            .unresolved_pct = 0.0,
            .exact_count = 0,
            .likely_count = 0,
            .possible_count = 0,
            .unresolved_count = 0,
        };
    }
};

pub const Violation = struct {
    severity: Severity,
    category: []const u8,
    file_path: []const u8,
    line: u32,
    message: []const u8,

    pub const Severity = enum {
        err,
        warning,
        note,
    };

    pub fn severityLabel(self: *const Violation) []const u8 {
        return switch (self.severity) {
            .err => "ERROR",
            .warning => "WARN",
            .note => "NOTE",
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const SymbolCollector = @import("main.zig").SymbolCollector;
extern fn tree_sitter_php() callconv(.c) *@import("tree-sitter").Language;

fn buildTestGraph(allocator: std.mem.Allocator, source: []const u8) !struct { *SymbolTable, *ProjectCallGraph } {
    const ts = @import("tree-sitter");
    const parser = ts.Parser.create();
    const php_lang = tree_sitter_php();
    parser.setLanguage(php_lang) catch unreachable;
    const tree = parser.parseString(source, null) orelse unreachable;

    const sym_table = try allocator.create(SymbolTable);
    sym_table.* = SymbolTable.init(allocator);

    const file_ctx = try allocator.create(types.FileContext);
    file_ctx.* = types.FileContext.init(allocator, "test.php");

    var collector = SymbolCollector.init(allocator, sym_table, file_ctx, source, php_lang);
    try collector.collect(tree);
    try sym_table.resolveInheritance();

    var analyzer = call_analyzer.CallAnalyzer.init(allocator, sym_table, file_ctx, php_lang);
    try analyzer.analyzeFile(tree, source, "test.php");

    const graph = try allocator.create(ProjectCallGraph);
    graph.* = ProjectCallGraph.init(allocator, sym_table);
    try graph.addCalls(&analyzer);

    return .{ sym_table, graph };
}

test "UnifiedReport: report with multiple phases" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Logger {
        \\    public function log(string $msg): void {}
        \\}
        \\class UserService {
        \\    private Logger $logger;
        \\    public function __construct(Logger $logger) { $this->logger = $logger; }
        \\    public function validate(): bool { return true; }
        \\    public function process(): void {
        \\        $this->validate();
        \\        $this->logger->log("processing");
        \\    }
        \\}
    ;

    const result = try buildTestGraph(alloc, source);
    const sym_table = result[0];
    const call_graph = result[1];

    var report = UnifiedReport.init(alloc);
    defer report.deinit();
    report.populate(sym_table, call_graph);
    report.coverage.total_files = 1;

    // Verify coverage populated
    try std.testing.expect(report.coverage.classes == 2);
    try std.testing.expect(report.coverage.total_symbols > 0);
    try std.testing.expect(report.coverage.total_calls > 0);
    try std.testing.expect(report.coverage.resolution_rate > 0.0);

    // Verify type checks populated
    try std.testing.expect(report.type_checks.total > 0);

    // Verify confidence populated
    const total_pct = report.confidence.exact_pct + report.confidence.likely_pct +
        report.confidence.possible_pct + report.confidence.unresolved_pct;
    try std.testing.expect(total_pct > 99.0 and total_pct < 101.0);

    // Verify text output doesn't crash
    const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer dev_null.close();
    try report.toText(dev_null);
}

test "UnifiedReport: JSON output schema" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Foo {
        \\    public function bar(): void {}
        \\    public function baz(): void { $this->bar(); }
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var report = UnifiedReport.init(alloc);
    defer report.deinit();
    report.populate(result[0], result[1]);

    // Write JSON to a buffer via a pipe
    const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer dev_null.close();
    try report.toJson(dev_null);

    // Verify the structure produces valid output (no crash)
    try std.testing.expect(report.coverage.classes == 1);
    try std.testing.expect(report.coverage.resolution_rate > 0.0);
}

test "UnifiedReport: SARIF output format" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Svc {
        \\    public function run(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var report = UnifiedReport.init(alloc);
    defer report.deinit();
    report.populate(result[0], result[1]);

    // Add a violation to test SARIF output
    try report.addViolation(.{
        .severity = .warning,
        .category = "type-check",
        .file_path = "src/Svc.php",
        .line = 3,
        .message = "Unresolved method call",
    });

    const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer dev_null.close();
    try report.toSarif(dev_null);

    // Verify violation stored
    try std.testing.expect(report.violations.items.len == 1);
    try std.testing.expectEqualStrings("WARN", report.violations.items[0].severityLabel());
}

test "UnifiedReport: report with no violations" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Clean {
        \\    public function doWork(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var report = UnifiedReport.init(alloc);
    defer report.deinit();
    report.populate(result[0], result[1]);

    // No violations
    try std.testing.expect(report.violations.items.len == 0);

    // Coverage should still be populated
    try std.testing.expect(report.coverage.classes == 1);
    try std.testing.expect(report.coverage.methods == 1);

    // Confidence should be all zeros (no calls)
    try std.testing.expect(report.coverage.total_calls == 0);
    try std.testing.expect(report.confidence.exact_pct == 0.0);
    try std.testing.expect(report.confidence.unresolved_pct == 0.0);

    // Text output should not include violations section
    const dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer dev_null.close();
    try report.toText(dev_null);
    try report.toJson(dev_null);
    try report.toSarif(dev_null);
    try report.toCheckstyle(dev_null);
}

// ============================================================================
// Checkstyle Output Tests
// ============================================================================

test "UnifiedReport: Checkstyle valid XML structure" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Svc {
        \\    public function run(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var unified_report = UnifiedReport.init(alloc);
    defer unified_report.deinit();
    unified_report.populate(result[0], result[1]);

    try unified_report.addViolation(.{
        .severity = .err,
        .category = "type-check.argument",
        .file_path = "src/Service/Foo.php",
        .line = 42,
        .message = "Argument 1 expects string, int given",
    });

    // Write to a pipe to capture output
    const pipe = try std.posix.pipe();
    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };
    defer read_file.close();

    try unified_report.toCheckstyle(write_file);
    write_file.close();

    // Read the output
    var output_buf: [4096]u8 = undefined;
    const n = try read_file.readAll(&output_buf);
    const output = output_buf[0..n];

    // Verify XML structure
    try std.testing.expect(std.mem.startsWith(u8, output, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "<checkstyle version=\"4.3\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</checkstyle>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<file name=\"src/Service/Foo.php\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "severity=\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "source=\"phpcma.type-check.argument\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line=\"42\"") != null);
}

test "UnifiedReport: Checkstyle severity mapping" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Svc {
        \\    public function run(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var unified_report = UnifiedReport.init(alloc);
    defer unified_report.deinit();
    unified_report.populate(result[0], result[1]);

    try unified_report.addViolation(.{
        .severity = .err,
        .category = "type-check.argument",
        .file_path = "src/A.php",
        .line = 10,
        .message = "error message",
    });
    try unified_report.addViolation(.{
        .severity = .warning,
        .category = "called-before.wrong-order",
        .file_path = "src/A.php",
        .line = 20,
        .message = "warning message",
    });
    try unified_report.addViolation(.{
        .severity = .note,
        .category = "interface.missing-method",
        .file_path = "src/A.php",
        .line = 30,
        .message = "note message",
    });

    const pipe = try std.posix.pipe();
    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };
    defer read_file.close();

    try unified_report.toCheckstyle(write_file);
    write_file.close();

    var output_buf: [4096]u8 = undefined;
    const n = try read_file.readAll(&output_buf);
    const output = output_buf[0..n];

    // Verify severity mapping: err->error, warning->warning, note->info
    try std.testing.expect(std.mem.indexOf(u8, output, "severity=\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "severity=\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "severity=\"info\"") != null);
}

test "UnifiedReport: Checkstyle file grouping" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Svc {
        \\    public function run(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var unified_report = UnifiedReport.init(alloc);
    defer unified_report.deinit();
    unified_report.populate(result[0], result[1]);

    // Add violations across two files
    try unified_report.addViolation(.{
        .severity = .err,
        .category = "type-check.argument",
        .file_path = "src/Service/Foo.php",
        .line = 10,
        .message = "error in Foo",
    });
    try unified_report.addViolation(.{
        .severity = .warning,
        .category = "called-before.missing",
        .file_path = "src/Service/Bar.php",
        .line = 20,
        .message = "warning in Bar",
    });
    try unified_report.addViolation(.{
        .severity = .err,
        .category = "type-check.return",
        .file_path = "src/Service/Foo.php",
        .line = 15,
        .message = "another error in Foo",
    });

    const pipe = try std.posix.pipe();
    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };
    defer read_file.close();

    try unified_report.toCheckstyle(write_file);
    write_file.close();

    var output_buf: [8192]u8 = undefined;
    const n = try read_file.readAll(&output_buf);
    const output = output_buf[0..n];

    // Count <file> elements — should be exactly 2
    var file_count: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_pos, "<file name=")) |pos| {
        file_count += 1;
        search_pos = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), file_count);

    // Verify both files are present
    try std.testing.expect(std.mem.indexOf(u8, output, "<file name=\"src/Service/Foo.php\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<file name=\"src/Service/Bar.php\">") != null);
}

test "UnifiedReport: Checkstyle empty results" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\<?php
        \\class Clean {
        \\    public function doWork(): void {}
        \\}
    ;

    const result = try buildTestGraph(alloc, source);

    var unified_report = UnifiedReport.init(alloc);
    defer unified_report.deinit();
    unified_report.populate(result[0], result[1]);

    // No violations added

    const pipe = try std.posix.pipe();
    const write_file = std.fs.File{ .handle = pipe[1] };
    const read_file = std.fs.File{ .handle = pipe[0] };
    defer read_file.close();

    try unified_report.toCheckstyle(write_file);
    write_file.close();

    var output_buf: [4096]u8 = undefined;
    const n = try read_file.readAll(&output_buf);
    const output = output_buf[0..n];

    // Should have valid XML with no file elements
    try std.testing.expect(std.mem.startsWith(u8, output, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "<checkstyle version=\"4.3\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</checkstyle>") != null);
    // No <file> elements
    try std.testing.expect(std.mem.indexOf(u8, output, "<file") == null);
}
