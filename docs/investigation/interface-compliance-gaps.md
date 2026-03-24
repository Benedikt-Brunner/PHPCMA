# Interface Compliance Gaps Investigation

## Scope

This investigation traces how interface compliance is currently checked in `check-types` (`src/type_violation_analyzer.zig`) and explains why injected interface signature violations can be missed.

The specific violation shape tested was:

- Interface method: `generateSnapshots(array $entities): array`
- Implementation method: `generateSnapshots(array $entities, bool $includeMeta): string`

## Code Path Trace

1. `TypeViolationAnalyzer.analyze()` runs boundary analysis first, then only analyzes `boundary_result.boundary_calls` (`src/type_violation_analyzer.zig:139-150`).
2. For each boundary call, `checkCallSite()` resolves the called method and then calls `checkInterfaceCompliance()` (`src/type_violation_analyzer.zig:180-237`).
3. `checkInterfaceCompliance()` compares return type, parameter count, and parameter types only for the *called method* (`src/type_violation_analyzer.zig:491-590`).
4. `BoundaryAnalyzer` only emits boundary calls when a call has `resolved_target` and the callee maps to a class/function project (`src/boundary_analyzer.zig:140-143`).
5. Method resolution ultimately goes through `SymbolTable.resolveMethod()`, which only resolves classes, not interfaces (`src/type_resolver.zig:444-469`, `src/symbol_table.zig:111-123`).

## Root Cause Analysis

1. Interface compliance is call-site driven, not declaration driven.
Only methods that appear in cross-project resolved call sites are validated. If no one calls the violating method, no interface mismatch is checked.

2. Same-project interface implementations are explicitly skipped.
`checkInterfaceCompliance()` ignores interface/class pairs when both belong to the same project (`src/type_violation_analyzer.zig:507-513`). This drops real violations when callers are cross-project but the interface and implementation live together.

3. Interface-typed calls are dropped before compliance checks run.
Calls on variables typed as interface frequently do not resolve to a concrete class method, so they never become boundary calls. Since analyzer traversal starts from boundary calls, compliance checks never execute for those paths.

4. Reporting counters are misleading and mask failures in downstream consumers.
`total_violations` and `cross_project_calls` are computed after `toOwnedSlice()` drains the source list, so they are often reported as `0` even when errors are present (`src/type_violation_analyzer.zig:168-175`, `src/boundary_analyzer.zig:275-282`). This can cause "all pass" summaries if tooling trusts totals instead of `error_count` / `violations.len`.

## Injected Violation Results

All scenarios were executed via:

```bash
./zig-out/bin/PHPCMA check-types --config <fixture>/.phpcma.json
```

Fixtures were created under `/tmp/phpcma-interface-gaps`.

1. `case-a-control-detects` (cross-project interface + direct call to violating method)
Observed: return-type mismatch and parameter-count mismatch were detected.

2. `case-b-no-callsite` (same violation exists, but only non-interface method is called)
Observed: no interface mismatch reported.
Expected: declaration mismatch should still be flagged.

3. `case-c-same-project-interface` (interface and implementation in same project, cross-project caller)
Observed: argument-count violation at callsite is reported, but no interface mismatch is reported.
Expected: interface mismatch should be flagged.

4. `case-d-interface-typed-call` (caller depends on interface type)
Observed: no interface mismatch reported.
Expected: implementation mismatch should still be discoverable.

## Proposed Fixes

1. Add a declaration-level interface compliance pass.
Iterate all classes that implement interfaces and compare signatures regardless of whether methods are called. Keep boundary-call checks for callsite-type issues, but make interface compliance independent.

2. Make same-project interface checks configurable or enabled by default.
Replace the hard skip on same-project interface/class pairs with a mode flag (for example, `--interface-scope=all|cross-project`), defaulting to `all` for correctness.

3. Improve resolution for interface-typed calls.
Allow method resolution and project mapping to understand interface symbols (or at minimum keep unresolved interface calls in a separate bucket that still triggers declaration-level checks).

4. Fix summary counters.
Capture counts before `toOwnedSlice()` (or derive from final owned slices) so totals reflect actual results.

5. Add regression tests for all four scenarios above.
Include "should fail but currently passes" tests and convert them to strict assertions once implementation is fixed.
