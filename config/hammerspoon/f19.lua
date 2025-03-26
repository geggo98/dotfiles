-- Define our module (optional style)
local f19 = {}

--------------------------------------------------------------------------------
-- Customize these callback functions for Cmd+F19, Alt+F19, and Shift+F19:
--------------------------------------------------------------------------------
local function doSomethingCmdF19()
    -- Trigger Homerow Search: Command + Alt + Shift + Space
    hs.eventtap.event.newKeyEvent({"cmd", "alt", "shift"}, "space", true):post()
    hs.eventtap.event.newKeyEvent({"cmd", "alt", "shift"}, "space", false):post()
end

local function doSomethingAltF19()
    -- Trigger Homerow: Command + Shift + Space
    hs.eventtap.event.newKeyEvent({"cmd", "shift"}, "space", true):post()
    hs.eventtap.event.newKeyEvent({"cmd", "shift"}, "space", false):post()
end

local function doSomethingCmdAltF19()
    -- Trigger Homerow Scroll: Command + Ctrl + Alt + Shift + J
    hs.eventtap.event.newKeyEvent({"cmd", "ctrl", "alt", "shift"}, "j", true):post()
    hs.eventtap.event.newKeyEvent({"cmd", "ctrl", "alt", "shift"}, "j", false):post()
end

local function doSomethingShiftF19()
    -- Trigger Ace Jump: Ctrl + ";"
    hs.eventtap.event.newKeyEvent({"ctrl"}, ";", true):post()
    hs.eventtap.event.newKeyEvent({"ctrl"}, ";", false):post()
end

--------------------------------------------------------------------------------
-- Internal variables and helpers
--------------------------------------------------------------------------------
f19.isF19Down = false
f19.didPressOtherKey = false
f19.hyperActive = false

-- List of modifiers to hold down for the "hyper" effect:
f19.hyperMods = { "cmd", "alt", "ctrl", "shift" }

-- Press the hyper modifiers (called once user presses another key while F19 is held).
local function pressHyper()
  for _, mod in ipairs(f19.hyperMods) do
    hs.eventtap.event.newKeyEvent(mod, true):post()
  end
  f19.hyperActive = true
end

-- Release the hyper modifiers.
local function releaseHyper()
  if f19.hyperActive then
    for _, mod in ipairs(f19.hyperMods) do
      hs.eventtap.event.newKeyEvent(mod, false):post()
    end
    f19.hyperActive = false
  end
end

-- Send Ctrl+[
local function sendVimEscape()
  hs.eventtap.event.newKeyEvent({"ctrl"}, "[", true):post()
  hs.eventtap.event.newKeyEvent({"ctrl"}, "[", false):post()
end

--------------------------------------------------------------------------------
-- Main eventtap to watch for key presses and releases
--------------------------------------------------------------------------------
f19.eventtap = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
  function(event)
    local keyCode = event:getKeyCode()
    local flags   = event:getFlags()
    local isDown  = (event:getType() == hs.eventtap.event.types.keyDown)

    -- Hammerspoon keycodes table for reference:
    --   https://www.hammerspoon.org/docs/hs.keycodes.html#map
    local f19KeyCode = hs.keycodes.map["F19"]
    if keyCode == f19KeyCode then
      -- We have an F19 event
      if isDown then
        -- Check modifiers exactly for Cmd+F19, Alt+F19, Shift+F19, or Cmd+Alt+F19
        local isCmdOnly   = (flags.cmd and not flags.alt and not flags.ctrl and not flags.shift)
        local isAltOnly   = (flags.alt and not flags.cmd and not flags.ctrl and not flags.shift)
        local isShiftOnly = (flags.shift and not flags.cmd and not flags.alt and not flags.ctrl)
        local isCmdAltOnly = (flags.cmd and flags.alt and not flags.ctrl and not flags.shift)

        if isCmdOnly then
          -- Cmd+F19
          doSomethingCmdF19()
          return true -- We handled it; don't pass to macOS
        elseif isAltOnly then
          -- Alt+F19
          doSomethingAltF19()
          return true
        elseif isShiftOnly then
          -- Shift+F19
          doSomethingShiftF19()
          return true
        elseif isCmdAltOnly then
          -- Cmd+Alt+F19
          doSomethingCmdAltF19()
          return true
        else
          -- No modifiers or multiple modifiers
          if next(flags) == nil then
            -- NO modifiers -> Potential "hyper" or "vim escape"
            f19.isF19Down = true
            f19.didPressOtherKey = false
            return true
          end
          -- If multiple modifiers, do nothing special (pass through or block, up to you).
          -- return false to let macOS see it if you prefer.
        end
      else
        -- Key up for F19
        if f19.isF19Down then
          -- If user never pressed a second key, send Ctrl+[
          if not f19.didPressOtherKey then
            sendVimEscape()
          end
          -- Always release the hyper keys (if pressed)
          releaseHyper()
          -- Reset state
          f19.isF19Down = false
        end
        return true
      end
    else
      -- Some other key is being pressed or released
      if isDown and f19.isF19Down and not f19.didPressOtherKey then
        -- We pressed another key while F19 is held -> "hyper" mode
        pressHyper()
        f19.didPressOtherKey = true
      end
    end

    -- By default, don't block events that aren't F19
    return false
  end
)

-- Start listening
f19.eventtap:start()

return f19