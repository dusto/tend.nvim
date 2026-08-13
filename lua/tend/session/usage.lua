--- Per-session token/context accounting, accumulated from the daemon's usage
--- session events (which the plugin otherwise drops). Three events feed it:
---
---  - agent_prompt_usage  — the daemon's approximate, model-agnostic estimate of
---    the client-composed prompt text for a turn (bytes + token estimate). Always
---    approximate; labeled as such.
---  - agent_token_usage   — the provider's authoritative per-turn accounting
---    (input/output/cached/reasoning/total), from the session/prompt result.
---    Supersedes the estimate; summed into a session running total.
---  - agent_context_usage — the provider's context-window fullness
---    (used/window tokens, optional cost). Cumulative; the latest wins.
---
--- Pure and window-free: `Usage:apply` folds an event envelope into state and
--- `render_lines` turns a snapshot into display lines, so both are unit-testable
--- without a live session or floating window.
local M = {}

--- @class tend.session.Usage
--- @field prompt? table latest agent_prompt_usage payload (approximate)
--- @field last_turn? table latest agent_token_usage payload (authoritative)
--- @field context? table latest agent_context_usage payload (authoritative)
--- @field turns integer authoritative turns counted (agent_token_usage events)
--- @field total_input integer session-cumulative input tokens (authoritative)
--- @field total_output integer session-cumulative output tokens (authoritative)
--- @field total_tokens integer session-cumulative total tokens (authoritative)
local Usage = {}
Usage.__index = Usage
M.Usage = Usage

--- @return tend.session.Usage
function Usage.new()
    return setmetatable({
        turns = 0,
        total_input = 0,
        total_output = 0,
        total_tokens = 0,
    }, Usage)
end

--- Fold a daemon event envelope into the accumulator.
--- @param event table daemon event envelope { type, payload }
--- @return boolean changed whether this event updated usage state
function Usage:apply(event)
    if type(event) ~= "table" then
        return false
    end
    local payload = type(event.payload) == "table" and event.payload or {}
    if event.type == "agent_prompt_usage" then
        self.prompt = payload
        return true
    elseif event.type == "agent_context_usage" then
        self.context = payload
        return true
    elseif event.type == "agent_token_usage" then
        self.last_turn = payload
        self.turns = self.turns + 1
        self.total_input = self.total_input + (payload.input_tokens or 0)
        self.total_output = self.total_output + (payload.output_tokens or 0)
        self.total_tokens = self.total_tokens + (payload.total_tokens or 0)
        return true
    end
    return false
end

--- Whether any usage has been reported yet.
--- @return boolean
function Usage:is_empty()
    return self.prompt == nil and self.last_turn == nil and self.context == nil
end

--- A compact, human count: 1_234 -> "1,234"; 18_240 -> "18.2k"; 2_000_000 -> "2.0M".
--- @param n integer|nil
--- @return string
function M.humanize(n)
    n = n or 0
    if n < 1000 then
        return tostring(n)
    end
    if n < 10000 then
        -- Group thousands with a comma for small counts (more legible than "1.2k").
        local s = tostring(n)
        return s:sub(1, -4) .. "," .. s:sub(-3)
    end
    if n < 1000000 then
        return string.format("%.1fk", n / 1000)
    end
    return string.format("%.1fM", n / 1000000)
end

--- The context-window fill percentage as a display string, or nil when the
--- window size is unknown.
--- @param used integer
--- @param window integer
--- @return string|nil
local function percent(used, window)
    if not window or window <= 0 then
        return nil
    end
    return string.format("~%d%%", math.floor((used / window) * 100 + 0.5))
end

--- @class tend.session.UsageHeader
--- @field session_id string
--- @field label? string user/task label for the session
--- @field provider_id? string
--- @field model_id? string
--- @field task? string task id
--- @field status? string

--- Render a session's info + usage into display lines. Pure: no windows, no
--- daemon calls. Degrades to a single "no usage yet" line when nothing has been
--- reported, so the view is never blank.
--- @param usage tend.session.Usage
--- @param header tend.session.UsageHeader
--- @return string[] lines
function M.render_lines(usage, header)
    local lines = {}
    local name = header.label or header.task or header.session_id
    local who = header.provider_id or "?"
    if header.model_id and header.model_id ~= "" then
        who = who .. " · " .. header.model_id
    end
    table.insert(lines, "# " .. name)
    table.insert(lines, ("%s · %s"):format(who, header.status or "unknown"))
    table.insert(lines, "Task: " .. (header.task or "none"))
    table.insert(lines, "")

    if usage:is_empty() then
        table.insert(lines, "_No usage reported yet._")
        return lines
    end

    local ctx = usage.context
    if ctx then
        local used = ctx.used_tokens or 0
        local window = ctx.window_tokens or 0
        local line = "Context window: " .. M.humanize(used)
        if window > 0 then
            local pct = percent(used, window)
            line = line
                .. " / "
                .. M.humanize(window)
                .. (pct and ("  (" .. pct .. ")") or "")
        end
        table.insert(lines, line)
        if ctx.cost and ctx.cost.amount then
            table.insert(
                lines,
                ("Cost: %.2f %s"):format(
                    ctx.cost.amount,
                    ctx.cost.currency or ""
                )
            )
        end
    end

    local turn = usage.last_turn
    if turn then
        table.insert(
            lines,
            ("Last turn: %s in · %s out · %s total"):format(
                M.humanize(turn.input_tokens),
                M.humanize(turn.output_tokens),
                M.humanize(turn.total_tokens)
            )
        )
    end

    if usage.turns > 0 then
        table.insert(
            lines,
            ("Session total: %s tokens across %d turn%s"):format(
                M.humanize(usage.total_tokens),
                usage.turns,
                usage.turns == 1 and "" or "s"
            )
        )
    end

    local prompt = usage.prompt
    if prompt then
        table.insert(
            lines,
            ("Prompt (composed): ~%s tokens · %s bytes  [approx]"):format(
                M.humanize(prompt.tokens_approx),
                M.humanize(prompt.text_bytes)
            )
        )
    end

    return lines
end

--- A condensed one-line usage annotation for a turn boundary, or nil when no
--- authoritative turn tokens have been reported (a prompt estimate alone does
--- not count — the boundary marks a completed turn). e.g.
--- "↑1,200 ↓18.2k · ctx ~18%". The context percent is appended only when the
--- window size is known.
--- @param usage tend.session.Usage
--- @return string|nil annotation
function M.render_turn_annotation(usage)
    local turn = usage.last_turn
    if not turn then
        return nil
    end
    local parts = {
        "↑" .. M.humanize(turn.input_tokens),
        "↓" .. M.humanize(turn.output_tokens),
    }
    local ctx = usage.context
    local pct = ctx and percent(ctx.used_tokens or 0, ctx.window_tokens or 0)
    if pct then
        table.insert(parts, "ctx " .. pct)
    end
    return table.concat(parts, " · ")
end

return M
