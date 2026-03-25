# Corpus Golden File Testing

Golden file tests compare PHPCMA analysis output against checked-in baselines
to detect regressions in parsing, type resolution, and dead code analysis.

## How it works

1. PHPCMA runs `report --format=json` on a PHP corpus (e.g., monolog/monolog)
2. The JSON output is compared against a checked-in golden file
3. Regressions are detected when:
   - Symbol counts **decrease** (classes, methods, etc.) → parsing bug
   - Resolution rate **drops** by more than 0.5pp → type resolution bug
   - Violation counts change by more than ±10% → unexpected behavior change
   - Performance exceeds 2× baseline → performance regression

## Creating a golden file

```bash
# Build PHPCMA first
zig build -Doptimize=ReleaseFast

# For a single composer project:
./scripts/corpus-snapshot.sh /path/to/project test/corpus/project-name.golden.json

# For a monorepo with .phpcma.json:
./scripts/corpus-snapshot.sh /path/to/monorepo test/corpus/name.golden.json --config
```

## Updating a golden file after intentional changes

When you've made changes that intentionally affect analysis results:

```bash
./scripts/corpus-snapshot.sh /path/to/project test/corpus/project-name.golden.json
git add test/corpus/project-name.golden.json
git commit -m "chore: update golden file after <description>"
```

## Running comparison manually

```bash
# Generate actual output
./zig-out/bin/PHPCMA report --composer=/path/to/project/composer.json --format=json > /tmp/actual.json

# Compare against golden file
python3 scripts/corpus-compare.py /tmp/actual.json test/corpus/project-name.golden.json
```

## CI corpus: monolog/monolog

The CI workflow uses [monolog/monolog](https://github.com/Seldaek/monolog) because:
- Small (~100 files) — fast to download and analyze
- Stable API — infrequent breaking changes
- Well-typed — exercises type resolution
- Open source — free to download via Composer

The shopware-plugins corpus is too large and private for CI use.

## Golden file format

Golden files contain the standard PHPCMA JSON report output plus `_metadata`:

```json
{
  "coverage": { "files": 42, "classes": 15, ... },
  "type_checks": { ... },
  "dead_code": { ... },
  "_metadata": {
    "corpus": "monolog",
    "snapshot_time": "2026-03-25T10:00:00Z",
    "duration_seconds": 0.5
  }
}
```
