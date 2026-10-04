#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Offline test: a fake fetch-ebook-metadata on PATH, no network, no calibre needed.
set -uo pipefail
SKILL="${0:A:h:h}"; BM="$SKILL/scripts/book_metadata.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
pass=0; fail=0
ok() { print "ok   $1"; pass=$((pass+1)); }
no() { print "FAIL $1"; fail=$((fail+1)); }

cat > "$T/bin/fetch-ebook-metadata" <<'FAKE'
#!/bin/zsh
case "$FAKE_MODE" in
  ok)   cat "$FAKE_OPF"; exit 0 ;;
  none) print -u2 "No results found"; exit 1 ;;
  flaky) n=$(cat "$FAKE_COUNT" 2>/dev/null || print 0); print $((n+1)) > "$FAKE_COUNT"
         if (( n < 1 )); then print -u2 "HTTP Error 500: Internal Server Error"; exit 1; fi
         cat "$FAKE_OPF"; exit 0 ;;
esac
FAKE
chmod +x "$T/bin/fetch-ebook-metadata"
cat > "$T/book.opf" <<'OPF'
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
<dc:identifier opf:scheme="uuid">x</dc:identifier><dc:title>Example Book</dc:title>
<dc:creator opf:role="aut">Ann Author</dc:creator><dc:date>2004-10-25T13:13:19+00:00</dc:date>
<dc:description>&lt;p&gt;One.&lt;/p&gt;&lt;p&gt;Two &amp;amp; three.&lt;/p&gt;</dc:description>
<dc:publisher>"Pub, Inc."</dc:publisher><dc:identifier opf:scheme="ISBN">9780000000002</dc:identifier>
<dc:language>deu</dc:language><dc:subject>A</dc:subject><dc:subject>A</dc:subject><dc:subject>B</dc:subject>
</metadata></package>
OPF
export PATH="$T/bin:$PATH" FAKE_OPF="$T/book.opf" FAKE_COUNT="$T/count" BM_NO_SLEEP=1

FAKE_MODE=ok "$BM" fetch --isbn 9780000000002 --format bookfusion > "$T/bf.json" 2>/dev/null
rc=$?; (( rc == 0 )) && ok "fetch exit 0" || no "fetch exit $rc"
python3 - "$T/bf.json" <<'PY' && ok "bookfusion mapping" || no "bookfusion mapping"
import json,sys
d=json.load(open(sys.argv[1]))
assert d=={"title":"Example Book","authors":["Ann Author"],"summary":"One.\n\nTwo & three.",
  "publisher_name":"Pub, Inc.","published_at":"2004-10-25","language":"de","tags":["A","B"]},d
PY
FAKE_MODE=none "$BM" fetch --isbn 1 >/dev/null 2>&1; rc=$?
(( rc == 1 )) && ok "no result -> exit 1" || no "no result -> exit $rc"
rm -f "$T/count"; FAKE_MODE=flaky "$BM" fetch --isbn 1 --retries 2 >/dev/null 2>&1; rc=$?
(( rc == 0 )) && ok "retry after HTTP 500" || no "retry after 500 -> exit $rc"
"$BM" fetch >/dev/null 2>&1; rc=$?
(( rc == 2 )) && ok "no query -> exit 2" || no "no query -> exit $rc"
PATH="/usr/bin:/bin:$(dirname $(command -v uv))" HOME="$T" "$BM" fetch --isbn 1 >/dev/null 2>&1; rc=$?
(( rc == 127 )) && ok "no calibre -> exit 127" || no "no calibre -> exit $rc"
"$BM" plugins remove Whatever >/dev/null 2>&1; rc=$?
(( rc == 4 )) && ok "remove without --yes -> exit 4" || no "remove without --yes -> exit $rc"

print "$pass passed, $fail failed"; (( fail == 0 ))
