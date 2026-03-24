# Resolution Rate Analysis: `shopware-plugins`

## Baseline

Ran:

```bash
./zig-out/bin/PHPCMA report \
  --config=/Users/benediktbrunner/PhpstormProjects/shopware-plugins/.phpcma.json \
  --format=text \
  --output=/tmp/shopware-report.txt
```

Observed report values:

- Total calls: `43,987`
- Resolved: `13,830` (`31.4%`)
- Unresolved: `30,157` (`68.6%`)

## Method Used For Unresolved Categorization

1. Discovered all top-level package manifests under `plugins/*/composer.json` and `bundles/*/composer.json` (`45` packages).
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

### Untyped Variable Method Calls In Project Code

- `bundles/austrian-post-bundle/src/Adapter/AustrianPostResponseProcessor.php:67` → `getId`  
  `shipmentId: $shipment->getId(),`
- `bundles/api-error-handling-bundle/src/ControllerExceptionHandling/JsonApiStashedErrorHandler.php:101` → `get`  
  `$debugHeader = $request->headers->get('X-Pickware-Show-Trace');`

### Framework External API Calls (Shopware/Symfony/Doctrine)

- `bundles/dal-bundle/src/DatabaseBulkInsertService.php:62` → `executeStatement`  
  `return $this->connection->executeStatement($sql, parameters($dataset), types($types, count($dataset)));`
- `bundles/datev-bundle/src/Config/Model/DatevConfigDefinition.php:48` → `addFlags`  
  `(new IdField('id', 'id'))->addFlags(new PrimaryKey(), new Required()),`

### Closure-Heavy Collection Pipelines

- `bundles/dal-bundle/src/EntityCollectionExtension.php:24` → `map`  
  `return array_values($entityCollection->map(fn(Entity $entity) => $entity->get($fieldName)));`
- `bundles/api-versioning-bundle/src/ApiVersioningRequestSubscriber.php:113` → `compareTo`  
  `fn(ApiLayer $lhs, ApiLayer $rhs) => $lhs->getVersion()->compareTo($rhs->getVersion()),`

### Global/Builtin Function Calls Lacking Symbol Model

- `bundles/api-error-handling-bundle/src/JsonApiErrorTranslating/LocalizableJsonApiError.php:63` → `array_key_exists`  
  `if (is_array($links) && !array_key_exists('about', $links) && !array_key_exists('type', $links)) {`
- `bundles/acl-bundle/src/Acl/AclRoleFactory.php:40` → `array_unique`  
  `privileges: array_unique($allPrivileges),`

### DI Container / Service Locator Calls

- `bundles/austrian-post-bundle/src/Installation/PickwareAustrianPostBundleInstaller.php:47` → `get`  
  `$self->connection = $container->get(Connection::class);`
- `bundles/dal-bundle/src/EntityManager.php:509` → `get`  
  `return $this->container->get(sprintf('%s.repository', $entityName));`

### Dynamic Dispatch / Runtime Call Indirection

- `bundles/validation-bundle/src/Subscriber/JsonRequestValueResolver.php:170` → `call_user_func`  
  `$payload = call_user_func(sprintf('%s::fromArray', $type), $argumentValue);`
- `bundles/dal-bundle/src/EnumSupportingCloneTrait.php:29` → `cloneArray`  
  `$this->$key = $this->cloneArray($value);`
