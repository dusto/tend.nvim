--- Rich chat view over a daemon session's event stream.
---
--- Owns a chat buffer and a MessageWriter — the kept rendering primitive from
--- the upstream chat UI — and translates daemon event envelopes into writer
--- calls, so a session's transcript renders as streamed agent messages,
--- thinking blocks, and tool-call blocks rather than the minimal line-per-event
--- TranscriptView. It is the per-session view the daemon command path attaches
--- to a session's stream; one instance owns one buffer, so several sessions
--- render independently (and across tabs) with no shared state.
---
--- Phase 2a is render-only: chat-driven prompting and in-chat approvals live in
--- a later bead, so approval and provider-notification events are not rendered
--- here (approvals surface through the approval manager).
local MessageWriter = require("tend.ui.message_writer")

--- @class tend.transcript.ChatView
--- @field private writer tend.ui.MessageWriter
--- @field private bufnr integer
--- @field private seen table<string, boolean> "kind:seq" keys already applied
local ChatView = {}
ChatView.__index = ChatView

--- @class tend.transcript.ChatViewOpts
--- @field provider_id? string Provider name shown in agent message headers.

--- @param bufnr integer
--- @param opts? tend.transcript.ChatViewOpts
--- @return tend.transcript.ChatView
function ChatView.new(bufnr, opts)
    opts = opts or {}
    -- Markdown so the writer's headers, code fences, and diffs render with
    -- treesitter highlighting. Skip when the buffer already has a filetype (the
    -- chat widget creates its session buffers as "TendChat").
    if vim.bo[bufnr].filetype == "" then
        vim.bo[bufnr].filetype = "markdown"
    end
    local writer = MessageWriter:new(bufnr)
    if opts.provider_id then
        writer:set_provider_name(opts.provider_id)
    end
    return setmetatable({
        writer = writer,
        bufnr = bufnr,
        seen = {},
    }, ChatView)
end

--- Apply one daemon event envelope, rendering it into the chat buffer.
--- @param event table
function ChatView:apply(event)
    -- Dedup so a replayed record on reconnect does not double-append to the
    -- streaming writer. Key on kind + seq, not seq alone: a summary for a range
    -- [from, n] can carry a seq already used by a raw event, so seq-only dedup
    -- would drop the summary as a false duplicate.
    local seq = event.seq
    if seq ~= nil then
        local key = tostring(event.kind or "event") .. ":" .. tostring(seq)
        if self.seen[key] then
            return
        end
        self.seen[key] = true
    end

    if event.kind == "summary" then
        self:_render_summary(event)
        return
    end

    local payload = type(event.payload) == "table" and event.payload or {}
    local etype = event.type

    if etype == "user_prompt" then
        self:_write_user_prompt(payload)
    elseif etype == "agent_message_chunk" then
        self:_write_chunk("agent_message_chunk", payload.text)
    elseif etype == "agent_thought_chunk" then
        self:_write_chunk("agent_thought_chunk", payload.text)
    elseif etype == "tool_call" then
        if payload.tool_call_id then
            self.writer:write_tool_call_block({
                tool_call_id = payload.tool_call_id,
                -- The daemon's tool_call carries the tool name; the writer
                -- renders it as the block header argument. Richer fields (kind,
                -- diff, body) arrive once the daemon normalizer emits them.
                argument = payload.name,
                status = "pending",
            })
        end
    elseif etype == "tool_call_update" then
        if payload.tool_call_id then
            self.writer:update_tool_call_block({
                tool_call_id = payload.tool_call_id,
                status = payload.status,
            })
        end
    elseif etype == "turn_end" then
        -- A turn boundary: reset sender tracking so the next turn's agent
        -- output writes a fresh header rather than extending the last one.
        self.writer:reset_sender_tracking()
    elseif etype == "agent_error" then
        self:_write_chunk(
            "agent_message_chunk",
            "⚠ " .. (payload.message or "error")
        )
    end
    -- approval_requested / approval_resolved / provider_notification are not
    -- rendered here (see the module note).
end

--- @private
--- Render the user's prompt for a turn as a distinct 'user' block, so the human
--- side of the conversation is visible in the transcript (the session stream
--- otherwise carries only agent output). The daemon emits user_prompt as the
--- turn starts; it is a complete message, so it writes as a full block rather
--- than a streamed chunk.
--- @param payload table user_prompt payload ({ text, attachments? })
function ChatView:_write_user_prompt(payload)
    local text = type(payload.text) == "string" and payload.text or ""
    -- The event carries only a count of attachments (blob content is not
    -- persisted). A file-only prompt has empty text but real attachments, so it
    -- must still render — dropping it would make the prompt vanish on replay.
    local attachments = payload.attachments
    local has_attachments = type(attachments) == "number" and attachments > 0

    if text == "" and not has_attachments then
        return
    end

    if has_attachments then
        local note = string.format(
            "_(+%d attachment%s)_",
            attachments,
            attachments == 1 and "" or "s"
        )
        text = text ~= "" and (text .. "\n\n" .. note) or note
    end
    self.writer:write_message({
        sessionUpdate = "user_message_chunk",
        content = { type = "text", text = text },
    })
end

--- @private
--- @param session_update string ACP sessionUpdate type for sender classification
--- @param text string|nil
function ChatView:_write_chunk(session_update, text)
    if not text or text == "" then
        return
    end
    self.writer:write_message_chunk({
        sessionUpdate = session_update,
        content = { type = "text", text = text },
    })
end

--- @private
--- Render a compaction summary as a structural collapse marker. The daemon does
--- not emit summary records yet; this keeps the view ready for them.
--- @param event table
function ChatView:_render_summary(event)
    local info = event.summary or {}
    local from = info.from_seq or event.seq or 0
    local to = info.to_seq or from
    local text = string.format("--- summarized turns %d-%d ---", from, to)
    local payload = type(event.payload) == "table" and event.payload or {}
    if type(payload.text) == "string" and payload.text ~= "" then
        text = text .. "\n" .. payload.text
    end
    self.writer:write_structural_message({
        sessionUpdate = "user_message_chunk",
        content = { type = "text", text = text },
    })
end

return ChatView
