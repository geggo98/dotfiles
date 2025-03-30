-- Automatically load all Lua files in ~/.hammerspoon that match "nix-*.lua"
local configDir = hs.configdir

print("Looking for Nix home-manager modules in: ", configDir)

for file in hs.fs.dir(configDir) do
  -- Pattern: nix_*.lua
  if file:match("^nix%_.*%.lua$") then
    -- Remove the ".lua" extension before requiring the module
    local moduleName = file:sub(1, -5)
    print("Loading Nix home-manager module: ", moduleName)
    require(moduleName)
  end
end
