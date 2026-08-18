{ ... }:
let
  # Public key material — safe to commit, and exactly what authorized_keys wants.
  #
  # These are LOAD-BEARING. After nixos-anywhere reboots the machine, this list
  # is the only thing standing between you and the Cloud Panel's KVM console:
  # nothing carries over from the old filesystem. Do not remove an entry without
  # confirming the remaining ones actually work.
  rootAuthorizedKeys = [
    # SHA256:YEUc7NtEQhufJSJroPQqWBvEULURYRJSiC9cKWJKgiE — held in 1Password
    # (vault "Homelab") and released by its SSH agent behind Touch ID, so the
    # private half is never a file on any disk. This is the key this host is
    # meant to be reached with; the two below are the pre-existing ones and are
    # kept only until this one is proven from BOTH workstations.
    #
    # Requires the agent to expose that vault — ~/.config/1Password/ssh/agent.toml
    # lists it. That file is not managed by this repo (it is 1Password's, and it
    # lives outside the flake), which is worth remembering when a new machine
    # cannot log in despite having 1Password installed.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA15XU9mL8Qq9aBQdOxoyEnk5Qb3wfxu14yq42LvoHKn p-ion-ber-xs56r6 (Ionos VPS)"

    # The two below were copied verbatim from the running Ubuntu before the
    # NixOS conversion.
    #
    # SHA256:qMz+MVejgC8S6KOgmZ79nJNliOMvJCxcVdEwbFGGRak — a plain file at
    # ~/.ssh/id_ed25519 on FCX19GT9XR. Measured to be the key that actually
    # authenticates today. While it is here the 1Password key above is
    # decoration: anyone who can read that home directory gets in without Touch
    # ID. Removing it is the actual security gain, and the only removal planned.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDfDRtjeP6ihkQHraLor019i9dVcDdeBgbdwYPXuFpv3 stefan@FCX19GT9XR"
    # SHA256:r6AR7CQY7+VJEP+tFglbyJ3P6kah1L4kQ+zBaiq2tEA — a GitLab deploy key,
    # kept because it was there. Probably not an interactive way back in; the
    # second workstation (DKL6GDJ7X1) is deliberately NOT added here, since that
    # would be a change rather than a faithful carry-over. Worth adding on
    # purpose if a single-laptop dependency is not acceptable.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBEh+/FqTXFLlhaIhR3RolOL+viECyVRJazrfpYp1yUk git@internal-git-host"
  ];
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
      # Tailscale SSH does NOT substitute for this. tailscaled answers port 22
      # on the tailnet address in userspace, so what listens there is not sshd —
      # which is also why nix's `nix-store --serve` protocol breaks over it
      # (tailscale/tailscale#14093, #14167, both open). `just cache-seed-remote`
      # would go with it.
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
