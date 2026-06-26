# PHPCMA — Integration Plan: Local MCP × origin/main Analyzers

Status: **proposed**. Authoring date: 2026-06-26. Base commit both lines share:
`9f22865 "plugins"`. Local `HEAD` is 94 commits behind `origin/main 8c07e18`
and fast-forwardable, but the local working tree contains a large uncommitted
MCP effort that origin never saw.

This plan covers three things the user asked for:

1. **Combine** the local (uncommitted) work with `origin/main`.
2. **Incorporate origin's analysis functionality into the MCP** so the engines
   origin built for batch CLI become interactive MCP tools.
3. **Wire the MCP into the repo's workflows** (CI, packaging, contributor gate).

---

## 0. Why this is a synthesis, not a catch-up

Both branches forked from the same base and went in orthogonal directions:

| | **Local (uncommitted)** | **origin/main (+94)** |
|---|---|---|
| Shape | MCP server, long-lived in-memory index | Batch CLI, parse→analyze→emit per run |
| Index | [`project_index.zig`](../src/project_index.zig) `ProjectIndex` (modular) | inline pipeline in [`main.zig`](../src/main.zig) + [`parallel.zig`](../src/parallel.zig) |
| Symbol collection | extracted to [`symbol_collector.zig`](../src/symbol_collector.zig) | inline in `main.zig` |
| Analyses | call graph, called-before, query DSL, references, DI bindings, boundaries(v1) | dead code, null safety, return types, type violations, generics, CFG, boundaries(v2) |
| Output | JSON-RPC tool results (agent-facing) | text / JSON / SARIF / Checkstyle ([`report.zig`](../src/report.zig)) |
| Resolution boost | DI config ([`di_config.zig`](../src/di_config.zig)) | framework stubs ([`framework_stubs.zig`](../src/framework_stubs.zig)) |
| Infra | `scripts/mcp_smoke.sh` | CI/release workflows, composer-plugin, fuzz/corpus/differential tests |

**The unifying fact:** every origin analyzer is a *pure function over the shared
core types*. Confirmed signatures on origin:

- `report.populate(sym_table: *const SymbolTable, call_graph: *const ProjectCallGraph)`
- `BoundaryAnalyzer.init(alloc, &call_graph, project_configs, &sym_table)`
- `TypeViolationAnalyzer.init(alloc, &call_graph, project_configs, &sym_table)`
- `dead_code.extractRefsFromCallGraph(alloc, &call_graph, &sym_table)` → `ProjectLivenessGraph.buildIndex(sym)` → `.analyze(sym, refs)`
- `ReturnTypeChecker` / `NullSafetyAnalyzer`: same `(sym_table, call_graph)` inputs.

Local's `ProjectIndex` already exposes exactly `index.sym_table`,
`index.call_graph`, and `index.project_configs`. So once the trees are merged,
**wrapping an origin analyzer as an MCP tool is a thin handler that calls it
against the already-loaded index** — no re-parsing, no new data model.

### Target architecture

```diagram
                         ╭────────────────────────────╮
   agent / editor  ──────▶  MCP server (stdio)         │
                         │  mcp_server.zig              │
                         ╰───────────────┬──────────────╯
                                         │ borrows
                         ╭───────────────▼──────────────╮
                         │  ProjectIndex (persistent)    │
                         │  sym_table · call_graph ·     │
                         │  resolved · project_configs   │
                         ╰───────────────┬──────────────╯
        ╭────────────────────────────────┼────────────────────────────────╮
        ▼                ▼                ▼                ▼                ▼
   query/refs      dead_code       type checks       boundaries        report
   (local)         (origin)     (origin: null,      (origin v2)      (origin:
                                  return, tva,                        JSON/SARIF/
                                  generics, cfg)                      Checkstyle)
        ╰────────────────────────────────┬────────────────────────────────╯
                                         │ same engines, batch entrypoints
                         ╭───────────────▼──────────────╮
                         │  CLI: report / check-dead /   │
                         │  check-types / check-boundaries│  ← CI uses these
                         ╰───────────────────────────────╯
```

One engine set, two front-ends: **MCP for interactive/agent use, CLI for CI.**

---

## Phase 1 — Reconcile history (combine local + remote)

**Goal:** get a single working tree containing origin's 94 commits *and* the
local MCP work, building green, before any feature integration.

### 1.1 Preserve local work (do first, non-destructive)
1. `git stash push -u -m "mcp-wip"` is *not* enough (loses the mental model).
   Instead create a snapshot branch and commit the WIP so it is diffable:
   - `git switch -c mcp-wip`
   - `git add -A && git commit -m "wip: local MCP server + ProjectIndex (pre-merge snapshot)"`
2. Tag the pre-merge base: `git tag pre-merge-base`.

### 1.2 Bring in origin
3. From `mcp-wip`, create the integration branch: `git switch -c integrate-mcp`.
4. `git merge origin/main` (merge, **not** rebase — the WIP touches 12 files
   origin also rewrote; a single merge with clear conflict resolution beats
   replaying dozens of commits).

### 1.3 Conflict map (known, from `git diff` analysis)

These tracked files are modified on **both** sides → expect real conflicts:

| File | Local intent | Origin intent | Resolution rule |
|---|---|---|---|
| [`main.zig`](../src/main.zig) | adds `mcp` subcommand, routes through `ProjectIndex` | adds `report`/`check-dead`/`check-types`/`check-boundaries`, inline parallel pipeline | **Union the subcommands.** Keep local `mcp`; keep origin's new commands but refactor them to build via `ProjectIndex` (Phase 2). |
| [`call_analyzer.zig`](../src/call_analyzer.zig) | edge fields for query (`is_test`, `unresolved_reason`, `arg_count`), DI bindings | resolution-rate, signature data origin analyzers read | **Superset the `Edge`/`ProjectCallGraph` structs.** Both sets of fields are additive; keep all. |
| [`symbol_table.zig`](../src/symbol_table.zig) | `ResolvedView.explicit_bindings` | inheritance/resolution used by dead_code & type checks | Merge fields; keep both `ResolvedView` extensions. |
| [`type_resolver.zig`](../src/type_resolver.zig) | self/static/parent + DI-aware resolution | local type propagation, generic concretization | Merge; both improve resolution. Verify no double-resolution. |
| [`types.zig`](../src/types.zig) | symbol fields used by MCP describe/query | fields used by type checks (phpdoc_return, etc.) | Superset struct fields. |
| [`phpdoc.zig`](../src/phpdoc.zig) | parser tweaks | parser tweaks + fuzz hardening | Take origin's (fuzz-hardened) base, re-apply any local-only additions. |
| [`composer.zig`](../src/composer.zig) / [`config.zig`](../src/config.zig) | discovery used by ProjectIndex | `extra.phpcma` settings, monorepo config | Merge; both extend config surface. |
| [`plugins/plugin_registry.zig`](../src/plugins/plugin_registry.zig), [`symfony_event_plugin.zig`](../src/plugins/symfony_event_plugin.zig) | local plugin work | origin plugin work | Diff carefully; pick the more complete, re-apply deltas. |
| [`build.zig`](../build.zig) / [`build.zig.zon`](../build.zig.zon) | adds `mcp` exe wiring + MCP dep | +430 lines: test/fuzz/bench/corpus/differential steps, dist | **Take origin's build.zig as the base** (it has all the build steps), then add the MCP module/dep and the local source files to it. |

**File collision (both added, different content):**

| File | Action |
|---|---|
| [`boundary_analyzer.zig`](../src/boundary_analyzer.zig) | **Pick origin's v2** (it is wired into `report.zig` and the `check-boundaries` CLI and is more mature). Port any unique capability from local v1, then delete local v1. Update `ProjectIndex` to import origin's. |

**Clean local-only adds (no origin counterpart — keep as-is):**
`mcp_server.zig`, `project_index.zig`, `query.zig`, `references.zig`,
`di_config.zig`, `symbol_collector.zig`.

**Clean origin-only adds (keep as-is):** `dead_code.zig`, `null_safety.zig`,
`return_type_checker.zig`, `type_violation_analyzer.zig`, `generics.zig`,
`cfg.zig`, `framework_stubs.zig`, `report.zig`, `parallel.zig`, `json_util.zig`,
`node_kind_ids.zig`, all `*_test.zig`, `.github/workflows/*`, `composer-plugin/*`,
`scripts/*`, `docs/investigation/*`.

### 1.4 Make it build & green
5. Reconcile `build.zig` so it compiles `mcp_server.zig` + deps **and** keeps
   origin's `test`/`fuzz`/`bench`/`corpus`/`differential`/`dist` steps.
6. `zig build` → fix compile errors from struct supersets.
7. `zig build test` → must reach origin's baseline + local's tests.
8. `bash scripts/mcp_smoke.sh` → local MCP still answers.

**Exit gate for Phase 1:** `zig build test` green, `mcp_smoke.sh` green, all four
origin CLI commands run, `mcp` command runs. No feature work yet.

---

## Phase 2 — Unify the index pipeline

**Goal:** one code path builds the index, used by both MCP and CLI. Today origin
inlines collect→resolve→callgraph in `main.zig` with `parallel.zig`; local has
`ProjectIndex.create`. Converge on `ProjectIndex`.

1. **Fold origin's parallelism into `ProjectIndex`.** Move
   `parallel.parallelSymbolCollect` / `parallelCallAnalysis` calls *inside*
   `ProjectIndex.create` (behind a thread-count heuristic). Result: the MCP's
   `load_project` gets origin's multi-threaded speed for free.
2. **Register framework stubs in the index build.** Call
   `framework_stubs.registerFrameworkStubs(alloc, &sym_table)` during
   `ProjectIndex` build, *after* symbol collection, *before* call analysis —
   matching origin's ordering. This raises MCP resolution rate on framework code
   (directly serves the local plan's "resolution transparency" goal) and stacks
   with local's DI bindings.
3. **Refactor origin's CLI commands** (`report`, `check-dead`, `check-types`,
   `check-boundaries`) to obtain `sym_table`/`call_graph` from
   `ProjectIndex.create` instead of their inline pipelines. Delete the duplicated
   inline collection code from `main.zig`.
4. Keep origin's per-thread arena memory model (the `fix:` commits converged on
   per-thread arenas, not freed) — `ProjectIndex` must adopt that allocator
   strategy to stay crash-free under parallelism.

**Exit gate:** single `ProjectIndex` build path; CLI and MCP produce identical
`sym_table`/`call_graph`; resolution rate on `test-project/` ≥ pre-merge with
framework stubs measurably improving it; `zig build test` green.

---

## Phase 3 — Expose origin analyzers as MCP tools

**Goal:** turn the batch engines into interactive, read-only MCP tools that run
against the already-loaded `ProjectIndex` (no re-parse). Each is a thin handler +
schema + JSON projection, mirroring the existing tool pattern in
[`mcp_server.zig`](../src/mcp_server.zig) (see how `dependencies`/`impact` are
registered around L208–L236).

| New MCP tool | Backs onto | Handler does | Notes |
|---|---|---|---|
| `check_dead` | `dead_code.ProjectLivenessGraph` | `extractRefsFromCallGraph` → `buildIndex` → `analyze`; project dead symbols as JSON | add `include_public_methods`, `interface_scope` params mirroring CLI |
| `check_types` | `type_violation_analyzer.TypeViolationAnalyzer` | `.init(.., &call_graph, configs, &sym_table).analyze()`; project violations | support `min_confidence`, `exclude_tests` |
| `null_safety` | `null_safety.NullSafetyAnalyzer` | run over loaded index; project nullable-deref findings | could fold into `check_types` as a section |
| `return_types` | `return_type_checker` + `cfg` | CFG-based return verification; project mismatches | |
| `check_boundaries` | `boundary_analyzer` (v2) | `BoundaryAnalyzer.init(..).analyze()`; cross-package violations | monorepo via `.phpcma.json` already loaded |
| `report` | `report.UnifiedReport` | `populate(sym_table, call_graph)` then `toJson` into a string | returns the full unified report as one MCP result; SARIF/Checkstyle stay CLI-only |

Design rules (consistent with [`mcp-design.md`](./mcp-design.md) §9 — *a
confidently-wrong answer is the worst outcome*):

- Every tool reuses the loaded index; **none re-parses**. If no project is
  loaded, return the same "call `load_project` first" contract.
- Each result must carry the existing **trust metadata**: resolution rate,
  `exclude_tests`, and per-finding `resolution`/`is_test` flags, so analyzer
  output inherits the MCP's honesty about a partially-resolved graph.
- All tools keep `readOnlyHint:true, idempotentHint:true` annotations.
- Reuse [`json_util.zig`](../src/json_util.zig) (origin's FQN-escaping helper) for
  every projection so backslash-in-FQN bugs don't reappear.

**Sequencing within Phase 3** (cheap/high-trust first): `check_boundaries` and
`report` (read straight off existing structs) → `check_dead` → `check_types` →
`null_safety` / `return_types` (most graph-quality-sensitive; land after
framework stubs + DI bindings are both active so they don't emit confidently-
wrong findings).

**Exit gate:** each new tool has (a) a schema, (b) a JSON projection with trust
metadata, (c) a `scripts/mcp_smoke.sh` assertion, (d) a unit test on the
projection. `zig build test` green.

---

## Phase 4 — Wire the MCP into the repo's workflows

**Goal:** the MCP becomes a first-class, tested, shipped artifact — not a
side build.

1. **CI (`.github/workflows/ci.yml`):** add a job step that builds the `mcp`
   binary and runs `scripts/mcp_smoke.sh` against `test-project/` and
   `test-project-mono/`. Gate merges on it, same as origin's other test
   pipelines.
2. **Contributor gate ([`AGENTS.md`](../AGENTS.md)):** origin's rule is "ALL test
   pipelines pass before commit." Add `mcp_smoke.sh` to that enumerated list so
   the MCP can't silently regress.
3. **Differential / corpus coverage:** extend origin's corpus harness to also
   exercise MCP tool outputs (at least a golden check that `report` via MCP ==
   `report` via CLI on a fixture). Reuses `scripts/diff-*` infrastructure.
4. **Release (`.github/workflows/release.yml`):** the cross-compilation dist step
   already builds the `phpcma` binary for all platforms; since `mcp` is a
   subcommand of the same binary, confirm the released binary advertises `phpcma
   mcp` and document it. No separate artifact needed.
5. **Composer plugin (`composer-plugin/`):** it auto-installs the `phpcma`
   binary. Add docs/registration so a project can declare the MCP server
   (`phpcma mcp --project composer.json`) for editor/agent integration, and read
   the default project path from the existing `extra.phpcma` composer settings.
6. **Docs:** add an "MCP usage" section (how to launch, tool catalog, the
   load-first contract) and fold the now-shipped `boundary`/`dead`/`type` tools
   into [`mcp-design.md`](./mcp-design.md) / `mcp-iteration-plan.md`.

**Exit gate:** CI runs MCP smoke on every PR; `AGENTS.md` lists it; released
binary documents `phpcma mcp`; composer plugin docs cover MCP setup.

---

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Struct-superset merges in `call_analyzer`/`types`/`symbol_table` silently change resolution behavior | High | After Phase 1, diff resolution rate on `test-project/` before vs after; add an invariant test (origin already has call-graph correctness invariants). |
| `boundary_analyzer` v1↔v2 reconciliation loses a local capability | Medium | Before deleting v1, list its public fns; port anything v2 lacks; keep v1 in `mcp-wip` branch for reference. |
| Origin's inline `main.zig` pipeline and local `ProjectIndex` diverge in symbol-collection details (origin inlines collection; local extracted it) | Medium | Phase 2 makes `ProjectIndex` the single source; add a test asserting CLI and MCP produce identical edge counts on a fixture. |
| Memory model mismatch (per-thread arenas vs ProjectIndex allocator) causes use-after-free under parallelism | Medium | Adopt origin's converged arena strategy in `ProjectIndex`; run origin's 9 parallel memory-safety tests against the merged build. |
| MCP tools emit confidently-wrong findings on partially-resolved graphs | Medium | Land null/return/type tools *after* framework stubs + DI bindings; always attach resolution-rate + `is_test` trust metadata. |
| Scope creep (rewriting analyzers instead of wrapping) | Medium | Phase 3 handlers are thin adapters only; no analyzer logic changes. |

## Sequencing summary

```diagram
Phase 1  Reconcile history ──► green build + smoke (no features)
            │
Phase 2  Unify pipeline ─────► ProjectIndex = single index path (+parallel +stubs)
            │
Phase 3  Wrap analyzers ─────► boundaries, report → dead → types → null/return
            │
Phase 4  Workflows ──────────► CI smoke, AGENTS gate, release, composer-plugin docs
```

Each phase ends green (`zig build test` + `scripts/mcp_smoke.sh`) before the next
begins. Phase 1 is the only high-conflict step; Phases 2–4 are additive.

## What explicitly stays out of scope

- Rewriting any origin analysis algorithm (we *wrap*, not reimplement).
- Adding SARIF/Checkstyle to MCP results (CLI-only; agents consume JSON).
- Changing the MCP transport (stdio stays).
- Merging local `boundary_analyzer` v1 wholesale (v2 wins; only unique deltas
  port over).
