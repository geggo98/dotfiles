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
| `sed -i'' -e 's/a/b/'` | `+perl-i -pe 's/a/b/' -- datei` |
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

### Unicode: `-CSDA -Mutf8`, sonst zählt perl Bytes

Perl unterscheidet ohne `use utf8` beziehungsweise `-C` nicht zwischen Bytes und
Zeichen. Kann Unicode im Spiel sein — bei deutschem Text, Dateinamen, JSON also
praktisch immer —, den Einzeiler als `perl -CSDA -Mutf8 …` aufrufen.

- `-CS`: STDIN, STDOUT und STDERR als UTF-8. `-CD`: Standard-Layer für `open`
  (und damit für `-i`). `-CA`: `@ARGV` dekodieren.
- `-Mutf8` (= `use utf8`): Literale **im Code** sind Zeichen. `-CSD` allein
  reicht nicht, wenn das Muster selbst Umlaute enthält.

Gemessen am 01.10.2026 mit perl 5.34.1 an der Eingabe `Größe`. Keiner der Fälle
bricht ab, alle liefern plausibel aussehende falsche Werte:

| Aufruf | ohne | mit |
|---|---|---|
| `length` | **7** | 5 (`-CSD`) |
| `uc` | **GRößE** | GRÖSSE (`-CSD`) |
| Anzahl `\w` | **3** | 5 (`-CSD`) |
| `/ö/` im Code | **miss** | hit (`-CSD -Mutf8`; `-CSD` allein: miss) |
| `length $ARGV[0]` | **7** | 5 (`-CSDA`; `-CSD` allein: 7) |

In einer Skriptdatei gehört `-C` nicht in die Shebang-Zeile: `perl script.pl`
bricht dann mit `Too late for "-CSD" option` ab (exit 255). Dort stattdessen
`use utf8;` und `use open qw(:std :encoding(UTF-8));`.

### In-place-Edits: immer mit Backup

In-place-Edits mit perl laufen über den Wrapper `+perl-i`. Den Wrapper liefert dieses
Repository (`modules/perl-i.nix`, Quelle `modules/_files/perl-i/perl-i.py`). Er sichert jede Datei,
bevor perl sie anfasst:

```zsh
+perl-i -pe 's/a/b/' -- datei1 datei2
```

- **Das `--` ist Pflicht:** links davon stehen die perl-Schalter, rechts davon die
  Dateien. Fehlt es, endet `+perl-i` mit exit 2 und fasst nichts an. `-i` nicht
  selbst übergeben, das lehnt der Wrapper ebenfalls mit exit 2 ab.
- **Ein neues Backup-Verzeichnis je Lauf:**
  `$TMPDIR/perl-i/<YYYYmmddTHHMMSS>-<zufall>/<absoluter Pfad der Datei>`, dazu
  `manifest.tsv` mit sha256, Größe und Pfad jeder Kopie. Zwei Läufe auf dieselbe
  Datei ergeben also zwei getrennte Backups. Backup-Pfad und Restore-Kommando
  stehen auf stderr.
- **Leer gewordene Dateien sind ein Fehler:** schrumpft eine Datei von mehr als
  0 Byte auf 0 Byte, warnt der Wrapper und endet mit exit 1. `--allow-empty`
  schaltet das ab.
- **Symlinks lehnt er ab.** `perl -i` ersetzt einen Symlink durch eine reguläre
  Datei und lässt das Ziel unverändert (gemessen am 15.11.2026, perl 5.34.1).
- `--backup-root DIR` legt die Backups woanders ab. `+perl-i --list` zeigt die
  Backup-Läufe, den neuesten zuerst. `+perl-i --restore <backup-verzeichnis>`
  prüft zuerst die sha256 jeder Kopie und stellt dann atomar wieder her.
- **Exit-Codes:** der von perl; 1 = eine Datei wurde leer oder der Restore
  scheiterte; 2 = falscher Aufruf; 125 = das Backup scheiterte, perl lief nicht.

Wo `+perl-i` nicht installiert ist, für **eine** Datei von Hand sichern:

```zsh
bak=$(mktemp -d "${TMPDIR:-/tmp}/perl-i.XXXXXX") && cp -p -- datei "$bak/" && echo "backup: $bak" >&2 && perl -i -pe 's/a/b/' -- datei
```

Für mehrere Dateien mit gleichem Basisnamen reicht das nicht, dort den Wrapper
nehmen. perls eigenes `-i"$bak/*"` ist kein Ersatz. Gemessen am 15.11.2026 mit
perl 5.34.1 scheitert es an Dateien in Unterverzeichnissen (`Can't rename sub/f to
…/sub/f: No such file or directory, skipping file`, exit 2; die Datei wird
übersprungen, nicht zerstört), und gleiche Basisnamen überschreiben sich im
Backup-Verzeichnis gegenseitig.

**Herkunft:** Am 15.11.2026 kürzte ein zsh-Helfer mit verschachteltem perl-Quoting
12 Skill-Markdown-Dateien auf 0 Byte. Ein anschließendes `perl -i`
„ersetzte" in der leeren Datei und meldete 1 Treffer. Die Trefferzahl bewies also
nichts. Die Dateien hatten nicht committete Änderungen und kein Backup; sie ließen
sich nur aus den Transkripten der Agenten wiederherstellen.

**Begründung:** `-i` ohne Endung überschreibt die Datei ohne Weg zurück, und ein
Fehler im Ausdruck zeigt sich erst nach dem Schreiben. Ein Backup unter `$TMPDIR`
kostet im Arbeitsbaum nichts. Ein eigenes Verzeichnis je Lauf verhindert, dass der
zweite Lauf die einzige gute Kopie überschreibt.

**Grenzen:** Die Regel gilt nicht, wenn der Edit nur Dateien berührt, die in git
committet und seitdem unverändert sind; dann ist git das Backup. Sie gilt auch
nicht für Wegwerfdateien im Scratchpad (dem sitzungseigenen Temp-Verzeichnis des Agenten). Im Zweifel das Backup anlegen.

Ein Backup ersetzt nicht die Prüfung des Ergebnisses: Steht der neue Text in der
Datei, ist die Größe plausibel? Siehe die Regel `filter-validation.md` (im selben Verzeichnis, `modules/ai/_files/rules/`).

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
