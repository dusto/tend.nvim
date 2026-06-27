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
            -- Scripted UI: tests set _G.ui_choice (one index) or _G.ui_choices
            -- (a queue of indices, consumed in order across sequential selects),
            -- and _G.ui_input.
            vim.ui.select = function(items, _, on_choice)
                _G.ui_items = items
                local idx = _G.ui_choice
                if _G.ui_choices and #_G.ui_choices > 0 then
                    idx = table.remove(_G.ui_choices, 1)
                end
                if idx then
                    on_choice(items[idx], idx)
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
                    untracked = {},
                    track = function(self, spec)
                        table.insert(self.tracked, spec)
                    end,
                    untrack = function(self, stream_id)
                        table.insert(self.untracked, stream_id)
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
            -- Start and focus a task-less session ses-1 via :TendSessionNew
            -- (provider #1 = codex). Resets ui_choice afterward so a test's own
            -- selection is not shadowed.
            _G.give_session = function()
                _G.give_workspace()
                _G.replies["agent.start"] = {
                    result = {
                        session_id = "ses-1",
                        stream_id = "str-1",
                        status = "idle",
                    },
                }
                _G.ui_choice = 1
                vim.cmd("TendSessionNew")
                _G.ui_choice = nil
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
            "TendConnect",
            "TendTaskNew",
            "TendTaskPick",
            "TendClaim",
            "TendProvider",
            "TendPersona",
            "TendSessionNew",
            "TendSessionAttach",
            "TendSessionDisconnect",
            "TendChat",
            "TendEvents",
            "TendApprove",
            "TendOpenChanges",
            "TendDiff",
        }) do
            assert.is_true(names[name] == true)
        end
        -- The old verbs are gone (renamed / folded into :TendTaskPick).
        for _, gone in ipairs({
            "TendAttach",
            "TendDelegate",
            "TendDelegateTo",
            "TendSessions",
        }) do
            assert.is_nil(names[gone])
        end
    end)

    it(
        "TendConnect starts the connection and opens the cwd workspace",
        function()
            child.lua([[
            _G.replies["workspace.open"] = {
                result = { workspace_id = "ws-1", worktree_root = "/repo" },
            }
            vim.cmd("TendConnect")
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
        assert.is_not_nil(last_notice().msg:find("TendConnect", 1, true))
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

    it("TendTaskPick delegates the picked task to a new session", function()
        child.lua([[
            _G.give_workspace()
            _G.ctx.provider_id = "codex"
            _G.replies["task.list"] = {
                result = {
                    tasks = {
                        {
                            ref = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
                            title = "one",
                            status = "open",
                            description = "do one",
                        },
                        {
                            ref = { provider = "beads", workspace_id = "ws-1", id = "t-2" },
                            title = "two",
                            status = "open",
                        },
                    },
                },
            }
            _G.replies["session.list"] = { result = { sessions = {} } }
            _G.replies["agent.start"] = {
                result = { session_id = "ses-N", stream_id = "str-N", status = "idle" },
            }
            _G.ui_choices = { 1, 1 } -- task #1, then target #1 = "+ New session"
            vim.cmd("TendTaskPick")
        ]])
        local sent = calls()
        assert.equal("task.list", sent[1].method)
        assert.same({ workspace_id = "ws-1" }, sent[1].params)
        assert.equal("session.list", sent[2].method)
        -- A new session is started bound to the task, then handed the task.
        assert.equal("agent.start", sent[3].method)
        assert.same({
            provider_id = "codex",
            workspace_id = "ws-1",
            worktree_root = "/repo",
            task = { provider = "beads", workspace_id = "ws-1", id = "t-1" },
        }, sent[3].params)
        assert.equal("agent.prompt", sent[4].method)
        assert.equal("ses-N", sent[4].params.session_id)
        assert.is_not_nil(sent[4].params.text:find("t-1", 1, true))
        assert.is_not_nil(sent[4].params.text:find("do one", 1, true))
        assert.equal("ses-N", child.lua_get("_G.ctx.active"))
        assert.equal("t-1", child.lua_get("_G.ctx.task.ref.id"))
    end)

    it(
        "TendTaskPick delegates the picked task to an existing session",
        function()
            child.lua([[
            _G.give_workspace()
            _G.replies["task.list"] = {
                result = {
                    tasks = {
                        {
                            ref = { provider = "beads", workspace_id = "ws-1", id = "t-7" },
                            title = "fix",
                            status = "open",
                            description = "the details",
                        },
                    },
                },
            }
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-9",
                            provider_id = "codex",
                            stream_id = "str-9",
                            status = "idle",
                            workspace_id = "ws-1",
                            task = { workspace_id = "ws-1", id = "t-2" },
                        },
                    },
                },
            }
            _G.ui_choices = { 1, 2 } -- task #1, then target #2 = ses-9 (#1 is new)
            vim.cmd("TendTaskPick")
        ]])
            local sent = calls()
            assert.equal("task.list", sent[1].method)
            assert.equal("session.list", sent[2].method)
            -- The task is handed to the EXISTING session, not a fresh agent.start.
            assert.equal("agent.prompt", sent[3].method)
            assert.equal("ses-9", sent[3].params.session_id)
            assert.is_not_nil(sent[3].params.text:find("t-7", 1, true))
            assert.is_not_nil(sent[3].params.text:find("the details", 1, true))
            for _, c in ipairs(sent) do
                assert.is_not.equal("agent.start", c.method)
            end
            assert.equal("ses-9", child.lua_get("_G.ctx.active"))
            assert.equal("t-7", child.lua_get("_G.ctx.task.ref.id"))
        end
    )

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

    it("TendSessionNew starts a task-less session and focuses it", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["agent.start"] = {
                result = { session_id = "ses-1", stream_id = "str-1", status = "idle" },
            }
            _G.ui_choice = 2 -- pick provider #2 = claude
            vim.cmd("TendSessionNew")
        ]])
        local sent = calls()
        assert.equal("agent.start", sent[1].method)
        -- No task: a task-less session carries only provider + workspace.
        assert.same({
            provider_id = "claude",
            workspace_id = "ws-1",
            worktree_root = "/repo",
        }, sent[1].params)
        assert.is_nil(sent[1].params.task)
        assert.equal(
            "ses-1",
            child.lua_get("_G.ctx:active_session().session_id")
        )
        assert.equal(
            "str-1",
            child.lua_get("_G.conn.subscriber.tracked[1].stream_id")
        )
        assert.equal(
            "ws-1",
            child.lua_get("_G.conn.subscriber.tracked[1].workspace_id")
        )
    end)

    it(
        "TendSessionNew without a workspace reports instead of calling",
        function()
            child.lua([[vim.cmd("TendSessionNew")]])
            assert.same({}, calls())
            assert.is_not_nil(last_notice().msg:find("TendConnect", 1, true))
        end
    )

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
        -- The rich ChatView renders the chunk (under an agent header), so the
        -- text appears among the buffer's lines rather than as the only line.
        local rendered = child.lua_get([[(function()
            local lines = vim.api.nvim_buf_get_lines(
                _G.ctx:active_session().bufnr, 0, -1, false)
            return table.concat(lines, "\n"):find("hello there", 1, true) ~= nil
        end)()]])
        assert.is_true(rendered)
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
        assert.is_not_nil(last_notice().msg:find("TendSessionNew", 1, true))
    end)

    it("TendEvents opens the transcript buffer in a window", function()
        child.lua([[
            _G.give_session()
            vim.cmd("TendEvents")
        ]])
        local shown = child.lua([[
            local bufnr = _G.ctx:active_session().bufnr
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if vim.api.nvim_win_get_buf(win) == bufnr then
                    return true
                end
            end
            return false
        ]])
        assert.is_true(shown)
    end)

    it("TendSessionAttach lists sessions and focuses the chosen one", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-A",
                            provider_id = "codex",
                            stream_id = "str-A",
                            status = "running",
                            workspace_id = "ws-1",
                            task = { workspace_id = "ws-1", id = "t-1" },
                        },
                        {
                            session_id = "ses-B",
                            provider_id = "codex",
                            stream_id = "str-B",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ui_choice = 2 -- pick ses-B
            vim.cmd("TendSessionAttach")
        ]])
        local sent = calls()
        assert.equal("session.list", sent[1].method)
        assert.same({ workspace_id = "ws-1" }, sent[1].params)
        -- The chosen (task-less) session is focused and its stream tracked,
        -- carrying the workspace the daemon reports independent of any task.
        assert.equal("ses-B", child.lua_get("_G.ctx.active"))
        assert.equal(
            "str-B",
            child.lua_get("_G.conn.subscriber.tracked[1].stream_id")
        )
        assert.equal(
            "ws-1",
            child.lua_get("_G.conn.subscriber.tracked[1].workspace_id")
        )
    end)

    it("TendSessionAttach reports when there are no sessions", function()
        child.lua([[
            _G.replies["session.list"] = { result = { sessions = {} } }
            vim.cmd("TendSessionAttach")
        ]])
        assert.is_not_nil(last_notice().msg:find("no active sessions", 1, true))
    end)

    it("tracks multiple sessions; chat targets the focused one", function()
        child.lua([[
            -- First :TendSessionNew -> ses-1 tracked and focused.
            _G.give_session()
            -- A second session started independently, then focused via select.
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-2",
                            provider_id = "codex",
                            stream_id = "str-2",
                            status = "idle",
                            workspace_id = "ws-1",
                            task = { workspace_id = "ws-1", id = "t-2" },
                        },
                    },
                },
            }
            _G.ui_choice = 1
            vim.cmd("TendSessionAttach")
        ]])
        -- Both sessions are tracked locally; ses-2 is now focused.
        assert.is_true(child.lua_get("_G.ctx.sessions['ses-1'] ~= nil"))
        assert.is_true(child.lua_get("_G.ctx.sessions['ses-2'] ~= nil"))
        assert.equal("ses-2", child.lua_get("_G.ctx.active"))

        child.lua([[
            _G.calls = {}
            _G.ui_input = "to two"
            vim.cmd("TendChat")
        ]])
        local sent = calls()
        assert.equal("agent.prompt", sent[1].method)
        assert.same({ session_id = "ses-2", text = "to two" }, sent[1].params)
    end)

    it("re-selecting a tracked session reuses its transcript", function()
        child.lua([[
            _G.give_session() -- ses-1 tracked
            _G.tracked_before = #_G.conn.subscriber.tracked
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-1",
                            provider_id = "codex",
                            stream_id = "str-1",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ui_choice = 1
            vim.cmd("TendSessionAttach")
        ]])
        -- Selecting an already-tracked session does not re-subscribe.
        assert.equal(
            child.lua_get("_G.tracked_before"),
            child.lua_get("#_G.conn.subscriber.tracked")
        )
    end)

    it("TendSessionDisconnect detaches a tracked session", function()
        child.lua([[
            _G.give_session() -- ses-1 tracked + focused
            _G.disconnected_buf = _G.ctx:active_session().bufnr
            _G.ui_choice = 1 -- only one tracked session
            vim.cmd("TendSessionDisconnect")
        ]])
        -- The session is untracked locally and its stream unsubscribed, but no
        -- agent.stop is sent — the daemon session keeps running.
        assert.equal("str-1", child.lua_get("_G.conn.subscriber.untracked[1]"))
        assert.is_true(child.lua_get("_G.ctx.sessions['ses-1'] == nil"))
        assert.is_true(child.lua_get("_G.ctx.active == nil"))
        for _, c in ipairs(calls()) do
            assert.is_not.equal("agent.stop", c.method)
        end
        assert.is_false(
            child.lua_get("vim.api.nvim_buf_is_valid(_G.disconnected_buf)")
        )
    end)

    it("TendSessionDisconnect reports when nothing is tracked", function()
        child.lua([[vim.cmd("TendSessionDisconnect")]])
        assert.same({}, calls())
        assert.is_not_nil(
            last_notice().msg:find("no tracked sessions", 1, true)
        )
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

    it("TendOpenChanges fetches file.diff and opens the set's files", function()
        child.lua([[
            local DR = require("tend.ui.diff_review")
            _G.opened = nil
            DR.open_files = function(uris)
                _G.opened = uris
                return {}
            end
            _G.replies["file.diff"] = {
                result = {
                    change_set_id = "cs-1",
                    files = {
                        { uri = "file:///repo/a.go", before = "x", after = "y" },
                        { uri = "file:///repo/b.go", before = "p", after = "q" },
                    },
                },
            }
            vim.cmd("TendOpenChanges cs-1")
        ]])
        local sent = calls()
        assert.equal("file.diff", sent[1].method)
        assert.same({ change_set_id = "cs-1" }, sent[1].params)
        assert.same(
            { "file:///repo/a.go", "file:///repo/b.go" },
            child.lua_get("_G.opened")
        )
    end)

    it("TendDiff fetches file.diff and shows the snapshots", function()
        child.lua([[
            local DR = require("tend.ui.diff_review")
            _G.diffed = nil
            DR.show_snapshots = function(csid, files)
                _G.diffed = { csid = csid, n = #files }
                return {}
            end
            _G.replies["file.diff"] = {
                result = {
                    change_set_id = "cs-2",
                    files = {
                        { uri = "file:///repo/a.go", before = "x", after = "y" },
                    },
                },
            }
            vim.cmd("TendDiff cs-2")
        ]])
        local sent = calls()
        assert.equal("file.diff", sent[1].method)
        assert.same({ change_set_id = "cs-2" }, sent[1].params)
        assert.equal("cs-2", child.lua_get("_G.diffed.csid"))
        assert.equal(1, child.lua_get("_G.diffed.n"))
    end)

    it("TendDiff prompts for a change set id when none is given", function()
        child.lua([[
            local DR = require("tend.ui.diff_review")
            _G.diffed = nil
            DR.show_snapshots = function(csid, _)
                _G.diffed = { csid = csid }
                return {}
            end
            _G.ui_input = "cs-prompted"
            _G.replies["file.diff"] = {
                result = {
                    change_set_id = "cs-prompted",
                    files = { { uri = "file:///a", before = "", after = "z" } },
                },
            }
            vim.cmd("TendDiff")
        ]])
        assert.equal("file.diff", calls()[1].method)
        assert.equal("cs-prompted", child.lua_get("_G.diffed.csid"))
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
