#!/usr/bin/env bash
# Integration test for the bookfusion-api skill: runs the real Kotlin client against a local
# stdlib mock (no real BookFusion account). Asserts login+token-cache, a search with the skill
# User-Agent, DANGEROUS gating, and the cross-invocation rate limiter.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
CLIENT="$SKILL/scripts/bookfusion.sh"

TMP="$(mktemp -d)"
export XDG_STATE_HOME="$TMP/state"   # isolate token cache / device id / rate-limit stamp
PORTFILE="$TMP/port"
REQLOG="$TMP/reqlog"
: >"$REQLOG"

pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

cleanup(){ [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "== starting mock =="
python3 "$HERE/mock_server.py" "$PORTFILE" "$REQLOG" & MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORTFILE" 2>/dev/null || true)"
[[ -n "$PORT" ]] || { echo "mock failed to start"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "mock on $BASE"

export BOOKFUSION_BASE_URL="$BASE"
export BOOKFUSION_USERNAME="test@example.com"
export BOOKFUSION_PASSWORD="hunter2"

run(){ "$CLIENT" "$@"; }   # forwards to kotlin client

echo "== test 1: login caches a token =="
if run login >/dev/null 2>&1; then
  if ls "$XDG_STATE_HOME"/bookfusion-api-skill/token-*.json >/dev/null 2>&1; then ok "login + token cache"; else no "token cache file missing"; fi
else no "login exited non-zero"; fi

echo "== test 2: searchUserBooks returns canned data (TSV) + sends skill User-Agent =="
OUT="$(run searchUserBooks --data '{"query":"k"}' 2>/dev/null)"
echo "$OUT" | grep -q "Kubernetes Up & Running" && ok "search returned canned data" || no "search data missing: $OUT"
printf '%s' "$OUT" | head -1 | grep -q $'\t' && ok "list rendered as TSV (tab-separated header)" || no "output not TSV: $OUT"
printf '%s' "$OUT" | head -1 | grep -q "title" && ok "TSV header has column names" || no "TSV header missing"
grep -q "ua=bookfusion-api-skill/" "$REQLOG" && ok "skill User-Agent sent" || no "User-Agent not observed"
grep -qE "POST /api/user/books/search .*xtoken=test-token-123" "$REQLOG" && ok "cached X-Token sent on search" || no "X-Token not sent"

echo "== test 3: DANGEROUS gating =="
run deleteUserBook --id 111 >/dev/null 2>&1; code=$?
[[ $code -eq 4 ]] && ok "deleteUserBook refused without --dangerous (exit 4)" || no "expected exit 4, got $code"
run deleteUserBook --id 111 --dangerous >/dev/null 2>&1; code=$?
[[ $code -eq 0 ]] && ok "deleteUserBook allowed with --dangerous (exit 0)" || no "expected exit 0 with --dangerous, got $code"

echo "== test 4: rate limiter spaces in-process requests (login+search) by ~1/s =="
run logout >/dev/null 2>&1                       # force auto-login (2 requests in one process)
: >"$REQLOG"
run searchUserBooks --rate 1 --data '{}' >/dev/null 2>&1
# two consecutive request timestamps recorded by the mock; gap must be >= ~900ms at --rate 1
GAP="$(awk 'NR==1{a=$1} NR==2{print $1-a; exit}' "$REQLOG")"
if [[ -n "$GAP" ]] && [[ "$GAP" -ge 900 ]]; then ok "rate limiter enforced (gap ${GAP}ms >= 900ms)"; else no "rate gap too small: ${GAP}ms"; fi

echo "== test 5: EXCLUDED command is not available =="
run createReaderSubscription --data '{}' >/dev/null 2>&1; code=$?
[[ $code -eq 4 ]] && ok "excluded command blocked (exit 4)" || no "expected exit 4 for excluded, got $code"

echo "== test 6: no secret values leaked to output =="
ALL="$(run getUser 2>&1; run login 2>&1)"
echo "$ALL" | grep -q "hunter2" && no "password leaked in output!" || ok "password never printed"

echo "== test 7: token-bearing response is filed + redacted (never in context) =="
STDOUT="$(run authenticate --data '{"email":"test@example.com","password":"hunter2"}' 2>/dev/null)"
STDERR="$(run authenticate --data '{"email":"test@example.com","password":"hunter2"}' 2>&1 1>/dev/null)"
{ echo "$STDOUT"; echo "$STDERR"; } | grep -q "test-token-123" && no "token leaked to context!" || ok "token never printed to context"
echo "$STDERR" | grep -q "contains-credentials=yes" && ok "credential response flagged + filed" || no "credential response not filed"
FILE="$(printf '%s' "$STDOUT" | tail -1)"
if [[ -f "$FILE" ]] && grep -q "test-token-123" "$FILE"; then ok "full token stored in file, not context ($FILE)"; else no "token file missing/empty: $FILE"; fi

echo "== test 8: large response spills to a temp file =="
BIGOUT="$(run searchUserBooks --data '{}' --max-bytes 5 2>/dev/null)"
BIGFILE="$(printf '%s' "$BIGOUT" | tail -1)"
[[ -f "$BIGFILE" ]] && ok "large output written to temp file ($BIGFILE)" || no "expected a temp file path on stdout, got: $BIGOUT"

# ---- request validation / auto-coercion (OpenAPI-driven) ----
run login >/dev/null 2>&1   # ensure a cached token so echo tests don't add auto-login noise

echo "== test 9: --dry-run validates offline, sends nothing =="
: >"$REQLOG"
run searchUserBooks --dry-run --data '{"query":"k"}' >/dev/null 2>&1; code=$?
[[ $code -eq 0 ]] && ok "dry-run of a valid request exits 0" || no "dry-run expected exit 0, got $code"
[[ ! -s "$REQLOG" ]] && ok "dry-run made no HTTP request" || no "dry-run hit the network: $(cat "$REQLOG")"

echo "== test 10: dry-run + missing required fields -> exit 2, still no network =="
: >"$REQLOG"
ERR="$(run updateBookReadingPosition --number 1 --dry-run --data '{}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 2 ]] && ok "dry-run with missing required exits 2" || no "expected exit 2, got $code"
[[ ! -s "$REQLOG" ]] && ok "invalid dry-run made no HTTP request" || no "invalid dry-run hit the network"
echo "$ERR" | grep -q "error:.*chapter_index" && ok "missing required field reported (chapter_index)" || no "missing-required not reported: $ERR"

echo "== test 11: default mode hard-fails a malformed request before sending =="
: >"$REQLOG"
ERR="$(run addBookBookmark --number 1 --data '{}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 2 ]] && ok "missing required -> exit 2" || no "expected exit 2, got $code"
[[ ! -s "$REQLOG" ]] && ok "blocked request never reached the server" || no "malformed request was sent anyway"
echo "$ERR" | grep -q "title" && echo "$ERR" | grep -q "chapter_index" && ok "both missing fields listed" || no "fields not both listed: $ERR"

echo "== test 12: datatype coercion reaches the server as the right type =="
OUT="$(run searchHighlights --data '{"book_id":"111","page":"2"}' 2>/dev/null)"
echo "$OUT" | grep -q '"book_id":111' && ok "string->integer coercion sent as integer (book_id)" || no "book_id not coerced: $OUT"
echo "$OUT" | grep -q '"page":2' && ok "string->integer coercion sent as integer (page)" || no "page not coerced: $OUT"

echo "== test 13: scalar->array wrap + nested item coercion =="
OUT="$(run searchHighlights --data '{"category_ids":"5","tags":"kube"}' 2>/dev/null)"
echo "$OUT" | grep -q '"category_ids":\[5\]' && ok "scalar wrapped in array + int-coerced (category_ids:[5])" || no "category_ids not [5]: $OUT"
echo "$OUT" | grep -q '"tags":\["kube"\]' && ok "scalar wrapped in string array (tags:[\"kube\"])" || no "tags not [\"kube\"]: $OUT"

echo "== test 14: case-insensitive enum snapping =="
OUT="$(run searchHighlights --data '{"types":["Book"]}' 2>/dev/null)"
echo "$OUT" | grep -q '"types":\["book"\]' && ok "enum snapped Book->book on the wire" || no "enum not snapped: $OUT"

echo "== test 15: unknown field warns but still sends =="
: >"$REQLOG"
ERR="$(run searchHighlights --data '{"quary":"x"}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 0 ]] && ok "unknown field does not block (exit 0)" || no "unknown field blocked, exit $code"
grep -q "POST /api/user/highlights/search" "$REQLOG" && ok "request with unknown field was sent" || no "request not sent"
echo "$ERR" | grep -q "warn:.*unknown field.*query" && ok "unknown field warned with did-you-mean (query)" || no "no did-you-mean warning: $ERR"

echo "== test 16: --force sends despite hard errors =="
: >"$REQLOG"
ERR="$(run addBookBookmark --number 1 --force --data '{}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 0 ]] && ok "--force sends despite errors (exit 0)" || no "--force expected exit 0, got $code"
grep -q "POST /api/v2/library/books/1/bookmarks" "$REQLOG" && ok "--force request reached the server" || no "--force request not sent"
echo "$ERR" | grep -q "error:" && ok "--force still reports the errors" || no "--force suppressed errors: $ERR"

echo "== test 17: --no-validate bypasses validation =="
: >"$REQLOG"
ERR="$(run addBookBookmark --number 1 --no-validate --data '{}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 0 ]] && ok "--no-validate sends (exit 0)" || no "--no-validate expected exit 0, got $code"
{ echo "$ERR" | grep -q "error:" || echo "$ERR" | grep -q "fix:"; } && no "--no-validate emitted validation output" || ok "--no-validate produced no validation diagnostics"

echo "== test 18: uncoercible datatype hard-errors before sending =="
: >"$REQLOG"
ERR="$(run searchHighlights --data '{"page":"abc"}' 2>&1 1>/dev/null)"; code=$?
[[ $code -eq 2 ]] && ok "uncoercible value -> exit 2" || no "expected exit 2, got $code"
[[ ! -s "$REQLOG" ]] && ok "uncoercible request never sent" || no "uncoercible request was sent"
echo "$ERR" | grep -q "error:.*page" && ok "error names the offending field (page)" || no "error did not name page: $ERR"

echo "== test 19: missing spec degrades gracefully (still works) =="
OUT="$(run searchUserBooks --spec /nonexistent/openapi.yaml --data '{}' 2>/dev/null)"
ERR="$(run searchUserBooks --spec /nonexistent/openapi.yaml --data '{}' 2>&1 1>/dev/null)"
echo "$OUT" | grep -q "Kubernetes Up & Running" && ok "request works when spec is unavailable" || no "request failed without spec: $OUT"
echo "$ERR" | grep -q "spec unavailable" && ok "spec-unavailable note printed" || no "no degradation note: $ERR"

echo "==================="
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
