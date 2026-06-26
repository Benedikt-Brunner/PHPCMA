#!/usr/bin/env bash
#
# Scripted stdio MCP protocol smoke test.
#
# Builds the binary, drives a canned JSON-RPC session over stdio against the
# `phpcma mcp` server, and asserts the responses. Exits non-zero on any failure
# so it can gate CI / pre-push.
#
# Usage: scripts/mcp_smoke.sh [path/to/composer.json]
#   Defaults to the bundled test-project.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

composer="${1:-$repo_root/test-project/composer.json}"
bin="$repo_root/zig-out/bin/PHPCMA"

echo "==> building"
zig build >/dev/null

echo "==> driving MCP session (project: $composer)"
out="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"load_project\",\"arguments\":{\"project_path\":\"$composer\"}}}" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query","arguments":{"query":{"start":{"match":{"kind":"class"}},"select":"count"}}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query","arguments":{"query":{"start":{"fqn":"Test\\Logger::log"},"traverse":{"direction":"callers","max_depth":5},"select":"nodes"}}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"called_before","arguments":{"before":"::setup","after":"::log"}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query","arguments":{"bogus":1}}}' \
  '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"query","arguments":{"query":{"start":{"fqn":"Test\\Logger::log"},"traverse":{"direction":"callers","max_depth":5,"edge_filter":{"exclude_tests":true}},"select":"nodes"}}}}' \
  '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"references","arguments":{"fqn":"Test\\Logger"}}}' \
  '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"describe_symbol","arguments":{"fqn":"Test\\Logger::log"}}}' \
  '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"describe_symbol","arguments":{"fqn":"Test\\Logger","members":"none"}}}' \
  '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"resolve_interface","arguments":{"fqn":"Test\\Notify\\NotifierInterface"}}}' \
  '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"resolve_interface","arguments":{"fqn":"Test\\Notify\\SmsNotifier"}}}' \
  '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"find_by_type","arguments":{"type":"Test\\Logger"}}}' \
  '{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"find_by_type","arguments":{"type":"Test\\Notify\\NotifierInterface","include_subtypes":true}}}' \
  '{"jsonrpc":"2.0","id":36,"method":"tools/call","params":{"name":"check_conformance","arguments":{"fqn":"Test\\Notify\\EmailNotifier","include_ok":true}}}' \
  '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"impact","arguments":{"fqn":"Test\\Logger::log","verbose":true}}}' \
  '{"jsonrpc":"2.0","id":37,"method":"tools/call","params":{"name":"impact","arguments":{"fqn":"Test\\Logger::log","simulate":{"param_type_change":{"position":0,"to":"Test\\Logger"}}}}}' \
  '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"impact","arguments":{"fqn":"Test\\Logger::log"}}}' \
  '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"query","arguments":{"query":{"start":{"fqn":"Test\\Notify\\SmsNotifier::send"},"traverse":{"direction":"callers","max_depth":3},"select":"edges"}}}}' \
  | "$bin" mcp 2>/dev/null)"

fail() { echo "FAIL: $1" >&2; echo "--- full output ---" >&2; echo "$out" >&2; exit 1; }

# Each response is one JSON line; check with a tiny python helper.
check() { # <id> <python-expr over `r` (the result object)> <label>
  python3 - "$out" "$1" "$2" "$3" <<'PY'
import sys, json
out, rid, expr, label = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
for line in out.splitlines():
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    if o.get("id") == rid:
        r = o.get("result", {})
        txt = r["content"][0]["text"] if r.get("content") else ""
        ok = eval(expr)
        if not ok:
            print(f"FAIL [{label}] id={rid}: {txt[:200]}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
print(f"FAIL [{label}]: no response with id={rid}", file=sys.stderr)
sys.exit(1)
PY
}

check 2 "sorted([t['name'] for t in r['tools']]) == ['called_before','check_conformance','dependencies','describe_symbol','find_by_type','impact','load_project','query','references','resolve_interface']" "tools/list" || fail "tools/list"
check 3 "'PHPCMA project loaded' in txt" "load_project" || fail "load_project"
# Priming payload exposes active plugins, synthetic-edge count, and the
# unresolved-reason breakdown (milestone 0 observability/transparency).
check 3 "'active plugins' in txt" "load_project plugins line" || fail "load_project plugins line"
check 3 "'synthetic (plugin' in txt" "load_project synthetic line" || fail "load_project synthetic line"
# Resolution rate is always reported (trust signal). The per-reason
# "unresolved breakdown" line only appears when unresolved edges exist; with
# DI-aware resolution test-project now resolves fully, so it may be absent.
check 3 "'resolution rate' in txt" "load_project resolution rate" || fail "load_project resolution rate"
check 4 "json.loads(txt)['count'] >= 1" "query count" || fail "query count"
check 5 "'Test\\\\DeepCaller::process' in [n['fqn'] for n in json.loads(txt)['nodes']]" "query callers" || fail "query callers"
# By default a test-file caller of Logger::log is included.
check 5 "'Tests\\\\LoggerUsageTest::testLogging' in [n['fqn'] for n in json.loads(txt)['nodes']]" "test caller present by default" || fail "test caller present"
check 6 "json.loads(txt)['satisfied'] == False and json.loads(txt)['violations_count'] >= 1" "called_before" || fail "called_before"
check 7 "r.get('isError') == True" "invalid query rejected" || fail "invalid query"
# exclude_tests drops the test-file caller but keeps the production caller.
check 8 "'Tests\\\\LoggerUsageTest::testLogging' not in [n['fqn'] for n in json.loads(txt)['nodes']] and 'Test\\\\DeepCaller::process' in [n['fqn'] for n in json.loads(txt)['nodes']]" "exclude_tests" || fail "exclude_tests"
# references: non-call occurrences of Test\Logger (constructor type hints + a
# test `use` import), FQN-scoped.
check 9 "json.loads(txt)['summary']['total'] >= 6" "references total" || fail "references total"
check 9 "json.loads(txt)['summary']['by_kind'].get('type_hint', 0) >= 5 and json.loads(txt)['summary']['by_kind'].get('use_import', 0) >= 1" "references by_kind" || fail "references by_kind"
# describe_symbol: a method returns its typed signature (parameters + return
# triad), and a type target lists its members.
check 30 "json.loads(txt)['symbol'] == 'method' and isinstance(json.loads(txt)['parameters'], list) and 'return' in json.loads(txt)" "describe_symbol method" || fail "describe_symbol method"
check 31 "json.loads(txt)['symbol'] == 'class' and 'log' in json.loads(txt)['members']['own_methods']" "describe_symbol class" || fail "describe_symbol class"
# resolve_interface: NotifierInterface has two implementors but services.yaml
# binds it to SmsNotifier (di_config wins). Reverse query confirms SmsNotifier
# is the bound implementor.
check 32 "json.loads(txt)['binding']['kind'] == 'di_config' and json.loads(txt)['binding']['resolves_to'] == 'Test\\\\Notify\\\\SmsNotifier' and len(json.loads(txt)['implementors']) >= 2" "resolve_interface forward" || fail "resolve_interface forward"
check 33 "'Test\\\\Notify\\\\NotifierInterface' in json.loads(txt)['is_di_bound_for'] and json.loads(txt)['bound_kind'].get('Test\\\\Notify\\\\NotifierInterface') == 'di_config'" "resolve_interface reverse" || fail "resolve_interface reverse"
# find_by_type: Test\Logger is consumed (constructor param) and held (property)
# by several services; FQCN-resolved so producers count is 0.
check 34 "json.loads(txt)['summary']['consumers'] >= 1 and json.loads(txt)['summary']['holders'] >= 1" "find_by_type consumers/holders" || fail "find_by_type consumers/holders"
# find_by_type with include_subtypes widens an interface to its implementors, so
# matched_types contains more than just the interface itself.
check 35 "len(json.loads(txt)['matched_types']) >= 2 and 'Test\\\\Notify\\\\NotifierInterface' in json.loads(txt)['matched_types']" "find_by_type include_subtypes" || fail "find_by_type include_subtypes"
# check_conformance: EmailNotifier correctly implements NotifierInterface::send,
# so it has zero findings and one conformant member (with include_ok).
check 36 "json.loads(txt)['summary']['missing'] == 0 and json.loads(txt)['summary']['mismatches'] == 0 and json.loads(txt)['summary']['ok'] >= 1 and 'Test\\\\Notify\\\\NotifierInterface' in json.loads(txt)['checked']['interfaces']" "check_conformance conformant" || fail "check_conformance conformant"
# impact on a single (non-monorepo) project: this exercises the boundary
# analyzer's config path, which slices root_path from the project path — a
# regression guard against the request-scoped-path dangling crash. Also checks
# the signature-aware fields (declared arity + per-call-site arg counts).
check 20 "json.loads(txt)['signature']['required_params'] == 1 and json.loads(txt)['call_site_arity']['max'] == 1" "impact signature" || fail "impact signature"
check 20 "all(c['arg_count'] == 1 for g in json.loads(txt)['groups'] for c in g['callers'])" "impact arg_count" || fail "impact arg_count"
# Verbose callers now carry observed arg types + result use.
check 20 "all('arg_types' in c and 'result_used' in c for g in json.loads(txt)['groups'] for c in g['callers'])" "impact arg_types/result_used" || fail "impact arg_types"
# simulate: narrowing Logger::log's string param to a class type is breaking,
# and every call site is typed (full coverage).
check 37 "json.loads(txt)['type_breaking_change']['param_type_change']['verdict'] == 'breaking' and len(json.loads(txt)['type_breaking_change']['param_type_change']['incompatible_call_sites']) >= 1" "impact simulate breaking" || fail "impact simulate breaking"
# Default (terse) impact: the verdict + per-package counts survive, but the
# heavy per-caller list is omitted unless `verbose` is passed.
check 22 "json.loads(txt).get('callers_omitted') is True and 'callers' not in json.loads(txt)['groups'][0]" "impact terse default omits callers" || fail "impact terse default"
check 22 "json.loads(txt)['groups'][0]['caller_count'] >= 1 and json.loads(txt)['risk'] == json.loads(txt)['risk']" "impact terse keeps counts+risk" || fail "impact terse counts"
# Phase B DI-aware resolution on disk: NotifierInterface has two implementors
# (EmailNotifier, SmsNotifier) so it's ambiguous to static analysis;
# config/services.yaml binds it to SmsNotifier, so SignupService::register must
# resolve to SmsNotifier::send (confidence 0.85 == di_config_binding).
check 21 "[e for e in json.loads(txt)['edges'] if e['from'] == 'Test\\\\Notify\\\\SignupService::register' and abs(e['confidence'] - 0.85) < 0.01]" "phase-b di binding on disk" || fail "phase-b di binding"

# --- Cross-package dependencies tool against a monorepo fixture ---------------
mono="$repo_root/test-project-mono/.phpcma.json"
echo "==> driving dependencies session (monorepo: $mono)"
mono_out="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"load_project\",\"arguments\":{\"project_path\":\"$mono\"}}}" \
  '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"dependencies","arguments":{"include_calls":true,"include_api_surface":true}}}' \
  '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"dependencies","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"dependencies","arguments":{"from":"beta","to":"alpha","min_call_count":1}}}' \
  '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"dependencies","arguments":{"min_call_count":99}}}' \
  '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"dependencies","arguments":{"include_api_surface":true,"to":"beta"}}}' \
  '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"impact","arguments":{"fqn":"Alpha\\Api::getData","verbose":true}}}' \
  | "$bin" mcp 2>/dev/null)"

mono_check() { # <id> <python-expr over `r`> <label>
  python3 - "$mono_out" "$1" "$2" "$3" <<'PY'
import sys, json
out, rid, expr, label = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
for line in out.splitlines():
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    if o.get("id") == rid:
        r = o.get("result", {})
        txt = r["content"][0]["text"] if r.get("content") else ""
        if not eval(expr):
            print(f"FAIL [{label}] id={rid}: {txt[:300]}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
print(f"FAIL [{label}]: no response with id={rid}", file=sys.stderr)
sys.exit(1)
PY
}

mono_fail() { echo "FAIL: $1" >&2; echo "--- mono output ---" >&2; echo "$mono_out" >&2; exit 1; }

# beta -> alpha cross-package call is detected, with the API surface attributed.
mono_check 11 "json.loads(txt)['summary']['cross_package_calls'] == 1" "dependencies cross count" || mono_fail "dependencies cross count"
mono_check 11 "json.loads(txt)['cross_package_calls'][0]['caller'] == 'Beta\\\\Consumer::run' and json.loads(txt)['cross_package_calls'][0]['callee'] == 'Alpha\\\\Api::getData'" "dependencies edge" || mono_fail "dependencies edge"
mono_check 11 "json.loads(txt)['api_surface_used'][0]['fqn'] == 'Alpha\\\\Api::getData'" "dependencies api surface" || mono_fail "dependencies api surface"
mono_check 11 "'unresolved_calls' in json.loads(txt)['caveats']" "dependencies caveats" || mono_fail "dependencies caveats"

# Default dependencies omits the heavy per-call list AND the api-surface
# inventory; the edge summary stays.
mono_check 13 "json.loads(txt).get('cross_package_calls_omitted') is True and 'cross_package_calls' not in json.loads(txt)" "dependencies omits calls by default" || mono_fail "dependencies default omit"
mono_check 13 "json.loads(txt).get('api_surface_used_omitted') is True and 'api_surface_used' not in json.loads(txt)" "dependencies omits api surface by default" || mono_fail "dependencies default omit surface"
mono_check 13 "json.loads(txt)['dependencies'][0]['to_short'] == 'alpha' and json.loads(txt)['dependencies_matched'] == 1" "dependencies edge summary" || mono_fail "dependencies edge summary"

# api_surface_used honors the `to` filter: alpha exposes the surface, so to:beta
# matches nothing.
mono_check 16 "json.loads(txt)['api_surface_used_matched'] == 0 and json.loads(txt)['api_surface_used'] == []" "dependencies api surface to-filter" || mono_fail "dependencies api surface to-filter"

# from/to filters echo back and keep the matching edge.
mono_check 14 "json.loads(txt)['filters']['from'] == 'beta' and json.loads(txt)['filters']['to'] == 'alpha' and json.loads(txt)['dependencies_matched'] == 1" "dependencies from/to filter" || mono_fail "dependencies filter"

# An unsatisfiable min_call_count filters every edge out (matched == 0).
mono_check 15 "json.loads(txt)['dependencies_matched'] == 0 and json.loads(txt)['dependencies'] == []" "dependencies min_call_count filter" || mono_fail "dependencies min_call_count"

# impact: beta consumes alpha's public API; the cross-package caller is grouped.
mono_check 12 "json.loads(txt)['symbol_project'] == 'alpha'" "impact symbol project" || mono_fail "impact symbol project"
mono_check 12 "json.loads(txt)['risk'] == 'public_api_low'" "impact risk" || mono_fail "impact risk"
mono_check 12 "json.loads(txt)['summary']['cross_package_callers'] == 1" "impact cross count" || mono_fail "impact cross count"
mono_check 12 "json.loads(txt)['groups'][0]['project'] == 'beta' and json.loads(txt)['groups'][0]['callers'][0]['caller'] == 'Beta\\\\Consumer::run'" "impact grouped caller" || mono_fail "impact grouped caller"

echo "==> all MCP smoke checks passed"
