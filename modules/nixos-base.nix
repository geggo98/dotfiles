{ ... }:
let
  # Public key material — safe to commit, and exactly what authorized_keys wants.
  #
  # LOAD-BEARING. Nothing carries over from the old filesystem after a
  # nixos-anywhere reinstall, so this list is what stands between you and the
  # Cloud Panel's KVM console. Do not remove an entry without confirming the
  # remaining ones actually work — from the machine you will need them from.
  #
  # The other doors, for when this list is the problem: Tailscale SSH does NOT
  # go through sshd and ignores this list entirely (but its ACL defaults to
  # `check`, i.e. a browser round-trip, so it is an emergency route rather than
  # an unattended one), and the KVM console reaches GRUB. Reaching 10.2.0.203
  # over WireGuard is NOT a separate door in this sense: that is the same sshd
  # and the same list.
  # ONE key, on purpose. Two others were removed on 2026-08-18 — see below for
  # what they were and why keeping them made the survivor pointless.
  rootAuthorizedKeys = [
    # SHA256:YEUc7NtEQhufJSJroPQqWBvEULURYRJSiC9cKWJKgiE — held in 1Password
    # (vault "Homelab") and released by its SSH agent behind Touch ID, so the
    # private half is never a file on any disk anywhere.
    #
    # Depends on something OUTSIDE this repo: the agent only offers that vault
    # because ~/.config/1Password/ssh/agent.toml lists it. That file is
    # 1Password's, not restored by `just switch`, and its absence is the most
    # likely reason a machine with 1Password installed still cannot log in.
    # AGENTS.md carries the symptom and the client-side diagnosis.
    #
    # The trailing comment is free text that sshd ignores; it names the machine
    # by its canonical name (infra/Naming.md). The 1Password ITEM is a separate
    # string and still reads `p-ion-ber-xs56r6 SSH-Key` until renamed there —
    # that is what `ssh-add -l` prints, so do not expect the two to match yet.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA15XU9mL8Qq9aBQdOxoyEnk5Qb3wfxu14yq42LvoHKn p-ion-berlin-xs56r6 (Ionos VPS)"
  ];

  # Removed 2026-08-18, recorded because "why is this gone" is a question that
  # gets asked at exactly the wrong moment:
  #
  #   SHA256:qMz+MVejgC8S6KOgmZ79nJNliOMvJCxcVdEwbFGGRak  stefan@FCX19GT9XR
  #     A plain file at ~/.ssh/id_ed25519, and measured to be the key that
  #     actually authenticated every session up to today. THIS removal is the
  #     entire point of the exercise: while it was authorised, the biometric key
  #     above was decoration — anyone able to read that home directory reached
  #     root without Touch ID, which is precisely the risk the 1Password key was
  #     introduced to close.
  #
  #   SHA256:r6AR7CQY7+VJEP+tFglbyJ3P6kah1L4kQ+zBaiq2tEA  git@gitlab.check24tech.de
  #     A GitLab deploy key inherited from the Ubuntu install and kept only
  #     because it was there. Nothing in this repo used it; a key nobody can
  #     account for is not a fallback, it is an unowned way in.
  #
  # If either is ever wanted back, it is one `git revert` away — but prefer
  # adding a NEW key deliberately over restoring one that was inherited.
in
{
  flake.modules.nixos.base = { config, lib, ... }: {
    # --- Remote access ------------------------------------------------------
    # A cloud VM with no working sshd is a brick that costs a console session to
    # revive, so everything here is oriented at not losing the door.
    services.openssh = {
      enable = true;
      # Tightened relative to the Ubuntu install, which had PermitRootLogin yes
      # AND PasswordAuthentication yes. Key-only root login is the reason the
      # key list above must be right before the first switch, not after.
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
      openFirewall = true;
    };

    users.users.root.openssh.authorizedKeys.keys = rootAuthorizedKeys;

    # Fail the build rather than install a machine nobody can log into. With
    # password auth off and no keys, the only remaining route is the Cloud
    # Panel's KVM console — this turns that outage into an eval error.
    assertions = [
      {
        assertion = rootAuthorizedKeys != [ ];
        message = ''
          nixos-base: root has no authorized SSH keys, and password authentication
          is disabled. Installing this would leave the KVM console as the only way
          in. Add a key to rootAuthorizedKeys in modules/nixos-base.nix.
        '';
      }

      # The keys above are useless if nothing is listening for them. This guards
      # the *activation path*, which is a separate thing from the login: `just
      # nixos-deploy` builds in a local Docker container, pushes the closure to
      # R2, and then activates it with `ssh $deployTarget` — where deployTarget
      # is a public IP. Lose public sshd and the host is not merely awkward to
      # log into, it can no longer be deployed at all, because no workstation
      # here can build x86_64-linux without that container round-trip.
      #
      # Tailscale SSH is not a substitute. tailscaled answers port 22 on the
      # tailnet address in userspace, so what listens there is not sshd, and it
      # runs commands through a login shell — measured to be quiet on this host
      # and to carry `nix copy` fine, but nothing enforces that it stays quiet,
      # and the route used to rescue a host should not depend on a remote
      # control plane. See modules/nixos-tailscale.nix for the detail.
      {
        assertion = config.services.openssh.enable
          && config.services.openssh.listenAddresses == [ ]
          && builtins.elem 22 config.networking.firewall.allowedTCPPorts;
        message = ''
          nixos-base: sshd must stay reachable on 0.0.0.0:22.
            services.openssh.enable         = ${lib.boolToString config.services.openssh.enable}
            services.openssh.listenAddresses = ${toString (builtins.length config.services.openssh.listenAddresses)} entries (expected 0 = wildcard)
            22 in firewall.allowedTCPPorts   = ${lib.boolToString (builtins.elem 22 config.networking.firewall.allowedTCPPorts)}
          `just nixos-deploy` activates over `ssh $deployTarget`, and that is the
          only way this host can be deployed. Without it the remaining route is
          the IONOS KVM console via GRUB.
        '';
      }
    ];

    # Second way in, independent of the network stack: IONOS exposes a serial
    # console through the Cloud Panel, and the Ubuntu install was already running
    # serial-getty on ttyS0. Keeping it means a network misconfiguration is
    # recoverable without a rescue ISO.
    boot.kernelParams = [ "console=ttyS0,115200" "console=tty0" ];
    systemd.services."serial-getty@ttyS0".enable = true;

    networking.firewall.enable = true;

    # --- Nix ----------------------------------------------------------------
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-cache.pub.schwetschke.dev"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10="
      ];

      # Same reasoning as modules/nix-cache.nix, and it matters most here: this
      # host never builds anything itself, it only consumes what a workstation
      # pushed. Nix's 3600 s default would let it remember a 404 from before the
      # push and fall back to building — on the smallest machine we own.
      narinfo-cache-negative-ttl = 60;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # --- Housekeeping -------------------------------------------------------
    time.timeZone = lib.mkDefault "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";
    security.sudo.wheelNeedsPassword = false;
    documentation.nixos.enable = false;
  };
}
