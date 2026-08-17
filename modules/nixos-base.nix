{ ... }:
let
  # The keys currently in /root/.ssh/authorized_keys on the IONOS VPS, copied
  # verbatim from the running Ubuntu before the NixOS conversion. Public key
  # material — safe to commit, and exactly what authorized_keys wants.
  #
  # These are LOAD-BEARING. After nixos-anywhere reboots the machine, this list
  # is the only thing standing between you and the Cloud Panel's KVM console:
  # nothing carries over from the old filesystem. Do not remove an entry without
  # confirming the remaining ones actually work.
  rootAuthorizedKeys = [
    # SHA256:qMz+MVejgC8S6KOgmZ79nJNliOMvJCxcVdEwbFGGRak
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
  flake.modules.nixos.base = { lib, ... }: {
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
    assertions = [{
      assertion = rootAuthorizedKeys != [ ];
      message = ''
        nixos-base: root has no authorized SSH keys, and password authentication
        is disabled. Installing this would leave the KVM console as the only way
        in. Add a key to rootAuthorizedKeys in modules/nixos-base.nix.
      '';
    }];

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
