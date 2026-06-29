# PHPCMA — MCP Type Surface Spec

Status: **shipped** — all five tools and their prerequisite engine fixes have
landed: the shared type-resolution prereq, the interface-`extends` collection
fix, the class-modifier collection fix, the call-site arg-type/result-use
capture, and tools #1 (`describe_symbol`), #3 (`resolve_interface`), #2
(`find_by_type`), #4 (`check_conformance`), and #5 (type-aware `impact`).

**Shipped** (`zig build test` → 95/95; `scripts/mcp_smoke.sh` → passed):
- **Prereq fix** — `parseTypeNode` now FQCN-resolves union/intersection
  `type_parts` and array element types (via a new `resolveTypeToken` helper), so
  type-directed matching sees FQCNs, not file-local short names. Unit test
  `native union/intersection/array member types resolve to FQCNs`
  ([project_index.zig](../src/project_index.zig)). Also fixed latent 0.15-era
  dead code in `TypeInfo.format` (union/intersection branches) that this work
  first exercised.
- **Interface `extends` collection fix** — `handleInterface` now parses the
  interface `base_clause` (interfaces may extend several parents) into
  `InterfaceSymbol.extends`, FQCN-resolved, and sets start/end lines. Previously
  the parent list was always empty, which also weakened `resolveInterfaceMethod`
  for sub-interfaces and made transitive-implementor detection impossible.
- **Class-modifier collection fix** — `handleClass` now reads the
  `abstract_modifier` / `final_modifier` / `readonly_modifier` named children of
  `class_declaration` into `ClassSymbol.{is_abstract,is_final,is_readonly}`.
  These were always `false` before; `check_conformance` (#4) needs `is_abstract`
  to know an abstract class is not obligated to implement inherited abstract /
  interface methods.
- **Tool #1 `describe_symbol`** — resolved, inheritance-aware, typed view of a
  Class / Interface / Trait / `Class::method` / `Class::property` / function.
  Emits the `{native, phpdoc, effective}` type triad per field, `declared_in` +
  `inherited` for members, generics, `parent_chain`, and own-vs-inherited member
  lists (capped). 3 unit tests in [mcp_server.zig](../src/mcp_server.zig) + 2
  smoke assertions.
- **Tool #3 `resolve_interface`** — DI/wiring explainer. Forward (interface FQN):
  in-project `implementors` (direct + transitive via sub-interface `extends`) and
  the `binding` the resolver would pick (`di_config` 0.85 > `single_impl` 0.6 >
  `ambiguous` > `none`), reusing `ResolvedView.explicitImplementor` /
  `singleImplementor`. Reverse (class FQN): `implements`,
  `implements_in_project`, `is_di_bound_for`, `bound_kind`. 2 unit tests + 2
  smoke assertions (di_config win + reverse).
- **Tool #2 `find_by_type`** — type producer/consumer/holder index: navigate by
  type rather than by call. Producers (methods/functions returning the type),
  consumers (parameters typed as it), holders (properties typed as it), each with
  an FQCN-resolved `match` (via / param / position / `type_text` / native-vs-phpdoc
  `source`). Supports `roles`, `include_subtypes` (widens an interface/class to
  in-project subtypes via the implementor/extends graph), `namespace_prefix`,
  `exclude_tests`, and `limit`. 3 unit tests + 2 smoke assertions.
- **Tool #4 `check_conformance`** — contract conformance checker for a class.
  Collects contracts (implemented interfaces transitively via `extends`,
  including those introduced by ancestors, plus abstract methods inherited from
  the parent chain) and, per contract method, looks up the class's effective
  method via `ResolvedView.resolveMethod` to flag `missing_method`, `param_count`,
  `param_type_incompatible`, `return_type_incompatible`, `nullability_widened`
  (return covariance), and `visibility_narrowed`. Name-equality, not full LSP
  variance (caveat); `self`/`static`/`parent` types skipped; abstract classes are
  not flagged for unimplemented methods; a `__call`-declaring class downgrades
  `missing_method` to `severity:"info"`. `against` (all|interfaces|parent) and
  `include_ok` options. 4 unit tests + 1 smoke assertion.
- **Call-site arg-type / result-use capture (engine prereq for #5)** — the call
  analyzer now resolves each positional argument's type (`EnhancedFunctionCall
  .arg_types: []const ?TypeInfo`, null where unresolved) and classifies how the
  result is consumed (`result_used: ResultUse` = ignored | assigned |
  member_access | passed) at every member/static/function call site, via the
  existing `TypeResolver`. Both fields are folded into the `canonicalize`
  snapshot, so the `incremental == from-scratch` differential guarantee now
  covers them.
- **Tool #5 type-aware `impact`** — extends `impact` from arity-only to *type*
  edits. Every verbose caller now reports its observed `arg_types[]` and
  `result_used`. With `simulate`: `param_type_change {position, to}` checks each
  caller's argument type against `to` ∪ its in-project subtypes (reusing #2's
  match-set) → `verdict` breaking | safe | unknown with `{typed_args,
  total_call_sites}` coverage and `incompatible_call_sites[]`; `return_type_change
  {to}` flags callers that dereference (`member_access`) or forward (`passed`) the
  result in `risky_call_sites[]` (narrowing to `?T` newly requires a null check)
  → `verdict` risky | safe. Honest-by-construction: `safe` requires every call
  site typed and compatible, so a weakly-resolved graph yields `unknown`, never a
  false `safe`. 1 analyzer-level + 4 render unit tests + 2 smoke assertions. The
  MCP surface is now **10 tools** (`impact` extended in place).

This document specs five tools/extensions that expose PHPCMA's already-resolved
**type information** through the MCP surface. Today that information
(param/return/property types, nullability, unions, generics, interface→implementor
bindings, inheritance) is computed and used **internally** for call resolution
but is almost never surfaced to the agent (the `query` `nodes`/`edges`
projections carry no types; `impact` carries arity only). See the gap analysis
at the end of [mcp-iteration-plan.md](./mcp-iteration-plan.md).

The five items, ordered by value × cheapness:

| # | Tool | New analysis? | Effort | Backing data |
|---|------|---------------|--------|--------------|
| 1 | `describe_symbol` | none | Low | `SymbolTable` + `ResolvedView` (existing) |
| 2 | `find_by_type` | one read-only pass | Low–Med | `SymbolTable` symbols (existing) |
| 3 | `resolve_interface` | none | Low | `ResolvedView` binding indexes (existing) |
| 4 | `check_conformance` | signature comparison | Med | inheritance view + signatures (existing) |
| 5 | type-aware `impact` | **call-site arg-type capture** | High | needs new `EnhancedFunctionCall` fields |

Items 1–3 are pure reads over already-resolved data. Item 4 adds a comparison
pass. Item 5 requires engine work in `call_analyzer.zig`/`type_resolver.zig`.

---

## Conventions shared by all tools

- **Wiring:** each tool follows the existing pattern in
  [src/mcp_server.zig](../src/mcp_server.zig): a `buildXSchema(sa)` using
  `mcp.schema.InputSchemaBuilder` (methods available: `addString`, `addInteger`,
  `addBoolean`, `addEnum`, `*WithDefault`), an `xHandler(user_data, io,
  allocator, arguments)` that casts `user_data` to `*McpState`, guards
  `state.loaded`, parses args via `mcp.tools.getString/getInteger`, and a
  `renderX(...)` that emits JSON with the existing `appendJson` string emitter.
  Register with `server.addTool(.{...})` next to the other six.
- **FQN identity:** the stable node id is the FQCN (`App\Foo`) or member FQN
  (`App\Foo::method`), exactly as `query`/`impact`/`references` already use.
  Tolerate a single leading `\` (strip it like `referencesHandler` does).
- **Type rendering:** a type is rendered to a string via `TypeInfo.format`
  ([src/types.zig](../src/types.zig)). Every typed field is emitted as a small
  object so the agent can distinguish source and shape:
  ```json
  { "text": "?App\\User", "kind": "nullable", "builtin": false,
    "nullable": true, "parts": ["App\\User"] }
  ```
  where `kind` is the `TypeInfo.Kind` tag, `parts` is `type_parts` for
  union/intersection (omitted otherwise), `nullable` is true for `?T` or a union
  containing `null`. When a symbol has both a native and a PHPDoc type, emit
  **both** plus the merged `effective` (mirrors `effectiveReturnType` /
  `PropertySymbol.effectiveType`), so the agent sees what the resolver actually
  uses without losing provenance.
- **Caps:** reuse `cb_list_cap` (200) for any member/result list, with a
  `*_truncated` flag, and the `response_byte_budget` guard already used in the
  `dependencies` renderer.
- **Errors:** structured `mcp.tools.errorResult` for "no project loaded",
  missing required arg, and "symbol not found in project" (the last lists the 3
  nearest FQNs by edit distance, so a stale FQN is self-correcting — optional).

### ⚠️ Shared prerequisite caveat (affects #1, #2, #4)

`SymbolCollector.parseTypeNode` ([src/symbol_collector.zig#L534](../src/symbol_collector.zig#L534))
only FQCN-resolves `.simple` and `.nullable` base types. **Union/intersection
`type_parts` and array element types keep their short, file-local names.** So
`Foo|Bar` is stored with parts `["Foo","Bar"]`, not their FQCNs. This means:

- type rendering for unions can show short names (cosmetic);
- **type matching by FQCN (`find_by_type`, `check_conformance`) silently misses
  union/array-element members.**

Two options: (a) ship #2/#4 matching `.simple`/`.nullable` only in v1 and
document the gap in `caveats`; or (b) first extend `parseTypeNode` to
FQCN-resolve `type_parts` + array element base (small, well-scoped change with
its own unit test). **Recommendation: do (b) before #2**, since silent
under-matching violates the design's "never silently under-report" gate
([mcp-design.md §9](./mcp-design.md)).

---

## Tool 1 — `describe_symbol`

### Purpose
Return the **resolved, inheritance-aware, typed** view of a single symbol so the
agent can call or edit it without opening the file. Strictly better than reading
source: native+PHPDoc types are already merged and (for simple types) FQCN-
normalized, and inherited/trait members are already flattened into the
`ResolvedView`.

### Input schema
```jsonc
{
  "fqn":      "string (required) — Class, Interface, Trait, Class::method, or function FQN",
  "members":  "enum(none|signatures|full) default signatures — for a type target, how much member detail",
  "inherited":"boolean default true — include inherited/trait members for a type target"
}
```
`addString("fqn",…,true)`, `addEnumWithDefault("members", …, ["none","signatures","full"], "signatures", false)`, `addBooleanWithDefault("inherited", …, true, false)`.

### Dispatch on what `fqn` resolves to
1. Contains `::` → **member**: split into `class_fqcn` + `member`. Try
   `ResolvedView.resolveMethod(class, member)` then `resolveProperty`. (Use the
   resolved view so inherited members resolve; fall back to interface methods via
   `SymbolTable.resolveInterfaceMethod`.)
2. No `::`, found in `sym_table.functions` → **function**.
3. No `::`, found in `classes`/`interfaces`/`traits` → **type**.

### Output — member (method)
```json
{
  "fqn": "App\\Service\\UserService::find",
  "symbol": "method",
  "declared_in": "App\\Service\\BaseService",
  "inherited": true,
  "visibility": "public",
  "modifiers": { "static": false, "abstract": false, "final": false },
  "parameters": [
    { "name": "id", "position": 0,
      "type": { "native": {"text":"int","kind":"simple","builtin":true},
                "phpdoc": null,
                "effective": {"text":"int","kind":"simple","builtin":true} },
      "has_default": false, "variadic": false, "by_reference": false, "promoted": false }
  ],
  "return": { "native": {"text":"?App\\User","kind":"nullable","builtin":false,"nullable":true},
              "phpdoc": null,
              "effective": {"text":"?App\\User","kind":"nullable","builtin":false,"nullable":true} },
  "location": { "file": "src/Service/BaseService.php", "start_line": 42, "end_line": 50 },
  "signature_text": "public function find(int $id): ?App\\User"
}
```
- `declared_in` ≠ the queried class ⇒ `inherited:true` (compare
  `MethodSymbol.containing_class` to the queried `class_fqcn`).
- `signature_text` is a human-readable reconstruction (handy for the agent to
  paste). Built from the fields above.

### Output — member (property)
Same envelope with `"symbol":"property"`, plus `static`, `readonly`, and
`type:{declared, phpdoc, effective}` from `PropertySymbol`.

### Output — function
Member-method shape minus `declared_in`/`inherited`/`visibility`/`modifiers`.

### Output — type (class/interface/trait)
```json
{
  "fqn": "App\\Service\\UserService",
  "symbol": "class",
  "modifiers": { "abstract": false, "final": true, "readonly": false },
  "namespace": "App\\Service",
  "extends": "App\\Service\\BaseService",
  "implements": ["App\\Contract\\UserRepository"],
  "uses_traits": ["App\\Concern\\LogsActivity"],
  "generics": { "templates": [{"name":"T","fallback":"App\\Model"}],
                "extends_args": ["App\\User"] },
  "parent_chain": ["App\\Service\\BaseService","App\\Service\\Kernel"],
  "members": {
    "own_methods":     ["find","save"],
    "inherited_methods":["log","boot"],
    "own_properties":  ["repo"],
    "inherited_properties":["logger"]
  },
  "location": { "file": "...", "start_line": 10, "end_line": 120 }
}
```
- `members:"signatures"` (default): replace the name arrays with arrays of the
  **member** shape above (capped at `cb_list_cap`, `members_truncated` flag).
- `members:"none"`: name arrays only (cheap, for orientation).
- `members:"full"`: like `signatures` but also expand inherited members' own
  `declared_in`. `inherited:false` drops the `inherited_*` arrays.
- `generics` comes straight from `ClassSymbol.template_params` /
  `extends_type_args`; omit if empty.
- `parent_chain` from `ResolvedClass.parent_chain`.

### Backing APIs (all existing)
`SymbolTable.getClass/getInterface/getTrait/getFunction`,
`ResolvedView.getClass/resolveMethod/resolveProperty`,
`SymbolTable.resolveInterfaceMethod`, `MethodSymbol.{parameters,return_type,
phpdoc_return,effectiveReturnType,containing_class}`, `PropertySymbol.effectiveType`,
`TypeInfo.format`.

### Algorithm
O(1) lookups for a member/function; O(members) to list a type's members. No
traversal, so the only cap that bites is the member list. No mutation.

### Edge cases
- FQN not in project → "not found" error (it may be a vendor/core symbol; say so).
- Method exists on an interface only → `symbol:"method"`, `declared_in` = the
  interface, `inherited` per resolution.
- Enum: PHP enums parse as classes today; report `symbol:"class"` (note in
  caveats; a dedicated enum kind is future work).

### Tests
- `describe_symbol: method merges native+phpdoc and marks inherited` — a child
  class method inherited from a base resolves with `declared_in`=base,
  `inherited:true`, and a `?T` return rendered `nullable:true`.
- `describe_symbol: class lists own vs inherited members + generics` — a class
  with `@template` and a trait; assert `templates`, `own_*`, `inherited_*`.
- `describe_symbol: property effective type prefers native over phpdoc`.
- Smoke: `describe_symbol` on `Test\Logger::log` asserts `parameters` and
  `return.effective.text`.

---

## Tool 2 — `find_by_type` (type producer/consumer/holder index)

### Purpose
The one capability the **call graph cannot give**: navigate by type, not by
call. "Where can I get a `User`?" (producers), "Where can a `User` go?"
(consumers), "Who stores a `User`?" (holders). Enables type-directed data-flow
reasoning.

### Input schema
```jsonc
{
  "type":              "string (required) — FQCN to search for, e.g. App\\User",
  "roles":             "enum(all|producers|consumers|holders) default all",
  "include_subtypes":  "boolean default false — also match subclasses/implementors of `type`",
  "namespace_prefix":  "string optional — restrict results to declarers under this namespace",
  "exclude_tests":     "boolean default true — drop results declared in test files",
  "limit":             "integer default 200 (cap 1000)"
}
```

### Output
```json
{
  "type": "App\\User",
  "matched_types": ["App\\User", "App\\AdminUser"],
  "summary": { "producers": 4, "consumers": 11, "holders": 3 },
  "producers": [
    { "fqn": "App\\Repository\\UserRepository::find", "kind": "method",
      "match": { "via": "return", "type_text": "?App\\User", "source": "native" },
      "file": "src/Repository/UserRepository.php", "line": 30, "is_test": false }
  ],
  "consumers": [
    { "fqn": "App\\Mailer::welcome", "kind": "method",
      "match": { "via": "param", "param": "user", "position": 0,
                 "type_text": "App\\User", "source": "phpdoc" },
      "file": "...", "line": 12, "is_test": false }
  ],
  "holders": [
    { "fqn": "App\\Session::currentUser", "kind": "property",
      "match": { "via": "property", "type_text": "App\\User", "source": "native" },
      "file": "...", "line": 8, "is_test": false }
  ],
  "caveats": { "union_array_matching": "simple/nullable only (see prereq)",
               "subtypes_included": true, "tests_excluded": true,
               "truncated": false }
}
```
Each role list is independently capped at `limit` with a per-list
`*_truncated` flag.

### Algorithm (target-scoped, no stored index)
Follow [src/references.zig](../src/references.zig)'s philosophy: scan on demand
rather than maintaining an invalidatable global index. Add
`ProjectIndex.findByType(allocator, type, opts)`:

1. Build the **match set**: `{type}` ∪ (if `include_subtypes`) all in-project
   subclasses/implementors. Subclass set = every class whose `parent_chain`
   contains `type`; implementor set = walk `classes` whose `implements`
   (transitively via interface `extends`) include `type`. (Reuse the logic shape
   from `ResolvedView.buildInterfaceImplIndex`.)
2. One pass over `sym_table.classes` (each class's **own** methods + properties),
   `sym_table.interfaces` (methods), and `sym_table.functions`:
   - **producer** if a method/function's `effectiveReturnType` base type (or any
     resolved union part) is in the match set;
   - **consumer** if any parameter's effective type matches;
   - **holder** if a property's effective type matches.
3. Classify each declarer file with the existing `isTestFile` helper
   (in [query.zig](../src/query.zig); factor it shared) for `is_test` /
   `exclude_tests`.
4. Sort deterministically by FQN; cap.

Type comparison: compare `TypeInfo.base_type` (and `type_parts` once the prereq
fix lands) by exact FQCN string equality against the match set. `?App\User`
matches `App\User` (nullable shares `base_type`).

### Cost
One linear pass over all symbols per call — same order as the priming-payload
stats walk. No traversal. For very large monorepos this is the heaviest of the
read-only tools; `namespace_prefix` prunes early.

### Edge cases / caveats
- Builtin `type` (`int`, `array`) → reject with a hint ("provide a class FQCN;
  builtins match too broadly").
- `include_subtypes` only covers **in-project** subtypes (vendor subclasses are
  invisible) — state in caveats.
- Union/array element matching gated on the prereq fix (caveat surfaced).

### Tests
- `find_by_type: producers and consumers of a class` — a repo returning `User`
  and a mailer taking `User`; assert both with correct `via`.
- `find_by_type: include_subtypes matches an implementor` — interface `Animal`,
  class `Dog implements Animal`; a method returning `Dog` shows up for
  `type=Animal, include_subtypes=true` but not when false.
- `find_by_type: exclude_tests drops a test-declared consumer`.
- Smoke: `find_by_type type=Test\\Logger` asserts ≥1 consumer/holder.

---

## Tool 3 — `resolve_interface` (DI/wiring explainer)

### Purpose
Answer "what does an interface-typed call actually hit, and why?" and the
reverse "what contracts does this class satisfy?". Surfaces the DI knowledge the
resolver already computes (`iface_single_impl` + `explicit_bindings`).

### Input schema
```jsonc
{ "fqn": "string (required) — an interface FQCN, or a class FQCN for the reverse query" }
```

### Output — interface target
```json
{
  "fqn": "App\\Contract\\Mailer",
  "symbol": "interface",
  "implementors": ["App\\Mailer\\SmtpMailer", "App\\Mailer\\SesMailer"],
  "binding": {
    "resolves_to": "App\\Mailer\\SesMailer",
    "kind": "di_config",            // di_config | single_impl | ambiguous | none
    "confidence": 0.85,             // 0.85 di_config, 0.6 single_impl, else null
    "explanation": "Bound in services.yaml; chosen over 2 implementors."
  },
  "methods": ["send", "queue"]
}
```
- `implementors`: every in-project class implementing `fqn` (direct or via
  sub-interface `extends`). Computed like `buildInterfaceImplIndex` but keeping
  the full list, not just the unique case.
- `binding.kind`/`resolves_to`: `explicitImplementor(fqn)` → `di_config` (0.85);
  else `singleImplementor(fqn)` → `single_impl` (0.6); else if ≥2 implementors →
  `ambiguous` (no `resolves_to`); else `none`. These mirror the
  `resolution_method` tags `di_config_binding` / `interface_single_impl` and
  their confidences in [call_analyzer.zig](../src/call_analyzer.zig).

### Output — class target (reverse)
```json
{
  "fqn": "App\\Mailer\\SmtpMailer",
  "symbol": "class",
  "implements": ["App\\Contract\\Mailer", "Stringable"],
  "implements_in_project": ["App\\Contract\\Mailer"],
  "is_di_bound_for": ["App\\Contract\\Mailer"],
  "bound_kind": { "App\\Contract\\Mailer": "single_impl" }
}
```
- `is_di_bound_for`: interfaces this class is the chosen implementor of (scan
  `explicit_bindings` + `iface_single_impl` values for `fqn`).

### Backing APIs (all existing)
`ResolvedView.singleImplementor/explicitImplementor`, the `iface_single_impl` /
`explicit_bindings` maps, `SymbolTable.interfaces`/`classes`,
`InterfaceSymbol.extends`, `ClassSymbol.implements`.

### Cost
O(implementors) for the forward query; O(classes) worst-case for the reverse
scan. No traversal.

### Edge cases
- `fqn` is a class that also has implementors (none — classes aren't
  implemented) → reverse path only.
- Interface with zero in-project implementors → `binding.kind:"none"`,
  empty `implementors` (likely a vendor contract; note it).

### Tests
- `resolve_interface: single implementor → single_impl 0.6`.
- `resolve_interface: services.yaml binding wins over multiple implementors →
  di_config 0.85` (reuse the Phase-B fixture
  `fixtures/project/config/services.yaml`).
- `resolve_interface: reverse — class reports the interfaces it is bound for`.
- Smoke: `resolve_interface` on the bound `NotifierInterface` asserts
  `resolves_to=SmsNotifier`, `kind=di_config`.

---

## Tool 4 — `check_conformance` (override / contract signature checking)

### Purpose
Use inheritance + signatures to flag where an implementor or override **doesn't
match** its contract: missing methods, arity mismatch, incompatible param/return
types, nullability widening, visibility narrowing. A real correctness signal the
agent can act on before trusting a class as a drop-in.

### Input schema
```jsonc
{
  "fqn":   "string (required) — a class FQCN to check",
  "against":"enum(all|interfaces|parent) default all — contracts to check the class against",
  "include_ok":"boolean default false — also list conformant members (otherwise only findings)"
}
```

### Output
```json
{
  "fqn": "App\\Mailer\\SmtpMailer",
  "checked": { "interfaces": ["App\\Contract\\Mailer"], "parent": "App\\Mailer\\AbstractMailer" },
  "summary": { "missing": 0, "mismatches": 1, "ok": 3 },
  "findings": [
    {
      "severity": "mismatch",            // missing | mismatch
      "member": "send",
      "contract": "App\\Contract\\Mailer::send",
      "issue": "return_type_incompatible",
      "detail": "contract returns bool, implementation returns void",
      "contract_signature": "send(App\\Message $m): bool",
      "impl_signature": "send(App\\Message $m): void"
    }
  ],
  "caveats": { "variance": "name-equality check, not full LSP variance",
               "union_array": "simple/nullable compared only (see prereq)" }
}
```
`issue` ∈ `missing_method`, `param_count`, `param_type_incompatible`,
`return_type_incompatible`, `nullability_widened`, `visibility_narrowed`.

### Algorithm
1. Collect contracts: each interface in `ClassSymbol.implements` (+ transitive
   `extends`); the parent class (`extends`) for abstract-method satisfaction.
2. For each contract method (`resolveInterfaceMethod` / parent's
   `ResolvedView.resolveMethod`): look up the class's effective method via
   `ResolvedView.resolveMethod(fqn, name)`.
   - absent → `missing_method`.
   - present → compare:
     - param count (account for `has_default`/variadic like
       `BoundaryAnalyzer.lookupSignature`);
     - per-position param effective-type FQCN equality;
     - return effective-type FQCN equality;
     - nullability: impl return nullable where contract isn't (widening) etc.;
     - visibility: impl more restrictive than contract → `visibility_narrowed`.
3. Emit findings (and `ok` entries if `include_ok`).

This is intentionally a **name-equality** check, not a full PHP LSP variance
engine (covariance of returns, contravariance of params) — that needs the
subtype graph and is explicitly out of v1 scope (caveat). Even name-equality
catches the common real bugs (wrong return type, missing method, dropped param).

### Backing APIs
`ClassSymbol.{implements,extends}`, `InterfaceSymbol.extends`,
`SymbolTable.resolveInterfaceMethod`, `ResolvedView.resolveMethod`,
`MethodSymbol.{parameters,visibility,effectiveReturnType}`, `Visibility`.

### Cost
O(contract methods) lookups; no traversal beyond interface `extends` chains.

### Edge cases
- Abstract class not required to implement interface methods → only flag
  `missing_method` for **concrete** classes (`!is_abstract`).
- Magic `__call`/`__get` can satisfy a contract at runtime → a `missing_method`
  on a class declaring `__call` is downgraded to `severity:"info"` with a note.

### Tests
- `check_conformance: missing interface method on concrete class`.
- `check_conformance: return type mismatch flagged`.
- `check_conformance: abstract class not flagged for unimplemented method`.
- `check_conformance: __call downgrades missing to info`.

---

## Tool 5 — type-aware `impact` (breaking-change for type edits)

### Purpose
Extend the existing `impact` tool from **arity-only** breaking-change verdicts to
**type** edits: "if I change param `Foo`→`Bar`, or narrow/widen the return type,
which call sites break?" This is the highest-value item but requires engine work
because call sites currently capture only `arg_count`, not argument types.

### Required engine work (prerequisite)
1. **Capture per-argument types at call sites.** Today
   [call_analyzer.zig](../src/call_analyzer.zig) records `arg_count` via
   `countCallArgs`. Extend the call-recording path to also resolve each
   argument expression's type with the existing `TypeResolver`
   (the same machinery that types receivers), storing:
   ```zig
   // in EnhancedFunctionCall (types.zig)
   arg_types: []const ?TypeInfo = &.{},   // per positional arg; null where unresolved
   result_used: ResultUse = .ignored,     // ignored | assigned | member_access | passed
   ```
   `result_used` records whether the call result is consumed (esp.
   `->member`/`::member` on the result), which is what makes return-type
   narrowing (`User` → `?User`) a breaking change.
2. **Honesty:** arg-type resolution has the same partiality as receiver
   resolution (untyped locals, chains). Each `arg_types[i]` is nullable; the tool
   reports **coverage** (how many call sites had fully-typed args) so a low-
   confidence verdict is never dressed up as complete.

### Input schema (additive to current `impact`)
```jsonc
{
  "fqn": "string (required)",
  "exclude_tests": "boolean default true",
  "simulate": {                       // optional: describe the edit to evaluate
    "param_type_change": { "position": 0, "to": "App\\Bar" },
    "return_type_change": { "to": "?App\\User" }
  }
}
```
Without `simulate`, the tool just adds observed **argument types** to the
existing per-caller output. With `simulate`, it evaluates the edit.

### Output (extends current `impact` shape)
Adds, alongside the existing `signature` / `call_site_arity` / `breaking_change`:
```json
{
  "type_breaking_change": {
    "param_type_change": {
      "position": 0, "to": "App\\Bar",
      "incompatible_call_sites": [
        { "caller": "App\\Foo::run", "file": "...", "line": 20,
          "arg_type": "App\\User", "reason": "App\\User is not App\\Bar or a subtype" }
      ],
      "verdict": "breaking",            // safe | breaking | unknown
      "coverage": { "typed_args": 7, "total_call_sites": 9 }
    },
    "return_type_change": {
      "to": "?App\\User",
      "risky_call_sites": [
        { "caller": "App\\Bar::handle", "file": "...", "line": 8,
          "result_used": "member_access",
          "reason": "result dereferenced without null check; narrowing to ?T may break" }
      ],
      "verdict": "risky",
      "coverage": { "result_use_known": 8, "total_call_sites": 9 }
    }
  }
}
```

### Algorithm
- **Param type change:** for each caller's `arg_types[position]`, check whether
  the observed type is `to` or an in-project subtype of `to` (reuse the subtype
  set logic from #2). Mismatch → incompatible. `unknown` when too few args typed.
- **Return type change (narrowing to nullable):** flag callers whose
  `result_used == member_access` (or `passed` to a non-nullable param) — those
  are where `?T` would newly require a null check.
- `verdict` is `breaking` only on a *typed, in-project* mismatch; otherwise
  `risky`/`unknown` with coverage. Never `safe` unless every call site is typed
  and compatible (the `breaking_change.remove_trailing_param` precedent in
  [mcp_server.zig#L1185](../src/mcp_server.zig#L1185) sets the bar: `safe` only
  when no observed call site contradicts it).

### Backing APIs
Existing `BoundaryAnalyzer.impact` + `lookupSignature`; **new** `arg_types` /
`result_used` on `EnhancedFunctionCall`; subtype set from #2.

### Cost
The capture cost is paid once at index-build time (extra `TypeResolver` calls per
argument). The tool itself is O(callers), same as today's `impact`.

### Edge cases / caveats
- Heavy reliance on resolution rate: on a weakly-resolved graph most `arg_types`
  are null → verdicts are mostly `unknown` (reported honestly via `coverage`).
- Widening a param (`Bar`→`Foo` supertype) is always safe; the tool can say so
  without call-site data.
- This is the only item that changes the **cold-build** cost and the
  `incremental == from-scratch` differential contract — the new fields must be
  reproduced identically by both build paths (extend the existing differential
  tests in [project_index.zig](../src/project_index.zig)).

### Tests
- `impact: argument types captured at call sites` (analyzer-level).
- `impact: param_type_change flags an incompatible in-project arg`.
- `impact: return narrowing to ?T flags a dereferencing caller`.
- `impact: low coverage yields unknown, not safe`.
- Differential: `arg_types`/`result_used` identical incremental vs from-scratch.

---

## Suggested execution order

1. **Prereq fix** — FQCN-resolve union/array element `type_parts` in
   `parseTypeNode` (+ test). Unblocks honest matching for #2/#4.
2. **`describe_symbol`** (#1) — foundation, pure read, immediately useful.
3. **`resolve_interface`** (#3) — tiny, high trust, reuses DI indexes.
4. **`find_by_type`** (#2) — the type-navigation win; one read pass.
5. **`check_conformance`** (#4) — comparison pass over existing data.
6. **type-aware `impact`** (#5) — engine work (arg-type capture) + differential
   test extension; do last.

Each step: implement → `zig build test` → extend `scripts/mcp_smoke.sh` where the
surface changed → update the `load_project` priming payload's tool list.
