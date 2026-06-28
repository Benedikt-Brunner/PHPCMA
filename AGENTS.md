# PHPCMA — Agent Instructions

PHPCMA is a Zig-based PHP Call Map Analyzer using tree-sitter. Built with **Zig 0.16.0**.

## Commit Gate

**Before committing ANY changes, ALL test pipelines MUST pass.** This is non-negotiable.

```bash
zig build test                                                    # Unit + generative tests
zig build fuzz                                                    # Fuzz tests
zig build diff-test                                               # Differential tests
PHPCMA_CORPUS_ROOT=/path/to/corpora zig build corpus-test         # Corpus tests (if env var set)
zig build bench                                                   # Benchmarks
zig build                                                         # Full build
scripts/mcp_smoke.sh                                              # MCP stdio protocol smoke test
```

If any pipeline fails, fix the failures before committing. Do not skip, ignore, or comment out failing tests.

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
| **MCP smoke** | `scripts/mcp_smoke.sh` | Drives a stdio JSON-RPC session against `phpcma mcp`, asserts every tool, and golden-checks `report` == CLI `report --format json` | **Must always pass** (needs `python3`) |

### CI

GitHub Actions (`.github/workflows/ci.yml`) runs `zig build test` and `zig build` (job `test`) and the MCP stdio smoke test (job `mcp-smoke`) on every push to `main` and on PRs. Fuzz tests run on PRs only.

### Environment Variables

- `PHPCMA_CORPUS_ROOT` — Required for `zig build corpus-test`. Points to the root directory containing real PHP codebases for regression testing. No hardcoded paths allowed.
