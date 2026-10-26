# Verständlichkeit beim ersten Lesen (deutsche IT-Texte)

Die übrigen Referenzen dieses Skills verringern, was der Leser nachschlagen muss: ein Begriff
pro Konzept, kurze Sätze, die Kernaussage zuerst. Diese hier behandelt den Rest. Ein Text kann
alles davon erfüllen und trotzdem schwer zu folgen sein, weil der Leser einen Bezug raten, einen
fehlenden Schritt ergänzen oder eine verdichtete Formulierung entschlüsseln muss.

Flüssiger Maschinentext scheitert häufiger so als menschlicher Text. Eine Studie von 2026 hat
Modelltexte mit Menschentexten und mit Umschreibungen desselben Inhalts verglichen. Modelle
bevorzugen demnach Konstruktionen, die nachweislich das Lesen verlangsamen. Ein Folgeexperiment
führt einen Teil der Ursache auf Längendruck im Training zurück. Siehe "Quellen" am Ende.

Das ist eine Adaption der englischen Fassung `reader-comprehension.en.md`, keine Übersetzung.
Die Studie misst Englisch. Die Muster in §7 sind für das Deutsche daher übertragen, nicht
gemessen.

## 1. Beginne mit der Aussage

Nenne zuerst den Befund, die Erklärung oder die Empfehlung. Eröffne nicht mit einer Position,
die der Leser nie vertreten hat, um sie dann zu widerlegen.

Schlecht (Ticket): "Das ist kein Cache-Problem, sondern ein Schlüssel-Problem."

Gut: "Der Cache verfehlt, weil der Schlüssel den Zeitstempel der Anfrage enthält."

Schlecht: "Weniger Konfiguration. Mehr Konvention."

Gut: "Das Werkzeug braucht keine Konfigurationsdatei, wenn das Projekt dem Standardlayout
folgt."

Behalte eine Verneinung, wenn sie eine gestellte Frage beantwortet, einen geäußerten Irrtum
korrigiert oder eine echte Grenze nennt.

Gut: "Entfernt das Löschen des Symlinks das Paket? Nein. Das Paket bleibt im Store, bis die
nächste Garbage Collection läuft."

Erfinde keinen Einwand, den du dann entkräftest. Hat niemand die Alternative vorgeschlagen,
lass sie weg.

## 2. Halte ein Subjekt im Blick

Jeder Satz setzt entweder fort, was der Leser schon hält, oder kündigt einen Themenwechsel an.
Nenne dieselbe Sache immer gleich (Begriffe: STE-DE §1). Ein Sammelausdruck wie "das Muster",
"diese Grenze" oder "dieser Ansatz" muss auf etwas zeigen, das der Leser eindeutig
identifiziert. Kommen zwei Dinge infrage, nenne das gemeinte. Für ein nacktes "das" und "dies"
gilt STE-DE §8.

## 3. Sage, wie das eine aus dem anderen folgt

Eine Schlussfolgerung braucht ihren Grund, wenn der Leser ihn nicht selbst liefern kann.
Schreibe die Ursache, die Bedingung oder den Zwischenschritt hin.

Schlecht (PR-Beschreibung): "Die Migration ist riskant. Führe sie im Wartungsfenster aus."

Gut: "Die Migration sperrt die Tabelle `orders` während des Backfills, deshalb scheitern
Schreibzugriffe bis zum Ende. Führe sie im Wartungsfenster aus."

Ein Konnektor hilft, wenn er eine echte Beziehung benennt (STE-DE §4). Setze ihn nicht als
Schmuck.

## 4. Nutze echte Subjekte und echte Verben

Mach das Handelnde zum Subjekt und wähle das Verb für das, was wirklich geschieht. Modelle geben
einem unbelebten Subjekt oft ein belebtes Verb. Der Satz verdeckt dann, was passiert.

Schlecht: "`is_file()` schluckt den Fehler und gibt `False` zurück."

Gut: "`is_file()` gibt `False` zurück, wenn der Aufruf `PermissionError` auslöst."

Schlecht: "Der Scheduler frisst das Retry-Budget."

Gut: "Jeder Retry senkt das Retry-Budget um eins, und der Scheduler stoppt bei null."

Zur selben Gruppe gehört das Ad-hoc-Verb aus einem Substantiv: "den Release kalendern", "das
Ticket durchjiraen". Der Leser muss ein neues Wort entschlüsseln. Nimm das Verb, das ein Kollege
erwartet: "den Release in den Kalender eintragen", "das Ticket in Jira anlegen".

Etablierte Fachverben sind in Ordnung ("loggen", "cachen", "parsen", "deployen"). Setze sie
konsistent ein (STE-DE §1).

## 5. Setze ein Bild nur ein, wenn die Zuordnung offensichtlich ist

Kenne die wörtliche Bedeutung, bevor du die Metapher schreibst. Behalte eine Analogie, wenn der
Leser jeden Teil ohne Hilfe zuordnet und sie etwas besser erklärt als der wörtliche Text. Lass
sie weg, wenn sie die Aussage ersetzt, Annahmen einschmuggelt, die die Fakten nicht tragen,
oder der Leser sie zurückübersetzen muss.

Schlecht: "Die Queue ist das Herzstück des Systems."

Gut: "Jeder Dienst liest seine Aufgaben aus der Queue. Fällt die Queue aus, arbeitet kein Dienst
mehr."

Redewendungen, die der Leser kennt, brauchen weder Erklärung noch Streichung.

## 6. Lass den Gedanken die Satzgrenze setzen

Lass einen Grund, eine Bedingung oder eine Folge an ihrer Aussage hängen, wenn die Trennung die
Beziehung verdecken würde. Teile einen Satz, der zwei Gedanken trägt. Verbinde Fragmente, die
voneinander abhängen.

Schlecht: "Dreimal gescheitert. Dieselbe Ursache. Timeout zu niedrig."

Gut: "Der Job ist dreimal aus demselben Grund gescheitert: Der Timeout war zu niedrig."

Die Satzlängen aus STE-DE §4 gelten weiter (etwa 20 Wörter für eine Anweisung, etwa 25 sonst).
Sie sind eine Obergrenze. Sie verlangen kein Stakkato aus Kurzsätzen. Vermeide einen Text, in
dem jede Tatsache eine eigene Pointe in einer Zeile ist, und einen, in dem alle Sätze gleich
lang sind. Ein langer Satz für einen langen Gedanken ist in Ordnung.

Wo der Dokumenttyp es erlaubt, beziehe Stellung. Eine Erklärung wägt Kompromisse ab und sagt,
welcher gewinnt. Eine Referenz bleibt trocken (siehe `plain-language.de.md`, "Wähle den
passenden Dokumenttyp").

## 7. Verdichtung ist keine Kürze

"Streiche unnötige Wörter" entfernt Wörter, die nichts leisten. Ein Funktionswort, das die
Struktur markiert, leistet etwas. Die Studie hat bei Modellen die gegenteilige Gewohnheit
gemessen: Sie lassen das optionale Wort weg, stapeln Substantive und packen Bedeutung in
weniger Tokens. Der Leser zahlt dafür. Für das Deutsche übersetzen sich die Muster so:

| Muster | Beispiel | Korrektur |
|---|---|---|
| Fehlendes Strukturwort | "Der Fehler tritt auf, Cache ist kalt." | "Der Fehler tritt auf, weil der Cache kalt ist." |
| Weggelassenes "dass" | "Prüfe, Job ist durchgelaufen." | "Prüfe, dass der Job durchgelaufen ist." (STE-DE §4) |
| Bandwurm-Kompositum | "Sitzungstokencacheinvalidierungslogik" | "die Logik, die gecachte Sitzungstokens ungültig macht" (STE-DE §2) |
| Substantiv zum Verb gebogen | "den Release kalendern" | "den Release in den Kalender eintragen" |
| Unbelebtes Subjekt, belebtes Verb | "der Parser verschluckt sich an Tabs" | "der Parser bricht bei einem Tabulatorzeichen ab" |
| Weite Klammer um Verb und Rest | "Die Funktion, die der Loader aufruft, nachdem er alle im Manifest deklarierten Importe aufgelöst hat, liefert eine Liste." | "Der Loader löst zuerst alle Importe aus dem Manifest auf und ruft dann die Funktion auf. Sie liefert eine Liste." |
| Nominalstil statt Verb | "Durchführung einer Prüfung der Konfiguration" | "die Konfiguration prüfen" (STE-DE §3) |

Behalte Artikel, "dass" und Verben. Schreibe Pfeile, Symbole und Abkürzungen aus, die der Leser
noch nicht kennt (STE-DE §4 und §8). Prüfe auch das Gegenteil: Ein Satz, der alle Regeln
erfüllt und trotzdem mechanisch klingt, braucht eine Umformulierung und keine weitere Regel.

Ein Werkzeug, das Wörter zählt, belohnt die verdichtete Fassung. Der Leser nicht.

## 8. Erfinde keine Fakten, um konkret zu klingen

Mach einen vagen Satz nur mit Fakten konkret, die du hast. Füge kein Motiv, keinen Mechanismus,
keine Zahl und keine Ursache hinzu, die dir niemand genannt hat. Wenn die fehlende Angabe
zählt, frage nach oder schreibe, dass sie unbekannt ist. Mach aus einer Vermutung keine
Aussage.

Schlecht: "Der Ausfall kam von einem falsch konfigurierten Load Balancer." (Einziger Beleg: eine
Häufung von 502-Antworten.)

Gut: "Der Ausfall begann mit einer Häufung von 502-Antworten. Die Ursache ist noch unbekannt.
Der Load Balancer ist ein Kandidat."

Behalte die Stimme des Autors. Wärme, Humor und nützliche Komplexität sind keine Fehler.

## 9. Lies einmal als Leser gegen

Suche vor dem Absenden diese Stellen:

1. Der Leser muss raten, worauf sich "dies", "das" oder "das Muster" bezieht.
2. Eine Schlussfolgerung hat keinen sichtbaren Grund.
3. Eine Metapher oder ein erfundener Begriff steht, wo eine schlichte Aussage reichen würde.
4. Ein Satz beginnt mit der Verneinung von etwas, das niemand gesagt hat.
5. Eine dramatische Pause (ein Fragment, ein Ein-Zeilen-Absatz) ersetzt eine Erklärung.
6. Ein Funktionswort, ein Artikel oder ein Verb fehlt.

Behebe, was du findest. Ergänze nichts, was die Fakten nicht tragen, und hänge keinen Bericht
über die Prüfung an.

## Quellen

Diese Datei fasst die folgenden Quellen zusammen. Formulierung und Beispiele sind eigen.

- Why is AI-generated language so hard to understand? arXiv 2610.29162, 2026.
  <https://arxiv.org/html/2610.29162>
  Gemessene Merkmale: seltene n-Gramme, lange Abhängigkeiten, Substantivstapel, Ad-hoc-Verben
  aus Substantiven, unbelebte Subjekte mit belebten Verben und verkürzte Relativsätze. Die
  Autoren nennen ihr Experiment zum Längenmalus einen Machbarkeitsnachweis an einem kleinen
  Modell. Untersucht ist Englisch.
- writing-clarity.md, ein öffentliches Gist, Stand Commit
  `3bc8462be49b7e34e49a547e56a9e756c5404a59`.
  <https://gist.github.com/lxe/4cd2ca0fd3b714b25f138227c8c650d3>
- `unslop` und `technical-writing` aus dem pstack-Plugin, MIT-Lizenz.
  <https://github.com/cursor/plugins/tree/main/pstack/skills>
  Die übernommenen Katalogeinträge aus `unslop` stehen in `anti-tropes-instruction.md`, die
  Teile aus `technical-writing` in `plain-language.de.md` und
  `simplified-technical-english.de.md`.
