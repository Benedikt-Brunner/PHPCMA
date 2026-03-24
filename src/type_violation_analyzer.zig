const std = @import("std");
const types = @import("types.zig");
const call_analyzer = @import("call_analyzer.zig");
const symbol_table = @import("symbol_table.zig");
const boundary_analyzer = @import("boundary_analyzer.zig");

const EnhancedFunctionCall = types.EnhancedFunctionCall;
const ProjectConfig = types.ProjectConfig;
const MethodSymbol = types.MethodSymbol;
const ClassSymbol = types.ClassSymbol;
const TypeInfo = types.TypeInfo;
const ParameterInfo = types.ParameterInfo;
const ProjectCallGraph = call_analyzer.ProjectCallGraph;
const SymbolTable = symbol_table.SymbolTable;
const BoundaryAnalyzer = boundary_analyzer.BoundaryAnalyzer;
const BoundaryCall = boundary_analyzer.BoundaryCall;
const BoundaryResult = boundary_analyzer.BoundaryResult;

// ============================================================================
// Cross-Project Type Violation Analyzer
// ============================================================================

pub const ViolationSeverity = enum {
    error_level,
    warning,
    info,
};

pub const ViolationKind = enum {
    wrong_argument_type,
    wrong_argument_count,
    wrong_return_type,
    visibility_violation,
    interface_mismatch,
    breaking_change,
};

/// A type violation at a cross-project call site
pub const TypeViolation = struct {
    kind: ViolationKind,
    severity: ViolationSeverity,
    caller_fqn: []const u8,
    callee_fqn: []const u8,
    caller_project: []const u8,
    callee_project: []const u8,
    file_path: []const u8,
    line: u32,
    message: []const u8,
    expected_type: ?[]const u8,
    actual_type: ?[]const u8,
};

/// A method signature snapshot for breaking change detection
pub const MethodSignature = struct {
    fqn: []const u8,
    parameter_types: []const ?[]const u8,
    parameter_names: []const []const u8,
    return_type: ?[]const u8,
    visibility: types.Visibility,
    is_static: bool,
    param_count: usize,
};

/// Breaking change between two method signatures
pub const BreakingChange = struct {
    fqn: []const u8,
    kind: BreakingChangeKind,
    message: []const u8,
    project: []const u8,
};

pub const BreakingChangeKind = enum {
    parameter_added_required,
    parameter_removed,
    parameter_type_changed,
    return_type_changed,
    visibility_reduced,
    method_removed,
};

/// API stability score for a project boundary
pub const ApiStabilityScore = struct {
    from_project: []const u8,
    to_project: []const u8,
    total_api_methods: usize,
    violations: usize,
    breaking_changes: usize,
    score: f32, // 0.0 (unstable) to 1.0 (stable)
};

/// Full result of type violation analysis
pub const TypeViolationResult = struct {
    violations: []const TypeViolation,
    api_signatures: []const MethodSignature,
    breaking_changes: []const BreakingChange,
    stability_scores: []const ApiStabilityScore,
    total_cross_project_calls: usize,
    total_violations: usize,
    error_count: usize,
    warning_count: usize,
};

/// Analyzer for cross-project type violations
pub const TypeViolationAnalyzer = struct {
    allocator: std.mem.Allocator,
    call_graph: *const ProjectCallGraph,
    project_configs: []const ProjectConfig,
    sym_table: *const SymbolTable,
    boundary_analyzer_inst: BoundaryAnalyzer,
    /// Optional: previous signatures for breaking change detection
    previous_signatures: ?[]const MethodSignature,
    /// Minimum resolution confidence to check (0.0-1.0)
    min_confidence: f32 = 0.0,
    /// Strict mode: treat warnings as errors
    strict: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        call_graph: *const ProjectCallGraph,
        project_configs: []const ProjectConfig,
        sym_table: *const SymbolTable,
    ) TypeViolationAnalyzer {
        return .{
            .allocator = allocator,
            .call_graph = call_graph,
            .project_configs = project_configs,
            .sym_table = sym_table,
            .boundary_analyzer_inst = BoundaryAnalyzer.init(allocator, call_graph, project_configs, sym_table),
            .previous_signatures = null,
        };
    }

    /// Set previous signatures for breaking change detection
    pub fn setPreviousSignatures(self: *TypeViolationAnalyzer, sigs: []const MethodSignature) void {
        self.previous_signatures = sigs;
    }

    /// Run the full type violation analysis
    pub fn analyze(self: *TypeViolationAnalyzer) !TypeViolationResult {
        // First run boundary analysis to get cross-project calls
        const boundary_result = try self.boundary_analyzer_inst.analyze();

        var violations: std.ArrayListUnmanaged(TypeViolation) = .empty;
        var error_count: usize = 0;
        var warning_count: usize = 0;

        // Check type violations at each cross-project call site
        for (boundary_result.boundary_calls) |bc| {
            try self.checkCallSite(&bc, &violations, &error_count, &warning_count);
        }

        // Extract API signatures
        const api_sigs = try self.extractApiSignatures(&boundary_result);

        // Detect breaking changes
        var breaking_changes: std.ArrayListUnmanaged(BreakingChange) = .empty;
        if (self.previous_signatures) |prev_sigs| {
            try self.detectBreakingChanges(prev_sigs, api_sigs, &breaking_changes);
        }

        // Compute stability scores
        const scores = try self.computeStabilityScores(
            &boundary_result,
            violations.items,
            breaking_changes.items,
        );

        return TypeViolationResult{
            .violations = try violations.toOwnedSlice(self.allocator),
            .api_signatures = api_sigs,
            .breaking_changes = try breaking_changes.toOwnedSlice(self.allocator),
            .stability_scores = scores,
            .total_cross_project_calls = boundary_result.cross_project_calls,
            .total_violations = violations.items.len,
            .error_count = error_count,
            .warning_count = warning_count,
        };
    }

    /// Check a single cross-project call site for type violations
    fn checkCallSite(
        self: *TypeViolationAnalyzer,
        bc: *const BoundaryCall,
        violations: *std.ArrayListUnmanaged(TypeViolation),
        error_count: *usize,
        warning_count: *usize,
    ) !void {
        // Look up the callee method
        const callee_fqn = bc.callee_fqn;

        // Parse "Class::method" format
        const sep = std.mem.indexOf(u8, callee_fqn, "::") orelse return;
        const class_fqcn = callee_fqn[0..sep];
        const method_name = callee_fqn[sep + 2 ..];

        const method = self.sym_table.resolveMethod(class_fqcn, method_name) orelse return;

        // Check visibility violation: cross-project calling private/protected
        if (method.visibility != .public) {
            const sev: ViolationSeverity = if (method.visibility == .private) .error_level else .warning;
            const vis_str = switch (method.visibility) {
                .private => "private",
                .protected => "protected",
                .public => "public",
            };
            try violations.append(self.allocator, .{
                .kind = .visibility_violation,
                .severity = sev,
                .caller_fqn = bc.caller_fqn,
                .callee_fqn = bc.callee_fqn,
                .caller_project = bc.caller_project,
                .callee_project = bc.callee_project,
                .file_path = bc.file_path,
                .line = bc.line,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Cross-project call to {s} method {s}",
                    .{ vis_str, bc.callee_fqn },
                ),
                .expected_type = "public",
                .actual_type = vis_str,
            });
            if (sev == .error_level) error_count.* += 1 else warning_count.* += 1;
        }

        // Check argument types: look up the caller method and its call args
        // We check if the caller provides arguments matching the callee's parameter types
        try self.checkArgumentTypes(bc, method, violations, error_count, warning_count);

        // Check interface compliance: if callee class implements an interface,
        // verify the method signature matches the interface definition
        try self.checkInterfaceCompliance(bc, class_fqcn, method, violations, error_count, warning_count);
    }

    /// Check argument types at a cross-project call site
    fn checkArgumentTypes(
        self: *TypeViolationAnalyzer,
        bc: *const BoundaryCall,
        callee_method: *const MethodSymbol,
        violations: *std.ArrayListUnmanaged(TypeViolation),
        error_count: *usize,
        warning_count: *usize,
    ) !void {
        // Find the actual call in the call graph to get argument info
        for (self.call_graph.calls.items) |call| {
            if (call.resolved_target == null) continue;
            if (!std.mem.eql(u8, call.resolved_target.?, bc.callee_fqn)) continue;
            if (!std.mem.eql(u8, call.file_path, bc.file_path)) continue;
            if (call.line != bc.line) continue;

            // Skip calls below minimum confidence threshold
            if (call.resolution_confidence < self.min_confidence) continue;

            // Check return type usage: if the callee returns a type from a third project
            const callee_return = callee_method.effectiveReturnType();
            if (callee_return) |ret_type| {
                if (!ret_type.is_builtin and ret_type.kind == .simple) {
                    if (self.sym_table.getClass(ret_type.base_type)) |ret_class| {
                        const ret_project = self.boundary_analyzer_inst.fileToProject(ret_class.file_path);
                        if (ret_project) |rp| {
                            if (!std.mem.eql(u8, rp, bc.callee_project) and
                                !std.mem.eql(u8, rp, bc.caller_project))
                            {
                                try violations.append(self.allocator, .{
                                    .kind = .wrong_return_type,
                                    .severity = .warning,
                                    .caller_fqn = bc.caller_fqn,
                                    .callee_fqn = bc.callee_fqn,
                                    .caller_project = bc.caller_project,
                                    .callee_project = bc.callee_project,
                                    .file_path = bc.file_path,
                                    .line = bc.line,
                                    .message = try std.fmt.allocPrint(
                                        self.allocator,
                                        "Return type {s} belongs to third project",
                                        .{ret_type.base_type},
                                    ),
                                    .expected_type = null,
                                    .actual_type = ret_type.base_type,
                                });
                                warning_count.* += 1;
                            }
                        }
                    }
                }
            }

            // Count required and max parameters
            var required_params: usize = 0;
            var has_variadic = false;
            for (callee_method.parameters) |param| {
                if (!param.has_default and !param.is_variadic) {
                    required_params += 1;
                }
                if (param.is_variadic) {
                    has_variadic = true;
                }
            }
            const max_params: usize = if (has_variadic) std.math.maxInt(usize) else callee_method.parameters.len;
            const arg_count: usize = call.argument_count;

            // Check: too few arguments
            if (arg_count < required_params) {
                try violations.append(self.allocator, .{
                    .kind = .wrong_argument_count,
                    .severity = .error_level,
                    .caller_fqn = bc.caller_fqn,
                    .callee_fqn = bc.callee_fqn,
                    .caller_project = bc.caller_project,
                    .callee_project = bc.callee_project,
                    .file_path = bc.file_path,
                    .line = bc.line,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Too few arguments: {d} passed, {d} required by {s}",
                        .{ arg_count, required_params, bc.callee_fqn },
                    ),
                    .expected_type = null,
                    .actual_type = null,
                });
                error_count.* += 1;
            }

            // Check: too many arguments (only if no variadic param)
            if (arg_count > max_params) {
                try violations.append(self.allocator, .{
                    .kind = .wrong_argument_count,
                    .severity = .error_level,
                    .caller_fqn = bc.caller_fqn,
                    .callee_fqn = bc.callee_fqn,
                    .caller_project = bc.caller_project,
                    .callee_project = bc.callee_project,
                    .file_path = bc.file_path,
                    .line = bc.line,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Too many arguments: {d} passed, {d} expected by {s}",
                        .{ arg_count, callee_method.parameters.len, bc.callee_fqn },
                    ),
                    .expected_type = null,
                    .actual_type = null,
                });
                error_count.* += 1;
            }

            // Check per-argument type compatibility
            const check_count = @min(arg_count, callee_method.parameters.len);
            for (0..check_count) |i| {
                const param = callee_method.parameters[i];
                const param_type = param.type_info orelse param.phpdoc_type orelse continue;

                // Skip untyped parameters
                if (param_type.kind == .mixed) continue;

                // Get argument type
                if (i >= call.argument_types.len) continue;
                const arg_type_opt = call.argument_types[i];
                const arg_type = arg_type_opt orelse continue; // Unresolved arg: skip

                // Check null to non-nullable
                if (std.mem.eql(u8, arg_type.base_type, "null")) {
                    if (param_type.kind != .nullable and
                        !std.mem.eql(u8, param_type.base_type, "null") and
                        param_type.kind != .mixed)
                    {
                        // Check if it's a union that includes null
                        var has_null_in_union = false;
                        if (param_type.kind == .union_type) {
                            for (param_type.type_parts) |part| {
                                if (std.mem.eql(u8, part, "null")) {
                                    has_null_in_union = true;
                                    break;
                                }
                            }
                        }
                        if (!has_null_in_union) {
                            try violations.append(self.allocator, .{
                                .kind = .wrong_argument_type,
                                .severity = .error_level,
                                .caller_fqn = bc.caller_fqn,
                                .callee_fqn = bc.callee_fqn,
                                .caller_project = bc.caller_project,
                                .callee_project = bc.callee_project,
                                .file_path = bc.file_path,
                                .line = bc.line,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "Argument {d} ('{s}'): null passed to non-nullable parameter of type {s}",
                                    .{ i + 1, param.name, param_type.base_type },
                                ),
                                .expected_type = param_type.base_type,
                                .actual_type = "null",
                            });
                            error_count.* += 1;
                            continue;
                        }
                    }
                    continue; // null to nullable is fine
                }

                // Check type compatibility
                if (!self.isTypeCompatible(&arg_type, &param_type)) {
                    try violations.append(self.allocator, .{
                        .kind = .wrong_argument_type,
                        .severity = .error_level,
                        .caller_fqn = bc.caller_fqn,
                        .callee_fqn = bc.callee_fqn,
                        .caller_project = bc.caller_project,
                        .callee_project = bc.callee_project,
                        .file_path = bc.file_path,
                        .line = bc.line,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Argument {d} ('{s}'): type {s} incompatible with parameter type {s}",
                            .{ i + 1, param.name, arg_type.base_type, param_type.base_type },
                        ),
                        .expected_type = param_type.base_type,
                        .actual_type = arg_type.base_type,
                    });
                    error_count.* += 1;
                }
            }

            break;
        }
    }

    /// Check if an argument type is compatible with a parameter type
    fn isTypeCompatible(self: *const TypeViolationAnalyzer, arg_type: *const TypeInfo, param_type: *const TypeInfo) bool {
        // mixed accepts anything
        if (param_type.kind == .mixed or std.mem.eql(u8, param_type.base_type, "mixed")) return true;

        // Defense-in-depth: skip compatibility check if either side still
        // carries an unconcretized self/static/parent (should have been
        // resolved upstream, but guard against it here to avoid false positives)
        if (arg_type.kind == .self_type or arg_type.kind == .static_type or arg_type.kind == .parent_type) return true;
        if (param_type.kind == .self_type or param_type.kind == .static_type or param_type.kind == .parent_type) return true;
        if (std.mem.eql(u8, arg_type.base_type, "self") or std.mem.eql(u8, arg_type.base_type, "static") or std.mem.eql(u8, arg_type.base_type, "parent")) return true;
        if (std.mem.eql(u8, param_type.base_type, "self") or std.mem.eql(u8, param_type.base_type, "static") or std.mem.eql(u8, param_type.base_type, "parent")) return true;

        // Same base type
        if (std.mem.eql(u8, arg_type.base_type, param_type.base_type)) return true;

        // Nullable: check the inner type
        if (param_type.kind == .nullable) {
            if (std.mem.eql(u8, arg_type.base_type, param_type.base_type)) return true;
        }

        // Union type: check if arg matches any part
        if (param_type.kind == .union_type) {
            for (param_type.type_parts) |part| {
                if (std.mem.eql(u8, arg_type.base_type, part)) return true;
            }
        }

        // Scalar widening: int -> float
        if (std.mem.eql(u8, arg_type.base_type, "int") and std.mem.eql(u8, param_type.base_type, "float")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "integer") and std.mem.eql(u8, param_type.base_type, "float")) return true;

        // Synonyms
        if (std.mem.eql(u8, arg_type.base_type, "int") and std.mem.eql(u8, param_type.base_type, "integer")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "integer") and std.mem.eql(u8, param_type.base_type, "int")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "bool") and std.mem.eql(u8, param_type.base_type, "boolean")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "boolean") and std.mem.eql(u8, param_type.base_type, "bool")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "float") and std.mem.eql(u8, param_type.base_type, "double")) return true;
        if (std.mem.eql(u8, arg_type.base_type, "double") and std.mem.eql(u8, param_type.base_type, "float")) return true;

        // Builtin types: if both are builtins and don't match, they're incompatible
        if (arg_type.is_builtin and param_type.is_builtin) return false;

        // Class inheritance compatibility
        if (!arg_type.is_builtin and !param_type.is_builtin) {
            return self.isClassCompatible(arg_type.base_type, param_type.base_type);
        }

        // Scalar vs class: incompatible
        return false;
    }

    /// Check if arg_class is a subtype of param_class (inheritance/interface)
    fn isClassCompatible(self: *const TypeViolationAnalyzer, arg_class: []const u8, param_class: []const u8) bool {
        if (std.mem.eql(u8, arg_class, param_class)) return true;

        // Check if arg_class extends param_class
        if (self.sym_table.getClass(arg_class)) |class| {
            // Check parent chain
            for (class.parent_chain) |ancestor| {
                if (std.mem.eql(u8, ancestor, param_class)) return true;
            }
            // Check implements
            for (class.implements) |iface| {
                if (std.mem.eql(u8, iface, param_class)) return true;
            }
        }

        return false;
    }

    /// Check interface compliance for cross-project calls
    fn checkInterfaceCompliance(
        self: *TypeViolationAnalyzer,
        bc: *const BoundaryCall,
        class_fqcn: []const u8,
        method: *const MethodSymbol,
        violations: *std.ArrayListUnmanaged(TypeViolation),
        error_count: *usize,
        warning_count: *usize,
    ) !void {
        _ = warning_count;
        const class = self.sym_table.getClass(class_fqcn) orelse return;

        for (class.implements) |iface_fqcn| {
            const iface = self.sym_table.getInterface(iface_fqcn) orelse continue;

            // Check if this interface is from a different project
            const iface_project = self.boundary_analyzer_inst.fileToProject(iface.file_path);
            const class_project = self.boundary_analyzer_inst.fileToProject(class.file_path);

            if (iface_project == null or class_project == null) continue;
            if (std.mem.eql(u8, iface_project.?, class_project.?)) continue;

            // Cross-project interface: check method signature matches
            if (iface.methods.get(method.name)) |iface_method| {
                // Check return type match
                const class_ret = method.effectiveReturnType();
                const iface_ret = iface_method.effectiveReturnType();

                if (iface_ret != null and class_ret != null) {
                    if (!std.mem.eql(u8, iface_ret.?.base_type, class_ret.?.base_type)) {
                        try violations.append(self.allocator, .{
                            .kind = .interface_mismatch,
                            .severity = .error_level,
                            .caller_fqn = bc.caller_fqn,
                            .callee_fqn = bc.callee_fqn,
                            .caller_project = bc.caller_project,
                            .callee_project = bc.callee_project,
                            .file_path = bc.file_path,
                            .line = bc.line,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Method {s} return type {s} doesn't match interface {s} ({s})",
                                .{ method.name, class_ret.?.base_type, iface_fqcn, iface_ret.?.base_type },
                            ),
                            .expected_type = iface_ret.?.base_type,
                            .actual_type = class_ret.?.base_type,
                        });
                        error_count.* += 1;
                    }
                }

                // Check parameter count match
                if (iface_method.parameters.len != method.parameters.len) {
                    try violations.append(self.allocator, .{
                        .kind = .interface_mismatch,
                        .severity = .error_level,
                        .caller_fqn = bc.caller_fqn,
                        .callee_fqn = bc.callee_fqn,
                        .caller_project = bc.caller_project,
                        .callee_project = bc.callee_project,
                        .file_path = bc.file_path,
                        .line = bc.line,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Method {s} has {d} params, interface {s} expects {d}",
                            .{ method.name, method.parameters.len, iface_fqcn, iface_method.parameters.len },
                        ),
                        .expected_type = null,
                        .actual_type = null,
                    });
                    error_count.* += 1;
                }

                // Check parameter types match
                const min_params = @min(iface_method.parameters.len, method.parameters.len);
                for (0..min_params) |i| {
                    const iface_param_type = iface_method.parameters[i].type_info orelse continue;
                    const class_param_type = method.parameters[i].type_info orelse continue;

                    if (!std.mem.eql(u8, iface_param_type.base_type, class_param_type.base_type)) {
                        try violations.append(self.allocator, .{
                            .kind = .interface_mismatch,
                            .severity = .error_level,
                            .caller_fqn = bc.caller_fqn,
                            .callee_fqn = bc.callee_fqn,
                            .caller_project = bc.caller_project,
                            .callee_project = bc.callee_project,
                            .file_path = bc.file_path,
                            .line = bc.line,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Parameter '{s}' type {s} doesn't match interface {s} ({s})",
                                .{ method.parameters[i].name, class_param_type.base_type, iface_fqcn, iface_param_type.base_type },
                            ),
                            .expected_type = iface_param_type.base_type,
                            .actual_type = class_param_type.base_type,
                        });
                        error_count.* += 1;
                    }
                }
            }
        }
    }

    /// Extract API method signatures from the boundary result
    fn extractApiSignatures(
        self: *TypeViolationAnalyzer,
        boundary_result: *const BoundaryResult,
    ) ![]const MethodSignature {
        var sigs: std.ArrayListUnmanaged(MethodSignature) = .empty;

        for (boundary_result.api_surface) |api| {
            const sep = std.mem.indexOf(u8, api.fqn, "::") orelse continue;
            const class_fqcn = api.fqn[0..sep];
            const method_name = api.fqn[sep + 2 ..];

            const method = self.sym_table.resolveMethod(class_fqcn, method_name) orelse continue;

            var param_types: std.ArrayListUnmanaged(?[]const u8) = .empty;
            var param_names: std.ArrayListUnmanaged([]const u8) = .empty;

            for (method.parameters) |param| {
                const ptype = if (param.type_info) |ti| ti.base_type else if (param.phpdoc_type) |pd| pd.base_type else null;
                try param_types.append(self.allocator, ptype);
                try param_names.append(self.allocator, param.name);
            }

            const ret_type = if (method.effectiveReturnType()) |rt| rt.base_type else null;

            try sigs.append(self.allocator, .{
                .fqn = api.fqn,
                .parameter_types = try param_types.toOwnedSlice(self.allocator),
                .parameter_names = try param_names.toOwnedSlice(self.allocator),
                .return_type = ret_type,
                .visibility = method.visibility,
                .is_static = method.is_static,
                .param_count = method.parameters.len,
            });
        }

        return try sigs.toOwnedSlice(self.allocator);
    }

    /// Detect breaking changes between previous and current API signatures
    fn detectBreakingChanges(
        self: *TypeViolationAnalyzer,
        prev_sigs: []const MethodSignature,
        curr_sigs: []const MethodSignature,
        changes: *std.ArrayListUnmanaged(BreakingChange),
    ) !void {
        // Build lookup of current signatures
        var curr_map = std.StringHashMap(*const MethodSignature).init(self.allocator);
        defer curr_map.deinit();
        for (curr_sigs) |*sig| {
            try curr_map.put(sig.fqn, sig);
        }

        for (prev_sigs) |*prev| {
            if (curr_map.get(prev.fqn)) |curr| {
                // Method still exists, check for changes
                // Check return type change
                if (prev.return_type != null and curr.return_type != null) {
                    if (!std.mem.eql(u8, prev.return_type.?, curr.return_type.?)) {
                        try changes.append(self.allocator, .{
                            .fqn = prev.fqn,
                            .kind = .return_type_changed,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Return type changed from {s} to {s}",
                                .{ prev.return_type.?, curr.return_type.? },
                            ),
                            .project = self.fqnToProjectName(prev.fqn),
                        });
                    }
                }

                // Check parameter count
                if (curr.param_count > prev.param_count) {
                    // Check if new params are required
                    try changes.append(self.allocator, .{
                        .fqn = prev.fqn,
                        .kind = .parameter_added_required,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Parameters increased from {d} to {d}",
                            .{ prev.param_count, curr.param_count },
                        ),
                        .project = self.fqnToProjectName(prev.fqn),
                    });
                } else if (curr.param_count < prev.param_count) {
                    try changes.append(self.allocator, .{
                        .fqn = prev.fqn,
                        .kind = .parameter_removed,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Parameters decreased from {d} to {d}",
                            .{ prev.param_count, curr.param_count },
                        ),
                        .project = self.fqnToProjectName(prev.fqn),
                    });
                }

                // Check parameter type changes
                const min_params = @min(prev.param_count, curr.param_count);
                for (0..min_params) |i| {
                    if (prev.parameter_types[i] != null and curr.parameter_types[i] != null) {
                        if (!std.mem.eql(u8, prev.parameter_types[i].?, curr.parameter_types[i].?)) {
                            try changes.append(self.allocator, .{
                                .fqn = prev.fqn,
                                .kind = .parameter_type_changed,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "Parameter '{s}' type changed from {s} to {s}",
                                    .{ curr.parameter_names[i], prev.parameter_types[i].?, curr.parameter_types[i].? },
                                ),
                                .project = self.fqnToProjectName(prev.fqn),
                            });
                        }
                    }
                }

                // Check visibility reduction
                if (visibilityRank(curr.visibility) < visibilityRank(prev.visibility)) {
                    try changes.append(self.allocator, .{
                        .fqn = prev.fqn,
                        .kind = .visibility_reduced,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Visibility reduced from {s} to {s}",
                            .{ visibilityStr(prev.visibility), visibilityStr(curr.visibility) },
                        ),
                        .project = self.fqnToProjectName(prev.fqn),
                    });
                }
            } else {
                // Method removed
                try changes.append(self.allocator, .{
                    .fqn = prev.fqn,
                    .kind = .method_removed,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "API method {s} was removed",
                        .{prev.fqn},
                    ),
                    .project = self.fqnToProjectName(prev.fqn),
                });
            }
        }
    }

    fn fqnToProjectName(self: *TypeViolationAnalyzer, fqn: []const u8) []const u8 {
        const sep = std.mem.indexOf(u8, fqn, "::") orelse return "unknown";
        const class_fqcn = fqn[0..sep];
        if (self.sym_table.getClass(class_fqcn)) |class| {
            if (self.boundary_analyzer_inst.fileToProject(class.file_path)) |proj| {
                return shortProjectName(proj);
            }
        }
        return "unknown";
    }

    /// Compute API stability scores per project boundary
    fn computeStabilityScores(
        self: *TypeViolationAnalyzer,
        boundary_result: *const BoundaryResult,
        all_violations: []const TypeViolation,
        all_breaking: []const BreakingChange,
    ) ![]const ApiStabilityScore {
        var scores: std.ArrayListUnmanaged(ApiStabilityScore) = .empty;

        for (boundary_result.summaries) |summary| {
            const from = summary.from_project;
            const to = summary.to_project;

            // Count violations for this boundary
            var violation_count: usize = 0;
            for (all_violations) |v| {
                if (std.mem.eql(u8, v.caller_project, from) and
                    std.mem.eql(u8, v.callee_project, to))
                {
                    violation_count += 1;
                }
            }

            // Count breaking changes for this boundary's target project
            var breaking_count: usize = 0;
            for (all_breaking) |bc| {
                if (std.mem.eql(u8, bc.project, shortProjectName(to))) {
                    breaking_count += 1;
                }
            }

            const total_methods = summary.api_methods.len;
            const total_calls = summary.call_count;

            // Score: 1.0 if no violations and no breaking changes
            // Penalize: -0.1 per violation, -0.2 per breaking change
            // Floor at 0.0
            var score: f32 = 1.0;
            if (total_calls > 0) {
                const violation_penalty = @as(f32, @floatFromInt(violation_count)) * 0.1;
                const breaking_penalty = @as(f32, @floatFromInt(breaking_count)) * 0.2;
                score = @max(0.0, score - violation_penalty - breaking_penalty);
            }

            try scores.append(self.allocator, .{
                .from_project = from,
                .to_project = to,
                .total_api_methods = total_methods,
                .violations = violation_count,
                .breaking_changes = breaking_count,
                .score = score,
            });
        }

        return try scores.toOwnedSlice(self.allocator);
    }

    // ========================================================================
    // Output Formats
    // ========================================================================

    /// Output as text format
    pub fn toText(_: *const TypeViolationAnalyzer, result: *const TypeViolationResult, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("Cross-Project Type Violation Analysis\n");
        try writer.writeAll("=====================================\n\n");

        try writer.print("Cross-project calls analyzed: {d}\n", .{result.total_cross_project_calls});
        try writer.print("Total violations: {d} ({d} errors, {d} warnings)\n\n", .{
            result.total_violations,
            result.error_count,
            result.warning_count,
        });

        // Violations
        if (result.violations.len > 0) {
            try writer.writeAll("Type Violations:\n");
            try writer.writeAll("----------------\n");
            for (result.violations) |v| {
                const severity_str = switch (v.severity) {
                    .error_level => "ERROR",
                    .warning => "WARN ",
                    .info => "INFO ",
                };
                try writer.print("  [{s}] {s}\n", .{ severity_str, v.message });
                try writer.print("    {s} -> {s}\n", .{
                    shortProjectName(v.caller_project),
                    shortProjectName(v.callee_project),
                });
                try writer.print("    at {s}:{d}\n\n", .{ v.file_path, v.line });
            }
        }

        // Breaking changes
        if (result.breaking_changes.len > 0) {
            try writer.writeAll("Breaking Changes:\n");
            try writer.writeAll("-----------------\n");
            for (result.breaking_changes) |bc| {
                try writer.print("  {s}: {s}\n", .{ bc.fqn, bc.message });
                try writer.print("    project: {s}\n\n", .{bc.project});
            }
        }

        // API stability scores
        if (result.stability_scores.len > 0) {
            try writer.writeAll("API Stability Scores:\n");
            try writer.writeAll("---------------------\n");
            for (result.stability_scores) |score| {
                try writer.print("  {s} -> {s}: {d:.0}% ({d} methods, {d} violations, {d} breaking)\n", .{
                    shortProjectName(score.from_project),
                    shortProjectName(score.to_project),
                    score.score * 100,
                    score.total_api_methods,
                    score.violations,
                    score.breaking_changes,
                });
            }
        }

        // API surface report
        if (result.api_signatures.len > 0) {
            try writer.writeAll("\nAPI Surface Signatures:\n");
            try writer.writeAll("----------------------\n");
            for (result.api_signatures) |sig| {
                const vis_str = visibilityStr(sig.visibility);
                const ret_str = sig.return_type orelse "mixed";
                const static_str: []const u8 = if (sig.is_static) "static " else "";
                try writer.print("  {s} {s}{s}(", .{ vis_str, static_str, sig.fqn });
                for (sig.parameter_types, 0..) |pt, i| {
                    if (i > 0) try writer.writeAll(", ");
                    const type_str = pt orelse "mixed";
                    try writer.print("{s} ${s}", .{ type_str, sig.parameter_names[i] });
                }
                try writer.print("): {s}\n", .{ret_str});
            }
        }

        try writer.flush();
    }

    /// Output as JSON format
    pub fn toJson(_: *const TypeViolationAnalyzer, result: *const TypeViolationResult, file: std.fs.File) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        try writer.writeAll("{\n");
        try writer.print("  \"cross_project_calls\": {d},\n", .{result.total_cross_project_calls});
        try writer.print("  \"total_violations\": {d},\n", .{result.total_violations});
        try writer.print("  \"errors\": {d},\n", .{result.error_count});
        try writer.print("  \"warnings\": {d},\n", .{result.warning_count});

        // Violations
        try writer.writeAll("  \"violations\": [\n");
        for (result.violations, 0..) |v, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"kind\": \"{s}\",\n", .{@tagName(v.kind)});
            try writer.print("      \"severity\": \"{s}\",\n", .{@tagName(v.severity)});
            try writer.print("      \"caller\": \"{s}\",\n", .{v.caller_fqn});
            try writer.print("      \"callee\": \"{s}\",\n", .{v.callee_fqn});
            try writer.print("      \"from_project\": \"{s}\",\n", .{shortProjectName(v.caller_project)});
            try writer.print("      \"to_project\": \"{s}\",\n", .{shortProjectName(v.callee_project)});
            try writer.print("      \"message\": \"{s}\",\n", .{v.message});
            try writer.print("      \"line\": {d}\n", .{v.line});
            if (i < result.violations.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        // Breaking changes
        try writer.writeAll("  \"breaking_changes\": [\n");
        for (result.breaking_changes, 0..) |bc, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"fqn\": \"{s}\",\n", .{bc.fqn});
            try writer.print("      \"kind\": \"{s}\",\n", .{@tagName(bc.kind)});
            try writer.print("      \"message\": \"{s}\",\n", .{bc.message});
            try writer.print("      \"project\": \"{s}\"\n", .{bc.project});
            if (i < result.breaking_changes.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        // Stability scores
        try writer.writeAll("  \"stability_scores\": [\n");
        for (result.stability_scores, 0..) |score, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"from\": \"{s}\",\n", .{shortProjectName(score.from_project)});
            try writer.print("      \"to\": \"{s}\",\n", .{shortProjectName(score.to_project)});
            try writer.print("      \"methods\": {d},\n", .{score.total_api_methods});
            try writer.print("      \"violations\": {d},\n", .{score.violations});
            try writer.print("      \"breaking_changes\": {d},\n", .{score.breaking_changes});

            // Format score as integer percentage to avoid float formatting
            const score_pct: u32 = @intFromFloat(score.score * 100);
            try writer.print("      \"score\": {d}\n", .{score_pct});
            if (i < result.stability_scores.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ],\n");

        // API signatures
        try writer.writeAll("  \"api_signatures\": [\n");
        for (result.api_signatures, 0..) |sig, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"fqn\": \"{s}\",\n", .{sig.fqn});
            try writer.print("      \"return_type\": ", .{});
            if (sig.return_type) |rt| {
                try writer.print("\"{s}\",\n", .{rt});
            } else {
                try writer.writeAll("null,\n");
            }
            try writer.print("      \"param_count\": {d},\n", .{sig.param_count});
            try writer.print("      \"visibility\": \"{s}\",\n", .{visibilityStr(sig.visibility)});
            try writer.print("      \"static\": {}\n", .{sig.is_static});
            if (i < result.api_signatures.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ]\n");

        try writer.writeAll("}\n");
        try writer.flush();
    }

    /// Make fileToProject accessible for internal use
    pub fn fileToProject(self: *const TypeViolationAnalyzer, file_path: []const u8) ?[]const u8 {
        return self.boundary_analyzer_inst.fileToProject(file_path);
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn visibilityRank(v: types.Visibility) u8 {
    return switch (v) {
        .public => 3,
        .protected => 2,
        .private => 1,
    };
}

fn visibilityStr(v: types.Visibility) []const u8 {
    return switch (v) {
        .public => "public",
        .protected => "protected",
        .private => "private",
    };
}

fn shortProjectName(root_path: []const u8) []const u8 {
    return BoundaryAnalyzer.shortProjectName(root_path);
}

// ============================================================================
// Tests
// ============================================================================

fn makeTestMethod(alloc: std.mem.Allocator, name: []const u8, class: []const u8, file: []const u8, vis: types.Visibility, params: []const ParameterInfo, ret: ?TypeInfo) types.MethodSymbol {
    _ = alloc;
    return .{
        .name = name,
        .visibility = vis,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = params,
        .return_type = ret,
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = class,
        .file_path = file,
    };
}

test "cross-project correct types - no violations" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Bundle class with public method, correct types
    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Service");
    bundle_class.file_path = "/mono/bundle/src/Service.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "process", "Bundle\\Service", "/mono/bundle/src/Service.php", .public, &.{
        .{ .name = "data", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, try TypeInfo.simple(alloc, "int")));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\Consumer");
    plugin_class.file_path = "/mono/plugin/src/Consumer.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Consumer::run",
        .callee_name = "process",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/plugin/src/Consumer.php",
        .resolved_target = "Bundle\\Service::process",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 1), result.total_cross_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.total_violations);
}

test "cross-project wrong types - visibility violation" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Bundle class with private method
    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Service");
    bundle_class.file_path = "/mono/bundle/src/Service.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "secret", "Bundle\\Service", "/mono/bundle/src/Service.php", .private, &.{}, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\Consumer");
    plugin_class.file_path = "/mono/plugin/src/Consumer.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Consumer::run",
        .callee_name = "secret",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/mono/plugin/src/Consumer.php",
        .resolved_target = "Bundle\\Service::secret",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 1), result.total_cross_project_calls);
    try std.testing.expect(result.total_violations > 0);
    try std.testing.expectEqual(result.violations[0].kind, ViolationKind.visibility_violation);
    try std.testing.expectEqual(result.violations[0].severity, ViolationSeverity.error_level);
}

test "interface in bundle impl in plugin - compliance check" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Interface in bundle
    var iface = types.InterfaceSymbol.init(alloc, "Bundle\\Contract\\Processor");
    iface.file_path = "/mono/bundle/src/Contract/Processor.php";
    try iface.addMethod(.{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = true,
        .is_final = false,
        .parameters = &.{
            .{ .name = "input", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        },
        .return_type = try TypeInfo.simple(alloc, "bool"),
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 2,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "Bundle\\Contract\\Processor",
        .file_path = "/mono/bundle/src/Contract/Processor.php",
    });
    try sym_table.addInterface(iface);

    // Plugin class implements the interface - correctly
    var plugin_class = ClassSymbol.init(alloc, "Plugin\\MyProcessor");
    plugin_class.file_path = "/mono/plugin/src/MyProcessor.php";
    var impl_list = try alloc.alloc([]const u8, 1);
    impl_list[0] = "Bundle\\Contract\\Processor";
    plugin_class.implements = impl_list;
    try plugin_class.addMethod(.{
        .name = "handle",
        .visibility = .public,
        .is_static = false,
        .is_abstract = false,
        .is_final = false,
        .parameters = &.{
            .{ .name = "input", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        },
        .return_type = try TypeInfo.simple(alloc, "bool"),
        .phpdoc_return = null,
        .start_line = 1,
        .end_line = 10,
        .start_byte = 0,
        .end_byte = 0,
        .containing_class = "Plugin\\MyProcessor",
        .file_path = "/mono/plugin/src/MyProcessor.php",
    });
    try sym_table.addClass(plugin_class);

    // A third project calls plugin's handle method
    var app_class = ClassSymbol.init(alloc, "App\\Runner");
    app_class.file_path = "/mono/app/src/Runner.php";
    try sym_table.addClass(app_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "App\\Runner::execute",
        .callee_name = "handle",
        .call_type = .method,
        .line = 15,
        .column = 1,
        .file_path = "/mono/app/src/Runner.php",
        .resolved_target = "Plugin\\MyProcessor::handle",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 3);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");
    configs[2] = ProjectConfig.init(alloc, "/mono/app");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    // Should have no interface mismatch violations (correct implementation)
    for (result.violations) |v| {
        try std.testing.expect(v.kind != ViolationKind.interface_mismatch);
    }
}

test "event dispatch/handler type match" {
    // Simulates event dispatch -> handler pattern across projects
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Event class in bundle
    var event_class = ClassSymbol.init(alloc, "Bundle\\Event\\UserCreated");
    event_class.file_path = "/mono/bundle/src/Event/UserCreated.php";
    try sym_table.addClass(event_class);

    // Handler in plugin
    var handler_class = ClassSymbol.init(alloc, "Plugin\\Handler\\OnUserCreated");
    handler_class.file_path = "/mono/plugin/src/Handler/OnUserCreated.php";
    try handler_class.addMethod(makeTestMethod(alloc, "onEvent", "Plugin\\Handler\\OnUserCreated", "/mono/plugin/src/Handler/OnUserCreated.php", .public, &.{
        .{ .name = "event", .type_info = try TypeInfo.simple(alloc, "Bundle\\Event\\UserCreated"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(handler_class);

    // Dispatch call: bundle dispatches, plugin handles
    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Bundle\\Dispatcher::dispatch",
        .callee_name = "onEvent",
        .call_type = .method,
        .line = 20,
        .column = 1,
        .file_path = "/mono/bundle/src/Dispatcher.php",
        .resolved_target = "Plugin\\Handler\\OnUserCreated::onEvent",
        .resolution_confidence = 0.8,
        .resolution_method = .plugin_generated,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    // Cross-project call should be detected
    try std.testing.expectEqual(@as(usize, 1), result.total_cross_project_calls);
}

test "API surface report accuracy" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Api");
    bundle_class.file_path = "/mono/bundle/src/Api.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "getUser", "Bundle\\Api", "/mono/bundle/src/Api.php", .public, &.{
        .{ .name = "id", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, try TypeInfo.simple(alloc, "string")));
    try bundle_class.addMethod(makeTestMethod(alloc, "setUser", "Bundle\\Api", "/mono/bundle/src/Api.php", .public, &.{
        .{ .name = "name", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, try TypeInfo.simple(alloc, "void")));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\Client");
    plugin_class.file_path = "/mono/plugin/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Client::use",
        .callee_name = "getUser",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/plugin/src/Client.php",
        .resolved_target = "Bundle\\Api::getUser",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Client::use",
        .callee_name = "setUser",
        .call_type = .method,
        .line = 11,
        .column = 1,
        .file_path = "/mono/plugin/src/Client.php",
        .resolved_target = "Bundle\\Api::setUser",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    // Should extract 2 API signatures
    try std.testing.expectEqual(@as(usize, 2), result.api_signatures.len);

    // Verify signature details
    var found_get = false;
    var found_set = false;
    for (result.api_signatures) |sig| {
        if (std.mem.eql(u8, sig.fqn, "Bundle\\Api::getUser")) {
            found_get = true;
            try std.testing.expectEqual(@as(usize, 1), sig.param_count);
            try std.testing.expectEqualStrings("string", sig.return_type.?);
        }
        if (std.mem.eql(u8, sig.fqn, "Bundle\\Api::setUser")) {
            found_set = true;
            try std.testing.expectEqual(@as(usize, 1), sig.param_count);
            try std.testing.expectEqualStrings("void", sig.return_type.?);
        }
    }
    try std.testing.expect(found_get);
    try std.testing.expect(found_set);
}

test "breaking change detection" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Current: method signature changed return type
    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Svc");
    bundle_class.file_path = "/mono/bundle/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "fetch", "Bundle\\Svc", "/mono/bundle/src/Svc.php", .public, &.{
        .{ .name = "id", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, try TypeInfo.simple(alloc, "array"))); // Changed from string to array
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\User");
    plugin_class.file_path = "/mono/plugin/src/User.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\User::load",
        .callee_name = "fetch",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/mono/plugin/src/User.php",
        .resolved_target = "Bundle\\Svc::fetch",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);

    // Set previous signatures (return was string, now it's array)
    const prev_param_types = try alloc.alloc(?[]const u8, 1);
    prev_param_types[0] = "int";
    const prev_param_names = try alloc.alloc([]const u8, 1);
    prev_param_names[0] = "id";

    const prev_sigs: []const MethodSignature = &.{.{
        .fqn = "Bundle\\Svc::fetch",
        .parameter_types = prev_param_types,
        .parameter_names = prev_param_names,
        .return_type = "string",
        .visibility = .public,
        .is_static = false,
        .param_count = 1,
    }};
    tva.setPreviousSignatures(prev_sigs);

    const result = try tva.analyze();

    try std.testing.expect(result.breaking_changes.len > 0);
    try std.testing.expectEqual(result.breaking_changes[0].kind, BreakingChangeKind.return_type_changed);
}

test "circular dependency with types" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "A\\Svc");
    class_a.file_path = "/m/a/src/Svc.php";
    try class_a.addMethod(makeTestMethod(alloc, "doA", "A\\Svc", "/m/a/src/Svc.php", .public, &.{}, null));
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "B\\Svc");
    class_b.file_path = "/m/b/src/Svc.php";
    try class_b.addMethod(makeTestMethod(alloc, "doB", "B\\Svc", "/m/b/src/Svc.php", .public, &.{}, null));
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    // A calls B
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "A\\Svc::run",
        .callee_name = "doB",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/a/src/Svc.php",
        .resolved_target = "B\\Svc::doB",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    // B calls A (circular)
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "B\\Svc::run",
        .callee_name = "doA",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/b/src/Svc.php",
        .resolved_target = "A\\Svc::doA",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    // Both directions should be cross-project calls
    try std.testing.expectEqual(@as(usize, 2), result.total_cross_project_calls);
    // Both use public methods so no violations
    try std.testing.expectEqual(@as(usize, 0), result.total_violations);
}

test "isolated projects - no cross-project calls" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "A\\Svc");
    class_a.file_path = "/m/a/src/Svc.php";
    try class_a.addMethod(makeTestMethod(alloc, "internal", "A\\Svc", "/m/a/src/Svc.php", .public, &.{}, null));
    try sym_table.addClass(class_a);

    var class_a2 = ClassSymbol.init(alloc, "A\\Other");
    class_a2.file_path = "/m/a/src/Other.php";
    try sym_table.addClass(class_a2);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "A\\Other::use",
        .callee_name = "internal",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/m/a/src/Other.php",
        .resolved_target = "A\\Svc::internal",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/a");
    configs[1] = ProjectConfig.init(alloc, "/m/b");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 0), result.total_cross_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.total_violations);
}

test "multiple plugins same bundle API" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Api");
    bundle_class.file_path = "/mono/bundle/src/Api.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "call", "Bundle\\Api", "/mono/bundle/src/Api.php", .public, &.{}, null));
    try sym_table.addClass(bundle_class);

    var plugin1 = ClassSymbol.init(alloc, "Plugin1\\Client");
    plugin1.file_path = "/mono/plugin1/src/Client.php";
    try sym_table.addClass(plugin1);

    var plugin2 = ClassSymbol.init(alloc, "Plugin2\\Client");
    plugin2.file_path = "/mono/plugin2/src/Client.php";
    try sym_table.addClass(plugin2);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin1\\Client::run",
        .callee_name = "call",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/plugin1/src/Client.php",
        .resolved_target = "Bundle\\Api::call",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin2\\Client::run",
        .callee_name = "call",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/plugin2/src/Client.php",
        .resolved_target = "Bundle\\Api::call",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 3);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin1");
    configs[2] = ProjectConfig.init(alloc, "/mono/plugin2");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 2), result.total_cross_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.total_violations);
    // Should have stability scores for both boundaries
    try std.testing.expectEqual(@as(usize, 2), result.stability_scores.len);
}

test "monorepo-only - single project no violations" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var class_a = ClassSymbol.init(alloc, "App\\Svc");
    class_a.file_path = "/mono/src/Svc.php";
    try class_a.addMethod(makeTestMethod(alloc, "run", "App\\Svc", "/mono/src/Svc.php", .private, &.{}, null));
    try sym_table.addClass(class_a);

    var class_b = ClassSymbol.init(alloc, "App\\Other");
    class_b.file_path = "/mono/src/Other.php";
    try sym_table.addClass(class_b);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "App\\Other::go",
        .callee_name = "run",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/mono/src/Other.php",
        .resolved_target = "App\\Svc::run",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 1);
    configs[0] = ProjectConfig.init(alloc, "/mono");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    // Single project: calling private is fine (not cross-project)
    try std.testing.expectEqual(@as(usize, 0), result.total_cross_project_calls);
    try std.testing.expectEqual(@as(usize, 0), result.total_violations);
}

test "bundle API method count" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Lib");
    bundle_class.file_path = "/m/bundle/src/Lib.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "fn1", "Bundle\\Lib", "/m/bundle/src/Lib.php", .public, &.{}, null));
    try bundle_class.addMethod(makeTestMethod(alloc, "fn2", "Bundle\\Lib", "/m/bundle/src/Lib.php", .public, &.{}, null));
    try bundle_class.addMethod(makeTestMethod(alloc, "fn3", "Bundle\\Lib", "/m/bundle/src/Lib.php", .public, &.{}, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\App");
    plugin_class.file_path = "/m/plugin/src/App.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{ .caller_fqn = "Plugin\\App::go", .callee_name = "fn1", .call_type = .method, .line = 10, .column = 1, .file_path = "/m/plugin/src/App.php", .resolved_target = "Bundle\\Lib::fn1", .resolution_confidence = 1.0, .resolution_method = .native_type });
    try call_graph.calls.append(alloc, .{ .caller_fqn = "Plugin\\App::go", .callee_name = "fn2", .call_type = .method, .line = 11, .column = 1, .file_path = "/m/plugin/src/App.php", .resolved_target = "Bundle\\Lib::fn2", .resolution_confidence = 1.0, .resolution_method = .native_type });
    try call_graph.calls.append(alloc, .{ .caller_fqn = "Plugin\\App::go", .callee_name = "fn3", .call_type = .method, .line = 12, .column = 1, .file_path = "/m/plugin/src/App.php", .resolved_target = "Bundle\\Lib::fn3", .resolution_confidence = 1.0, .resolution_method = .native_type });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/bundle");
    configs[1] = ProjectConfig.init(alloc, "/m/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 3), result.total_cross_project_calls);
    try std.testing.expectEqual(@as(usize, 3), result.api_signatures.len);
}

test "boundary violation severity" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var bundle_class = ClassSymbol.init(alloc, "Bundle\\Svc");
    bundle_class.file_path = "/mono/bundle/src/Svc.php";
    // private method -> error
    try bundle_class.addMethod(makeTestMethod(alloc, "priv", "Bundle\\Svc", "/mono/bundle/src/Svc.php", .private, &.{}, null));
    // protected method -> warning
    try bundle_class.addMethod(makeTestMethod(alloc, "prot", "Bundle\\Svc", "/mono/bundle/src/Svc.php", .protected, &.{}, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "Plugin\\Client");
    plugin_class.file_path = "/mono/plugin/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Client::a",
        .callee_name = "priv",
        .call_type = .method,
        .line = 5,
        .column = 1,
        .file_path = "/mono/plugin/src/Client.php",
        .resolved_target = "Bundle\\Svc::priv",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });
    try call_graph.calls.append(alloc, .{
        .caller_fqn = "Plugin\\Client::b",
        .callee_name = "prot",
        .call_type = .method,
        .line = 10,
        .column = 1,
        .file_path = "/mono/plugin/src/Client.php",
        .resolved_target = "Bundle\\Svc::prot",
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
    });

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/mono/bundle");
    configs[1] = ProjectConfig.init(alloc, "/mono/plugin");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();

    try std.testing.expectEqual(@as(usize, 2), result.total_violations);
    try std.testing.expectEqual(@as(usize, 1), result.error_count);
    try std.testing.expectEqual(@as(usize, 1), result.warning_count);

    // Verify specific severities
    var has_error = false;
    var has_warning = false;
    for (result.violations) |v| {
        if (v.severity == .error_level) has_error = true;
        if (v.severity == .warning) has_warning = true;
    }
    try std.testing.expect(has_error);
    try std.testing.expect(has_warning);
}

// ============================================================================
// Phase 2b: Call-Site Argument Type Checking Tests
// ============================================================================

fn makeCallWithArgs(alloc: std.mem.Allocator, caller_fqn: []const u8, callee_name: []const u8, file: []const u8, resolved: []const u8, line: u32, arg_types: []const ?TypeInfo, arg_count: u32) EnhancedFunctionCall {
    _ = alloc;
    return .{
        .caller_fqn = caller_fqn,
        .callee_name = callee_name,
        .call_type = .method,
        .line = line,
        .column = 1,
        .file_path = file,
        .resolved_target = resolved,
        .resolution_confidence = 1.0,
        .resolution_method = .native_type,
        .argument_types = arg_types,
        .argument_count = arg_count,
    };
}

test "ph2b: correct types pass" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "name", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const str_type = try TypeInfo.simple(alloc, "string");
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = str_type;
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: wrong scalar type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "count", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
    try std.testing.expectEqual(ViolationKind.wrong_argument_type, result.violations[0].kind);
}

test "ph2b: null to non-nullable" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "name", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "null");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
    try std.testing.expectEqual(ViolationKind.wrong_argument_type, result.violations[0].kind);
}

test "ph2b: null to nullable passes" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "name", .type_info = try TypeInfo.nullable(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "null");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: compatible class hierarchy" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    // Base class
    var base_class = ClassSymbol.init(alloc, "B\\Base");
    base_class.file_path = "/m/b/src/Base.php";
    try sym_table.addClass(base_class);

    // Child class extends Base
    var child_class = ClassSymbol.init(alloc, "B\\Child");
    child_class.file_path = "/m/b/src/Child.php";
    child_class.extends = "B\\Base";
    try sym_table.addClass(child_class);

    // Method expecting Base
    var svc_class = ClassSymbol.init(alloc, "B\\Svc");
    svc_class.file_path = "/m/b/src/Svc.php";
    try svc_class.addMethod(makeTestMethod(alloc, "process", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "obj", .type_info = TypeInfo{ .kind = .simple, .base_type = "B\\Base", .type_parts = &.{}, .is_builtin = false }, .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(svc_class);

    try sym_table.resolveInheritance();

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = TypeInfo{ .kind = .simple, .base_type = "B\\Child", .type_parts = &.{}, .is_builtin = false };
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "process", "/m/p/src/Client.php", "B\\Svc::process", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: incompatible class" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);

    var expected_class = ClassSymbol.init(alloc, "B\\Expected");
    expected_class.file_path = "/m/b/src/Expected.php";
    try sym_table.addClass(expected_class);

    var wrong_class = ClassSymbol.init(alloc, "B\\Wrong");
    wrong_class.file_path = "/m/b/src/Wrong.php";
    try sym_table.addClass(wrong_class);

    var svc_class = ClassSymbol.init(alloc, "B\\Svc");
    svc_class.file_path = "/m/b/src/Svc.php";
    try svc_class.addMethod(makeTestMethod(alloc, "process", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "obj", .type_info = TypeInfo{ .kind = .simple, .base_type = "B\\Expected", .type_parts = &.{}, .is_builtin = false }, .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(svc_class);

    try sym_table.resolveInheritance();

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = TypeInfo{ .kind = .simple, .base_type = "B\\Wrong", .type_parts = &.{}, .is_builtin = false };
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "process", "/m/p/src/Client.php", "B\\Svc::process", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
    try std.testing.expectEqual(ViolationKind.wrong_argument_type, result.violations[0].kind);
}

test "ph2b: too few args" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "a", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        .{ .name = "b", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
    try std.testing.expectEqual(ViolationKind.wrong_argument_count, result.violations[0].kind);
}

test "ph2b: too many args" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "a", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 3);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    arg_types[1] = try TypeInfo.simple(alloc, "int");
    arg_types[2] = try TypeInfo.simple(alloc, "bool");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 3));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
    try std.testing.expectEqual(ViolationKind.wrong_argument_count, result.violations[0].kind);
}

test "ph2b: variadic accepts extras" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "log", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "msg", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        .{ .name = "args", .type_info = try TypeInfo.simple(alloc, "mixed"), .has_default = false, .is_variadic = true, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 4);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    arg_types[1] = try TypeInfo.simple(alloc, "int");
    arg_types[2] = try TypeInfo.simple(alloc, "string");
    arg_types[3] = try TypeInfo.simple(alloc, "bool");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "log", "/m/p/src/Client.php", "B\\Svc::log", 5, arg_types, 4));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: default param fewer args OK" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "a", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        .{ .name = "b", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = true, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: union type param" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";

    const union_parts = try alloc.alloc([]const u8, 2);
    union_parts[0] = "string";
    union_parts[1] = "int";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "val", .type_info = TypeInfo{ .kind = .union_type, .base_type = "string|int", .type_parts = union_parts, .is_builtin = true }, .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "int");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: mixed accepts anything" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "val", .type_info = try TypeInfo.simple(alloc, "mixed"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: unresolved arg skipped" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "val", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = null; // unresolved
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: untyped param skipped" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "val", .type_info = null, .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: cross-project wrong type" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "count", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "bool");
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    try std.testing.expect(result.error_count > 0);
}

test "ph2b: confidence scoring - filtered out" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "count", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 1);
    arg_types[0] = try TypeInfo.simple(alloc, "string");
    // Low confidence call
    var low_call = makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 1);
    low_call.resolution_confidence = 0.3;
    try call_graph.calls.append(alloc, low_call);

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    tva.min_confidence = 0.8; // Filter out the low-confidence call
    const result = try tva.analyze();
    // The arg type violation should be filtered out
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
}

test "ph2b: multiple violations in single call" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    var sym_table = SymbolTable.init(alloc);
    var bundle_class = ClassSymbol.init(alloc, "B\\Svc");
    bundle_class.file_path = "/m/b/src/Svc.php";
    try bundle_class.addMethod(makeTestMethod(alloc, "run", "B\\Svc", "/m/b/src/Svc.php", .public, &.{
        .{ .name = "name", .type_info = try TypeInfo.simple(alloc, "string"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
        .{ .name = "count", .type_info = try TypeInfo.simple(alloc, "int"), .has_default = false, .is_variadic = false, .is_by_reference = false, .is_promoted = false, .phpdoc_type = null },
    }, null));
    try sym_table.addClass(bundle_class);

    var plugin_class = ClassSymbol.init(alloc, "P\\Client");
    plugin_class.file_path = "/m/p/src/Client.php";
    try sym_table.addClass(plugin_class);

    var call_graph = ProjectCallGraph.init(alloc, &sym_table);
    const arg_types = try alloc.alloc(?TypeInfo, 2);
    arg_types[0] = try TypeInfo.simple(alloc, "int"); // wrong: int instead of string
    arg_types[1] = try TypeInfo.simple(alloc, "string"); // wrong: string instead of int
    try call_graph.calls.append(alloc, makeCallWithArgs(alloc, "P\\Client::go", "run", "/m/p/src/Client.php", "B\\Svc::run", 5, arg_types, 2));

    var configs = try alloc.alloc(ProjectConfig, 2);
    configs[0] = ProjectConfig.init(alloc, "/m/b");
    configs[1] = ProjectConfig.init(alloc, "/m/p");

    var tva = TypeViolationAnalyzer.init(alloc, &call_graph, configs, &sym_table);
    const result = try tva.analyze();
    // Should have 2 type violations (one per wrong argument)
    var type_violations: usize = 0;
    for (result.violations) |v| {
        if (v.kind == .wrong_argument_type) type_violations += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), type_violations);
}
