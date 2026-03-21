const std = @import("std");
const ts = @import("tree-sitter");

// ============================================================================
// Control Flow Graph Infrastructure
// ============================================================================
//
// Pure infrastructure for building CFGs from tree-sitter PHP ASTs.
// No analysis logic — subsequent phases consume the CFG.

/// A basic block: a sequence of statements with single entry/exit.
pub const BasicBlock = struct {
    id: u32,
    /// Indices into the CFG's statements array (start..end).
    stmt_start: u32,
    stmt_end: u32,
    /// Outgoing edges (indices of successor BasicBlocks).
    successors: std.ArrayListUnmanaged(u32),
    /// Incoming edges (indices of predecessor BasicBlocks).
    predecessors: std.ArrayListUnmanaged(u32),
    /// Whether this block is an exit point (return/throw).
    is_exit: bool,
    /// The kind of terminator that ends this block (if any).
    terminator: Terminator,

    pub const Terminator = enum {
        none, // Falls through to next block
        branch, // if/elseif condition
        switch_dispatch, // switch
        return_stmt,
        throw_stmt,
        break_stmt,
        continue_stmt,
        loop_back, // while/for/foreach/do back-edge
    };

    fn init(id: u32, stmt_start: u32) BasicBlock {
        return .{
            .id = id,
            .stmt_start = stmt_start,
            .stmt_end = stmt_start,
            .successors = .empty,
            .predecessors = .empty,
            .is_exit = false,
            .terminator = .none,
        };
    }

    fn deinit(self: *BasicBlock, allocator: std.mem.Allocator) void {
        self.successors.deinit(allocator);
        self.predecessors.deinit(allocator);
    }
};

/// A statement reference within a basic block.
pub const StmtRef = struct {
    /// Byte offset range in source.
    start_byte: u32,
    end_byte: u32,
    /// Line range.
    start_line: u32,
    end_line: u32,
    /// The tree-sitter node kind id.
    kind_id: u16,
};

/// Directed graph of BasicBlocks.
pub const CFG = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(BasicBlock),
    statements: std.ArrayListUnmanaged(StmtRef),
    /// Index of the entry block.
    entry: u32,

    pub fn init(allocator: std.mem.Allocator) CFG {
        return .{
            .allocator = allocator,
            .blocks = .empty,
            .statements = .empty,
            .entry = 0,
        };
    }

    pub fn deinit(self: *CFG) void {
        for (self.blocks.items) |*blk| {
            blk.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
        self.statements.deinit(self.allocator);
    }

    pub fn blockCount(self: *const CFG) u32 {
        return @intCast(self.blocks.items.len);
    }

    pub fn getBlock(self: *const CFG, id: u32) *const BasicBlock {
        return &self.blocks.items[id];
    }

    fn getBlockMut(self: *CFG, id: u32) *BasicBlock {
        return &self.blocks.items[id];
    }

    fn addBlock(self: *CFG) !u32 {
        const id: u32 = @intCast(self.blocks.items.len);
        const stmt_start: u32 = @intCast(self.statements.items.len);
        try self.blocks.append(self.allocator, BasicBlock.init(id, stmt_start));
        return id;
    }

    fn addStmt(self: *CFG, ref: StmtRef) !void {
        try self.statements.append(self.allocator, ref);
    }

    fn addEdge(self: *CFG, from: u32, to: u32) !void {
        const src = self.getBlockMut(from);
        // Avoid duplicate edges.
        for (src.successors.items) |s| {
            if (s == to) return;
        }
        try src.successors.append(self.allocator, to);
        const dst = self.getBlockMut(to);
        try dst.predecessors.append(self.allocator, from);
    }

    /// Enumerate all paths from entry to any exit block.
    /// Returns list of paths, each path is a list of block ids.
    pub fn enumeratePaths(self: *const CFG, allocator: std.mem.Allocator) ![]const []const u32 {
        var result: std.ArrayListUnmanaged([]const u32) = .empty;
        var path: std.ArrayListUnmanaged(u32) = .empty;
        defer path.deinit(allocator);
        const visited = try allocator.alloc(bool, self.blocks.items.len);
        defer allocator.free(visited);
        @memset(visited, false);

        try self.dfsEnumerate(self.entry, &path, visited, &result, allocator);
        return result.toOwnedSlice(allocator);
    }

    fn dfsEnumerate(
        self: *const CFG,
        block_id: u32,
        path: *std.ArrayListUnmanaged(u32),
        visited: []bool,
        result: *std.ArrayListUnmanaged([]const u32),
        allocator: std.mem.Allocator,
    ) !void {
        if (visited[block_id]) return;
        visited[block_id] = true;
        try path.append(allocator, block_id);

        const blk = self.getBlock(block_id);
        if (blk.is_exit or blk.successors.items.len == 0) {
            // Record path.
            try result.append(allocator, try allocator.dupe(u32, path.items));
        } else {
            for (blk.successors.items) |succ| {
                try self.dfsEnumerate(succ, path, visited, result, allocator);
            }
        }

        _ = path.pop();
        visited[block_id] = false;
    }

    /// Return all exit blocks.
    pub fn exitBlocks(self: *const CFG, allocator: std.mem.Allocator) ![]const u32 {
        var exits: std.ArrayListUnmanaged(u32) = .empty;
        for (self.blocks.items, 0..) |blk, i| {
            if (blk.is_exit or blk.successors.items.len == 0) {
                try exits.append(allocator, @intCast(i));
            }
        }
        return exits.toOwnedSlice(allocator);
    }
};

// ============================================================================
// CFG Node Kind IDs — cached tree-sitter symbol IDs for control flow nodes
// ============================================================================

const CfgNodeIds = struct {
    if_statement: u16,
    else_clause: u16,
    else_if_clause: u16,
    switch_statement: u16,
    switch_block: u16,
    case_statement: u16,
    default_statement: u16,
    try_statement: u16,
    catch_clause: u16,
    finally_clause: u16,
    while_statement: u16,
    do_statement: u16,
    for_statement: u16,
    foreach_statement: u16,
    return_statement: u16,
    throw_expression: u16,
    break_statement: u16,
    continue_statement: u16,
    expression_statement: u16,
    compound_statement: u16,
    method_declaration: u16,
    function_definition: u16,
    colon_block: u16,

    fn init(lang: *const ts.Language) CfgNodeIds {
        return .{
            .if_statement = lang.idForNodeKind("if_statement", true),
            .else_clause = lang.idForNodeKind("else_clause", true),
            .else_if_clause = lang.idForNodeKind("else_if_clause", true),
            .switch_statement = lang.idForNodeKind("switch_statement", true),
            .switch_block = lang.idForNodeKind("switch_block", true),
            .case_statement = lang.idForNodeKind("case_statement", true),
            .default_statement = lang.idForNodeKind("default_statement", true),
            .try_statement = lang.idForNodeKind("try_statement", true),
            .catch_clause = lang.idForNodeKind("catch_clause", true),
            .finally_clause = lang.idForNodeKind("finally_clause", true),
            .while_statement = lang.idForNodeKind("while_statement", true),
            .do_statement = lang.idForNodeKind("do_statement", true),
            .for_statement = lang.idForNodeKind("for_statement", true),
            .foreach_statement = lang.idForNodeKind("foreach_statement", true),
            .return_statement = lang.idForNodeKind("return_statement", true),
            .throw_expression = lang.idForNodeKind("throw_expression", true),
            .break_statement = lang.idForNodeKind("break_statement", true),
            .continue_statement = lang.idForNodeKind("continue_statement", true),
            .expression_statement = lang.idForNodeKind("expression_statement", true),
            .compound_statement = lang.idForNodeKind("compound_statement", true),
            .method_declaration = lang.idForNodeKind("method_declaration", true),
            .function_definition = lang.idForNodeKind("function_definition", true),
            .colon_block = lang.idForNodeKind("colon_block", true),
        };
    }
};

// ============================================================================
// CFG Builder — constructs a CFG from a tree-sitter AST
// ============================================================================

pub const CfgBuilder = struct {
    allocator: std.mem.Allocator,
    cfg: CFG,
    ids: CfgNodeIds,
    /// Current block being built.
    current_block: u32,
    /// Stack of loop headers for break/continue.
    loop_stack: std.ArrayListUnmanaged(LoopCtx),

    const LoopCtx = struct {
        header: u32, // Block to continue to
        exit: u32, // Block to break to
    };

    pub fn init(allocator: std.mem.Allocator, language: *const ts.Language) CfgBuilder {
        return .{
            .allocator = allocator,
            .cfg = CFG.init(allocator),
            .ids = CfgNodeIds.init(language),
            .current_block = 0,
            .loop_stack = .empty,
        };
    }

    pub fn deinit(self: *CfgBuilder) void {
        self.loop_stack.deinit(self.allocator);
        self.cfg.deinit();
    }

    /// Build a CFG from a method or function body node.
    /// The node should be a compound_statement (method/function body).
    pub fn buildFromBody(self: *CfgBuilder, body: ts.Node) !CFG {
        const entry = try self.cfg.addBlock();
        self.cfg.entry = entry;
        self.current_block = entry;

        try self.processBlock(body);

        // Finalize: close the last block's statement range.
        self.finalizeCurrentBlock();

        // Return the built CFG, replacing self.cfg with a fresh empty one.
        const result = self.cfg;
        self.cfg = CFG.init(self.allocator);
        return result;
    }

    fn finalizeCurrentBlock(self: *CfgBuilder) void {
        const blk = self.cfg.getBlockMut(self.current_block);
        blk.stmt_end = @intCast(self.cfg.statements.items.len);
    }

    fn startNewBlock(self: *CfgBuilder) !u32 {
        self.finalizeCurrentBlock();
        const new_id = try self.cfg.addBlock();
        self.current_block = new_id;
        return new_id;
    }

    fn emitStmt(self: *CfgBuilder, node: ts.Node) !void {
        try self.cfg.addStmt(.{
            .start_byte = node.startByte(),
            .end_byte = node.endByte(),
            .start_line = node.startPoint().row + 1,
            .end_line = node.endPoint().row + 1,
            .kind_id = node.kindId(),
        });
    }

    // ========================================================================
    // Process compound_statement or colon_block children
    // ========================================================================

    fn processBlock(self: *CfgBuilder, node: ts.Node) error{OutOfMemory}!void {
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                try self.processStatement(child);
            }
        }
    }

    // ========================================================================
    // Statement dispatch
    // ========================================================================

    fn processStatement(self: *CfgBuilder, node: ts.Node) error{OutOfMemory}!void {
        const kid = node.kindId();

        if (kid == self.ids.if_statement) {
            try self.processIf(node);
        } else if (kid == self.ids.switch_statement) {
            try self.processSwitch(node);
        } else if (kid == self.ids.try_statement) {
            try self.processTry(node);
        } else if (kid == self.ids.while_statement) {
            try self.processWhile(node);
        } else if (kid == self.ids.do_statement) {
            try self.processDo(node);
        } else if (kid == self.ids.for_statement) {
            try self.processFor(node);
        } else if (kid == self.ids.foreach_statement) {
            try self.processForeach(node);
        } else if (kid == self.ids.return_statement) {
            try self.processReturn(node);
        } else if (kid == self.ids.expression_statement) {
            try self.processExpressionStatement(node);
        } else if (kid == self.ids.break_statement) {
            try self.processBreak(node);
        } else if (kid == self.ids.continue_statement) {
            try self.processContinue(node);
        } else if (kid == self.ids.compound_statement or kid == self.ids.colon_block) {
            try self.processBlock(node);
        } else {
            // Other statement types: just record them.
            try self.emitStmt(node);
        }
    }

    // ========================================================================
    // Expression statement — may contain throw_expression
    // ========================================================================

    fn processExpressionStatement(self: *CfgBuilder, node: ts.Node) !void {
        // Check if the expression is a throw.
        if (node.namedChild(0)) |expr| {
            if (expr.kindId() == self.ids.throw_expression) {
                try self.processThrow(node);
                return;
            }
        }
        try self.emitStmt(node);
    }

    // ========================================================================
    // Control flow handlers
    // ========================================================================

    fn processIf(self: *CfgBuilder, node: ts.Node) !void {
        // Record the condition as a statement in the current block.
        try self.emitStmt(node);
        const cond_block = self.current_block;
        self.cfg.getBlockMut(cond_block).terminator = .branch;

        // After-if join block.
        const join_block = try self.cfg.addBlock();

        // Process the "then" body.
        const then_block = try self.startNewBlock();
        try self.cfg.addEdge(cond_block, then_block);
        if (node.childByFieldName("body")) |body| {
            try self.processBody(body);
        }
        // If the then-branch didn't terminate, connect to join.
        if (!self.currentBlockTerminated()) {
            self.finalizeCurrentBlock();
            try self.cfg.addEdge(self.current_block, join_block);
        } else {
            self.finalizeCurrentBlock();
        }

        // Process else_if and else clauses (iterate named children).
        var last_cond_block = cond_block;
        var i: u32 = 0;
        while (i < node.namedChildCount()) : (i += 1) {
            if (node.namedChild(i)) |child| {
                const ck = child.kindId();
                if (ck == self.ids.else_if_clause) {
                    const elif_cond = try self.startNewBlock();
                    try self.cfg.addEdge(last_cond_block, elif_cond);
                    try self.emitStmt(child);
                    self.cfg.getBlockMut(elif_cond).terminator = .branch;

                    const elif_body = try self.startNewBlock();
                    try self.cfg.addEdge(elif_cond, elif_body);
                    if (child.childByFieldName("body")) |body| {
                        try self.processBody(body);
                    }
                    if (!self.currentBlockTerminated()) {
                        self.finalizeCurrentBlock();
                        try self.cfg.addEdge(self.current_block, join_block);
                    } else {
                        self.finalizeCurrentBlock();
                    }
                    last_cond_block = elif_cond;
                } else if (ck == self.ids.else_clause) {
                    const else_body_block = try self.startNewBlock();
                    try self.cfg.addEdge(last_cond_block, else_body_block);
                    if (child.childByFieldName("body")) |body| {
                        try self.processBody(body);
                    }
                    if (!self.currentBlockTerminated()) {
                        self.finalizeCurrentBlock();
                        try self.cfg.addEdge(self.current_block, join_block);
                    } else {
                        self.finalizeCurrentBlock();
                    }
                    last_cond_block = 0; // sentinel: else consumed
                }
            }
        }

        // If no else clause, the condition may fall through directly.
        if (last_cond_block != 0) {
            try self.cfg.addEdge(last_cond_block, join_block);
        }

        self.current_block = join_block;
    }

    fn processSwitch(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const dispatch_block = self.current_block;
        self.cfg.getBlockMut(dispatch_block).terminator = .switch_dispatch;

        const exit_block = try self.cfg.addBlock();

        // Push break target.
        try self.loop_stack.append(self.allocator, .{ .header = dispatch_block, .exit = exit_block });
        defer _ = self.loop_stack.pop();

        if (node.childByFieldName("body")) |switch_block| {
            var i: u32 = 0;
            var prev_case_fell_through = false;
            var prev_case_block: u32 = 0;

            while (i < switch_block.namedChildCount()) : (i += 1) {
                if (switch_block.namedChild(i)) |child| {
                    const ck = child.kindId();
                    if (ck == self.ids.case_statement or ck == self.ids.default_statement) {
                        const case_block = try self.startNewBlock();
                        try self.cfg.addEdge(dispatch_block, case_block);

                        // Fall-through from previous case.
                        if (prev_case_fell_through) {
                            try self.cfg.addEdge(prev_case_block, case_block);
                        }

                        // Process case body statements.
                        var j: u32 = 0;
                        while (j < child.namedChildCount()) : (j += 1) {
                            if (child.namedChild(j)) |stmt| {
                                try self.processStatement(stmt);
                            }
                        }

                        if (!self.currentBlockTerminated()) {
                            prev_case_fell_through = true;
                            prev_case_block = self.current_block;
                            self.finalizeCurrentBlock();
                        } else {
                            prev_case_fell_through = false;
                            self.finalizeCurrentBlock();
                        }
                    }
                }
            }

            // Last case falls through to exit.
            if (prev_case_fell_through) {
                try self.cfg.addEdge(prev_case_block, exit_block);
            }
        }

        self.current_block = exit_block;
    }

    fn processTry(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const pre_try_block = self.current_block;

        // Try body.
        const try_body_block = try self.startNewBlock();
        try self.cfg.addEdge(pre_try_block, try_body_block);
        if (node.childByFieldName("body")) |body| {
            try self.processBlock(body);
        }
        const try_end_block = self.current_block;
        const try_terminated = self.currentBlockTerminated();
        self.finalizeCurrentBlock();

        // Join block (after try/catch/finally).
        const join_block = try self.cfg.addBlock();

        // Find finally clause (if any).
        var finally_node: ?ts.Node = null;
        var catch_count: u32 = 0;
        {
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                if (node.namedChild(i)) |child| {
                    if (child.kindId() == self.ids.finally_clause) {
                        finally_node = child;
                    } else if (child.kindId() == self.ids.catch_clause) {
                        catch_count += 1;
                    }
                }
            }
        }

        // Process catch clauses.
        {
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                if (node.namedChild(i)) |child| {
                    if (child.kindId() == self.ids.catch_clause) {
                        const catch_block = try self.startNewBlock();
                        // Any statement in try body can throw → edge to catch.
                        try self.cfg.addEdge(try_body_block, catch_block);
                        if (child.childByFieldName("body")) |body| {
                            try self.processBlock(body);
                        }
                        if (!self.currentBlockTerminated()) {
                            self.finalizeCurrentBlock();
                            try self.cfg.addEdge(self.current_block, join_block);
                        } else {
                            self.finalizeCurrentBlock();
                        }
                    }
                }
            }
        }

        // Connect try end to join (if not terminated).
        if (!try_terminated) {
            try self.cfg.addEdge(try_end_block, join_block);
        }

        // Process finally (modeled as part of join block).
        if (finally_node) |fin| {
            self.current_block = join_block;
            if (fin.childByFieldName("body")) |body| {
                try self.processBlock(body);
            }
            if (!self.currentBlockTerminated()) {
                self.finalizeCurrentBlock();
                if (self.current_block != join_block) {
                    // finally produced new blocks; the last one is the real join.
                    const final_join = try self.cfg.addBlock();
                    try self.cfg.addEdge(self.current_block, final_join);
                    self.current_block = final_join;
                }
            } else {
                self.finalizeCurrentBlock();
            }
        } else {
            self.current_block = join_block;
        }
    }

    fn processWhile(self: *CfgBuilder, node: ts.Node) !void {
        // Condition block (loop header).
        self.finalizeCurrentBlock();
        const pre_loop = self.current_block;
        const header = try self.startNewBlock();
        try self.cfg.addEdge(pre_loop, header);
        try self.emitStmt(node);
        self.cfg.getBlockMut(header).terminator = .branch;

        // Exit block.
        const exit_block = try self.cfg.addBlock();

        // Loop body.
        try self.loop_stack.append(self.allocator, .{ .header = header, .exit = exit_block });
        defer _ = self.loop_stack.pop();

        const body_block = try self.startNewBlock();
        try self.cfg.addEdge(header, body_block);
        if (node.childByFieldName("body")) |body| {
            try self.processBody(body);
        }
        if (!self.currentBlockTerminated()) {
            self.finalizeCurrentBlock();
            self.cfg.getBlockMut(self.current_block).terminator = .loop_back;
            try self.cfg.addEdge(self.current_block, header);
        } else {
            self.finalizeCurrentBlock();
        }

        // False edge from header.
        try self.cfg.addEdge(header, exit_block);
        self.current_block = exit_block;
    }

    fn processDo(self: *CfgBuilder, node: ts.Node) !void {
        self.finalizeCurrentBlock();
        const pre_loop = self.current_block;

        // Body block (entered unconditionally first).
        const body_block = try self.startNewBlock();
        try self.cfg.addEdge(pre_loop, body_block);

        // Exit block.
        const exit_block = try self.cfg.addBlock();

        // The condition block comes after the body.
        const cond_block_id = try self.cfg.addBlock();

        try self.loop_stack.append(self.allocator, .{ .header = cond_block_id, .exit = exit_block });
        defer _ = self.loop_stack.pop();

        if (node.childByFieldName("body")) |body| {
            try self.processBody(body);
        }
        if (!self.currentBlockTerminated()) {
            self.finalizeCurrentBlock();
            try self.cfg.addEdge(self.current_block, cond_block_id);
        } else {
            self.finalizeCurrentBlock();
        }

        // Condition block.
        self.current_block = cond_block_id;
        try self.emitStmt(node);
        self.cfg.getBlockMut(cond_block_id).terminator = .branch;
        self.finalizeCurrentBlock();
        try self.cfg.addEdge(cond_block_id, body_block); // loop back
        try self.cfg.addEdge(cond_block_id, exit_block); // exit

        self.current_block = exit_block;
    }

    fn processFor(self: *CfgBuilder, node: ts.Node) !void {
        // Init part in current block.
        try self.emitStmt(node);
        self.finalizeCurrentBlock();
        const pre_loop = self.current_block;

        // Header (condition).
        const header = try self.startNewBlock();
        try self.cfg.addEdge(pre_loop, header);
        self.cfg.getBlockMut(header).terminator = .branch;

        // Exit block.
        const exit_block = try self.cfg.addBlock();

        try self.loop_stack.append(self.allocator, .{ .header = header, .exit = exit_block });
        defer _ = self.loop_stack.pop();

        // Body.
        const body_block = try self.startNewBlock();
        try self.cfg.addEdge(header, body_block);
        if (node.childByFieldName("body")) |body| {
            try self.processBody(body);
        }
        if (!self.currentBlockTerminated()) {
            self.finalizeCurrentBlock();
            self.cfg.getBlockMut(self.current_block).terminator = .loop_back;
            try self.cfg.addEdge(self.current_block, header);
        } else {
            self.finalizeCurrentBlock();
        }

        try self.cfg.addEdge(header, exit_block);
        self.current_block = exit_block;
    }

    fn processForeach(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        self.finalizeCurrentBlock();
        const pre_loop = self.current_block;

        // Header.
        const header = try self.startNewBlock();
        try self.cfg.addEdge(pre_loop, header);
        self.cfg.getBlockMut(header).terminator = .branch;

        // Exit block.
        const exit_block = try self.cfg.addBlock();

        try self.loop_stack.append(self.allocator, .{ .header = header, .exit = exit_block });
        defer _ = self.loop_stack.pop();

        // Body.
        const body_block = try self.startNewBlock();
        try self.cfg.addEdge(header, body_block);
        if (node.childByFieldName("body")) |body| {
            try self.processBody(body);
        }
        if (!self.currentBlockTerminated()) {
            self.finalizeCurrentBlock();
            self.cfg.getBlockMut(self.current_block).terminator = .loop_back;
            try self.cfg.addEdge(self.current_block, header);
        } else {
            self.finalizeCurrentBlock();
        }

        try self.cfg.addEdge(header, exit_block);
        self.current_block = exit_block;
    }

    fn processReturn(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const blk = self.cfg.getBlockMut(self.current_block);
        blk.terminator = .return_stmt;
        blk.is_exit = true;
    }

    fn processThrow(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const blk = self.cfg.getBlockMut(self.current_block);
        blk.terminator = .throw_stmt;
        blk.is_exit = true;
    }

    fn processBreak(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const blk = self.cfg.getBlockMut(self.current_block);
        blk.terminator = .break_stmt;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
            self.finalizeCurrentBlock();
            try self.cfg.addEdge(self.current_block, ctx.exit);
        }
    }

    fn processContinue(self: *CfgBuilder, node: ts.Node) !void {
        try self.emitStmt(node);
        const blk = self.cfg.getBlockMut(self.current_block);
        blk.terminator = .continue_stmt;
        if (self.loop_stack.items.len > 0) {
            const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
            self.finalizeCurrentBlock();
            try self.cfg.addEdge(self.current_block, ctx.header);
        }
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// Process a body node which may be compound_statement, colon_block, or
    /// a single statement.
    fn processBody(self: *CfgBuilder, node: ts.Node) !void {
        const kid = node.kindId();
        if (kid == self.ids.compound_statement or kid == self.ids.colon_block) {
            try self.processBlock(node);
        } else {
            try self.processStatement(node);
        }
    }

    fn currentBlockTerminated(self: *const CfgBuilder) bool {
        const blk = self.cfg.getBlock(self.current_block);
        return blk.terminator != .none;
    }
};

// ============================================================================
// Tests
// ============================================================================

extern fn tree_sitter_php() callconv(.c) *ts.Language;

fn testParse(source: []const u8) ?*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();
    parser.setLanguage(tree_sitter_php()) catch return null;
    return parser.parseString(source, null);
}

fn findMethodBody(node: ts.Node, ids: CfgNodeIds) ?ts.Node {
    if (node.kindId() == ids.method_declaration or node.kindId() == ids.function_definition) {
        return node.childByFieldName("body");
    }
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        if (node.namedChild(i)) |child| {
            if (findMethodBody(child, ids)) |body| return body;
        }
    }
    return null;
}

fn buildCfgFromSource(allocator: std.mem.Allocator, source: []const u8) !CFG {
    const lang = tree_sitter_php();
    const tree = testParse(source) orelse return error.ParseFailed;
    defer tree.destroy();

    var builder = CfgBuilder.init(allocator, lang);
    defer builder.deinit();

    const ids = CfgNodeIds.init(lang);
    const body = findMethodBody(tree.rootNode(), ids) orelse return error.NoBody;
    return builder.buildFromBody(body);
}

test "CFG: simple linear block" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f() {
        \\    $x = 1;
        \\    $y = 2;
        \\    $z = $x + $y;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have exactly 1 block (entry).
    try std.testing.expectEqual(@as(u32, 1), cfg.blockCount());
    // 3 statements.
    try std.testing.expectEqual(@as(usize, 3), cfg.statements.items.len);
}

test "CFG: if/else branching" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($x) {
        \\    if ($x > 0) {
        \\        $a = 1;
        \\    } else {
        \\        $a = 2;
        \\    }
        \\    return $a;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have multiple blocks: entry+cond, then, else, join.
    try std.testing.expect(cfg.blockCount() >= 4);
    // Entry block should have branch terminator.
    try std.testing.expectEqual(BasicBlock.Terminator.branch, cfg.getBlock(0).terminator);
}

test "CFG: switch/case" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($x) {
        \\    switch ($x) {
        \\        case 1:
        \\            $a = 'one';
        \\            break;
        \\        case 2:
        \\            $a = 'two';
        \\            break;
        \\        default:
        \\            $a = 'other';
        \\    }
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Dispatch block should have switch_dispatch terminator.
    try std.testing.expectEqual(BasicBlock.Terminator.switch_dispatch, cfg.getBlock(0).terminator);
    // At least 5 blocks: dispatch, case1, case2, default, exit.
    try std.testing.expect(cfg.blockCount() >= 5);
}

test "CFG: try/catch/finally" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f() {
        \\    try {
        \\        doSomething();
        \\    } catch (Exception $e) {
        \\        handleError();
        \\    } finally {
        \\        cleanup();
        \\    }
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // At least: pre-try, try-body, catch, join/finally.
    try std.testing.expect(cfg.blockCount() >= 3);
}

test "CFG: while loop" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f() {
        \\    $i = 0;
        \\    while ($i < 10) {
        \\        $i++;
        \\    }
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have: entry, header, body, exit.
    try std.testing.expect(cfg.blockCount() >= 4);
    // Header block should have branch terminator.
    var found_branch = false;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .branch) found_branch = true;
    }
    try std.testing.expect(found_branch);
    // Should have a loop_back terminator.
    var found_loopback = false;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .loop_back) found_loopback = true;
    }
    try std.testing.expect(found_loopback);
}

test "CFG: for loop" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f() {
        \\    for ($i = 0; $i < 10; $i++) {
        \\        echo $i;
        \\    }
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    try std.testing.expect(cfg.blockCount() >= 4);
    var found_branch = false;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .branch) found_branch = true;
    }
    try std.testing.expect(found_branch);
}

test "CFG: early return" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($x) {
        \\    if ($x < 0) {
        \\        return -1;
        \\    }
        \\    return $x;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have return terminators.
    var return_count: u32 = 0;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .return_stmt) return_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), return_count);
    // Both return blocks should be exits.
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .return_stmt) {
            try std.testing.expect(blk.is_exit);
        }
    }
}

test "CFG: nested conditionals" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($x, $y) {
        \\    if ($x > 0) {
        \\        if ($y > 0) {
        \\            return 1;
        \\        } else {
        \\            return 2;
        \\        }
        \\    }
        \\    return 3;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have 3 return blocks.
    var return_count: u32 = 0;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .return_stmt) return_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), return_count);
}

test "CFG: throw as terminator" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($x) {
        \\    if ($x === null) {
        \\        throw new \InvalidArgumentException("null");
        \\    }
        \\    return $x;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    var throw_count: u32 = 0;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .throw_stmt) {
            throw_count += 1;
            try std.testing.expect(blk.is_exit);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), throw_count);
}

test "CFG: empty method" {
    const allocator = std.testing.allocator;
    const source = "<?php function f() {}";
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 1), cfg.blockCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.statements.items.len);
}

test "CFG: complex mixed control flow" {
    const allocator = std.testing.allocator;
    const source =
        \\<?php function f($items) {
        \\    $result = [];
        \\    foreach ($items as $item) {
        \\        if ($item === null) {
        \\            continue;
        \\        }
        \\        try {
        \\            $val = process($item);
        \\        } catch (Exception $e) {
        \\            return null;
        \\        }
        \\        $result[] = $val;
        \\    }
        \\    return $result;
        \\}
    ;
    var cfg = try buildCfgFromSource(allocator, source);
    defer cfg.deinit();

    // Should have many blocks due to foreach + if + try/catch.
    try std.testing.expect(cfg.blockCount() >= 6);

    // Should have continue terminator.
    var found_continue = false;
    for (cfg.blocks.items) |blk| {
        if (blk.terminator == .continue_stmt) found_continue = true;
    }
    try std.testing.expect(found_continue);

    // Path enumeration should produce at least 2 paths.
    const paths = try cfg.enumeratePaths(allocator);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    try std.testing.expect(paths.len >= 2);
}
