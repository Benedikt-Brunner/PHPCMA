# Differential Corpus Runs

This directory stores the Packagist differential run report produced by [`scripts/diff-corpus.sh`](../../scripts/diff-corpus.sh).

## Manual Run

Run from the repository root:

```bash
./scripts/diff-corpus.sh
```

This command:

1. Builds `PHPCMA` and the `phpcma-symbol-dump` helper.
1. Downloads the configured Packagist packages with Composer.
1. Collects PHP source files (excluding `vendor/` and test folders).
1. Runs PHPCMA project analysis (`report --format=json`).
1. Runs PHPCMA symbol extraction and PHP reflection extraction.
1. Compares symbol tables and writes [`results.md`](./results.md).

## Useful Options

1. `--limit 1` to run only the first package while validating the pipeline.
1. `--package symfony/console --package monolog/monolog` to run a custom subset.
1. `--workdir /tmp/phpcma-diff` to preserve all raw artifacts in a known location.
