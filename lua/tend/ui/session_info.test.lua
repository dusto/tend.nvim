local assert = require("tests.helpers.assert")

--- The tests inspect the view's internal buf/win handles to verify rendering and
--- in-place refresh; those fields are private to production callers and typed
--- optional, so poking them trips `invisible` and `param-type-mismatch`.
--- @diagnostic disable: invisible, param-type-mismatch

describe("tend.ui.session_info", function()
    local SessionInfo = require("tend.ui.session_info")
    local views = {}

    local function new_view()
        local v = SessionInfo.SessionInfoView.new()
        table.insert(views, v)
        return v
    end

    after_each(function()
        for _, v in ipairs(views) do
            v:close()
        end
        views = {}
    end)

    it("starts closed", function()
        assert.is_false(new_view():is_open())
    end)

    it("show opens a float rendering the lines", function()
        local v = new_view()
        v:show({ "# sess", "Context window: 1k" })
        assert.is_true(v:is_open())
        local buf = vim.api.nvim_win_get_buf(v.win)
        assert.same(
            { "# sess", "Context window: 1k" },
            vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        )
        assert.is_false(vim.bo[buf].modifiable)
    end)

    it(
        "refresh updates the open float in place without a new window",
        function()
            local v = new_view()
            v:show({ "one" })
            local win = v.win
            v:refresh({ "two", "three" })
            assert.equal(win, v.win)
            assert.same(
                { "two", "three" },
                vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)
            )
        end
    )

    it("show relocates the float to the current tab", function()
        local start_tab = vim.api.nvim_get_current_tabpage()
        local v = new_view()
        v:show({ "a" })
        local first_win = v.win
        vim.cmd("tabnew")
        v:show({ "b" })
        -- The float now lives in the current (new) tab, and the old window is
        -- gone rather than a stale, off-screen render.
        assert.equal(
            vim.api.nvim_get_current_tabpage(),
            vim.api.nvim_win_get_tabpage(v.win)
        )
        assert.is_false(vim.api.nvim_win_is_valid(first_win))
        v:close()
        if vim.api.nvim_get_current_tabpage() ~= start_tab then
            vim.cmd("tabclose")
        end
    end)

    it("refresh is a no-op when closed", function()
        local v = new_view()
        v:refresh({ "x" })
        assert.is_false(v:is_open())
    end)

    it("close is idempotent", function()
        local v = new_view()
        v:show({ "x" })
        v:close()
        assert.is_false(v:is_open())
        v:close()
        assert.is_false(v:is_open())
    end)
end)
