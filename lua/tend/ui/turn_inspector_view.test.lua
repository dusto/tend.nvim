local assert = require("tests.helpers.assert")

--- The tests poke the view's private buf/win handles to verify rendering.
--- @diagnostic disable: invisible, param-type-mismatch

describe("tend.ui.turn_inspector_view", function()
    local Inspector = require("tend.ui.turn_inspector_view")
    local views = {}

    local function new_view()
        local v = Inspector.TurnInspectorView.new()
        table.insert(views, v)
        return v
    end

    after_each(function()
        for _, v in ipairs(views) do
            v:close()
        end
        views = {}
    end)

    describe("fold_level", function()
        it("starts a fold at a level-2 heading, continues otherwise", function()
            assert.equal(">1", Inspector.fold_level("## Prompt"))
            assert.equal(">1", Inspector.fold_level("## Tools & MCP"))
            assert.equal("=", Inspector.fold_level("some body text"))
            assert.equal("=", Inspector.fold_level("# Title"))
            assert.equal("=", Inspector.fold_level(""))
        end)
    end)

    it("starts closed", function()
        assert.is_false(new_view():is_open())
    end)

    it("show opens a float rendering the lines, read-only", function()
        local v = new_view()
        v:show({ "## Prompt", "hello" })
        assert.is_true(v:is_open())
        local buf = vim.api.nvim_win_get_buf(v.win)
        assert.same(
            { "## Prompt", "hello" },
            vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        )
        assert.is_false(vim.bo[buf].modifiable)
        -- Section folds are enabled on the float window.
        assert.equal("expr", vim.wo[v.win].foldmethod)
    end)

    it("close is idempotent and drops the window", function()
        local v = new_view()
        v:show({ "## Prompt" })
        v:close()
        assert.is_false(v:is_open())
        v:close() -- no error on a second close
        assert.is_false(v:is_open())
    end)
end)
