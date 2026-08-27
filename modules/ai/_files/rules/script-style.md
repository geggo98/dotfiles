# Skripte: perl statt BSD/GNU-Gefrickel, zsh statt bash, ab mittlerer Größe Python

## Textverarbeitung: perl-Einzeiler bevorzugen

Statt `grep` (bei kleinen Datenmengen), `sed`, `awk`, `cut`, `tr`, und erst recht
statt der `g`-präfixierten Varianten. perl liegt im macOS-Basissystem, bringt
`-i`, `-n`, `-p` und PCRE selbst mit und verhält sich auf macOS und Linux
identisch. Damit verschwindet die BSD/GNU-Divergenz an der Wurzel, statt
umschifft zu werden. Zum GNU-Werkzeug erst greifen, wenn Datenmenge oder
Startzeit wirklich der Engpass sind.

Zwei gemessene Beispiele, warum: `date -d` ist GNU-only — `/bin/date` antwortet
`illegal option -- d`, und ein `|| echo 0` daneben macht daraus einen stillen
Totalausfall. BSD-`sed` liest `-i'' -e` als „Backup-Endung `-e`" und legt
wortlos eine Datei `foo-e` neben das Original.

| statt | schreiben |
|---|---|
| `grep -o` / `sed -n 's/…/\1/p'` | `perl -ne 'print $+{x} if /(?<x>…)/'` |
| `sed -i'' -e 's/a/b/'` | `perl -i -pe 's/a/b/'` |
| `awk -F'\t' '{print $4}'` | `perl -F'\t' -lane 'print $F[3]'` |
| `grep -c` | `perl -ne '$n++ if /…/; END { print $n // 0 }'` |
| `date -d "$ts" +%s` | `perl -MTime::Local=timegm_modern -e '…'` (rein UTC, keine Sommerzeitfälle) |

Regex dabei: benannte Gruppen (`(?<name>…)` mit `$+{name}`), komplexe Muster
mehrzeilig mit `/x` kommentiert, und immer ein konkretes Beispiel der erwarteten
Eingabe als Kommentar darüber.

```perl
# matches:     url = "github:owner/repo/6.0.17";   ->  $+{tag} eq "6.0.17"
m{^ \s* url \s* = \s* "github:owner/repo/(?<tag>[^"]+)"; \s* $}x
```

## Kurze Skripte: `#!/bin/zsh`, nicht bash

macOS' `/bin/bash` steht bei 3.2 von 2007: keine assoziativen Arrays, kein
`${var@Q}`, kein `readarray`, kein `wait -n`. zsh ist die Standard-Login-Shell
und eine aktuelle Version.

Beim Umschreiben von bash die eine echte Falle beachten: **zsh trennt unquotierte
Parameter nicht in Wörter.** Wo Code darauf gebaut hat, `${=VAR}` verwenden —
sonst wird aus einer Liste stillschweigend ein einziges Argument.

## Ab mittlerer Komplexität: `python3` mit PEP-723-uv-Header

Sobald Argument-Parsing, JSON oder mehr als ein paar Verzweigungen dazukommen,
ist die Shell-Fassung weder lesbar noch testbar. Dann:
`#!/usr/bin/env -S uv --quiet run --frozen --script`, die per `uv lock --script`
erzeugte `script.py.lock` danebenlegen und mitcommitten, und im Header eine
Alterssperre setzen (`exclude-newer` bzw. `min-release-age`), damit kein frisch
veröffentlichtes Paket ungeprüft hereinkommt. Stdlib bevorzugen. `--frozen` ist
nicht optional, sobald das Skript aus einem schreibgeschützten Pfad läuft.

## Ausnahme: `pkgs.writeShellApplication` in Nix ist bash-only

Dort bleibt es bei bash — dafür laufen shellcheck und `set -euo pipefail` mit,
und jedes Werkzeug aus `runtimeInputs` zeigt auf einen gepinnten Store-Pfad.
