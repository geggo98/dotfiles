# Redaktionelle Mechanik für deutsche IT-Texte

Die übrigen Referenzen dieses Skills regeln, was du sagst und wie du es gliederst. Diese regelt
die Typografie darunter: Kommas, Bindestriche, Schrägstriche, Gedankenstriche,
Anführungszeichen, Überschriften, Listen- und Prozedurformatierung, Genus.

Das ist eine Adaption der englischen Fassung, keine Übersetzung. Der größte Teil der englischen
Mechanik lässt sich gar nicht übertragen: die deutsche Kommasetzung ist grammatisch statt
stilistisch, der Halbgeviertstrich steht mit Leerzeichen, wo der Em-Dash keine hat, ein Title
Case existiert nicht, und `a`/`an` hat kein Gegenstück. Die wertvollsten Regeln hier sind
genau die, wo das Deutsche das Gegenteil verlangt und die englische Gewohnheit in die Irre
führt.

## 1. Kommas

Das deutsche Komma folgt der Grammatik, nicht dem Sprechrhythmus. Wo das Englische wählt,
schreibt das Deutsche vor.

### Setze das Komma vor jedem Nebensatz

Vor `dass`, `weil`, `wenn`, `obwohl`, `damit`, `bevor`, `nachdem` und vor jedem Relativsatz
steht ein Komma. Das ist keine Stilfrage.

Schlecht: "Der Operator rollt zurück weil der Health-Check dreimal fehlschlägt."

Gut: "Der Operator rollt zurück, weil der Health-Check dreimal fehlschlägt."

Gut: "Der Job, der die Replikate einholt, läuft nachts."

### Setze kein Komma vor "und" oder "oder" in einer Aufzählung

Das ist die direkte Umkehrung des englischen Oxford-Kommas, und der häufigste Fehler in
Texten von jemandem, der viel Englisch schreibt.

Schlecht: "Der Exporter meldet Queue-Tiefe, Consumer-Lag, und Retry-Zähler."

Gut: "Der Exporter meldet Queue-Tiefe, Consumer-Lag und Retry-Zähler."

### Behandle "und" zwischen zwei Hauptsätzen als Hausregel

Seit 1996 ist das Komma zwischen zwei vollständigen Hauptsätzen, die mit `und` oder `oder`
verbunden sind, freigestellt. Setze es, wenn es die Gliederung sichtbar macht, und halte die
Entscheidung im ganzen Dokument durch.

Gut: "Die Migration lief durch, und die Replikate holten binnen einer Minute auf."

Gut: "Die Migration lief durch und ließ die Replikate zwei Minuten zurückfallen."
(Ein Subjekt, zwei Verben. Hier ist gar kein Komma möglich.)

### Setze das Komma beim erweiterten Infinitiv, wo es Pflicht ist

Nach `um`, `ohne`, `statt`, `anstatt`, `außer` und `als` ist das Komma obligatorisch. Ebenso,
wenn die Infinitivgruppe von einem Substantiv abhängt oder durch ein Korrelat wie `es` oder
`darauf` angekündigt wird.

Schlecht: "Der Operator wartet um die Replikate einzuholen."

Gut: "Der Operator wartet, um die Replikate einzuholen."

### Unterscheide den Vergleich mit Satz vom Vergleich ohne Satz

Vor `wie` und `als` steht nur dann ein Komma, wenn ein vollständiger Satz folgt.

Gut: "Der Build dauert länger als erwartet."

Gut: "Der Build dauert länger, als wir gemessen hatten."

### Trenne die Bedingung mit einem Komma vom Befehl

Das steht bereits in `simplified-technical-english.de.md` §5 und gilt hier unverändert:
Bedingung zuerst, dann Komma, dann Befehl.

## 2. Bindestrich und Durchkopplung

`simplified-technical-english.de.md` §2 fordert die Durchkopplung gemischter Komposita. Das
sind die weiteren Fälle.

### Koppele Zusammensetzungen mit Abkürzungen, Ziffern und Einzelbuchstaben

Schlecht: "API Schlüssel", "x86 Architektur", "5 Punkte Skala", "S Kurve"

Gut: "API-Schlüssel", "x86-Architektur", "5-Punkte-Skala", "S-Kurve"

### Nutze den Ergänzungsstrich statt zu wiederholen

Gut: "Ein- und Ausgabe", "Vor- und Nachteile", "Datei- und Verzeichnisrechte"

### Schreibe keine Leerzeichen in Komposita

Das Leerzeichen im Kompositum ist die aus dem Englischen übernommene Fehlform. Deutsch
zusammenschreiben oder durchkoppeln, aber nie trennen.

Schlecht: "Backup Strategie", "Deployment Pipeline", "Feature Flag Verwaltung"

Gut: "Backup-Strategie", "Deployment-Pipeline", "Feature-Flag-Verwaltung"

## 3. Schrägstrich

### Setze den Schrägstrich ohne Leerzeichen, solange die Teile einzelne Wörter sind

Nach DIN 5008 steht der Schrägstrich bei einzelnen Wörtern ohne Leerzeichen. Besteht
mindestens ein Teil aus mehreren Wörtern, stehen Leerzeichen darum.

Gut: "Ein-/Ausgabe", "Client/Server", "TCP/IP"

Gut: "Frankfurt am Main / Berlin"

### Nutze den Schrägstrich nicht als Ersatz für "oder"

Schlecht: "Setze die Aufbewahrung auf dem Bucket/Präfix."

Gut: "Setze die Aufbewahrung auf dem Bucket oder dem Präfix."

### Löse "er/sie" auf, statt es zu schreiben

`simplified-technical-english.de.md` §8 fordert geschlechtsneutrale Formulierung. Der
Schrägstrich ist dafür kein Werkzeug. Formuliere die Rolle neutral oder in den Plural.

Schlecht: "Frage den/die Reviewer/in, ob er/sie freigegeben hat."

Gut: "Frage im Review nach, ob die Änderung freigegeben ist."

## 4. Gedankenstrich

### Setze den Halbgeviertstrich mit Leerzeichen

Der deutsche Gedankenstrich ist der Halbgeviertstrich (–) und steht **mit** Leerzeichen. Das
ist genau umgekehrt zum englischen Em-Dash, der ohne Leerzeichen gesetzt wird. Der
Geviertstrich (—) ist im Deutschen unüblich.

Schlecht: "Der Job läuft nachts—meist gegen 3 Uhr—und dauert zwei Stunden."

Gut: "Der Job läuft nachts – meist gegen 3 Uhr – und dauert zwei Stunden."

### Setze den Bis-Strich ohne Leerzeichen

Gut: "10–20 Sekunden", "Montag–Freitag", "Seiten 12–18"

### Halte die Häufigkeitsgrenze ein

`anti-tropes-instruction.md` begrenzt Gedankenstriche auf zwei bis drei pro Text und verbietet
sie als Standardmittel für Einschübe. Das gilt hier unverändert. Bevorzuge Komma, Klammer oder
Doppelpunkt.

## 5. Anführungszeichen

### Entscheide nach dem Medium, nicht nach der Sprache

`„…“` ist die korrekte deutsche Typografie, und `anti-tropes-instruction.md` verbietet
typografische Anführungszeichen als KI-Merkmal. Beides stimmt. Die Grenze verläuft nicht
zwischen den Sprachen, sondern zwischen gesetztem und kopierbarem Text.

Gerade Anführungszeichen in allem, was jemand als Zeichen weiterverarbeitet: Markdown-Quellen,
Code, Bezeichner, Pfade, Commit-Nachrichten, Jira-Tickets, PR-Beschreibungen,
Review-Kommentare. Das sind die Medien, für die dieses Skill geschrieben ist, also ist das hier
der Normalfall. Die Referenzdateien dieses Skills halten sich selbst daran.

`„…“` nur dort, wo der Text als gesetztes Dokument beim Leser ankommt und niemand ihn wieder
herauskopiert: ein veröffentlichtes Handbuch, ein PDF, eine Kundenmitteilung.

Gut (PR-Beschreibung): Der Fehler lautet "connection refused" und nennt den Port nicht.

Gut (gesetztes Handbuch): Der Fehler lautet „Verbindung abgelehnt“ und nennt den Port nicht.

## 6. Überschriften

### Schreibe Überschriften nach normaler deutscher Rechtschreibung

Das Deutsche kennt kein Title Case. Groß geschrieben werden das erste Wort und die
Substantive, sonst nichts. Diese Regel steht hier nur, weil die englische Konvention
regelmäßig mitwandert.

Schlecht: "## Rollback Bei Fehlgeschlagener Migration"

Gut: "## Rollback bei fehlgeschlagener Migration"

Die Schreibweise von UI-Beschriftungen, Befehlen und API-Bezeichnern bleibt exakt so, wie das
Produkt sie schreibt. Wenn ein kleingeschriebener Bezeichner am Anfang wie ein Fehler aussieht,
stelle die Überschrift um.

Schlecht: "## Fdisk-Partitionierung"

Gut: "## Partitionieren mit fdisk"

## 7. Listen

### Löse drei oder mehr gleichrangige Elemente aus dem Fließtext heraus

`simplified-technical-english.de.md` §4 fordert vertikale Listen für komplexe Inhalte. Der
Auslöser ist die Zahl drei.

Schlecht: "Der Exporter meldet Queue-Tiefe, Consumer-Lag, Retry-Zähler und Dead-Letter-Größe
an Prometheus."

Gut:

    Der Exporter meldet vier Werte an Prometheus:

    - Queue-Tiefe
    - Consumer-Lag
    - Retry-Zähler
    - Dead-Letter-Größe

### Nummeriere Reihenfolgen, zähle Mengen auf

Nummerierte Liste, wenn der Leser die Punkte der Reihe nach abarbeiten muss.
Aufzählungszeichen, wenn keine Reihenfolge gilt. Das steht bereits in
`plain-language.de.md` und gilt hier unverändert.

### Halte einen Interpunktionsstil pro Liste durch

Entweder sind alle Punkte Ganzsätze und enden mit einem Punkt, oder alle sind Satzteile und
keiner endet mit einem Punkt. Für die Großschreibung gilt dasselbe. Nicht mischen.

Schlecht:

    - Stoppe den Writer.
    - tabelle leeren
    - Starte den Writer neu

Gut:

    - Stoppe den Writer.
    - Leere die Tabelle.
    - Starte den Writer neu.

### Fette den Begriff nur in echten Begriff/Definition-Listen

Wo eine Liste wirklich Begriffe erklärt, steht der Begriff fett und die Erklärung normal.
Das ist die enge Ausnahme, nicht die Standardform: `anti-tropes-instruction.md` verbietet es,
jeden Listenpunkt mit einer fetten Wendung zu beginnen, und `signs_of_AI_writing.md` führt die
Form Aufzählungszeichen-plus-fette-Überschrift-plus-Doppelpunkt als KI-Merkmal.

Bei Links steht der Link zuerst und die Beschreibung eingerückt darunter.

## 8. Prozeduren: Nummerierung und Schrittgrenzen

Diese Regeln erweitern `simplified-technical-english.de.md` §5, das den Inhalt eines Schritts
regelt, aber nicht seine Form.

### Setze einen einzelnen Schritt als Aufzählungspunkt

Eine "1." ohne "2." lässt den Leser nach dem Rest suchen.

Schlecht:

    Programm beenden
    1. Wähle Beenden im Menü Datei.

Gut:

    Programm beenden
    - Wähle Beenden im Menü Datei.

### Nummeriere Unterschritte mit Kleinbuchstaben, Unter-Unterschritte mit römischen Ziffern

Gut:

    1. Bereite den Knoten vor:
       a. Sperre den Knoten.
       b. Verschiebe die Workloads:
          i.  Räume die zustandslosen Pods.
          ii. Schwenke die StatefulSets um.
    2. Aktualisiere den Kernel.

### Lass die bestätigende Taste im selben Schritt

Auf zwei Schritte verteilt liest sich der Tastendruck als eigenständige Handlung und lädt zum
Innehalten ein.

Schlecht:

    1. Klicke in das Suchfeld und tippe den Funktionsnamen.
    2. Drücke die Eingabetaste.

Gut:

    1. Klicke in das Suchfeld, tippe den Funktionsnamen und drücke die Eingabetaste.

### Nenne den Zweck vor der Handlung

So kann jemand, dessen Zweck ein anderer ist, den Schritt überspringen, ohne ihn zu lesen. Das
ist das zweckförmige Gegenstück zur Bedingung-zuerst-Regel aus §5.

Schlecht: "Wähle Datei > Neu > Dokument, um ein neues Dokument zu erstellen."

Gut: "Um ein neues Dokument zu erstellen, wähle Datei > Neu > Dokument."

Gib jeder Prozedur eine Überschrift und formuliere benachbarte Prozeduren gleich
("Programm beenden", "Programm neu starten", "Programm deinstallieren"). Ein einleitender Satz
darf davorstehen, muss aber Kontext ergänzen statt die Überschrift zu wiederholen. Die
Entscheidung zwischen Imperativ und Infinitiv gilt pro Dokument, nicht pro Schritt (§5).

## 9. Genus englischer Fachbegriffe

`a`/`an` hat kein deutsches Gegenstück. Das gleichartige Problem im Deutschen ist das Genus
englischer Fachbegriffe: eine willkürliche Festlegung, die niemand aus der Sprache ableiten
kann, die aber einmal getroffen und dann gehalten werden muss.

Strittig sind unter anderem `der`/`das Commit`, `der`/`das Cache`, `das`/`der Log`,
`der`/`das Blog`, `die`/`das E-Mail`. Entscheide einmal, schreibe es ins Glossar und halte es
im ganzen Text durch. Das ist §1 (ein Begriff pro Konzept) auf das Genus angewandt.

Schlecht: "Das Commit ist gemergt. Der Commit fehlt aber im Release-Branch."

Gut: "Der Commit ist gemergt. Der Commit fehlt aber im Release-Branch."

Ein deutscher Sonderfall: `Daten` ist im Deutschen immer Plural ("Die Daten zeigen"). Der
Singular `das Datum` heißt in IT-Texten fast immer "Kalendertag" und ist damit ein falscher
Freund zum englischen `datum`. Schreibe "der Datensatz" oder "der Wert", wenn du ein einzelnes
Element meinst.

## 10. Abkürzungen

### Führe keine Abkürzung ein, die nur einmal vorkommt

`plain-language.de.md` fordert, Akronyme beim ersten Vorkommen aufzulösen. Das ergänzt den
Fall, den es nicht abdeckt: Kommt der Begriff im ganzen Text nur einmal vor, führe gar keine
Kurzform ein. Eine definierte und nie wieder verwendete Abkürzung kostet den Leser einen
Einschub und spart niemandem etwas.

Schlecht: "Der Scheduler nutzt Kernel Samepage Merging (KSM), um Speicher zu sparen."
(KSM kommt nie wieder vor.)

Gut: "Der Scheduler nutzt Kernel Samepage Merging, um Speicher zu sparen."

### Setze das Leerzeichen in "z. B." und "d. h."

`simplified-technical-english.de.md` §8 erlaubt diese Abkürzungen, verlangt aber Sparsamkeit.
Wenn sie stehen, dann mit Leerzeichen zwischen den Bestandteilen. Die zusammengeschriebene
Form ist schlicht falsch.

Schlecht: "z.B.", "d.h."

Gut: "z. B.", "d. h."

Typografisch korrekt wäre ein geschütztes Leerzeichen, damit der Zeilenumbruch die Abkürzung
nicht zerreißt. Dafür gilt dieselbe Grenze wie bei den Anführungszeichen (§5): in gesetztem
Text ja, in Markdown-Quellen, Tickets und Commit-Nachrichten nein. Dort ist U+00A0 unsichtbar,
überlebt Copy-and-paste nicht zuverlässig und irritiert Werkzeuge, die auf Leerzeichen
trennen. Das tragende Stück der Regel ist, dass überhaupt ein Leerzeichen steht.

## 11. Beispiele müssen korrekt und getestet sein

Jeder Befehl, jedes Konfigurationsfragment und jeder Codeblock muss in dem Zustand gelaufen
sein, den der Text beschreibt, und muss das ergeben haben, was der Text behauptet.

Lieber gar kein Beispiel als ein schlechtes. Ein ungetestetes Beispiel ist keine halbe Hilfe,
sondern ein ausgelieferter Defekt: der Leser vertraut ihm mehr als der Prosa daneben und sucht
dann den Fehler in deinem Beispiel statt in seinem Problem.

Lässt sich ein Beispiel nicht so ausführen, wie es dasteht, schreibe das in die Zeile darüber
und nenne, was fehlt.

## 12. Fremde Produktnamen

Schreibe fremde Produktnamen so, wie ihr Eigentümer sie schreibt. Die Groß- und
Kleinschreibung ist Teil des Namens, keine Stilentscheidung, und weder die Gewohnheit noch die
Autokorrektur ist die Autorität, sondern die Dokumentation des Produkts.

Schlecht: "VMWare", "CentOs", "openvz", "Postgresql", "NPM", "MacOS", "github"

Gut: "VMware", "CentOS", "OpenVZ", "PostgreSQL", "npm", "macOS", "GitHub"

Das erweitert §1, das Komponentennamen aus Code, API-Doku und Glossar übernimmt.

Ein Begriff pro Konzept bleibt (§1). Ergänze eine Bewegung darauf: Nenne gängige Alternativen
genau einmal beim ersten Vorkommen, damit auch jemand, der nach dem anderen Wort sucht, den
Text findet. Danach nutze durchgehend den gewählten Begriff.

Gut: "Ein USB-Stick (auch USB-Flash-Laufwerk) ist das empfohlene Installationsmedium.
Schreibe das Image auf den USB-Stick und starte davon."

## 13. Bewusst nicht übernommen

Diese Regeln stehen in anderen Hausstil-Leitfäden, insbesondere im Proxmox VE Technical Writing
Style Guide, aus dem ein großer Teil dieser Datei stammt. Sie sind hier als entschieden
festgehalten, nicht als übersehen, damit derselbe Vergleich sie nicht erneut als Lücke meldet.

**Das Semikolon zur Reparatur einer Komma-Verbindung.**
`simplified-technical-english.de.md` §8 rät vom Semikolon ab. Schreibe stattdessen zwei Sätze.

**Title Case in Überschriften der obersten Ebenen.** Im Deutschen existiert die Form nicht,
und `signs_of_AI_writing.md` führt sie ohnehin als KI-Merkmal. Siehe §6.

**Fette Listenanfänge als allgemeines Muster.** Nur für echte Begriff/Definition-Listen
zugelassen, siehe §7.

**Das Auslassen der Auflösung bekannter Akronyme.** Andere Leitfäden lassen USB, HTML, URL und
FAQ unaufgelöst stehen. `plain-language.de.md` knüpft die Auflösung daran, ob alle Leser das
Kürzel kennen, und diese Regel gilt weiter. §10 ergänzt nur den Fall, in dem der Begriff einmal
vorkommt und gar keine Kurzform braucht.

**Eine Tabelle von Übergangswörtern nach Funktion.** Fehlt in diesem Skill und fehlt
absichtlich. Die Hälfte der Einträge, die eine solche Tabelle trüge, steht in
`anti-tropes-instruction.md` und `signs_of_AI_writing.md` auf der Verbotsliste.
`simplified-technical-english.de.md` §4 deckt das Nötige ab: nutze einen Konnektor zwischen
zusammenhängenden Sätzen, und nimm einen schlichten.

**Kontraktionen.** Im Deutschen ist das kein Gegenstück zum englischen `it's`, sondern die
Verschmelzung von Präposition und Artikel. Die etablierten Formen (`zum`, `im`, `am`, `beim`,
`vom`, `zur`, `ins`) sind Standardsprache und in Ordnung. Die umgangssprachlichen (`fürs`,
`übers`, `durchs`, `aufs`) gehören nicht in Dokumentation.
