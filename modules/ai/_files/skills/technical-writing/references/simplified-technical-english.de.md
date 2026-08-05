# Vereinfachtes Technisches Deutsch (nach ASD-STE100)

Diese Referenz überträgt die Schreibprinzipien des ASD-STE100 (Simplified Technical English, Issue 9) auf deutsche IT-Texte. Lade sie, wenn du auf Deutsch Jira-Tickets, PR-Beschreibungen, Review-Kommentare, Runbooks, READMEs oder Architektur-Doku schreibst oder überarbeitest.

Quelle und Abgrenzung: Adaptiert für IT-Texte von "ASD-STE100 Simplified Technical English", Issue 9 (2025), herausgegeben von der Aerospace, Security and Defence Industries Association of Europe (ASD). Der Standard regelt kontrolliertes Englisch. Diese Datei überträgt seine Prinzipien frei auf das Deutsche. Sie übernimmt keinen Wortlaut aus dem Standard und ersetzt ihn nicht.

## 1. Terminologie

### Verwende einen Begriff pro Konzept (abgeleitet von STE 1.11)

Benenne dasselbe Ding im ganzen Dokument gleich. Synonyme wirken in Prosa elegant, in technischen Texten erzeugen sie Zweifel, ob zwei Begriffe zwei Dinge meinen.

Schlecht (Runbook): "1. Starte das Gateway neu. 2. Prüfe die Logs des Proxys. 3. Wenn der Edge-Service weiter Fehler wirft, eskaliere."

Gut: "1. Starte das Gateway neu. 2. Prüfe die Logs des Gateways. 3. Wenn das Gateway weiter Fehler wirft, eskaliere."

### Führe ein Projektglossar als kontrolliertes Wörterbuch (abgeleitet von STE 1.1 und 1.8)

Lege zentrale Begriffe im Glossar fest und verwende nur diese. Prüfe vor dem Schreiben, ob es für ein Konzept schon einen festgelegten Begriff gibt.

Schlecht (Jira-Ticket): "Der Kunde sieht die Rechnungen anderer Kunden." (Meint "Kunde" den Mandanten oder die zahlende Firma?)

Gut: "Ein Mandant sieht die Rechnungen anderer Mandanten." (Das Glossar definiert: Mandant = engl. tenant, isolierter Datenraum.)

### Nutze englische Fachbegriffe konsistent, ohne sie zwanghaft einzudeutschen (abgeleitet von STE 1.8 und 1.11)

Etablierte englische Fachbegriffe wie Commit, Branch, Pull-Request oder Deployment bleiben englisch. Erfundene Übersetzungen verwirren mehr, als sie helfen. Wähle aber pro Konzept eine Form und mische nicht.

Schlecht (Review-Kommentar): "Bitte die Änderung noch committen. Und vergiss nicht, den Fix aus main auch einzuchecken."

Gut: "Bitte committe die Änderung. Und committe auch den Fix aus main."

### Vermeide regionale Begriffe, Slang und Jargon (abgeleitet von STE 1.10)

Slang versteht nur, wer ihn schon kennt. Beschreibe stattdessen den beobachtbaren Zustand.

Schlecht (Jira-Ticket): "Nach dem Firmware-Update ist die Kiste gebrickt."

Gut: "Nach dem Firmware-Update startet das Gerät nicht mehr. Die Status-LED bleibt aus."

### Wähle neue Begriffe kurz und verständlich (abgeleitet von STE 1.9)

Wenn kein festgelegter Begriff existiert, wähle einen kurzen mit höchstens drei Gliedern. Der Begriff muss ohne Erklärung verständlich sein.

Schlecht (Architektur-Doku): "Das Modul zur automatisierten Berichtserstellung und -verteilung schreibt in den S3-Bucket."

Gut: "Der Report-Generator schreibt in den S3-Bucket."

## 2. Komposita und Wortketten

### Begrenze Komposita auf etwa drei Glieder (abgeleitet von STE 2.1)

Was im Englischen ein Noun-Cluster ist, ist im Deutschen ein Bandwurm-Kompositum. Ab vier Gliedern muss der Leser die Beziehungen zwischen den Teilen raten. Löse lange Komposita mit Präpositionen auf oder kürze sie auf drei Glieder.

Schlecht (README): "Passe die Datenbankverbindungskonfigurationsdatei an."

Gut: "Passe die Konfigurationsdatei der Datenbankverbindung an." Oder: "Passe die Datenbank-Verbindungskonfiguration an."

### Kopple gemischte Komposita mit Bindestrichen durch (abgeleitet von STE 2.2 und 8.2)

Deutsch-englische Mischkomposita ohne Bindestriche sind schwer zu lesen, mit Leerzeichen sind sie orthografisch falsch. Kopple durch.

Schlecht (PR-Beschreibung): "Der End to End Test für die Open Source Lizenz Prüfung läuft jetzt in der Pipeline."

Gut: "Der End-to-End-Test für die Open-Source-Lizenzprüfung läuft jetzt in der Pipeline."

### Schreibe lange offizielle Namen einmal aus, dann nutze eine Kurzform (abgeleitet von STE 2.2)

Führe beim ersten Vorkommen den vollen Namen mit Abkürzung in Klammern ein. Verwende danach die Kurzform. Vermeide aber Texte, die nur noch aus Abkürzungen bestehen.

Schlecht (Architektur-Doku): "Das ZKVS validiert Tokens. Das System prüft gegen den IdP, bevor das ZKVS antwortet." (ZKVS ist nirgends erklärt.)

Gut: "Der zentrale Konfigurations-Verteilungsservice (ZKVS) validiert Tokens. Der ZKVS prüft gegen den Identity Provider, bevor er antwortet."

## 3. Verben

### Schreibe im Aktiv und im Präsens (abgeleitet von STE 3.2 und 3.6)

Das Aktiv nennt den Akteur. Das Präsens beschreibt, was der Code tut. Vermeide Futur, wenn das Präsens denselben Inhalt trägt.

Schlecht (PR-Beschreibung): "Es wurde eine Validierung der Eingaben ergänzt, und es wurden die Tests entsprechend angepasst."

Gut: "Dieser PR ergänzt eine Eingabevalidierung und passt die Tests an."

### Verwende das Passiv nur, wenn der Akteur unbekannt oder unwichtig ist (abgeleitet von STE 3.6)

Ein Passivsatz ist erlaubt, wenn niemand wissen muss, wer handelt. Sobald der Akteur zählt, nenne ihn. STE selbst erlaubt das Passiv nur, wenn der Akteur unbekannt ist. Diese Adaption lässt es auch zu, wenn der Akteur unwichtig ist.

Erlaubt (README): "Die Konfiguration wird beim Start eingelesen."

Schlecht (Incident-Bericht): "Das Feature-Flag wurde am Freitag aktiviert." (Wer hat es aktiviert? Das ist hier die zentrale Information.)

Gut: "Das On-Call-Team aktivierte das Feature-Flag am Freitag."

### Löse Nominalstil in Verben auf (abgeleitet von STE 3.7)

Substantivierte Verben mit Hilfskonstruktionen ("erfolgt", "findet statt") verstecken die Handlung. Mache die Handlung zum Verb des Satzes.

Schlecht (Runbook): "Die Durchführung der Migration erfolgt über das Skript migrate.sh."

Gut: "Das Skript migrate.sh migriert die Datenbank." Oder als Anweisung: "Führe migrate.sh aus."

### Vermeide Funktionsverbgefüge, wo ein einfaches Verb reicht (abgeleitet von STE 3.7)

"In Betrieb nehmen", "zur Ausführung bringen", "eine Prüfung vornehmen": solche Gefüge blähen den Satz auf. Nutze das einfache Verb, außer das Gefüge ist der etablierte Fachbegriff (etwa "in Betrieb nehmen" für die Erstinbetriebnahme einer Anlage).

Schlecht (Runbook): "Nimm den Dienst wieder in Betrieb und nimm eine Prüfung der Logs vor."

Gut: "Starte den Dienst. Prüfe die Logs."

### Nutze Vergangenheitsformen nur für Vergangenes (abgeleitet von STE 3.2)

In Incident-Berichten und Changelogs ist die Vergangenheitsform korrekt. In Beschreibungen von aktuellem Verhalten ist das Präsens die Normalform.

Schlecht (README): "Das Skript wird die alten Einträge löschen und wird danach einen Report erzeugen."

Gut: "Das Skript löscht die alten Einträge und erzeugt danach einen Report."

## 4. Sätze

### Halte Sätze kurz (abgeleitet von STE 5.1 und 6.3)

Richtwert: höchstens 20 Wörter pro Satz in Anleitungen, höchstens 25 Wörter in beschreibendem Text. Teile längere Sätze auf.

Schlecht (Runbook): "Fülle die Staging-Datenbank über das Seed-Skript mit Testdaten, bis der Dashboard-Zähler ungefähr 10.000 Einträge anzeigt, und beobachte dabei die Fehlerrate im Grafana-Board, das im Team-Ordner liegt."

Gut: "Fülle die Staging-Datenbank mit dem Seed-Skript, bis der Dashboard-Zähler ungefähr 10.000 Einträge zeigt. Beobachte dabei die Fehlerrate im Grafana-Board im Team-Ordner."

### Löse Schachtelsätze auf (abgeleitet von STE 4.1)

Verschachtelte Relativsätze sind das deutsche Gegenstück zu den Langsätzen, die STE verbietet. Mache aus jeder eingeschobenen Information einen eigenen Satz.

Schlecht (Jira-Ticket): "Der Export, der nachts läuft, schlägt fehl, weil der Token, den das Deployment erzeugt, abläuft, bevor der Job endet."

Gut: "Der nächtliche Export schlägt fehl. Ursache: Das Deployment erzeugt den Token mit einer Gültigkeit von einer Stunde. Der Job läuft aber länger als eine Stunde."

### Schreibe keine Auslassungen im Telegrammstil (abgeleitet von STE 4.2)

Im Chat sind Stichworte in Ordnung. In Tickets, Runbooks und Berichten fehlen dem Leser sonst Subjekt, Verb und Zusammenhang.

Schlecht (Incident-Notiz): "DB down, Failover ok, Ursache unklar, Monitoring beobachten."

Gut: "Die Datenbank fiel um 14:32 aus. Der Failover auf die Replika hat funktioniert. Die Ursache ist noch unklar. Beobachte das Monitoring bis zum Abschluss der Analyse."

### Nutze vertikale Listen für komplexe Inhalte (abgeleitet von STE 4.3)

Drei oder mehr gleichrangige Elemente in einem Satz sind schwer zu erfassen. Eine Liste macht Reihenfolge und Vollständigkeit sichtbar.

Schlecht (PR-Beschreibung): "Zum Testen bitte den Branch auschecken, docker compose up ausführen, unter /admin einloggen und dann prüfen, ob der neue Tab erscheint."

Gut: "Zum Testen:
1. Checke den Branch aus.
2. Führe docker compose up aus.
3. Logge dich unter /admin ein.
4. Prüfe, ob der neue Tab "Audit" erscheint."

### Setze Artikel (abgeleitet von STE 4.5)

Weggelassene Artikel sparen wenig und kosten Klarheit, besonders für Leser mit Deutsch als Fremdsprache.

Schlecht (README): "Skript erzeugt Konfigurationsdatei in Home-Verzeichnis."

Gut: "Das Skript erzeugt eine Konfigurationsdatei im Home-Verzeichnis."

### Schreibe dass-Sätze aus (abgeleitet von STE GR-1)

Ein weggelassenes "dass" verschleiert, wo der Hauptsatz endet und der Nebensatz beginnt. Das "dass" markiert die Grenze und erleichtert Verstehen und Übersetzung.

Schlecht (Runbook): "Stelle sicher, der Export ist beendet."

Gut: "Stelle sicher, dass der Export beendet ist."

### Schreibe konkret statt abstrakt (abgeleitet von STE 4.1)

Abstrakte Aussagen lassen sich nicht prüfen. Nenne Zahlen, Bedingungen und beobachtbare Effekte.

Schlecht (Ticket-Akzeptanzkriterium): "Die Performance darf sich nicht verschlechtern."

Gut: "Die p95-Latenz von GET /orders bleibt unter 300 ms bei 100 Anfragen pro Sekunde."

## 5. Anleitungen

Gilt für Runbooks, How-tos, Repro-Schritte und Testanleitungen in PRs.

### Wähle einen Anweisungsstil und halte ihn durch (abgeleitet von STE 5.3 und 9.4)

Im Deutschen sind zwei Stile üblich: Imperativ ("Starte den Dienst.") und Infinitiv ("Den Dienst starten."). Beide sind in Ordnung. Entscheide dich pro Dokument für einen und mische nicht.

Schlecht (Runbook): "1. Starte den Dienst neu. 2. Logdatei auf Fehler prüfen. 3. Danach solltest du das Ticket schließen."

Gut: "1. Starte den Dienst neu. 2. Prüfe die Logdatei auf Fehler. 3. Schließe das Ticket."

### Schreibe einen Befehl pro Satz (abgeleitet von STE 5.2)

Ein Schritt, eine Handlung. Zwei Handlungen in einem Satz sind nur erlaubt, wenn sie gleichzeitig stattfinden.

Schlecht (How-to): "Setze die Umgebungsvariable, starte den Server neu und leere den Cache."

Gut: "1. Setze die Umgebungsvariable DEBUG=1. 2. Starte den Server neu. 3. Leere den Cache."

Erlaubt (gleichzeitige Handlungen): "Halte die Reset-Taste gedrückt und stecke das Netzkabel ein."

### Stelle die Bedingung vor den Befehl (abgeleitet von STE 5.4)

Wer erst den Befehl liest und dann die Bedingung, hat den Befehl im Zweifel schon ausgeführt. Trenne die Bedingung mit einem Komma vom Befehl.

Schlecht (Runbook): "Setze das Deployment zurück, aber nur, falls der Health-Check nach fünf Minuten noch rot ist."

Gut: "Wenn der Health-Check nach fünf Minuten noch rot ist, setze das Deployment zurück."

### Nutze Hinweise nur für Information, nie für Anweisungen (abgeleitet von STE 5.5)

Ein "Hinweis:" erklärt Hintergrund. Leser überspringen Hinweise, wenn sie unter Zeitdruck arbeiten. Eine Handlung, die ausgeführt werden muss, gehört als nummerierter Schritt in die Anleitung.

Schlecht (Runbook): "Hinweis: Führe nach der Migration unbedingt ein Backup aus."

Gut: "4. Führe nach der Migration ein Backup aus: backup.sh --full. Hinweis: Die Migration schreibt nur in die neue Tabelle, die alte bleibt unverändert."

## 6. Beschreibender Text

Gilt für READMEs, Architektur-Doku und Kontextabschnitte in Tickets.

### Gib Information schrittweise (abgeleitet von STE 6.1)

Ein Satz, ein Gedanke. Baue jeden Satz auf dem vorherigen auf, statt alles in den ersten Satz zu packen.

Schlecht (README): "Der Importer, ein Cron-getriebener Kotlin-Service mit eigener Postgres-Instanz und Retry-Logik über eine Dead-Letter-Queue, synchronisiert Artikeldaten aus dem ERP."

Gut: "Der Importer synchronisiert Artikeldaten aus dem ERP. Er ist ein Kotlin-Service und läuft als Cronjob. Seine Daten liegen in einer eigenen Postgres-Instanz. Fehlgeschlagene Sätze landen in einer Dead-Letter-Queue und werden erneut verarbeitet."

### Behandle ein Thema pro Absatz (abgeleitet von STE 6.5)

Ein Absatz beantwortet eine Frage. Wechselt das Thema, beginne einen neuen Absatz.

Schlecht (Architektur-Doku): Ein Absatz beschreibt erst das Caching, springt dann zur Authentifizierung und endet mit Deployment-Details.

Gut: Drei Absätze mit je einem Thema: Caching, Authentifizierung, Deployment.

### Begrenze Absätze auf sechs Sätze (abgeleitet von STE 6.6)

Längere Absätze enthalten fast immer ein zweites Thema oder Füllmaterial. Teile sie oder kürze sie.

### Verzichte in Beschreibungen auf den Imperativ (abgeleitet von STE Abschnitt 6, Einleitung)

Beschreibender Text informiert, er weist nicht an. Anweisungen gehören in einen eigenen Anleitungsabschnitt.

Schlecht (Architektur-Doku): "Der Cache hält Sessions für 30 Minuten. Denke daran, ihn nach Schema-Änderungen zu leeren."

Gut (Doku): "Der Cache hält Sessions für 30 Minuten. Nach Schema-Änderungen ist er veraltet." Die Anweisung "Leere den Cache nach Schema-Änderungen" steht im Runbook.

## 7. Warnhinweise

Gilt für destruktive Kommandos, Breaking Changes und alles, was Datenverlust verursachen kann.

### Benenne die Risikostufe (abgeleitet von STE 7.1)

Kennzeichne das Risiko mit einem festen Wort. Bewährte Abstufung für IT-Texte: WARNUNG für irreversible Folgen (Datenverlust, gelöschte Ressourcen, Ausfall in Produktion), ACHTUNG für reversible Folgen (Neustart nötig, Cache weg, Downtime in Staging). Im Zweifel wähle die höhere Stufe.

Schlecht (Runbook): "Übrigens löscht der Befehl auch die Snapshots."

Gut: "WARNUNG: Der Befehl löscht auch alle Snapshots. Gelöschte Snapshots sind nicht wiederherstellbar."

### Beginne die Warnung mit Befehl oder Bedingung und erkläre die Folge (abgeleitet von STE 7.2 und 7.3)

Sage zuerst, was zu tun oder zu lassen ist. Erkläre danach, was sonst passiert. Wer die Folge kennt, nimmt die Warnung ernst.

Schlecht (README): "ACHTUNG: Vorsicht mit dem Reset-Endpunkt."

Gut: "WARNUNG: Rufe den Reset-Endpunkt nie gegen die Produktionsumgebung auf. Er löscht alle Benutzerkonten endgültig."

### Platziere die Warnung vor der Anweisung (abgeleitet von STE 7.2 und 5.4)

Eine Warnung nach dem Befehl kommt zu spät. Der Leser arbeitet Schritt für Schritt und hat den Befehl schon ausgeführt.

Schlecht (Runbook): "5. Führe terraform destroy aus. WARNUNG: Der Befehl löscht alle Ressourcen des Workspaces endgültig."

Gut: "WARNUNG: terraform destroy löscht alle Ressourcen des Workspaces endgültig. Prüfe zuerst mit terraform workspace show, dass du im Staging-Workspace bist. 5. Führe terraform destroy aus."

## 8. Zeichensetzung und Wortwahl

### Vermeide das Semikolon (abgeleitet von STE 8.1)

Das Semikolon lädt zu langen Sätzen ein und ist schwer korrekt zu setzen. Schreibe zwei Sätze.

Schlecht (Review-Kommentar): "Die Methode fängt die Exception; sie loggt sie aber nicht."

Gut: "Die Methode fängt die Exception. Sie loggt sie aber nicht."

### Gib "dies", "das" und "diese" immer ein Bezugswort (abgeleitet von STE GR-3 und GR-4)

Ein nacktes "das" kann sich auf den ganzen vorherigen Satz oder ein einzelnes Wort beziehen. Wiederhole das gemeinte Substantiv.

Schlecht (Jira-Ticket): "Der Worker liest den Status, bevor der Lock greift. Das führt zu doppelten Rechnungen."

Gut: "Der Worker liest den Status, bevor der Lock greift. Diese Race Condition führt zu doppelten Rechnungen."

### Setze Abkürzungen sparsam ein (abgeleitet von STE GR-6)

"z. B." und "d. h." sind im Deutschen üblich und in Ordnung. Häufe sie nicht, und vermeide "etc.": eine Aufzählung mit "zum Beispiel" zu öffnen ist klarer, als sie mit "etc." offen enden zu lassen.

Schlecht (README): "Der Client unterstützt div. Formate, z. B. JSON, YAML etc., d. h. i. d. R. reicht die Standardkonfiguration."

Gut: "Der Client unterstützt mehrere Formate, zum Beispiel JSON und YAML. In der Regel reicht die Standardkonfiguration."

### Achte auf falsche Freunde in DE/EN-Mischtexten (abgeleitet von STE GR-5)

Deutsche IT-Texte zitieren englische Begriffe und übersetzen englische Doku. Drei häufige Fallen:

"actual" heißt "tatsächlich" oder "Ist-", nicht "aktuell". Schlecht (Bug-Report-Vorlage): "Aktuelles Ergebnis: 500er-Fehler." Gut: "Tatsächliches Ergebnis: 500er-Fehler. Erwartetes Ergebnis: 200 OK."

"eventually" heißt "schließlich" oder "irgendwann", nicht "eventuell". Schlecht (Architektur-Doku): "Der Store ist eventuell konsistent." Gut: "Der Store ist schließlich konsistent (eventually consistent): Replikate konvergieren nach endlicher Zeit."

Deutsch "Konzept" meint oft einen Entwurf, englisch "concept" einen Begriff oder ein Prinzip. Schlecht (PR-Beschreibung): "Dieses Feature ist noch ein Concept." Gut: "Dieses Feature ist noch ein Entwurf."

### Schreibe inklusiv (abgeleitet von STE GR-7)

Formuliere geschlechtsneutral. Sprich die Lesenden direkt an oder verwende neutrale Rollen und Pluralformen. Halte dich an die Konvention des Projekts (etwa Doppelnennung oder neutrale Begriffe) und bleibe dabei im ganzen Dokument konsistent.

Schlecht (Onboarding-Doku): "Der Entwickler muss seinen API-Key vor dem ersten Deployment rotieren."

Gut: "Rotiere deinen API-Key vor dem ersten Deployment." Oder: "Alle im Team rotieren ihren API-Key vor dem ersten Deployment."

## 9. Konsistente Schreibpraxis

### Verwende für gleiche Aktionen die gleiche Formulierung (abgeleitet von STE 9.4)

Wiederkehrende Schritte sollen wiedererkennbar sein. Variation kostet den Leser bei jedem Schritt eine Prüfung, ob etwas anderes gemeint ist.

Schlecht (Runbook): "2. Starte den Worker neu. ... 6. Führe einen Neustart des Schedulers durch. ... 9. Recycle den Exporter."

Gut: "2. Starte den Worker neu. ... 6. Starte den Scheduler neu. ... 9. Starte den Exporter neu."

### Baue den Satz um, wenn eine Wortersetzung nicht reicht (abgeleitet von STE 9.1)

Ein vages Wort lässt sich selten eins zu eins durch ein präzises ersetzen. Frage, was der Satz sagen soll, und schreibe ihn neu.

Schlecht (Changelog): "Die Verfügbarkeit der Schnittstelle ist während des Updates gegebenenfalls eingeschränkt."

Gut: "Während des Updates antwortet die Schnittstelle bis zu 30 Sekunden nicht."

### Prüfe Sätze mit "mit" auf Mehrdeutigkeit (abgeleitet von STE GR-2)

"Mit" kann Werkzeug, Begleitung oder Eigenschaft bedeuten. Formuliere so, dass nur eine Lesart bleibt.

Schlecht (Ticket): "Ersetze den Service mit dem Feature-Flag." (Den Service, der das Flag auswertet? Oder mithilfe des Flags umschalten?)

Gut: "Schalte den neuen Service über das Feature-Flag frei." Oder: "Ersetze den Service, der das Feature-Flag auswertet."

### Halte den Stil im ganzen Dokument durch (abgeleitet von STE 9.4)

Anrede (du oder Sie), Anweisungsstil, Terminologie und Warnstufen sind Entscheidungen pro Dokument, nicht pro Absatz. Prüfe beim Überarbeiten, ob spätere Abschnitte von den Entscheidungen des Anfangs abweichen, und gleiche sie an.

Schlecht (How-to): Abschnitt 1 duzt im Imperativ, Abschnitt 3 siezt, Abschnitt 5 wechselt in den Infinitivstil.

Gut: Das ganze How-to duzt im Imperativ.
