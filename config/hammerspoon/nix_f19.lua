-- Define our module (optional style)
local f19 = {}

-- Specification:
-- - If debug mode is set, print log messages, otherwise mute them
-- - If the the moeule is not active, pass through all keys. The use can use this to temporarily deactivate the module from the Hammerspoon console
-- - If the user presses and releases the F19 key without any other key, the system should act as if the user pressed the escaoe key
-- - If the user presses the F19 key with anothe key, the system shoudl act as if the F19 key is the "hyper" modifier  (Cmd+Ctrl+Alt+Shift) for the other key.
-- - If the user presses a modifier with the F19 key (e.g., Alt+F19), this should be passed through to the system.

--------------------------------------------------------------------------------
-- Internal variables and helpers
--------------------------------------------------------------------------------
f19.isDebug = true
f19.isActive = true
f19.isF19Down = false
f19.didPressOtherKey = false
f19.hyperActive = false


-- List of modifiers to hold down for the "hyper" effect:
f19.hyperMods = { "cmd", "alt", "ctrl", "shift" }

local function debug(...)
    if f19.isDebug then
        print("[nix_f19] ", ...)
    end
end

-- Press the hyper modifiers (called once user presses another key while F19 is held).
local function pressHyper()
    debug(">>> pressHyper")
    for _, mod in ipairs(f19.hyperMods) do
        hs.eventtap.event.newKeyEvent(mod, true):post()
    end
    debug("<<< pressHyper")
end

-- Release the hyper modifiers.
local function releaseHyper()
    debug(">>> releaseHyper")
    if f19.hyperActive then
        for _, mod in ipairs(f19.hyperMods) do
            hs.eventtap.event.newKeyEvent(mod, false):post()
        end
        f19.hyperActive = false
    end
    debug("<<< releaseHyper")
end

-- Send Esc
local function sendEscape()
    debug(">>> sendEscape")
    hs.eventtap.event.newKeyEvent({}, "escape", true):post()
    hs.eventtap.event.newKeyEvent({}, "escape", false):post()
    debug("<<< sendEscape")
end
--------------------------------------------------------------------------------
-- Main eventtap to watch for key presses and releases
--------------------------------------------------------------------------------
f19.eventtap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
    function(event)
        if (not f19.isActive) then
            return false
        end

        local keyCode    = event:getKeyCode()
        local flags      = event:getFlags()
        local isFlags = (flags.cmd or flags.alt or flags.ctrl or flags.shift)
        local isDown     = (event:getType() == hs.eventtap.event.types.keyDown)
        local isUp       = (event:getType() == hs.eventtap.event.types.keyUp)
        local f19KeyCode = hs.keycodes.map["f19"]

        -- debug("nix_f19: ", hs.inspect(f19))
        if keyCode == f19KeyCode then
            -- We have an F19 event
            if isDown then
                -- Check if there are no modifiers
                if not isFlags then
                    debug("-> f19, no modfifers")
                    -- F19 pressed with no modifiers -> Potential "hyper" or "vim escape"
                    f19.isF19Down = true
                    f19.didPressOtherKey = false
                    return true -- Block so macOS doesn't see plain F19
                else
                    debug("-> f19, with modifiers: pass through")
                    -- F19 with any modifiers: pass through
                    f19.didPressOtherKey = false
                    return false
                end
            elseif isUp then
                -- Key up for F19
                if f19.isF19Down then
                    debug("-> f19 up, after other action")
                    -- If user never pressed a second key, send escape
                    if not f19.didPressOtherKey then
                        sendEscape()
                    end
                    -- Always release the hyper keys (if pressed)
                    if f19.hyperActive then
                        releaseHyper()
                        f19.hyperActive = false
                    end
                    -- Reset state
                    f19.isF19Down = false
                    f19.didPressOtherKey = false
                else
                    debug("-> f19 up, no other action")
                    f19.didPressOtherKey = false
                end
                return true
            end
            debug("-> other f19 action")
            return false
        else
            -- Some other key is being pressed or released
            if isDown and f19.isF19Down and not f19.didPressOtherKey then
                debug("-> other key, while f19 was down")
                -- We pressed another key while F19 is held -> "hyper" mode
                if not f19.hyperActive then
                    pressHyper()
                    f19.hyperActive = true
                end

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