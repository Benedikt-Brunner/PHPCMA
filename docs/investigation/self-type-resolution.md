# Investigation: `self` Type Resolution in `check-types`

## Summary

`check-types` currently carries `self`/`static`/`parent` through argument inference without concretizing them to a class FQCN in expression context. This reaches cross-project argument compatibility checks as raw `"self"`, which then mismatches concrete class parameter types and produces false positives (reported: 76).

The best place to resolve these special types is **during expression type resolution in call analysis** (`type_resolver.zig` used by `call_analyzer.zig`), not during symbol collection and not only in final type checking.

## Root Cause

The failure path is:

1. Symbol collection parses native/PHPDoc types with `phpdoc.parseTypeString` and preserves special kinds (`.self_type`, `.static_type`, `.parent_type`) from declarations.
2. In call analysis, `TypeResolver.resolveMethodCallType` and `TypeResolver.resolveStaticMethodCallType` return `method.effectiveReturnType()` directly.
3. `CallAnalyzer.resolveArgumentTypes` stores those inferred argument types as-is in `call.argument_types`.
4. `TypeViolationAnalyzer.checkArgumentTypes` compares argument vs parameter via `isTypeCompatible`, primarily by `base_type` string equality and class lookup.
5. `arg_type.base_type == "self"` is not compatible with a concrete FQCN parameter (for example `ShipmentsOperationResult`) and is flagged as a hard error.

So the key issue is **special type metadata survives too long without context-sensitive concretization**.

## Affected Code Paths

- `src/main.zig` (`check-types` pipeline)
  - Pass 4: `parallelCallAnalysis`
  - Pass 5: `TypeViolationAnalyzer.analyze`
- `src/type_resolver.zig`
  - `resolveMethodCallType` (returns `method.effectiveReturnType()` directly)
  - `resolveStaticMethodCallType` (same)
- `src/call_analyzer.zig`
  - `resolveArgumentTypes` (records unresolved special types into call graph)
- `src/type_violation_analyzer.zig`
  - `checkArgumentTypes`
  - `isTypeCompatible`

## Where Resolution Should Happen

### Option A: Symbol Collection (not recommended)

Resolving `self` to FQCN while collecting symbols would over-eagerly erase semantic intent.

- `self` and `parent` depend on declaring context.
- `static` uses late static binding semantics.
- Trait-related behavior is context-sensitive at use site.

Global, one-time concretization in symbol collection risks encoding the wrong class identity and losing useful original type intent.

### Option B: Type Checker Only (insufficient alone)

Type checking has partial context (`caller_fqn`, `callee_fqn`) but not reliable provenance for every argument expression’s originating method/type context.

It can normalize some parameter-side cases, but argument-side `self` derived from nested/chained expressions is already lossy by this stage.

### Option C: Call Analysis / Type Resolver (recommended)

Expression resolution has the right local context at the right time:

- It knows the resolved method symbol and its `containing_class`.
- It knows current class context for static/self/parent references.
- It is exactly where argument types are inferred before persisting to the call graph.

## Proposed Fix Approach

1. Add a helper in `TypeResolver` to concretize special types in a given class context (for example, `concretizeSpecialType(type_info, context_class_fqcn)`).
2. Call it when returning method/static-call return types:
   - `resolveMethodCallType`: use resolved method’s `containing_class` as context.
   - `resolveStaticMethodCallType`: use resolved static target class context.
3. Ensure `parent` maps to the class’s `extends` where available.
4. Apply recursively for compound types (`nullable`, `union`, `intersection`, `generic`) so `self|nil`-style declarations are handled consistently.
5. Keep symbol table declarations unchanged (still store special kinds), and materialize only when deriving expression/call-site types.
6. Optional defense-in-depth: add lightweight normalization in `TypeViolationAnalyzer` for callee parameter-side `self`/`parent`.

## Estimated Complexity

**Medium**.

- Core implementation: 0.5 to 1 day.
- Additional tests and stabilization: 0.5 day.

Total expected effort: **1 to 1.5 days** including tests.

## Suggested Regression Tests

1. `CallAnalyzer`/`TypeResolver`: method returning `self` passed as argument to method expecting concrete class should infer concrete FQCN argument type.
2. `TypeResolver`: static call returning `self`/`parent` resolves to expected concrete class in context.
3. `TypeViolationAnalyzer`: no false positive for `self`-origin argument where concrete class compatibility exists.
4. Compound types containing `self` (nullable/union) remain compatible where expected.
