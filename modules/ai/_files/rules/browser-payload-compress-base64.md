# Browser-Datenaustausch: gzip, dann base64 — brotli und zstd gibt es dort nicht

Nutzdaten zum und vom Browser — agent-browser, die Chrome-Integration,
`javascript_tool`, jedes `evaluate` in der Seite — **erst mit gzip komprimieren,
dann base64 kodieren**. Nicht umgekehrt und nicht roh.

**gzip, nicht zstd und nicht brotli.** Die Seite komprimiert mit
`CompressionStream`, und die kennt nur drei Verfahren. Gemessen am 09.09.2026 in
Chrome 152:

```
new CompressionStream("gzip")         -> ok        (ebenso DecompressionStream)
new CompressionStream("deflate")      -> ok
new CompressionStream("deflate-raw")  -> ok
new CompressionStream("brotli")       -> TypeError: Failed to construct
      'CompressionStream': Unsupported compression format: 'brotli'
new CompressionStream("zstd")         -> TypeError: … 'zstd'
```

Das gilt für beide Richtungen — `DecompressionStream` wirft dieselben Fehler.
Dass auf dieser Maschine `zstd` und `brotli` als CLI liegen, hilft nicht: das
Gegenstück in der Seite fehlt, und ein Verfahren, das nur eine Seite beherrscht,
ist keins.

**Nicht mit der HTTP-Tabelle verwechseln.** `Content-Encoding` kann in Chrome
längst `br` (seit 50) und `zstd` (seit 123) — das ist der *Header*, den der
Browser beim Laden aushandelt, nicht die API, die einem Skript zur Verfügung
steht. MDN führt bei `CompressionStream` außerdem `brotli` und `zstd` auf; in
Chrome 152 sind beide nicht implementiert. Deshalb gilt die Messung, nicht die
Tabelle.

## Warum überhaupt der Umweg

Drei Gründe, der zweite ist der wichtigste:

1. **Kodierung.** Der Weg führt durch JSON, durch eine Shell-Kommandozeile und
   durch ein Terminal. Zeilenumbrüche, Anführungszeichen, NUL- und
   Steuerzeichen, einsame Surrogate aus dem DOM überstehen das nicht
   zuverlässig. base64 ist reines ASCII und übersteht jede dieser Stufen.
2. **Eine Kappung wird laut statt still.** Tool-Ergebnisse werden gekappt. gzip
   trägt Prüfsumme und Rahmenende, ein abgeschnittener Blob **scheitert beim
   Dekomprimieren**. Gemessen an einem um 20 % gekürzten Blob: der
   `DecompressionStream` bricht ab, während derselbe Text roh gekappt wortlos
   durchläuft und danach aussieht wie ein vollständiges Ergebnis — dieselbe
   Fehlerklasse wie bei der Regel zu `git diff` und difftastic, wo ein Filter
   „keine Treffer" meldet, statt zu scheitern. Das gilt für den **Transport** —
   gegen eine Kappung *vor* der Kompression hilft es nicht, siehe unten.
3. **Größe.** Siehe unten.

**base64 allein macht es schlimmer**: es bläht um 4/3 auf. Erst die Kompression
davor macht den Umweg zum Gewinn. Zweimal gemessen, am 09.09.2026:

| | roh | nur base64 | gzip, dann base64 |
|---|---|---|---|
| CLI, 136 730 Byte Markdown | 1,00 | **1,33** | 0,54 (`gzip -9`) |
| Seite, `document.body.innerText` | 1,00 | **1,33** | 0,54 (`CompressionStream`) |

Beide Seiten kommen auf dieselben Faktoren. `deflate-raw` lag mit 0,540 gegen
0,543 marginal vorn, weil der gzip-Rahmen rund 18 Byte kostet — das ist kein
Grund, das Format zu wechseln.

## In der Seite

Verlustfreiheit und Faktor oben stammen aus diesem Round-Trip:

```js
async function gzipB64(text) {
  const cs = new CompressionStream("gzip");
  const w = cs.writable.getWriter();
  w.write(new TextEncoder().encode(text)); w.close();
  const comp = new Uint8Array(await new Response(cs.readable).arrayBuffer());
  let s = ""; const CH = 0x8000;                       // NICHT String.fromCharCode(...comp)
  for (let i = 0; i < comp.length; i += CH) s += String.fromCharCode.apply(null, comp.subarray(i, i + CH));
  return btoa(s);
}
```

**Die Schleife ist Pflicht, kein Stil.** `String.fromCharCode(...u8)` breitet
jedes Byte zu einem Argument aus und sprengt den Argumentstack. Gemessen mit
inkompressiblen Bytes:

| Eingabe | `fromCharCode(...u8)` | Schleife à 32 KiB |
|---|---|---|
| 64 KiB | ok | ok |
| 128 KiB | **RangeError** | ok |
| 1 MiB | **RangeError** | ok |

Die Grenze liegt zwischen 64 und 128 KiB — also genau dort, wo ein
Seiten-Payload anfängt, interessant zu werden. Der Fehler kommt beim Kodieren,
lange nachdem die Kompression schon funktioniert hat.

## Länge und Prüfsumme mitschicken — und zwar VOR den Daten

Ja, und es lohnt sich. Was gzip selbst schon leistet und was nicht, ist am
09.09.2026 in Chrome 152 gemessen worden.

**Für den Transport braucht es nichts weiter.** gzip trägt CRC32 und die
unkomprimierte Länge im Trailer, und jede Kappung der Leitung schlug laut fehl —
bei 50 %, 90 %, 99 % und 99,9 % Restlänge, an der jeweils ersten Stufe, die sie
sehen konnte:

| gekappt bei | mit Umschlag | nackter base64-String |
|---|---|---|
| 50 … 99,9 % | `JSON.parse: SyntaxError` | `gunzip: TypeError` |
| 100 % | OK | OK |

**Die Kappung, die gzip nicht sehen kann, ist die vor der Kompression.**
Gemessen an einem auf 80 % gekürzten `innerText`:

```
Original 7452 Zeichen, komprimiert wurden 5961
gzip meldet keinen Fehler        ISIZE == 5961, also die gekappte Länge
Round-Trip verlustfrei
```

gzip bestätigt exakt das, was es bekommen hat. Die fehlenden 20 % sind
unsichtbar — und genau so sieht es aus, wenn die Seite noch nicht fertig geladen
war, ein `innerText` an einer Grenze abbrach oder der Aufrufer selbst gekürzt
hat. **Deshalb Länge und Prüfsumme an der Quelle nehmen, nicht aus dem
gzip-Rahmen ableiten.**

Der Umschlag, Metadaten zuerst:

```json
{"v":1,"alg":"gzip","rawBytes":22371,"sha256":"…","b64Bytes":4272,"data":"H4sIA…"}
```

**Die Reihenfolge ist kein Stil.** Eine Kappung schneidet hinten ab, also
verschwindet eine Prüfsumme am Ende genau dann, wenn sie gebraucht wird. Gemessen
mit einem nachsichtigen Empfänger — einem, der das Fragment per Regex liest statt
mit `JSON.parse`, also so, wie ein Agent eine gekappte Tool-Ausgabe liest, bei
60 % Restlänge:

| | Ergebnis |
|---|---|
| `data` zuletzt | „erkannt: 2376 von 4000 Zeichen" |
| `data` zuerst | „kein `b64Bytes` im Fragment — Kappung nicht feststellbar" |

Kosten, gemessen: SHA-256 über 22 KB dauert **0,2 ms**, der Kopf wiegt **139
Byte**. Bei diesem Payload sind das 3,2 %, bei größeren weniger. Wer die
Prüfsumme sparen will, nimmt wenigstens `rawBytes` und `b64Bytes` — die
Längenprüfung allein fängt jede Kappung, nur keine Verfälschung.

Empfänger prüfen billig vor teuer und brechen bei der ersten Abweichung ab:

```js
const env = JSON.parse(wire);                       // 1. Rahmen vollstaendig?
if (env.data.length !== env.b64Bytes) throw new Error(
  `gekappt: ${env.data.length} von ${env.b64Bytes} Zeichen`);   // 2. billig, und nennt den Fehlbetrag
const bytes = unb64(env.data);                      // 3. atob
const text  = await gunzip(bytes);                  // 4. CRC32 des gzip-Rahmens
if (await sha256hex(text) !== env.sha256) throw new Error("Inhalt weicht ab");  // 5. Ende zu Ende
```

Nur Schritt 5 deckt die Kappung vor der Kompression ab, und auch nur dann, wenn
`sha256` an der Quelle über den Text gebildet wurde, den die Quelle für
vollständig hält.

Zwei Einschränkungen, beide geprüft: `crypto.subtle` gibt es **nur im secure
context** — auf `http://` oder `file://` fehlt es, dann bleibt die Längenprüfung.
Und `crypto.subtle.digest` ist asynchron, der Aufrufer muss also `await` können.

## base64 auf der CLI hat eine BSD/GNU-Falle

`base64` bricht die Ausgabe um oder nicht, je nachdem, welches zuerst im PATH
liegt. Gemessen an 300 Byte Eingabe:

| Aufruf | Zeilen |
|---|---|
| GNU coreutils `base64` | **6** — Umbruch bei 76 Zeichen |
| `/usr/bin/base64` (BSD) | 1 |

`-w0` schaltet den Umbruch bei GNU ab und ist bei BSD ein Fehler
(`base64: invalid argument`). Wer sich nicht auf die PATH-Reihenfolge verlassen
will, nimmt perl — es liegt im macOS-Basissystem und verhält sich überall
gleich:

```bash
perl -MMIME::Base64 -0777 -ne 'print encode_base64($_, "")'   # ohne Umbruch
perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)'
gzip -9 -c < datei | perl -MMIME::Base64 -0777 -ne 'print encode_base64($_, "")'
```

Das ist derselbe Grund, aus dem die Regel zum Skriptstil perl vorzieht.

## Wenn kein Browser beteiligt ist

Dann fällt die Beschränkung weg und `zstd` oder `brotli` sind die besseren
Verfahren — für JSON deutlich: brotli auf Stufe 11 lag über fünf gemessene
Payloads (7 KB bis 15,7 MB) durchweg 6 bis 16 % unter `zstd -19`. Diese Regel
handelt aber vom Browser, und dort ist die Auswahl von der Gegenseite bestimmt.
