#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title OpenVPN: Scoped Default Route
# @raycast.mode compact
# @raycast.packageName OpenVPN
#
# Optional parameters:
# @raycast.icon ./images/openvpn.png
#
# @raycast.description After connecting with OpenVPN Connect: add a default route scoped to the tunnel interface. OpenVPN Connect runs no up/route-up scripts, so this does by hand what scoped-default-route.sh does for Tunnelblick.

# OpenVPN Connect gives no hook, so find the tunnel ourselves: the utun interface that has a
# private 10.x IPv4 address. Tailscale (100.64/10) and the system utuns (IPv6 only) do not match.
#   ifconfig utun4:   inet 10.8.0.76 --> 10.8.0.76 netmask 0xffffe000
# With "topology subnet" the VPN server is the first host of that network: 10.8.0.1.
found=$(/sbin/ifconfig -a | perl -ne '
  $if = $1 if /^(utun\d+):/;
  if ($if and /^\s+inet (10\.\d+\.\d+\.\d+) --> \S+ netmask 0x([0-9a-f]{8})/) {
    my ($ip, $mask) = ($1, hex $2);
    my $ipn = unpack "N", pack "C4", split /\./, $ip;
    my $gw  = join ".", unpack "C4", pack "N", ($ipn & $mask) + 1;
    print "$if $gw\n";
  }')

if [[ -z "$found" ]]; then
  echo "No utun interface with a 10.x address. Is OpenVPN Connect connected?"
  exit 1
fi
if [[ $(print -r -- "$found" | wc -l) -ne 1 ]]; then
  echo "More than one candidate, not guessing: ${found//$'\n'/; }"
  exit 1
fi

dev=${found%% *}
gw=${found##* }

# "change" when a route is left over from an earlier run; "add" otherwise.
/usr/bin/osascript -e "do shell script \"/sbin/route -n add -net 0.0.0.0/0 -ifscope $dev $gw || /sbin/route -n change -net 0.0.0.0/0 -ifscope $dev $gw\" with administrator privileges" >/dev/null || {
  echo "route failed for $dev via $gw"
  exit 1
}
echo "0.0.0.0/0 via $gw scoped to $dev"
