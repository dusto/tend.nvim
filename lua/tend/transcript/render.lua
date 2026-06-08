--- Default rendering of TEND event envelopes into transcript display lines.
---
--- Each event (and compaction summary) renders to a list of buffer lines that
--- the transcript model treats as one range-addressable block keyed by its seq.
--- A renderer returning no lines (e.g. turn_end) contributes an empty block,
--- which is still addressable for later summary replacement.
local M = {}

--- Split text into display lines, dropping a single trailing newline so a chunk
--- ending in "\n" does not add a blank line.
--- @param text string
--- @return string[]
local function text_lines(text)
    if text == "" then
        return {}
    end
    -- Drop one trailing newline so a chunk ending in "\n" does not add a blank
    -- line, while newlines in the middle still split.
    text = text:gsub("\n$", "")
    return vim.split(text, "\n", { plain = true })
end

--- @type table<string, fun(payload: table, event: table): string[]>
local renderers = {
    agent_message_chunk = function(payload)
        return text_lines(payload.text or "")
    end,

    tool_call = function(payload)
        return { "tool: " .. (payload.name or payload.tool_call_id or "?") }
    end,

    tool_call_update = function(payload)
        return {
            "  "
                .. (payload.tool_call_id or "?")
                .. " -> "
                .. (payload.status or "?"),
        }
    end,

    -- A turn boundary is implicit in the layout; render nothing.
    turn_end = function()
        return {}
    end,

    approval_requested = function(payload)
        return { "[approval needed] " .. (payload.kind or "?") }
    end,

    approval_resolved = function(payload)
        local verdict = payload.approved and "approved" or "denied"
        local line = "[approval " .. verdict .. "]"
        if payload.reason and payload.reason ~= "" then
            line = line .. " " .. payload.reason
        end
        return { line }
    end,

    agent_error = function(payload)
        return { "error: " .. (payload.message or "") }
    end,

    -- Provider-private metadata; not shown in the transcript body.
    provider_notification = function()
        return {}
    end,
}

--- Render a compaction summary record as a collapsed range marker plus any text
--- the summary payload carries.
--- @param event table
--- @return string[]
local function render_summary(event)
    local info = event.summary or {}
    local from = info.from_seq or event.seq or 0
    local to = info.to_seq or from
    local lines = { "--- summarized turns " .. from .. "-" .. to .. " ---" }
    local payload = event.payload
    if type(payload) == "table" and type(payload.text) == "string" then
        for _, l in ipairs(text_lines(payload.text)) do
            lines[#lines + 1] = l
        end
    end
    return lines
end

--- Render an event envelope into transcript lines.
--- @param event table
--- @return string[]
function M.render(event)
    if event.kind == "summary" then
        return render_summary(event)
    end
    local payload = type(event.payload) == "table" and event.payload or {}
    local renderer = renderers[event.type]
    if renderer then
        return renderer(payload, event)
    end
    return { "<" .. tostring(event.type) .. ">" }
end

return M
