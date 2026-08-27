# Fremde Daten und interne Infrastruktur: nur nach ausdrücklicher Freigabe

Zwei Kategorien nie ungefragt in ein Repository schreiben — unabhängig davon, ob
es öffentlich ist, denn die Sichtbarkeit kann sich ändern, der Inhalt bleibt in
der Historie:

1. **Personenbezogene Daten Dritter** — Namen, Mailadressen, Account-IDs, Handles
   von jemand anderem als mir. Diese Personen wurden nicht gefragt.
2. **Interne Infrastruktur** — Hostnamen, Repository- und Produktnamen,
   Projekt-Kürzel, Cloud-Projekt-IDs, echte Ticketnummern, Runbook-Namen,
   Workflow-Konfiguration.

**Eine einmal erteilte Freigabe gilt nicht weiter.** Jedes Mal neu fragen.

**Und bei jedem Review auch das hinterfragen, was schon dort steht.** Dass etwas
im Repo liegt, ist kein Beleg dafür, dass es jemand freigegeben hat — meistens
heißt es, dass niemand hingesehen hat.

**Kennungen entziehen sich der Stichwortsuche.** Eine Account-ID steht als blanke
Zeichenkette im Code, ohne Firmennamen daneben. Keine Suche nach „intern" oder
nach einem Firmennamen findet sie je. Es reicht deshalb nicht, nach verdächtigen
Wörtern zu greppen — die Formate selbst müssen gesucht werden: ID-artige
Zeichenketten, Ticket-Muster wie `ABC-1234`, PR-Nummern, Repo-Slugs,
Mailadressen.

**Eingefügte Beispielausgabe ist der häufigste Weg hinein**, weil sie mitbringt,
was zufällig auf der Zeile stand. Vor dem Commit echte Ticketnummern, PR-Nummern,
Repo-Slugs und Account-IDs durch Platzhalter ersetzen — und zwar **alle auf der
Zeile, nicht nur die auffälligen**. Der typische Fehler ist, Branchnamen und
Issue-ID zu bereinigen und den Repo-Slug und die PR-Nummer daneben stehen zu
lassen.

**Den Scan validieren, bevor „keine Treffer" als Ergebnis gilt.** Ein Filter, der
strukturell nichts finden kann, meldet dasselbe wie ein sauberes Ergebnis. Erst
zählen, wie viele Zeilen er überhaupt sieht. Siehe die Regel zu `git diff` und
difftastic für einen gemessenen Fall, in dem genau das passiert ist.

Im Zweifel fragen. Eine Frage kostet nichts; eine nachträgliche Bereinigung
kostet einen Rewrite der Historie und einen Force-Push.
