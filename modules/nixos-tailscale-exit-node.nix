# Makes a NixOS host CAPABLE of being a Tailscale exit node / subnet router.
#
# Split out from modules/nixos-tailscale.nix on purpose: importing this aspect
# is the switch. Every other host that imports `nixos.tailscale` keeps IP
# forwarding off, which is the right default for a machine that only wants to
# be reachable over the tailnet.
#
# ACTIVATION IS TWO-STAGE, and the first stage lives here entirely:
#
#   1. This module — forwarding on, UDP GRO tuned, AND the advertisement
#      itself via extraSetFlags below. `just nixos-deploy <host>`.
#   2. The tailnet — *approving* the advertised route in the admin console
#      (Machines -> the node -> Edit route settings). Not expressible in this
#      repo: that is state in Tailscale's control plane, not on the machine.
#
# Measured on p-ion-berlin-xs56r6 on 2026-08-19, and worth knowing before
# reading further: stage 2a has ALREADY been done by hand and nothing in this
# repo records it. `tailscale debug prefs` reports
#     "AdvertiseRoutes": [ "0.0.0.0/0", "::/0" ]
# while `tailscale exit-node list` from the workstation lists only the two
# nas-aleuten nodes. So the host advertises and the tailnet has not accepted —
# and tailscaled's own health check says why:
#     "Subnet routing is enabled, but IP forwarding is disabled."
#
# That hand-made advertisement is runtime state in
# /var/lib/tailscale/tailscaled.state, and a `nixos-anywhere` reinstall — the
# documented recovery path for this host — would NOT restore it. So the
# extraSetFlags entry below is not merely tidiness: it is what stops the
# capability from quietly disappearing at exactly the moment someone is
# rebuilding the machine under pressure. From here on the two agree, and the
# declarative one wins on a reinstall.
{ ... }:
{
  flake.modules.nixos.tailscale-exit-node =
    { config, lib, pkgs, ... }:
    let
      # Tailscale's tuning applies to the interface carrying the DEFAULT ROUTE,
      # not to tailscale0 — the aggregation happens on the encrypted UDP flow
      # arriving from the internet, before tailscaled decrypts it. Resolved at
      # runtime rather than hardcoded to "ens6": a hardcoded name that stops
      # matching produces a unit that succeeds while doing nothing, which is the
      # failure mode this repository refuses everywhere else.
      #
      # writeShellApplication and not a zsh script (the repo default) for the
      # reason CLAUDE.md carves out: shellcheck runs over the source, `set -euo
      # pipefail` is injected, and `ethtool` resolves to a pinned store path.
      tuneUdpGro = pkgs.writeShellApplication {
        name = "tailscale-tune-udp-gro";
        runtimeInputs = [ pkgs.iproute2 pkgs.ethtool ];
        text = ''
          # `ip route get` and not `ip route show default`: it answers with the
          # interface actually chosen for a real destination, which is what the
          # kernel will use for exit-node traffic. Both families, because the
          # uplink for one is not necessarily the uplink for the other — on
          # p-ion-berlin-xs56r6 they are both ens6, but that is a fact about
          # this host, not about the option.
          #
          # `ip route get` honours policy routing, so on a host that also *uses*
          # an exit node this would answer tailscale0 (table 52 gains a default
          # route, and `ip rule` consults it at priority 5270 before main). That
          # is not the case here — useRoutingFeatures is "server", not "client",
          # --accept-routes=false, and ExitNodeID is empty — and if it ever
          # becomes the case, ethtool fails on the TUN device and the unit goes
          # red rather than tuning the wrong interface.
          #
          # BASH_REMATCH and not the perl one-liner the style guide prefers.
          # That preference exists because BSD and GNU userlands disagree on
          # macOS, which cannot happen inside a pinned Linux closure — whereas
          # putting perl in runtimeInputs to run one regex would add it to the
          # closure of the 4 GB host whose path count was deliberately cut from
          # ~9000 to 941. CLAUDE.md names BASH_REMATCH as the sanctioned
          # fallback where there is no named-capture form.
          declare -A seen=()
          devs=()
          for target in 8.8.8.8 2001:4860:4860::8888; do
            # matches:  8.8.8.8 via 87.106.149.1 dev ens6 src 87.106.149.208 uid 0
            #             ->  BASH_REMATCH[1] == "ens6"
            line=$(ip -o route get "$target" 2>/dev/null) || continue
            [[ $line =~ [[:space:]]dev[[:space:]]+([^[:space:]]+) ]] || continue
            dev=''${BASH_REMATCH[1]}
            # A plain `[[ -v seen[$dev] ]] && continue` would be the shorter
            # spelling and is safe here, but only after reasoning about how
            # `set -e` treats a failing left-hand side of an && list. An `if`
            # needs no such reasoning.
            if [ -z "''${seen[$dev]:-}" ]; then
              seen[$dev]=1
              devs+=("$dev")
            fi
          done

          if [ ''${#devs[@]} -eq 0 ]; then
            echo "no default route on either family — refusing to guess an uplink" >&2
            exit 1
          fi

          for dev in "''${devs[@]}"; do
            # Exactly what tailscale.com/s/ethtool-config-udp-gro prescribes.
            # Verified on this host that neither feature is reported [fixed] by
            # the virtio_net driver, so both are actually settable:
            #   rx-gro-list: off   rx-udp-gro-forwarding: off
            # A [fixed] feature would make ethtool exit non-zero here, which is
            # wanted — a silently ineffective tuning is worse than a red unit.
            echo "tuning $dev: rx-udp-gro-forwarding on, rx-gro-list off"
            ethtool -K "$dev" rx-udp-gro-forwarding on rx-gro-list off
          done
        '';
      };
    in
    {
      # --- IP forwarding ------------------------------------------------------
      # `useRoutingFeatures = "server"` and NOT a hand-written boot.kernel.sysctl.
      # Read against the pinned nixpkgs (tailscale.nix:252), the option expands to
      # exactly two definitions and nothing else:
      #
      #   boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = mkOverride 97 true;
      #   boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = mkOverride 97 true;
      #
      # so it is not a bigger hammer than the manual route — it is the same
      # hammer with a name, and it keeps the checkReversePath relationship in one
      # place (see modules/nixos-tailscale.nix, which leaves that option unset so
      # a later move to "client"/"both" merges instead of erroring).
      #
      # Both families covered. Note net.ipv4.ip_forward, which is what tailscaled's
      # health check reads, is the SAME kernel variable as
      # net.ipv4.conf.all.forwarding — not a second knob to set. Measured on the
      # host: /proc/sys/net/ipv4/ip_forward and
      # /proc/sys/net/ipv4/conf/all/forwarding both read 0 today.
      #
      # "server" and not "both": "both" would additionally relax
      # checkReversePath to "loose", which is what a host needs when it *uses*
      # someone else's exit node (return packets arrive on tailscale0 whose
      # reverse path is the uplink). Nothing here wants that, and strict is
      # correct for the forwarding direction: packets from the tailnet arrive on
      # tailscale0 with source 100.64.0.0/10, and `ip rule` sends exactly that
      # lookup to table 52, which holds a per-peer route out of tailscale0.
      services.tailscale.useRoutingFeatures = "server";

      # --- The advertisement itself -------------------------------------------
      # `extraSetFlags` is a listOf str, so this concatenates with the base list
      # in modules/nixos-tailscale.nix rather than replacing it — the --ssh,
      # --accept-dns=false and --accept-routes=false set there all survive.
      #
      # It belongs in THIS aspect and not the shared one: advertising a default
      # route is a property of the one host that should carry traffic, and every
      # other NixOS host importing `nixos.tailscale` must keep quiet.
      #
      # Advertising is not the same as being used. The route still has to be
      # approved in the admin console, and clients still have to select the node
      # explicitly. Until both happen this flag changes nothing observable —
      # which is why it is safe to carry ahead of that decision.
      #
      # TAKING IT BACK NEEDS A FLAG, NOT A DELETION, and the trap is worth
      # spelling out because the intuitive move is the wrong one. `tailscale set
      # --help` states it plainly: "Only settings explicitly mentioned will be
      # set. There are no default values." So deleting this line stops *asking*
      # for the advertisement while tailscaled happily keeps the one it already
      # has — the node goes on offering itself as an exit node, and nothing in
      # this repository says so any more. That is the same class of silent
      # divergence the hand-set state above created in the first place.
      #
      # To withdraw it, change the flag to its negative form for one deploy:
      #     services.tailscale.extraSetFlags = [ "--advertise-exit-node=false" ];
      # then remove the module import once the node has stopped advertising.
      services.tailscale.extraSetFlags = [ "--advertise-exit-node" ];

      # --- The IPv6 trap this deliberately steps around -----------------------
      # There is a second, tempting way to enable IPv6 forwarding: systemd-networkd's
      # own `IPv6Forwarding=` (networkd.conf, or per-link). DO NOT USE IT HERE.
      # systemd.network(5) on systemd 260, verbatim, under IPv6AcceptRA=:
      #
      #   "When IPv6SendRA=, IPv6Forwarding=, or IPMasquerade= is enabled, this
      #    feature is disabled by default […] Note, IPv6Forwarding= may be
      #    indirectly enabled when the global setting with the same name is
      #    enabled"
      #
      # i.e. telling networkd the host is a router makes networkd stop accepting
      # Router Advertisements. This host's entire IPv6 configuration depends on
      # them: measured on 2026-08-19, `net.ipv6.conf.ens6.accept_ra = 0` because
      # networkd runs the RA client in USERSPACE, the default route is
      # `default via fe80::1 dev ens6 proto ra … expires 1634sec`, and the
      # address 2a01:239:485:8d00::1/128 is `dynamic noprefixroute` with
      # `valid_lft 421sec` — DHCPv6, which the RA's M flag is what starts.
      # Everything about IPv6 here has a lease measured in minutes.
      #
      # The sysctl route above does not trigger that branch: networkd keys the
      # default off its OWN IPv6Forwarding= setting, which stays unset, and
      # correspondingly does not touch net.ipv6.conf.<iface>.forwarding
      # ("If none of them are specified, the sysctl option will not be changed").
      #
      # Pinning IPv6AcceptRA explicitly is the belt to that braces. It is a no-op
      # against today's behaviour (the default is already true) and costs one
      # line; what it buys is that nobody can turn IPv6 off on this machine as a
      # side effect of enabling forwarding somewhere else. mkIf at the `networks`
      # level and not deeper, because a bare
      # `networks."99-ethernet-default-dhcp".networkConfig = {}` would still
      # CREATE that network file — with no [Match] section, matching every
      # interface — on a host that had useDHCP off.
      systemd.network.networks = lib.mkIf
        (config.networking.useDHCP && config.networking.useNetworkd)
        {
          "99-ethernet-default-dhcp".networkConfig.IPv6AcceptRA = true;
        };

      # --- UDP GRO forwarding -------------------------------------------------
      # tailscaled asks for this in its own health output:
      #   "UDP GRO forwarding is suboptimally configured on ens6, UDP forwarding
      #    throughput capability will increase with a configuration change."
      #
      # A systemd oneshot rather than a systemd .link file, and the reason is the
      # one that matters on a host whose fallback is a KVM console: .link files
      # are applied by udev's net_setup_link builtin at device-add time, and
      # `nixos-rebuild switch` does not re-trigger net devices. A .link change
      # would therefore report success and take effect at the next REBOOT — the
      # one operation `just nixos-deploy`'s rollback timer cannot cover, because
      # transient units do not survive one. Replacing 99-default.link for this
      # interface would also mean restating its NamePolicy/MACAddressPolicy,
      # since only the first matching .link file applies.
      #
      # (systemd 260 does have the settings, and nixpkgs whitelists them —
      # linkConfig.GenericReceiveOffloadUDPForwarding and
      # .GenericReceiveOffloadList, both "Added in version 260", mapping 1:1 onto
      # the two ethtool flags. They were checked and rejected for the reason
      # above, not overlooked. If NixOS ever triggers udev for net devices on
      # switch, they are the better home.)
      #
      # Requires Tailscale >= 1.54 and Linux >= 6.2; this host runs 1.98.5 on
      # 6.18.39.
      #
      # NOT bound to a .device unit. ethtool offload flags survive link down/up
      # and are lost only when the netdev is destroyed and recreated — on a
      # virtio guest, at reboot — which `wantedBy = multi-user.target` already
      # covers. A device binding would buy driver-reload coverage at the price of
      # hardcoding the interface name in a place where a mismatch is silent.
      # If the driver is ever reloaded by hand: `systemctl restart tailscale-udp-gro`.
      systemd.services.tailscale-udp-gro = {
        description = "Tune UDP GRO forwarding on the uplink for Tailscale";
        # network-online, because the script resolves the uplink from the default
        # route and there is none before networkd has configured the link.
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe tuneUdpGro;
        };
      };

      # --- Firewall: nothing to do, and that is a measured claim, not a shrug --
      # `networking.firewall.filterForward` is NOT set here, for two reasons.
      #
      # It could not be: firewall.nix:324 asserts `filterForward ->
      # networking.nftables.enable`, and this host runs the iptables backend
      # (evaluated: networking.nftables.enable = false). Setting it fails the
      # build.
      #
      # And it need not be: forwarded packets are not dropped today. Measured on
      # the host with `iptables-save`, the FORWARD chain is
      #     :FORWARD ACCEPT [0:0]
      #     -A FORWARD -j ts-forward
      # with tailscaled's own chain doing the policy (mark packets from
      # tailscale0, accept marked, drop 100.64.0.0/10 heading back out
      # tailscale0), and `-A ts-postrouting -m mark --mark 0x40000/0xff0000 -j
      # MASQUERADE` in nat/POSTROUTING supplying the SNAT an exit node needs.
      # NixOS' own nixos-fw lives on INPUT only. So the sysctl above is genuinely
      # the single missing piece.
      #
      # WHAT THIS DOES OPEN, and it is not obvious: with forwarding on, a tailnet
      # client that selects this exit node sends ALL its traffic here, INCLUDING
      # RFC1918 destinations, and this host has a route for 10.2.0.0/24 and
      # fd11:1b58:53c0::/64 through wg0 to the home LAN (modules/nixos-wireguard-home.nix).
      # ts-forward accepts anything marked from tailscale0, so such packets reach
      # the FRITZ!Box network, SNATed to 10.2.0.203. That is a *feature* if the
      # intent is a subnet router; it is a surprise if the intent was only "give
      # me a fixed source IP". The client-side control is
      # `--exit-node-allow-lan-access` (which keeps the client's own LAN local);
      # the host-side control would be an explicit
      #     ip46tables -I FORWARD 1 -i tailscale0 -o wg0 -j DROP
      # in networking.firewall.extraCommands. Deliberately not added unmeasured —
      # decide it, do not inherit it.
    };
}
