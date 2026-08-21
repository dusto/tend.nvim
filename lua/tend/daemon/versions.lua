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
    -- 0.25.0 added session.rename (+ SessionInfo.label), which :TendSessionRename
    -- calls (0.16.0 added session.set_thought_level and the thought-level axis on
    -- SessionInfo, which the thought-level switcher uses; 0.15.0 added
    -- agent.prompt content blocks; 0.14.0 added slash.invoke; 0.13.0 added
    -- slash.complete; 0.12.0 added slash.list; 0.11.0 added provider.list; 0.10.0
    -- added session.set_model/set_mode; 0.9.0 made agent.start's task optional;
    -- 0.8.0 added session.list/claim; 0.6.0 added file.diff). Pin the highest
    -- contract this plugin relies on so an older daemon is rejected at the
    -- handshake, not mid-session when a command first runs a missing method.
    plugin_to_daemon = "0.25.0",
    -- The plugin serves editor.open / editor.diff (daemon->editor 0.2.0); pin it
    -- so we never try to render a diff payload a too-old daemon cannot send. The
    -- plugin also serves the editor LSP surface (editor.current_buffer +
    -- diagnostics/symbols/definition/references/hover at 0.4.0, code_actions at
    -- 0.5.0) and the file-mutation surface (editor.read_buffer/write_buffer,
    -- foundational — at or below 0.2.0), but those are reactive: an older daemon
    -- simply never calls them, so the required minimum stays 0.2.0 rather than
    -- rejecting a daemon that is otherwise fine for diff/open.
    daemon_to_editor = "0.2.0",
    -- 1.0.0 moved approval_requested/approval_resolved off the session stream
    -- onto the repo-wide workspace stream (the approval channel); this plugin now
    -- subscribes there for live approvals (commands.lua Context:track_workspace).
    -- It is a BREAKING major bump on the daemon side: a pre-1.0 daemon still emits
    -- approvals on session streams, which this plugin no longer follows for
    -- approvals, so it must be rejected at the handshake rather than silently
    -- delivering no approval prompts. (0.13.0 added session_renamed, which the
    -- header consumes to keep a session's label live; 0.7.0 added
    -- agent_thought_level_updated; 0.6.0 slash_commands_updated; 0.5.0 agent_plan.
    -- 1.1.0 added the filesystem_access approval kind, which the approval renderer
    -- now surfaces; it is reactive — a pre-1.1.0 daemon hard-denies outside-worktree
    -- reads and never emits it — so the required minimum stays 1.0.0.)
    daemon_to_client = "1.0.0",
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
