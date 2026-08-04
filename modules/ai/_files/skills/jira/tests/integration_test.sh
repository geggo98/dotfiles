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
run get JIRA-1 >/dev/null 2>&1 && ok "get (read)" || no "get failed"
run status JIRA-1 >/dev/null 2>&1 && ok "status (read)" || no "status failed"
run transitions JIRA-1 >/dev/null 2>&1 && ok "transitions (read)" || no "transitions failed"
run comments JIRA-1 >/dev/null 2>&1 && ok "comments (read)" || no "comments failed"
run search 'project = VUKFZIF' >/dev/null 2>&1 && ok "search (read)" || no "search failed"

echo "== test 2: write gating (comment) =="
before="$(count 'POST /rest/api/2/issue/JIRA-1/comment')"
err="$(printf 'hello' | run comment JIRA-1 - 2>&1 >/dev/null)"; rc=$?
after="$(count 'POST /rest/api/2/issue/JIRA-1/comment')"
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err" && [[ "$before" == "$after" ]]; } \
  && ok "comment without --write is refused (no POST)" || no "comment gating rc=$rc (before=$before after=$after)"

cid="$(printf 'hello' | run --write comment JIRA-1 - 2>/dev/null)"; rc=$?
{ [[ $rc -eq 0 ]] && [[ "$cid" =~ ^[0-9]+$ ]]; } \
  && ok "comment with --write posts; stdout is only the id ($cid)" || no "comment --write rc=$rc cid='$cid'"

echo "== test 3: dangerous gating (comment-rm) =="
before="$(count 'DELETE /rest/api/2/issue/JIRA-1/comment/1001')"
err="$(run --write comment-rm JIRA-1 1001 2>&1)"; rc=$?
after="$(count 'DELETE /rest/api/2/issue/JIRA-1/comment/1001')"
{ [[ $rc -eq 1 ]] && grep -q -- "--dangerous" <<<"$err" && [[ "$before" == "$after" ]]; } \
  && ok "comment-rm with only --write is refused (no DELETE)" || no "dangerous gating rc=$rc (before=$before after=$after)"
run --dangerous comment-rm JIRA-1 1001 >/dev/null 2>&1 && ok "comment-rm with --dangerous deletes" || no "comment-rm --dangerous failed"

echo "== test 4: user search — pagination + 429 retry + cache =="
lines="$(run user someUser --format tsv 2>/dev/null | wc -l | tr -d ' ')"
n1="$(count '/rest/api/2/user/search')"
[[ "$lines" == "60" ]] && ok "user search paged through 60 users" || no "expected 60 users, got $lines"
[[ "${n1:-0}" -ge 2 ]] && ok "hit API >=2x (429 retry + pagination: $n1 requests)" || no "expected >=2 user/search requests, got $n1"
run user someUser --format tsv >/dev/null 2>&1
n2="$(count '/rest/api/2/user/search')"
[[ "$n1" == "$n2" ]] && ok "second lookup served from SQLite cache (no new API request)" || no "cache miss: $n1 -> $n2"

echo "== test 5: undo round-trip (describe) =="
# `get` reports only description_chars, so assert on the PUT bodies the mock logged:
# describe must overwrite with NEW, and undo must restore the ORIGINAL — which only works
# if the prior value was snapshotted before the overwrite.
run --write describe JIRA-1 "NEW DESC" >/dev/null 2>&1
grep -q '"description": "NEW DESC"' "$BODYLOG" \
  && ok "describe overwrote the description (PUT NEW DESC)" || no "describe PUT missing"
run undo --list --issue JIRA-1 2>/dev/null | grep -q "describe" \
  && ok "undo --list shows the describe entry (read, no flag)" || no "undo --list missing entry"
err="$(run undo --issue JIRA-1 2>&1)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err"; } \
  && ok "undo apply without --write is refused" || no "undo gating rc=$rc"
run --write undo --issue JIRA-1 >/dev/null 2>&1 && ok "undo apply succeeds with --write" || no "undo apply failed"
grep -q '"description": "ORIG DESC"' "$BODYLOG" \
  && ok "undo restored the original description (PUT ORIG DESC)" || no "undo did not restore the description"

echo "== test 6: create — where the description comes from =="
c_before="$(count 'POST /rest/api/2/issue$')"

# THE REGRESSION: '--description -' used to store the literal string "-" and drop stdin.
k="$(printf 'BODY-FROM-STDIN' | run --write create --summary S1 --description - 2>"$TMP/e6a")"
[[ "$k" =~ ^[A-Z]+-[0-9]+$ ]] && ok "create --description - returns a key ($k)" || no "create key='$k'"
d="$(run description "$k" 2>/dev/null)"
[[ "$d" == "BODY-FROM-STDIN" ]] && ok "--description - read stdin" || no "expected stdin body, got '$d'"
[[ "$d" != "-" ]] && ok "description is not the literal '-'" || no "REGRESSION: literal '-' stored"
grep -q -- "--description-file -" "$TMP/e6a" \
  && ok "--description - points at the canonical spelling on stderr" || no "no canonical-form hint"
grep -q "description: 15 chars" "$TMP/e6a" \
  && ok "create reports the description size it sent" || no "no size in the success line"

# canonical spelling: same result, and no hint
k="$(printf 'BODY-VIA-FILE-DASH' | run --write create --summary S2 --description-file - 2>"$TMP/e6b")"
[[ "$(run description "$k" 2>/dev/null)" == "BODY-VIA-FILE-DASH" ]] \
  && ok "--description-file - reads stdin" || no "--description-file - broke"
grep -q -- "--description-file -" "$TMP/e6b" \
  && no "canonical form should not warn" || ok "canonical form warns about nothing"

# bare '-' (the form SKILL.md documents) still works
k="$(printf 'BODY-BARE-DASH' | run --write create --summary S3 - 2>/dev/null)"
[[ "$(run description "$k" 2>/dev/null)" == "BODY-BARE-DASH" ]] && ok "bare - still reads stdin" || no "bare - broke"

k="$(run --write create --summary S4 --description 'inline text' 2>/dev/null)"
[[ "$(run description "$k" 2>/dev/null)" == "inline text" ]] && ok "--description TEXT" || no "inline desc broke"

printf 'FROM-FILE' >"$TMP/desc.wiki"
k="$(run --write create --summary S5 --description-file "$TMP/desc.wiki" 2>/dev/null)"
[[ "$(run description "$k" 2>/dev/null)" == "FROM-FILE" ]] && ok "--description-file PATH" || no "desc-file broke"

run --write create --summary S6 >/dev/null 2>&1 && ok "create without a description" || no "description became mandatory"

# stdin is a pipe but no '-' was asked for -> it must be ignored, never read
k="$(printf 'MUST-NOT-APPEAR' | run --write create --summary S7 2>/dev/null)"
[[ -z "$(run description "$k" 2>/dev/null)" ]] && ok "create ignores an unrequested pipe" || no "create read stdin unasked"

echo "== test 7: conflicting / malformed create arguments =="
b="$(count 'POST /rest/api/2/issue$')"
err="$(printf 'x' | run --write create --summary S8 --description X - 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q -- '--description' <<<"$err" && [[ "$b" == "$(count 'POST /rest/api/2/issue$')" ]]; } \
  && ok "--description X + - is an error, nothing POSTed" || no "conflict not rejected (rc=$rc)"
err="$(run --write create --summary S9 --description X --description-file "$TMP/desc.wiki" 2>&1 >/dev/null)"; rc=$?
[[ $rc -eq 1 ]] && ok "--description + --description-file is an error" || no "file/inline conflict not rejected"
b="$(count 'POST /rest/api/2/issue$')"
run --write create --summary --type >/dev/null 2>&1; rc=$?
{ [[ $rc -eq 1 ]] && [[ "$b" == "$(count 'POST /rest/api/2/issue$')" ]]; } \
  && ok "--summary --type is an error, no ticket titled '--type'" || no "created a ticket titled '--type'"
run --write create --summary A --summary B >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "a repeated --summary is an error" || no "duplicate --summary silently took the last"
run --write create --summary '--frozen fails on uv 0.9' >/dev/null 2>&1 \
  && ok "a legitimate dash-leading summary is accepted" || no "dash-leading summary rejected"

echo "== test 8: '-' as a filename, and --output =="
printf 'VIA-FILE-DASH' | run --write describe JIRA-1 --file - >/dev/null 2>&1
grep -q '"description": "VIA-FILE-DASH"' "$BODYLOG" && ok "describe --file - reads stdin" || no "describe --file - broke"
cid="$(printf 'COMMENT-VIA-FILE-DASH' | run --write comment JIRA-1 --file - 2>/dev/null)"
[[ "$(run comment-get JIRA-1 "$cid" 2>/dev/null)" == "COMMENT-VIA-FILE-DASH" ]] \
  && ok "comment --file - reads stdin; comment-get reads it back" || no "comment --file - / comment-get broke"

run description JIRA-1 --output "$TMP/out.txt" >"$TMP/out.stdout" 2>/dev/null
{ [[ "$(cat "$TMP/out.txt")" == "VIA-FILE-DASH" ]] && grep -q "$TMP/out.txt" "$TMP/out.stdout"; } \
  && ok "--output PATH writes the payload, stdout gets only the path" || no "--output PATH broke"
[[ "$(wc -c <"$TMP/out.stdout")" -lt 100 ]] && ok "--output PATH keeps stdout tiny" || no "--output PATH flooded stdout"

JIRA_OUTPUT_MAX_BYTES=10 run description JIRA-1 --output - 2>/dev/null | grep -q '^VIA-FILE-DASH$' \
  && ok "--output - bypasses the spill guard (pipe-safe)" || no "--output - was truncated"
JIRA_OUTPUT_MAX_BYTES=10 run description JIRA-1 2>/dev/null | grep -q 'truncated' \
  && ok "without --output the spill guard still protects context" || no "spill guard stopped working"

# the round-trip the whole --output/'-' contract exists for
run description JIRA-1 --output - 2>/dev/null | sed 's/VIA-FILE-DASH/ROUNDTRIPPED/' \
  | run --write describe JIRA-1 --file - >/dev/null 2>&1
[[ "$(run description JIRA-1 2>/dev/null)" == "ROUNDTRIPPED" ]] \
  && ok "read -> sed -> write round-trip" || no "round-trip broke"

echo "== test 9: get is verifiable and stays machine-readable =="
run get JIRA-1 --format json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "get --format json is valid JSON" || no "get json unparseable"
n="$(run get JIRA-1 --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["description_chars"])' 2>/dev/null)"
[[ "$n" == "12" ]] && ok "get reports description_chars=12 (ROUNDTRIPPED)" || no "description_chars=$n, expected 12"
run get JIRA-99 --format json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "get json stays parseable on a 60KB description" || no "get json spilled and broke jq/json"
JIRA_OUTPUT_MAX_BYTES=10000 run description JIRA-99 2>/dev/null | grep -q 'truncated' \
  && ok "description spills a 60KB body instead of flooding context" || no "description did not spill"

echo "== test 10: input that used to be dropped silently =="
run --write describe JIRA-1 "part one" "part two" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "describe rejects a second inline text" || no "describe silently dropped 'part one'"
run --write comment JIRA-1 "a" "b" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "comment rejects a second inline text" || no "comment silently dropped 'a'"
run get JIRA-1 JIRA-99 >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "get rejects a second issue key" || no "get silently read the wrong issue"
run --write comment JIRA-1 --file "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "an empty --file path is an error" || no "empty --file silently ignored"
b="$(count 'PUT /rest/api/2/issue/JIRA-1$')"
run --write label JIRA-1 --add --remove >/dev/null 2>&1; rc=$?
{ [[ $rc -eq 1 ]] && [[ "$b" == "$(count 'PUT /rest/api/2/issue/JIRA-1$')" ]]; } \
  && ok "label --add --remove is an error, no label named '--remove'" || no "added a label called '--remove'"
run --write comment JIRA-1 --file a --file b >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "a repeated --file is an error" || no "duplicate --file silently took the last"

echo
echo "== results: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
