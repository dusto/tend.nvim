local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- diff_review drives buffers, windows, tabs, and native diff mode, so it runs
-- in a child Neovim; the parent reads state back over RPC.
describe("tend.ui.diff_review", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            _G.R = require("tend.ui.diff_review")
            _G.tmp = vim.fn.tempname()
            vim.fn.mkdir(_G.tmp, "p")
            _G.uri = function(name)
                return vim.uri_from_fname(_G.tmp .. "/" .. name)
            end
            _G.write = function(name, text)
                vim.fn.writefile(vim.split(text, "\n"), _G.tmp .. "/" .. name)
            end
        ]])
    end)

    after_each(function()
        pcall(child.lua, [[vim.fn.delete(_G.tmp, "rf")]])
        child.stop()
    end)

    it("open_files opens each file, focusing only the first", function()
        local first = child.lua([[
            _G.write("a.go", "package a")
            _G.write("b.go", "package b")
            local bufs = _G.R.open_files({ _G.uri("a.go"), _G.uri("b.go") })
            _G.bufs = bufs
            return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
        ]])
        assert.equal(2, child.lua_get("#_G.bufs"))
        -- The first file is the focused buffer; the second is loaded but not focused.
        assert.is_not_nil(first:find("a.go", 1, true))
        local loaded = child.lua([[
            return {
                vim.api.nvim_buf_is_loaded(_G.bufs[1]),
                vim.api.nvim_buf_is_loaded(_G.bufs[2]),
            }
        ]])
        assert.is_true(loaded[1])
        assert.is_true(loaded[2])
    end)

    it("open_files skips non-file uris", function()
        local n = child.lua_get(
            [[#_G.R.open_files({ "http://example.com/x", "tel:123" })]]
        )
        assert.equal(0, n)
    end)

    it("show_snapshots renders before/after in a diff tab per file", function()
        child.lua([[
            _G.rendered = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "one\ntwo", after = "one\nTWO" },
            })
        ]])
        assert.equal(1, child.lua_get("#_G.rendered"))

        local before = child.lua_get(
            "vim.api.nvim_buf_get_lines(_G.rendered[1].before_bufnr, 0, -1, false)"
        )
        local after = child.lua_get(
            "vim.api.nvim_buf_get_lines(_G.rendered[1].after_bufnr, 0, -1, false)"
        )
        assert.same({ "one", "two" }, before)
        assert.same({ "one", "TWO" }, after)
    end)

    it("snapshot buffers are read-only and in diff mode", function()
        local state = child.lua([[
            local r = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "x", after = "y" },
            })[1]
            vim.api.nvim_set_current_tabpage(r.tabpage)
            local diffs = {}
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(r.tabpage)) do
                table.insert(diffs, vim.wo[win].diff)
            end
            return {
                before_mod = vim.bo[r.before_bufnr].modifiable,
                after_mod = vim.bo[r.after_bufnr].modifiable,
                diffs = diffs,
            }
        ]])
        assert.is_false(state.before_mod)
        assert.is_false(state.after_mod)
        -- Both windows in the tab are in diff mode.
        for _, d in ipairs(state.diffs) do
            assert.is_true(d)
        end
    end)

    it("renders one tab per file for a multi-file set", function()
        local tabs_before = child.lua_get("#vim.api.nvim_list_tabpages()")
        child.lua([[
            _G.rendered = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "a", after = "A" },
                { uri = _G.uri("b.go"), before = "b", after = "B" },
            })
        ]])
        assert.equal(2, child.lua_get("#_G.rendered"))
        -- Two new tabs (one per file).
        local tabs_after = child.lua_get("#vim.api.nvim_list_tabpages()")
        assert.equal(tabs_before + 2, tabs_after)
        assert.is_true(
            child.lua_get("_G.rendered[1].tabpage ~= _G.rendered[2].tabpage")
        )
    end)

    it("show_snapshots with no files renders nothing", function()
        assert.equal(0, child.lua_get([[#_G.R.show_snapshots("cs-1", {})]]))
    end)
end)
