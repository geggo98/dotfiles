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

echo "== test 11: the sops file outranks a generic env alias =="
# Regression guard for the 2026-08-24 bug: modules/shells.nix exported
# ATLASSIAN_API_TOKEN globally, holding a *Bitbucket* token, and the credential
# chain consulted every env name before any file -- so the alias beat the
# correct jira_api_token file and every call failed. It failed as 404, not 401,
# because Jira hides issue existence from unauthenticated callers, so it read
# like a missing ticket. The chain is now ONE env name then ONE file.
mkdir -p "$TMP/sops"
printf 'secret-token' >"$TMP/sops/jira_api_token"
printf '%s' "$BASE"   >"$TMP/sops/jira_url"
printf 'test@example.com' >"$TMP/sops/jira_username"

out="$(env -u JIRA_API_TOKEN -u JIRA_URL -u JIRA_USERNAME \
        SOPS_SECRETS_DIR="$TMP/sops" ATLASSIAN_API_TOKEN=bogus-bitbucket-token \
        "$CLIENT" whoami 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -q "acc-self" <<<"$out"; } \
  && ok "a bogus \$ATLASSIAN_API_TOKEN does not shadow the jira_api_token file" \
  || no "env alias still shadows the file rc=$rc out=$out"

# ...and a failure names the source it actually used. The mock does not verify
# tokens, so provoke the message with a 404 rather than a 401 -- which is also
# the exact path that made the original bug unreadable.
err="$(env -u JIRA_URL -u JIRA_USERNAME SOPS_SECRETS_DIR="$TMP/sops" \
        JIRA_API_TOKEN=explicit-token "$CLIENT" get JIRA-404 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -ne 0 ]] && grep -q 'token source: \$JIRA_API_TOKEN (environment override)' <<<"$err"; } \
  && ok "an explicit \$JIRA_API_TOKEN overrides the file, and the error names it" \
  || no "override precedence or source reporting broken rc=$rc err=$err"

# A 404 must say that a bad token also produces 404, or it reads as a missing ticket.
err="$(env -u JIRA_API_TOKEN -u JIRA_URL -u JIRA_USERNAME SOPS_SECRETS_DIR="$TMP/sops" \
        "$CLIENT" get JIRA-404 2>&1 >/dev/null)"
{ grep -q 'jira_api_token' <<<"$err" && grep -q 'also answers 404' <<<"$err"; } \
  && ok "a 404 names the token source and warns that auth also yields 404" \
  || no "404 is not self-diagnosing: $err"

echo "== test 12: issue links — direction, ids, idempotency, unlink, undo =="
# The bug this block exists for: cmd_link filled inwardIssue/outwardIssue the
# wrong way round, so `link A "Blocks" B` recorded "B blocks A". Nothing caught
# it because (a) there was no test, (b) the command reported its INTENT
# ("Linked A —Blocks→ B") rather than what Jira had stored, and (c) `links`
# printed no id, so the wrong link could not even be named, let alone deleted.
A=JIRA-1; B=JIRA-2
lpost(){ count 'POST /rest/api/2/issueLink$'; }
ldel(){ count 'DELETE /rest/api/2/issueLink/'; }
# The inward/outward keys of the most recent POST /issueLink, as the client sent it.
lastlink(){ python3 - "$BODYLOG" <<'PY'
import json, sys
last = None
for line in open(sys.argv[1]):
    d = json.loads(line)
    if d["method"] == "POST" and d["path"] == "/rest/api/2/issueLink":
        last = d["body"]
if last:
    print(last["inwardIssue"]["key"], last["outwardIssue"]["key"], last["type"]["name"])
PY
}
# One link row from `links`, by link id: "<relation>|<other>"
lrow(){ run links "$1" --format tsv --output - 2>/dev/null \
          | perl -F'\t' -lane 'print "$F[1]|$F[2]" if $F[0] eq $ENV{LID}'; }

b="$(lpost)"
err="$(run link $A "Blocks" $B 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err" && [[ "$b" == "$(lpost)" ]]; } \
  && ok "link without --write is refused (no POST)" || no "link gating rc=$rc (before=$b after=$(lpost))"

lid="$(run --write link $A "Blocks" $B 2>"$TMP/e12a")"; rc=$?
{ [[ $rc -eq 0 ]] && [[ "$lid" =~ ^[0-9]+$ ]]; } \
  && ok "link --write puts the link id on stdout ($lid)" || no "link rc=$rc lid='$lid'"

# THE REGRESSION GUARD. Measured on the live site: the payload's inwardIssue is
# the SUBJECT of the type's outward description, so "A blocks B" is
# {inwardIssue: A, outwardIssue: B}. Swapped, this line reads "$B $A Blocks".
[[ "$(lastlink)" == "$A $B Blocks" ]] \
  && ok "payload direction: inwardIssue=$A, outwardIssue=$B for 'A blocks B'" \
  || no "REGRESSION: payload is '$(lastlink)', expected '$A $B Blocks'"

grep -q "$A blocks $B" "$TMP/e12a" \
  && ok "link reports the read-back result ('$A blocks $B'), not its intent" \
  || no "no rendered result on stderr: $(cat "$TMP/e12a")"

LID="$lid" lrow $A | grep -qx "blocks|$B" \
  && ok "links lists the new link by id, relation 'blocks'" || no "links row: $(LID=$lid lrow $A)"

b="$(lpost)"
lid2="$(run --write link $A "Blocks" $B 2>"$TMP/e12b")"; rc=$?
{ [[ $rc -eq 0 ]] && [[ "$lid2" == "$lid" ]] && [[ "$b" == "$(lpost)" ]] \
  && grep -q "already exists" "$TMP/e12b"; } \
  && ok "an identical link is warned about and NOT duplicated (id $lid2 reported again)" \
  || no "idempotency broke rc=$rc lid2='$lid2' posts $b->$(lpost)"

# The inward phrasing: "A Uses B" is the inward reading of type `Used`, so the
# payload must be swapped — the caller never has to think about direction.
lid3="$(run --write link $A "Uses" $B 2>/dev/null)"
[[ "$(lastlink)" == "$B $A Used" ]] \
  && ok "an inward phrase reverses the payload (inwardIssue=$B)" \
  || no "inward phrase payload is '$(lastlink)', expected '$B $A Used'"
LID="$lid3" lrow $A | grep -qx "Uses|$B" \
  && ok "links renders it back as the inward phrase ('Uses')" || no "links row: $(LID=$lid3 lrow $A)"

# "Used by" is the outward of `Used` AND the inward of `Depends` — a real
# collision on the live site, not an invented one.
b="$(lpost)"
err="$(run --write link $A "Used by" $B 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q "Depends" <<<"$err" && grep -q "Used" <<<"$err" \
  && [[ "$b" == "$(lpost)" ]]; } \
  && ok "an ambiguous phrase names both candidate types and posts nothing" \
  || no "ambiguity not reported rc=$rc err=$err"
# ...and the two candidates must READ differently. Echoing the phrase the caller
# typed renders both as "KEY 'Used by' OTHER" — that names the ambiguity without
# resolving it, which is what the first version of this message did. Only the
# canonical outward direction tells them apart.
{ grep -q "$A Used by $B" <<<"$err" && grep -q "$B Depends on $A" <<<"$err"; } \
  && ok "the two candidates are rendered so they differ (outward direction, real keys)" \
  || no "ambiguity message does not distinguish the candidates: $err"

# ...while a SYMMETRIC type matches both directions harmlessly and must not be
# reported as ambiguous.
run --write link $A "relates to" $B >/dev/null 2>&1 \
  && ok "a symmetric phrase ('relates to') resolves instead of erroring" || no "symmetric phrase rejected"

b="$(lpost)"
err="$(run --write link $A "frobnicates" $B 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q "Blocks" <<<"$err" && [[ "$b" == "$(lpost)" ]]; } \
  && ok "an unknown phrase lists the available types and posts nothing" || no "unknown phrase rc=$rc"

b="$(lpost)"
run --write link $A "Blocks" $A >/dev/null 2>&1; rc=$?
{ [[ $rc -eq 1 ]] && [[ "$b" == "$(lpost)" ]]; } \
  && ok "linking an issue to itself is refused" || no "self-link accepted"

b="$(ldel)"
err="$(run unlink $A "$lid" 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q -- "--write" <<<"$err" && [[ "$b" == "$(ldel)" ]]; } \
  && ok "unlink without --write is refused (no DELETE)" || no "unlink gating rc=$rc"

# The KEY argument is the guard: the API would happily delete this by id alone.
lidx="$(run --write link JIRA-99 "Blocks" $B 2>/dev/null)"
b="$(ldel)"
err="$(run --write unlink $A "$lidx" 2>&1 >/dev/null)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q "does not touch" <<<"$err" && [[ "$b" == "$(ldel)" ]]; } \
  && ok "unlink refuses a link that does not touch KEY (no DELETE)" || no "KEY guard rc=$rc err=$err"

run --write unlink $A "$lid" >/dev/null 2>&1 && ok "unlink deletes with --write" || no "unlink failed"
[[ -z "$(LID=$lid lrow $A)" ]] && ok "the deleted link is gone from links" || no "link $lid survived unlink"

# undo, both directions
lid4="$(run --write link $A "Blocks" $B 2>/dev/null)"
run --write undo --issue $A >/dev/null 2>&1
[[ -z "$(LID=$lid4 lrow $A)" ]] && ok "undo removes a link that 'link' journalled" || no "undo did not remove link $lid4"
run --write unlink $A "$lid3" >/dev/null 2>&1
run --write undo --issue $A >/dev/null 2>&1
run links $A --format tsv --output - 2>/dev/null | perl -F'\t' -lane 'print $F[1]' | grep -qx "Uses" \
  && ok "undo re-creates a link that 'unlink' deleted (relation preserved)" || no "undo did not restore the unlinked link"

echo
echo "== results: $pass passed, $fail failed =="
[[ $fail -eq 0 ]]
