{ ... }:
{
  flake.modules.homeManager.tunnelblick-raycast = { config, ... }: {
    sops.templates."tunnelblick-connect-office-vpn.applescript" = {
      path = "${config.xdg.configHome}/raycast/script_commands/tunnelblick-connect-office-vpn.applescript";
      mode = "0755";
      content = ''
        #!/usr/bin/osascript

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Tunnelblick: Connect Office*
        # @raycast.mode silent
        # @raycast.packageName TunnelBlick
        #
        # Optional parameters:
        # @raycast.icon images/tunnelblick.png
        # @raycast.needsConfirmation false
        #
        # @raycast.description Connect Tunnelblick VPN configurations whose name starts with the office prefix (case-insensitive).

        on toLower(s)
        	return do shell script "printf %s " & quoted form of s & " | tr '[:upper:]' '[:lower:]'"
        end toLower

        on startsWith(theText, thePrefix)
        	set pLen to (length of thePrefix)
        	if pLen = 0 then return true
        	if (length of theText) < pLen then return false
        	return (text 1 thru pLen of theText) is thePrefix
        end startsWith

        on run argv
        	set prefix to "${config.sops.placeholder.office_vpn_prefix}"

        	-- Case-insensitive matching: lowercase both sides.
        	set prefixLower to my toLower(prefix)

        	tell application "Tunnelblick"
        		set cfgNames to (get name of configurations)

        		repeat with cfgName in cfgNames
        			set cfgName to (cfgName as text)

        			if my startsWith(my toLower(cfgName), prefixLower) then
        				connect cfgName
        			end if
        		end repeat
        	end tell

        	return
        end run
      '';
    };
  };
}
