# Return Type Checker Integration Investigation

## Scope

Investigate why unified report output can show `return_types: pass=0, fail=0, unchecked=0` in monorepo mode, and determine whether `src/return_type_checker.zig` is wired into `report` or `check-types` command paths.

## Command Path Trace

### `report` Command (`main.zig`)

1. CLI command wiring points `report` to `analyzeReport` (`src/main.zig`, command registration around lines 993-1029).
2. `analyzeReport` builds analysis data in this order:
   - parse config/composer and discover files
   - symbol collection (`parallel.parallelSymbolCollect`)
   - inheritance resolution (`sym_table.resolveInheritance`)
   - call analysis (`parallel.parallelCallAnalysis`)
   - unified report generation (`unified_report.populate(&sym_table, &call_graph)`)
3. There is no import or invocation of `return_type_checker.zig` in this flow.

### `check-types` Command (`main.zig`)

1. CLI command wiring points `check-types` to `analyzeCheckTypes` (`src/main.zig`, command registration around lines 950-990).
2. `analyzeCheckTypes` performs the same data setup stages (config -> symbols -> inheritance -> calls), then runs:
   - `type_violation_analyzer.TypeViolationAnalyzer.analyze()`
3. This analyzer focuses on cross-project call-site and API-surface violations. It does not run method-body return-statement verification from `ReturnTypeChecker`.

### `return_type_checker.zig`

1. `src/return_type_checker.zig` defines `ReturnTypeChecker` and tests.
2. Repository-wide search shows no production imports of `return_type_checker.zig`.
3. The checker is compiled and exercised only in its dedicated unit test target (`build.zig`, return type test step around lines 254-275).

## Current Wiring Status

1. **Not wired into monorepo pipeline**: `report --config` and `check-types --config` do not invoke `ReturnTypeChecker`.
2. **Not wired into single-project pipeline**: `report --composer` also does not invoke it.
3. **Not wired into single-file CLI path**: `analyzeFile` does not invoke it either.
4. **Only present in tests**: checker behavior is validated in unit tests but not connected to user-facing commands.

## Why `return_types` Can Stay Zero In Report Output

`UnifiedReport.populateTypeChecks` (`src/report.zig`) does not consume `ReturnTypeChecker` diagnostics. It increments `type_checks.return_types.pass` only when a call edge has resolution method `.return_type_chain`.

Implications:

1. `return_types.fail` is never incremented in current report population logic.
2. `return_types.unchecked` is not tied to method-level return verification and can stay zero.
3. If no calls are resolved via `.return_type_chain`, `return_types.pass` also remains zero.

So the report's "Return types" row is currently a call-resolution heuristic bucket, not return-statement correctness verification.

## What's Missing

1. A production integration point that executes `ReturnTypeChecker` during command execution.
2. Mapping from checker diagnostics/stats into report schema (`pass/fail/unchecked` and optional violation list entries).
3. Output surfacing in `report` and optionally `check-types` JSON/text output.
4. Tests that cover end-to-end command behavior (not only checker unit tests).

## Proposed Integration Approach

## Phase 1: Integrate into `report`

1. Add a dedicated return-check pass in `analyzeReport` after symbol collection/inheritance and before final output.
2. Implement a helper that:
   - parses each file source into a tree
   - finds methods from `sym_table` by file
   - runs `ReturnTypeChecker.analyzeMethod(...)`
   - aggregates summary counts and diagnostics
3. Extend `UnifiedReport` population to accept these aggregated results and fill:
   - `type_checks.return_types.pass`
   - `type_checks.return_types.fail`
   - `type_checks.return_types.unchecked`
4. Optionally emit checker diagnostics into `UnifiedReport.violations` with a category like `return-type-mismatch`.

## Phase 2: Decide `check-types` Scope

1. Keep `check-types` focused on cross-project interface/call-site constraints, and leave return-statement validation to `report`.
2. Or add `--include-return-checks` flag to `check-types` if a combined gate is desired.

## Phase 3: Testing and Performance

1. Add integration tests for `analyzeReport` proving non-zero return-type counters for seeded fixtures.
2. Add regression tests for cases with mismatches, missing returns, nullable handling, and void-with-value.
3. For monorepo performance, parse files once per pass and reuse discovered sources where possible.

## Recommended Minimum Fix

If the goal is to make report output truthful with minimal scope:

1. Wire `ReturnTypeChecker` into `analyzeReport` only.
2. Feed checker result directly into `UnifiedReport.type_checks.return_types`.
3. Leave `check-types` unchanged for now and document that it is boundary-focused.

This resolves the current mismatch where return-type checker code exists but report metrics do not reflect it.
