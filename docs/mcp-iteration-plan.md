# PHPCMA — MCP Iteration Plan

Status: **all planned goals complete** (Milestones 0, 1, 2 done). The two
originally-deferred items have since shipped as post-plan follow-ons: Goal 1.2
(signature-aware `impact`) and Goal 2.1 Phase B (services.yaml DI bindings).
Nothing remains deferred.

**Final tally:** `zig build test` → 60/60 (from a 29-test baseline);
`bash scripts/mcp_smoke.sh` → passed. MCP tool surface grew from 3 to 6 tools:
`load_project`, `query`, `called_before` (pre-existing) plus `dependencies`,
`impact`, `references` (new). Resolution rate on `test-project/` rose from
0% instance-call resolution to 100% (21/21 edges) after the DI/property fixes.

**Post-plan follow-on (done):**
- Goal 1.2 — signature-aware `impact`. Call sites now capture `arg_count`
  (`EnhancedFunctionCall.arg_count`, populated in `src/call_analyzer.zig`), and
  `impact` reports the target's declared `signature` (total/required/optional
  params + variadic), the observed `call_site_arity` (min/max), per-caller
  `arg_count`, and data-driven `breaking_change` verdicts (add_required_param,
  remove_trailing_param, add_optional_param, make_param_optional). The fan-out
  `risk` verdict is retained alongside.
- Goal 2.1 Phase B — services.yaml DI bindings. A new `src/di_config.zig`
  extracts global interface→concrete bindings (top-level service aliases,
  long-form `alias:`, and `_defaults.bind` typed entries) from Symfony
  `services.yaml`. `ProjectIndex` discovers these configs on disk (and accepts
  them in-memory for tests), and `ResolvedView` gains an `explicit_bindings`
  map consulted *before* the single-implementor heuristic. This resolves the
  multi-implementor interface case Phase A left ambiguous; such edges are tagged
  `di_config_binding` (confidence 0.85). `load_project` now reports DI-aware
  edge counts and the number of explicit bindings.
- Bug fix (pre-existing crash): `dependencies`/`impact` segfaulted on a single
  (non-monorepo) project because `composer.parseComposerJson` slices the
  config's `root_path`/`composer_path` from the project path, but
  `loadProjectInto` parsed from the request-scoped `path` (freed after
  `load_project` returns). Now parses from the arena-owned `owned_path`. Smoke
  test gains a single-project `impact` regression guard.

**Known limitations (intentional scope boundaries, not bugs):**
- Per-service `arguments:`/`bind:` (scoped to one consumer's constructor) are not
  treated as global interface bindings — the type-directed resolver resolves by
  declared type, which can't express call-site-scoped bindings.
- DI configs are discovered on a full `load_project`; editing a `services.yaml`
  needs a fresh load to take effect (same contract as composer.json autoload
  changes).

This plan turns the MCP-improvement suggestion into distinct, quantifiable
goals. It is grounded in the current tree (verified June 2026): the MCP surface
lives in [`src/mcp_server.zig`](../src/mcp_server.zig), the query engine in
[`src/query.zig`](../src/query.zig), the call graph in
[`src/call_analyzer.zig`](../src/call_analyzer.zig), config in
[`src/config.zig`](../src/config.zig), and the Symfony plugin in
[`src/plugins/symfony_event_plugin.zig`](../src/plugins/symfony_event_plugin.zig).

## Guiding principle

The design doc's correctness gate ([mcp-design.md §9](./mcp-design.md)) is the
ordering authority: *a confidently-wrong answer is the worst outcome*. Therefore
the cheap **trust-enablers** (test classification, resolution transparency,
config-reload correctness) land **before** the boundary/impact tools that would
otherwise report confidently-wrong results on a ~33%-resolved graph.

## Baseline (measured)

- Tests: `zig build test` green (29 `test` blocks across `src/`).
- Resolution rate: reported in the priming payload via
  `call_graph.getResolutionRate()` ([call_analyzer.zig#L500](../src/call_analyzer.zig#L500)).
- `EdgeFilter` fields today: `min_confidence`, `include_synthetic`,
  `include_bridged`, `include_unresolved` ([query.zig#L103-L114](../src/query.zig#L103-L114)).
  **No** test/prod separation.
- `Edge.resolution` ∈ {`exact`, `name_bridge`, `external`}
  ([query.zig#L156-L164](../src/query.zig#L156-L164)). No "why unresolved" reason.
- `loadProjectInto` same-path reload reuses `lp.index.project_configs` and never
  re-parses `.phpcma.json` ([mcp_server.zig#L253-L261](../src/mcp_server.zig#L253-L261)).
- Priming payload reports files/classes/edges/namespaces but **not** active
  plugins or synthetic-edge count ([mcp_server.zig#L601-L625](../src/mcp_server.zig#L601-L625)).
- `boundary_analyzer.zig` (1108 lines, commit `bd78340`) and
  `type_violation_analyzer.zig` (1561 lines, `dd56eb3`) exist in git history but
  are **absent** from the current `src/`.

---

## Milestone 0 — Trust enablers (P0) — ✅ DONE

All four goals landed: `zig build test` 34/34 green (+5 tests),
`scripts/mcp_smoke.sh` green (+4 assertions). Summary of what shipped:
- 0.1: `isTestFile` + `EdgeFilter.exclude_tests`; `is_test` on every edge and in
  the `edges` projection ([query.zig](../src/query.zig)).
- 0.2: per-edge `unresolved_reason` in the `edges` projection +
  `computeUnresolvedBreakdown` histogram in the priming payload
  ([mcp_server.zig](../src/mcp_server.zig)).
- 0.3: `ConfigFingerprint` — same-path reload re-parses config when the file
  changed on disk ([mcp_server.zig](../src/mcp_server.zig)).
- 0.4: active-plugins line + synthetic-edge count in the priming payload.
- Fixture: `test-project/tests/LoggerUsageTest.php` (`Tests\` namespace) exercises
  `exclude_tests` end-to-end in the smoke script.

### Goal 0.1 — Test/production edge classification ✅
**What:** Tag every edge with `is_test` derived from the caller file path; add
`exclude_tests: bool = false` to `EdgeFilter`.
**Quantifiable acceptance:**
- `Edge` gains an `is_test` field; classifier matches `/test/`, `/tests/`,
  `*Test.php`, `*.unit.php`, `*.integration.php`, `/Tests/` (case-insensitive).
- `query` honors `edge_filter.exclude_tests`; with it set, no edge whose caller
  file is a test file appears in `nodes`/`edges`/`count`/`paths`.
- ≥ 2 new unit tests: (a) classifier truth table, (b) a `count` query that drops
  from N to N−k when `exclude_tests` is on for a fixture with test callers.
- `scripts/mcp_smoke.sh` gains one `exclude_tests` assertion.

### Goal 0.2 — Resolution transparency ✅
**What:** When an edge is unresolved, say *why*. Add an `unresolved_reason`
classification and surface a breakdown in the priming payload.
**Quantifiable acceptance:**
- New enum reason ∈ {`interface_no_binding`, `dynamic_or_variable`,
  `no_candidate`, `ambiguous_bridge`} attached to non-`exact` edges (best-effort
  from `call_type`/candidate count/receiver info available at build time).
- `edges` projection emits `unresolved_reason` for every non-exact edge.
- Priming payload prints an unresolved-reason histogram (counts per reason).
- ≥ 1 unit test asserting the histogram sums to `unresolved_calls`.

**Shipped taxonomy note:** receiver-type info is not yet threaded into the call
record, so `interface_no_binding` vs `dynamic_or_variable` can't be told apart
honestly today. Shipped the buckets that *are* derivable from build-time data:
`single_candidate` (one same-named def — the likely DI/interface case),
`ambiguous_bridge` (several defs), `no_candidate` (none, or static/function
callee). The richer interface-vs-dynamic split is unblocked by milestone 2.1
(DI-aware resolution) and will refine `single_candidate` then.

### Goal 0.3 — Config-reload correctness ✅ (promoted from P3: silent-lie bug)
**What:** Same-path `load_project` must re-parse `.phpcma.json` /
`composer.json` so plugin-set / namespace-map edits take effect.
**Quantifiable acceptance:**
- Same-path reload re-runs `parseConfigs` (or detects config-file mtime change
  and falls back to full rebuild) rather than reusing stale `project_configs`.
- ≥ 1 unit test: load → change enabled plugins in config on disk → same-path
  reload → assert the active plugin set changed (and synthetic edges follow).
- No regression in the incremental==from-scratch differential tests.

### Goal 0.4 — load_project observability ✅
**What:** Report active plugins and synthetic-edge count in the priming payload.
**Quantifiable acceptance:**
- Payload lists active plugin names (union across project configs, sorted) and
  the count of synthetic (`plugin_generated`) edges.
- `scripts/mcp_smoke.sh` asserts the plugins line is present.

**Milestone 0 exit:** `zig build test` green with ≥ 4 new tests; smoke green.

---

## Milestone 1 — Boundary/impact surface (P1)

> **Prereq fix (done):** `autoload-dev` PSR-4 entries no longer clobber same-namespace
> `autoload` entries — `composer.zig` now merges path lists (`mergePsr4`), with a
> unit test. This was the latent bug flagged at the end of Milestone 0.

### Goal 1.1 — Port + expose `dependencies` (boundary) tool ✅ DONE
Ported `boundary_analyzer.zig` onto the current `ProjectIndex` and exposed it as
the MCP `dependencies` tool. Returns `{summary, caveats, dependencies[],
cross_package_calls[], api_surface_used[]}`; each cross-package finding carries
`resolution` + `is_test`; `exclude_tests` honored (default true); `caveats`
surfaces `unresolved_calls`/`resolution_rate`/`tests_excluded` (the
never-silently-under-report guarantee). 4 unit tests + a monorepo smoke session
(`test-project-mono/`). 38/38 tests green; smoke green.

Scope note vs. original wording: the tool reports cross-package *coupling* (the
raw signal) rather than judging calls "illegal" against a declared dependency
policy — `composer.zig` does not yet parse `require`/package `name`, so a
policy check would be guesswork. That classification is a clean follow-on once
require-parsing lands; the agent can already diff `dependencies` output against
composer `require` itself.

### Goal 1.1 (original spec) — Port + expose `dependencies` (boundary) tool
**What:** Port `boundary_analyzer.zig` onto the current `ProjectIndex` and expose
as an MCP tool: given changed files or a package, return illegal cross-package
calls + the API surface used, **with per-finding confidence/resolution caveats**
(leveraging 0.1/0.2 so it never silently under-reports).
**Quantifiable acceptance:**
- New MCP tool returns JSON: `{cross_package_calls[], api_surface_used[],
  caveats}`; each finding carries `resolution` + `is_test`.
- `exclude_tests` respected (production-caller findings only by default).
- ≥ 3 unit tests on a multi-package fixture (legal call, illegal cross-package
  call, test-only caller excluded).

### Goal 1.2 — Impact / public-surface tool ✅ DONE
**What shipped:** `impact(fqn)` in `src/boundary_analyzer.zig`, exposed as the MCP
`impact` tool. Given an FQN it returns external (cross-package) callers grouped by
package, an internal/cross-package caller breakdown, and a `risk` classification
(`public_api_low|public_api_medium|public_api_high` by cross-package fan-out;
`internal_only` when no cross-package callers). `exclude_tests` defaults true.
**Shape:** `{fqn, symbol_project, risk, summary{total_callers,
cross_package_callers, internal_callers, caller_packages}, caveats{
unresolved_same_name, exclude_tests}, groups[{project, is_cross_package,
caller_count, callers[{caller, file, line, is_test, confidence, arg_count}]}]}`,
plus `signature`, `call_site_arity`, and `breaking_change` (see follow-on below).
**Acceptance met:**
- Returns callers grouped by package + a risk verdict enum. ✅
- Unit test `impact: cross-package caller grouped and counted` (analyzer side). ✅
- Smoke `impact` session on the monorepo fixture asserts `symbol_project=alpha`,
  `risk=public_api_low`, 1 cross-package caller `Beta\Consumer::run`. ✅
- `zig build test --summary all` → 40/40; `bash scripts/mcp_smoke.sh` → passed.

**Follow-on (Goal 1.2) — signature-aware `impact` ✅ DONE.** The fan-out `risk`
verdict is now joined by real signature data so the agent can answer "if I change
this signature, who breaks?" with evidence:
- `EnhancedFunctionCall.arg_count` records the positional argument count at each
  call site (`countCallArgs` in `src/call_analyzer.zig`, applied to member,
  static, and free-function calls).
- `BoundaryAnalyzer.lookupSignature` resolves the target's declared arity from
  the symbol table → `signature{total_params, required_params, optional_params,
  has_variadic}` (a variadic tail or a defaulted param counts as optional).
- `ImpactResult` now carries `signature`, `min_caller_args`, `max_caller_args`;
  the MCP renderer emits `signature`, `call_site_arity{min,max}`, per-caller
  `arg_count`, and `breaking_change` verdicts (`add_required_param`,
  `remove_trailing_param` — judged `safe` only when no observed call site fills
  the last positional slot and there is no variadic tail — `add_optional_param`,
  `make_param_optional`).
- Unit test `impact: signature arity + call-site arg counts captured`; smoke
  single-project guard asserts `signature.required_params` and `arg_count`.

---

## Milestone 2 — Resolution accuracy & coverage (P1/P2)

### Goal 2.1 — DI-aware resolution (phased) — Phase A ✅ DONE
**Phase A shipped (single-implementor interface binding).** While implementing it
we found the real reason resolution sat so low: **property-typed instance calls
were not resolving at all**, because (a) constructor-promoted parameters were
never registered as properties, and (b) property/param/return types were stored
as short names, not FQCNs, so they never matched symbol-table keys. Both are now
fixed, which is the bulk of the win.

**What shipped:**
- `src/symbol_collector.zig`:
  - `parseTypeNode` now FQCN-resolves class-like base types via the file's
    namespace + `use` statements (builtins/`self`/`static`/`parent` untouched).
  - Constructor property promotion (`__construct(private readonly Foo $foo)`) now
    registers `$this->foo` as a real property.
- `src/symbol_table.zig` (`ResolvedView`): builds an interface→single-implementor
  index (`iface_single_impl`), following sub-interface `extends`; exposes
  `singleImplementor(iface)`. Interfaces with ≥2 implementors are left ambiguous.
- `src/type_resolver.zig`: `resolveMethodCall` returns `MethodResolution{method,
  binding}` (binding kind; see Phase B); falls back to the sole implementor when
  the declared type is an interface with no direct method match.
- `src/call_analyzer.zig`: DI-bound edges are tagged
  `resolution_method = .interface_single_impl` with confidence `0.6` (real but
  inferred), distinct from `1.0` concrete resolution.

**Quantified delta (recorded):** on `test-project/`, instance-call resolution
went from **0% (all name-bridged/unresolved)** to **100% (21/21 edges resolved,
0 unresolved)** in the `load_project` priming payload. The full interprocedural
chain `DeepCaller::process → MiddleService → InnerService → Logger::log` now
resolves (previously invisible). A new single-implementor interface call
(`SignupService::register → EmailNotifier::send`) resolves via DI binding.

**Tests (43/43, +3):**
- `DI-aware: interface-typed property resolves to single implementor`
- `DI-aware: interface with two implementors stays unresolved (ambiguous)`
- `constructor-promoted property resolves a concrete method call`
- Fixtures added: `test-project/src/Notify/{NotifierInterface,EmailNotifier,
  SignupService}.php`.
- `zig build test --summary all` → 43/43; `bash scripts/mcp_smoke.sh` → passed
  (smoke updated: resolution-rate trust-signal assertion; the per-reason
  "unresolved breakdown" line is now correctly absent at 100%).

### Goal 2.1 — DI-aware resolution — Phase B ✅ DONE
**Phase B shipped (services.yaml interface→concrete bindings).** Phase A left the
multi-implementor case ambiguous because the *choice* of implementation lives in
the DI container, not the type system. Phase B reads that config.

**What shipped:**
- `src/di_config.zig` (new): a tolerant, indentation-aware `services.yaml`
  scanner that extracts the three *global* Symfony binding forms —
  (1) top-level service aliases `App\Iface: '@App\Impl'`, (2) long-form
  `alias:`, (3) `_defaults.bind` typed entries (`App\Iface [$var]: '@App\Impl'`).
  Per-service `arguments:`/`bind:` and untyped `$var` keys are deliberately
  ignored (call-site-scoped, not global). FQCNs are normalized (leading `\`
  stripped). 6 unit tests.
- `src/symbol_table.zig` (`ResolvedView`): new `explicit_bindings` map +
  `addExplicitBinding`/`explicitImplementor`; `addExplicitBinding` drops bindings
  whose concrete isn't in-project, so no false edges. `SymbolTable.explicitBinding`
  delegate.
- `src/type_resolver.zig`: `MethodResolution.binding: BindingKind` (`direct` |
  `di_config` | `single_impl`); `resolveMethodCall` consults the explicit binding
  *before* the single-implementor heuristic (config is authoritative).
- `src/call_analyzer.zig`: DI-config edges tagged
  `resolution_method = .di_config_binding`, confidence `0.85` (config-authoritative,
  above single-impl's `0.6`, below concrete `1.0`).
- `src/project_index.zig`: a Tier-1 `di_yaml` cache; `discoverDiConfigs` walks
  each project root for `services.ya?ml` (skips vendor/.git/node_modules/var);
  `loadDiBindings` parses + registers bindings between the resolved-view build
  and call analysis. In-memory test builds inject yaml via `.yaml`/`.yml` paths.
- `src/mcp_server.zig`: `load_project` priming payload reports DI-aware edge
  counts (`via services.yaml bindings` / `via single-implementor`) and the
  explicit-binding/config-file counts.

**Acceptance met:**
- Multi-implementor interface resolves via config: unit test `DI-aware Phase B:
  services.yaml binding resolves a multi-implementor interface` (edge resolves to
  the bound concrete, tagged `di_config_binding`). ✅
- Config wins over single-impl heuristic: `DI-aware Phase B: explicit binding
  overrides the single implementor` (via `_defaults.bind`). ✅
- No false edges to unknown concretes: `DI-aware Phase B: binding to an unknown
  concrete is ignored` (call stays unresolved). ✅
- End-to-end on disk: `test-project/config/services.yaml` binds the now-ambiguous
  `Test\Notify\NotifierInterface` (two implementors) to `SmsNotifier`; smoke
  asserts `SignupService::register → SmsNotifier::send` at confidence 0.85.
- `zig build test --summary all` → 60/60; `bash scripts/mcp_smoke.sh` → passed.

### Goal 2.2 — Finish symfony-events plugin ✅ DONE
**What shipped (all in `src/plugins/symfony_event_plugin.zig`):**
- **Attribute-argument parsing** (new lexical helpers): `attributeArgs` extracts
  the `(...)` arg list for a named attribute; `namedArgClassLike` reads a
  `name: Foo::class` or `name: 'Foo\Bar'` class reference; `namedArgString` reads
  a quoted value; with `matchParen`/`unquote`/`namedArgRaw` support. Region
  helpers `classAttributeRegion`/`methodAttributeRegion` bound the scan to one
  declaration so attributes never leak across neighbours.
- **Class- and method-level `#[AsMessageHandler(handles:, method:)]`** named args
  (this session's gap): a class-level attribute with `handles:`+`method:` now
  routes the message to the *named* method (not just `__invoke`), and a
  method-level `handles:` overrides the first-parameter inference. Duplicate
  emission for the named method is suppressed.
- **`#[AsEventListener(event:, method:)]`** (Symfony 6.1+): new
  `buildEventListenerMappings`, wired into `analyze()`, handling class-level
  (defaults to `__invoke`) and method-level (event from `event:` or first-param
  type) listeners.
- **FQN-string `getSubscribedEvents` keys** (soft-dependency pattern):
  `extractMappingsFromSource` gained a second pass matching
  `'App\Event\Foo' => 'onFoo'` (and `=> ['onFoo', 10]`), restricted to quoted
  keys containing a namespace separator so plain event-name strings
  (`'kernel.request'`) are not misread as classes.

**Tests (48/48, +5):**
- Pure: `attributeArgs + named-arg extraction (AsMessageHandler handles/method)`,
  `named arg accepts class-string form and ignores :: scope operator`,
  `extractMappingsFromSource handles FQN-string keys (soft dependency)`.
- End-to-end (synthetic edges via `createInMemoryWithConfigsForTest` with the
  plugin enabled): `symfony-events: class-level #[AsMessageHandler(handles:,
  method:)]`, `symfony-events: #[AsEventListener(event:, method:)]`.
- `zig build test --summary all` → 48/48; `bash scripts/mcp_smoke.sh` → passed.

### Goal 2.3 — `references` (rename blast radius) tool ✅ DONE
**What shipped:**
- New `src/references.zig`: a target-scoped AST reference collector. Given a
  class FQN it walks each cached tree and records *non-call* occurrences — type
  hints (`named_type`), `new`, `extends`/`implements`, `::class`, other static
  refs (`Foo::CONST`/`Foo::method()` scope), `use` imports, and exact-FQN string
  literals. Every occurrence is resolved to an FQCN via the file's namespace +
  `use` table, so the **sibling-namespace twin is never matched**. Collection is
  target-scoped (no global occurrence index to store/invalidate) and uses a
  scratch arena for transient allocations.
- `ProjectIndex.collectReferences(allocator, fqn)` iterates `file_order` and
  returns matches ordered by file then line.
- MCP `references` tool in `src/mcp_server.zig`: `{fqn}` → `{fqn, summary{total,
  files, by_kind{...}}, references[{kind, file, line, column}]}` with a per-kind
  histogram; tolerates a leading backslash; registered in the tool list and
  priming payload.

**Acceptance met:**
- FQN-scoped, sibling-twin non-match: unit test `references: FQN-scoped,
  sibling-namespace twin is never matched` (two `Bar` classes in distinct
  namespaces; each consumer resolves only to its own). ✅
- Coverage of kinds: unit test `references: extends, implements, static ref, and
  string literal`. ✅ (≥2 tests; both end-to-end via `createInMemory`.)
- Smoke: `references` session asserts `Test\Logger` has ≥6 occurrences with
  `type_hint`≥5 and `use_import`≥1.
- `zig build test --summary all` → 50/50; `bash scripts/mcp_smoke.sh` → passed
  (tools/list now expects 6 tools).

---

## Execution order

Milestone 0 (0.1 → 0.2 → 0.3 → 0.4) first — small, independent, trust-critical.
Then Milestone 1, then Milestone 2. Each goal: implement → `zig build test` →
update `scripts/mcp_smoke.sh` where the surface changed.

---

## Post-merge integration (Phase 2–4): analyzer tools over the unified index

After merging the upstream analysis engine into the MCP branch, the index
pipeline was unified (Phase 2) and the remaining CLI analyzers were exposed as
MCP tools (Phase 3), then wired into the repo's workflows (Phase 4).

**Phase 2 — one index path.** `ProjectIndex.buildDerived` now injects the
framework API stub catalog (`framework_stubs.registerFrameworkStubs`) and builds
the legacy inheritance view (`SymbolTable.resolveInheritance`, populating
`ClassSymbol.all_methods`/`all_properties`) alongside the Tier‑2 `ResolvedView`.
One index feeds both the MCP tools and the CLI; MCP gains framework‑stub +
DI‑aware resolution for free. A `register_stubs` flag keeps the pure in‑memory
call‑graph unit tests stub‑free for deterministic counts. (Parallelism is *not*
folded into `ProjectIndex` yet — behavior first, parallelism second.)

**Phase 3 — analyzers as MCP tools.** Six thin handlers were added to
[`src/mcp_server.zig`](../src/mcp_server.zig), each building its analyzer
directly on the loaded `ProjectIndex` (no re‑parse) and rendering JSON with the
same trust metadata the other tools expose (`resolution_rate`, `is_test`,
explicit caveats):

- `check_dead` — whole‑program liveness sweep (`dead_code`); caveats surface
  `resolution_rate` and `kept_alive_by_unresolved` so a low‑resolution graph is
  never mistaken for a delete list.
- `check_types` — cross‑project type violations at resolved call sites
  (`type_violation_analyzer`).
- `check_boundaries` — monorepo boundary verdict (`boundary_analyzer`): totals,
  exposed API surface, per‑pair dependency edges.
- `null_safety` — intraprocedural nullable‑dereference check (`null_safety`).
- `return_types` — CFG‑based return‑type conformance (`return_type_checker`);
  unresolved returns count as *uncertain*, never *failed*.
- `report` — unified health report (`report.UnifiedReport`). `report.zig` gained
  a writer‑based `writeJson` so the MCP payload is **byte‑identical** to
  `phpcma report --format json` (the Phase‑4 golden check).

The graph‑quality‑sensitive tools (`null_safety`, `return_types`, `report`) are
deliberately the last to land, after stubs + DI resolution are active, per the
correctness gate (*a confidently‑wrong answer is the worst outcome*).

**Phase 4 — workflows.** `scripts/mcp_smoke.sh` drives all sixteen tools over a
stdio session and golden‑checks `report` == CLI `report --format json`. It is in
the [AGENTS.md](../AGENTS.md) commit gate and runs as the `mcp-smoke` CI job
(`.github/workflows/ci.yml`). Bug fixed en route: a use‑after‑free in
`framework_stubs` (stub method `parameters` slices pointed at stack‑temporary
array literals) — made `comptime` so they get static lifetime.
