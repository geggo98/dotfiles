#!/bin/sh
# Entrypoint for the Dockerised Linux Nix builder (see ../../linux-builder.nix
# and ./linux-builder). Runs inside `nixos/nix:<ver>-<arch>`.
#
# POSIX sh, NOT zsh, and that is a deliberate carve-out from the repo's
# "short scripts -> zsh" rule: this script's whole job is to run *before* any
# package is installed. The image ships bash (as /bin/sh) and nothing else —
# there is no zsh to run it with until nix has fetched one, which is what this
# script arranges. Everything that runs after the store is populated is zsh.
#
# Everything it writes lives under $STATE (inside the /nix volume) so that
# `docker rm` loses nothing and `docker volume rm` loses everything. The
# container's own writable layer is treated as throwaway.
#
# Required environment (set by `linux-builder up`):
#   BUILDER_AUTHORIZED_KEY   public half of the workstation's builder key
#   BUILDER_NIXPKGS_REV      nixpkgs revision to take openssh from (pinned to
#                            the repo's own flake.lock, so it substitutes)
#   BUILDER_SUBSTITUTERS     extra substituters for the builder's nix.conf
#   BUILDER_TRUSTED_KEYS     matching extra-trusted-public-keys
#   BUILDER_MIN_FREE         min-free, bytes
#   BUILDER_MAX_FREE         max-free, bytes
#   BUILDER_SYSTEM           this builder's Nix system, e.g. x86_64-linux.
#                            Pinned into extra-platforms because the auto-
#                            detected value is wrong twice over under Rosetta —
#                            see the nix.conf comment below.
set -eu

: "${BUILDER_AUTHORIZED_KEY:?BUILDER_AUTHORIZED_KEY is required}"
: "${BUILDER_NIXPKGS_REV:?BUILDER_NIXPKGS_REV is required}"
: "${BUILDER_SUBSTITUTERS:?BUILDER_SUBSTITUTERS is required}"
: "${BUILDER_TRUSTED_KEYS:?BUILDER_TRUSTED_KEYS is required}"
: "${BUILDER_MIN_FREE:?BUILDER_MIN_FREE is required}"
: "${BUILDER_MAX_FREE:?BUILDER_MAX_FREE is required}"
: "${BUILDER_SYSTEM:?BUILDER_SYSTEM is required}"

STATE=/nix/var/linux-builder
PROFILE="$STATE/profile"

# Nix's caches go in the VOLUME, not the container layer. `linux-builder up`
# replaces the container on every start (its env and mounts would otherwise go
# stale), so $HOME/.cache would be discarded each time — and that directory
# holds binary-cache-v8.sqlite (every narinfo lookup we have already paid for),
# eval-cache-v6, and tarball-cache-v2 (the fetched flake inputs, i.e. nixpkgs).
# Measured at 73 MB after a single closure; throwing it away meant re-querying
# thousands of narinfos and re-fetching nixpkgs on every recreation.
#
# The trade-off: this now counts against the volume's 25 GiB cap, and
# `nix store gc` does not prune it — only `linux-builder destroy` does. That is
# the right way round, because the cap check measures /nix as a whole and will
# therefore see it grow.
export XDG_CACHE_HOME="$STATE/cache"

mkdir -p "$STATE" "$XDG_CACHE_HOME" /etc/nix /root/.ssh

# /etc/nix/nix.conf ships as a SYMLINK into the image's own store path:
#   /etc/nix/nix.conf -> /nix/store/kscc46…-base-system/etc/nix/nix.conf
# `cat > /etc/nix/nix.conf` follows it and rewrites a file INSIDE /nix/store —
# mutating a store path, which is the one thing Nix's model forbids outright,
# and doing it in the volume that later gets signed and pushed to R2. Remove the
# link first, then write a real file.
rm -f /etc/nix/nix.conf

# build-dir: since Nix 2.30 this no longer follows $TMPDIR — it defaults to
# stateDir/builds, i.e. /nix/var/nix/builds, INSIDE the size-capped volume. And
# `nix store gc` collects store paths and .links, never the state dir, so a
# build killed by `docker rm` leaks its whole scratch tree there permanently
# and the cap enforcement cannot see it. /var/tmp is the container layer: it
# dies with the container, and measured faster (1.3 GB/s vs 961 MB/s).
# NOT /var/tmp/nix-build: Nix rejects a build-dir whose ANCESTOR is
# world-writable ("Path \"/var/tmp\" is world-writable or a symlink"), and
# /var/tmp is mode 1777. /build sits directly under / (0755).
mkdir -p /build
chmod 0755 /build

# build-users-group is NOT empty, deliberately. Leaving it empty overrides the
# image's own `nixbld` and makes useBuildUsers() false, so every build runs as
# root: no uid isolation between concurrent builds, and the uid half of the
# output-ownership check never runs. For a throwaway container that would be
# tolerable; for one that SIGNS its output into a cache serving a production
# host it is not. The group and nixbld1..32 already exist in this image.
#
# sandbox = false is not laziness. Nix's Linux sandbox needs pivot_root(2), and
# pivot_root does not appear in Docker's default seccomp profile at all — it is
# denied by the profile's SCMP_ACT_ERRNO default, and `--cap-add SYS_ADMIN` does
# NOT re-enable it. Measured here: `sandbox = true` fails outright with "this
# system does not support the kernel namespaces that are required for
# sandboxing", and even --privileged would then need filter-syscalls = false
# anyway. sandbox-fallback = false is the load-bearing half: the default (true)
# turns the sandbox off *silently* when namespaces are unavailable.
#
# extra-platforms is PINNED because Nix's auto-detection is wrong twice over
# under Rosetta, and this is the machine whose output gets signed:
#   * i686-linux is added unconditionally for any x86_64-linux host. Rosetta 2
#     translates x86-64 only — there is no 32-bit support — so the claim is
#     false and a 32-bit build scheduled here would fail or, worse, not.
#   * x86_64-v3-linux is asserted although CPUID reports avx=0/avx2=0. Not a
#     Nix bug: it delegates to libcpuid, whose decode_architecture_version_x86()
#     computes has_all_features and then never reads it, so the level is decided
#     by the LAST element of the feature array — which for v3 is OSXSAVE, and
#     Rosetta does set that (leaf1.ecx bit 27). v4 escapes only because its last
#     element is AVX512VL.
# This is an assignment, so it REPLACES the detected list (extra-extra-platforms
# would append). The native system is always supported regardless.
#
# filter-syscalls = false is required, not preventive. Nix installs a seccomp BPF
# filter around every build and the kernel rejects it under Rosetta:
#   error: unable to load seccomp BPF program: Invalid argument
# Measured, not assumed — every build fails until this is off, and
# `sandbox = false` alone does not avoid it. The cost is real: that filter is
# what stops a build writing setuid/setgid bits into its output.
#
# min-free/max-free bound the OrbStack VM disk, NOT this volume. The volume cap
# is enforced by `linux-builder gc` before every build; these are only the
# backstop that stops one runaway build filling the whole VM.
#
# NOTE ON download-buffer-size: do NOT raise it here, even though the Macs set
# 1 GiB. 1 MiB is the current upstream default, and since the pause-based
# backpressure landed in Nix 2.33 the release notes say raising it is no longer
# recommended. The Mac's value is the stale one.
cat >/etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
build-users-group = nixbld
build-dir = /build
sandbox = false
sandbox-fallback = false
filter-syscalls = false
max-jobs = auto
cores = 0
extra-platforms = $BUILDER_SYSTEM
extra-substituters = $BUILDER_SUBSTITUTERS
extra-trusted-public-keys = $BUILDER_TRUSTED_KEYS
min-free = $BUILDER_MIN_FREE
max-free = $BUILDER_MAX_FREE
EOF

# The builder's own toolchain, fetched once into a profile inside the volume:
# it is a GC root (so `nix store gc` cannot sweep the running sshd out from
# under us) and it survives `docker rm`. Pinned to the repo's own nixpkgs
# revision, so it substitutes rather than builds.
#
# coreutils is here on purpose and is not redundant with the image's own copy.
# The image roots its tools through /nix/var/nix/profiles/default, which is
# outside our control; owning the few binaries the control script depends on
# (du, cut) means the builder cannot lose them to a garbage collection. This was
# not hypothetical — an earlier `nix-collect-garbage -d` in the gc path unrooted
# that profile and left the container without `ls`.
ensure_pkg() {
  bin="$1"
  attr="$2"
  if [ ! -x "$PROFILE/bin/$bin" ]; then
    echo "linux-builder: installing $attr from nixpkgs/$BUILDER_NIXPKGS_REV ..." >&2
    # `add`, not `install`: 2.35 prints "'install' is a deprecated alias for 'add'".
    nix profile add --profile "$PROFILE" \
      "github:nixos/nixpkgs/$BUILDER_NIXPKGS_REV#$attr"
  fi
}
ensure_pkg sshd openssh
ensure_pkg du coreutils

PATH="$PROFILE/bin:$PATH"
export PATH

# OpenSSH always uses privilege separation and refuses to start without the
# `sshd` account and an empty, root-owned chroot dir:
#   "Privilege separation user sshd does not exist"
# The image has neither. Both live in the container layer, so they are recreated
# on every start — cheap and idempotent.
if ! grep -q '^sshd:' /etc/passwd; then
  echo 'sshd:x:498:498:Privilege-separated SSH:/var/empty:/bin/false' >>/etc/passwd
fi
if ! grep -q '^sshd:' /etc/group; then
  echo 'sshd:x:498:' >>/etc/group
fi
mkdir -p /var/empty
chown root:root /var/empty
chmod 755 /var/empty

# The image ships `root:!:1::::::` in /etc/shadow, and OpenSSH's
# auth_shadow_locked() treats a leading `!` as a locked account and refuses the
# login BEFORE it ever looks at authorized_keys. Symptom, which names neither
# the file nor the reason:
#   User root not allowed because account is locked
#   Connection closed by invalid user root … [preauth]
# `*` means "no password will ever match" without meaning "locked", so public
# key authentication works and password authentication remains impossible — and
# PasswordAuthentication is off regardless.
#
# Done with a shell loop rather than `grep -v` or a perl one-liner, and both
# alternatives were rejected for a reason:
#   * `grep -v '^root:' … >new` exits 1 when it selects NO lines, and `set -e` is
#     live here — the container would die before sshd starts, with no message at
#     all, and `linux-builder up` would burn its whole timeout waiting. That is
#     survivable today only because the image ships 32 nixbld* entries; this
#     builder sets `build-users-group =`, which is exactly the direction an image
#     that drops them would go.
#   * perl (the repo's usual preference over grep/sed/awk) is not in this image,
#     and pulling it in to rewrite one line is not worth the closure.
while IFS= read -r line; do
  case "$line" in
    root:*) printf 'root:*:1::::::\n' ;;
    *)      printf '%s\n' "$line" ;;
  esac
done </etc/shadow >/etc/shadow.new
# `cat >` rather than `mv`: keeps /etc/shadow's own inode and 0600 mode.
cat /etc/shadow.new >/etc/shadow
rm -f /etc/shadow.new

# Our own host key, generated here and kept in the volume — deliberately NOT the
# well-known insecure keypair that nix-darwin's VM builder ships. The
# workstation records it on first connect via StrictHostKeyChecking=accept-new;
# `linux-builder destroy` therefore has to tell the user to drop the stale
# known_hosts entry.
if [ ! -f "$STATE/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'nix-linux-builder' \
    -f "$STATE/ssh_host_ed25519_key"
fi

printf '%s\n' "$BUILDER_AUTHORIZED_KEY" >/root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# MaxSessions is headroom for the nix-daemon, which opens several channels over
# one connection when it delegates a build. It is NOT what makes `linux-push`
# work — that path pins `max-connections=1` regardless (see cmd_push_env), for
# the same reason the VPS recipe does: a channel refused past the limit hands
# nix multiplexer noise instead of a protocol greeting, and the whole copy
# aborts having transferred nothing.
cat >"$STATE/sshd_config" <<EOF
Port 22
HostKey $STATE/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /root/.ssh/authorized_keys
UsePAM no
PrintMotd no
MaxSessions 32
PidFile $STATE/sshd.pid
SetEnv PATH=$PROFILE/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin XDG_CACHE_HOME=$XDG_CACHE_HOME
EOF

echo "linux-builder: $(nix eval --impure --raw --expr builtins.currentSystem), $(nix --version)" >&2

# -D: stay in the foreground so Docker owns the lifecycle. -e: log to stderr so
# `docker logs` shows authentication failures instead of swallowing them.
exec "$PROFILE/bin/sshd" -D -e -f "$STATE/sshd_config"
