{ ... }:
{
  flake.modules.homeManager.vault = { config, pkgs, lib, ... }:
    let
      # The single source of truth for every Vault instance. Adding one is a
      # line here plus the secret declaration in hosts/<serial>/secrets.nix;
      # the commands, the `-address` aliases and the prefix matching all
      # follow from this set.
      #
      # legacyToken: additionally mirror the fresh token into the legacy
      # ~/.vault-token location after a successful login. Write-only: nothing
      # here (or in the token helper) ever reads that file — it exists solely
      # for tools that hardcode Path.of(user.home, ".vault-token"). Only
      # staging sets this, so a production token never lands there. May go
      # stale after a helper `erase` — accepted for a legacy shim.
      vaultEnvironments = {
        production = { addrFile = config.sops.secrets.vault_addr_production.path; };
        staging = {
          addrFile = config.sops.secrets.vault_addr_staging.path;
          legacyToken = true;
        };
      };

      # What a bare `+vault` (and interactive fish) talks to when nothing says
      # otherwise.
      defaultEnvironment = "staging";

      # Alphabetical, so the prefix matching below is deterministic.
      environmentNames = lib.attrNames vaultEnvironments;
      legacyEnvironments =
        lib.filter (n: vaultEnvironments.${n}.legacyToken or false) environmentNames;
      shellList = lib.concatMapStringsSep " " lib.escapeShellArg;

      # Token helper wired into ~/.vault: the Vault CLI calls it as
      # `vault-token-helper get|store|erase` with VAULT_ADDR in the
      # environment. Storing one token per address lets staging and production
      # logins coexist instead of clobbering the single ~/.vault-token.
      vaultTokenHelper = pkgs.writeShellApplication {
        name = "vault-token-helper";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          addr="''${VAULT_ADDR:-}"
          addr="''${addr%/}"
          if [ -z "$addr" ]; then
            echo "vault-token-helper: VAULT_ADDR is not set" >&2
            exit 1
          fi
          dir="''${XDG_STATE_HOME:-$HOME/.local/state}/vault/tokens"
          file="$dir/$(printf '%s' "$addr" | sha256sum | cut -d' ' -f1)"

          case "''${1:-}" in
            get)
              # No token file means "not logged in": print nothing, exit 0.
              if [ -f "$file" ]; then
                cat "$file"
              fi
              ;;
            store)
              umask 077
              mkdir -p "$dir"
              chmod 700 "$dir"
              cat > "$file"
              ;;
            erase)
              rm -f "$file"
              ;;
            *)
              echo "usage: vault-token-helper get|store|erase" >&2
              exit 1
              ;;
          esac
        '';
      };

      # Shared by both wrappers: turns "prod", "p", "staging" or a literal URL
      # into an address, and says so loudly when it cannot. Generated from
      # vaultEnvironments above.
      resolverLib = ''
        vault_env_names=( ${shellList environmentNames} )
        vault_env_files=( ${shellList (map (n: vaultEnvironments.${n}.addrFile) environmentNames)} )
        vault_env_legacy=( ${shellList legacyEnvironments} )
        # Read by +vault only — the resolver is shared with +vault-login.
        # shellcheck disable=SC2034
        vault_env_default=${lib.escapeShellArg defaultEnvironment}

        # vault_resolve_env <value>
        # Sets VAULT_ENV_NAME (canonical name; empty for a literal URL) and
        # VAULT_ENV_ADDR. Never falls back silently: an unknown or ambiguous
        # value aborts, because a quiet fallback to the default would redirect
        # a production command without saying a word.
        vault_resolve_env() {
          local want="''${1-}" lower name file idx
          local matches=()
          local i
          # VAULT_ENV_NAME is read by +vault-login only.
          # shellcheck disable=SC2034
          VAULT_ENV_NAME=""
          VAULT_ENV_ADDR=""

          if [ -z "$want" ]; then
            echo "vault: empty address; expected a URL or one of: ''${vault_env_names[*]}" >&2
            return 1
          fi

          # Anything carrying a scheme is a literal address, passed through
          # untouched.
          case "$want" in
            *://*)
              VAULT_ENV_ADDR="$want"
              return 0
              ;;
          esac

          lower="''${want,,}"
          for i in "''${!vault_env_names[@]}"; do
            name="''${vault_env_names[i]}"
            # An exact match wins outright, so a name that happens to be a
            # prefix of another one stays reachable.
            if [ "$name" = "$lower" ]; then
              matches=( "$i" )
              break
            fi
            case "$name" in
              "$lower"*) matches+=( "$i" ) ;;
            esac
          done

          if [ "''${#matches[@]}" -eq 0 ]; then
            echo "vault: unknown environment '$want'; known: ''${vault_env_names[*]}" >&2
            return 1
          fi
          if [ "''${#matches[@]}" -gt 1 ]; then
            local candidates=()
            for i in "''${matches[@]}"; do
              candidates+=( "''${vault_env_names[i]}" )
            done
            echo "vault: '$want' is ambiguous; it matches: ''${candidates[*]}" >&2
            return 1
          fi

          idx="''${matches[0]}"
          name="''${vault_env_names[idx]}"
          file="''${vault_env_files[idx]}"
          if [ ! -r "$file" ]; then
            echo "vault: cannot read the address of '$name' at $file" >&2
            echo "       (sops-nix secret missing — has 'just switch' run?)" >&2
            return 1
          fi
          VAULT_ENV_ADDR="$(< "$file")"
          if [ -z "$VAULT_ENV_ADDR" ]; then
            echo "vault: the address file of '$name' is empty: $file" >&2
            return 1
          fi
          # shellcheck disable=SC2034
          VAULT_ENV_NAME="$name"
        }

        # vault_env_wants_legacy_token <canonical-name>
        vault_env_wants_legacy_token() {
          local n
          for n in "''${vault_env_legacy[@]}"; do
            if [ "$n" = "''${1-}" ]; then
              return 0
            fi
          done
          return 1
        }
      '';

      # `vault` itself is provided by Homebrew (hashicorp/tap/vault in
      # homebrew-common.nix) and is absent from the non-interactive PATH, so
      # both wrappers put /opt/homebrew on it themselves. No recursion risk:
      # these are named `+vault*`, not `vault`.
      homebrewPath = ''
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
      '';

      # Runs `vault` with `-address=<environment>` resolved — full name, or any
      # unambiguous prefix, or a literal URL.
      vaultCli = pkgs.writeShellApplication {
        name = "+vault";
        text = ''
          ${homebrewPath}
          ${resolverLib}

          # Consume every -address/--address, in the "=" form and the
          # space-separated one; the last occurrence wins, as in Go's flag
          # package. The flag is REMOVED rather than rewritten in place, and
          # that is the whole point: VAULT_ADDR below already carries the
          # answer, while a rewritten flag left standing counts as a positional
          # argument to Vault, which parses flags only BEFORE the positionals.
          # Measured while it still rewrote in place:
          #
          #   $ +vault kv get secret/x -address=https://b.invalid:8200
          #   Command flags must be provided before positional arguments. …
          #   Too many arguments (expected 1, got 2)            # exit 1
          #
          # So the command did NOT reach the instance that was typed; it
          # aborted. `token lookup` and `version` tolerate a surplus argument,
          # which is why it went unnoticed. Removing the flag honours the
          # intent wherever it stands, and Vault's positional warning never
          # fires. Everything after `--` passes through untouched — a
          # `-address` there belongs to the command, not to us.
          args=()
          addr_value=""
          addr_found=0
          passthrough=0
          while [ "$#" -gt 0 ]; do
            if [ "$passthrough" -eq 1 ]; then
              args+=( "$1" )
              shift
              continue
            fi
            case "$1" in
              --)
                passthrough=1
                args+=( "$1" )
                shift
                ;;
              -address=*|--address=*)
                addr_value="''${1#*=}"
                addr_found=1
                shift
                ;;
              -address|--address)
                if [ "$#" -lt 2 ]; then
                  echo "+vault: -address needs a value" >&2
                  exit 1
                fi
                addr_value="$2"
                addr_found=1
                shift 2
                ;;
              *)
                args+=( "$1" )
                shift
                ;;
            esac
          done

          if [ "$addr_found" -eq 1 ]; then
            vault_resolve_env "$addr_value"
          else
            # No flag, so resolve VAULT_ADDR — which makes
            # `VAULT_ADDR=prod +vault …` work too — or the default.
            vault_resolve_env "''${VAULT_ADDR:-$vault_env_default}"
          fi

          # The whole point of this wrapper. Vault starts the external token
          # helper with an unmodified os.Environ(), so the helper only ever
          # sees VAULT_ADDR and never -address. Measured both ways against a
          # host that does not resolve, so no production request was made:
          # with VAULT_ADDR unset the helper aborts ("VAULT_ADDR is not set"),
          # with it set the helper hands over THAT environment's token while
          # the request goes to the -address target. Both exit 2 — the exit
          # code does not tell them apart. Without this line a
          # `-address=production` command would be signed with the staging
          # token.
          export VAULT_ADDR="$VAULT_ENV_ADDR"

          if ! command -v vault > /dev/null; then
            echo "+vault: no 'vault' on PATH (brew install hashicorp/tap/vault)" >&2
            exit 127
          fi

          exec vault "''${args[@]}"
        '';
      };

      # OIDC login against one environment, resolved the same way.
      vaultLogin = pkgs.writeShellApplication {
        name = "+vault-login";
        text = ''
          ${homebrewPath}
          ${resolverLib}

          # No default environment on purpose: a login should never land in
          # the wrong instance because an argument was forgotten.
          if [ "$#" -lt 1 ]; then
            echo "usage: +vault-login <environment> [<token>]" >&2
            echo "       environments: ''${vault_env_names[*]}" >&2
            echo "       an unambiguous prefix is enough, e.g. '+vault-login p'" >&2
            exit 1
          fi

          vault_resolve_env "$1"

          # Force the address: interactive fish exports VAULT_ADDR (the
          # default environment), which would otherwise silently redirect this
          # login to the wrong vault.
          export VAULT_ADDR="$VAULT_ENV_ADDR"

          write_legacy_token() {
            if ! vault_env_wants_legacy_token "$VAULT_ENV_NAME"; then
              return 0
            fi
            local token
            token="$(${lib.getExe vaultTokenHelper} get)"
            if [ -n "$token" ]; then
              umask 077
              printf '%s' "$token" > "$HOME/.vault-token"
              chmod 600 "$HOME/.vault-token"
            fi
          }

          # A token passed as the second argument skips OIDC and logs in
          # directly — useful when the OIDC flow is unavailable.
          if [ "$#" -ge 2 ]; then
            vault login -address "$VAULT_ADDR" -no-print "$2"
            write_legacy_token
            echo "Logged in to $VAULT_ADDR with the provided token."
            exit 0
          fi

          if vault login -method=oidc -address "$VAULT_ADDR" -no-print; then
            write_legacy_token
            echo "Check your web browser and finish the login there if necessary."
          else
            echo "" >&2
            echo "OIDC login against VAULT_ADDR=$VAULT_ADDR failed." >&2
            echo "Log in via the web UI to grab a token:" >&2
            echo "  $VAULT_ADDR/ui/vault/secrets" >&2
            echo "(the direct URL returns an Internal Server Error)." >&2
            echo "Then pass that token directly. Prepend a space so it" >&2
            echo "stays out of your shell history (it is short-lived anyway):" >&2
            echo "   +vault-login $1 <token>" >&2
            exit 1
          fi
        '';
      };
    in
    {
      home.packages = [
        vaultCli
        vaultLogin
      ];

      # The `-address` trap is a property of this machine, not of any one
      # repository, so it ships as a global agent rule — and it ships from
      # here, so it only reaches hosts that actually import this aspect.
      my.ai.extraRules = [ ./_files/vault/rules/vault-address.md ];

      home.file.".vault".text = ''
        token_helper = "${lib.getExe vaultTokenHelper}"
      '';

      # Default plain `vault` to the default instance. Reads the secret at
      # runtime so the address never lands in the Nix store; intentionally
      # plain fish (no promptInit.fish helpers) to avoid init-order
      # dependencies between modules.
      programs.fish.interactiveShellInit =
        let addrFile = vaultEnvironments.${defaultEnvironment}.addrFile; in
        ''
          if not set -q VAULT_ADDR; and test -r "${addrFile}"
            set -gx VAULT_ADDR (command cat "${addrFile}")
          end
        '';
    };
}
