# Nix-darwin configuration tasks
# Recipes are sandbox-safe for LLM agents (no sudo, non-destructive) EXCEPT
# `switch` / `switch-host`, which apply the system config with sudo — run those
# interactively yourself, not from an agent.

# Pass recipe arguments to shebang recipes as real positional params ($@/$1…),
# so variadic wrappers (e.g. `pulumi`) can forward them via "$@" without the
# word-splitting/globbing that raw `{{ args }}` interpolation would cause.
set positional-arguments

# Default: list available tasks
default:
    @just --list

# Warn if there are untracked files under modules/ or hosts/ — Nix flakes
# only see git-tracked files, so untracked changes are silently ignored
# by build/eval/check. Run `git add -N <paths>` to make them visible.
_check-untracked:
    #!/usr/bin/env bash
    set -euo pipefail
    # matches: ?? modules/foo.nix   and   ?? hosts/FCX19GT9XR/secrets.nix
    # perl exits 0 on no match, so this needs no `|| true` under `set -e`.
    untracked=$(git status --porcelain | perl -ne 'print if m{^\?\? (?:modules|hosts)/}')
    if [ -n "$untracked" ]; then
        echo "WARNING: untracked files under modules/ or hosts/ — the flake will NOT see them." >&2
        echo "Stage them first:  git add -N <paths>" >&2
        echo "$untracked" >&2
    fi

# Run a developer shell
shell:
    nix develop --no-pure-eval

# Build the current host configuration (without applying)
build: _check-untracked
    #!/usr/bin/env bash
    # pipefail is load-bearing: just's default shell is `sh -cu`, so a bare
    # `darwin-rebuild build … | ts` reports the exit status of *ts*, and a failing
    # build comes out green. Observed for real — a shellcheck error inside a
    # writeShellApplication failed the build while `just build` returned 0.
    set -euo pipefail
    time darwin-rebuild build --flake . --keep-going --keep-failed -L | ts

# Build a specific host configuration
build-host host: _check-untracked
    #!/usr/bin/env bash
    set -euo pipefail   # see the note on `build` — without it `| ts` eats failures
    time nix build '.#darwinConfigurations.{{ host }}.system' --keep-going --keep-failed | ts

# --- Apply configuration (needs sudo; interactive — NOT agent-safe) ---

# Apply THIS host's configuration. Selects the flake attr by hardware serial
# (IOPlatformSerialNumber) so a transiently drifted LocalHostName — macOS's
# "-2" Bonjour suffix on a name collision — can't break attr selection the way
# a bare `--flake .` does. Extra args are forwarded, e.g. `just switch --dry-run`.
switch *args:
    #!/usr/bin/env bash
    set -euo pipefail
    # matches:       "IOPlatformSerialNumber" = "FCX19GT9XR"   ->  $+{serial}
    # Anchored on the key name and the quoted value, not on a '"'-field index.
    serial=$(ioreg -c IOPlatformExpertDevice -d 2 | perl -ne '
        if (/"IOPlatformSerialNumber" \s* = \s* "(?<serial>[^"]+)"/x) {
            print $+{serial};
            last;
        }
    ')
    [ -n "$serial" ] || { echo "could not determine hardware serial" >&2; exit 1; }
    echo "→ sudo darwin-rebuild switch --flake .#${serial} $*" >&2
    sudo darwin-rebuild switch --flake ".#${serial}" "$@"

# Apply a SPECIFIC host by name, e.g. `just switch-host DKL6GDJ7X1`
switch-host host:
    sudo darwin-rebuild switch --flake ".#{{ host }}"

# Run flake checks
check: _check-untracked
    nix flake check

# Format all Nix files
fmt:
    nix run nixpkgs#nixpkgs-fmt -- $(find . -name '*.nix' -not -path './_*')

# Format and check — returns non-zero if files were changed
fmt-check:
    nix run nixpkgs#nixpkgs-fmt -- --check $(find . -name '*.nix' -not -path './_*')

# Update all flake inputs
update:
    nix flake update

# Update a single flake input
update-input input:
    nix flake update {{ input }}

# Bump the pinned Homebrew source (brew-src in flake.nix) to the latest upstream
# release and relock. Homebrew 6 serves casks from a rolling JSON API that cannot
# be pinned, so a stale brew eventually meets a cask DSL artifact it doesn't know
# and `brew bundle` aborts activation — see the brew-src comment in flake.nix.
# This is the cure for that. Optional argument pins a specific tag instead.
brew-bump tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{ tag }}"
    if [ -z "$tag" ]; then
        tag=$(curl -fsSL https://api.github.com/repos/Homebrew/brew/releases/latest | jq -r .tag_name)
    fi
    [ -n "$tag" ] && [ "$tag" != "null" ] || { echo "could not determine a brew tag" >&2; exit 1; }
    # matches:     url = "github:Homebrew/brew/6.0.17";   ->  $+{tag} eq "6.0.17"
    current=$(perl -ne '
        if (m{^ \s* url \s* = \s* "github:Homebrew/brew/(?<tag>[^"]+)"; \s* $}x) {
            print $+{tag};
            last;
        }
    ' flake.nix)
    [ -n "$current" ] || { echo "no brew-src url line found in flake.nix" >&2; exit 1; }
    if [ "$tag" = "$current" ]; then
        echo "brew-src already at $tag"
        exit 0
    fi
    echo "brew-src: $current -> $tag"
    # perl -i, not sed -i: Perl implements in-place editing itself, so it behaves
    # identically everywhere. `sed -i` does not — macOS puts BSD sed on PATH when
    # just runs without a loaded direnv, and BSD sed reads `-i'' -e` as "backup
    # extension -e", silently leaving a stale flake.nix-e beside the real file.
    # The END block makes a non-matching pattern a hard error instead of a no-op.
    # \Q…\E quotes the interpolated tag, so a dot in it stays a literal dot.
    # matches:     url = "github:Homebrew/brew/6.0.9";   (with CUR=6.0.9)
    CUR="$current" NEW="$tag" perl -i -pe '
        BEGIN { $n = 0 }
        $n += s|\Qurl = "github:Homebrew/brew/$ENV{CUR}";\E|url = "github:Homebrew/brew/$ENV{NEW}";|;
        END { die "substitution matched nothing — pattern drift in flake.nix?\n" unless $n }
    ' flake.nix
    nix flake update brew-src
    echo "Now run: just build && just switch   (switch selects the flake attr by hardware serial)"

# Recompute the agent-browser release-binary hashes for modules/agent-browser.nix
# after bumping the agent-browser-src tag in flake.nix. Prints the ready-to-paste
# `assets` attrset. Example: `just agent-browser-hashes 0.34.0`
agent-browser-hashes version:
    #!/usr/bin/env bash
    set -euo pipefail
    base="https://github.com/vercel-labs/agent-browser/releases/download/v{{ version }}"
    for pair in aarch64-darwin:darwin-arm64 x86_64-darwin:darwin-x64 \
                x86_64-linux:linux-musl-x64 aarch64-linux:linux-musl-arm64; do
        sys="${pair%%:*}"
        asset="agent-browser-${pair##*:}"
        hash=$(nix store prefetch-file --json "$base/$asset" | nix run nixpkgs#jq -- -r .hash)
        printf '    %-14s = { asset = "%s"; hash = "%s"; };\n' "$sys" "$asset" "$hash"
    done

# Show what would change between current system and new build
diff: build
    nix store diff-closures /run/current-system ./result

# Build and verify no package delta (useful after refactoring)
verify-no-diff: build
    #!/usr/bin/env bash
    set -euo pipefail
    diff_output=$(nix store diff-closures /run/current-system ./result 2>&1)
    if [ -n "$diff_output" ]; then
        echo "Differences found:"
        echo "$diff_output"
        exit 1
    else
        echo "No differences — refactoring is safe."
    fi

# Show the flake dependency tree
deps:
    nix flake metadata --json | nix run nixpkgs#jq -- -r '.locks.nodes | to_entries[] | select(.value.locked?) | "\(.key): \(.value.locked.type):\(.value.locked.owner // ""):\(.value.locked.repo // "")"'

# Evaluate a flake output without building (fast syntax check)
eval: _check-untracked
    nix eval '.#darwinConfigurations' --apply 'x: builtins.attrNames x'

# Show derivation of current host build
show-derivation:
    nix derivation show '.#darwinConfigurations.FCX19GT9XR.system' | nix run nixpkgs#jq -- .

# --- Store maintenance ---

# Deduplicate the store by hard-linking identical files (safe, reversible)
optimise:
    nix store optimise

# Collect user-level garbage, keeping generations from the last 7 days. The
# system profile is pruned automatically every week (see modules/nix-gc.nix);
# a one-off full sweep is `sudo nix-collect-garbage --delete-older-than 7d`.
gc:
    nix-collect-garbage --delete-older-than 7d

# Decrypt and view the Boundary reference doc (hosts/DKL6GDJ7X1/BOUNDARY.md.gpg)
view-boundary-doc:
    gpg --decrypt hosts/DKL6GDJ7X1/BOUNDARY.md.gpg | less -R

# Edit the Boundary reference doc: decrypt -> $EDITOR -> re-encrypt to all three recipients
edit-boundary-doc:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -t BOUNDARY.md.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    gpg --decrypt hosts/DKL6GDJ7X1/BOUNDARY.md.gpg > "$tmp"
    "${EDITOR:-nvim}" "$tmp"
    # --trust-model always: rely on the explicit recipient list rather than GPG's web-of-trust.
    # Necessary because the work check24 key has no WoT path to your primary key.
    gpg --yes --trust-model always --encrypt --armor \
        -r stefan@schwetschke.de \
        -r stefan.schwetschke@check24.de \
        -r stefan.schwetschke+DKL6GDJ7X1@check24.de \
        -o hosts/DKL6GDJ7X1/BOUNDARY.md.gpg "$tmp"

# Enter the devenv-backed developer shell (also available automatically via direnv)
devshell:
    nix develop --no-pure-eval

# --- Pulumi (infra/) ---

# Assert a secrets file can actually be opened by this machine's key, before sops runs.
#
# We decrypt with an SSH identity: SOPS_AGE_SSH_PRIVATE_KEY_FILE (exported from
# modules/shells.nix) points at ~/.ssh/id_ed25519_sops_nopw. In age, an SSH identity
# can ONLY open `ssh-ed25519` recipient blocks — never `age1` ones, even when the age1
# recipient is the ssh-to-age conversion of that very key. So a file carrying only
# age1 recipients is undecryptable here, and sops' own error does not say why: once
# SOPS_AGE_SSH_PRIVATE_KEY_FILE is set it drops out of the "did not find keys in
# locations" list, which reads as if it were never consulted at all.
_sops-preflight file:
    #!/usr/bin/env bash
    set -euo pipefail
    f="{{ file }}"
    [ -r "$f" ] || { echo "sops preflight: cannot read $f" >&2; exit 1; }
    # matches:   recipient: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...   -> ssh
    #            recipient: age1vygfenpy584kvfdge57ep2...             -> age
    #            fp: B6CA7BD9B0973FBF981C3B1E7C8C077F1B72E98B         -> pgp
    read -r n_ssh n_age n_pgp <<<"$(perl -ne '
        $ssh++ if /^\s*-?\s*recipient:\s*ssh-ed25519\s/;
        $age++ if /^\s*-?\s*recipient:\s*age1[a-z0-9]/;
        $pgp++ if /^\s*-?\s*fp:\s*\S/;
        END { printf "%d %d %d", $ssh // 0, $age // 0, $pgp // 0 }
    ' "$f")"
    if [ "$n_ssh" -gt 0 ]; then exit 0; fi
    {
        echo "sops preflight FAILED: $f has no ssh-ed25519 recipient."
        echo "  in the file:  $n_ssh ssh-ed25519, $n_age age1, $n_pgp pgp"
        echo "  We decrypt with an SSH identity (SOPS_AGE_SSH_PRIVATE_KEY_FILE, set in"
        echo "  modules/shells.nix). In age an SSH identity can only open ssh-ed25519"
        echo "  blocks — never age1 ones, not even the ssh-to-age conversion of the same"
        echo "  key — so this file cannot be decrypted here."
        echo
        echo "  declared for this path in .sops.yaml:"
        # Filename travels through the environment, not shell interpolation, so a path
        # holding regex metacharacters cannot break the pattern (same idiom as the
        # brew-bump recipe below). Backslashes are stripped per line because .sops.yaml
        # stores the path as an escaped regex.
        # matches:   - path_regex: ^secrets/infra\.enc\.yaml$   (against secrets/infra.enc.yaml)
        SOPS_FILE="$f" perl -ne '
            (my $line = $_) =~ s/\\//g;
            $on = 1 if $line =~ /\Q$ENV{SOPS_FILE}\E/;
            if ($on) { print "    $_"; $on = 0 if /age:.*\]/ }
        ' .sops.yaml | perl -pe 's/", "/",\n        "/g' || true
        echo
        echo "  Fix — re-key the file to every recipient .sops.yaml declares:"
        echo "      sops updatekeys $f"
        echo "  (this also restores any missing pgp recovery key, not just the ssh ones)"
        echo
        echo "  sops version: $(sops --version 2>&1 | head -1)"
    } >&2
    exit 1

# Run any pulumi command in infra/ with the Pulumi Cloud + Cloudflare tokens from SOPS
pulumi *args: (_sops-preflight "secrets/infra.enc.yaml")
    #!/usr/bin/env bash
    set -euo pipefail
    PULUMI_ACCESS_TOKEN="$(sops -d --extract '["pulumi_access_token"]' secrets/infra.enc.yaml)"
    export PULUMI_ACCESS_TOKEN
    # The default cloudflare provider (and CLI `pulumi import`) reads this env var.
    CLOUDFLARE_API_TOKEN="$(sops -d --extract '["cloudflare_api_token"]' secrets/infra.enc.yaml)"
    export CLOUDFLARE_API_TOKEN
    # AWS goes through the environment rather than ~/.aws/credentials, per
    # Architecture.md §2: infra secrets live in the pulumi process and nowhere
    # else. That is not just tidiness here — sops-nix writes the *C24 work*
    # profile to ~/.aws/credentials on this machine, so a file-based setup would
    # put two unrelated identities in one place and pick between them by
    # convention. Static env credentials outrank the shared file in the SDK
    # chain, but an AWS_PROFILE inherited from the caller would still redirect
    # the provider at that work profile. Unset it so the identity Pulumi uses is
    # decided here and nowhere else.
    AWS_ACCESS_KEY_ID="$(sops -d --extract '["aws_access_key_id"]' secrets/infra.enc.yaml)"
    AWS_SECRET_ACCESS_KEY="$(sops -d --extract '["aws_secret_access_key"]' secrets/infra.enc.yaml)"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    # Which stack to operate on. Unlike the backend (pinned in infra/Pulumi.yaml),
    # this cannot be declared in the project file — Pulumi's ProjectBackend carries
    # only `url`, and there is no default-stack key. Stack selection is otherwise
    # per-machine state in ~/.pulumi/workspaces/, which a fresh checkout lacks, so
    # every command dies with "no stack selected". PULUMI_STACK supplies it and
    # persists nothing. Non-clobbering, and an explicit `-s/--stack` still wins.
    #
    # Beware the misleading error: a stack name that does not exist reports
    # "no stack selected" rather than "no stack named 'x' found". If you see that
    # after this is set, the NAME is wrong, not the backend — run
    # `just pulumi stack ls` to see the real names, and use <org>/<stack> if the
    # stack lives under an organisation rather than your personal account.
    export PULUMI_STACK="${PULUMI_STACK:-prod}"
    cd infra
    # pulumi runs the compiled dist/index.js (see Pulumi.yaml `main`), so rebuild
    # it first — tsc is fast/incremental and keeps the program in sync. pulumi +
    # pnpm live in the devenv shell; fall back to it when not already active
    # (e.g. non-interactive `just` without a loaded direnv). Args are forwarded
    # via "$@" (see `set positional-arguments`), so quoting/whitespace survives.
    if command -v pulumi >/dev/null 2>&1 && command -v pnpm >/dev/null 2>&1; then
      pnpm run --silent build
      pulumi "$@"
    else
      nix develop ../ --no-pure-eval -c bash -euc 'pnpm run --silent build && pulumi "$@"' -- "$@"
    fi

# Preview infrastructure changes
pulumi-preview: (pulumi "preview")

# Apply infrastructure changes
pulumi-up: (pulumi "up")

# Show current infrastructure state
pulumi-stack: (pulumi "stack")

# Install infra dependencies
pulumi-install:
    #!/usr/bin/env bash
    set -euo pipefail   # see the note on `build` — without it `| ts` eats failures
    cd infra && time pnpm install | ts

# Audit infra/pnpm-lock.yaml against OSV + npm publish dates (exits 1 on findings)
pulumi-audit *args:
    python3 infra/scripts/osv-audit.py "$@"

# --- Inventory of hosts Pulumi cannot manage ---

# The hosts in infra/src/inventory.ts have no provider and no API (see that file's
# header, and Architecture.md §11), so `pulumi preview` reconciles nothing about
# them: the recorded constants could drift arbitrarily far from the real machine
# and every Pulumi command would still report a clean stack. This is the only
# thing that can tell you otherwise. Fails on a host-key mismatch AND on an
# unreachable host — silence is never success.
#
# Verify infra/src/inventory.ts against the real hosts (reachable + host key matches)
infra-verify *args:
    python3 infra/scripts/infra-verify.py "$@"

# Fills the inventory and decides how deeply Nix can manage a host: system-manager
# on the existing distro, or a full NixOS conversion via nixos-anywhere. Changes
# nothing on the target; prints to stdout, so redirect to keep the result —
#   just infra-recon root@87.106.149.208 > /tmp/ionos-recon.txt
#
# Read-only SSH survey of an unprovisioned host (hardware, disks, network, services)
infra-recon target:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "# recon of $1 — read-only, no changes made"
    # BatchMode: fail fast instead of prompting, so a missing key is an error
    # rather than a hung recipe. accept-new (not `no`) because the point of this
    # run is often to learn the host key in the first place; `just infra-verify`
    # is what pins it afterwards.
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$1" 'bash -s' <<'REMOTE'
    # Survey only. Every entry is a read; nothing here writes, installs or
    # restarts. A missing tool prints "(exit N)" rather than aborting the run —
    # for a survey "not present" is a real answer, not a swallowed failure.
    run() { printf '\n### %s\n' "$1"; sh -c "$2" 2>&1 || printf '(exit %d)\n' "$?"; }

    run 'identity'        'hostnamectl; uname -a'
    run 'uptime / boot'   'uptime; who -b'
    run 'cpu + memory'    'nproc; free -m'
    run 'block devices'   'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL'
    run 'partitions'      'sudo -n parted -l 2>/dev/null || parted -l 2>/dev/null || echo "(needs root)"'
    run 'filesystems'     'df -hT -x tmpfs -x devtmpfs'
    run 'fstab'           'cat /etc/fstab'
    # Interface name and both gateways decide the static network config a NixOS
    # install must carry: IONOS hands out a static IPv6 with a link-local gateway,
    # and a DHCP-only config comes back up without it.
    run 'addresses'       'ip -brief addr'
    run 'routes v4'       'ip route'
    run 'routes v6'       'ip -6 route'
    run 'netplan'         'cat /etc/netplan/*.yaml 2>/dev/null || echo "(no netplan)"'
    run 'dns'             'resolvectl status 2>/dev/null | head -30 || cat /etc/resolv.conf'
    run 'kexec support'   'test -e /sys/kernel/kexec_loaded && echo "kexec_loaded present" || echo "no /sys/kernel/kexec_loaded"; dpkg -l kexec-tools 2>/dev/null | tail -1'
    run 'running units'   'systemctl list-units --type=service --state=running --no-pager --no-legend'
    run 'listening ports' 'ss -tulpn 2>/dev/null || ss -tuln'
    run 'enabled at boot' 'systemctl list-unit-files --state=enabled --no-pager --no-legend'
    run 'containers'      'docker ps -a 2>/dev/null || echo "(no docker)"; podman ps -a 2>/dev/null || true'
    # What a NixOS conversion would destroy. Sizes only — no file contents.
    # Each path is tested before measuring: `du` exits non-zero if *any* argument
    # is missing, and an || fallback chain would then re-run and append a bogus
    # "(needs root)" after a perfectly complete listing. An absent directory is
    # reported as absent rather than silently dropped.
    run 'data footprint'  'for d in /home /srv /opt /var/www /var/lib /root /usr/local; do if [ -e "$d" ]; then du -shx "$d"; else printf -- "-\t%s (does not exist)\n" "$d"; fi; done'
    run 'human users'     'getent passwd | awk -F: "\$3 >= 1000 && \$3 < 65534"'
    run 'authorized_keys' 'wc -l /root/.ssh/authorized_keys ~/.ssh/authorized_keys 2>/dev/null || echo "(none readable)"'
    run 'cron / timers'   'ls -1 /etc/cron.d 2>/dev/null; systemctl list-timers --no-pager --no-legend 2>/dev/null | head -20'
    run 'nix present?'    'test -d /nix && echo "/nix exists" || echo "no /nix"'
    run 'package count'   'dpkg -l | grep -c "^ii" || true'
    REMOTE

# --- Nix binary cache (Cloudflare R2) ---

# Endpoint of the S3 push target (public pull URL is the custom domain).
R2_S3_URL := "s3://nix-cache?endpoint=81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com&region=auto&compression=zstd"

# Seed R2 with the current system's delta (paths not already on cache.nixos.org)
cache-seed:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' bash modules/_files/nix-cache/nix-cache-push --seed

# Push specific paths (repair/ad hoc), e.g. `just cache-push /run/current-system`
cache-push *paths:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' bash modules/_files/nix-cache/nix-cache-push "$@"

# Seed R2 with a REMOTE host's closure delta, e.g. the x86_64-linux VPS. Needed
# because no Darwin workstation can build x86_64-linux (nix-darwin's
# nix.linux-builder requires nix.enable, which Determinate sets to false), so
# those paths only ever exist on the server. The R2 write credentials stay here;
# the server has the cache as a read-only substituter and never holds a push key.
#   just cache-seed-remote root@87.106.149.208
cache-seed-remote host target="/run/current-system":
    #!/usr/bin/env bash
    set -euo pipefail
    # max-connections=1 is not tuning, it is correctness. `nix copy` otherwise
    # opens several SSH channels at once; sshd refuses the ones past its
    # MaxSessions limit, and the refused channel hands nix a few bytes of
    # multiplexer noise instead of a protocol greeting:
    #     error: cannot open connection to remote store 'ssh-ng://…':
    #            protocol mismatch, got 'started …'
    # The whole copy then aborts having transferred nothing. Serial is slower
    # and finishes.
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' bash modules/_files/nix-cache/nix-cache-push \
      --from "ssh-ng://{{ host }}?max-connections=1" --seed "{{ target }}"

# Bootstrap a fresh machine: pre-fetch the R2-cached delta (the paths NOT on
# cache.nixos.org) into the store BEFORE the first switch, so that first —
# otherwise most expensive — build downloads them instead of compiling from
# source. Needs sudo: on a fresh box the login user isn't a trusted-user yet
# (that only lands at the first activation) and nix.custom.conf doesn't exist,
# so only a root (always-trusted) invocation with explicit flags makes the
# daemon honor R2. Then apply the printed switch. Example: `just bootstrap DKL6GDJ7X1`
bootstrap host:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo nix build --no-link \
      --extra-substituters 'https://nix-cache.pub.schwetschke.dev' \
      --extra-trusted-public-keys 'nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=' \
      '.#darwinConfigurations.{{ host }}.system'
    echo
    echo "R2 delta is in the local store. Now apply it:"
    echo "  just switch-host {{ host }}"
