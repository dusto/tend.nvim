local assert = require("tests.helpers.assert")

describe("tend.prompt_content", function()
    local PromptContent = require("tend.prompt_content")

    describe("file_block", function()
        it("maps a code file to a resource_link block", function()
            local block = PromptContent.file_block("lua/tend/init.lua")
            assert.equal("resource_link", block.type)
            assert.equal("init.lua", block.name)
            assert.is_not_nil(block.uri:find("^file://"))
            assert.is_not_nil(block.uri:find("init.lua", 1, true))
        end)

        it("maps an image file to an image block with base64 data", function()
            local path = vim.fn.tempname() .. ".png"
            local f = io.open(path, "wb")
            if not f then
                error("could not open temp file " .. path)
            end
            f:write("\137PNG\r\n\26\n") -- a few PNG-ish bytes
            f:close()

            local block = PromptContent.file_block(path)
            assert.equal("image", block.type)
            assert.equal("image/png", block.mime_type)
            assert.is_true(#block.data > 0)
            vim.fn.delete(path)
        end)
    end)

    describe("selection_block", function()
        it(
            "wraps a selection in <selected_code> with numbered lines",
            function()
                local block = PromptContent.selection_block({
                    lines = { "local x = 1", "return x" },
                    start_line = 10,
                    end_line = 11,
                    file_path = "lua/tend/init.lua",
                    file_type = "lua",
                })
                assert.equal("text", block.type)
                assert.is_not_nil(block.text:find("<selected_code>", 1, true))
                assert.is_not_nil(
                    block.text:find("<line_start>10</line_start>", 1, true)
                )
                assert.is_not_nil(
                    block.text:find("<line_end>11</line_end>", 1, true)
                )
                assert.is_not_nil(
                    block.text:find("Line 10: local x = 1", 1, true)
                )
                assert.is_not_nil(block.text:find("Line 11: return x", 1, true))
            end
        )
    end)

    describe("build", function()
        it("returns a single text block when no context is attached", function()
            local blocks = PromptContent.build({ text = "hello" })
            assert.same({ { type = "text", text = "hello" } }, blocks)
        end)

        it(
            "orders blocks: text, selection guidance + selections, files, diagnostics",
            function()
                local blocks = PromptContent.build({
                    text = "do it",
                    selections = {
                        {
                            lines = { "x" },
                            start_line = 1,
                            end_line = 1,
                            file_path = "a.lua",
                            file_type = "lua",
                        },
                    },
                    files = { "lua/tend/init.lua" },
                    diagnostics = {
                        {
                            type = "text",
                            text = "<diagnostic>oops</diagnostic>",
                        },
                    },
                })
                assert.equal("do it", blocks[1].text)
                -- Guidance precedes the selection block.
                assert.is_not_nil(blocks[2].text:find("line numbers", 1, true))
                assert.is_not_nil(
                    blocks[3].text:find("<selected_code>", 1, true)
                )
                assert.equal("resource_link", blocks[4].type)
                assert.equal("<diagnostic>oops</diagnostic>", blocks[5].text)
            end
        )

        it("skips empty selections", function()
            local blocks = PromptContent.build({
                text = "hi",
                selections = {
                    {
                        lines = {},
                        start_line = 1,
                        end_line = 1,
                        file_path = "a",
                        file_type = "lua",
                    },
                },
            })
            -- Only the text block and the guidance (no selection block for empties).
            assert.equal(1, #blocks)
        end)
    end)
end)
