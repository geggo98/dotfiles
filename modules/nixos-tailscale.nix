# Tailscale, including Tailscale SSH, for NixOS hosts.
#
# This is the "own devices" tier of a three-tier access model (see
# modules/nixos-wireguard-home.nix for the other two): the tailnet reaches this
# host from anywhere, the home LAN reaches it over WireGuard, and the public
# internet gets sshd and nothing else.
#
# NOT A DEPLOY TRANSPORT — this is the important thing to know before pointing
# `deployTarget` at a tailnet name. tailscaled claims TCP/22 on the tailnet
# address in userspace (gVisor netstack) and never hands those packets to the
# kernel, so what answers there is Tailscale's own SSH server, not sshd. That
# server injects data into the exec channel, which corrupts nix's
# `nix-store --serve` protocol:
#
#     error: 'nix-store --serve' protocol mismatch from 'root@…'
#
# tailscale/tailscale#14093 and #14167, both still open as of 2026-08-18.
# `just nixos-deploy` is unaffected — it activates with a plain command exec and
# realises the closure from R2 — but `just cache-seed-remote` (ssh-ng://) and a
# `nixos-anywhere` reinstall would both break over it.
{ ... }:
{
  flake.modules.nixos.tailscale = { ... }: {
    services.tailscale = {
      enable = true;

      # UDP/41641 inbound, so peers can reach this host directly instead of
      # relaying through DERP. Not mandatory — Tailscale works without it, just
      # indirectly and with more latency — but this host has a static public
      # address, so it is a cheap win. The IONOS provider firewall needs the
      # same port opened by hand; it has no API, so infra/src/inventory.ts
      # records what was set there.
      openFirewall = true;

      # No subnet router and no exit node for now. Keeping this at "none" leaves
      # IP forwarding off and, just as importantly, leaves
      # networking.firewall.checkReversePath at its strict default — see below.
      useRoutingFeatures = "none";

      # extraSetFlags, NOT extraUpFlags. Verified against the pinned nixpkgs:
      # extraUpFlags is interpolated only inside tailscaled-autoconnect.service
      # (tailscale.nix:218), and that unit is `mkIf (cfg.authKeyFile != null)`
      # (:183). This repo is PUBLIC, so no auth key is committed and that unit
      # never exists — which would make extraUpFlags dead code. extraSetFlags
      # runs unconditionally via tailscaled-set.service (:237).
      #
      # The practical consequence of getting this wrong is delayed and quiet:
      # everything works until a `tailscale logout` or a reinstall, and then
      # --ssh is simply not set any more.
      extraSetFlags = [
        "--ssh"

        # A headless server should not make its own name resolution depend on a
        # remotely reconfigurable control plane — "Override local DNS" is a
        # switch in the admin console, not in this repo. Being *addressed* by
        # MagicDNS still works; this host just does not consume tailnet DNS.
        "--accept-dns=false"

        # Nothing here should silently acquire routes from other nodes.
        "--accept-routes=false"
      ];
    };

    # `tailscale set` fails while the backend is still in NeedsLogin, so on the
    # very first switch — before anyone has run `tailscale up` — this oneshot
    # unit fails once. Harmless, but a red unit invites someone to "fix" it in
    # the wrong direction, so let it retry until the node is authenticated.
    systemd.services.tailscaled-set = {
      serviceConfig.Restart = "on-failure";
      serviceConfig.RestartSec = 30;
      unitConfig.StartLimitIntervalSec = 0;
    };

    # Tier 3: the tailnet. Deliberately an explicit (currently empty) allow-list
    # rather than `networking.firewall.trustedInterfaces = [ "tailscale0" ]`.
    # Blanket trust would expose every future service that happens to bind
    # 0.0.0.0 to the whole tailnet, with nothing in the configuration recording
    # that it did. The tailnet ACL already decides *who* may reach this node;
    # a second, invisible copy of that policy would only drift.
    #
    # Tailscale SSH is deliberately absent here and CANNOT be listed: it is
    # answered in userspace and never traverses this firewall at all. That also
    # means the firewall cannot switch it off — `--ssh` is the only control.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ ];

    # checkReversePath is left UNSET on purpose. tailscale.nix:259 defines it as
    # `mkIf (useRoutingFeatures == "client" || == "both") "loose"` — an ordinary
    # definition, not mkDefault. Setting it here as well would turn any future
    # move to "client"/"both" into an option *conflict* (an eval error), not a
    # merge. Strict is correct for the current shape: tailscaled's fwmark and
    # policy routing satisfy `-m rpfilter --validmark`.
  };
}
