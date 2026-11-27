#!/bin/zsh
# OpenVPN route-up script: add a default route that is scoped to the tunnel interface.
#
# Why: the VPN profile keeps the local network and the normal default route untouched,
# but tools that bind to the tunnel interface (-ifscope) still need a default route there.
# Equivalent to the manual command:
#   sudo route -n add -net 0.0.0.0/0 -ifscope utun4 10.8.0.1
#
# OpenVPN sets these variables for route-up scripts (needs "script-security 2"):
#   dev                 tunnel interface, e.g. utun4 (the number changes between connections)
#   route_vpn_gateway   gateway inside the tunnel, e.g. 10.8.0.1
#
# The route disappears with the interface, so there is no down script.
set -u

if [[ -z "${dev:-}" || -z "${route_vpn_gateway:-}" ]]; then
  print -u2 "scoped-default-route: dev='${dev:-}' route_vpn_gateway='${route_vpn_gateway:-}' missing; no route added"
  exit 1
fi

# "add" fails with "File exists" when a route is left over; fall back to "change".
if ! /sbin/route -n add -net 0.0.0.0/0 -ifscope "$dev" "$route_vpn_gateway"; then
  /sbin/route -n change -net 0.0.0.0/0 -ifscope "$dev" "$route_vpn_gateway" || exit 1
fi
print -u2 "scoped-default-route: 0.0.0.0/0 via $route_vpn_gateway scoped to $dev"
