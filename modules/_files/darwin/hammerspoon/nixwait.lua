-- Copied (not symlinked) by home-manager activation (modules/misc.nix): it must load
-- before the encrypted "Nix Store" volume is mounted, which at login can lag
-- Hammerspoon by several seconds. nix.lua is a symlink into /nix/store.
local target = hs.configdir .. "/nix.lua"
local function ready() return hs.fs.attributes(target) ~= nil end -- stat follows the link

if ready() then
  require("nix")
else
  print("nixwait: " .. target .. " not resolvable yet (/nix not mounted?), waiting")
  local waited, limit = 0, 300
  nixwaitTimer = hs.timer.doEvery(1, function()   -- global: keep the timer from being GC'd
    waited = waited + 1
    if ready() then
      nixwaitTimer:stop(); nixwaitTimer = nil
      print("nixwait: available after " .. waited .. "s, loading")
      require("nix")
    elseif waited >= limit then
      nixwaitTimer:stop(); nixwaitTimer = nil
      hs.alert.show("Hammerspoon: Nix modules not loaded, /nix missing after " .. limit .. "s")
    end
  end)
end
