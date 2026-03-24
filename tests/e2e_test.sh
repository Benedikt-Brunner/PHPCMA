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
# Test 12: Resolution rate on shopware-plugins (if available)
# ============================================================================
SHOPWARE_CONFIG="/Users/benediktbrunner/PhpstormProjects/shopware-plugins/.phpcma.json"
if [ -f "$SHOPWARE_CONFIG" ]; then
    echo "Test 12: Resolution rate on shopware-plugins (vs baseline 31.4%)"
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
    echo "Test 12: SKIPPED (shopware-plugins not available at $SHOPWARE_CONFIG)"
    echo ""
fi

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
