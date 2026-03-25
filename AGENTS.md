# PHPCMA — Agent Instructions

PHPCMA is a Zig-based PHP Call Map Analyzer using tree-sitter. Built with **Zig 0.15.2**.

## Commit Gate

**Before committing ANY changes, `zig build test` MUST pass.** This is non-negotiable.

```bash
zig build test   # MUST pass before every commit
```

If tests fail, fix the failures before committing. Do not skip, ignore, or comment out failing tests.

## Test Pipelines

Run from the rig root (`phpcma/mayor/rig/`).

| Pipeline | Command | Description | Status |
|----------|---------|-------------|--------|
| **Unit tests** | `zig build test` | Unit + generative property-based tests (~370+) | **Must always pass** |
| **Fuzz tests** | `zig build fuzz` | Coverage-guided mutation fuzz testing | Has known failures (ph-du1) |
| **Diff tests** | `zig build diff-test` | Compares PHPCMA output vs PHP reflection API | Passes (1 skip for PHP 8.3) |
| **Corpus tests** | `PHPCMA_CORPUS_ROOT=/path/to/corpora zig build corpus-test` | Regression tests against real codebases | Requires `PHPCMA_CORPUS_ROOT` env var |
| **Benchmarks** | `zig build bench` | Performance benchmarks with synthetic projects | Passes |
| **Build** | `zig build` | Full release build | Must always pass |

### CI

GitHub Actions (`.github/workflows/ci.yml`) runs `zig build test` and `zig build` on every push to `main` and on PRs. Fuzz tests run on PRs only (120s budget).

### Environment Variables

- `PHPCMA_CORPUS_ROOT` — Required for `zig build corpus-test`. Points to the root directory containing real PHP codebases for regression testing. No hardcoded paths allowed.
