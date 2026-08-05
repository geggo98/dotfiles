# Klartext für deutsche IT-Texte (nach ISO 24495-1)

Diese Referenz überträgt die vier Prinzipien der Plain-Language-Norm ISO 24495-1:2023
auf deutsche IT-Texte: Jira-Tickets, PR-Beschreibungen, Review-Kommentare, Runbooks,
READMEs und Fehlermeldungen. Lade sie beim Schreiben oder Überarbeiten solcher Texte.

Hinweis zur Quelle: Diese Datei ist eine freie Adaption der Prinzipien und Leitlinien
aus ISO 24495-1:2023 ("Plain language — Part 1: Governing principles and guidelines")
für die IT-Praxis. Sie gibt den Normtext nicht wieder und übersetzt ihn nicht.
Verweise wie "ISO 5.2.2 a" nennen den zugehörigen Abschnitt der Norm.

Ein Text ist nutzbar, wenn sein Inhalt relevant, auffindbar und verständlich ist
(ISO Abschnitt 4). Prüfe alle vier Prinzipien, nicht nur eines.

## Prinzip 1: Relevant (ISO 5.1)

Leser bekommen, was sie brauchen. Kläre vor dem Schreiben, wer liest, warum und
in welcher Situation. Wähle danach Inhalt und Form aus.

### Identifiziere die Leser (ISO 5.1.2)

Benenne konkret, wer den Text liest. In der IT sind das selten "alle":

- die Reviewerin, die den PR freigeben soll
- der künftige Maintainer, der den Code in zwei Jahren erbt
- die On-Call-Kollegin, die das Runbook um 3 Uhr nachts öffnet
- der PM, der nur das Jira-Ticket liest und den Code nie sieht

Schreibe für den Leser mit dem wenigsten Vorwissen, der den Text braucht.

Schlecht (Runbook-Schritt, geschrieben für den Autor selbst):
> Wie üblich den Consumer neu starten, falls der Lag wieder hochgeht.

Besser (geschrieben für On-Call ohne Vorwissen):
> Wenn der Kafka-Consumer-Lag über 10 000 steigt (Dashboard "Orders / Lag"),
> starte den Consumer neu: `kubectl rollout restart deploy/order-consumer -n prod`.

### Identifiziere den Lesezweck (ISO 5.1.3)

Frage: Was will der Leser mit dem Text tun? Typische Zwecke: einen PR freigeben,
einen Bug reproduzieren, einen Aufwand schätzen, eine Störung beheben.

Der Zweck bestimmt den Inhalt. Ein Bug-Ticket, das der Zuweisung dient, braucht
Reproduktionsschritte. Ein Ticket, das der Priorisierung dient, braucht die
Auswirkung auf Nutzer.

Schlecht (Bug-Ticket ohne Bezug zum Lesezweck "reproduzieren"):
> Der Export funktioniert manchmal nicht richtig. Bitte anschauen.

Besser:
> CSV-Export bricht bei Umlauten im Kundennamen ab.
> Reproduktion: Kunde "Müller GmbH" anlegen, Export unter Berichte > CSV starten.
> Erwartet: Datei wird erzeugt. Beobachtet: HTTP 500, Stacktrace im Anhang.

### Identifiziere den Lesekontext (ISO 5.1.4)

Berücksichtige, wo und unter welchem Druck gelesen wird:

- Ein Diff wird überflogen, nicht studiert. Die PR-Beschreibung muss das Wichtige
  tragen, nicht der Diff.
- Ein Runbook wird mitten im Incident gelesen, unter Stress und mit halber
  Aufmerksamkeit. Jeder Schritt muss ohne Nachdenken ausführbar sein.
- Ein Jira-Ticket wird oft auf dem Handy oder im Sprint-Meeting gelesen. Die ersten
  zwei Zeilen entscheiden, ob der Rest gelesen wird.

Schlecht (Runbook als Fließtext, im Incident unbrauchbar):
> Falls die Datenbank nicht erreichbar ist, sollte man zunächst überlegen, ob es
> sich um ein Netzwerkproblem handeln könnte, und gegebenenfalls die Verbindung
> testen, bevor man weitere Schritte einleitet.

Besser:
> 1. Verbindung testen: `pg_isready -h db.prod.example.com -p 5432`
> 2. Bei "no response": Netzwerk-Runbook öffnen (Link).
> 3. Bei "accepting connections": weiter mit Schritt 4.

### Wähle den passenden Dokumenttyp (ISO 5.1.5)

Nicht jede Information gehört in denselben Kanal. Eine Architekturentscheidung
gehört in ein ADR, nicht in einen PR-Kommentar; eine API-Einschränkung in die
Referenzdoku, nicht nur in einen Slack-Thread. Wähle den Ort, an dem der Leser
später sucht.

### Wähle nur Inhalte aus, die Leser brauchen (ISO 5.1.6)

Stelle die Bedürfnisse der Leser vor deine eigenen (ISO 5.1.6 a). Lass weg, was
der Leser für seinen Zweck nicht braucht (ISO 5.1.6 d). Die Entstehungsgeschichte
einer Änderung interessiert den Reviewer selten; das Ergebnis und die Risiken
interessieren ihn immer.

Schlecht (PR-Beschreibung erzählt den Arbeitsweg):
> Zuerst habe ich versucht, das über einen Interceptor zu lösen, das ging aber
> nicht wegen der Filterreihenfolge. Dann habe ich es mit einem Aspekt probiert.
> Am Ende bin ich bei einem Servlet-Filter gelandet.

Besser:
> Fügt einen Servlet-Filter hinzu, der Request-IDs in den MDC schreibt.
> Interceptor und AOP-Aspekt scheiden aus, weil das Logging vor der
> Spring-Security-Kette greifen muss.

### Wähle Inhalte ehrlich aus (ISO 5.1.6 f)

Verschweige nichts, was der Leser wissen muss. Bekannte Limitierungen, offene
Punkte und bewusste Abkürzungen gehören in die PR-Beschreibung, nicht erst in das
Post-Mortem.

Schlecht (bekannte Lücke unerwähnt):
> Fügt Retry-Logik für den Payment-Client hinzu.

Besser:
> Fügt Retry-Logik für den Payment-Client hinzu.
> Bekannte Lücke: Retries sind nicht idempotent abgesichert. Bei einem Timeout
> nach erfolgreichem Buchen kann doppelt gebucht werden. Folgeticket: PAY-482.

## Prinzip 2: Auffindbar (ISO 5.2)

Leser finden schnell, was sie brauchen. Struktur und Gestaltung entscheiden, ob
der Leser in Sekunden erkennt, worum es geht und wo seine Antwort steht
(ISO 5.2.1).

### Die wichtigste Botschaft zuerst: TL;DR (ISO 5.2.2 a)

Platziere die Kernaussage dort, wo der Leser sie leicht findet, meist am
Anfang. In kurzen IT-Texten heißt das: immer an den Anfang. Daraus folgt die
TL;DR-Regel: Jedes Jira-Ticket, jede PR-Beschreibung und jeder längere
Review-Kommentar beginnt mit ein bis drei Sätzen, die das Wesentliche
zusammenfassen. Wer nur diese Sätze liest, kennt Kernaussage und nächste Aktion.

Schlecht (Ticket vergräbt die eigentliche Bitte):
> Im Zuge der Migration auf Postgres 16 sind einige Punkte aufgefallen. Die
> Extension pg_trgm ist in der neuen Version anders paketiert. Außerdem hat sich
> das Verhalten von... [12 weitere Zeilen] ...deshalb bräuchten wir bis Freitag
> eine Freigabe für das Wartungsfenster.

Besser:
> TL;DR: Wir brauchen bis Freitag die Freigabe für ein Wartungsfenster am 12.08.,
> 22:00 bis 23:00 Uhr, für die Migration auf Postgres 16.
>
> Hintergrund: [Details folgen]

### Gruppiere zusammengehörige Informationen (ISO 5.2.2)

Halte zusammen, was zusammengehört. Verstreute Angaben zum selben Thema zwingen
den Leser, den ganzen Text zu durchsuchen.

Schlecht (README verteilt Konfiguration über drei Abschnitte):
> Setze `DB_URL` in der `.env`. ... [40 Zeilen später] ... Für lokale Tests muss
> außerdem `DB_POOL_SIZE=2` gesetzt sein. ... [30 Zeilen später] ... Achtung:
> `DB_URL` braucht das Suffix `?sslmode=disable`.

Besser: Ein Abschnitt "Konfiguration" mit einer Tabelle aller Variablen, je mit
Pflicht/optional, Default und Beispielwert.

### Ordne Prozeduren chronologisch (ISO 5.2.2 c)

Beschreibe Abläufe in der Reihenfolge, in der sie ausgeführt werden. Nenne
Voraussetzungen vor dem ersten Schritt, nicht als Nachtrag.

Schlecht:
> Führe `terraform apply` aus. Vorher muss übrigens `terraform init` gelaufen
> sein, und du brauchst die AWS-Credentials aus dem Vault.

Besser:
> 1. AWS-Credentials laden: `vault read aws/creds/deploy`
> 2. `terraform init`
> 3. `terraform apply`

### Stelle Warnungen vor die Anweisung (ISO 5.2.2 e)

Wenn ein Fehler Schaden anrichtet, warne davor, bevor du die Anweisung gibst.
Eine Warnung nach dem Befehl kommt zu spät; der Leser hat ihn schon ausgeführt.

Schlecht:
> Führe `flyway migrate` auf der Produktions-DB aus. Hinweis: vorher unbedingt
> ein Backup ziehen, die Migration ist nicht rückwärtskompatibel.

Besser:
> Warnung: Die Migration ist nicht rückwärtskompatibel. Ziehe zuerst ein Backup
> (`just db-backup prod`). Führe erst danach `flyway migrate` aus.

### Nutze Informationsdesign (ISO 5.2.3)

Mache Struktur sichtbar. In Markdown heißt das konkret:

- Überschriften für Abschnitte, keine Fettdruck-Zeilen als Ersatz.
- Codeblöcke für alles, was kopiert oder ausgeführt wird. Befehle im Fließtext
  lassen sich nicht sauber kopieren.
- Tabellen für Werte mit gleicher Struktur (Konfiguration, Endpunkte, Fehlercodes).
- Nummerierte Listen für Reihenfolgen, Aufzählungszeichen für Mengen ohne
  Reihenfolge.

Schlecht:
> Starte den Dienst mit systemctl start api und prüfe mit journalctl -u api -f
> die Logs.

Besser:
> Starte den Dienst und prüfe die Logs:
>
> ```
> systemctl start api
> journalctl -u api -f
> ```

### Schreibe Überschriften, die den Inhalt vorhersagen (ISO 5.2.4)

Eine Überschrift verspricht dem Leser, was der Abschnitt liefert. Vage
Überschriften wie "Sonstiges", "Hinweise" oder "Details" verstecken Inhalt.

Schlecht: `## Wichtige Hinweise`

Besser: `## Rollback bei fehlgeschlagener Migration`

### Halte Zusatzinformationen getrennt (ISO 5.2.5)

Lagere aus, was nur manche Leser brauchen: lange Logs, vollständige Stacktraces,
Messreihen, Hintergrunddiskussionen. Geeignete Orte sind `<details>`-Blöcke in
PR-Beschreibungen und Tickets, Anhänge in Jira und Links auf bestehende Doku
statt kopierter Absätze.

Schlecht: Eine PR-Beschreibung mit 200 Zeilen Benchmark-Rohdaten im Haupttext.

Besser:
> Der neue Cache senkt die p95-Latenz von 480 ms auf 120 ms (Benchmark unten).
>
> <details><summary>Benchmark-Rohdaten (200 Zeilen)</summary> ... </details>

## Prinzip 3: Verständlich (ISO 5.3)

Leser verstehen, was sie finden. Wortwahl, Satzbau und Ton entscheiden darüber.

### Wähle vertraute Wörter (ISO 5.3.2)

Ersetze Bürokratendeutsch durch das gebräuchliche Wort:

| Statt | Schreibe |
|---|---|
| Verwendung finden | nutzen |
| aufgrund der Tatsache, dass | weil |
| einer Prüfung unterziehen | prüfen |
| zur Durchführung bringen | durchführen |
| zeitnah | bis (konkretes Datum) |

Schreibe Akronyme beim ersten Auftreten aus, wenn nicht jeder Leser sie kennt.
Der PM, der das Ticket liest, kennt "CQRS" oder "HPA" nicht unbedingt.

Schlecht:
> Die Anpassung findet im Rahmen der Umstellung Verwendung, aufgrund der Tatsache,
> dass der bisherige Prozess einer Überarbeitung unterzogen werden musste.

Besser:
> Wir nutzen die Anpassung für die Umstellung, weil der bisherige Prozess
> überarbeitet werden musste.

### Schreibe klare Sätze (ISO 5.3.3)

Eine Aussage pro Satz. Aktiv statt Passiv: Nenne, wer handelt. Passiv versteckt
den Handelnden, und genau der fehlt dem Leser später.

Schlecht (Commit-Message, Passiv ohne Akteur und ohne Grund):
> Es wurde beschlossen, dass die Timeouts angepasst werden.

Besser:
> Erhöht den HTTP-Timeout von 5 s auf 30 s, weil der Reporting-Endpoint bei
> großen Mandanten länger braucht.

### Schreibe knappe Sätze (ISO 5.3.4)

Kürze Sätze, bis jedes Wort trägt. Verschachtelte Nebensätze zwingen den Leser,
den Satz zweimal zu lesen.

Schlecht:
> Der Fehler, der immer dann auftritt, wenn ein Nutzer, der bereits eingeloggt
> ist, versucht, sich erneut einzuloggen, was durch einen zweiten Tab passieren
> kann, führt zu einer Session-Invalidierung.

Besser:
> Loggt sich ein bereits eingeloggter Nutzer erneut ein (zum Beispiel in einem
> zweiten Tab), wird seine Session invalidiert.

### Schreibe klare Absätze (ISO 5.3.5)

Ein Thema pro Absatz. Beginne den Absatz mit dem Satz, der das Thema nennt.
In Tickets und PR-Beschreibungen sind drei kurze Absätze mit je einem Thema
besser als ein Block über alles.

### Nutze Diagramme und Screenshots, wo sie helfen (ISO 5.3.6)

Ein Screenshot mit Markierung erklärt einen UI-Bug schneller als ein Absatz. Ein
Sequenzdiagramm erklärt einen Race-Condition-Fix schneller als Prosa. Ergänze das
Bild um einen Satz, der sagt, was darauf zu sehen ist.

Schlecht:
> Der Button ist auf kleinen Bildschirmen irgendwie verschoben und überlappt mit
> dem Text daneben, ungefähr im rechten oberen Bereich.

Besser:
> Ab Viewport-Breite unter 400 px überlappt der Button "Speichern" das Label
> "Status" (Screenshot, rote Markierung).

### Wahre einen respektvollen Ton (ISO 5.3.7)

Der Ton entscheidet, ob ein Review-Kommentar als Hilfe oder als Angriff ankommt.
Drei Regeln:

1. Kritisiere den Code, nicht die Person. "Diese Methode" statt "du".
2. Stelle echte Fragen statt rhetorischer Vorwürfe. Eine Frage unterstellt
   nichts und lädt zur Antwort ein.
3. Werde konkret. Ein vager Einwand ohne Vorschlag zwingt den Autor zum Raten.

Schlecht:
> Warum hast du das schon wieder ohne Null-Check gebaut? Das hatten wir doch
> schon mal.

Besser:
> `customer.getAddress()` kann hier null liefern, wenn der Kunde importiert
> wurde (siehe CustomerImporter, Zeile 88). Wollen wir hier ein
> `Optional.ofNullable` oder den Import härten?

Schlecht (vage): "Das gefällt mir nicht."

Besser (konkret):
> Die Methode macht zwei Dinge: Validierung und Persistenz. Vorschlag: die
> Validierung in `OrderValidator` ziehen, dann lässt sie sich einzeln testen.

### Halte den Text kohäsiv (ISO 5.3.8)

Verwende denselben Begriff für dieselbe Sache, im ganzen Text und über Texte
hinweg. Synonyme wirken in Prosa elegant; in technischen Texten erzeugen sie
Zweifel, ob zwei Begriffe zwei Dinge meinen.

Schlecht (drei Begriffe, ein Konzept):
> Der Auftrag wird angelegt. Danach prüft der Service die Order. Ist die
> Bestellung gültig, wird sie gespeichert.

Besser:
> Der Auftrag wird angelegt. Danach prüft der Service den Auftrag. Ist er
> gültig, wird er gespeichert.

## Prinzip 4: Nutzbar (ISO 5.4)

Leser können mit der Information arbeiten. Ob das gelingt, zeigt erst der
Gebrauch.

### Lies vor dem Absenden aus Lesersicht gegen (ISO 5.4.2)

Prüfe den Text, bevor er rausgeht, mit den Augen des Lesers: Kann die Reviewerin
nach der TL;DR entscheiden, ob sie tief einsteigen muss? Kann On-Call jeden
Schritt ausführen, ohne dich zu fragen? Wenn nein, überarbeite vor dem Absenden.

### Nimm Rückfragen als Messwert (ISO 5.4.3)

Rückfragen im Review und Ping-Pong im Ticket sind das ehrlichste Feedback zum
Text: Er hat nicht gereicht. Arbeite die Antwort in den Text ein, aus dem die
Frage entstand (PR-Beschreibung, Ticket, Doku), statt sie nur im Kommentar zu
geben. Sonst stellt die nächste Leserin dieselbe Frage wieder.

### Verbessere Vorlagen anhand der tatsächlichen Nutzung (ISO 5.4.4)

Beobachte, wie Texte wirklich genutzt werden, und passe Vorlagen und Doku an.
Überspringt On-Call im Incident regelmäßig einen Runbook-Schritt, ist der Schritt
falsch platziert oder überflüssig. Kommt jedes zweite Bug-Ticket ohne
Reproduktionsschritte an, fehlt das Feld in der Ticket-Vorlage.

## Checkliste

Beantworte jede Frage mit Ja oder Nein. Ein Nein heißt: nacharbeiten.

### Jira-Ticket

1. Beginnt das Ticket mit einer TL;DR von ein bis drei Sätzen?
2. Erkennt der Leser in den ersten zwei Zeilen, was er tun soll (entscheiden,
   fixen, priorisieren)?
3. Kann jemand den Bug allein mit den Angaben im Ticket reproduzieren
   (Schritte, erwartetes und beobachtetes Verhalten, Umgebung)?
4. Versteht auch der PM ohne Codekenntnis, worum es geht und was auf dem Spiel
   steht?
5. Sind Termine und Zuständigkeiten konkret ("bis 12.08.", nicht "zeitnah")?
6. Sind Logs und Stacktraces als Anhang oder eingeklappt, nicht im Haupttext?
7. Verwendet das Ticket durchgehend dieselben Begriffe wie Code und Doku?

### PR-Beschreibung

1. Fassen die ersten ein bis drei Sätze zusammen, was der PR ändert und warum?
2. Steht das Warum im Text, nicht nur das Was (das Was zeigt der Diff)?
3. Sind bekannte Limitierungen, Abkürzungen und offene Punkte genannt, je mit
   Folgeticket?
4. Kann die Reviewerin nach der Beschreibung entscheiden, welche Dateien sie
   genau lesen muss?
5. Steht drin, wie die Änderung getestet wurde und wie man sie selbst prüft?
6. Sind Breaking Changes und nötige Migrationsschritte vor den Details genannt?
7. Ist Zusatzmaterial (Benchmarks, lange Logs) eingeklappt oder verlinkt?

### Review-Kommentar

1. Nennt der Kommentar die Codestelle und das konkrete Problem, nicht nur ein
   Unbehagen?
2. Kritisiert er den Code statt der Person?
3. Ist er als echte Frage oder als Vorschlag formuliert, nicht als Vorwurf?
4. Enthält er einen umsetzbaren Vorschlag oder ein Beispiel?
5. Ist markiert, ob der Punkt blockierend ist oder nur ein Hinweis ("nit:")?
6. Beginnt ein langer Kommentar mit der Kernaussage in einem Satz?
7. Würdest du den Kommentar genauso schreiben, wenn die Autorin daneben säße?
