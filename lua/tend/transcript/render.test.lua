local assert = require("tests.helpers.assert")
local Render = require("tend.transcript.render")

local function event(type_, payload, extra)
    local e = { kind = "event", type = type_, payload = payload }
    for k, v in pairs(extra or {}) do
        e[k] = v
    end
    return e
end

describe("tend.transcript.render", function()
    it("renders an agent message chunk as its text lines", function()
        local lines = Render.render(event("agent_message_chunk", {
            text = "hello\nworld",
        }))
        assert.same(lines, { "hello", "world" })
    end)

    it("renders empty text as no lines", function()
        local lines = Render.render(event("agent_message_chunk", { text = "" }))
        assert.same(lines, {})
    end)

    it("drops a single trailing newline", function()
        local lines = Render.render(event("agent_message_chunk", {
            text = "one\n",
        }))
        assert.same(lines, { "one" })
    end)

    it("renders a tool call and update", function()
        assert.same(
            Render.render(event("tool_call", { name = "edit_file" })),
            { "tool: edit_file" }
        )
        assert.same(
            Render.render(event("tool_call_update", {
                tool_call_id = "tc1",
                status = "completed",
            })),
            { "  tc1 -> completed" }
        )
    end)

    it("renders turn_end as nothing", function()
        assert.same(Render.render(event("turn_end", {})), {})
    end)

    it("renders approvals", function()
        assert.same(
            Render.render(event("approval_requested", { kind = "file_edit" })),
            { "[approval needed] file_edit" }
        )
        assert.same(
            Render.render(event("approval_resolved", {
                approved = true,
                reason = "ok",
            })),
            { "[approval approved] ok" }
        )
        assert.same(
            Render.render(event("approval_resolved", { approved = false })),
            { "[approval denied]" }
        )
    end)

    it("renders an agent error", function()
        assert.same(
            Render.render(event("agent_error", { message = "boom" })),
            { "error: boom" }
        )
    end)

    it("renders an unknown type generically", function()
        assert.same(Render.render(event("mystery", {})), { "<mystery>" })
    end)

    it("renders a summary as a range marker with payload text", function()
        local lines = Render.render({
            kind = "summary",
            type = "summary",
            seq = 1,
            summary = { from_seq = 1, to_seq = 4 },
            payload = { text = "did three things" },
        })
        assert.same(lines, {
            "--- summarized turns 1-4 ---",
            "did three things",
        })
    end)
end)
