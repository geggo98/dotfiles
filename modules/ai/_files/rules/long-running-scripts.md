# Lang laufende Skripte: wiederaufsetzbar, abbrechbar, beobachtbar

Jedes Skript, das länger als etwa eine Minute laufen kann — Batch über eine Liste,
Download, Migration, Konvertierung —, erfüllt **immer** diese fünf Punkte. Nicht
erst, wenn es das erste Mal hängt. Das Ziel: **jederzeit abbrechen, neu starten,
nachsehen ob es noch läuft und wie lange schon** — ohne zu raten und ohne
Ermittlungsarbeit.

## 1. Wiederaufsetzbar

Ein Lauf wird unterbrochen: Quota voll, Verbindung weg, Timeout, Ctrl-C. Ein
Skript, das sich nicht gedankenlos neu starten lässt, macht daraus eine Untersuchung.

- **Jedes Element ist SUCCESS, SKIP, ERROR oder CLEANUP — nie zwei davon in einem
  Zähler.** Ein Skip ist kein Fehler. Wer ein fremdes Werkzeug umhüllt, bildet
  dessen Exit-Codes und Meldungen bewusst ab; `|| fail` ist die Stelle, an der der
  Unterschied stirbt. Gemessen an einem Fall mit 204 Dateien: „exists, skipping"
  als Fehler gezählt ergab „142 failed", dann „148 failed", während die Zahl der
  fertigen Dateien stieg.
- **Zustand aus den Arbeitsprodukten ableiten, nicht aus einer Datei, die das
  Skript geschrieben hat.** Fortschrittsdatei und Marker fehlen genau dann, wenn
  der Lauf schlecht gestorben ist.
- **„Die Ausgabe verifiziert" statt „die Ausgabe existiert".** Eine abgebrochene
  Schreiboperation hinterlässt eine Datei, die fertig aussieht. Prüfsumme, Manifest
  oder wenigstens die erwartete Größe.
- **Atomar veröffentlichen:** unter Temp-Namen im selben Verzeichnis schreiben,
  dann `mv`/`rename`. Dann trägt nur Vollständiges den endgültigen Namen, und
  „existiert" wird wieder ein brauchbares Kriterium. Reste früherer Läufe beim
  Start aufräumen und als CLEANUP zählen.
- **Zusammenfassung, die für sich spricht:** alle vier Zähler plus was ein
  weiterer Lauf täte. `62 ok, 142 skip, 0 error, 0 übrig — nichts mehr zu tun`
  beendet die Diskussion, `62 ok, 142 failed` beginnt sie.
- **Exit-Codes trennen die Fälle:** 0 = fertig oder nichts zu tun, 1 = Fehler,
  75 = läuft bereits, 128+Signal = abgebrochen. Ein zweiter Lauf nach Erfolg
  endet mit 0.

## 2. Jederzeit abbrechbar

`SIGINT` und `SIGTERM` abfangen, das laufende Element **verwerfen** (nie halb
veröffentlichen), Zusammenfassung drucken, mit 130 beziehungsweise 143 enden.
Der Handler setzt nur ein Flag; die Schleife prüft es **zwischen** Elementen. Ein
Abbruch darf nie mehr kosten als das gerade laufende Element — bei langen
Elementen ist das die Obergrenze der Reaktionszeit und gehört in die Planung.

## 3. Fortschritt mit ETA

Pro Zeile `n/N`, Rate, ETA, verstrichene Zeit — gedrosselt (etwa je Sekunde bis
alle 10 s) und **zeilenweise auf stderr**, kein `\r`: ein Agent oder ein Logfile
sieht von einem Carriage-Return-Balken nichts oder Müll. Nicht durch einen
blockweise puffernden Filter wie `ts` leiten, sonst steht die Anzeige minutenlang
still, während gearbeitet wird.

**Die Rate nur aus Elementen berechnen, die in *diesem* Lauf wirklich bearbeitet
wurden — SKIPs zählen nicht.** Gemessen am 01.10.2026: 1000 Elemente, 900 davon
schon fertig, der Rest je 0,2 s Arbeit. Nach einer Sekunde:

| | Rate | ETA |
|---|---|---|
| `n / elapsed` (SKIPs mitgezählt) | 905/s | **0,1 s** |
| nur echte Arbeit | 4,9/s | **19 s** (tatsächlich ≈ 19 s) |

Die naive Fassung meldet „gleich fertig", während noch fast alles bevorsteht —
und zwar umso falscher, je erfolgreicher der vorherige Lauf war, also genau beim
Neustart.

## 4. „Läuft es noch?" — ohne PID zu raten

**Lock per `flock` auf eine Lock-Datei, die der Prozess offen hält.** Der Kernel
gibt ihn beim Tod frei, auch bei `kill -9` — es gibt keinen veralteten Zustand
wie bei einer PID-Datei. Gemessen am 01.10.2026 (perl 5.34.1, python3): Lock
gehalten → zweiter Versuch scheitert, nach `kill -9` des Halters sofort wieder
frei. Das Kommando `flock(1)` **gibt es auf macOS nicht** (`command -v flock`
ist leer), also in perl (`Fcntl :flock`) oder Python (`fcntl.flock`).

Zweiter Start bei gehaltenem Lock: klar melden (`läuft bereits: pid=… läuft seit
…`), mit **75** enden, nicht parallel loslegen. Daneben eine Statusdatei mit PID
und Startzeit — **nur zur Anzeige**, nie als Grundlage fürs Wiederaufsetzen.

## 5. „Seit wann?"

Startzeit in die Statusdatei, Gegenprobe mit `ps -o etime= -p <pid>` (macOS,
gemessen: `00:02`; das Format ist `[[dd-]hh:]mm:ss`). Ein `--status`-Schalter
macht daraus eine Frage statt einer Ermittlung: Lock-Probe, dann Statusdatei,
dann `etime`. Ist der Lock frei, lief keiner — dann ist auch eine Statusdatei
mit PID bloß ein Überbleibsel.

## Für Agenten

- **Lange Läufe vom Harness abkoppeln.** Hintergrundjobs des Harness sterben nach
  etwa 10 Minuten. `setsid` gibt es auf macOS nicht; stattdessen python3 mit
  `os.fork()` und `os.setsid()`, Ausgabe in eine Logdatei.
- **Status abfragen, nicht am Log raten:** `--status` beziehungsweise die
  Lock-Probe, dazu der Zeitstempel der letzten Fortschrittszeile.
- **Nach einem Abbruch einfach neu starten** — dafür ist Punkt 1 da. Nicht
  zuerst aufräumen, nicht Zustand nachbauen.

## Referenz: perl-Einzeiler (Liste in einer Datei, ein Element je Zeile)

Für die typische Form „Liste abarbeiten". Am 01.10.2026 gelaufen: normaler Lauf,
zweiter Lauf (alles SKIP, exit 0), Ctrl-C mitten drin (exit 130, 10 ok / 30
übrig), Doppelstart (exit 75, meldet PID und Startzeit), `kill -9` mit
zurückgelassener `*.tmp.*`-Datei und anschließender Neustart (Rest aufgeräumt,
Rest abgearbeitet). Das Beispiel schreibt pro Element eine Datei; die Zeile
`sleep 0.2` ist die Stelle für die eigentliche Arbeit.

```zsh
#!/bin/zsh
# usage: run.pl.sh <liste> <outdir>   (Element = Zeile; Ergebnis = <outdir>/<element>)
exec perl -CSDA -Mutf8 -MFcntl=:flock -MTime::HiRes=time,sleep -ne '
BEGIN {
  $list = $ARGV[0]; $dir = pop @ARGV;
  $lock = "$dir/.run.lock";
  open $LK, ">>", $lock or die "lock: $!";
  flock $LK, LOCK_EX|LOCK_NB or do {
    open my $s, "<", "$dir/.run.status"; my $st = <$s> // "?";
    print STDERR "läuft bereits: $st"; exit 75 };      # 75 = EX_TEMPFAIL
  $t0 = time;  $N = do { open my $f, "<", $list; my @l = <$f>; scalar @l };
  open my $s, ">", "$dir/.run.status"; print $s "pid=$$ start=@{[scalar localtime $t0]}\n"; close $s;
  unlink glob "$dir/*.tmp.*";                          # CLEANUP: Reste früherer Abbrüche
  $SIG{$_} = sub { $stop = shift } for qw(INT TERM);   # nur Flag; Schleife prüft zwischen Elementen
}
if ($stop) { last }
chomp; $n++; $out = "$dir/$_";
if (-s $out) { $skip++ }                               # SKIP: Arbeitsprodukt vorhanden (Größe > 0)
else {
  my $tmp = "$out.tmp.$$";
  sleep 0.2;                                           # <- hier die eigentliche Arbeit
  my $good = open(my $o, ">", $tmp);  $good &&= print $o "ok\n";  $good &&= close $o;
  if ($good) { rename $tmp, $out; $ok++ } else { $err++ }
}
if (time - ($last // 0) >= 1 or $n == $N) {            # gedrosselt, Zeilen statt \r
  $last = time; $el = $last - $t0;
  $rate = $ok / $el;                                   # nur echte Arbeit, SKIPs zählen nicht
  $eta = $rate > 0 ? sprintf "%ds", ($N - $n) / $rate : "?";
  printf STDERR "%d/%d  %.1f/s  ETA %s  elapsed %ds\n", $n, $N, $rate, $eta, $el;
}
END {
  return if $? or !defined $N;                        # bei die/Fehlstart den Exit-Code nicht überschreiben
  printf STDERR "%d ok, %d skip, %d error, %d übrig%s\n", $ok//0, $skip//0, $err//0, $N-($n//0),
    $stop ? " — abgebrochen" : ($N-($n//0) ? "" : " — nichts mehr zu tun");
  $? = $stop ? 128 + ($stop eq "INT" ? 2 : 15) : $err ? 1 : 0;
}' "$@"
```

Drei Fallen, an denen der erste Entwurf scheiterte:

- **`open(my $o, …) && print $o …` in einem Ausdruck:** `my $o` ist erst in der
  *nächsten* Anweisung sichtbar. Fehler: `Can't use an undefined value as a symbol
  reference`. Deshalb `$good` in drei Anweisungen.
- **`@ARGV` in `BEGIN` lesen, ohne das Verzeichnis zu entfernen:** `-n` liest dann
  auch das Verzeichnis als Eingabedatei. Daher `pop @ARGV`.
- **`$?` in `END` bedingungslos setzen:** überschreibt den Exit-Code eines `die`
  mit 0 — ein Totalausfall, der wie Erfolg aussieht. Deshalb `return if $?`.

Wird der Einzeiler länger als eine Bildschirmseite oder braucht Argument-Parsing,
ist das das Signal zum Wechsel auf Python (siehe Regel zum Skriptstil).

## Referenz: Python

Dasselbe Verhalten, plus `--status`. Am 01.10.2026 gelaufen: normaler Lauf,
`--status` während des Laufs (`läuft bereits: pid=… läuft seit 00:02`), Doppelstart
(exit 75), SIGINT (exit 130, 11 ok / 29 übrig), Neustart (29 ok, 11 skip, exit 0),
dritter Lauf (40 skip, exit 0), `--status` danach (`läuft nicht`). Für ein
richtiges Skript gelten Shebang und PEP-723-Header der Regel zum Skriptstil.

```python
#!/usr/bin/env python3
"""usage: run.py [--status] <liste> <outdir>   (Element = Zeile; Ergebnis = <outdir>/<element>)"""
import fcntl, os, signal, subprocess, sys, time

status_only = sys.argv[1] == "--status"
args = sys.argv[2:] if status_only else sys.argv[1:]
lst, out = args
statusf = f"{out}/.run.status"

def info():                                   # Anzeige, nie Resume-Grundlage
    pid = open(statusf).read().split()[0].removeprefix("pid=") if os.path.exists(statusf) else "?"
    et = subprocess.run(["ps", "-o", "etime=", "-p", pid], capture_output=True, text=True).stdout.strip()
    return f"pid={pid} läuft seit {et or '? (Prozess weg)'}"

lock = open(f"{out}/.run.lock", "a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)      # Kernel gibt ihn beim Tod frei
except BlockingIOError:
    print("läuft bereits:", info(), file=sys.stderr); sys.exit(75)   # 75 = EX_TEMPFAIL
if status_only:
    print("läuft nicht"); sys.exit(0)           # Lock war frei, also lief keiner
open(statusf, "w").write(f"pid={os.getpid()} start={time.ctime()}\n")

stop = []
for s in (signal.SIGINT, signal.SIGTERM):
    signal.signal(s, lambda sig, _f: stop.append(sig))   # nur Flag, Schleife prüft zwischen Elementen

items = open(lst).read().split()
t0 = last = time.monotonic()
ok = skip = err = n = 0
for item in items:
    if stop: break
    n += 1; dest = f"{out}/{item}"
    if os.path.exists(dest) and os.path.getsize(dest) > 0:          # SKIP: Arbeitsprodukt verifiziert
        skip += 1
    else:
        tmp = f"{dest}.tmp.{os.getpid()}"
        try:
            time.sleep(0.2)                                         # <- die eigentliche Arbeit
            open(tmp, "w").write("ok\n"); os.replace(tmp, dest); ok += 1   # atomar veröffentlichen
        except OSError:
            err += 1
            if os.path.exists(tmp): os.unlink(tmp)
    now = time.monotonic()
    if now - last >= 1 or n == len(items):                          # gedrosselt, Zeilen statt \r
        last = now; el = now - t0; rate = ok / el                   # nur echte Arbeit zählt
        eta = f"{(len(items) - n) / rate:.0f}s" if rate else "?"
        print(f"{n}/{len(items)}  {rate:.1f}/s  ETA {eta}  elapsed {el:.0f}s", file=sys.stderr)

left = len(items) - n
print(f"{ok} ok, {skip} skip, {err} error, {left} übrig"
      + (" — abgebrochen" if stop else " — nichts mehr zu tun" if not left else ""), file=sys.stderr)
sys.exit(128 + stop[0] if stop else 1 if err else 0)
```

Bekannte Lücke des Python-Skeletts: es räumt `*.tmp.*`-Reste früherer Abbrüche
nicht beim Start auf (der perl-Einzeiler tut es) — im echten Skript ergänzen und
als CLEANUP zählen.
