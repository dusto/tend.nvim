local assert = require("tests.helpers.assert")

describe("tend.transcript.ChatView", function()
    --- @type tend.transcript.ChatView
    local ChatView
    --- @type integer
    local bufnr
    --- @type tend.transcript.ChatView
    local view

    before_each(function()
        ChatView = require("tend.transcript.chat_view")
        bufnr = vim.api.nvim_create_buf(false, true)
        view = ChatView.new(bufnr, { provider_id = "codex" })
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- The whole buffer as one string, for substring assertions.
    --- @return string
    local function text()
        return table.concat(
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            "\n"
        )
    end

    --- @param seq integer
    --- @param etype string
    --- @param payload table
    --- @return table
    local function event(seq, etype, payload)
        return {
            kind = "event",
            type = etype,
            seq = seq,
            cursor_seq = seq,
            stream_id = "str-1",
            payload = payload,
        }
    end

    it("renders an agent message chunk under an agent header", function()
        view:apply(event(1, "agent_message_chunk", { text = "hello there" }))
        local body = text()
        -- The kept writer attributes the chunk to the agent with the provider
        -- name, not a bare line like the minimal TranscriptView.
        assert.is_not_nil(body:find("Agent", 1, true))
        assert.is_not_nil(body:find("codex", 1, true))
        assert.is_not_nil(body:find("hello there", 1, true))
    end)

    it("dedups by seq so a replayed record is not double-rendered", function()
        local chunk = event(1, "agent_message_chunk", { text = "once" })
        view:apply(chunk)
        view:apply(chunk) -- replay on reconnect
        local _, count = text():gsub("once", "once")
        assert.equal(1, count)
    end)

    it("renders a tool-call block and updates its status", function()
        view:apply(event(1, "tool_call", {
            tool_call_id = "tc-1",
            name = "read_file",
        }))
        assert.is_not_nil(text():find("read_file", 1, true))

        view:apply(event(2, "tool_call_update", {
            tool_call_id = "tc-1",
            status = "completed",
        }))
        assert.is_not_nil(text():find("completed", 1, true))
    end)

    it(
        "turn_end resets the sender so the next turn writes a fresh header",
        function()
            view:apply(event(1, "agent_message_chunk", { text = "turn one" }))
            view:apply(event(2, "turn_end", {}))
            view:apply(event(3, "agent_message_chunk", { text = "turn two" }))
            -- Two turns -> the agent header is written twice.
            local _, headers = text():gsub("Agent", "Agent")
            assert.equal(2, headers)
        end
    )

    it("renders a user_prompt as a distinct user block", function()
        view:apply(event(1, "user_prompt", {
            session_id = "s1",
            text = "do the thing",
        }))
        local body = text()
        -- The human side of the conversation is now visible: a User header and
        -- the prompt text, not just agent output.
        assert.is_not_nil(body:find("User", 1, true))
        assert.is_not_nil(body:find("do the thing", 1, true))
    end)

    it("renders the user prompt before the agent's reply", function()
        view:apply(event(1, "user_prompt", { session_id = "s1", text = "ask" }))
        view:apply(event(2, "agent_message_chunk", { text = "answer" }))
        local body = text()
        local user_at = body:find("ask", 1, true)
        local agent_at = body:find("answer", 1, true)
        assert.is_not_nil(user_at)
        assert.is_not_nil(agent_at)
        assert.is_not_nil(body:find("User", 1, true))
        assert.is_not_nil(body:find("Agent", 1, true))
        assert.is_true(user_at < agent_at)
    end)

    it("notes attachment count on a user_prompt that carries them", function()
        view:apply(event(1, "user_prompt", {
            session_id = "s1",
            text = "look at these",
            attachments = 2,
        }))
        assert.is_not_nil(text():find("2 attachment", 1, true))
    end)

    it("renders an attachment-only prompt (empty text)", function()
        -- A file-only prompt carries no text but real attachments; it must still
        -- appear in the transcript (and on replay), not vanish.
        view:apply(event(1, "user_prompt", {
            session_id = "s1",
            text = "",
            attachments = 1,
        }))
        local body = text()
        assert.is_not_nil(body:find("User", 1, true))
        assert.is_not_nil(body:find("1 attachment", 1, true))
    end)

    it("ignores a user_prompt with no text and no attachments", function()
        view:apply(event(1, "user_prompt", { session_id = "s1", text = "" }))
        assert.same({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("renders an agent error inline", function()
        view:apply(event(1, "agent_error", { message = "boom" }))
        assert.is_not_nil(text():find("boom", 1, true))
    end)

    it("does not render approval or provider-notification events", function()
        view:apply(event(1, "approval_requested", { kind = "file_edit" }))
        view:apply(event(2, "approval_resolved", { approved = true }))
        view:apply(event(3, "provider_notification", { method = "x" }))
        -- The buffer keeps only its initial empty line.
        assert.same({ "" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("renders a summary record as a collapse marker", function()
        view:apply({
            kind = "summary",
            seq = 5,
            summary = { from_seq = 1, to_seq = 4 },
            payload = { text = "did some work" },
        })
        local body = text()
        assert.is_not_nil(body:find("summarized turns 1-4", 1, true))
        assert.is_not_nil(body:find("did some work", 1, true))
    end)

    it(
        "renders a summary sharing a seq with an already-rendered event",
        function()
            -- The contract lets a summary for [1, n] carry a seq already used by a
            -- raw event; dedup must not drop it (kind + seq, not seq alone).
            view:apply(event(1, "agent_message_chunk", { text = "first turn" }))
            view:apply({
                kind = "summary",
                seq = 1,
                summary = { from_seq = 1, to_seq = 3 },
                payload = { text = "summary of it" },
            })
            local body = text()
            assert.is_not_nil(body:find("first turn", 1, true))
            assert.is_not_nil(body:find("summarized turns 1-3", 1, true))
        end
    )
end)
