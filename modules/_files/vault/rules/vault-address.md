# `vault -address=…` schickt den falschen Token, weil der Token-Helper das Flag nie sieht

Vault startet seinen externen Token-Helper mit einem blanken `os.Environ()`. Der
Helper sieht deshalb nur `VAULT_ADDR` — **niemals `-address`**. `modules/vault.nix`
benennt die Token-Dateien aber nach `sha256(VAULT_ADDR)`, damit Staging- und
Produktions-Login nebeneinander bestehen können statt sich in einer einzigen
`~/.vault-token` zu überschreiben.

Folge: In einer interaktiven fish steht `VAULT_ADDR` auf der Staging-Instanz. Ein
`vault … -address=<produktion>` redet damit zwar mit Produktion, **signiert die
Anfrage aber mit dem Staging-Token**. Das sieht nach einer fehlenden Berechtigung
aus, nicht nach falscher Konfiguration — und schickt einen ins Rechtesystem, wo
gar nichts kaputt ist.

Gemessen am 03.09.2026 mit Vault v1.21.1:

```console
$ env -u VAULT_ADDR vault token lookup -address=https://vault.invalid:8200
failed to get token from token helper: "vault-token-helper: VAULT_ADDR is not set\n": exit status 1
```

Der Helper meldet hier eine fehlende Adresse, obwohl eine auf der Kommandozeile
steht. Genau das ist der Beweis: das Flag kommt bei ihm nicht an.

## Richtig

`+vault` statt `vault`. Der Wrapper löst die Umgebung auf und exportiert
`VAULT_ADDR` auf denselben Wert, bevor er das echte `vault` startet:

```bash
+vault status -address=p              # production — jedes eindeutige Praefix genuegt
+vault kv get -address=s secret/x     # staging
+vault status -address=https://…      # alles mit :// wird woertlich durchgereicht
+vault-login production               # OIDC-Login, ohne Default-Umgebung
```

Ein unbekannter oder mehrdeutiger Name bricht ab und nennt die Kandidaten. Einen
stillen Rückfall auf die Default-Umgebung gibt es bewusst nicht — er würde einen
Produktionsbefehl unbemerkt umleiten.

`+vault-login` verlangt die Umgebung als erstes Argument und hat keinen Default,
damit ein vergessenes Argument nicht in der falschen Instanz landet.

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
