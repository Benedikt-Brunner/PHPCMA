#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULT_DIR="$REPO_ROOT/test/differential"
RESULT_FILE="$RESULT_DIR/results.md"

DEFAULT_PACKAGES=(
  "symfony/console"
  "symfony/http-foundation"
  "monolog/monolog"
  "guzzlehttp/guzzle"
  "doctrine/orm"
  "phpunit/phpunit"
  "league/flysystem"
  "nesbot/carbon"
  "ramsey/uuid"
  "nikic/php-parser"
)

usage() {
  cat <<'USAGE'
Usage: scripts/diff-corpus.sh [options]

Options:
  --package <vendor/name>   Add a package to test (can be repeated)
  --limit <N>               Limit how many packages to run (after selection)
  --workdir <path>          Store temporary run artifacts in this directory
  --help                    Show this help

If no --package is provided, the default top-10 Packagist packages are used.
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

PACKAGES=()
LIMIT=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      PACKAGES+=("$2")
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --workdir)
      WORK_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  PACKAGES=("${DEFAULT_PACKAGES[@]}")
fi

if [[ -n "$LIMIT" ]]; then
  PACKAGES=("${PACKAGES[@]:0:$LIMIT}")
fi

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  echo "No packages selected." >&2
  exit 1
fi

require_cmd zig
require_cmd composer
require_cmd php
require_cmd python3

mkdir -p "$RESULT_DIR"

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phpcma-diff-corpus-XXXXXX")"
fi
mkdir -p "$WORK_DIR"

echo "Using work directory: $WORK_DIR"
echo "Building PHPCMA binaries..."
(cd "$REPO_ROOT" && zig build >/dev/null)
(cd "$REPO_ROOT" && zig build symbol-dump >/dev/null)

PHPCMA_BIN="$REPO_ROOT/zig-out/bin/PHPCMA"
SYMBOL_DUMP_BIN="$REPO_ROOT/zig-out/bin/phpcma-symbol-dump"
COMPARE_SCRIPT="$REPO_ROOT/scripts/diff-compare.py"
REFLECT_SCRIPT="$REPO_ROOT/scripts/reflect.php"

if [[ ! -x "$PHPCMA_BIN" ]]; then
  echo "PHPCMA binary not found at $PHPCMA_BIN" >&2
  exit 1
fi

if [[ ! -x "$SYMBOL_DUMP_BIN" ]]; then
  echo "Symbol dump binary not found at $SYMBOL_DUMP_BIN" >&2
  exit 1
fi

RUN_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
COMMIT_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD)"

TABLE_ROWS=()
DETAIL_ROWS=()

for package in "${PACKAGES[@]}"; do
  echo "=== Processing $package ==="
  slug="${package//\//__}"
  package_dir="$WORK_DIR/$slug/package"
  package_work="$WORK_DIR/$slug"
  mkdir -p "$package_work"

  create_project_log="$package_work/create-project.log"
  if ! composer create-project --no-dev --no-scripts --no-interaction --prefer-dist --ignore-platform-reqs "$package" "$package_dir" >"$create_project_log" 2>&1; then
    rm -rf "$package_dir"
    echo "Initial create-project failed, retrying with --no-install" >>"$create_project_log"
    if ! composer create-project --no-dev --no-scripts --no-interaction --prefer-dist --ignore-platform-reqs --no-install "$package" "$package_dir" >>"$create_project_log" 2>&1; then
      TABLE_ROWS+=("| \`$package\` | 0 | 0 | 0 | 0 | 0 | create-project failed |")
      DETAIL_ROWS+=("### \`$package\`\n\nComposer create-project failed. See \`$create_project_log\`.\n")
      continue
    fi
  fi

  autoload_log="$package_work/dump-autoload.log"
  if ! (cd "$package_dir" && composer dump-autoload --no-dev --no-interaction --ignore-platform-reqs >"$autoload_log" 2>&1); then
    echo "Warning: composer dump-autoload failed for $package (see $autoload_log)" >&2
  fi

  files_list="$package_work/files.txt"
  find "$package_dir" -type f -name '*.php' \
    ! -path '*/vendor/*' \
    ! -path '*/tests/*' \
    ! -path '*/Tests/*' \
    ! -path '*/test/*' \
    ! -path '*/Test/*' \
    | sort > "$files_list"

  file_count="$(wc -l < "$files_list" | tr -d ' ')"
  if [[ "$file_count" == "0" ]]; then
    TABLE_ROWS+=("| \`$package\` | 0 | 0 | 0 | 0 | 0 | no PHP files found |")
    DETAIL_ROWS+=("### \`$package\`\n\nNo PHP source files found after filtering.\n")
    continue
  fi

  phpcma_report_json="$package_work/phpcma-report.json"
  phpcma_report_log="$package_work/phpcma-report.log"
  if ! "$PHPCMA_BIN" report --composer "$package_dir/composer.json" --format=json >"$phpcma_report_json" 2>"$phpcma_report_log"; then
    TABLE_ROWS+=("| \`$package\` | $file_count | 0 | 0 | 0 | 0 | PHPCMA report failed |")
    DETAIL_ROWS+=("### \`$package\`\n\nPHPCMA report command failed. See \`$phpcma_report_log\`.\n")
    continue
  fi

  phpcma_symbols_json="$package_work/phpcma-symbols.json"
  symbol_dump_log="$package_work/symbol-dump.log"
  if ! "$SYMBOL_DUMP_BIN" --file-list "$files_list" >"$phpcma_symbols_json" 2>"$symbol_dump_log"; then
    TABLE_ROWS+=("| \`$package\` | $file_count | 0 | 0 | 0 | 0 | symbol dump failed |")
    DETAIL_ROWS+=("### \`$package\`\n\nPHPCMA symbol dump failed. See \`$symbol_dump_log\`.\n")
    continue
  fi

  reflect_json="$package_work/reflect.json"
  reflect_log="$package_work/reflect.log"
  if ! php "$REFLECT_SCRIPT" --autoload "$package_dir/vendor/autoload.php" --file-list "$files_list" >"$reflect_json" 2>"$reflect_log"; then
    TABLE_ROWS+=("| \`$package\` | $file_count | 0 | 0 | 0 | 0 | reflection failed |")
    DETAIL_ROWS+=("### \`$package\`\n\nPHP reflection extraction failed. See \`$reflect_log\`.\n")
    continue
  fi

  summary_json="$package_work/summary.json"
  if ! python3 "$COMPARE_SCRIPT" --phpcma "$phpcma_symbols_json" --reflect "$reflect_json" --output "$summary_json"; then
    TABLE_ROWS+=("| \`$package\` | $file_count | 0 | 0 | 0 | 0 | compare failed |")
    DETAIL_ROWS+=("### \`$package\`\n\nComparison script failed.\n")
    continue
  fi

  read -r total_classes class_matches class_mismatches total_mismatches < <(
    python3 - "$summary_json" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

print(data['total_classes'], data['class_matches'], data['class_mismatches'], data['total_mismatches'])
PY
  )

  status="ok"
  if [[ "$total_mismatches" != "0" ]]; then
    status="mismatch"
  fi

  TABLE_ROWS+=("| \`$package\` | $file_count | $total_classes | $class_matches | $class_mismatches | $total_mismatches | $status |")

  detail_body="$(python3 - "$summary_json" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)

mismatches = data.get('mismatches', [])
if not mismatches:
    print('No mismatches found.')
    raise SystemExit(0)

limit = 20
for item in mismatches[:limit]:
    print(f"- [{item['kind']}] `{item['fqcn']}`: {item['detail']}")

remaining = len(mismatches) - limit
if remaining > 0:
    print(f"- ... and {remaining} more mismatch(es)")
PY
  )"

  DETAIL_ROWS+=("### \`$package\`\n\n$detail_body\n")
done

{
  echo "# Differential Results"
  echo
  echo "Generated: \`$RUN_TIMESTAMP\`"
  echo
  echo "Commit: \`$COMMIT_SHA\`"
  echo
  echo "Work Directory: \`$WORK_DIR\`"
  echo
  echo "| Package | PHP Files | Classes Compared | Class Matches | Class Mismatches | Total Mismatches | Status |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | --- |"
  for row in "${TABLE_ROWS[@]}"; do
    echo "$row"
  done
  echo
  echo "## Mismatch Details"
  echo
  for row in "${DETAIL_ROWS[@]}"; do
    printf '%b\n' "$row"
  done
} > "$RESULT_FILE"

echo "Wrote report: $RESULT_FILE"
