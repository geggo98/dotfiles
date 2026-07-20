#!/usr/bin/env bash
# Integration test for the jira skill: runs the real client (jira.sh → jira.py) against a
# local stdlib mock (no real JIRA). Asserts the read/write/dangerous gating, stdout/stderr
# split, paginated user search with a 429 retry + SQLite cache, and the undo round-trip.
#
# Requires: uv, gtimeout (same as the skill). Run from anywhere.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
CLIENT="$SKILL/scripts/jira.sh"

TMP="$(mktemp -d)"
export JIRA_CACHE_DIR="$TMP/cache"     # isolate the user cache
export JIRA_STATE_DIR="$TMP/state"     # isolate the undo journal
export JIRA_OUTPUT_MAX_BYTES=1000000   # don't spill during the test
export SOPS_SECRETS_DIR="$TMP/nosops"  # ensure no real sops creds leak in
PORTFILE="$TMP/port"; REQLOG="$TMP/reqlog"; BODYLOG="$TMP/bodylog"
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

export JIRA_URL="$BASE"
export JIRA_USERNAME="test@example.com"
export JIRA_API_TOKEN="secret-token"

run(){ "$CLIENT" "$@"; }
count(){ grep -c "$1" "$REQLOG" 2>/dev/null || true; }

echo "== test 1: read commands need no flag =="
out="$(run whoami 2>/dev/null)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -q "acc-self" <<<"$out"; } && ok "whoami (read, no flag)" || no "whoami rc=$rc out=$out"
run get VUKFZIF-1 >/dev/null 2>&1 && ok "get (read)" || no "get failed"
run status VUKFZIF-1 >/dev/null 2>&1 && ok "status (read)" || no "status failed"
run transitions VUKFZIF-1 >/dev/null 2>&1 && ok "transitions (read)" || no "transitions failed"
run comments VUKFZIF-1 >/dev/null 2>&1 && ok "comments (read)" || no "comments failed"
run search 'project = VUKFZIF' >/dev/null 2>&1 && ok "search (read)" || no "search failed"

echo "== test 2: write gating (comment) =="
before="$(count 'POST /rest/api/2/issue/VUKFZIF-1/comment')"
err="$(printf 'hello' | run comment VUKFZIF-1 - 2>&1 >/dev/null)"; rc=$?
after="$(count 'POST /rest/api/2/issue/VUKFZIF-1/comment')"
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err" && [[ "$before" == "$after" ]]; } \
  && ok "comment without --write is refused (no POST)" || no "comment gating rc=$rc (before=$before after=$after)"

cid="$(printf 'hello' | run --write comment VUKFZIF-1 - 2>/dev/null)"; rc=$?
{ [[ $rc -eq 0 ]] && [[ "$cid" =~ ^[0-9]+$ ]]; } \
  && ok "comment with --write posts; stdout is only the id ($cid)" || no "comment --write rc=$rc cid='$cid'"

echo "== test 3: dangerous gating (comment-rm) =="
before="$(count 'DELETE /rest/api/2/issue/VUKFZIF-1/comment/1001')"
err="$(run --write comment-rm VUKFZIF-1 1001 2>&1)"; rc=$?
after="$(count 'DELETE /rest/api/2/issue/VUKFZIF-1/comment/1001')"
{ [[ $rc -eq 1 ]] && grep -q -- "--dangerous" <<<"$err" && [[ "$before" == "$after" ]]; } \
  && ok "comment-rm with only --write is refused (no DELETE)" || no "dangerous gating rc=$rc (before=$before after=$after)"
run --dangerous comment-rm VUKFZIF-1 1001 >/dev/null 2>&1 && ok "comment-rm with --dangerous deletes" || no "comment-rm --dangerous failed"

echo "== test 4: user search — pagination + 429 retry + cache =="
lines="$(run user someUser --format tsv 2>/dev/null | wc -l | tr -d ' ')"
n1="$(count '/rest/api/2/user/search')"
[[ "$lines" == "60" ]] && ok "user search paged through 60 users" || no "expected 60 users, got $lines"
[[ "${n1:-0}" -ge 2 ]] && ok "hit API >=2x (429 retry + pagination: $n1 requests)" || no "expected >=2 user/search requests, got $n1"
run user someUser --format tsv >/dev/null 2>&1
n2="$(count '/rest/api/2/user/search')"
[[ "$n1" == "$n2" ]] && ok "second lookup served from SQLite cache (no new API request)" || no "cache miss: $n1 -> $n2"

echo "== test 5: undo round-trip (describe) =="
# `get` intentionally omits the full description, so assert on the PUT bodies the mock
# logged: describe must overwrite with NEW, and undo must restore the ORIGINAL — which
# only works if the prior value was snapshotted before the overwrite.
run --write describe VUKFZIF-1 "NEW DESC" >/dev/null 2>&1
grep -q '"description": "NEW DESC"' "$BODYLOG" \
  && ok "describe overwrote the description (PUT NEW DESC)" || no "describe PUT missing"
run undo --list --issue VUKFZIF-1 2>/dev/null | grep -q "describe" \
  && ok "undo --list shows the describe entry (read, no flag)" || no "undo --list missing entry"
err="$(run undo --issue VUKFZIF-1 2>&1)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err"; } \
  && ok "undo apply without --write is refused" || no "undo gating rc=$rc"
run --write undo --issue VUKFZIF-1 >/dev/null 2>&1 && ok "undo apply succeeds with --write" || no "undo apply failed"
grep -q '"description": "ORIG DESC"' "$BODYLOG" \
  && ok "undo restored the original description (PUT ORIG DESC)" || no "undo did not restore the description"

echo
echo "== results: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
