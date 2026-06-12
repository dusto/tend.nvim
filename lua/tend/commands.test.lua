local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- Commands register user commands and drive buffers/windows/vim.ui, so they run
-- in a child Neovim process against a scripted fake connection; the parent
-- inspects the recorded daemon calls and editor state over RPC.
describe("tend.commands", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            -- Scripted UI: tests set _G.ui_choice (index) and _G.ui_input.
            vim.ui.select = function(items, _, on_choice)
                _G.ui_items = items
                if _G.ui_choice then
                    on_choice(items[_G.ui_choice], _G.ui_choice)
                else
                    on_choice(nil, nil)
                end
            end
            vim.ui.input = function(_, on_confirm)
                on_confirm(_G.ui_input)
            end

            -- Capture notifications.
            _G.notices = {}
            local Logger = require("tend.utils.logger")
            Logger.notify = function(msg, level)
                table.insert(_G.notices, { msg = msg, level = level })
            end

            -- A scripted connection: requests are recorded and answered from
            -- _G.replies[method] = { err = ..., result = ... }.
            _G.calls = {}
            _G.replies = {}
            _G.conn = {
                started = 0,
                subscriber = {
                    tracked = {},
                    track = function(self, spec)
                        table.insert(self.tracked, spec)
                    end,
                },
                approvals = {
                    syncs = 0,
                    events = {},
                    sync = function(self, cb)
                        self.syncs = self.syncs + 1
                        if cb then
                            cb(nil, _G.pending_count or 0)
                        end
                    end,
                    handle_event = function(self, event)
                        table.insert(self.events, event)
                    end,
                },
                start = function(self)
                    self.started = self.started + 1
                end,
                stops = 0,
                stop = function(self)
                    self.stops = self.stops + 1
                end,
                when_connected = function(_, cb)
                    cb()
                end,
                request = function(_, method, params, cb)
                    table.insert(_G.calls, { method = method, params = params })
                    local reply = _G.replies[method]
                    if reply and cb then
                        cb(reply.err, reply.result)
                    end
                end,
            }

            _G.ctx = require("tend.commands").setup({
                connection = _G.conn,
                providers = { "codex", "claude" },
                assignee = "dustin",
                persona_dirs = { "/tmp/tend-test-personas" },
            })

            -- Common fixtures.
            _G.give_workspace = function()
                _G.ctx.workspace = {
                    workspace_id = "ws-1",
                    worktree_root = "/repo",
                }
            end
            _G.give_task = function()
                _G.ctx.task = {
                    ref = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
                    title = "fix bug",
                    status = "open",
                }
            end
            _G.give_session = function()
                _G.give_workspace()
                _G.replies["agent.start"] = {
                    result = {
                        session_id = "ses-1",
                        stream_id = "str-1",
                        status = "idle",
                    },
                }
                _G.give_task()
                _G.ctx.provider_id = "codex"
                _G.ui_input = "go"
                vim.cmd("TendDelegate")
            end
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    local function calls()
        return child.lua_get("_G.calls")
    end

    local function last_notice()
        return child.lua_get("_G.notices[#_G.notices] or {}")
    end

    it("registers the core commands", function()
        local names = child.lua([[
            local out = {}
            for name in pairs(vim.api.nvim_get_commands({})) do
                if name:find("^Tend") then
                    out[name] = true
                end
            end
            return out
        ]])
        for _, name in ipairs({
            "TendAttach",
            "TendTaskNew",
            "TendTaskPick",
            "TendClaim",
            "TendProvider",
            "TendPersona",
            "TendDelegate",
            "TendChat",
            "TendEvents",
            "TendApprove",
        }) do
            assert.is_true(names[name] == true)
        end
    end)

    it(
        "TendAttach starts the connection and opens the cwd workspace",
        function()
            child.lua([[
            _G.replies["workspace.open"] = {
                result = { workspace_id = "ws-1", worktree_root = "/repo" },
            }
            vim.cmd("TendAttach")
        ]])
            assert.equal(1, child.lua_get("_G.conn.started"))
            local sent = calls()
            assert.equal("workspace.open", sent[1].method)
            assert.equal(child.lua_get("vim.fn.getcwd()"), sent[1].params.dir)
            assert.equal("ws-1", child.lua_get("_G.ctx.workspace.workspace_id"))
        end
    )

    it("TendTaskNew requires a workspace", function()
        child.lua([[vim.cmd("TendTaskNew")]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("TendAttach", 1, true))
    end)

    it("TendTaskNew creates a task from the entered title", function()
        child.lua([[
            _G.give_workspace()
            _G.ui_input = "fix the bug"
            _G.replies["task.create"] = {
                result = {
                    ref = { provider = "beads", workspace_id = "ws-1", id = "t-9" },
                    title = "fix the bug",
                    status = "open",
                },
            }
            vim.cmd("TendTaskNew")
        ]])
        local sent = calls()
        assert.equal("task.create", sent[1].method)
        assert.same(
            { workspace_id = "ws-1", title = "fix the bug" },
            sent[1].params
        )
        assert.equal("t-9", child.lua_get("_G.ctx.task.ref.id"))
    end)

    it("TendTaskNew aborts on an empty title", function()
        child.lua([[
            _G.give_workspace()
            _G.ui_input = nil
            vim.cmd("TendTaskNew")
        ]])
        assert.same({}, calls())
    end)

    it("TendTaskPick selects the current task from the list", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["task.list"] = {
                result = {
                    tasks = {
                        {
                            ref = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
                            title = "one",
                            status = "open",
                        },
                        {
                            ref = { provider = "beads", workspace_id = "ws-1", id = "t-2" },
                            title = "two",
                            status = "open",
                        },
                    },
                },
            }
            _G.ui_choice = 2
            vim.cmd("TendTaskPick")
        ]])
        local sent = calls()
        assert.equal("task.list", sent[1].method)
        assert.same({ workspace_id = "ws-1" }, sent[1].params)
        assert.equal("t-2", child.lua_get("_G.ctx.task.ref.id"))
    end)

    it("TendClaim claims the current task for the assignee", function()
        child.lua([[
            _G.give_task()
            _G.replies["task.claim"] = {
                result = {
                    ref = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
                    title = "fix bug",
                    status = "in_progress",
                    assignee = "dustin",
                },
            }
            vim.cmd("TendClaim")
        ]])
        local sent = calls()
        assert.equal("task.claim", sent[1].method)
        assert.equal("dustin", sent[1].params.assignee)
        assert.equal("t-1", sent[1].params.ref.id)
        assert.equal("in_progress", child.lua_get("_G.ctx.task.status"))
    end)

    it("TendClaim without a task reports instead of calling", function()
        child.lua([[vim.cmd("TendClaim")]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("task", 1, true))
    end)

    it("TendProvider picks from the configured providers", function()
        child.lua([[
            _G.ui_choice = 2
            vim.cmd("TendProvider")
        ]])
        assert.equal("claude", child.lua_get("_G.ctx.provider_id"))
    end)

    it("TendPersona picks from the persona directories", function()
        child.lua([[
            vim.fn.mkdir("/tmp/tend-test-personas", "p")
            vim.fn.writefile({ "reviewer prompt" }, "/tmp/tend-test-personas/reviewer.md")
            vim.fn.writefile({ "planner prompt" }, "/tmp/tend-test-personas/planner.md")
            _G.ui_choice = 1
            vim.cmd("TendPersona")
        ]])
        local ids = child.lua([[
            return vim.tbl_map(function(p)
                return p.id
            end, _G.ui_items)
        ]])
        assert.same({ "planner", "reviewer" }, ids)
        assert.equal("planner", child.lua_get("_G.ctx.persona_id"))
        assert.equal("planner prompt", child.lua_get("_G.ctx.persona.prompt"))
        child.lua([[vim.fn.delete("/tmp/tend-test-personas", "rf")]])
    end)

    it("TendPersona imports harness agents from the workspace", function()
        child.lua([[
            local ws = vim.fn.tempname()
            vim.fn.mkdir(ws .. "/.claude/agents", "p")
            vim.fn.writefile({
                "---",
                "name: reviewer",
                "description: PR review agent",
                "---",
                "Review the diff.",
            }, ws .. "/.claude/agents/reviewer.md")
            _G.ctx.workspace = { workspace_id = "ws-1", worktree_root = ws }
            _G.ui_choice = 1
            vim.cmd("TendPersona")
            vim.fn.delete(ws, "rf")
        ]])
        assert.equal("claude:reviewer", child.lua_get("_G.ctx.persona_id"))
        assert.equal("Review the diff.", child.lua_get("_G.ctx.persona.prompt"))
    end)

    it("TendDelegate starts a session and sends the first prompt", function()
        child.lua([[_G.give_session()]])
        local sent = calls()
        assert.equal("agent.start", sent[1].method)
        assert.same({
            provider_id = "codex",
            task = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
            worktree_root = "/repo",
        }, sent[1].params)
        assert.equal("agent.prompt", sent[2].method)
        assert.same({ session_id = "ses-1", text = "go" }, sent[2].params)
        assert.equal("ses-1", child.lua_get("_G.ctx.session.session_id"))
        assert.equal(
            "str-1",
            child.lua_get("_G.conn.subscriber.tracked[1].stream_id")
        )
        assert.equal(
            "ws-1",
            child.lua_get("_G.conn.subscriber.tracked[1].workspace_id")
        )
    end)

    it("TendDelegate without a task reports instead of calling", function()
        child.lua([[
            _G.give_workspace()
            vim.cmd("TendDelegate")
        ]])
        assert.same({}, calls())
    end)

    it("session events fan out to the transcript and approvals", function()
        child.lua([[
            _G.give_session()
            _G.conn.subscriber.tracked[1].on_event({
                kind = "event",
                type = "agent_message_chunk",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { text = "hello there" },
            })
        ]])
        local lines = child.lua_get(
            "vim.api.nvim_buf_get_lines(_G.ctx.session.bufnr, 0, -1, false)"
        )
        assert.same({ "hello there" }, lines)
        assert.equal(
            "agent_message_chunk",
            child.lua_get("_G.conn.approvals.events[1].type")
        )
    end)

    it("TendChat prompts the current session", function()
        child.lua([[
            _G.give_session()
            _G.calls = {}
            _G.ui_input = "and then?"
            vim.cmd("TendChat")
        ]])
        local sent = calls()
        assert.equal("agent.prompt", sent[1].method)
        assert.same(
            { session_id = "ses-1", text = "and then?" },
            sent[1].params
        )
    end)

    it("TendChat without a session reports instead of calling", function()
        child.lua([[vim.cmd("TendChat")]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("TendDelegate", 1, true))
    end)

    it("TendEvents opens the transcript buffer in a window", function()
        child.lua([[
            _G.give_session()
            vim.cmd("TendEvents")
        ]])
        local shown = child.lua([[
            local bufnr = _G.ctx.session.bufnr
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if vim.api.nvim_win_get_buf(win) == bufnr then
                    return true
                end
            end
            return false
        ]])
        assert.is_true(shown)
    end)

    it("setup stops the previous context's connection", function()
        child.lua([[
            require("tend.commands").setup({
                connection = { stop = function() end },
            })
        ]])
        assert.equal(1, child.lua_get("_G.conn.stops"))
    end)

    it("re-running plugin setup rebuilds the command context", function()
        child.lua([[
            require("tend").setup({ daemon = { providers = { "zed" } } })
            _G.ui_choice = 1
            vim.cmd("TendProvider")
        ]])
        local provider = child.lua([[
            local ctx = require("tend.commands").current()
            return ctx and ctx.provider_id or "no-context"
        ]])
        assert.equal("zed", provider)
    end)

    it("TendApprove syncs and reports when nothing is pending", function()
        child.lua([[
            _G.pending_count = 0
            vim.cmd("TendApprove")
        ]])
        assert.equal(1, child.lua_get("_G.conn.approvals.syncs"))
        assert.is_not_nil(last_notice().msg:find("pending", 1, true))
    end)
end)
