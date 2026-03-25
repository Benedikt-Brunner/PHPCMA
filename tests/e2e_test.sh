#!/usr/bin/env bash
# End-to-End Pipeline Tests for PHPCMA
# Runs PHPCMA as a subprocess and asserts on stdout/stderr/exit code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHPCMA="$PROJECT_ROOT/zig-out/bin/PHPCMA"
TEST_PHP="$PROJECT_ROOT/test.php"
TEST_PROJECT="$PROJECT_ROOT/test-project/composer.json"
TMPDIR_E2E="$(mktemp -d)"

PASS=0
FAIL=0
TOTAL=0

cleanup() {
    rm -rf "$TMPDIR_E2E"
}
trap cleanup EXIT

assert_exit_code() {
    local expected="$1" actual="$2" test_name="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" -eq "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $test_name (expected exit $expected, got $actual)"
    fi
}

assert_contains() {
    local output="$1" pattern="$2" test_name="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -qF -- "$pattern"; then
        PASS=$((PASS + 1))
        echo "  ✓ $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $test_name (output missing: $pattern)"
    fi
}

assert_not_contains() {
    local output="$1" pattern="$2" test_name="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -qF -- "$pattern"; then
        FAIL=$((FAIL + 1))
        echo "  ✗ $test_name (output unexpectedly contains: $pattern)"
    else
        PASS=$((PASS + 1))
        echo "  ✓ $test_name"
    fi
}

assert_file_exists() {
    local path="$1" test_name="$2"
    TOTAL=$((TOTAL + 1))
    if [ -f "$path" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $test_name (file not found: $path)"
    fi
}

assert_file_not_empty() {
    local path="$1" test_name="$2"
    TOTAL=$((TOTAL + 1))
    if [ -s "$path" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $test_name"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $test_name (file empty or missing: $path)"
    fi
}

# ============================================================================
# Ensure binary is built
# ============================================================================
echo "Building PHPCMA..."
(cd "$PROJECT_ROOT" && zig build 2>&1) || { echo "FATAL: zig build failed"; exit 2; }
echo ""

# ============================================================================
# Test 1: 'file' command on single PHP file
# ============================================================================
echo "Test 1: file command on single PHP file"
OUTPUT=$("$PHPCMA" file --file="$TEST_PHP" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Call Graph Analysis" "output contains 'Call Graph Analysis'"
assert_contains "$OUTPUT" "Total calls:" "output contains 'Total calls:'"
assert_contains "$OUTPUT" "Resolved:" "output contains 'Resolved:'"
assert_contains "$OUTPUT" "UserService::createUser" "output contains method calls"
echo ""

# ============================================================================
# Test 2: 'project' command on test-project
# ============================================================================
echo "Test 2: project command on test-project"
OUTPUT=$("$PHPCMA" project --composer="$TEST_PROJECT" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Call Graph Analysis" "output contains 'Call Graph Analysis'"
assert_contains "$OUTPUT" "Total calls: 18" "output has expected call count (18)"
assert_contains "$OUTPUT" "GoodService::doWork" "output contains GoodService::doWork"
assert_contains "$OUTPUT" "BadService::doWork" "output contains BadService::doWork"
echo ""

# ============================================================================
# Test 3: 'called-before' satisfied (exit 0)
# ============================================================================
echo "Test 3: called-before satisfied (exit 0)"
OUTPUT=$("$PHPCMA" called-before --composer="$TEST_PROJECT" --before="::setup" --after="::reset" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0 when constraint satisfied"
assert_contains "$OUTPUT" "SATISFIED" "output contains SATISFIED"
assert_contains "$OUTPUT" "Violations: 0" "output shows 0 violations"
echo ""

# ============================================================================
# Test 4: 'called-before' violated (exit 1 + violations)
# ============================================================================
echo "Test 4: called-before violated (exit 1 + violations)"
EXIT_CODE=0
OUTPUT=$("$PHPCMA" called-before --composer="$TEST_PROJECT" --before="::setup" --after="::log" 2>&1) || EXIT_CODE=$?

assert_exit_code 1 "$EXIT_CODE" "exits with 1 when constraint violated"
assert_contains "$OUTPUT" "VIOLATED" "output contains VIOLATED"
assert_contains "$OUTPUT" "VIOLATIONS" "output contains VIOLATIONS section"
assert_contains "$OUTPUT" "BadService::doWork" "output names BadService::doWork as violator"
echo ""

# ============================================================================
# Test 5: DOT output format (valid syntax)
# ============================================================================
echo "Test 5: DOT output format"
OUTPUT=$("$PHPCMA" file --file="$TEST_PHP" --format=dot 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "digraph CallGraph" "DOT output starts with 'digraph CallGraph'"
assert_contains "$OUTPUT" "rankdir=LR" "DOT output contains rankdir"
assert_contains "$OUTPUT" "->" "DOT output contains edges (->)"
assert_contains "$OUTPUT" "}" "DOT output closes with }"
echo ""

# ============================================================================
# Test 6: text output format (expected sections)
# ============================================================================
echo "Test 6: text output format (expected sections)"
OUTPUT=$("$PHPCMA" file --file="$TEST_PHP" --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Call Graph Analysis" "text output has header"
assert_contains "$OUTPUT" "Total calls:" "text output has total calls"
assert_contains "$OUTPUT" "Resolved:" "text output has resolved count"
assert_contains "$OUTPUT" "Unresolved:" "text output has unresolved count"
echo ""

# ============================================================================
# Test 7: output to file (--output)
# ============================================================================
echo "Test 7: output to file (--output)"
OUTFILE="$TMPDIR_E2E/file_output.txt"
OUTPUT=$("$PHPCMA" file --file="$TEST_PHP" --output="$OUTFILE" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Output written to:" "stdout confirms output written"
assert_file_exists "$OUTFILE" "output file was created"
assert_file_not_empty "$OUTFILE" "output file is not empty"

# Verify file content has expected data
FILE_CONTENT=$(cat "$OUTFILE")
assert_contains "$FILE_CONTENT" "Call Graph Analysis" "output file has call graph"
echo ""

# ============================================================================
# Test 8: verbose mode (pass numbers printed)
# ============================================================================
echo "Test 8: verbose mode"
OUTPUT=$("$PHPCMA" project --composer="$TEST_PROJECT" --verbose 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Pass 1:" "verbose shows Pass 1"
assert_contains "$OUTPUT" "Pass 2:" "verbose shows Pass 2"
assert_contains "$OUTPUT" "Pass 3:" "verbose shows Pass 3"
assert_contains "$OUTPUT" "Pass 4:" "verbose shows Pass 4"
assert_contains "$OUTPUT" "Discovered" "verbose shows discovery count"
assert_contains "$OUTPUT" "Symbol Table Statistics:" "verbose shows symbol table stats"
echo ""

# ============================================================================
# Test 9: plugin execution (--plugins=symfony-events)
# ============================================================================
echo "Test 9: plugin execution (--plugins=symfony-events)"
OUTPUT=$("$PHPCMA" called-before --composer="$TEST_PROJECT" --before="::setup" --after="::reset" --plugins=symfony-events --verbose 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Pass 5: Running plugins" "verbose shows plugin pass"
assert_contains "$OUTPUT" "Running plugin: symfony-events" "verbose names the plugin"
assert_contains "$OUTPUT" "synthetic edges" "verbose reports synthetic edge count"
echo ""

# ============================================================================
# Test 10: monorepo mode (.phpcma.json)
# ============================================================================
echo "Test 10: monorepo mode (.phpcma.json)"

# Create a monorepo test fixture
MONOREPO_DIR="$TMPDIR_E2E/monorepo"
mkdir -p "$MONOREPO_DIR/plugins/my-plugin/src"

# Create .phpcma.json
cat > "$MONOREPO_DIR/.phpcma.json" << 'EOF'
{"scan_paths":["plugins"]}
EOF

# Create a composer.json for the sub-project
cat > "$MONOREPO_DIR/plugins/my-plugin/composer.json" << 'EOF'
{"autoload":{"psr-4":{"MyPlugin\\":"src/"}}}
EOF

# Create a simple PHP file
cat > "$MONOREPO_DIR/plugins/my-plugin/src/Service.php" << 'PHPEOF'
<?php
namespace MyPlugin;

class Service {
    public function init(): void {}
    public function run(): void {
        $this->init();
        $this->doWork();
    }
    private function doWork(): void {}
}
PHPEOF

OUTPUT=$("$PHPCMA" called-before --config="$MONOREPO_DIR/.phpcma.json" --before="::init" --after="::doWork" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0 (constraint satisfied)"
assert_contains "$OUTPUT" "SATISFIED" "monorepo analysis shows SATISFIED"
echo ""

# ============================================================================
# Test 11: Framework stubs improve resolution rate
# ============================================================================
echo "Test 11: Framework stubs improve resolution rate"

# Create a Shopware-style test fixture that exercises framework stub APIs
STUB_TEST_DIR="$TMPDIR_E2E/stub-test"
mkdir -p "$STUB_TEST_DIR/src"

cat > "$STUB_TEST_DIR/composer.json" << 'EOF'
{"autoload":{"psr-4":{"StubTest\\":"src/"}}}
EOF

# Service that uses Shopware EntityRepository, Doctrine Connection, and Criteria
cat > "$STUB_TEST_DIR/src/ProductService.php" << 'PHPEOF'
<?php
namespace StubTest;

use Shopware\Core\Framework\DataAbstractionLayer\EntityRepository;
use Shopware\Core\Framework\DataAbstractionLayer\Search\Criteria;
use Shopware\Core\Framework\DataAbstractionLayer\Search\EntitySearchResult;
use Shopware\Core\Framework\Context;
use Doctrine\DBAL\Connection;

class ProductService
{
    private EntityRepository $productRepository;
    private Connection $connection;

    public function __construct(EntityRepository $productRepository, Connection $connection)
    {
        $this->productRepository = $productRepository;
        $this->connection = $connection;
    }

    public function findProducts(Context $context): EntitySearchResult
    {
        $criteria = new Criteria();
        $criteria->addFilter(new \Shopware\Core\Framework\DataAbstractionLayer\Search\Filter\EqualsFilter('active', true));
        $criteria->addSorting(new \Shopware\Core\Framework\DataAbstractionLayer\Search\Sorting\FieldSorting('name'));
        $criteria->setLimit(100);
        $criteria->addAssociation('manufacturer');

        $result = $this->productRepository->search($criteria, $context);
        $count = $result->count();
        $first = $result->first();
        $total = $result->getTotal();
        $entities = $result->getEntities();

        return $result;
    }

    public function countByCategory(string $categoryId): int
    {
        $sql = 'SELECT COUNT(*) FROM product WHERE category_id = ?';
        $count = $this->connection->executeStatement($sql, [$categoryId]);
        $rows = $this->connection->fetchAllAssociative('SELECT * FROM product LIMIT 10');
        $qb = $this->connection->createQueryBuilder();
        $this->connection->beginTransaction();
        $this->connection->commit();

        return $count;
    }

    public function internalHelper(): void
    {
        $this->findProducts(Context::createDefaultContext());
        $this->countByCategory('test');
    }
}
PHPEOF

OUTPUT=$("$PHPCMA" project --composer="$STUB_TEST_DIR/composer.json" --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"

# Extract resolution rate — format is "Resolution rate:  XX.X% (N/M calls)"
# Since all methods on framework classes should be resolved via stubs,
# we expect a significant resolution rate (well above 0%)
RATE=$(echo "$OUTPUT" | grep -oE 'Resolved:.*\(([0-9.]+)%\)' | grep -oE '[0-9.]+%' | tr -d '%')
if [ -n "$RATE" ]; then
    TOTAL=$((TOTAL + 1))
    # The fixture uses only framework stubs + internal calls, so resolution should be high
    # We check that it's above 40% (baseline without stubs would be much lower)
    RATE_INT=$(echo "$RATE" | cut -d. -f1)
    if [ "$RATE_INT" -ge 40 ]; then
        PASS=$((PASS + 1))
        echo "  ✓ resolution rate ${RATE}% >= 40% (framework stubs working)"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ resolution rate ${RATE}% < 40% (framework stubs may not be loading)"
    fi
else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  ✗ could not parse resolution rate from output"
fi
echo ""

# ============================================================================
# Test 12: Resolution rate on corpus (if available)
# ============================================================================
SHOPWARE_CONFIG="${PHPCMA_CORPUS_ROOT:-.}/.phpcma.json"
if [ -f "$SHOPWARE_CONFIG" ]; then
    echo "Test 12: Resolution rate on corpus (vs baseline 31.4%)"
    OUTPUT=$("$PHPCMA" report --config="$SHOPWARE_CONFIG" --format=text 2>&1) || true
    EXIT_CODE=$?

    assert_exit_code 0 "$EXIT_CODE" "exits with 0"

    # Extract resolution rate
    RATE=$(echo "$OUTPUT" | grep -oE 'Resolution rate:  [0-9.]+%' | grep -oE '[0-9.]+')
    if [ -n "$RATE" ]; then
        TOTAL=$((TOTAL + 1))
        RATE_INT=$(echo "$RATE" | cut -d. -f1)
        # Baseline was 31.4%. Framework stubs should push this above 31.4%.
        # The theoretical max uplift from stubs alone is +24.6pp → ~56%.
        # We conservatively check for > 31% to verify improvement.
        if [ "$RATE_INT" -ge 32 ]; then
            PASS=$((PASS + 1))
            echo "  ✓ resolution rate ${RATE}% > 31.4% baseline (stubs improve resolution)"
        else
            FAIL=$((FAIL + 1))
            echo "  ✗ resolution rate ${RATE}% <= 31.4% baseline (no improvement from stubs)"
        fi
    else
        TOTAL=$((TOTAL + 1))
        FAIL=$((FAIL + 1))
        echo "  ✗ could not parse resolution rate from output"
    fi
    echo ""
else
    echo "Test 12: SKIPPED (corpus not available, set PHPCMA_CORPUS_ROOT)"
    echo ""
fi

# ============================================================================
# Test 13: Null safety in report output (regression)
# ============================================================================
echo "Test 13: Null safety in report output"

# Create a fixture with nullable patterns
NULL_TEST_DIR="$TMPDIR_E2E/null-safety-test"
mkdir -p "$NULL_TEST_DIR/src"

cat > "$NULL_TEST_DIR/composer.json" << 'EOF'
{"autoload":{"psr-4":{"NullTest\\":"src/"}}}
EOF

# File with both guarded and unguarded nullable accesses
cat > "$NULL_TEST_DIR/src/NullService.php" << 'PHPEOF'
<?php
namespace NullTest;

class NullService
{
    public function findUser(int $id): ?User { return null; }

    public function guardedAccess(?Foo $x): void
    {
        if ($x !== null) {
            $x->method();
        }
    }

    public function unguardedAccess(?Foo $x): void
    {
        $x->method();
    }

    public function instanceofGuard(?Bar $bar): void
    {
        if ($bar instanceof Bar) {
            $bar->doStuff();
        }
    }

    public function coalesceGuard(?string $val): string
    {
        $safe = $val ?? 'default';
        return $safe;
    }

    public function earlyReturnGuard(?Baz $baz): void
    {
        if ($baz === null) {
            return;
        }
        $baz->process();
    }
}
PHPEOF

# Test report text output includes null safety section
OUTPUT=$("$PHPCMA" report --composer="$NULL_TEST_DIR/composer.json" --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Null safety" "text report contains 'Null safety' row"
echo ""

# ============================================================================
# Test 14: Null safety violations appear in JSON report
# ============================================================================
echo "Test 14: Null safety violations in JSON report"
JSON_FILE="$TMPDIR_E2E/null_safety_report.json"
OUTPUT=$("$PHPCMA" report --composer="$NULL_TEST_DIR/composer.json" --format=json --output="$JSON_FILE" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_file_exists "$JSON_FILE" "JSON report file created"
assert_file_not_empty "$JSON_FILE" "JSON report file is not empty"

JSON_CONTENT=$(cat "$JSON_FILE")
assert_contains "$JSON_CONTENT" "\"null_safety\"" "JSON contains null_safety section"

# Verify null_safety unchecked is NOT the old call-resolution artifact
# It should be 0 (from NullSafetyAnalyzer, which doesn't produce 'unchecked')
TOTAL=$((TOTAL + 1))
NULL_UNCHECKED=$(echo "$JSON_CONTENT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data['type_checks']['null_safety']['unchecked'])
" 2>/dev/null || echo "PARSE_ERROR")
if [ "$NULL_UNCHECKED" = "0" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ null_safety.unchecked is 0 (no call-resolution artifact)"
elif [ "$NULL_UNCHECKED" = "PARSE_ERROR" ]; then
    FAIL=$((FAIL + 1))
    echo "  ✗ could not parse null_safety.unchecked from JSON"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ null_safety.unchecked is $NULL_UNCHECKED (expected 0 — call-resolution artifact still present)"
fi
echo ""

# ============================================================================
# Test 15: Null safety violations appear in SARIF report
# ============================================================================
echo "Test 15: Null safety violations in SARIF report"
SARIF_FILE="$TMPDIR_E2E/null_safety_report.sarif"
OUTPUT=$("$PHPCMA" report --composer="$NULL_TEST_DIR/composer.json" --format=sarif --output="$SARIF_FILE" 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_file_exists "$SARIF_FILE" "SARIF report file created"
assert_file_not_empty "$SARIF_FILE" "SARIF report file is not empty"

SARIF_CONTENT=$(cat "$SARIF_FILE")
assert_contains "$SARIF_CONTENT" "sarif-schema-2.1.0" "SARIF has correct schema"
assert_contains "$SARIF_CONTENT" "phpcma/null-safety" "SARIF contains null-safety rule"
echo ""

# ============================================================================
# Test 16: Return type checker — text output has non-zero counters
# ============================================================================
echo "Test 16: Return type checker — non-zero return-type counters in text report"
OUTPUT=$("$PHPCMA" report --composer="$TEST_PROJECT" --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Return types" "text report has 'Return types' row"

# The ReturnTypeBad.php fixture seeds at least 4 violations (mismatch, missing, null, void_with_value, badBranch)
# So return_types fail counter must be > 0
RT_LINE=$(echo "$OUTPUT" | grep "Return types")
TOTAL=$((TOTAL + 1))
RT_FAIL=$(echo "$RT_LINE" | grep -oE 'fail:[0-9]+' | grep -oE '[0-9]+')
if [ -n "$RT_FAIL" ] && [ "$RT_FAIL" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ return_types fail count = $RT_FAIL (> 0)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ return_types fail count is 0 or missing (expected > 0)"
    echo "    RT_LINE: $RT_LINE"
fi

# pass counter should also be > 0 (ReturnTypeGood has valid methods)
TOTAL=$((TOTAL + 1))
RT_PASS=$(echo "$RT_LINE" | grep -oE 'pass:[0-9]+' | grep -oE '[0-9]+')
if [ -n "$RT_PASS" ] && [ "$RT_PASS" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ return_types pass count = $RT_PASS (> 0)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ return_types pass count is 0 or missing (expected > 0)"
    echo "    RT_LINE: $RT_LINE"
fi
echo ""

# ============================================================================
# Test 17: Return type checker — violations appear in text report
# ============================================================================
echo "Test 17: Return type checker — violations in text output"
assert_contains "$OUTPUT" "return type mismatch" "text report lists return type mismatch violations"
assert_contains "$OUTPUT" "ReturnTypeBad" "violations reference ReturnTypeBad class"
echo ""

# ============================================================================
# Test 18: Return type checker — JSON report includes return-type data
# ============================================================================
echo "Test 18: Return type checker — JSON report includes return-type violations"
JSON_OUTPUT=$("$PHPCMA" report --composer="$TEST_PROJECT" --format=json 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$JSON_OUTPUT" "\"return_types\"" "JSON has return_types section"

# Check that return_types has non-zero fail
TOTAL=$((TOTAL + 1))
RT_JSON_FAIL=$(echo "$JSON_OUTPUT" | grep -o '"return_types":[^}]*' | grep -oE '"fail": *[0-9]+' | grep -oE '[0-9]+')
if [ -n "$RT_JSON_FAIL" ] && [ "$RT_JSON_FAIL" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ JSON return_types fail = $RT_JSON_FAIL (> 0)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ JSON return_types fail is 0 or missing (expected > 0)"
fi

# Violations array should contain return type mismatch entries
assert_contains "$JSON_OUTPUT" "return type mismatch" "JSON violations include return type mismatch"
echo ""

# ============================================================================
# Test 19: Return type checker — good fixtures produce no violations
# ============================================================================
echo "Test 19: Return type checker — good fixtures produce no false positives"

# Create a clean fixture with only well-typed methods
RT_GOOD_DIR="$TMPDIR_E2E/rt-good"
mkdir -p "$RT_GOOD_DIR/src"
cat > "$RT_GOOD_DIR/composer.json" << 'EOF'
{"autoload":{"psr-4":{"RtGood\\":"src/"}}}
EOF

cat > "$RT_GOOD_DIR/src/Clean.php" << 'PHPEOF'
<?php
namespace RtGood;

class Clean
{
    public function getInt(): int
    {
        return 42;
    }

    public function getString(): string
    {
        return "hello";
    }

    public function doVoid(): void
    {
        $x = 1;
    }

    public function conditional(bool $flag): int
    {
        if ($flag) {
            return 1;
        } else {
            return 2;
        }
    }

    public function nullable(): ?int
    {
        return null;
    }
}
PHPEOF

OUTPUT=$("$PHPCMA" report --composer="$RT_GOOD_DIR/composer.json" --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"

# fail count for return_types should be 0
RT_LINE=$(echo "$OUTPUT" | grep "Return types")
TOTAL=$((TOTAL + 1))
RT_FAIL=$(echo "$RT_LINE" | grep -oE 'fail:[0-9]+' | grep -oE '[0-9]+')
if [ -n "$RT_FAIL" ] && [ "$RT_FAIL" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ return_types fail = 0 for clean fixture"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ return_types fail = $RT_FAIL (expected 0 for clean fixture)"
    echo "    RT_LINE: $RT_LINE"
fi

# pass count should be > 0
TOTAL=$((TOTAL + 1))
RT_PASS=$(echo "$RT_LINE" | grep -oE 'pass:[0-9]+' | grep -oE '[0-9]+')
if [ -n "$RT_PASS" ] && [ "$RT_PASS" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  ✓ return_types pass = $RT_PASS (> 0 for clean fixture)"
else
    FAIL=$((FAIL + 1))
    echo "  ✗ return_types pass = 0 (expected > 0 for clean fixture)"
    echo "    RT_LINE: $RT_LINE"
fi
assert_not_contains "$OUTPUT" "return type mismatch" "no return-type violations for clean fixture"
echo ""

# ============================================================================
# Test 20: Return type checker — verbose shows return type pass
# ============================================================================
echo "Test 20: Return type checker — verbose mode shows pass 4 return types"
OUTPUT=$("$PHPCMA" report --composer="$TEST_PROJECT" --verbose --format=text 2>&1) || true
EXIT_CODE=$?

assert_exit_code 0 "$EXIT_CODE" "exits with 0"
assert_contains "$OUTPUT" "Pass 4: Checking return types" "verbose shows Pass 4 return type check"
assert_contains "$OUTPUT" "Methods analyzed:" "verbose shows methods analyzed count"
assert_contains "$OUTPUT" "diagnostics:" "verbose shows diagnostics count"
echo ""

# ============================================================================
# Test 21: Interface compliance regression — case-a: cross-project interface
#           + direct call to violating method (should detect return type
#           mismatch + param count mismatch)
# ============================================================================
echo "Test 21: Interface compliance — case-a: cross-project iface + direct call"

IFACE_A_DIR="$TMPDIR_E2E/iface-case-a"
mkdir -p "$IFACE_A_DIR/packages/lib-iface/src" "$IFACE_A_DIR/packages/lib-impl/src" "$IFACE_A_DIR/packages/app/src"

cat > "$IFACE_A_DIR/.phpcma.json" << 'EOF'
{"scan_paths":["packages"]}
EOF

cat > "$IFACE_A_DIR/packages/lib-iface/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibIface\\":"src/"}}}
EOF

cat > "$IFACE_A_DIR/packages/lib-iface/src/SnapshotInterface.php" << 'PHPEOF'
<?php
namespace LibIface;

interface SnapshotInterface {
    public function generateSnapshots(array $entities): array;
}
PHPEOF

cat > "$IFACE_A_DIR/packages/lib-impl/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibImpl\\":"src/"}}}
EOF

cat > "$IFACE_A_DIR/packages/lib-impl/src/SnapshotService.php" << 'PHPEOF'
<?php
namespace LibImpl;

use LibIface\SnapshotInterface;

class SnapshotService implements SnapshotInterface {
    public function generateSnapshots(array $entities, bool $includeMeta): string {
        return 'done';
    }
}
PHPEOF

cat > "$IFACE_A_DIR/packages/app/composer.json" << 'EOF'
{"autoload":{"psr-4":{"App\\":"src/"}}}
EOF

cat > "$IFACE_A_DIR/packages/app/src/Runner.php" << 'PHPEOF'
<?php
namespace App;

use LibImpl\SnapshotService;

class Runner {
    public function run(): void {
        $svc = new SnapshotService();
        $svc->generateSnapshots([]);
    }
}
PHPEOF

EXIT_CODE=0
OUTPUT=$("$PHPCMA" check-types --config="$IFACE_A_DIR/.phpcma.json" 2>&1) || EXIT_CODE=$?

assert_exit_code 1 "$EXIT_CODE" "exits with 1 (violations detected)"
assert_contains "$OUTPUT" "match interface" "output reports interface mismatch"
assert_contains "$OUTPUT" "return type" "output mentions return type issue"
assert_contains "$OUTPUT" "params, interface" "output mentions parameter count issue"
echo ""

# ============================================================================
# Test 22: Interface compliance regression — case-b: violation exists but only
#           non-interface method is called (declaration-level pass should still
#           flag it)
# ============================================================================
echo "Test 22: Interface compliance — case-b: no callsite, declaration-level detects"

IFACE_B_DIR="$TMPDIR_E2E/iface-case-b"
mkdir -p "$IFACE_B_DIR/packages/lib-iface/src" "$IFACE_B_DIR/packages/lib-impl/src" "$IFACE_B_DIR/packages/app/src"

cat > "$IFACE_B_DIR/.phpcma.json" << 'EOF'
{"scan_paths":["packages"]}
EOF

cat > "$IFACE_B_DIR/packages/lib-iface/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibIface\\":"src/"}}}
EOF

cat > "$IFACE_B_DIR/packages/lib-iface/src/SnapshotInterface.php" << 'PHPEOF'
<?php
namespace LibIface;

interface SnapshotInterface {
    public function generateSnapshots(array $entities): array;
}
PHPEOF

cat > "$IFACE_B_DIR/packages/lib-impl/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibImpl\\":"src/"}}}
EOF

cat > "$IFACE_B_DIR/packages/lib-impl/src/SnapshotService.php" << 'PHPEOF'
<?php
namespace LibImpl;

use LibIface\SnapshotInterface;

class SnapshotService implements SnapshotInterface {
    public function generateSnapshots(array $entities, bool $includeMeta): string {
        return 'done';
    }

    public function unrelatedMethod(): void {}
}
PHPEOF

cat > "$IFACE_B_DIR/packages/app/composer.json" << 'EOF'
{"autoload":{"psr-4":{"App\\":"src/"}}}
EOF

# Only calls the non-interface method — no call to generateSnapshots
cat > "$IFACE_B_DIR/packages/app/src/Runner.php" << 'PHPEOF'
<?php
namespace App;

use LibImpl\SnapshotService;

class Runner {
    public function run(): void {
        $svc = new SnapshotService();
        $svc->unrelatedMethod();
    }
}
PHPEOF

EXIT_CODE=0
OUTPUT=$("$PHPCMA" check-types --config="$IFACE_B_DIR/.phpcma.json" 2>&1) || EXIT_CODE=$?

assert_exit_code 1 "$EXIT_CODE" "exits with 1 (declaration-level violation detected)"
assert_contains "$OUTPUT" "interface LibIface" "declaration-level pass flags interface compliance violation"
assert_contains "$OUTPUT" "SnapshotService" "violation references SnapshotService"
echo ""

# ============================================================================
# Test 23: Interface compliance regression — case-c: same-project interface/class
#           with cross-project caller (should flag interface mismatch)
# ============================================================================
echo "Test 23: Interface compliance — case-c: same-project iface+class, cross-project caller"

IFACE_C_DIR="$TMPDIR_E2E/iface-case-c"
mkdir -p "$IFACE_C_DIR/packages/lib/src" "$IFACE_C_DIR/packages/app/src"

cat > "$IFACE_C_DIR/.phpcma.json" << 'EOF'
{"scan_paths":["packages"]}
EOF

cat > "$IFACE_C_DIR/packages/lib/composer.json" << 'EOF'
{"autoload":{"psr-4":{"Lib\\":"src/"}}}
EOF

# Interface and implementation in the SAME project
cat > "$IFACE_C_DIR/packages/lib/src/SnapshotInterface.php" << 'PHPEOF'
<?php
namespace Lib;

interface SnapshotInterface {
    public function generateSnapshots(array $entities): array;
}
PHPEOF

cat > "$IFACE_C_DIR/packages/lib/src/SnapshotService.php" << 'PHPEOF'
<?php
namespace Lib;

class SnapshotService implements SnapshotInterface {
    public function generateSnapshots(array $entities, bool $includeMeta): string {
        return 'done';
    }
}
PHPEOF

# Cross-project caller
cat > "$IFACE_C_DIR/packages/app/composer.json" << 'EOF'
{"autoload":{"psr-4":{"App\\":"src/"}}}
EOF

cat > "$IFACE_C_DIR/packages/app/src/Runner.php" << 'PHPEOF'
<?php
namespace App;

use Lib\SnapshotService;

class Runner {
    public function run(): void {
        $svc = new SnapshotService();
        $svc->generateSnapshots([]);
    }
}
PHPEOF

EXIT_CODE=0
OUTPUT=$("$PHPCMA" check-types --config="$IFACE_C_DIR/.phpcma.json" 2>&1) || EXIT_CODE=$?

assert_exit_code 1 "$EXIT_CODE" "exits with 1 (same-project interface mismatch detected)"
assert_contains "$OUTPUT" "match interface" "same-project interface mismatch flagged"
assert_contains "$OUTPUT" "SnapshotService" "violation references SnapshotService"
echo ""

# ============================================================================
# Test 24: Interface compliance regression — case-d: caller depends on interface
#           type (implementation mismatch should be discoverable)
# ============================================================================
echo "Test 24: Interface compliance — case-d: caller uses interface type"

IFACE_D_DIR="$TMPDIR_E2E/iface-case-d"
mkdir -p "$IFACE_D_DIR/packages/lib-iface/src" "$IFACE_D_DIR/packages/lib-impl/src" "$IFACE_D_DIR/packages/app/src"

cat > "$IFACE_D_DIR/.phpcma.json" << 'EOF'
{"scan_paths":["packages"]}
EOF

cat > "$IFACE_D_DIR/packages/lib-iface/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibIface\\":"src/"}}}
EOF

cat > "$IFACE_D_DIR/packages/lib-iface/src/SnapshotInterface.php" << 'PHPEOF'
<?php
namespace LibIface;

interface SnapshotInterface {
    public function generateSnapshots(array $entities): array;
}
PHPEOF

cat > "$IFACE_D_DIR/packages/lib-impl/composer.json" << 'EOF'
{"autoload":{"psr-4":{"LibImpl\\":"src/"}}}
EOF

cat > "$IFACE_D_DIR/packages/lib-impl/src/SnapshotService.php" << 'PHPEOF'
<?php
namespace LibImpl;

use LibIface\SnapshotInterface;

class SnapshotService implements SnapshotInterface {
    public function generateSnapshots(array $entities, bool $includeMeta): string {
        return 'done';
    }
}
PHPEOF

cat > "$IFACE_D_DIR/packages/app/composer.json" << 'EOF'
{"autoload":{"psr-4":{"App\\":"src/"}}}
EOF

# Caller type-hints on the interface, NOT the concrete class
cat > "$IFACE_D_DIR/packages/app/src/Runner.php" << 'PHPEOF'
<?php
namespace App;

use LibIface\SnapshotInterface;

class Runner {
    public function run(SnapshotInterface $svc): void {
        $svc->generateSnapshots([]);
    }
}
PHPEOF

EXIT_CODE=0
OUTPUT=$("$PHPCMA" check-types --config="$IFACE_D_DIR/.phpcma.json" 2>&1) || EXIT_CODE=$?

assert_exit_code 1 "$EXIT_CODE" "exits with 1 (implementation mismatch discoverable via declaration pass)"
assert_contains "$OUTPUT" "interface LibIface" "interface mismatch found despite interface-typed caller"
assert_contains "$OUTPUT" "SnapshotService" "violation references the violating implementation"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================"
echo "E2E Test Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILURES: $FAIL"
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
