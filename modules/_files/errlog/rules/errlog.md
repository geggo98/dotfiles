# `+errlog`: stderr von langen oder lauten Kommandos aus dem Kontext halten

Programme, die lange laufen oder erwartbar viel auf stderr schreiben (Gradle,
`nix build`, Migrationen, Testläufe, Downloads, Compiler), **mit `+errlog`
umhüllen**. Sonst füllt ihr stderr den Kontext — und genau die Zeile, die zählt,
geht darin unter.

```bash
+errlog -- ./gradlew --no-build-cache test
+errlog --mask-env API_TOKEN --mask-file ~/.config/sops-nix/secrets/db_password -- ./migrate.sh
```

## Was passiert

- **stdout und stdin bleiben unberührt**, der **Exit-Code kommt unverändert
  zurück** (Signal N → 128+N, nicht gefunden 127, nicht ausführbar 126).
  Exit **125** heißt: `+errlog` selbst ist vor dem Start gescheitert (falsche
  Option, unlesbare Maskendatei) — das Kommando lief dann nicht.
- **stderr geht in eine Datei** (Modus 0600, in `$TMPDIR`). Der Pfad steht sofort
  auf stderr: `[errlog] stderr -> <pfad> (pid <n>)`. Danach gezielt lesen, nicht
  alles: `tail -n 50 <pfad>`, `grep -n -i 'error\|fail' <pfad>`.
- **Am Ende** eine Zeile `[errlog] exit=<n> after <dauer>, <z> stderr lines …`.
  Nur bei exit ≠ 0 zusätzlich die **letzten 10 Zeilen** (`--tail N`, `--tail 0`
  schaltet ab) — meist genug, um die Ursache zu sehen.
- **Die Datei wird laufend geschrieben**, auch Zeilen ohne `\n` (Fortschrittsbalken
  mit `\r`, eine letzte `Error: …`-Meldung) sind nach etwa einer Viertelsekunde
  drin. Ein `tail -f` oder `tail` mitten im Lauf zeigt also den aktuellen Stand.
- **Metadaten stehen in der Datei** mit festem Präfix: `grep '^errlog:' <pfad>`
  liefert Befehl (maskiert), Start/Ende, Dauer, Exit-Code, CPU-Zeit, maximalen
  RSS, PIDs, Zeilen-/Bytezahl und die Zahl der Maskierungen.
- Das Kind sieht `ERRLOG_FILE=<pfad>` in der Umgebung.

## Maskieren

Bekannte Geheimnisse werden in der Datei **und** im Tail durch `***` ersetzt
(roh, URL-kodiert und URL-dekodiert; auch im protokollierten Befehl).

- **Nur über Datei oder Umgebungsvariable**: `--mask-file PATH` (jede nicht leere
  Zeile ein Wert — sops-nix-Dateien passen direkt), `--mask-env NAME`; als
  Voreinstellung `ERRLOG_MASK_FILES` (durch `:` getrennt) und `ERRLOG_MASK_ENVS`
  (durch `,` getrennt). Es gibt **absichtlich keine Option, die den Wert selbst
  nimmt** — der stünde in `ps` und in der Shell-Historie. `--mask GEHEIM` ist ein
  Fehler (125).
- Fehlt die Quelle oder ist sie leer, startet das Kommando **nicht** (125) —
  weiterlaufen ohne Maske wäre ein Leck.
- **Grenze:** maskiert wird, was man benennt. Muster wie `password=…` ohne
  bekannten Wert erkennt `+errlog` nicht (dafür gibt es `redact.pl` im
  database-Skill). Und die Datei bleibt trotzdem 0600 und gehört nicht in Tickets
  oder Commits.

## Wann nicht

- Interaktive Programme, die ein Terminal brauchen und deren stderr man sehen will.
- Kurze Kommandos mit kleiner Ausgabe — dort kostet der Umweg mehr, als er spart.
- Ersatz für Resumability, Abbruch und Fortschritt ersetzt es nicht; das steht in
  `long-running-scripts.md`. Beides lässt sich kombinieren.
