# Filter validieren, bevor „keine Treffer“ gilt

**Erst zählen, wie viele Zeilen ein Filter überhaupt sieht, dann seinem Ergebnis
glauben.** Ein Scan, der strukturell nichts finden kann, meldet dasselbe wie ein
sauberes Ergebnis.

Ein leeres Ergebnis ohne Fehler und mit Exit-Code 0 ist genau der Fall, dem man
misstrauen muss. Er sieht aus wie Erfolg und ist oft ein Totalausfall.

## Gemessenes Beispiel

Ein Plus-Zeilen-Filter (`grep '^+'`) über die Ausgabe eines externen
Diff-Programms, das `git diff` anstelle seines eigenen Diffs aufruft, fand 0
Plus-Zeilen. Der Unified-Diff derselben Commit-Spanne mit abgeschaltetem
externem Programm (`git diff --no-ext-diff`) hatte 789, gemessen am 27.08.2026.
Der Filter lief fehlerfrei und endete mit Exit-Code 0.

## Dieselbe Fehlerklasse

`date -d "$ts" +%s || echo 0`: `date -d` gibt es nur bei GNU, BSD-`date` bricht
ab, und der Fallback macht daraus eine plausible Zahl — ein stiller Totalausfall.
Siehe `script-style.md`.
