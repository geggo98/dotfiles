# macOS: GNU-Werkzeuge tragen ein `g`-Präfix

Auf diesem macOS-Rechner sind die GNU-Tools mit `g`-Präfix installiert, um sie von
den BSD-Varianten zu unterscheiden: `gtimeout`, `gsleep`, `gdate`, `gsed`,
`gstat` und so weiter.

**Das schlichte `timeout` existiert NICHT.** Statt `timeout 300 …` immer
`gtimeout 300 …` verwenden.

Die `g`-Werkzeuge bleiben richtig, wo es kein perl-Gegenstück gibt — `gtimeout`
und `gstat` sind Prozess- und Dateisystemwerkzeuge, keine Textverarbeitung. Für
Textverarbeitung siehe die Regel zum Skriptstil.
