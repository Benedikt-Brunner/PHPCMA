# PHPCMA Analysis Engine — Gap Assessment

## Executive Summary

PHPCMA is a Zig-based static analysis engine for PHP codebases. It provides
call-graph resolution, type checking, interface compliance verification, return
type checking, and null safety analysis. When run against a real-world monorepo
(a real-world monorepo with 4096 files, 16 290 methods), several gaps emerge:

- **Call resolution rate is 31.4%** — 68.6% of calls are unresolved, dominated by
  untyped variable methods (48.9%) and missing framework API stubs (35.8%).
- **Self/static/parent types produce 76 false positives** in type checking because
  special types are not concretized to concrete FQCNs during expression inference.
- **Interface compliance checking is call-site-driven only** — violations are missed
  when no cross-project call site exists for the violating method, and same-project
  interface/class pairs are explicitly skipped.
- **Return type checker is not wired** into any CLI command; report metrics reflect
  call-resolution heuristics, not method-body return-statement verification.
- **Null safety analyzer is not wired** into any CLI command; report metrics reflect
  call-resolution classification artifacts, not null-dereference analysis.

**Performance baseline**: ~300 ms wall clock for 4096-file monorepo analysis.

## Per-Gap Findings

### 1. Call Resolution Rate (68.6% Unresolved)

**Bead**: ph-19f · **Doc**: `resolution-rate-analysis.md`

**Baseline**: 43 987 total calls, 13 830 resolved (31.4%), 30 157 unresolved (68.6%).

**Unresolved category breakdown**:

| Category | Count | % of Unresolved | Max Uplift |
|----------|------:|----------------:|-----------:|
| Untyped variable method calls | 14 774 | 48.9% | +33.6 pp |
| Framework external APIs (Shopware/Symfony/Doctrine) | 10 834 | 35.8% | +24.6 pp |
| Closure/collection pipelines | 2 749 | 9.1% | +6.2 pp |
| Global/builtin functions | 1 651 | 5.5% | +3.8 pp |
| DI container / service locator | 142 | 0.5% | +0.3 pp |
| Dynamic dispatch | 81 | 0.3% | +0.2 pp |

**Root cause**: The type resolver lacks local type propagation for untyped
variables and has no framework API stub catalog. Together these two categories
account for 84.7% of unresolved calls.

### 2. Self-Type Resolution (76 False Positives)

**Bead**: ph-als · **Doc**: `self-type-resolution.md`

**Problem**: `self`/`static`/`parent` types survive expression inference as raw
strings and reach cross-project argument compatibility checks, where
`"self" != "ConcreteClassName"` is flagged as a type error.

**Root cause path**:
1. Symbol collection preserves `.self_type`/`.static_type`/`.parent_type` kinds.
2. `TypeResolver.resolveMethodCallType` returns `effectiveReturnType()` without
   concretizing specials.
3. `CallAnalyzer.resolveArgumentTypes` stores raw special types in call graph.
4. `TypeViolationAnalyzer.isTypeCompatible` does string equality → mismatch.

**Recommended fix**: Add `concretizeSpecialType(type_info, context_class_fqcn)`
in `TypeResolver`, called when resolving method/static-call return types. Apply
recursively for compound types (nullable, union, intersection, generic).

**Estimated effort**: 1–1.5 days.

### 3. Interface Compliance Gaps

**Bead**: ph-z5o · **Doc**: `interface-compliance-gaps.md`

**Problem**: The checker reported 9 643 passes and 0 fails, yet deliberately
injected violations (return type change + extra parameter) were not detected.

**Root causes**:
1. **Call-site-driven only**: Only methods appearing in cross-project resolved
   call sites are validated. No-callsite violations are invisible.
2. **Same-project skip**: Interface/class pairs in the same project are
   explicitly skipped, even when cross-project callers exist.
3. **Interface-typed calls dropped**: Calls on interface-typed variables often
   fail to resolve to concrete methods, so they never become boundary calls.
4. **Counter bug**: `total_violations` and `cross_project_calls` are computed
   after `toOwnedSlice()` drains the source, reporting 0 even when errors exist.

**Recommended fix**: Add a declaration-level interface compliance pass that
iterates all implementing classes regardless of call sites. Remove or make
configurable the same-project skip. Fix counter ordering.

### 4. Return Type Checker (Not Integrated)

**Bead**: ph-c9o · **Doc**: `return-type-checker-integration.md`

**Problem**: Report shows `return_types: pass=0, fail=0, unchecked=0`.
`ReturnTypeChecker` exists in `src/return_type_checker.zig` with unit tests but
is not imported or invoked from any CLI command (`report`, `check-types`,
`analyzeFile`).

**Current metric source**: `UnifiedReport.populateTypeChecks` increments
`return_types.pass` only when a call edge has resolution method
`.return_type_chain`. No method-body return-statement verification occurs.

**Recommended fix**: Wire `ReturnTypeChecker` into `analyzeReport` as a
dedicated pass after symbol collection. Map checker diagnostics into
`UnifiedReport.type_checks.return_types` and optionally into violations.

### 5. Null Safety Analyzer (Not Integrated)

**Bead**: ph-2jz · **Doc**: `null-safety-integration.md`

**Problem**: Report shows `null_safety: pass=0, fail=0, unchecked=41`.
`NullSafetyAnalyzer` exists in `src/null_safety.zig` with unit tests but is not
imported or invoked from any CLI command.

**Current metric source**: The `unchecked=41` value comes from call edges where
`resolved_target != null` but `resolution_method == .unresolved` — a
call-resolution classification artifact, not null-dereference analysis.

**Recommended fix**: Wire `NullSafetyAnalyzer` into `analyzeReport` as a
dedicated pass. Replace the placeholder metric in `populateTypeChecks` with
actual analyzer output. Map `NullAnalysisResult` into report counters.

## Prioritized Fix Roadmap

| Priority | Gap | Estimated Effort | Impact |
|:--------:|-----|:----------------:|--------|
| **P0** | Self-type concretization | 1–1.5 days | Eliminates 76 false positives in type checking; prerequisite for trustworthy violation reports |
| **P1** | Interface compliance: declaration-level pass | 2–3 days | Catches real contract violations currently invisible; fixes counter bug |
| **P1** | Return type checker integration | 1–2 days | Enables method-body return verification; makes report metrics truthful |
| **P1** | Null safety analyzer integration | 1–2 days | Enables null-dereference detection; makes report metrics truthful |
| **P2** | Local type propagation for untyped variables | 3–5 days | +33.6 pp resolution rate uplift (largest single category) |
| **P2** | Framework API stub catalog (Shopware/Symfony/Doctrine) | 2–3 days | +24.6 pp resolution rate uplift |
| **P3** | Closure/collection type propagation | 2–3 days | +6.2 pp resolution rate uplift |
| **P3** | Builtin/global function signatures | 1 day | +3.8 pp resolution rate uplift |
| **P4** | DI container resolution | 1–2 days | +0.3 pp resolution rate uplift |

**Rationale**: P0/P1 items fix correctness — the engine produces wrong or
missing results. P2 items improve coverage for the two dominant unresolved
categories (84.7% combined). P3/P4 items address long-tail categories.

## Performance Baseline

| Metric | Value |
|--------|-------|
| Files analyzed | 4 096 |
| Methods discovered | 16 290 |
| Total calls | 43 987 |
| Wall clock time | ~300 ms |
| Calls resolved | 13 830 (31.4%) |

Performance is not currently a concern. The engine processes 4 096 files in
under a second. Integration of the unwired analyzers (return type checker, null
safety) will add per-method and per-file passes but should remain well within
acceptable bounds given the existing parallel infrastructure.

## Recommended Next Steps

1. **Fix self-type resolution first** (P0) — it is the most contained fix with
   immediate false-positive elimination. Unblocks trustworthy type-checking
   output.

2. **Wire return type checker and null safety analyzer** (P1) — these are
   straightforward integration tasks since the analyzers already exist with
   tests. Makes report output truthful.

3. **Add declaration-level interface compliance** (P1) — requires a new analysis
   pass but is well-scoped. Fix the counter bug in the same change.

4. **Tackle resolution rate** (P2) — start with local type propagation for
   untyped variables (largest bucket), then add framework stubs. These are
   larger efforts but provide the highest coverage uplift.

5. **Add integration tests** for all fixes — each investigation documented
   specific regression test scenarios that should be implemented alongside the
   fix.
