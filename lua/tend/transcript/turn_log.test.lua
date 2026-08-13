local assert = require("tests.helpers.assert")

describe("tend.transcript.turn_log", function()
    local TurnLog = require("tend.transcript.turn_log").TurnLog

    local function ev(type_, payload)
        return { type = type_, payload = payload }
    end

    it("starts with one open turn and no sealed turns", function()
        local log = TurnLog.new()
        assert.equal(1, log:count())
        assert.is_not_nil(log:record(1))
        assert.is_nil(log:record(2))
    end)

    it("collects a turn's prompt, usage, tokens, context, and tools", function()
        local log = TurnLog.new()
        log:apply(ev("user_prompt", { text = "hello", attachments = 1 }))
        log:apply(ev("agent_prompt_usage", { tokens_approx = 42 }))
        log:apply(
            ev("tool_call", { tool_call_id = "tc-1", name = "read_file" })
        )
        log:apply(ev("tool_call_update", {
            tool_call_id = "tc-1",
            status = "completed",
        }))
        log:apply(ev("agent_token_usage", {
            input_tokens = 100,
            output_tokens = 200,
            total_tokens = 300,
        }))
        log:apply(ev("agent_context_usage", {
            used_tokens = 18000,
            window_tokens = 100000,
        }))

        local turn = log:record(1)
        assert.is_not_nil(turn)
        --- @cast turn tend.transcript.TurnRecord
        assert.equal("hello", turn.prompt.text)
        assert.equal(1, turn.prompt.attachments)
        assert.equal(42, turn.prompt_usage.tokens_approx)
        assert.equal(100, turn.tokens.input_tokens)
        assert.equal(18000, turn.context.used_tokens)
        assert.equal(1, #turn.tools)
        assert.equal("read_file", turn.tools[1].name)
        assert.equal("completed", turn.tools[1].status)
    end)

    it("seals a turn on turn_end and opens a fresh one", function()
        local log = TurnLog.new()
        log:apply(ev("user_prompt", { text = "one" }))
        log:apply(ev("turn_end", {}))
        assert.equal(2, log:count())
        -- Turn 1 sealed, turn 2 is the fresh open turn.
        assert.equal("one", log:record(1).prompt.text)
        assert.is_nil(log:record(2).prompt)
        assert.same({}, log:record(2).tools)

        log:apply(ev("user_prompt", { text = "two" }))
        assert.equal("two", log:record(2).prompt.text)
    end)

    it("keeps each turn's tools separate across turns", function()
        local log = TurnLog.new()
        log:apply(ev("tool_call", { tool_call_id = "a", name = "first" }))
        log:apply(ev("turn_end", {}))
        log:apply(ev("tool_call", { tool_call_id = "b", name = "second" }))
        assert.equal(1, #log:record(1).tools)
        assert.equal("first", log:record(1).tools[1].name)
        assert.equal(1, #log:record(2).tools)
        assert.equal("second", log:record(2).tools[1].name)
    end)

    it("ignores unrelated and malformed events", function()
        local log = TurnLog.new()
        assert.is_false(log:apply(ev("agent_message_chunk", { text = "x" })))
        --- @diagnostic disable-next-line: param-type-mismatch
        assert.is_false(log:apply("nope"))
        assert.equal(1, log:count())
    end)
end)
