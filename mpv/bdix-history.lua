-- bdix-history.lua
-- Place this file in mpv's scripts directory or pass it to mpv with --script
-- It appends a JSON line to %TEMP%/bdix-mpv-events.log on every file-loaded event

local temp = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local logfile = temp .. "\\bdix-mpv-events.log"

local function write_event()
    local path = mp.get_property("path") or ""
    local title = mp.get_property("media-title") or ""
    local t = os.date("%Y-%m-%d %H:%M:%S")
    -- Escape quotes in title/path
    title = title:gsub('"', '\\"')
    path = path:gsub('"', '\\"')
    local line = string.format('{"Name":"%s","Url":"%s","Time":"%s"}\n', title, path, t)
    local f, err = io.open(logfile, "a")
    if f then
        f:write(line)
        f:close()
    else
        mp.msg.warn("bdix-history.lua: failed to open log file: " .. tostring(err))
    end
end

mp.register_event("file-loaded", write_event)
mp.msg.info("bdix-history.lua loaded; logging to: " .. logfile)
