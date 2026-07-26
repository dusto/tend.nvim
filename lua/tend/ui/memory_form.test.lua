local assert = require("tests.helpers.assert")

describe("tend.ui.memory_form", function()
    local MemoryForm = require("tend.ui.memory_form")

    describe("parse", function()
        it("collects title, tags, and body", function()
            local fields = MemoryForm.parse({
                "# Title",
                "Auth flow",
                "",
                "# Tags (comma-separated)",
                "auth, api",
                "",
                "# Body",
                "The token refreshes",
                "on a 401.",
            })
            assert.equal("Auth flow", fields.title)
            assert.same({ "auth", "api" }, fields.tags)
            assert.equal("The token refreshes\non a 401.", fields.body)
        end)

        it("allows an empty title and drops empty tags", function()
            local fields = MemoryForm.parse({
                "# Title",
                "",
                "# Tags (comma-separated)",
                " a ,, b ,",
                "# Body",
                "just a body",
            })
            assert.equal("", fields.title)
            assert.same({ "a", "b" }, fields.tags)
            assert.equal("just a body", fields.body)
        end)

        it("reports an empty body when the section is blank", function()
            local fields = MemoryForm.parse(MemoryForm.template())
            assert.equal("", fields.body)
            assert.same({}, fields.tags)
        end)
    end)

    describe("template", function()
        it("seeds the body section from opts.body", function()
            local lines = MemoryForm.template({ body = "line one\nline two" })
            local fields = MemoryForm.parse(lines)
            assert.equal("line one\nline two", fields.body)
        end)
    end)

    describe("open", function()
        local handles = {}

        local function open(opts)
            local h = MemoryForm.open(opts)
            table.insert(handles, h)
            return h
        end

        after_each(function()
            vim.cmd("stopinsert")
            for _, h in ipairs(handles) do
                pcall(h.cancel)
            end
            handles = {}
        end)

        it(
            "opens a float, seeded with the body, resting in normal mode",
            function()
                local h =
                    open({ on_submit = function() end, body = "captured" })
                assert.is_true(vim.api.nvim_win_is_valid(h.win))
                local lines = vim.api.nvim_buf_get_lines(h.buf, 0, -1, false)
                assert.is_not_nil(
                    table.concat(lines, "\n"):find("captured", 1, true)
                )
                -- Not insert: otherwise `q`/`<Esc>` would not cancel on first press.
                assert.equal("n", vim.api.nvim_get_mode().mode)
            end
        )

        it("submit parses the buffer, calls on_submit, and closes", function()
            local got
            local h = open({
                on_submit = function(fields)
                    got = fields
                end,
            })
            vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, {
                "# Title",
                "A note",
                "# Body",
                "the body",
            })
            h.submit()
            assert.equal("A note", got.title)
            assert.equal("the body", got.body)
            assert.is_false(vim.api.nvim_win_is_valid(h.win))
        end)

        it("submit with no body is rejected and keeps the form open", function()
            local submitted = false
            local reason
            local h = open({
                on_submit = function()
                    submitted = true
                end,
                on_invalid = function(r)
                    reason = r
                end,
            })
            -- Template has a blank body.
            h.submit()
            assert.is_false(submitted)
            assert.is_not_nil(reason)
            assert.is_true(vim.api.nvim_win_is_valid(h.win))
        end)

        it("cancel closes the form and calls on_cancel", function()
            local cancelled = false
            local h = open({
                on_submit = function() end,
                on_cancel = function()
                    cancelled = true
                end,
            })
            h.cancel()
            assert.is_true(cancelled)
            assert.is_false(vim.api.nvim_win_is_valid(h.win))
        end)
    end)
end)
