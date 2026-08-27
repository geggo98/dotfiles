# `git diff` nutzt hier difftastic, deshalb findet `grep '^+'` nichts

`modules/git.nix` setzt `programs.difftastic.git.enable`. Das schreibt
`diff.external` nach `~/.config/git/config`, also **benutzerweit für jedes
Repository auf dieser Maschine** — nicht nur für das nix-darwin-Repo.

Folge: `git diff` gibt **kein Unified-Diff** aus, sondern eine strukturelle
Ansicht mit Zeilennummern am Zeilenanfang. Jede Pipeline, die auf `+`- oder
`-`-Zeilen filtert, liefert **null Treffer, ohne Fehler und mit Exit-Code 0**.

Gemessen auf derselben Commit-Spanne:

| Kommando | Plus-Zeilen |
|---|---|
| `git diff …` | **0** |
| `git diff --no-color …` | **0** |
| `git diff --no-ext-diff …` | **789** |
| `git show`, `git log -p`, `git format-patch` | korrekt |

`git show` und `git log -p` sind **nicht** betroffen: laut `git-log(1)` muss ein
externer Differ dort mit `--ext-diff` ausdrücklich eingeschaltet werden, die
log-Familie läuft also standardmäßig ohne. `git diff --stat` und
`--name-only` funktionieren ebenfalls normal — was den Irrtum stützt, weil der
Befehl sich unauffällig verhält, bis man auf Zeileninhalte filtert.

## Was nicht hilft

- **`--no-color`** — das Problem ist der externe Differ, nicht die Farbe.
- **`GIT_EXTERNAL_DIFF=` und `-c diff.external=`** — beide sehen aus wie ein
  Ausschalter und sind keiner. Git versucht, die leere Zeichenkette als Programm
  auszuführen, und bricht ab:
  `cannot run : No such file or directory` /
  `externes Diff-Programm unerwartet beendet`.

## Richtig

```bash
git diff --no-ext-diff --no-color <range>   # echtes Unified-Diff
git grep -n MUSTER <commit> -- <pfade>      # Inhalt statt Diff-Ausgabe
```

Für Sicherheits- und Vollständigkeitsprüfungen die zweite Form bevorzugen: sie
prüft, was im Commit steht, statt eine Ausgabeformatierung zu parsen.

## Die allgemeine Regel dahinter

**Einen Filter erst validieren, dann seinem Ergebnis glauben.** Zähle, wie viele
Zeilen er überhaupt sieht, bevor „keine Treffer" als Befund gilt. Ein Scan, der
strukturell nichts finden kann, meldet dasselbe wie ein sauberes Ergebnis — und
das ist dieselbe Fehlerklasse wie `date -d … || echo 0`, wo der Fallback den
Totalausfall in eine plausible Zahl verwandelt.
