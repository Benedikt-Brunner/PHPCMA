# Null Safety Integration Investigation

## Scope

Investigate why `PHPCMA report` in monorepo mode can show `null_safety: pass=0, fail=0, unchecked=41` even though `src/null_safety.zig` exists, and document what is currently wired versus missing.

## Current Wiring (What Runs Today)

### CLI Path For `report`

`report` is wired to `analyzeReport()` in `src/main.zig`.

`analyzeReport()` currently does this:

1. Discovers files from either `--config` (monorepo) or `--composer` (single project).
2. Builds symbol table via `parallel.parallelSymbolCollect`.
3. Resolves inheritance.
4. Builds call graph via `parallel.parallelCallAnalysis`.
5. Builds `UnifiedReport` and calls `unified_report.populate(&sym_table, &call_graph)`.

There is no null-safety pass in this pipeline.

### Where Null Safety Numbers Come From

`UnifiedReport.populateTypeChecks()` in `src/report.zig` currently fills the "Null safety" row from call resolution metadata:

- If `call.resolved_target != null` and `call.resolution_method == .unresolved`, it increments `type_checks.null_safety.unchecked`.
- It does not invoke `NullSafetyAnalyzer`.

So the current "Null safety" field is not a null-dereference analysis result; it is a derived count from call-resolution classification.

### Status Of `src/null_safety.zig`

`NullSafetyAnalyzer` exists and has unit tests in `src/null_safety.zig`, but it is not imported or called from `src/main.zig`, `src/parallel.zig`, or `src/report.zig` execution paths.

In other words: the module is implemented but not integrated into production CLI commands.

## What Is Missing

1. A pipeline stage that executes `NullSafetyAnalyzer` across discovered files for `report` (and optionally `check-types`).
2. Aggregation logic that maps `NullAnalysisResult` into report counters and violations.
3. A data model connection between null-safety findings and `UnifiedReport.violations` output formats (text/json/sarif/checkstyle).
4. Removal/replacement of the placeholder metric in `populateTypeChecks()` that currently uses `ResolutionMethod.unresolved` as a stand-in for null safety.

## Why `unchecked=41` Happens

The `41` value is not "41 null checks evaluated and left unknown."

It means there are 41 call edges where:

- the call had a resolved target, but
- call-resolution method remained `.unresolved`.

`populateTypeChecks()` treats that pattern as `null_safety.unchecked += 1`.

This can happen because `CallAnalyzer.determineResolutionMethod()` returns `.unresolved` for object expression shapes it does not explicitly classify (it only has specific cases like `$this`, variable, `new`, member access/call). If target resolution still succeeds, those calls become "resolved target + unresolved method," which are currently counted as null-safety unchecked.

So `unchecked=41` is a call-resolution classification artifact, not output from null-dereference analysis.

## Proposed Integration

### Phase 1: Wire Null Safety Into `report`

1. Add a new pass in `analyzeReport()` after symbol collection and inheritance resolution that runs `NullSafetyAnalyzer` per file.
2. Reuse existing per-file sources/contexts (`file_sources`, `file_contexts`) and parse trees similarly to `parallelCallAnalysis`.
3. Aggregate per-file results into a `NullSafetySummary`:
   - `pass += guarded_accesses`
   - `fail += unguarded_accesses` (or `violations.len` if kept equivalent)
   - `unchecked += unresolved/unsupported cases` (explicitly defined, not inferred from call resolution)
4. Add each null-safety violation into `UnifiedReport.violations` with category like `null-safety` and severity mapped from `NullSeverity`.

### Phase 2: Replace Placeholder Metric

1. Remove this mapping in `populateTypeChecks()`:
   - `ResolutionMethod.unresolved -> null_safety.unchecked`
2. Keep unresolved call-resolution accounting under call/type resolution checks only (for example call-site unchecked), not null safety.

### Phase 3: Coverage And Regression Tests

1. Add report-level test(s) proving null-safety counts come from `NullSafetyAnalyzer` outputs.
2. Add a monorepo fixture test with nullable dereference examples across project boundaries.
3. Ensure report JSON/SARIF emit expected null-safety violations.

## Practical Outcome

After integration, `null_safety` in reports will reflect actual null-dereference analysis (guards, violations, unresolved analysis cases), and values like `unchecked=41` will no longer be inflated by unrelated call-resolution metadata.
