#!/usr/bin/env bash
# Benchmark PHPCMA: run report N times, record median wall clock, CPU time, peak memory.
# Usage: scripts/benchmark.sh [--corpus <path>] [--runs N] [--output <json>]
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHPCMA="$PROJECT_ROOT/zig-out/bin/PHPCMA"
RUNS=5
CORPUS_COMPOSER="$PROJECT_ROOT/test-project/composer.json"
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus)   CORPUS_COMPOSER="$2"; shift 2 ;;
        --runs)     RUNS="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--corpus <composer.json>] [--runs N] [--output <file.json>]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$PHPCMA" ]; then
    echo "Building PHPCMA (ReleaseFast)..."
    (cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseFast 2>&1)
fi

if [ ! -f "$CORPUS_COMPOSER" ]; then
    echo "Error: corpus composer.json not found: $CORPUS_COMPOSER" >&2
    exit 1
fi

# Count PHP files in the corpus
CORPUS_DIR="$(dirname "$CORPUS_COMPOSER")"
FILE_COUNT=$(find "$CORPUS_DIR" -name '*.php' -type f 2>/dev/null | wc -l | tr -d ' ')

echo "PHPCMA Performance Benchmark"
echo "============================="
echo "Corpus:    $CORPUS_COMPOSER"
echo "PHP files: $FILE_COUNT"
echo "Runs:      $RUNS"
echo ""

WALL_TIMES=()
CPU_TIMES=()
PEAK_MEMS=()

for i in $(seq 1 "$RUNS"); do
    # Use Python wrapper for high-precision wall clock + resource usage
    RESULT=$(python3 -c "
import subprocess, time, resource, json
t0 = time.monotonic()
p = subprocess.run(['$PHPCMA', 'report', '--composer=$CORPUS_COMPOSER'],
                   capture_output=True)
t1 = time.monotonic()
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
wall_ms = int((t1 - t0) * 1000)
cpu_ms = int((ru.ru_utime + ru.ru_stime) * 1000)
# macOS: ru_maxrss in bytes; Linux: in KB
import sys
rss = ru.ru_maxrss
if sys.platform != 'darwin':
    rss *= 1024
mem_mb = round(rss / (1024*1024), 1)
print(json.dumps({'wall': wall_ms, 'cpu': cpu_ms, 'mem': mem_mb}))
")

    WALL_MS=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['wall'])")
    CPU_MS=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['cpu'])")
    PEAK_MB=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['mem'])")

    WALL_TIMES+=("$WALL_MS")
    CPU_TIMES+=("$CPU_MS")
    PEAK_MEMS+=("$PEAK_MB")

    printf "  Run %d/%d: wall=%dms cpu=%dms mem=%.1fMB\n" "$i" "$RUNS" "$WALL_MS" "$CPU_MS" "$PEAK_MB"
done

# Build comma-separated lists for Python
WALL_CSV=$(IFS=,; echo "${WALL_TIMES[*]}")
CPU_CSV=$(IFS=,; echo "${CPU_TIMES[*]}")
MEM_CSV=$(IFS=,; echo "${PEAK_MEMS[*]}")

# Compute medians using Python
MEDIAN_WALL=$(python3 -c "
import statistics
vals = [${WALL_CSV}]
print(int(statistics.median(vals)))
")

MEDIAN_CPU=$(python3 -c "
import statistics
vals = [${CPU_CSV}]
print(int(statistics.median(vals)))
")

MEDIAN_MEM=$(python3 -c "
import statistics
vals = [${MEM_CSV}]
print(round(statistics.median(vals), 1))
")

COMMIT=$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE=$(date +%Y-%m-%d)
CORPUS_NAME=$(basename "$(dirname "$CORPUS_COMPOSER")")

echo ""
echo "Results (median of $RUNS runs):"
echo "  Wall clock: ${MEDIAN_WALL}ms"
echo "  CPU time:   ${MEDIAN_CPU}ms"
echo "  Peak memory: ${MEDIAN_MEM}MB"

# Build JSON result
JSON=$(python3 -c "
import json, sys
result = {
    'corpus': '${CORPUS_NAME}',
    'files': ${FILE_COUNT},
    'wall_clock_median_ms': ${MEDIAN_WALL},
    'cpu_time_median_ms': ${MEDIAN_CPU},
    'peak_memory_mb': ${MEDIAN_MEM},
    'date': '${DATE}',
    'commit': '${COMMIT}',
    'runs': ${RUNS},
    'wall_clock_all_ms': [${WALL_CSV}],
    'cpu_time_all_ms': [${CPU_CSV}],
    'peak_memory_all_mb': [${MEM_CSV}]
}
print(json.dumps(result, indent=2))
")

if [ -n "$OUTPUT" ]; then
    echo "$JSON" > "$OUTPUT"
    echo ""
    echo "Written to: $OUTPUT"
else
    echo ""
    echo "$JSON"
fi
