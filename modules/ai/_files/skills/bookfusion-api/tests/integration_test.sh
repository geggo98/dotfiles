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
BODYLOG="$TMP/reqlog.body"   # mock logs one JSON object per request here (outgoing body/headers/parts)
: >"$REQLOG"; : >"$BODYLOG"

pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

cleanup(){ [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "== starting mock =="
python3 "$HERE/mock_server.py" "$PORTFILE" "$REQLOG" "$BODYLOG" & MOCK_PID=$!
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

# ---- fixes B1/B2/B5/B6, features U2/U6/batch, and exit-code / wire-behavior gaps ----
run login >/dev/null 2>&1   # ensure a cached token for the endpoint tests below

echo "== test 20: multipart binary part is named 'binary' for createHighlight, 'file' otherwise (B1) =="
# REAL BEHAVIOR: createHighlight expects the image part named 'binary'; updateUserBook expects 'file'.
head -c 16 /dev/urandom >"$TMP/q.png"
: >"$BODYLOG"; run createHighlight --no-validate --data '{"book_id":111,"quote_text":"x"}' --file "$TMP/q.png" >/dev/null 2>&1
grep -q '"binary"' "$BODYLOG" && ok "createHighlight sent binary part named 'binary'" || no "createHighlight part name wrong: $(cat "$BODYLOG")"
: >"$BODYLOG"; run updateUserBook --id 111 --dangerous --no-validate --data '{"title":"T"}' --file "$TMP/q.png" >/dev/null 2>&1
grep -q '"file"' "$BODYLOG" && ok "updateUserBook sent binary part named 'file'" || no "updateUserBook part name wrong: $(cat "$BODYLOG")"

echo "== test 21: getTtsCredentials — token/preview_token never in context; file is 0600 (B2) =="
STDOUT="$(run getTtsCredentials 2>/dev/null)"
STDERR="$(run getTtsCredentials 2>&1 1>/dev/null)"
{ echo "$STDOUT"; echo "$STDERR"; } | grep -q "tts-token-xyz" && no "tts token leaked to context!" || ok "tts token never in context"
{ echo "$STDOUT"; echo "$STDERR"; } | grep -q "tts-preview-abc" && no "tts preview_token leaked to context!" || ok "preview_token never in context (endsWith _token)"
echo "$STDERR" | grep -q "contains-credentials=yes" && ok "tts response flagged + filed" || no "tts response not filed"
FILE="$(printf '%s' "$STDOUT" | tail -1)"
if [[ -f "$FILE" ]]; then
  PERM="$(stat -f '%Lp' "$FILE" 2>/dev/null || stat -c '%a' "$FILE" 2>/dev/null)"
  [[ "$PERM" == "600" ]] && ok "credential file is 0600" || no "expected 0600, got $PERM"
else no "credential file missing: $FILE"; fi

echo "== test 22: a mid-path '~' in --data-file is not mangled (B5) =="
mkdir -p "$TMP/te~st"; printf '{"query":"k"}' >"$TMP/te~st/b.json"
OUT="$(run searchUserBooks --data-file "$TMP/te~st/b.json" 2>/dev/null)"; code=$?
{ [[ $code -eq 0 ]] && echo "$OUT" | grep -q "Kubernetes"; } && ok "mid-path ~ preserved in --data-file" || no "mid-path ~ mangled: code=$code out=$OUT"

echo "== test 23: a future rate-limit timestamp does not stall the next call (B6) =="
STATE="$XDG_STATE_HOME/bookfusion-api-skill"; mkdir -p "$STATE"
printf '%s' "$(( $(python3 -c 'import time;print(int(time.time()*1000))') + 3600000 ))" >"$STATE/last-request"
START="$(date +%s)"; run getUser --rate 1 >/dev/null 2>&1; END="$(date +%s)"
[[ $((END-START)) -lt 5 ]] && ok "future timestamp clamped (call took $((END-START))s)" || no "call stalled $((END-START))s on a future timestamp"

echo "== test 24: --quiet suppresses the 2xx body for non-SAFE commands (U2) =="
OUT="$(run addBookBookmark --number 1 --quiet --data '{"title":"t","chapter_index":0}' 2>/dev/null)"
[[ -z "$OUT" ]] && ok "--quiet produced no stdout body" || no "--quiet still printed: $OUT"
ERR="$(run addBookBookmark --number 1 --quiet --data '{"title":"t","chapter_index":0}' 2>&1 1>/dev/null)"
echo "$ERR" | grep -qi "^ok:" && ok "--quiet prints an 'ok:' line on stderr" || no "no ok: line: $ERR"

echo "== test 25: an unparseable numeric flag value fails fast (U6) =="
for pair in "--rate abc" "--max-bytes foo" "--preview-lines x"; do
  # shellcheck disable=SC2086
  run getUser $pair >/dev/null 2>&1; code=$?
  [[ $code -eq 2 ]] && ok "$pair -> exit 2" || no "$pair expected exit 2, got $code"
done

echo "== test 26: batch runs many ops with ONE login, JSONL results, continue-on-error (batch) =="
run logout >/dev/null 2>&1; : >"$REQLOG"
OUT="$(printf '%s\n' \
  '{"command":"searchUserBooks","data":{"query":"k"}}' \
  '{"command":"getUser"}' \
  '{"command":"bogusCommand"}' | run batch 2>/dev/null)"; code=$?
[[ $(printf '%s\n' "$OUT" | grep -c '"line":') -eq 3 ]] && ok "batch emitted 3 result lines" || no "batch line count wrong: $OUT"
printf '%s\n' "$OUT" | grep -q '"line":1.*"status":"ok"' && ok "batch op 1 ok" || no "batch op1 not ok: $OUT"
printf '%s\n' "$OUT" | grep -q '"line":3.*"status":"error"' && ok "batch op 3 (unknown command) errored" || no "batch op3 not error: $OUT"
[[ $code -ne 0 ]] && ok "batch exits non-zero when an op fails" || no "batch exit should be non-zero, got $code"
[[ "$(grep -c 'POST /api/v3/auth.json' "$REQLOG")" -eq 1 ]] && ok "batch logged in exactly once" || no "batch login count = $(grep -c 'POST /api/v3/auth.json' "$REQLOG")"
: >"$REQLOG"
OUT="$(printf '%s\n' '{"command":"deleteUserBook","id":111}' | run batch 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q '"status":"error"' && ok "batch delete without --dangerous is refused per-line" || no "batch delete not refused: $OUT"
grep -q "DELETE /api/user/books/111" "$REQLOG" && no "batch sent a DELETE despite no --dangerous!" || ok "batch made no DELETE without --dangerous"

echo "== test 27: auth failures exit 3 (EX_AUTH) =="
( unset BOOKFUSION_USERNAME BOOKFUSION_PASSWORD; run logout >/dev/null 2>&1; run getUser >/dev/null 2>&1; [[ $? -eq 3 ]] ) && ok "missing credentials -> exit 3" || no "missing creds not exit 3"
( export BOOKFUSION_PASSWORD="wrongpass"; run logout >/dev/null 2>&1; run login >/dev/null 2>&1; [[ $? -eq 3 ]] ) && ok "bad credentials -> exit 3" || no "bad creds not exit 3"
run login >/dev/null 2>&1   # restore a cached token for the remaining tests

echo "== test 28: an HTTP error exits 5 (EX_HTTP) =="
run getBookReadingPosition --number 999 >/dev/null 2>&1; code=$?
[[ $code -eq 5 ]] && ok "404 -> exit 5" || no "expected exit 5, got $code"

echo "== test 29: a network failure exits 6 (EX_IO) =="
BOOKFUSION_BASE_URL="http://127.0.0.1:1" run getUser >/dev/null 2>&1; code=$?
[[ $code -eq 6 ]] && ok "connection refused -> exit 6" || no "expected exit 6, got $code"

echo "== test 30: a secret in the request body is SENT but never printed to context =="
: >"$BODYLOG"
STDOUT="$(run authenticate --data '{"email":"test@example.com","password":"s3cr3t-outgoing"}' 2>/dev/null)"
STDERR="$(run authenticate --data '{"email":"test@example.com","password":"s3cr3t-outgoing"}' 2>&1 1>/dev/null)"
grep -q "s3cr3t-outgoing" "$BODYLOG" && ok "secret body reached the server (proves it was sent)" || no "secret not in outgoing body: $(cat "$BODYLOG")"
{ echo "$STDOUT"; echo "$STDERR"; } | grep -q "s3cr3t-outgoing" && no "outgoing secret leaked to context!" || ok "outgoing secret never printed to context"

echo "== test 31: --no-validate sends raw; --force still coerces the coercible fields =="
OUT="$(run searchHighlights --no-validate --data '{"page":"2"}' 2>/dev/null)"
echo "$OUT" | grep -q '"page":"2"' && ok "--no-validate sent page as a raw string" || no "--no-validate altered the body: $OUT"
OUT="$(run addBookBookmark --number 1 --force --data '{"chapter_index":"3"}' 2>/dev/null)"
echo "$OUT" | grep -q '"chapter_index":3' && ok "--force still coerced chapter_index to int on the wire" || no "--force did not coerce: $OUT"

echo "== test 32: DANGEROUS gate precedes dry-run; --dangerous --dry-run sends nothing =="
: >"$REQLOG"
run deleteUserBook --id 1 --dry-run >/dev/null 2>&1; code=$?
[[ $code -eq 4 ]] && ok "dry-run of a DANGEROUS command without --dangerous still exits 4" || no "expected exit 4, got $code"
run deleteUserBook --id 1 --dangerous --dry-run >/dev/null 2>&1; code=$?
{ [[ $code -eq 0 ]] && [[ ! -s "$REQLOG" ]]; } && ok "--dangerous --dry-run validates offline, sends nothing" || no "dangerous dry-run: code=$code reqlog=$(cat "$REQLOG")"

echo "== test 34: a stale cached token triggers one clear + re-auth, then succeeds (B4) =="
run login >/dev/null 2>&1
for f in "$XDG_STATE_HOME"/bookfusion-api-skill/token-*.json; do
  python3 -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['token']='stale-bad';json.dump(d,open(p,'w'))" "$f"
done
: >"$REQLOG"
run getUser >/dev/null 2>&1; code=$?
[[ $code -eq 0 ]] && ok "stale token recovered via one re-auth (exit 0)" || no "stale-token recovery failed, exit $code"
grep -q "POST /api/v3/auth.json" "$REQLOG" && ok "re-authenticated after the 401" || no "no re-auth observed: $(cat "$REQLOG")"

echo "== test 33: exportHighlights binary response is written byte-exact (B3) =="
OUT="$(run exportHighlights --no-validate --data '{}' 2>/dev/null)"
BINFILE="$(printf '%s' "$OUT" | tail -1)"
if [[ -f "$BINFILE" ]]; then
  SIZE="$(wc -c <"$BINFILE" | tr -d ' ')"
  [[ "$SIZE" == "17" ]] && ok "binary export written byte-exact (17 bytes)" || no "binary size wrong: $SIZE (UTF-8 round-trip would inflate it)"
else no "no binary file path on stdout: $OUT"; fi

echo "==================="
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
