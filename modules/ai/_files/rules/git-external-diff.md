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

## Die zweite Falle in derselben Familie: textconv entschlüsselt Secrets

`.gitattributes` in `~/.config/nix-darwin` enthält `*.enc.yaml diff=sopsdiffer`,
und der Treiber ist `diff.sopsdiffer.textconv = sops -d`. **`git diff` gibt für
SOPS-Dateien also entschlüsselten Klartext aus**, damit ein Mensch die Änderung
lesen kann. Für ein Werkzeug ist das genau falsch herum: es liest Secrets, die im
Commit gar nicht stehen, und schreibt sie womöglich in ein Log, ein Ticket oder
eine Agenten-Konversation.

Gemessen am 27.08.2026 an einem echten Commit, der Arbeits-Secrets zwischen
SOPS-Dateien verschob:

| Kommando | Klartext-Treffer |
|---|---|
| `git diff --no-ext-diff …` | **3** |
| `git diff --no-ext-diff --no-textconv …` | **0** |

Der Commit selbst enthält nur `ENC[AES256_GCM,…]`. Der Klartext entstand erst
beim Anzeigen.

**Für alles Automatisierte deshalb beide Flags:**

```bash
git diff --no-ext-diff --no-textconv --no-color <range>
```

`--no-ext-diff` macht die Ausgabe überhaupt maschinenlesbar, `--no-textconv`
sorgt dafür, dass sie zeigt, was im Commit steht. Interaktiv beide weglassen —
dort sind difftastic und die Entschlüsselung ja der Zweck.

Dieselbe Frage stellt sich bei jedem weiteren textconv-Treiber; `git-crypt` ist
hier ebenfalls konfiguriert. `git config --get-regexp '^diff\.' ` zeigt sie alle.

## Die allgemeine Regel dahinter

**Einen Filter erst validieren, dann seinem Ergebnis glauben.** Zähle, wie viele
Zeilen er überhaupt sieht, bevor „keine Treffer" als Befund gilt. Ein Scan, der
strukturell nichts finden kann, meldet dasselbe wie ein sauberes Ergebnis — und
das ist dieselbe Fehlerklasse wie `date -d … || echo 0`, wo der Fallback den
Totalausfall in eine plausible Zahl verwandelt.
