--- Per-turn record of a session's conversation, accumulated from the daemon
--- event stream so the turn inspector (48d.36 layer 3) can show one turn's full
--- detail. The transcript's usage annotation (layer 2) folds usage into a single
--- session-cumulative accumulator; this instead keeps an ordered history, one
--- record per turn, each collecting the turn's prompt, prompt estimate, token
--- usage, context fullness, and tool calls.
---
--- Pure and window-free: `TurnLog:apply` folds an event envelope into the open
--- turn and seals it on turn_end, so the model is unit-testable without a live
--- session or buffer.
local M = {}

--- @class tend.transcript.TurnToolCall
--- @field id string tool_call_id
--- @field name? string tool name (from tool_call)
--- @field status? string latest status (from tool_call/tool_call_update)

--- @class tend.transcript.TurnRecord
--- @field prompt? { text: string, attachments: integer } user_prompt content
--- @field prompt_usage? table agent_prompt_usage payload (approximate estimate)
--- @field tokens? table agent_token_usage payload (authoritative)
--- @field context? table agent_context_usage payload (window fullness)
--- @field tools tend.transcript.TurnToolCall[] tool calls in the turn, in order

--- @class tend.transcript.TurnLog
--- @field private sealed tend.transcript.TurnRecord[] completed turns, in order
--- @field private open tend.transcript.TurnRecord the in-progress turn
local TurnLog = {}
TurnLog.__index = TurnLog
M.TurnLog = TurnLog

--- @return tend.transcript.TurnRecord
local function new_record()
    return { tools = {} }
end

--- @return tend.transcript.TurnLog
function TurnLog.new()
    return setmetatable({ sealed = {}, open = new_record() }, TurnLog)
end

--- Fold a daemon event envelope into the open turn, sealing it on turn_end.
--- @param event table daemon event envelope { type, payload }
--- @return boolean changed whether this event updated turn state
function TurnLog:apply(event)
    if type(event) ~= "table" then
        return false
    end
    local payload = type(event.payload) == "table" and event.payload or {}
    local etype = event.type

    if etype == "user_prompt" then
        self.open.prompt = {
            text = type(payload.text) == "string" and payload.text or "",
            attachments = payload.attachments or 0,
        }
        return true
    elseif etype == "agent_prompt_usage" then
        self.open.prompt_usage = payload
        return true
    elseif etype == "agent_token_usage" then
        self.open.tokens = payload
        return true
    elseif etype == "agent_context_usage" then
        self.open.context = payload
        return true
    elseif etype == "tool_call" then
        if payload.tool_call_id then
            table.insert(self.open.tools, {
                id = payload.tool_call_id,
                name = payload.name,
                status = payload.status or "pending",
            })
        end
        return true
    elseif etype == "tool_call_update" then
        if payload.tool_call_id then
            for _, tc in ipairs(self.open.tools) do
                if tc.id == payload.tool_call_id then
                    tc.status = payload.status or tc.status
                    break
                end
            end
        end
        return true
    elseif etype == "turn_end" then
        table.insert(self.sealed, self.open)
        self.open = new_record()
        return true
    end
    return false
end

--- The record for a turn by 1-based index over sealed turns, then the open turn
--- as the last index. So index N+1 (with N sealed turns) is the in-progress one.
--- Out-of-range indices return nil.
--- @param index integer
--- @return tend.transcript.TurnRecord|nil
function TurnLog:record(index)
    if index == #self.sealed + 1 then
        return self.open
    end
    return self.sealed[index]
end

--- Number of addressable turns: the sealed turns plus the open one.
--- @return integer
function TurnLog:count()
    return #self.sealed + 1
end

return M
