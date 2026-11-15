# Technische Dokumente: den Skill `technical-writing` laden

Wer ein technisches Dokument anlegt oder ändert, lädt zuerst den Skill `technical-writing`,
sofern der User nicht ausdrücklich etwas anderes sagt. Das gilt für jede Markdown-Datei
(`.md`) und jede AsciiDoc-Datei (`.adoc`, `.asciidoc`): READMEs, Doku, Regeln, Skills, ADRs,
Runbooks. Es gilt nicht für Dateien, die ein Werkzeug erzeugt (ein generiertes Changelog,
Lock-Dateien), und nicht für Code-Kommentare über das hinaus, was der Skill selbst abdeckt.

Herkunft: Wunsch des Users vom 15.11.2026. Vorher griff der Skill nur über seine
Beschreibung, und die wandten Agenten nicht bei jedem Markdown-Edit an. Begründung: Solche
Dateien lesen später Menschen und Agenten, die die Sitzung nicht kennen. Diese Regel lädt
jede Sitzung von Claude Code, Codex und opencode; eine Skill-Beschreibung wirkt nur, wenn
das Modell sich dafür entscheidet.

Jede Regel in einem solchen Dokument nennt Herkunft, Begründung und Grenzen, siehe den
Abschnitt „Writing Rules" im Skill. Die Quelle des Skills liegt im nix-darwin-Repository
unter `modules/ai/_files/skills/technical-writing/`, neben dieser Regel
(`modules/ai/_files/rules/`).
