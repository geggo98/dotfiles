# Modellwahl in Workflows: Fallback, wenn nichts anderes vorgegeben ist

Wer einen Workflow oder Subagenten startet, wählt das Modell nach der Rolle des Schritts.
Diese Regel ist der Fallback: Sie gilt nur, wenn weder der User noch ein Skill noch eine
andere Regel ein Modell nennt. Deren Vorgabe geht vor. Insbesondere bleibt der Abschnitt
„Which Model Writes" im Skill `technical-writing` in Kraft: Fable-Modelle schreiben keinen
Text, den Menschen lesen.

## Rollen und Modellklassen

| Rolle | Anthropic | OpenAI |
|---|---|---|
| Analyse und Hypothesen, nur nach Freigabe oder auf Anforderung | Fable | Astra |
| Planen; auch Ersatz für Fable ohne Freigabe | Opus | Sol: Effort `xhigh` als Ersatz für Analyse, `high` für Planung |
| Programmieren und Umsetzung, die Urteil verlangt, auch innerhalb einer Analyse | Sonnet | Terra |
| Mechanische Schritte mit klarer Vorgabe: suchen, umbenennen, formatieren, Daten extrahieren | Haiku | Luna |
| Eskalation, wenn Sonnet beziehungsweise Terra nachweislich scheitert; nur dieser Schritt | Opus | Sol, Effort `high` |

Effort ist die Stufe des Reasoning-Aufwands bei OpenAI-Modellen; `xhigh` heißt in der
OpenAI-Doku „extra high" und liegt eine Stufe über `high`.

**Fable und Astra nur mit Freigabe oder auf ausdrückliche Anforderung.** Eine Freigabe gilt
für genau einen Workflow oder einen Einsatz eines Subagenten. Beim nächsten Mal neu fragen;
eine einmal erteilte Freigabe gilt nicht weiter, wie bei der Regel `third-party-data.md`.
Ohne Freigabe übernimmt Opus beziehungsweise Sol mit Effort `xhigh` die Analyse.

**Haiku und Luna nur für mechanische Schritte.** Echtes Programmieren geht an Sonnet
beziehungsweise Terra.

**Eskalation:** Ein Schritt gilt als nachweislich gescheitert, wenn Tests oder Build nach zwei
Versuchen rot bleiben oder der Subagent selbst meldet, die Aufgabe sei zu groß. Nur dieser
Schritt wechselt auf Opus beziehungsweise Sol, der Rest des Workflows bleibt beim bisherigen
Modell.

## Design, Bilder und GIFs

Für den gestalterischen Entwurf in diesen Aufgaben gilt statt der Tabelle oben nur diese
Zuordnung, ohne weitere Modelle:

| Aufgabe | Modell |
|---|---|
| 2D-Design, insbesondere Webdesign | nur Fable, kein Astra; nur nach Freigabe oder auf Anforderung |
| 3D-Design, Bilder, GIFs | Astra nach Freigabe oder auf Anforderung, sonst Sol |

Freigabe und Anforderung gelten wie im Absatz „Fable und Astra nur mit Freigabe" oben: für
genau einen Workflow oder einen Einsatz eines Subagenten.

Ist das vorgesehene Modell nicht verfügbar, den User fragen. Das betrifft 2D-Design ohne
Freigabe, 2D-Design in einem Agenten ohne Anthropic-Modelle und 3D-Design, Bilder und GIFs in
einem Agenten ohne OpenAI-Modelle. Ein Ersatzmodell gibt es hier nicht.

Zwei Teile einer Design-Aufgabe folgen weiter den anderen Regeln:

- **Code, der einen fertigen Entwurf umsetzt** (HTML, CSS, JavaScript), geht nach der
  Tabelle oben an Sonnet beziehungsweise Terra.
- **Texte, die Menschen lesen**, auch UI-Texte, schreibt Opus oder ein Sol-Modell, nie Fable
  oder Astra (Skill `technical-writing`, Abschnitt „Which Model Writes").

Wie die Rollentabelle ist auch diese Zuordnung ein Fallback: Nennt der User oder ein Skill ein
Modell, gilt dessen Vorgabe.

## Umsetzung

In Claude Code bei jedem Aufruf des `Agent`-Tools und bei jedem `agent()` in einem
Workflow-Skript `model` ausdrücklich setzen. Ein Workflow-Skript ist ein Skript für das
Workflow-Tool von Claude Code; `agent()` startet darin einen Subagenten (Skill
`workflow-authoring`). Ein Subagent ohne `model` erbt das Modell der
Sitzung, laut Dokumentation von Claude Code. In Codex und opencode das Modell ebenso für jeden
Teillauf setzen.

Beispiel-IDs, Stand 17.11.2026; sie veralten, maßgeblich sind die Klassen:

- Anthropic, Aliase: `fable`, `opus`, `sonnet`, `haiku`
- OpenAI: `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-luna`

## Herkunft

Wunsch des Users vom 17.11.2026. Am selben Tag gegen die Empfehlungen der Hersteller geprüft:

- <https://www.anthropic.com/claude-haiku-5-5>: „A more intelligent model like Fable or Opus can
  plan the work and hand off subtasks to Haiku". Dieselbe Seite nennt Opus 5.5 „the daily
  driver" für komplexes Programmieren und Sonnet 5.5 passend für „well-scoped tasks". Daher
  der Eskalationsschritt.
- <https://code.claude.com/docs/en/sub-agents>: Subagenten erben das Modell der Sitzung, wenn
  `model` fehlt.
- <https://developers.openai.com/api/docs/models>: GPT-6 Astra ist das Spitzenmodell über Sol.
  Daher übernimmt Astra die Rolle von Fable.
- <https://developers.openai.com/api/docs/guides/model-selection>: Luna mit niedrigem Effort
  für klar umrissene Änderungen und Extraktion; Sol mit Effort „extra high" für Entscheidungen
  aus widersprüchlichen Belegen.

Der Abschnitt „Design, Bilder und GIFs" kam am 17.11.2026 auf Wunsch des Users hinzu. Er wurde
nicht gegen Herstellerangaben geprüft.

## Begründung

1. **Stärken.** Fable, Opus, Astra und Sol sind am stärksten bei offener Analyse und Planung.
   Bei klar umrissener Umsetzung liefern Sonnet, Haiku, Terra und Luna vergleichbare Ergebnisse.
2. **Kosten und Kontingent.** Fable und Astra kosten am meisten. Deshalb brauchen sie eine
   Freigabe.
3. **Geschwindigkeit.** Kleinere Modelle arbeiten parallele Umsetzungsschritte schneller ab.
4. **Design, Bilder und GIFs.** Der User hat die Zuordnung vorgegeben, ohne Begründung. Sie
   ist deshalb bei neuen Modellklassen als Erstes zu überprüfen.

## Grenzen

- Keiner der Hersteller schreibt eine feste Aufteilung in Planer und Ausführende vor. Beide
  empfehlen, das kleinste Modell zu nehmen, das in der Evaluation die Qualitätsschwelle
  erreicht. Diese Regel ist eine Voreinstellung, kein Gesetz.
- Die Regel gilt nicht für das Modell der laufenden Sitzung. Sie regelt nur, was ein
  gestarteter Workflow oder Subagent bekommt.

**Ablauf:** Die Regel ist zu überprüfen, sobald neue Modellklassen erscheinen oder die
Hersteller ihre Empfehlungen ändern.
