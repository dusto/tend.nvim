local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- The view drives buffers, floats, and buffer-local keymaps, so it runs in a
-- child Neovim process; the parent reads state back over RPC and asserts on it.
describe("tend.approval.view", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            local Model = require("tend.approval.model")
            local ViewMod = require("tend.approval.view")
            _G.responses = {}
            _G.model = Model.new()
            _G.view = ViewMod.View.new(_G.model, {
                respond = function(id, approved)
                    table.insert(_G.responses, { id = id, approved = approved })
                end,
            })
            _G.add = function(id, command)
                _G.model:add({
                    approval_id = id,
                    session_id = "ses-1",
                    kind = "pane_run",
                    detail = { pane_id = "pn-1", command = command, cwd = "/r" },
                })
            end
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    local function view_lines()
        return child.lua_get(
            "vim.api.nvim_buf_get_lines(_G.view:bufnr(), 0, -1, false)"
        )
    end

    it("show opens a focused float rendering the approval", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
        ]])
        assert.is_true(child.lua_get("_G.view:is_open()"))
        assert.equal(
            child.lua_get("_G.view:winid()"),
            child.lua_get("vim.api.nvim_get_current_win()")
        )
        local lines = view_lines()
        assert.equal("pane_run · session ses-1", lines[1])
        assert.is_true(vim.tbl_contains(lines, "command: make"))
    end)

    it("show is a no-op when nothing is pending", function()
        child.lua([[_G.view:show()]])
        assert.is_false(child.lua_get("_G.view:is_open()"))
    end)

    it("the approve key responds for the focused approval", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
        ]])
        child.type_keys("a")
        assert.same(
            { { id = "ap-1", approved = true } },
            child.lua_get("_G.responses")
        )
    end)

    it("the deny key responds with approved=false", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
        ]])
        child.type_keys("d")
        assert.same(
            { { id = "ap-1", approved = false } },
            child.lua_get("_G.responses")
        )
    end)

    it("next/prev cycle the rendered approval", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.add("ap-2", "ls")
            _G.view:show()
        ]])
        local lines = view_lines()
        assert.is_true(vim.tbl_contains(lines, "command: make"))
        assert.is_not_nil(lines[#lines]:find("1/2", 1, true))

        child.type_keys("n")
        assert.is_true(vim.tbl_contains(view_lines(), "command: ls"))
        child.type_keys("p")
        assert.is_true(vim.tbl_contains(view_lines(), "command: make"))
    end)

    it("the hide key closes the float and keeps approvals pending", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
        ]])
        child.type_keys("q")
        assert.is_false(child.lua_get("_G.view:is_open()"))
        assert.equal(1, child.lua_get("_G.model:count()"))
        child.lua([[_G.view:refresh()]])
        assert.is_false(child.lua_get("_G.view:is_open()"))
    end)

    it("refresh closes the float when the model empties", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
            _G.model:resolve("ap-1")
            _G.view:refresh()
        ]])
        assert.is_false(child.lua_get("_G.view:is_open()"))
    end)

    it("refresh repaints the open float in place", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
            _G.add("ap-2", "ls")
            _G.view:refresh()
        ]])
        local lines = view_lines()
        assert.is_not_nil(lines[#lines]:find("1/2", 1, true))
    end)

    it("show moves the float to the current tabpage", function()
        child.lua([[
            _G.add("ap-1", "make")
            _G.view:show()
            vim.cmd("tabnew")
            _G.view:show()
        ]])
        assert.is_true(child.lua_get("_G.view:is_open()"))
        assert.equal(
            child.lua_get("vim.api.nvim_win_get_tabpage(_G.view:winid())"),
            child.lua_get("vim.api.nvim_get_current_tabpage()")
        )
    end)

    it("paints highlight marks for diff lines", function()
        child.lua([[
            _G.model:add({
                approval_id = "ap-3",
                session_id = "ses-1",
                kind = "file_edit",
                detail = {
                    change_set_id = "cs-1",
                    targets = {
                        {
                            uri = "a.go",
                            base = { changedtick = 1 },
                            diff = "@@ -1 +1 @@\n-old\n+new",
                        },
                    },
                },
            })
            _G.view:show()
        ]])
        local groups = child.lua([[
            local ns = vim.api.nvim_create_namespace("tend_approval")
            local marks = vim.api.nvim_buf_get_extmarks(
                _G.view:bufnr(), ns, 0, -1, { details = true }
            )
            local groups = {}
            for _, m in ipairs(marks) do
                groups[m[4].hl_group] = true
            end
            return groups
        ]])
        assert.is_true(groups.Added)
        assert.is_true(groups.Removed)
        assert.is_true(groups.Changed)
    end)
end)
