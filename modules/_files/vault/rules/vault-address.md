# `vault -address=…` schickt den falschen Token, weil der Token-Helper das Flag nie sieht

Vault startet seinen externen Token-Helper mit einem unveränderten `os.Environ()`. Der
Helper sieht deshalb nur `VAULT_ADDR` — **niemals `-address`**. `modules/vault.nix`
benennt die Token-Dateien aber nach `sha256(VAULT_ADDR)`, damit Staging- und
Produktions-Login nebeneinander bestehen können statt sich in einer einzigen
`~/.vault-token` zu überschreiben.

Folge: In einer interaktiven fish steht `VAULT_ADDR` auf der Staging-Instanz. Ein
`vault … -address=<produktion>` redet damit zwar mit Produktion, **signiert die
Anfrage aber mit dem Staging-Token**. Das sieht nach einer fehlenden Berechtigung
aus, nicht nach falscher Konfiguration — und schickt einen ins Rechtesystem, wo
gar nichts kaputt ist.

Gemessen am 03.09.2026 mit Vault v1.21.1, gegen einen Host, der nicht auflöst —
also ohne jede Anfrage an eine echte Instanz:

```console
$ env -u VAULT_ADDR vault token lookup -address=https://vault.invalid:8200
failed to get token from token helper: "vault-token-helper: VAULT_ADDR is not set\n"
                                                                          # exit 2

$ env VAULT_ADDR=<staging> vault token lookup -address=https://vault.invalid:8200
Error looking up token: Get "https://vault.invalid:8200/…": no such host    # exit 2
```

Der erste Fall ist der Beweis, dass das Flag beim Helper nicht ankommt: er meldet
eine fehlende Adresse, obwohl eine auf der Kommandozeile steht.

Der zweite ist der gefährliche. Hier **hat** der Helper eine Adresse gesehen —
`VAULT_ADDR` — und den dazu gehörenden Token herausgegeben, während die Anfrage
woanders hinging. Beide Fälle enden auf **exit 2**: der Exit-Code trennt den
lauten Fall nicht vom stillen.

## Richtig

`+vault` statt `vault`. Der Wrapper löst die Umgebung auf und exportiert
`VAULT_ADDR` auf denselben Wert, bevor er das echte `vault` startet:

```bash
+vault status -address=p              # production — jedes eindeutige Praefix genuegt
+vault kv get -address=s secret/x     # staging
+vault status -address=https://…      # alles mit :// wird woertlich durchgereicht
+vault-login production               # OIDC-Login, ohne Default-Umgebung
```

`-address` wird an **jeder** Position erkannt und aus der Kommandozeile
entfernt, bevor `vault` sie sieht. `+vault kv get secret/x -address=p`
funktioniert deshalb, wo das echte `vault` mit „Command flags must be provided
before positional arguments" und „Too many arguments" abbricht.

Ein unbekannter oder mehrdeutiger Name bricht ab und nennt die Kandidaten. Einen
stillen Rückfall auf die Default-Umgebung gibt es bewusst nicht — er würde einen
Produktionsbefehl unbemerkt umleiten.

Das gilt für **Namen**. Für ein fehlendes Flag gilt es nicht: ohne `-address`
benutzt `+vault` das vorhandene `VAULT_ADDR` und sonst `staging`. Ein blankes
`vault` verhält sich dabei **nicht** gleich — ohne `VAULT_ADDR` scheitert es am
Token-Helper (`vault-token-helper: VAULT_ADDR is not set`, exit 1), statt auf
eine Default-Umgebung zu fallen. Gleich sind die beiden nur in einer interaktiven
fish, wo `VAULT_ADDR` ohnehin gesetzt ist — und ein Agent läuft nicht interaktiv.
Wer die Produktionsinstanz meint, muss sie nennen.

`+vault-login` verlangt die Umgebung als erstes Argument und hat keinen Default,
damit ein vergessenes Argument nicht in der falschen Instanz landet. Einen Token
nimmt es über stdin (`… | +vault-login staging -`) oder fragt ihn still ab; als
zweites Argument geht er weiterhin, steht dann aber im Prozesslisting und wird
mit einer Warnung quittiert.

## Die allgemeine Regel dahinter

**Ein Helfer-Prozess, den ein Werkzeug startet, sieht die Umgebung — nicht die
Flags des Aufrufers.** Ein Flag schaltet den Hauptprozess um, sonst nichts: jeder
Credential-Helper, jeder Hook und jedes `exec`te Unterprogramm arbeitet weiter mit
dem alten Wert. Das trifft `git`s Credential-Helper genauso wie Vaults
Token-Helper.

Prüfen statt annehmen: das Flag setzen, den Helfer etwas Beobachtbares tun lassen
und nachsehen, welchen Wert er benutzt hat. Dieselbe Denkart wie bei der Regel zu
`git diff` und difftastic — erst den Filter validieren, dann seinem Ergebnis
glauben.
