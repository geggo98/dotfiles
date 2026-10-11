# Nachrichten an den User: absolute Pfade und wörtliche Zitate

Der User sieht nur den Text meiner Nachrichten. Er sieht weder meinen Kontext
noch gelesene Dateien, Tool-Ausgaben oder den Scratchpad.

## Scratchpad-Dateien: immer der absolute Pfad

Der User kennt den Pfad zum Scratchpad nicht. „Liegt im Scratchpad“, ein
relativer Pfad oder ein bloßer Dateiname sind für ihn nicht auffindbar.

Bezieht sich eine Nachricht auf eine Datei aus dem Scratchpad, steht darin ihr
**absoluter Pfad**. Das gilt für jede Erwähnung, auch in Zusammenfassungen und
Rückfragen.

## Relevante Stellen zitieren, nicht nur darauf verweisen

Der User kennt den Kontext nicht. Bezieht sich eine Aussage auf eine Codezeile,
eine Logzeile, eine Fehlermeldung, eine Regel oder einen Dateiabschnitt, gehört
die maßgebliche Stelle **wörtlich** in die Nachricht, mit `pfad:zeile`, wenn es
eine Datei ist.

- „Siehe oben“, „wie in der Datei“ oder „die Regel dazu“ ohne Zitat reichen nicht.
- Nur so viel zitieren, wie zum Verstehen nötig ist, nicht die ganze Datei.
- Geheimnisse und personenbezogene Daten Dritter auch im Zitat schwärzen
  (siehe `third-party-data.md`).
