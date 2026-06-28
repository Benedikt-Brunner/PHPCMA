# PHPCMA — MCP Surface Design

Status: **implemented** (steps 1–7 complete; build + 26/26 tests + scripted MCP smoke green)

This document specifies adding **MCP (Model Context Protocol)** as a secondary
interaction surface alongside the existing `phpcma` CLI. It captures the design
decisions and their rationale so implementation can proceed against a shared
reference.

## Goal

Let an AI agent run **arbitrary, composable queries** against PHPCMA's call
graph / symbol table over a long-lived session — "build its own analyses" —
with fast, repeated tool calls. The CLI stays the engine API; MCP is a thin
in-process adapter that keeps the expensive analysis state alive between calls.

## Context: today's engine

`phpcma` is a one-shot Zig CLI with three subcommands (`file`, `project`,
`called-before`). Every `project`/`called-before` run executes the full
pipeline and throws the result away on exit:

```
discover files (composer.json / .phpcma.json)
  → tree-sitter parse ALL files
  → SymbolCollector (per-file symbols)
  → resolveInheritance()        [global join]
  → CallAnalyzer + TypeResolver [type-directed, cross-file]
  → ProjectCallGraph
  → text / dot output → exit
```

Two facts drive the whole design:
- **Stateless & one-shot** — re-parses the world every invocation; an MCP
  client expects a warm, fast server.
- **Heavily cross-file coupled** — `resolveClassInheritance` flattens parent +
  trait members into every child; call resolution infers receiver types and
  looks methods up in other files' (inherited) tables. Editing one base class
  ripples into every descendant and every call site that targets them.

## Decisions

### 1. Placement
- New in-binary subcommand **`phpcma mcp`** speaking JSON-RPC over **stdio**.
- The CLI subcommands remain the single source of truth for engine behavior;
  MCP reuses the same internal modules in-process (no shelling out, no
  re-serialization through text).

### 2. Library & toolchain
- Use **`muhammad-fiaz/mcp.zig`** (maintained line) for the MCP protocol.
- **Upgrade the project to Zig 0.16** to use it (`main`/`0.0.5` require 0.16;
  the 0.15-compatible `0.0.3` tag is a dead-end pin). The `tree_sitter`,
  `tree_sitter_php`, and `cli` deps are pinned to 0.15-era refs and may need
  bumping as part of the upgrade.
- **Security:** audited `0.0.5` — zero transitive deps, no build-time code
  execution in `build.zig`, no process spawning on the server path, no env /
  secret / filesystem access. The only outbound network is an opt-in GitHub
  update check (`report.zig`) and the client-side HTTP transport — neither is
  imported by `server.zig` nor on the stdio-server code path. Pin the `.zon`
  hash; re-audit on any version bump.
- **Pinned + re-audited** at the `0.0.5` release tag commit
  `393ccea608f29d6be8324acb2deafa52c7ba6b96`
  (hash `mcp-0.0.5-cIUFgwGFBACgcv5OVy2tp7Vlc47GFpUQdaErzZDRz40C`). First-hand
  re-check of the fetched tarball confirmed: `.dependencies = .{}`, no
  exec/run/system in `build.zig`, `report.checkForUpdates` called only from
  `client/client.zig` (we use the server only), and no `std.fs`/`getenv`/
  `process.Child` anywhere in `src`. We call `Server.run(.stdio)` exclusively.

### 3. Lifecycle & caching
- Persistent in-memory index, kept alive across tool calls.
- **Two-tier cache:**
  - **Tier-1 (per-file, local, expensive):** file I/O + tree-sitter parse +
    raw symbol collection. Incrementally patched for **only** changed files.
  - **Tier-2 (global join, cross-file):** inheritance resolution + type-directed
    call edges. **Rebuilt wholesale** on every change.
- Rationale: Tier-1 (I/O + parsing) is the dominant cost; eliminating
  re-parse-the-world is ~all the win. Wholesale Tier-2 rebuild is
  **correct by construction** (no stale cross-file edges) and avoids a
  salsa-style dependency-tracking engine. **Measure the Tier-2 rebuild on a
  real monorepo before** considering fine-grained Tier-2 invalidation.

### 4. Invalidation
- **mtime polling per call** for edits (cheap, robust, no client cooperation).
- **Explicit reload** for structural changes (adds/deletes) — folded into the
  `load_project` tool.
- **No filesystem watcher in v1** (cross-platform fiddliness + threading).

### 5. Memory model
- **Per-file arena (Tier-1)** + **one rebuildable Tier-2 arena**.
  - File change → reset that file's arena, rebuild its Tier-1 artifacts.
  - Tier-2 → `reset()` + rebuild wholesale each change (cheap, leak-free).
- **Foundational refactor — raw/derived split:** Tier-1 produces *immutable raw*
  symbols (own members, `extends`, `uses`); Tier-2 builds the *resolved* view
  (`all_methods`, `parent_chain`, resolved call edges) as a separate structure
  keyed by FQCN, **never mutating Tier-1**. Today `resolveClassInheritance`
  mutates the collected `ClassSymbol`; that must move into the Tier-2 layer or
  the cache cannot be reset cleanly and re-running the join double-applies
  inheritance.
- tree-sitter `Tree`s are C resources, not arena memory: track per file and
  `.destroy()` on invalidation. Index-lifetime strings (FQCN keys/values) are
  owned by / duped into the Tier-2 arena, never borrowed from a file arena.

### 6. Concurrency
- **Single-threaded message loop**, no worker threads (one local stdio client;
  threading would reintroduce data races on the shared cache).
- **Lazy synchronous build** kept off the `initialize` handshake (slow
  handshake → clients declare the server dead). Pay the cost on first build.
- Emit **`notifications/progress`** from inside the build loop (the handler owns
  the loop, so no thread is needed) so cold start doesn't look hung.
- Optional **`--project <path>` pre-warm** flag: build the index right after
  `initialize` so the agent's first real query is warm.
- Cost caps bound every query, so the loop can only ever block on the one-time
  cold build.

### 7. Tool surface

Fine-grained query tools, **not** CLI mirrors. Never expose a whole-graph dump
(blows the agent's context). All output is **bounded, structured JSON,
confidence-annotated**; FQN is the stable node id; the agent does set ops
(intersection/difference) client-side over returned FQN lists. Tools return a
structured error if no project is loaded.

- **`load_project(project_path?, plugins?)`**
  - Resolves `composer.json` or `.phpcma.json` (monorepo), builds the index.
  - Returns a **hybrid priming payload**:
    - *Static guide* (restated): query-AST grammar, tool list, cost caps,
      confidence semantics, FQN id format, 2–3 worked whole-analysis examples.
    - *Dynamic orientation*: files/classes indexed, resolution rate, top-level
      namespaces present, candidate entry points.
  - Idempotent: same path = reload; different path = swap active index.
  - Path resolution when called with no argument: `--project` default, else
    **auto-discovery** — walk up from the server's cwd to the first
    `.phpcma.json`/`composer.json`. This is what makes one static MCP config
    work across many git worktrees: each agent spawns its own stdio server with
    cwd = its worktree, and the server resolves the matching project. (`stdio`
    is one process per client, so there is no cross-worktree state sharing.)
  - **Not** named `initialize` (reserved JSON-RPC handshake method).
- **`query(ast)`** — server-side JSON query AST (see below).
- **`called_before(before, after)`** — wraps the existing interprocedural
  `CalledBeforeAnalyzer` (the one negative-path-constraint analysis that can't
  be done client-side).
- **Convenience wrappers:** `find_callers`, `find_callees`, `lookup_symbol`,
  `list_methods` (incl. inherited).

### 8. Query AST

Linear pipeline, evaluated server-side over the in-RAM graph:

```json
{
  "start":    { "fqn": "App\\Service::save" },
              { "match": { "kind": "method|function|class",
                           "name": "*::save",
                           "namespace_prefix": "App\\",
                           "file": "src/..." } },
  "traverse": { "direction": "callers|callees",
                "min_depth": 1, "max_depth": 5,
                "edge_filter": { "min_confidence": 0.5,
                                 "include_synthetic": true,
                                 "include_unresolved": false } },
  "where":    { "kind": "method", "namespace_prefix": "App\\" },
  "select":   "nodes | edges | count | paths",
  "limit": 200, "cursor": "..."
}
```

- **Matching:** glob (`*::save`) + structured predicates. **No regex**
  (catastrophic-backtracking risk on the single-threaded loop). FQN exact match
  is the fast path.
- **Traversal:** **directed only** (`callers` / `callees`); no undirected mode.
  `where` is a **node-level** predicate applied on the traversal frontier
  (path-level predicates are out of scope for v1).
- **Projections:** `nodes`, `edges`, `count` ship in v1. `paths` ships
  **bounded**: shortest-first (BFS order), at most `limit` paths, never full
  enumeration (a diamond graph has exponentially many paths through few nodes),
  with `truncated: true` when capped.
- **Cost caps (server-enforced, not trusted from the agent):** `max_depth`
  ceiling, `max_nodes_visited`, `limit` ceiling, `truncated` flag in the
  response.
- Set composition (named subqueries, intersection/difference) is **deferred** —
  the agent stitches small FQN lists client-side. Revisit only if usage proves
  it too chatty.
- **Edge model (as implemented):** the engine's call resolution is partial, so
  traversal uses a hybrid "may-call" graph. Each edge has a `resolution`:
  `exact` (analyzer resolved the callee type), `name_bridge` (an unresolved
  *instance* call expanded to every same-named method definition; confidence
  0.0, annotated with `raw_callee`/`candidate_count`), or `external` (no
  in-project candidate — a terminal pseudo-node). `edge_filter` controls this:
  `include_bridged` (default true), `include_unresolved` (default false, for
  `external`), and `min_confidence` (a value > 0 yields the exact-only graph,
  since bridges are 0.0). This keeps the tool useful on weakly-resolved graphs
  without misrepresenting bridges as precise, and matches `called_before`'s
  name-matching semantics. Edges report `from,to,confidence,resolved,resolution,
  synthetic,line,column[,raw_callee,candidate_count][,file]`.

### 9. Correctness (a gate, not an afterthought)

A silently-stale cache giving a confidently-wrong `called_before` answer is the
worst possible outcome — worse than being slow.

- **Cornerstone — `incremental == from-scratch` differential test:** load a
  project, apply an edit, reload **incrementally**, then build a **fresh** index
  from the mutated files and assert identical symbol tables + call edges + query
  results. **Wire this before the incremental path is connected to the server.**
  On mismatch, **fall back to a full rebuild** rather than serve wrong answers.
- **Hand-written edit scenarios first** (then fuzz): edit base class, edit
  trait, add/remove method, change signature, add file, delete file, change
  `namespace` / `use` alias — i.e. the known ripple cases.
- **Scripted stdio protocol smoke test:** spawn `phpcma mcp`, drive a canned
  JSON-RPC session (`initialize` → `load_project` → `query` → edit → `query`).
- **Cap/safety tests:** hub node (`Logger`), deep traversal, diamond graph —
  must return `truncated`, stay bounded, never hang the loop.
- **Arena lifecycle test:** many `load_project`/reload cycles under leak
  detection — per-file arena reset reclaims; Tier-2 reset has no
  use-after-reset into Tier-1.
- Existing `test-project/` fixtures and inline Zig `test` blocks are the
  substrate.

## Implementation order (suggested)

1. **Design doc** (this file). ✅ done
2. **Zig 0.16 upgrade** — riskiest prerequisite; bump/verify `tree_sitter`,
   `tree_sitter_php`, `cli` deps; get the existing CLI green on 0.16. ✅ done
   - `minimum_zig_version` → `0.16.0`; deps repinned: `zig-tree-sitter` master,
     `zig-cli` main (off the `zig-0.15` branch), `tree-sitter-php` master.
   - Entry point migrated to `pub fn main(init: std.process.Init)`.
   - Filesystem layer migrated to `std.Io` (`std.fs.File`→`std.Io.File`,
     `openFileAbsolute`/`readToEndAlloc`→`std.Io.Dir.cwd().readFileAlloc`,
     `writeAll`→`writeStreamingAll`, `createFile`/`openDir`/`access`/`statFile`/
     `Iterator.next` now take `io`). A process-wide `types.io` handle, set once
     in `main`, avoids threading `io` through every signature.
   - Misc 0.16 renames: `mem.trimLeft`→`trimStart`, `ArrayList(...){}`→`.empty`,
     ArrayList `.writer()`→`.appendSlice`/`.print`. `Dir.realpath` removed —
     directory cycle-detection now uses the literal path (depth-bounded).
   - `r.deinit()` added in `main` to satisfy the new Debug leak checker.
   - `zig build test` step added; existing tests + all 3 CLI commands pass clean.
   - **Toolchain note:** requires Zig 0.16.0. System Homebrew toolchain has been
     upgraded — `zig` and `zls` are both `0.16.0` at `/opt/homebrew/bin`.
3. **Raw/derived Tier-1/Tier-2 split**, behind the differential
   `incremental == from-scratch` test. Everything else rests on this. ✅ done
   - CLI passes 2–4 extracted into a reusable `ProjectIndex` backbone
     (`src/project_index.zig`), shared by `analyzeProject` and
     `analyzeCalledBefore`; `SymbolCollector` split out into
     `src/symbol_collector.zig`.
   - Tier-2 resolution no longer mutates Tier-1: the inherited/trait view moved
     out of `ClassSymbol` into a new `ResolvedView` (`src/symbol_table.zig`),
     keyed by FQCN, with its own arena and `build`/`destroy` lifecycle. Raw
     `ClassSymbol` lost `all_methods`/`all_properties`/`parent_chain`;
     `SymbolTable` lost `inheritance_resolved`, gaining a non-owning
     `resolved: ?*const ResolvedView` back-pointer that `resolveMethod`/
     `resolveProperty` delegate to (falling back to raw members when null).
   - `ProjectIndex` owns the `ResolvedView` and attaches it before the call
     graph pass, so call analysis sees inherited/trait members exactly as before.
   - Verified: `project` and `called-before` outputs byte-identical to the
     pre-refactor runs; leak-free; `zig build test` green. The from-scratch
     resolver is now covered by a multi-level inheritance + override + trait +
     property unit test (the differential `incremental == from-scratch` test
     lands with the incremental path in step 5).
4. **Add `mcp.zig` dependency** (pinned hash) + minimal `phpcma mcp` subcommand:
   `initialize` handshake + `load_project` (full build, no incremental yet). ✅ done
   - `mcp` dep pinned in `build.zig.zon` (see Library & toolchain audit above);
     wired into both the exe and test modules in `build.zig`.
   - New `src/mcp_server.zig`: stdio `mcp.Server` with persistent `McpState`
     shared via tool `user_data`. The loaded index lives in a persistent
     allocator; each handler gets a per-message arena (freed after its response),
     so index state is never tied to a call.
   - `load_project(project_path?)` tool: resolves `composer.json` (single) or
     `.phpcma.json` (monorepo), builds a `ProjectIndex`, and returns the hybrid
     priming payload (dynamic orientation — files/classes/edges/resolution rate/
     top namespaces — plus a static guide). Idempotent: same path reloads, a
     different path swaps; old project freed only after the new build succeeds.
     Defaults to the `--project` flag when called with no argument.
   - Pass-1 discovery (configs + file list) lives in a heap-pinned arena owned
     alongside the index (the index borrows the configs), avoiding dangling
     arena allocators when the owning struct is stored.
   - Verified by driving a canned stdio JSON-RPC session: `initialize` →
     `notifications/initialized` → `tools/list` (shows `load_project` + schema)
     → `tools/call` (builds index, returns payload). Reload/swap, the
     no-path-and-no-default error, and the FileNotFound error path all return
     clean results. `zig build test` green; CLI commands unchanged + leak-free.
   - Deferred to step 7 (with cap tests): `--project` *pre-warm* and an automated
     scripted protocol smoke test. The priming payload's query-AST grammar is
     restated once the `query` tool lands (step 6).
5. **Persistent index cache** + mtime-poll invalidation + incremental Tier-1
   (guarded by the differential test, full-rebuild fallback). ✅ done
   - `ProjectIndex` rewritten around a persistent per-file Tier-1 cache:
     each `FileUnit` owns its own arena (source + parse tree), a gpa-owned
     stable `path` key, and an mtime/size fingerprint. The files map and the
     sorted `file_order` live in the persistent gpa; derived Tier-2 state
     (symbol table, resolved view, call graph, file contexts/sources) lives in
     a separate `derived_arena` that is reset wholesale on every rebuild.
   - `refresh(new_files)`: structural reload — removes vanished files,
     re-parses fingerprint-changed ones, adds new ones, then rebuilds derived
     state only if anything changed. `pollEdits()`: cheap mtime poll over the
     cached set (no discovery) for pre-query freshening. Tier-2 stays wholesale
     and deterministic (sorted file order) for correctness.
   - MCP `load_project` is now incremental on same-path re-calls: it discovers
     the current file set (temp arena) and calls `refresh`, reusing the parse
     cache; a different path still does a full build + swap.
   - The cornerstone differential gate landed as two tests in
     `src/project_index.zig` (`incremental == from-scratch`: edit a base class;
     add and remove a file). Verified: `zig build test` green, `project` and
     `called-before` byte-identical to baselines, same-path MCP reload returns
     the priming payload, leak-free.
6. **`query` tool** (AST evaluator + cost caps), then `called_before` and the
   convenience wrappers. ✅ done (query tool + `called_before`)
   - `src/query.zig`: parses the JSON query AST (`start` → `traverse` → `where`
     → `select`), evaluates it over the in-RAM graph, and renders deterministic
     JSON. Projections: `nodes`, `edges`, `count`, `paths` (shortest-first via
     BFS parent links). Caps enforced server-side: `max_depth` clamp (25),
     `max_nodes_visited` (100k), `limit` ceiling (1000); `truncated`/`limited`
     flags surface any cap. Matching is glob-only (`*`,`?`) — no regex.
   - Wired into `src/mcp_server.zig` as the `query` tool (nested-object schema
     built by hand since the lib's flat schema builder can't express it). The
     priming payload now restates the full query grammar + worked examples.
   - **Hybrid "may-call" edge model** (oracle-reviewed): resolved calls become
     `exact` edges; unresolved *instance* calls are expanded into `name_bridge`
     edges to every same-named method definition (confidence 0.0, flagged with
     `raw_callee`/`candidate_count`); unresolved calls with no candidate become
     terminal `external` pseudo-nodes. Bridges are on by default (so the tool is
     useful on imperfectly-resolved graphs) but `edge_filter.min_confidence > 0`
     (or `include_bridged:false`) gives the exact-only graph. This mirrors the
     trusted `called_before` name-matching semantics.
   - **Adjacent fix — `FileContext.resolveFQCN`** (`src/types.zig`): completed
     the unfinished namespace-prepend TODO so unqualified/relative names resolve
     against the current namespace (PHP-correct). This makes caller FQNs match
     the symbol-table FQCN identity (`Test\DeepCaller::process` rather than the
     short `DeepCaller::process`). CLI baselines updated accordingly; the
     incremental==from-scratch differential test still passes. (Deeper callee
     resolution — typing constructor-promoted properties for
     `$this->prop->m()` — remains future work; the name-bridge layer covers it
     for now.)
   - **Test harness fix:** `zig build test` was silently running almost no tests
     — Zig lazily analyzes, and in test mode nothing referenced the module
     graph, so `project_index`/`query`/etc. `test` blocks were never compiled.
     Added a test-aggregation block in `src/main.zig` (`_ = @import(...)` for
     every source file). This immediately surfaced and fixed real issues: a
     0.16 comptime bug in `plugins/plugin_registry.zig` (returning a pointer to
     a comptime-local from `getPluginNames`) and pre-existing test-allocator
     leaks in `phpdoc`/`symfony_event_plugin` tests (now run under arenas).
   - Verified: 23/23 tests pass, zero leaks; `query` smoke over the deep call
     chain returns correct nodes/edges/count/paths; exact-only filter, no-project
     and invalid-AST error paths all behave.
   - **`called_before` tool** (`src/mcp_server.zig`): wraps the existing
     `CalledBeforeAnalyzer` over the loaded index. Args `before`/`after` accept a
     full FQN, a class-agnostic `::method`, or a function name. Returns JSON
     `{satisfied, satisfied_in[], violations[], matches[]}` — violations carry
     their `kind` (wrong_order|missing_before|conditional_before) and any
     interprocedural `missing_before_paths`. Lists capped at 200 with
     `*_truncated` flags. Verified: MCP output matches the CLI (`::setup` before
     `::log` → VIOLATED, 2 satisfying, 2 violations); added a rendering unit test
     (now 24/24 tests pass, zero leaks); missing-arg error path behaves.
7. **`--project` pre-warm, protocol smoke + cap tests** — *done*.
   - `phpcma mcp --project=<path>` pre-warms the index on startup via
     `loadProjectInto`; failures are non-fatal and logged to stderr only
     (`logStderr`). Verified by smoke (stderr: `pre-warmed project ...`).
   - **cwd auto-discovery (multi-worktree support):** when no `project_path`
     arg and no `--project` are given, the server walks up from its working
     directory (`discoverProjectFromCwd`) to the first
     `.phpcma.json`/`composer.json` and loads/pre-warms that. Lets one static
     MCP config serve every worktree it is launched in. Uses libc `getcwd`
     (the `Dir.cwd()` AT_FDCWD handle can't be `realPath`-canonicalized).
     Verified: no-arg `load_project` from a worktree root and from a nested
     `src/` both resolve correctly; an unrelated cwd returns the structured
     "No project found" error.
   - Query safety caps unit-tested (depth clamp, visited-node cap, limit
     ceiling, cycle handling) — bringing the suite to **26/26 tests, zero
     leaks**.
   - Scripted stdio protocol smoke added at `scripts/mcp_smoke.sh`: builds,
     drives a canned JSON-RPC session (initialize → tools/list → load_project →
     query count/callers → called_before → invalid-AST), and asserts each
     response. Exits non-zero on any failure so it can gate CI/pre-push.
   - **Progress notifications** remain deferred (not needed for local stdio v1).
