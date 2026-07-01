local assert = require("tests.helpers.assert")

describe("tend.ui.slash_complete", function()
    local Slash = require("tend.ui.slash_complete")

    describe("parse", function()
        it("returns nil for a non-slash line", function()
            assert.is_nil(Slash.parse(""))
            assert.is_nil(Slash.parse("hello"))
            assert.is_nil(Slash.parse(" /leading-space"))
        end)

        it("parses a command-name context (no space yet)", function()
            assert.same(
                { kind = "name", prefix = "", start = 1 },
                Slash.parse("/")
            )
            assert.same(
                { kind = "name", prefix = "comm", start = 1 },
                Slash.parse("/comm")
            )
        end)

        it(
            "parses an argument context after the command and a space",
            function()
                assert.same({
                    kind = "arg",
                    command = "comment",
                    prefix = "",
                    start = 9,
                }, Slash.parse("/comment "))
                assert.same({
                    kind = "arg",
                    command = "comment",
                    prefix = "t-1",
                    start = 9,
                }, Slash.parse("/comment t-1"))
            end
        )

        it("does not complete past the first argument token", function()
            -- Free-form text after the first token is not completed.
            assert.is_nil(Slash.parse("/comment t-1 some message"))
        end)
    end)

    describe("name_items", function()
        it("maps commands to complete-items with a slash abbr", function()
            local items = Slash.name_items({
                { name = "tasks", description = "List tasks", arg_hint = "" },
                {
                    name = "comment",
                    description = "Comment on a task",
                    arg_hint = "<task-id> <text>",
                },
            })
            assert.equal("tasks", items[1].word)
            assert.equal("/tasks", items[1].abbr)
            assert.equal("List tasks", items[1].info)
            assert.equal("comment", items[2].word)
            assert.equal("<task-id> <text>", items[2].menu)
        end)

        it("skips commands whose name contains whitespace", function()
            local items = Slash.name_items({
                { name = "ok" },
                { name = "not ok" },
            })
            assert.equal(1, #items)
            assert.equal("ok", items[1].word)
        end)
    end)

    describe("arg_items", function()
        it(
            "maps candidates to complete-items with the detail as menu",
            function()
                local items = Slash.arg_items({
                    { value = "t-1", detail = "fix the bug" },
                    { value = "t-2" },
                })
                assert.equal("t-1", items[1].word)
                assert.equal("fix the bug", items[1].menu)
                assert.equal("t-2", items[2].word)
                assert.equal("", items[2].menu)
            end
        )
    end)

    describe("complete_func", function()
        it("returns the stored start column and items", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_set_current_buf(bufnr)
            vim.b[bufnr].tend_slash_start = 1
            vim.b[bufnr].tend_slash_items = { { word = "tasks" } }
            assert.equal(1, Slash.complete_func(1, ""))
            assert.same({ { word = "tasks" } }, Slash.complete_func(0, ""))
        end)

        it("cancels completion when no state is set", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_set_current_buf(bufnr)
            assert.equal(-3, Slash.complete_func(1, ""))
            assert.same({}, Slash.complete_func(0, ""))
        end)
    end)
end)
