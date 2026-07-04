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

    it(
        "native 'unified' style renders one diff-filetype buffer per file",
        function()
            local state = child.lua([[
            local cfg = require("tend.config")
            cfg.diff_review.backend = "native"
            cfg.diff_review.style = "unified"
            local r = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "one\ntwo", after = "one\nTWO" },
            })
            local lines = vim.api.nvim_buf_get_lines(r[1].bufnr, 0, -1, false)
            return {
                count = #r,
                ft = vim.bo[r[1].bufnr].filetype,
                modifiable = vim.bo[r[1].bufnr].modifiable,
                body = table.concat(lines, "\n"),
            }
        ]])
            assert.equal(1, state.count)
            assert.equal("diff", state.ft)
            assert.is_false(state.modifiable)
            -- The unified hunk shows the removed and added line.
            assert.is_not_nil(state.body:find("-two", 1, true))
            assert.is_not_nil(state.body:find("+TWO", 1, true))
        end
    )

    it(
        "routes to a configured 'custom' renderer and returns its result",
        function()
            local seen = child.lua([[
            local cfg = require("tend.config")
            cfg.diff_review.backend = "custom"
            _G.seen = {}
            cfg.diff_review.renderer = function(change_set_id, files)
                _G.seen.change_set_id = change_set_id
                _G.seen.file_count = #files
                return { { uri = files[1].uri, tabpage = 0 } }
            end
            local r = _G.R.show_snapshots("cs-42", {
                { uri = _G.uri("a.go"), before = "x", after = "y" },
            })
            _G.seen.returned = #r
            return _G.seen
        ]])
            assert.equal("cs-42", seen.change_set_id)
            assert.equal(1, seen.file_count)
            assert.equal(1, seen.returned)
        end
    )

    it("falls back to native when 'custom' backend has no renderer", function()
        local rendered = child.lua([[
            local cfg = require("tend.config")
            cfg.diff_review.backend = "custom"
            cfg.diff_review.renderer = nil
            local r = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "a", after = "A" },
            })
            -- native split renders paired before/after scratch buffers.
            return { count = #r, has_pair = r[1].before_bufnr ~= nil and r[1].after_bufnr ~= nil }
        ]])
        assert.equal(1, rendered.count)
        assert.is_true(rendered.has_pair)
    end)

    it("mini_diff backend seeds after-content and reference text", function()
        local state = child.lua([[
            local cfg = require("tend.config")
            cfg.diff_review.backend = "mini_diff"
            _G.mini_calls = {}
            _G.R.get_mini_diff = function()
                return {
                    enable = function(b) _G.mini_calls.enabled = b end,
                    set_ref_text = function(b, t) _G.mini_calls.ref = t end,
                    toggle_overlay = function(b) _G.mini_calls.overlay = b end,
                }
            end
            local r = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "before-text", after = "after-text" },
            })
            return {
                count = #r,
                after = vim.api.nvim_buf_get_lines(r[1].bufnr, 0, -1, false),
                ref = _G.mini_calls.ref,
                enabled_is_buf = _G.mini_calls.enabled == r[1].bufnr,
            }
        ]])
        assert.equal(1, state.count)
        assert.same({ "after-text" }, state.after)
        assert.equal("before-text", state.ref)
        assert.is_true(state.enabled_is_buf)
    end)

    it(
        "mini_diff backend falls back to native when mini.diff is absent",
        function()
            local rendered = child.lua([[
            local cfg = require("tend.config")
            cfg.diff_review.backend = "mini_diff"
            _G.R.get_mini_diff = function() return nil end
            local r = _G.R.show_snapshots("cs-1", {
                { uri = _G.uri("a.go"), before = "a", after = "A" },
            })
            return { count = #r, has_pair = r[1].before_bufnr ~= nil and r[1].after_bufnr ~= nil }
        ]])
            assert.equal(1, rendered.count)
            assert.is_true(rendered.has_pair)
        end
    )
end)
