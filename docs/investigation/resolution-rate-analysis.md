# Resolution Rate Analysis

## Baseline

Ran:

```bash
./zig-out/bin/PHPCMA report \
  --config=/path/to/project/.phpcma.json \
  --format=text \
  --output=/tmp/report.txt
```

Observed report values:

- Total calls: `43,987`
- Resolved: `13,830` (`31.4%`)
- Unresolved: `30,157` (`68.6%`)

## Method Used For Unresolved Categorization

1. Discovered all top-level package manifests (each `composer.json`) across the monorepo.
2. Ran `PHPCMA project --format=json` per package and extracted unresolved entries (`resolved_target = null`, `confidence = 0.00`) with file+line context.
3. Classified unresolved calls with deterministic heuristics (container patterns, dynamic dispatch patterns, closure/HOF patterns, framework API signature patterns, global function patterns, default untyped-method bucket).

Dataset used for category math: `30,231` unresolved calls.

Note: this is `74` calls (`0.2%`) above the unified report unresolved count (`30,157`) because per-package analysis loses a small amount of cross-package resolution.

## Category Breakdown

| Category | Count | % of unresolved (`30,231`) | Max resolution-rate uplift* |
|---|---:|---:|---:|
| Untyped variable method calls in project code | 14,774 | 48.9% | +33.6 pp |
| Framework external API calls (Shopware/Symfony/Doctrine) | 10,834 | 35.8% | +24.6 pp |
| Closure-heavy collection pipelines | 2,749 | 9.1% | +6.2 pp |
| Global/builtin function calls lacking symbol model | 1,651 | 5.5% | +3.8 pp |
| DI Container / Service Locator calls | 142 | 0.5% | +0.3 pp |
| Dynamic dispatch / runtime call indirection | 81 | 0.3% | +0.2 pp |

\* Max uplift is theoretical if that entire category became resolvable, measured against total calls (`43,987`).

## Top 5 Improvement Opportunities

1. **Improve local type propagation for untyped variables** (`14,774` calls, 48.9% of unresolved): infer variable/object type through assignments, fluent chains, and constructor-injected fields; this is the single biggest bucket.
2. **Add framework API stubs/signatures (Shopware DAL + Symfony/Doctrine touchpoints)** (`10,834` calls, 35.8%): methods such as `executeStatement`, `addFlags`, `findBy`, `getByPrimaryKey`, `addFilter` dominate unresolved external calls.
3. **Model closure/collection generic flows** (`2,749` calls, 9.1%): propagate closure input/output types through `map`, `filter`, `flatMap`, `first`, `usort`, and similar helpers.
4. **Ship a builtin/global function signature catalog** (`1,651` calls, 5.5%): unresolved `array_*`, `mb_*`, and utility functions are a concentrated, mostly deterministic quick win.
5. **Resolve DI container lookups to concrete services** (`142` calls, 0.5%): map `$container->get(...)`/`$this->container->get(...)` to class strings/service IDs for high-confidence resolution in service-locator-heavy code.

Dynamic dispatch (`81`, 0.3%) is a separate long-tail problem and likely needs conservative heuristics plus confidence downgrades, not strict resolution.

## Sample Unresolved Calls By Category

The examples below are generic, illustrative shapes for each category (not drawn
from any specific codebase).

### Untyped Variable Method Calls In Project Code

- `src/Adapter/ResponseProcessor.php` → `getId`  
  `shipmentId: $shipment->getId(),` — `$shipment` has no inferable type.
- `src/Http/ErrorHandler.php` → `get`  
  `$header = $request->headers->get('X-Show-Trace');` — receiver type unknown.

### Framework External API Calls (Shopware/Symfony/Doctrine)

- `src/Db/BulkInsertService.php` → `executeStatement`  
  `return $this->connection->executeStatement($sql, ...);` — Doctrine DBAL API.
- `src/Config/ConfigDefinition.php` → `addFlags`  
  `(new IdField('id', 'id'))->addFlags(new PrimaryKey());` — Shopware DAL API.

### Closure-Heavy Collection Pipelines

- `src/Collection/CollectionExtension.php` → `map`  
  `$collection->map(fn(Entity $entity) => $entity->get($field));` — closure result type unknown.
- `src/Subscriber/RequestSubscriber.php` → `compareTo`  
  `fn(Layer $lhs, Layer $rhs) => $lhs->getVersion()->compareTo($rhs->getVersion());`

### Global/Builtin Function Calls Lacking Symbol Model

- `src/Error/LocalizableError.php` → `array_key_exists`  
  `if (!array_key_exists('about', $links)) { ... }` — builtin has no symbol model.
- `src/Acl/RoleFactory.php` → `array_unique`  
  `privileges: array_unique($allPrivileges),`

### DI Container / Service Locator Calls

- `src/Installation/BundleInstaller.php` → `get`  
  `$self->connection = $container->get(Connection::class);`
- `src/Orm/EntityManager.php` → `get`  
  `return $this->container->get(sprintf('%s.repository', $entityName));`

### Dynamic Dispatch / Runtime Call Indirection

- `src/Resolver/ValueResolver.php` → `call_user_func`  
  `$payload = call_user_func(sprintf('%s::fromArray', $type), $value);`
- `src/Orm/CloneTrait.php` → `cloneArray`  
  `$this->$key = $this->cloneArray($value);` — dynamic property + method.
