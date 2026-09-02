# `git history` gibt es hier — aber nur mit Terminal

git ab 2.54 bringt `git history` mit, angekündigt als „EXPERIMENTAL: Rewrite
history":

```
git history reword <commit> [--dry-run] [--update-refs=(branches|head)]
git history split  <commit> [--dry-run] [--update-refs=(branches|head)] [--] [<pathspec>...]
```

Auf diesen Rechnern kommt git aus nixpkgs über home-manager (`modules/git.nix`,
`programs.git`), deshalb liegt 2.54.0 auf dem PATH. **Apples git kann es nicht**,
gemessen am 02.09.2026:

```console
$ env -i /usr/bin/git --version
git version 2.50.1 (Apple Git-155)
$ env -i /usr/bin/git history -h
git: 'history' is not a git command. See 'git --help'.   # exit 1
```

Das `env -i` ist keine Zierde. Ohne es meldete `/usr/bin/git --version` hier
**2.54.0**, weil die Umgebung durchschlägt — wer die Verfügbarkeit prüfen will,
muss die Umgebung leeren, sonst misst er die Nix-Version über den Apple-Pfad.

## Für Agenten: nicht benutzbar

`git history split` wählt die Hunks **interaktiv**, mit demselben Selektor wie
`git add -p` („Diesen Patch-Block der Staging-Area hinzufügen [y,n,q,a,d,?]"). Ein
Pathspec schränkt nur den Ausschnitt ein, er ersetzt die Auswahl nicht — die
Vorstellung, `git history split <commit> -- <pfade>` teile rein nach Dateien, ist
falsch.

Ohne Terminal scheitert es sauber:

```console
$ git history split HEAD -- a.txt </dev/null
Fehler: split commit is empty          # exit 255, HEAD unverändert
```

Laut und folgenlos, also ungefährlich — aber eben auch nutzlos in Automatisierung.
`--dry-run` hilft nicht, es fragt genauso.

**Nicht-interaktive Entsprechung**, wenn ein Commit entlang von Hunks geteilt
werden muss:

```bash
git diff --no-ext-diff --no-textconv --no-color <datei> > /tmp/p.patch
# gewünschte Hunks herausschneiden: Datei-Header plus die @@-Blöcke
git apply --cached --recount /tmp/p.patch
git commit -m "..."   # der Rest bleibt im Arbeitsbaum für den nächsten Commit
```

`--recount` macht die Zeilenzähler des Ausschnitts wieder stimmig, wenn davor
liegende Hunks fehlen. Die beiden `--no-*`-Flags sind Pflicht — siehe die Regel zu
`git diff` und difftastic.

Wo die Trennlinie ohnehin zwischen Dateien verläuft, ist der einfachere Weg, von
vornherein zweimal zu committen statt einen Commit nachträglich zu zerlegen.

`git history` schreibt Historie um. Für bereits gepushte Commits gilt das Übliche:
erst abstimmen, dann `--force-with-lease`.

## Nebenbefund aus derselben Messung

`kommando | head; echo $?` meldet den Status von `head`, nicht den des Kommandos.
Genau hier stand deshalb zuerst „exit=0", während der echte Code 255 war — und
„exit 0, tut aber nichts" hätte zu einer ganz anderen Regel geführt als „exit 255,
scheitert sauber". Exit-Codes ohne Pipe messen, oder `PIPESTATUS` beziehungsweise
`pipefail` benutzen.
