-- Define our module (optional style)
local f19 = {}

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
    print(">>> pressHyper")
    for _, mod in ipairs(f19.hyperMods) do
        hs.eventtap.event.newKeyEvent(mod, true):post()
    end
    print("<<< pressHyper")
end

-- Release the hyper modifiers.
local function releaseHyper()
    print(">>> releaseHyper")
    if f19.hyperActive then
        for _, mod in ipairs(f19.hyperMods) do
            hs.eventtap.event.newKeyEvent(mod, false):post()
        end
        f19.hyperActive = false
    end
    print("<<< releaseHyper")
end

-- Send Esc
local function sendEscape()
    print(">>> sendEscape")
    hs.eventtap.event.newKeyEvent({}, "escape", true):post()
    hs.eventtap.event.newKeyEvent({}, "escape", false):post()
    print("<<< sendEscape")
end
--------------------------------------------------------------------------------
-- Main eventtap to watch for key presses and releases
--------------------------------------------------------------------------------
f19.eventtap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
    function(event)
        local keyCode    = event:getKeyCode()
        local flags      = event:getFlags()
        local isFlags = (flags.cmd or flags.alt or flags.ctrl or flags.shift)
        local isDown     = (event:getType() == hs.eventtap.event.types.keyDown)
        local f19KeyCode = hs.keycodes.map["f19"]

        if keyCode == f19KeyCode then
            -- We have an F19 event
            if isDown then
                -- Check if there are no modifiers
                if not isFlags then
                    print("-> f19, no modfifers")
                    -- F19 pressed with no modifiers -> Potential "hyper" or "vim escape"
                    f19.isF19Down = true
                    f19.didPressOtherKey = false
                    return true -- Block so macOS doesn't see plain F19
                else
                    print("-> f19, with modifiers: pass through")
                    -- F19 with any modifiers: pass through
                    f19.didPressOtherKey = true
                    return false
                end
            else
                -- Key up for F19
                if f19.isF19Down then
                    print("-> f19 up, after other action")
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
                else
                    print("-> f19 up, no other action")
                end
                return true
            end
        else
            -- Some other key is being pressed or released
            if isDown and f19.isF19Down and not f19.didPressOtherKey then
                print("-> other key, while f19 was down")
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