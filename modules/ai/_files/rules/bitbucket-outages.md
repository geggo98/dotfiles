# Bitbucket-Ausfälle: erst wiederholen, dann debuggen

Bitbucket hat zurzeit immer wieder Ausfälle mit diversen Fehlern, zum Beispiel
HTTP 401. Kurz warten und nochmals probieren behebt das Problem oft.

Ein 401 dort ist also nicht automatisch ein Credential-Problem. Erst wiederholen,
bevor Token, Konfiguration oder Berechtigungen untersucht werden.
