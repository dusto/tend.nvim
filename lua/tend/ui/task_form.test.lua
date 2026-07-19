local assert = require("tests.helpers.assert")

describe("tend.ui.task_form", function()
    local TaskForm = require("tend.ui.task_form")

    describe("parse", function()
        it("collects every field from a filled form", function()
            local fields = TaskForm.parse({
                "# Title",
                "Add retries",
                "",
                "# Description",
                "The client should retry",
                "on 5xx responses.",
                "",
                "# Acceptance criteria",
                "Retries up to 3 times.",
                "",
                "# Labels (comma-separated)",
                "net, resilience",
                "",
                "# Priority (0-4, blank to omit)",
                "1",
            })
            assert.equal("Add retries", fields.title)
            assert.equal(
                "The client should retry\non 5xx responses.",
                fields.description
            )
            assert.equal("Retries up to 3 times.", fields.acceptance_criteria)
            assert.same({ "net", "resilience" }, fields.labels)
            assert.equal("1", fields.priority)
        end)

        it("reports an empty title when the section is blank", function()
            local fields = TaskForm.parse(TaskForm.template())
            assert.equal("", fields.title)
            assert.same({}, fields.labels)
            assert.equal("", fields.priority)
        end)

        it("splits labels on commas and drops empty entries", function()
            local fields = TaskForm.parse({
                "# Title",
                "x",
                "# Labels (comma-separated)",
                " a ,, b ,c,",
            })
            assert.same({ "a", "b", "c" }, fields.labels)
        end)

        it(
            "ignores unknown headings and keeps section bodies trimmed",
            function()
                local fields = TaskForm.parse({
                    "# Notes (ignored)",
                    "junk",
                    "# Title",
                    "",
                    "  spaced title  ",
                    "",
                })
                assert.equal("spaced title", fields.title)
                assert.equal("", fields.description)
            end
        )
    end)

    describe("open", function()
        local handles = {}

        local function open(opts)
            local h = TaskForm.open(opts)
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

        it("opens a float seeded with the template", function()
            local h = open({ on_submit = function() end })
            assert.is_true(vim.api.nvim_win_is_valid(h.win))
            assert.same(
                TaskForm.template(),
                vim.api.nvim_buf_get_lines(h.buf, 0, -1, false)
            )
        end)

        it(
            "rests in normal mode so cancel/submit keys fire on first press",
            function()
                open({ on_submit = function() end })
                -- Not insert: otherwise `q` would type a literal "q" and `<Esc>`
                -- would only leave insert instead of cancelling.
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
                "Ship it",
                "# Priority (0-4, blank to omit)",
                "0",
            })
            h.submit()
            assert.equal("Ship it", got.title)
            assert.equal("0", got.priority)
            assert.is_false(vim.api.nvim_win_is_valid(h.win))
        end)

        it(
            "submit with no title is rejected and keeps the form open",
            function()
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
                -- Template has a blank title.
                h.submit()
                assert.is_false(submitted)
                assert.is_not_nil(reason)
                assert.is_true(vim.api.nvim_win_is_valid(h.win))
            end
        )

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
