local assert = require("tests.helpers.assert")

describe("tend.transcript.turn_inspector", function()
    local Inspector = require("tend.transcript.turn_inspector")

    --- @return string
    local function joined(record)
        return table.concat(Inspector.render(record), "\n")
    end

    it("always renders all four headed sections", function()
        local body = joined(nil)
        for _, h in ipairs({
            "## Prompt",
            "## Context",
            "## Tokens",
            "## Tools & MCP",
        }) do
            assert.is_not_nil(body:find(h, 1, true))
        end
        -- Empty record shows placeholders, not blank sections.
        assert.is_not_nil(body:find("_(no prompt text)_", 1, true))
        assert.is_not_nil(body:find("_(none)_", 1, true))
    end)

    it("renders prompt text, attachments, and estimate", function()
        local body = joined({
            prompt = { text = "do the thing", attachments = 2 },
            prompt_usage = { tokens_approx = 1180, text_bytes = 4900 },
            tools = {},
        })
        assert.is_not_nil(body:find("do the thing", 1, true))
        assert.is_not_nil(body:find("Attachments: 2", 1, true))
        assert.is_not_nil(body:find("~1,180 tokens", 1, true))
    end)

    it("renders context window fill and token counts", function()
        local body = joined({
            context = { used_tokens = 18000, window_tokens = 100000 },
            tokens = {
                input_tokens = 1200,
                output_tokens = 3400,
                total_tokens = 4600,
            },
            tools = {},
        })
        assert.is_not_nil(body:find("18%", 1, true))
        assert.is_not_nil(
            body:find("In 1,200 · Out 3,400 · Total 4,600", 1, true)
        )
    end)

    it("lists tool calls with their status", function()
        local body = joined({
            tools = {
                { id = "tc-1", name = "read_file", status = "completed" },
                { id = "tc-2", name = "edit_buffer", status = "pending" },
            },
        })
        assert.is_not_nil(body:find("read_file — completed", 1, true))
        assert.is_not_nil(body:find("edit_buffer — pending", 1, true))
    end)
end)
