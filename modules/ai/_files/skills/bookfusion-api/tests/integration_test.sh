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

echo "==================="
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
