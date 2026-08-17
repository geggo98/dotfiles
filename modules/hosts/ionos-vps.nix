{ config, inputs, ... }:
let
  inherit (config.flake.modules) nixos;
in
{
  configurations.nixos.ionos-vps.module = {
    imports = [
      inputs.disko.nixosModules.disko
      nixos.base
    ];

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
