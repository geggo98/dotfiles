-- Specification:
-- - Monitor for display changes
-- - When a target display is connected (either AU16T or Lenovo p27):
--   1. Quit Plash application
--   2. Set the display preference for Plash to use the connected display
--   3. Activate Plash application

local displayMonitor = {}

-- Debug flag
displayMonitor.isDebug = false  -- Set to true to enable debug output

-- Target display IDs with names
displayMonitor.targetDisplays = {
    {
        hammerspoonUuid = "F07C06B9-8DE6-47AD-BBAD-C6099C6CE317", -- UUID for Hammerspoon matching
        plashUuid = "F07C06B9-8DE6-47AD-BBAD-C6099C6CE317", -- UUID for Plash defaults
        name = "AU16T"
    },
    {
        hammerspoonUuid = "4CD90719-DE57-467E-A396-6D71BE0FF1B6", -- UUID for Hammerspoon matching
        plashUuid = "4CD90719-DE57-467E-A396-6D71BE0FF1B6", -- UUID for Plash defaults
        name = "Lenovo p27"
    }
}

-- Debug print function
local function debugPrint(...)
    if displayMonitor.isDebug then
        print("[Display Monitor] ", ...)
    end
end

-- Function to check if any target display is connected
local function isTargetDisplayConnected()
    local screens = hs.screen.allScreens()
    for _, screen in ipairs(screens) do
        local id = screen:getUUID()
        debugPrint("Found screen with ID: " .. id)

        -- Check if this screen matches any of our target displays (case insensitive)
        for _, targetDisplay in ipairs(displayMonitor.targetDisplays) do
            if string.lower(id) == string.lower(targetDisplay.hammerspoonUuid) then
                debugPrint("Matched target display: " .. targetDisplay.name .. " (" .. targetDisplay.hammerspoonUuid .. ")")
                return targetDisplay
            end
        end
    end
    return nil
end

-- Function to execute commands when target display is connected
local function handleTargetDisplay(targetDisplay)
    debugPrint("Target display " .. targetDisplay.name .. " (Hammerspoon UUID: " .. targetDisplay.hammerspoonUuid .. ", Plash UUID: " .. targetDisplay.plashUuid .. ") connected, executing commands")

    -- Quit Plash application
    hs.osascript.applescript('tell application "Plash" to quit')

    -- Wait a moment for the application to quit
    hs.timer.doAfter(1, function()
        -- Set the display preference for Plash
        hs.execute('defaults write com.sindresorhus.Plash display "' .. targetDisplay.plashUuid .. '"')

        -- Wait a moment for the preference to be set
        hs.timer.doAfter(0.5, function()
            -- Activate Plash application
            hs.osascript.applescript('tell application "Plash" to activate')
        end)
    end)
end

-- Screen watcher callback function
local function screenWatcherCallback()
    debugPrint("Screen configuration changed")

    local connectedDisplay = isTargetDisplayConnected()
    if connectedDisplay then
        debugPrint("Target display " .. connectedDisplay.name .. " is connected")
        handleTargetDisplay(connectedDisplay)
    else
        debugPrint("No target displays are connected")
    end
end

-- Create and start the screen watcher
displayMonitor.screenWatcher = hs.screen.watcher.new(screenWatcherCallback)
displayMonitor.screenWatcher:start()

-- Function to print information about all connected displays
local function printDisplayInfo()
    local screens = hs.screen.allScreens()
    print("[Display Monitor] Initial display check - Connected displays:")
    for _, screen in ipairs(screens) do
        local uuid = screen:getUUID()
        local name = screen:name()
        local modeDesc = screen:currentMode().desc
        print("[Display Monitor] Display: UUID=" .. uuid .. ", name=" .. name .. ", mode=" .. modeDesc)
    end
end

-- Run once at startup to handle the case where the display is already connected
hs.timer.doAfter(5, function()
    debugPrint("Running initial display check")
    printDisplayInfo() -- Print info about all displays regardless of debug flag
    screenWatcherCallback()
end)

debugPrint("Display monitor initialized")
return displayMonitor
