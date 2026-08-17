{ config, inputs, ... }:
let
  inherit (config.flake.modules) nixos homeManager;
in
{
  # Where `just nixos-deploy ionos-vps` activates. The IPv4 literal rather than
  # a hostname: this box's own DNS is not what we want to depend on when the
  # reason for deploying might be that something on it is broken.
  configurations.nixos.ionos-vps.deployTarget = "root@87.106.149.208";

  configurations.nixos.ionos-vps.module = {
    imports = [
      inputs.disko.nixosModules.disko
      inputs.home-manager.nixosModules.home-manager
      nixos.base
    ];

    # --- Interactive environment ---------------------------------------------
    # The same shell as the workstations: fish with the shared promptInit,
    # starship, atuin, fzf, bat, the plugin set and the abbreviations.
    #
    # `homeManager.shell` and not `homeManager.base`: base pulls in the whole
    # workstation aspect set (vscode, gram, homebrew-adjacent tooling, the AI
    # stack) plus `shell-secrets`, which dereferences sops secrets this host
    # neither has nor should have. Two aspects is the whole ask — fish and nvim.
    #
    # Applied to root because root is the only account here. A dedicated user is
    # the better long-term shape, but adding one now would change how you log in,
    # which is not a thing to bundle into an unrelated change.
    programs.fish.enable = true;
    users.users.root.shell = inputs.nixpkgs.legacyPackages."x86_64-linux".fish;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.root = { pkgs, ... }: {
        imports = [
          homeManager.shell
          homeManager.neovim
        ];

        # The binaries `shell` and `neovim` assume are on PATH. Without them the
        # config loads but misbehaves quietly: nvim prints "gitsigns: git not in
        # path. Aborting setup" and every +l/+ll/+lt abbreviation expands to a
        # command that does not exist.
        #
        # Deliberately NOT `homeManager.packages` (~144 entries — the whole AI
        # toolchain on a 4 GB server), and deliberately not `homeManager.git`:
        # that aspect sets credentialStore = "keychain", which is macOS-only. Git
        # is wanted here as a binary, not as this user's workstation identity.
        home.packages = with pkgs; [
          git # gitsigns, and the +git-* forgit abbreviations
          lsd # +l / +ll / +lla / +llt / +lt
          ugrep # +grep / +grep-tui  (the `ug` binary)
          ripgrep # telescope/live-grep inside nvim
          fd
        ];
        home.stateVersion = "26.05";
      };
    };

    nixpkgs.hostPlatform = "x86_64-linux";

    networking.hostName = "ionos-vps";
    networking.domain = "";

    # --- Disk layout --------------------------------------------------------
    # Measured on the running Ubuntu before conversion, not assumed:
    #   /dev/vda, 120 GB virtio block device, GPT
    #   vda14 bios_grub · vda15 ESP (fat32) · vda16 bls_boot · vda1 ext4 /
    #
    # The machine boots in LEGACY BIOS mode. That is easy to get wrong: an ESP
    # exists and Ubuntu mounts it at /boot/efi, which reads like UEFI — but
    # /sys/firmware/efi is absent, so the firmware is not EFI at all. Ubuntu
    # ships a hybrid cloud image that can boot either way; this host uses the
    # BIOS path. Installing systemd-boot here produces a machine that partitions
    # and installs cleanly and then never comes back from the reboot.
    #
    # Hence: a bios_grub partition and GRUB written to the disk, and no ESP —
    # an unused ESP would only be a second thing to keep consistent. Switching
    # to UEFI later means repartitioning, which is a KVM-console job anyway.
    disko.devices.disk.main = {
      device = "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          # GRUB's stage-2 lives here on a GPT/BIOS system. Without it,
          # grub-install fails ("this GPT partition label contains no BIOS Boot
          # Partition") during the install, not after it.
          bios = {
            size = "1M";
            type = "EF02";
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    # `devices` is deliberately not set here: disko derives it from the EF02
    # partition above and appends /dev/vda itself. Setting it as well yields
    # [ "/dev/vda" "/dev/vda" ] and the grub module rejects it with
    # "You cannot have duplicated devices in mirroredBoots".
    boot.loader.grub = {
      enable = true;
      efiSupport = false;
    };

    # NixOS defaults to 5 s, which is too short here for the one situation the
    # menu exists for. Root's password is locked and PasswordAuthentication is
    # off, so when SSH is broken the *only* way in is picking an older
    # generation — or `e`, append init=/bin/sh — in this menu, driven through
    # the Cloud Panel's KVM console. Measured: 5 s does not survive the console's
    # round-trip latency; the keypresses land at the login prompt of an
    # already-booted system (visible as a row of ^[[B). 30 s costs half a minute
    # on a machine that reboots roughly never and buys a usable rescue path.
    boot.loader.timeout = 30;

    # virtio, because the host is QEMU/KVM: the root filesystem is on a
    # virtio_blk device (/dev/vda). If these are missing from the initrd the
    # machine cannot find its own root and drops to an emergency shell that only
    # the serial console can reach.
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "virtio_net"
      "sd_mod"
      "sr_mod"
    ];

    # --- Network ------------------------------------------------------------
    # DHCP for both families, which is what the machine already does — netplan
    # has dhcp4 and dhcp6 on `en*`, IPv4 arrives as 87.106.149.208/32 with an
    # on-link route to 87.106.149.1, and IPv6 comes from router advertisements
    # (2a01:239:485:8d00::1/128, default via fe80::1).
    #
    # Deliberately NOT a static configuration. Reproducing a /32 with an
    # on-link gateway by hand is exactly the kind of detail that locks you out
    # on first boot, and there is nothing to gain: the addresses are stable
    # because IONOS assigns them, not because the guest asserts them.
    networking.useDHCP = true;
    networking.useNetworkd = true;

    system.stateVersion = "26.05";
  };
}
