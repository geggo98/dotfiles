-- Specification:
-- - If debug mode is set, print log messages, otherwise mute them
-- - If the the moeule is not active, pass through all keys. The use can use this to temporarily deactivate the module from the Hammerspoon console
-- - If the user presses and releases the F19 key without any other key, the system should act as if the user pressed the escaoe key
-- - If the user presses the F19 key with anothe key, the system shoudl act as if the F19 key is the "hyper" modifier  (Cmd+Ctrl+Alt+Shift) for the other key.
-- - If the user presses a modifier with the F19 key (e.g., Alt+F19), this should be passed through to the system.

local f19            = {}

-- Debug and active flags
f19.isDebug          = false    -- Set to false to silence debug output
f19.isActive         = true     -- Set to false to pass through all keys

-- Keep track of whether F19 is down, whether we've pressed another key,
-- and whether we've already activated "hyper" mode
f19.isF19Down        = false
f19.didPressOtherKey = false
f19.hyperActive      = false

-- Modifiers used for the "hyper" effect
f19.hyperMods        = { "cmd", "alt", "ctrl", "shift" }

-- Debug print function
local function debugPrint(...)
    if f19.isDebug then
        print("[F19 Module] ", ...)
    end
end

-- Press all "hyper" modifiers
local function pressHyper()
    debugPrint("Activating hyper modifiers")
    for _, mod in ipairs(f19.hyperMods) do
        hs.eventtap.event.newKeyEvent(mod, true):post()
    end
    f19.hyperActive = true
end

-- Release any active "hyper" modifiers
local function releaseHyper()
    if f19.hyperActive then
        debugPrint("Releasing hyper modifiers")
        for _, mod in ipairs(f19.hyperMods) do
            hs.eventtap.event.newKeyEvent(mod, false):post()
        end
        f19.hyperActive = false
    end
end

-- Send an Escape key press
local function sendEscape()
    debugPrint("Sending Escape")
    hs.eventtap.event.newKeyEvent({}, "escape", true):post()
    hs.eventtap.event.newKeyEvent({}, "escape", false):post()
end

-- Eventtap to intercept key events
f19.eventtap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
    function(event)
        if not f19.isActive then
            -- If module is inactive, don't intercept anything
            return false
        end

        local keyCode      = event:getKeyCode()
        local flags        = event:getFlags()
        local isDown       = (event:getType() == hs.eventtap.event.types.keyDown)
        local isUp         = (event:getType() == hs.eventtap.event.types.keyUp)
        local f19KeyCode   = hs.keycodes.map["f19"]
        local hasModifiers = (flags.cmd or flags.alt or flags.ctrl or flags.shift)

        -- Handle F19 key events
        if keyCode == f19KeyCode then
            if isDown then
                if not hasModifiers then
                    -- F19 pressed alone; might be ESC or might become hyper
                    f19.isF19Down = true
                    f19.didPressOtherKey = false
                    debugPrint("F19 pressed with no modifiers")
                    -- Block the raw F19 event from reaching the system
                    return true
                else
                    -- If F19 is pressed together with any standard modifier
                    -- (like Alt+F19), pass it straight through
                    debugPrint("F19 with standard modifier => pass through")
                    f19.didPressOtherKey = false
                    return false
                end
            elseif isUp then
                if f19.isF19Down then
                    -- If no other key was pressed while F19 was down, send Escape
                    if not f19.didPressOtherKey then
                        debugPrint("F19 released without pressing another key => Escape")
                        sendEscape()
                    end
                    -- Cleanup state
                    releaseHyper()
                    f19.isF19Down = false
                    return true
                end
            end
        else
            -- Any other keys
            if f19.isF19Down and isDown then
                -- We've pressed another key while F19 is held, so let's do hyper
                f19.didPressOtherKey = true
                pressHyper()
                -- Post this key event as if hyper modifiers are held
                local char = hs.keycodes.map[keyCode]
                if char then
                    hs.eventtap.event.newKeyEvent(f19.hyperMods, char, true):post()
                end
                return true
            elseif f19.isF19Down and isUp then
                -- Key up while F19 is held
                local char = hs.keycodes.map[keyCode]
                if char then
                    hs.eventtap.event.newKeyEvent(f19.hyperMods, char, false):post()
                end
                return true
            end
        end

        -- If we reach here, pass the event through normally
        return false
    end
)

-- Start watching key events
f19.eventtap:start()

return f19
