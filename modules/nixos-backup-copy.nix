# Second copy of the restic backup: R2 -> Dropbox, driven from the VPS.
#
# WHY THIS RUNS HERE AND NOT ON A WORKSTATION. The copy moves ~1 TB. Both homes
# sit behind consumer lines that are force-disconnected nightly (see
# infra/machines/p-own-lengenwang-c5esve.md) and whose upstream is a fraction of
# the downstream. This VPS is in a data centre with, measured on 2026-08-21 from
# the box itself:
#
#   R2 -> VPS   37.0 MB/s  (319 MB in 8.6 s, against our own nix-cache on R2)
#   VPS -> CF   91.2 MB/s  (100 MB in 1.1 s)
#
# so the transfer is bounded by Dropbox's API rather than by a domestic uplink,
# and IONOS states "Unbegrenzt Traffic bis zu 1 Gbit/s" with no fair-use clause
# on the product page. R2 egress is free in both storage classes.
#
# WHY rclone AND NOT `restic copy --from-repo`. `restic copy` decrypts the
# source and re-encrypts into the destination, so it needs the repository
# password -- the single secret that unlocks every backup we have -- on the one
# machine here that faces the open internet. rclone copies the already-encrypted
# objects verbatim and never learns what is inside them. This host therefore
# holds only a READ-ONLY R2 credential and a Dropbox token: an attacker who
# takes the VPS gets ciphertext and no way to delete the original.
#
# What that trades away: the copy is byte-identical, so damage in the source
# would be copied too, whereas `restic copy` would rebuild fresh packs. The
# answer is sequencing, not tooling -- prove the source intact BEFORE copying.
#
# And that proof does not need the password either. restic names every pack file
# after the SHA-256 of its contents, so the filename verifies itself: download,
# hash, compare. Measured against a 16 MiB pack on 2026-08-26 -- filename and
# computed digest identical. `verify-then-copy` does exactly that and only
# copies if it comes out clean:
#
#   systemctl start backup-verify-then-copy@<prefix>
#
# That splits the work by what it costs rather than by what it proves. The
# expensive half -- reading ~840 GiB -- runs here, on the fast line. The half
# that still needs the password is `restic check` WITHOUT --read-data: it reads
# only index and snapshots, so it confirms that nothing is missing and that the
# metadata matches, and it finishes in minutes even over a bad connection.
# Together they are the same guarantee `restic check --read-data` gives, minus
# the requirement to hold a terabyte-sized download on a laptop.
#
# COST, because the deadline is easy to miss. modules/../infra/src/backup.ts
# demotes `<prefix>/data/` to Infrequent Access 30 days after upload, and IA
# charges $0.01/GB to read. Copying ~1 TB while it is still Standard costs about
# $0.02 in Class B operations; the same copy after the transition costs ~$10.30.
# Phase-1 objects were written 2026-08-19, so they turn cold on 2026-09-18.
{ ... }:
{
  flake.modules.nixos.backup-copy = { pkgs, ... }:
    let
      # Not a secret: it is the hostname of the public S3 endpoint both Macs and
      # this host already use as a substituter. Stated as such in
      # infra/src/account.ts, which is the authority -- keep the two in step.
      accountId = "81e63dbf073ca45ebf67c430beac09a4";
      bucketName = "restic-backup";

      # Destination root inside the Dropbox app folder. With an App-folder
      # scoped Dropbox app (the kind to create -- see the runbook below) this is
      # relative to that folder, so rclone cannot reach the rest of the account.
      dropboxRoot = "restic-backup";

      copyScript = pkgs.writeShellApplication {
        name = "backup-copy-to-dropbox";
        runtimeInputs = with pkgs; [ rclone coreutils ];
        text = ''
          # usage: backup-copy-to-dropbox <repository-prefix> [copy|check]
          prefix="''${1:?Repository-Prefix fehlt, z. B. p-own-lengenwang-c5esve}"
          mode="''${2:-copy}"

          # systemd hands us a private tmpfs via RuntimeDirectory=. Outside
          # systemd (a manual test run) fall back to a mktemp dir, so the script
          # never silently writes credentials somewhere durable.
          workdir="''${RUNTIME_DIRECTORY:-$(mktemp -d)}"
          conf="$workdir/rclone.conf"

          # rclone REWRITES its config when it refreshes the Dropbox OAuth
          # token, so this file cannot live in /run/secrets (read-only) or in
          # the store. tmpfs also means the plaintext never touches the disk.
          # Ein in der Dropbox-App-Konsole per Knopfdruck erzeugtes Token ist
          # KURZLEBIG: es laeuft nach ~4 Stunden ab und bringt keinen
          # refresh_token mit. Dieser Transfer dauert 12-24 Stunden, stuerbe also
          # mittendrin mit 401 invalid_access_token -- nach Stunden Arbeit, an
          # einer Stelle, die nach einem Netzproblem aussieht.
          #
          # `rclone authorize dropbox <id> <secret>` fuehrt den Flow mit
          # token_access_type=offline und liefert einen refresh_token, den rclone
          # selbsttaetig einloest. Das hier prueft genau diesen Unterschied,
          # bevor irgendetwas uebertragen wird.
          token_file=/run/secrets/dropbox_token
          if ! grep -q refresh_token "$token_file"; then
            echo "ABBRUCH: dropbox_token enthaelt keinen refresh_token." >&2
            echo "" >&2
            echo "Vermutlich stammt es aus dem Knopf 'Generated access token' in" >&2
            echo "der App-Konsole. Solche Token verfallen nach ~4 Stunden und" >&2
            echo "koennen nicht erneuert werden -- dieser Lauf wuerde mitten in" >&2
            echo "der Uebertragung abbrechen." >&2
            echo "" >&2
            echo "Stattdessen auf einer Maschine mit Browser:" >&2
            echo "  rclone authorize dropbox <client_id> <client_secret>" >&2
            echo "und das VOLLSTAENDIGE ausgegebene JSON hinterlegen." >&2
            exit 2
          fi

          install -m 0600 /dev/null "$conf"
          {
            printf '[r2]\n'
            printf 'type = s3\n'
            printf 'provider = Cloudflare\n'
            printf 'region = auto\n'
            printf 'endpoint = https://%s.r2.cloudflarestorage.com\n' ${accountId}
            printf 'access_key_id = %s\n' "$(cat /run/secrets/r2_backup_ro_access_key_id)"
            printf 'secret_access_key = %s\n' "$(cat /run/secrets/r2_backup_ro_secret_access_key)"
            printf '\n'
            printf '[dropbox]\n'
            printf 'type = dropbox\n'
            printf 'client_id = %s\n' "$(cat /run/secrets/dropbox_client_id)"
            printf 'client_secret = %s\n' "$(cat /run/secrets/dropbox_client_secret)"
            printf 'token = %s\n' "$(cat /run/secrets/dropbox_token)"
          } >"$conf"
          export RCLONE_CONFIG="$conf"

          src="r2:${bucketName}/$prefix"
          dst="dropbox:${dropboxRoot}/$prefix"

          # --fast-list turns the S3 listing into paged bulk requests instead of
          # one per directory. On ~62 000 objects that is the difference between
          # a few dozen Class A operations and thousands.
          #
          # --tpslimit is about Dropbox, not R2: it rate-limits aggressively and
          # answers 429 with a Retry-After of 15-300 s. Staying under the limit
          # is far cheaper than being throttled out of it.
          #
          # No --checksum: S3 ETags and Dropbox content hashes are different
          # functions, so there is nothing to compare. Size plus modtime is what
          # rclone can actually verify here; the cryptographic proof is `restic
          # check` against the destination, run from a workstation afterwards.
          common=(
            --config "$conf"
            --fast-list
            --transfers 8
            --checkers 8
            --tpslimit 12
            --retries 10
            --low-level-retries 20
            --stats 5m
            --stats-one-line
            --log-level INFO
          )

          case "$mode" in
            copy)
              echo "Kopiere $src -> $dst"
              # `copy`, never `sync`: sync would DELETE anything in the
              # destination that is absent from the source. If the source is
              # ever damaged or truncated, that is precisely the moment the
              # second copy must not follow along.
              rclone copy "''${common[@]}" "$src" "$dst"
              ;;
            check)
              echo "Vergleiche $src <-> $dst (Groesse, nicht Inhalt)"
              rclone check "''${common[@]}" --size-only "$src" "$dst"
              ;;
            verify-packs)
              # Vollstaendige Integritaetspruefung OHNE das Repository-Passwort.
              #
              # restic benennt jede Pack-Datei nach dem SHA-256 ihres Inhalts.
              # Gemessen am 2026-08-26 an einem 16-MiB-Pack: Dateiname und
              # berechneter Hash waren identisch. Also laesst sich hier pruefen,
              # was sonst `restic check --read-data` prueft -- naemlich dass
              # jedes Pack bitgenau das ist, was restic geschrieben hat --, und
              # zwar auf der Maschine mit der schnellen Leitung statt auf einem
              # Notebook, und ohne ihr das Passwort zu geben.
              #
              # Was das NICHT abdeckt: ob Index und Snapshots zu den Packs
              # passen und nichts fehlt. Das prueft `restic check` OHNE
              # --read-data, was nur Metadaten liest und deshalb auch ueber eine
              # duenne Leitung in Minuten durchlaeuft. Die teure Haelfte hier,
              # die billige dort.
              #
              # --download ist zwingend: R2 liefert ETags, keinen SHA-256, also
              # muss rclone die Objekte tatsaechlich lesen.
              # Erst zaehlen, wie viele Packs es GIBT. Ohne diese Zahl ist die
              # Pruefung wertlos: bricht rclone nach der Haelfte ab, meldet der
              # Auswerter "alle korrekt" -- ueber die Haelfte. Eine Pruefung, die
              # bei stiller Teilabdeckung "sauber" sagt, ist schlimmer als keine.
              echo "Zaehle Packs unter $src/data ..."
              expected=$(rclone lsf -R --files-only "''${common[@]}" "$src/data" | wc -l)
              echo "  $expected Packs erwartet"

              # Die Hash-Liste erst vollstaendig holen, dann auswerten. Getrennt
              # statt als Pipe, damit rclones Exit-Code eindeutig geprueft werden
              # kann; in einer Pipe verdeckt der Auswerter ihn.
              echo "Lese und hashe alle Packs (das ist der teure Teil) ..."
              if ! rclone hashsum sha256 --download "''${common[@]}" \
                "$src/data" >"$workdir/hashes.txt"; then
                echo "ABBRUCH: rclone konnte nicht alle Packs lesen." >&2
                echo "Die Pruefung ist damit unvollstaendig und sagt NICHTS aus." >&2
                exit 2
              fi

              perl -sne '
                BEGIN { $ok = 0; $bad = 0 }
                # rclone-Zeile: "<64 hex>  00/00b52872a0d8…e659"
                if (m{^(?<hash>[0-9a-f]{64})\s+(?<path>\S+)$}) {
                  my ($h, $p) = ($+{hash}, $+{path});
                  (my $name = $p) =~ s{.*/}{};
                  if ($name eq $h) { $ok++ }
                  else { $bad++; print "BESCHAEDIGT: $p (berechnet: $h)\n" }
                }
                END {
                  my $seen = $ok + $bad;
                  printf "\n%d von %d Packs geprueft: %d korrekt, %d beschaedigt.\n",
                    $seen, $expected, $ok, $bad;
                  if ($seen != $expected) {
                    printf "UNVOLLSTAENDIG: %d Packs fehlen in der Hash-Liste.\n",
                      $expected - $seen;
                    exit 2;
                  }
                  print $bad ? "NICHT sauber -- vor dem Kopieren klaeren.\n"
                             : "Alle Packs sind bitgenau unversehrt.\n";
                  exit($bad ? 1 : 0);
                }
              ' -- -expected="$expected" <"$workdir/hashes.txt"
              ;;
            verify-then-copy)
              # Beides in einem Lauf, in DIESER Reihenfolge. Eine 1:1-Kopie
              # kopiert Schaeden mit, also muss die Quelle vorher als heil
              # erwiesen sein -- sonst entstehen zwei gleich kaputte Kopien und
              # der zweite Speicherort taeuscht Sicherheit vor.
              echo "### 1/2  Integritaet der Quelle"
              "$0" "$prefix" verify-packs || {
                echo "ABBRUCH: Quelle nicht sauber, es wird nichts kopiert." >&2
                exit 1
              }
              echo
              echo "### 2/2  Kopie nach Dropbox"
              exec "$0" "$prefix" copy
              ;;
            verify-credentials)
              # Beweist die Eigenschaft, auf der das ganze Sicherheitsargument
              # dieses Moduls ruht: dass die R2-Zugangsdaten hier NICHT schreiben
              # koennen. Ein als read-only gemeinter Token, der doch schreiben
              # darf, sieht im Normalbetrieb genauso aus -- der Unterschied faellt
              # erst auf, wenn ihn jemand missbraucht.
              rc=0

              echo "1) Lesen (muss klappen)"
              if rclone lsd "''${common[@]}" "r2:${bucketName}" >/dev/null; then
                echo "   OK -- Bucket ist lesbar."
              else
                echo "   FEHLER -- kein Lesezugriff. Token, Bucket-Scope oder" >&2
                echo "   IP-Bedingung pruefen." >&2
                rc=1
              fi

              echo "2) Schreiben (muss FEHLSCHLAGEN)"
              # Ausserhalb jedes restic-Prefix, damit ein unerwartet gelungener
              # Schreibvorgang nichts beruehrt, was restic verwaltet.
              probe="r2:${bucketName}/_permission-probe/ro-check.txt"
              if echo probe | rclone rcat "''${common[@]}" "$probe" 2>/dev/null; then
                echo "   KRITISCH -- der Schreibvorgang war ERFOLGREICH." >&2
                echo "   Dieser Token ist NICHT read-only. Ersetzen, und zwar" >&2
                echo "   bevor er benutzt wird; er kann das Backup zerstoeren." >&2
                echo "   Zurueckgeblieben: $probe (nur mit dem rw-Token loeschbar)" >&2
                rc=1
              else
                echo "   OK -- Schreiben wurde abgelehnt, wie es sein soll."
              fi

              exit "$rc"
              ;;
            *)
              echo "Unbekannter Modus: $mode (erlaubt: copy, check, verify-packs, verify-then-copy, verify-credentials)" >&2
              exit 2
              ;;
          esac
        '';
      };
    in
    {
      environment.systemPackages = [ pkgs.rclone copyScript ];

      # A template unit so a second machine's repository needs no new Nix:
      #   systemctl start backup-copy-to-dropbox@p-own-lengenwang-c5esve
      #   systemctl start backup-copy-check@p-own-lengenwang-c5esve
      #
      # Deliberately no timer and no wantedBy. This is a migration step someone
      # decides to take, not a recurring job -- and it reads a repository that is
      # being written to while the first backup is still running, which would
      # produce an inconsistent copy.
      systemd.services."backup-copy-to-dropbox@" = {
        description = "Copy restic repository %i from R2 to Dropbox";
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "backup-copy";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${copyScript}/bin/backup-copy-to-dropbox %i copy";

          # ~1 TB over a rate-limited API. systemd's default would not stop it,
          # but being explicit avoids a future default surprising us.
          TimeoutStartSec = "infinity";

          # It reads secrets and talks to two APIs; it has no business anywhere
          # else on the filesystem.
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      # Run this FIRST, before trusting the credentials with anything:
      #   systemctl start backup-copy-verify-credentials
      # It proves the R2 token can read and cannot write. The argument is a
      # dummy — the probe is repository-independent.
      systemd.services.backup-copy-verify-credentials = {
        description = "Prove the R2 credential can read and cannot write";
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "backup-copy";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${copyScript}/bin/backup-copy-to-dropbox unused verify-credentials";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      # Der Weg, den man normalerweise will: Integritaet der Quelle beweisen,
      # dann kopieren — in dieser Reihenfolge, weil eine 1:1-Kopie Schaeden
      # mitkopiert.
      #
      #   systemctl start backup-verify-then-copy@p-own-lengenwang-c5esve
      #
      # Braucht KEIN Repository-Passwort: restic benennt Packs nach dem SHA-256
      # ihres Inhalts, also prueft der Dateiname sich selbst. Was hier nicht
      # geprueft wird — ob Index und Snapshots zu den Packs passen — kostet
      # `restic check` ohne --read-data nur Metadaten und laeuft auch ueber eine
      # schlechte Leitung in Minuten.
      systemd.services."backup-verify-then-copy@" = {
        description = "Verify pack integrity of %i, then copy it to Dropbox";
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "backup-copy";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${copyScript}/bin/backup-copy-to-dropbox %i verify-then-copy";
          TimeoutStartSec = "infinity";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      systemd.services."backup-verify-packs@" = {
        description = "Verify every pack of %i against its SHA-256 filename";
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "backup-copy";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${copyScript}/bin/backup-copy-to-dropbox %i verify-packs";
          TimeoutStartSec = "infinity";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      systemd.services."backup-copy-check@" = {
        description = "Compare restic repository %i between R2 and Dropbox";
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "backup-copy";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${copyScript}/bin/backup-copy-to-dropbox %i check";
          TimeoutStartSec = "infinity";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
    };
}
