# Register the Dockerised Linux builders (modules/_files/linux-builder/) with
# the local Nix daemon, so plain `nix build` can realise Linux derivations on a
# Darwin workstation without going through the `just linux-*` recipes.
#
# WHY THIS IS POSSIBLE AT ALL. nix-darwin's `nix.buildMachines` is unavailable
# here: `nix.enable = false` (modules/determinate.nix) makes every `nix.*` option
# throw. Determinate ships its own equivalent, `determinateNix.buildMachines`,
# which writes /etc/nix/machines — and Nix's `builders` default is already
# `@/etc/nix/machines`. That is the whole hook. It is also why nix-rosetta-builder
# and friends cannot be used unmodified: they all set `nix.buildMachines`.
#
# THIS MODULE DOES NOT START ANYTHING. It only tells Nix where the builders are.
# If the container is not running, a Linux build fails exactly as it does today.
# Bring one up with `just linux-builder-up`. Genuine on-demand start would need a
# launchd-socket-activated proxy and is deliberately out of scope.
#
# AFTER THE FIRST SWITCH, RESTART THE DAEMON ONCE — same story as the R2
# post-build-hook (modules/nix-cache.nix): the Determinate nix-daemon reads
# /etc/nix/machines at startup and `darwin-rebuild switch` does not restart it.
#   just daemon-restart
# (which runs `sudo launchctl kickstart -k system/systems.determinate.nix-daemon`
# and then waits for the daemon to answer again).
{ ... }:
{
  flake.modules.darwin.linux-builder = { config, lib, ... }:
    let
      user = config.system.primaryUser;
      homeDir = toString config.users.users.${user}.home;

      # Must match KEY_DIR/KEY_FILE in modules/_files/linux-builder/linux-builder,
      # which hardcodes the same path for the same reason: a Nix module has no
      # user shell environment to resolve XDG_STATE_HOME from, so resolving it
      # two different ways is how the two halves would silently disagree.
      sourceKey = "${homeDir}/.local/state/nix-linux-builder/id_ed25519";

      installedKey = "/etc/nix/linux-builder-ed25519";
      knownHosts = "/etc/nix/linux-builder-known_hosts";

      # Ports and container naming must match the ARCH_PORT table in
      # modules/_files/linux-builder/linux-builder. They avoid 31022 (the VM
      # builder shipped by both nix-darwin and Determinate) and 31122
      # (nix-rosetta-builder), so either could run alongside these.
      builders = [
        { arch = "x86_64"; system = "x86_64-linux"; port = 31222; }
        { arch = "aarch64"; system = "aarch64-linux"; port = 31223; }
      ];
      aliasOf = b: "nix-linux-builder-${b.arch}";
    in
    {
      # NO ControlMaster/ControlPath here, deliberately. The obvious spelling —
      # `ControlPath /tmp/nix-linux-builder-%r@%h:%p` — is a local privilege
      # escalation: it is the *root* nix-daemon that opens this, the path is
      # fully predictable, and /tmp is world-writable, so any local user can
      # create a socket there first and `ControlMaster auto` will happily connect
      # to it and speak the multiplexer protocol to them. ssh_config(5) says the
      # path must be in a directory not writable by other users, and the sticky
      # bit does not help — nothing has to be deleted, only created first.
      # Nix passes its own -oControlPath when it wants multiplexing, so nothing
      # is lost by leaving it out.
      #
      # A host alias is not cosmetic: Nix store URIs cannot carry a port, and
      # nix-cache-push additionally slices the host out of the URI itself
      # (`ssh-ng://user@host:31222` would reach `ssh` as a hostname it rejects).
      # An alias moves the port into ssh's own config, which is exactly what
      # nix-darwin's linux-builder does. /etc/ssh/ssh_config already carries
      # `Include /etc/ssh/ssh_config.d/*`, and being system-wide it applies to
      # root — which matters, because the nix-daemon does the SSH, not the user.
      environment.etc."ssh/ssh_config.d/101-nix-linux-builder.conf".text =
        lib.concatMapStrings
          (b: ''
            Host ${aliasOf b}
              HostName 127.0.0.1
              Port ${toString b.port}
              User root
              HostKeyAlias ${aliasOf b}
              IdentityFile ${installedKey}
              IdentitiesOnly yes
              StrictHostKeyChecking accept-new
              UserKnownHostsFile ${knownHosts}
          '')
          builders;

      determinateNix = {
        buildMachines = map
          (b: {
            hostName = aliasOf b;
            inherit (b) system;
            sshUser = "root";
            sshKey = installedKey;
            protocol = "ssh-ng";
            maxJobs = 8;
            speedFactor = 1;

            # Deliberately no "kvm": there is no /dev/kvm in a container, and
            # claiming a feature the builder lacks turns "built somewhere else"
            # into "failed here".
            supportedFeatures = [ "big-parallel" ];

            # null on purpose — the container generates its own host key rather
            # than reusing the well-known insecure one that the VM builder
            # ships, so there is nothing to pin at build time. SSH falls back to
            # the UserKnownHostsFile above, recorded on first connect.
            publicHostKey = null;
          })
          builders;

        # Without this the module only *warns* ("build machines aren't
        # configured") and nothing is delegated. Default is false.
        distributedBuilds = true;

        # Let the builder fetch dependencies from R2 and cache.nixos.org itself.
        # Without it this Mac downloads every input and pushes it over SSH into
        # the container, which is both slower and pointless — the container has
        # the same substituters configured.
        customSettings."builders-use-substitutes" = true;
      };

      # The root nix-daemon opens the SSH connection, and ssh refuses a private
      # key owned by someone else ("bad ownership or modes"). So the key the user
      # generated has to be copied to a root-owned path. This mirrors nixpkgs'
      # own nix-builder profile, which likewise `install`s its generated key into
      # /etc/nix rather than sharing the user's copy.
      #
      # Named linux-builder-ed25519, NOT builder_ed25519: the latter is the
      # hardcoded identity file of Determinate's VM-based builder, and a stale
      # copy of it from a 2024 nix.linux-builder experiment is still lying in
      # /etc/nix on FCX19GT9XR. Reusing the name would have them overwrite each
      # other.
      system.activationScripts.postActivation.text = ''
        # --- Docker Linux builder key -----------------------------------------
        if [ -f '${sourceKey}' ] && [ -f '${sourceKey}.pub' ]; then
          install -m 0600 -o root -g wheel '${sourceKey}'     '${installedKey}'
          install -m 0644 -o root -g wheel '${sourceKey}.pub' '${installedKey}.pub'
        else
          # Loud, not silent: without this key every delegated Linux build fails
          # with a bare "Permission denied (publickey)" and nothing says why.
          echo "linux-builder: no keypair at ${sourceKey}" >&2
          echo "linux-builder: run 'just linux-builder-up' to generate it, then switch again;" >&2
          echo "linux-builder: until then ${installedKey} is missing and Linux builds cannot be delegated." >&2
        fi
      '';
    };
}
