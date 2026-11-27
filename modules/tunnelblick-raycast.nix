{ ... }:
{
  flake.modules.homeManager.tunnelblick-raycast = { config, ... }:
    let
      # Name suffix that marks the full-tunnel copy of the office profile, e.g.
      # "<office prefix> ... full-tunnel". Matching is case-insensitive.
      fullTunnelMarker = "full-tunnel";

      # AppleScript for one Raycast command. `connectFull` selects which profiles the
      # command connects; the opposite variant gets disconnected first.
      mkScript = { title, description, connectFull }: ''
        #!/usr/bin/osascript

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title ${title}
        # @raycast.mode silent
        # @raycast.packageName TunnelBlick
        #
        # Optional parameters:
        # @raycast.icon images/tunnelblick.png
        # @raycast.needsConfirmation false
        #
        # @raycast.description ${description}

        on toLower(s)
        	return do shell script "printf %s " & quoted form of s & " | tr '[:upper:]' '[:lower:]'"
        end toLower

        on startsWith(theText, thePrefix)
        	set pLen to (length of thePrefix)
        	if pLen = 0 then return true
        	if (length of theText) < pLen then return false
        	return (text 1 thru pLen of theText) is thePrefix
        end startsWith

        on isFullTunnel(lowerName, marker)
        	return lowerName contains marker
        end isFullTunnel

        on run argv
        	set prefix to "${config.sops.placeholder.office_vpn_prefix}"
        	set marker to "${fullTunnelMarker}"
        	set wantFull to ${if connectFull then "true" else "false"}

        	-- Case-insensitive matching: lowercase both sides.
        	set prefixLower to my toLower(prefix)

        	tell application "Tunnelblick"
        		set cfgNames to (get name of configurations)

        		-- Pass 1: disconnect the other variant, so only one office tunnel is up.
        		repeat with cfgName in cfgNames
        			set cfgName to (cfgName as text)
        			set lowerName to my toLower(cfgName)
        			if my startsWith(lowerName, prefixLower) and (my isFullTunnel(lowerName, marker)) is not wantFull then
        				disconnect cfgName
        			end if
        		end repeat

        		-- Pass 2: connect the requested variant.
        		repeat with cfgName in cfgNames
        			set cfgName to (cfgName as text)
        			set lowerName to my toLower(cfgName)
        			if my startsWith(lowerName, prefixLower) and (my isFullTunnel(lowerName, marker)) is wantFull then
        				connect cfgName
        			end if
        		end repeat
        	end tell

        	return
        end run
      '';
    in
    {
      sops.templates."tunnelblick-connect-office-vpn.applescript" = {
        path = "${config.xdg.configHome}/raycast/script_commands/tunnelblick-connect-office-vpn.applescript";
        mode = "0755";
        content = mkScript {
          title = "Tunnelblick: Connect Office";
          description = "Connect the office VPN (split tunnel, local network stays local). Disconnects the full-tunnel variant first.";
          connectFull = false;
        };
      };

      sops.templates."tunnelblick-connect-office-vpn-full.applescript" = {
        path = "${config.xdg.configHome}/raycast/script_commands/tunnelblick-connect-office-vpn-full.applescript";
        mode = "0755";
        content = mkScript {
          title = "Tunnelblick: Connect Office (Full Tunnel)";
          description = "Connect the office VPN with all traffic in the tunnel. Disconnects the split-tunnel variant first.";
          connectFull = true;
        };
      };
    };
}
