-- Specification:
-- - Monitor for display changes
-- - When a display with ID "F07C06B9-8DE6-47AD-BBAD-C6099C6CE317" is connected:
--   1. Quit Plash application
--   2. Set the display preference for Plash
--   3. Activate Plash application

local displayMonitor = {}

-- Debug flag
displayMonitor.isDebug = false  -- Set to true to enable debug output

-- Target display ID
displayMonitor.targetDisplayID = "F07C06B9-8DE6-47AD-BBAD-C6099C6CE317" -- Display: AU16T

-- Debug print function
local function debugPrint(...)
    if displayMonitor.isDebug then
        print("[Display Monitor] ", ...)
    end
end

-- Function to check if the target display is connected
local function isTargetDisplayConnected()
    local screens = hs.screen.allScreens()
    for _, screen in ipairs(screens) do
        local id = screen:getUUID()
        debugPrint("Found screen with ID: " .. id)
        if id == displayMonitor.targetDisplayID then
            return true
        end
    end
    return false
end

-- Function to execute commands when target display is connected
local function handleTargetDisplay()
    debugPrint("Target display connected, executing commands")
    
    -- Quit Plash application
    hs.osascript.applescript('tell application "Plash" to quit')
    
    -- Wait a moment for the application to quit
    hs.timer.doAfter(1, function()
        -- Set the display preference for Plash
        hs.execute('defaults write com.sindresorhus.Plash display "' .. displayMonitor.targetDisplayID .. '"')
        
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
    
    if isTargetDisplayConnected() then
        debugPrint("Target display is connected")
        handleTargetDisplay()
    else
        debugPrint("Target display is not connected")
    end
end

-- Create and start the screen watcher
displayMonitor.screenWatcher = hs.screen.watcher.new(screenWatcherCallback)
displayMonitor.screenWatcher:start()

-- Run once at startup to handle the case where the display is already connected
hs.timer.doAfter(5, function()
    debugPrint("Running initial display check")
    screenWatcherCallback()
end)

debugPrint("Display monitor initialized")
return displayMonitor