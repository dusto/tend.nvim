--- The plugin's API version pin against the daemon's wire contract.
---
--- The three method sets version independently as MAJOR.MINOR.PATCH and the
--- handshake is checked client-side (mirroring the Go client): a set is
--- compatible when the daemon's version shares the required major and is >=
--- the required version; empty required fields are not checked. REQUIRED pins
--- the minimum for what this plugin actually uses — plugin->daemon for the
--- methods the commands call, daemon->client for event.push/prompt.raise.
--- daemon->editor is unpinned until the plugin serves editor.* requests.
local M = {}

--- The minimum contract versions this plugin requires per method set.
--- plugin_to_daemon 0.2.0 is the first version with task.*.
M.REQUIRED = {
    plugin_to_daemon = "0.2.0",
    daemon_to_client = "0.1.0",
}

--- @param s string|nil
--- @return integer[]|nil triplet
local function parse_version(s)
    if type(s) ~= "string" then
        return nil
    end
    local major, minor, patch = s:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- Whether `have` >= `req` within the same major version.
--- @param h integer[]
--- @param r integer[]
--- @return boolean
local function at_least(h, r)
    if h[1] ~= r[1] then
        return false -- different major: incompatible
    end
    for i = 2, 3 do
        if h[i] ~= r[i] then
            return h[i] > r[i]
        end
    end
    return true
end

--- Whether the daemon's reported versions satisfy every pinned set. Returns
--- false with a descriptive reason on the first incompatible (or malformed)
--- set, mirroring api.Versions.Satisfies.
--- @param have table<string, string> the daemon's reported versions per set
--- @param required? table<string, string> pins (default: M.REQUIRED)
--- @return boolean ok
--- @return string|nil why
function M.satisfies(have, required)
    required = required or M.REQUIRED
    if type(have) ~= "table" then
        return false, "daemon reported no contract versions"
    end
    for _, set in ipairs({
        "plugin_to_daemon",
        "daemon_to_editor",
        "daemon_to_client",
    }) do
        local req = required[set]
        if req ~= nil and req ~= "" then
            local r = parse_version(req)
            if not r then
                return false, set .. ": malformed pin " .. tostring(req)
            end
            local h = parse_version(have[set])
            if not h then
                return false,
                    set
                        .. ": daemon reported "
                        .. tostring(have[set])
                        .. ", required "
                        .. req
            end
            if not at_least(h, r) then
                return false,
                    set
                        .. " version "
                        .. have[set]
                        .. " does not satisfy required "
                        .. req
            end
        end
    end
    return true, nil
end

return M
