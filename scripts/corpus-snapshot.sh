#!/usr/bin/env bash
# corpus-snapshot.sh — Run PHPCMA report on a corpus and save JSON output as golden file.
# Usage: ./scripts/corpus-snapshot.sh /path/to/project test/corpus/project-name.golden.json
#
# For monorepo mode (with .phpcma.json):
#   ./scripts/corpus-snapshot.sh /path/to/monorepo test/corpus/name.golden.json --config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHPCMA="${PHPCMA:-$PROJECT_ROOT/zig-out/bin/PHPCMA}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <project-path> <golden-file-output> [--config]"
    echo ""
    echo "  <project-path>       Path to the PHP project (must contain composer.json or .phpcma.json)"
    echo "  <golden-file-output> Path where golden JSON will be written"
    echo "  --config             Use monorepo mode (.phpcma.json instead of composer.json)"
    exit 1
fi

CORPUS_PATH="$(cd "$1" && pwd)"
GOLDEN_FILE="$2"
MODE="composer"

if [ "${3:-}" = "--config" ]; then
    MODE="config"
fi

# Ensure PHPCMA binary exists
if [ ! -x "$PHPCMA" ]; then
    echo "Building PHPCMA..."
    (cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseFast 2>&1)
fi

# Ensure output directory exists
mkdir -p "$(dirname "$GOLDEN_FILE")"

# Run PHPCMA report
echo "Running PHPCMA report on: $CORPUS_PATH"
START_TIME=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')

if [ "$MODE" = "config" ]; then
    "$PHPCMA" report --config="$CORPUS_PATH/.phpcma.json" --format=json > "$GOLDEN_FILE"
else
    "$PHPCMA" report --composer="$CORPUS_PATH/composer.json" --format=json > "$GOLDEN_FILE"
fi

END_TIME=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')

# Calculate duration
DURATION_NS=$((END_TIME - START_TIME))
DURATION_S=$(echo "scale=2; $DURATION_NS / 1000000000" | bc 2>/dev/null || python3 -c "print(f'{$DURATION_NS/1e9:.2f}')")

# Add metadata to golden file (performance baseline)
# Note: PHPCMA may emit unescaped backslashes in fqn fields (PHP namespaces).
# We sanitize them before parsing via the helper.
python3 "$SCRIPT_DIR/corpus-add-metadata.py" "$GOLDEN_FILE" "$(basename "$CORPUS_PATH")" "$DURATION_S"

echo "Golden file written: $GOLDEN_FILE"
echo "Duration: ${DURATION_S}s"
echo ""
echo "Summary:"
python3 -c "
import json
with open('$GOLDEN_FILE') as f:
    data = json.load(f)
cov = data.get('coverage', {})
print(f'  Files:      {cov.get(\"files\", \"?\")}')
print(f'  Classes:    {cov.get(\"classes\", \"?\")}')
print(f'  Interfaces: {cov.get(\"interfaces\", \"?\")}')
print(f'  Methods:    {cov.get(\"methods\", \"?\")}')
rr = cov.get('resolution_rate', 0)
if rr > 1: rr = rr  # already percentage
print(f'  Resolution: {rr:.1f}%' if rr > 1 else f'  Resolution: {rr*100:.1f}%')
"
