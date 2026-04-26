# Helpers for loading sops-nix secrets into env vars.
# Sourced from writeShellApplication wrappers (bash, set -euo pipefail).
# Defines: $SECRETS_DIR, load_from_secret(), require_secrets()

SECRETS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"

# Load the file "$SECRETS_DIR/$2" into env var named $1 if that var is unset
# or empty. Silent no-op if the file is missing or empty — callers should
# follow up with require_secrets to assert presence.
load_from_secret() {
  local var_name="$1" file_name="$2"
  local current_val="${!var_name-}"
  if [[ -z "$current_val" && -r "$SECRETS_DIR/$file_name" ]]; then
    local val
    val="$(<"$SECRETS_DIR/$file_name")"
    if [[ -n "$val" ]]; then
      export "$var_name=$val"
    fi
  fi
}

# Exit 1 if any of the named env vars is unset or empty. Reports all
# missing names at once (not just the first) for better diagnostics.
require_secrets() {
  local missing=() v
  for v in "$@"; do
    if [[ -z "${!v-}" ]]; then
      missing+=("$v")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: missing secrets: ${missing[*]}" >&2
    echo "Provide via environment or files in: $SECRETS_DIR" >&2
    exit 1
  fi
}
