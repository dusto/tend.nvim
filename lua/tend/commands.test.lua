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
                    resets = {},
                    track = function(self, spec)
                        table.insert(self.tracked, spec)
                    end,
                    untrack = function(self, stream_id)
                        table.insert(self.untracked, stream_id)
                    end,
                    reset_cursor = function(self, _, stream_id)
                        table.insert(self.resets, stream_id)
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

            -- A fake chat widget: real scratch chat buffers (so ChatView
            -- renders into them and tests can read the transcript), with the
            -- window machinery stubbed. Captures the submit callback so a test
            -- can simulate the user pressing <CR> in the input.
            _G.widget = nil
            _G.make_widget = function(on_submit, on_switch, controls, slash, files)
                local w = {
                    on_submit = on_submit,
                    on_switch = on_switch,
                    controls = controls,
                    slash = slash,
                    files = files,
                    -- Real scratch panel buffers so the TodoList / context lists
                    -- (files, code, diagnostics) render into them.
                    buf_nrs = {
                        chat = -1,
                        todos = vim.api.nvim_create_buf(false, true),
                        files = vim.api.nvim_create_buf(false, true),
                        code = vim.api.nvim_create_buf(false, true),
                        diagnostics = vim.api.nvim_create_buf(false, true),
                    },
                    shows = {},
                    hides = 0,
                    destroys = 0,
                    closed_panels = {},
                    _open = false,
                }
                function w:create_chat_buffer()
                    return vim.api.nvim_create_buf(false, true)
                end
                function w:close_optional_window(panel_name)
                    table.insert(self.closed_panels, panel_name)
                end
                function w:is_open()
                    return self._open
                end
                function w:show(opts)
                    self._open = true
                    table.insert(self.shows, opts or {})
                end
                function w:hide()
                    self._open = false
                    self.hides = self.hides + 1
                end
                function w:destroy()
                    self.destroys = self.destroys + 1
                end
                w.headers = {}
                function w:render_header(window_name, context)
                    table.insert(
                        self.headers,
                        { window = window_name, context = context }
                    )
                end
                _G.widget = w
                return w
            end

            _G.ctx = require("tend.commands").setup({
                connection = _G.conn,
                providers = { "codex", "claude" },
                assignee = "dustin",
                persona_dirs = { "/tmp/tend-test-personas" },
                widget_factory = _G.make_widget,
            })

            -- Providers come from the daemon (provider.list); default to the two
            -- configured ones, both enabled, so a provider pick resolves.
            _G.replies["provider.list"] = {
                result = {
                    providers = {
                        { provider_id = "codex", enabled = true, running = 0 },
                        { provider_id = "claude", enabled = true, running = 0 },
                    },
                },
            }

            -- Tracking a session primes its slash-command set via slash.list.
            _G.replies["slash.list"] = {
                result = {
                    commands = {
                        {
                            name = "tasks",
                            description = "List tasks",
                            origin = "daemon",
                        },
                    },
                },
            }

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

    --- The first recorded call for a method (fails the test when absent).
    --- @return table
    local function find_call(sent, method)
        for _, c in ipairs(sent) do
            if c.method == method then
                return c
            end
        end
        error("no recorded call for " .. method)
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
        -- Tracking the new session primes its commands (slash.list) before the
        -- task is handed over, so locate the prompt by method rather than index.
        local prompt = find_call(sent, "agent.prompt")
        assert.equal("ses-N", prompt.params.session_id)
        assert.is_not_nil(prompt.params.text:find("t-1", 1, true))
        assert.is_not_nil(prompt.params.text:find("do one", 1, true))
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
            local prompt = find_call(sent, "agent.prompt")
            assert.equal("ses-9", prompt.params.session_id)
            assert.is_not_nil(prompt.params.text:find("t-7", 1, true))
            assert.is_not_nil(prompt.params.text:find("the details", 1, true))
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

    it("TendProvider picks from the daemon's enabled providers", function()
        child.lua([[
            _G.give_workspace()
            _G.ui_choice = 2
            vim.cmd("TendProvider")
        ]])
        -- Sourced from provider.list (daemon), not client config.
        assert.equal("provider.list", calls()[1].method)
        assert.equal("ws-1", calls()[1].params.workspace_id)
        assert.equal("claude", child.lua_get("_G.ctx.provider_id"))
    end)

    it("TendProvider without a workspace reports instead of calling", function()
        child.lua([[
            _G.ui_choice = 1
            vim.cmd("TendProvider")
        ]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("workspace", 1, true))
    end)

    it("TendProvider skips providers the daemon reports disabled", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["provider.list"] = {
                result = {
                    providers = {
                        { provider_id = "codex", enabled = true },
                        { provider_id = "kiro", enabled = false },
                    },
                },
            }
            _G.ui_choice = 1
            vim.cmd("TendProvider")
        ]])
        local items = child.lua_get("_G.ui_items")
        assert.equal(1, #items)
        assert.equal("codex", items[1].provider_id)
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
        -- The provider is picked from the daemon (provider.list) first, then the
        -- session is started.
        assert.equal("provider.list", sent[1].method)
        assert.equal("agent.start", sent[2].method)
        -- No task: a task-less session carries only provider + workspace.
        assert.same({
            provider_id = "claude",
            workspace_id = "ws-1",
            worktree_root = "/repo",
        }, sent[2].params)
        assert.is_nil(sent[2].params.task)
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

    --- The todos buffer's rendered lines for the current widget.
    local function todo_lines()
        return child.lua_get([[vim.api.nvim_buf_get_lines(
            _G.widget.buf_nrs.todos, 0, -1, false)]])
    end

    it("an agent_plan event renders into the todos panel", function()
        child.lua([[
            _G.give_session()
            _G.conn.subscriber.tracked[1].on_event({
                kind = "event",
                type = "agent_plan",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { entries = {
                    { content = "write the test", status = "completed" },
                    { content = "make it green", status = "in_progress" },
                } },
            })
        ]])
        assert.same({
            "- [x] write the test",
            "- [~] make it green",
        }, todo_lines())
    end)

    it("primes the session command set via slash.list on track", function()
        child.lua([[ _G.give_session() ]])
        -- The default slash.list reply is stored on the session and exposed via
        -- the injected slash source the widget completes against.
        assert.same({
            { name = "tasks", description = "List tasks", origin = "daemon" },
        }, child.lua_get("_G.ctx.sessions['ses-1'].commands"))
        assert.equal("tasks", child.lua_get("_G.widget.slash.list()[1].name"))
    end)

    it(
        "a slash_commands_updated event replaces the session command set",
        function()
            child.lua([[
            _G.give_session()
            _G.conn.subscriber.tracked[1].on_event({
                kind = "event",
                type = "slash_commands_updated",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { session_id = "ses-1", commands = {
                    { name = "compact", description = "Compact", origin = "provider" },
                    { name = "tasks", description = "List tasks", origin = "daemon" },
                } },
            })
        ]])
            assert.equal(2, child.lua_get("#_G.ctx.sessions['ses-1'].commands"))
            assert.equal(
                "compact",
                child.lua_get("_G.widget.slash.list()[1].name")
            )
        end
    )

    it("the slash source completes arguments via slash.complete", function()
        child.lua([[
            _G.give_session()
            _G.replies["slash.complete"] = {
                result = { candidates = {
                    { value = "t-1", detail = "fix the bug" },
                } },
            }
            _G.captured = nil
            _G.widget.slash.complete("comment", "t", function(cands)
                _G.captured = cands
            end)
            _G.complete_call = _G.calls[#_G.calls]
        ]])
        assert.same({
            session_id = "ses-1",
            command = "comment",
            prefix = "t",
        }, child.lua_get("_G.complete_call.params"))
        assert.same(
            { { value = "t-1", detail = "fix the bug" } },
            child.lua_get("_G.captured")
        )
    end)

    it("an empty plan clears and closes the todos panel", function()
        child.lua([[
            _G.give_session()
            local track = _G.conn.subscriber.tracked[1]
            track.on_event({
                kind = "event",
                type = "agent_plan",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { entries = {
                    { content = "a step", status = "pending" },
                } },
            })
            _G.widget.closed_panels = {}
            -- The daemon replaces the plan with an empty one.
            track.on_event({
                kind = "event",
                type = "agent_plan",
                seq = 2,
                cursor_seq = 2,
                stream_id = "str-1",
                payload = { entries = {} },
            })
        ]])
        assert.same({ "" }, todo_lines())
        assert.equal("todos", child.lua_get("_G.widget.closed_panels[1]"))
    end)

    it("a plan is preserved across session switches", function()
        child.lua([[
            _G.give_session() -- ses-1 active
            _G.conn.subscriber.tracked[1].on_event({
                kind = "event",
                type = "agent_plan",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { entries = {
                    { content = "ses-1 step", status = "pending" },
                } },
            })
            -- A second session becomes active with its own plan.
            _G.replies["agent.start"] = { result = {
                session_id = "ses-2", stream_id = "str-2", status = "idle",
            } }
            _G.ui_choice = 1
            vim.cmd("TendSessionNew")
            _G.ui_choice = nil
            _G.conn.subscriber.tracked[2].on_event({
                kind = "event",
                type = "agent_plan",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-2",
                payload = { entries = {
                    { content = "ses-2 step", status = "pending" },
                } },
            })
        ]])
        -- The active (ses-2) plan is shown.
        assert.same({ "- [ ] ses-2 step" }, todo_lines())
        -- Switching back to ses-1 (focus + show) re-renders its stored plan.
        child.lua([[
            local s = _G.ctx:focus_session({
                session_id = "ses-1",
                stream_id = "str-1",
                workspace_id = "ws-1",
            })
            _G.ctx:show_session(s, false)
        ]])
        assert.same({ "- [ ] ses-1 step" }, todo_lines())
    end)

    it("submitting the next prompt collapses a fully completed plan", function()
        child.lua([[
            _G.give_session()
            _G.conn.subscriber.tracked[1].on_event({
                kind = "event",
                type = "agent_plan",
                seq = 1,
                cursor_seq = 1,
                stream_id = "str-1",
                payload = { entries = {
                    { content = "all done", status = "completed" },
                } },
            })
            _G.widget.on_submit("what next?")
        ]])
        -- The panel is cleared and closed, and the stored plan is dropped.
        assert.same({ "" }, todo_lines())
        assert.equal("todos", child.lua_get("_G.widget.closed_panels[1]"))
        assert.is_true(child.lua_get("_G.ctx.sessions['ses-1'].plan == nil"))
    end)

    it(
        "TendChat opens the widget on the focused session, input focused",
        function()
            child.lua([[
            _G.give_session()
            _G.widget.shows = {}
            vim.cmd("TendChat")
        ]])
            -- The widget is shown on the active session's buffer with the prompt
            -- focused (no more vim.ui.input prompt box).
            assert.is_true(child.lua_get("#_G.widget.shows >= 1"))
            assert.is_true(
                child.lua_get("_G.widget.shows[#_G.widget.shows].focus_prompt")
            )
            assert.is_true(
                child.lua_get(
                    "_G.widget.buf_nrs.chat == _G.ctx:active_session().bufnr"
                )
            )
        end
    )

    it(
        "open_widget shows the focused session (require('tend').open)",
        function()
            child.lua([[
            _G.give_session()
            _G.widget.shows = {}
            _G.ctx:open_widget()
        ]])
            assert.is_true(child.lua_get("#_G.widget.shows >= 1"))
            assert.is_true(
                child.lua_get(
                    "_G.widget.buf_nrs.chat == _G.ctx:active_session().bufnr"
                )
            )
        end
    )

    it("open_widget without a focused session reports", function()
        child.lua([[
            _G.ctx:ensure_widget()
            _G.widget.shows = {}
            _G.ctx:open_widget()
        ]])
        assert.equal(0, child.lua_get("#_G.widget.shows"))
        assert.is_not_nil(last_notice().msg:find("no focused session", 1, true))
    end)

    it("close_widget hides the widget (require('tend').close)", function()
        child.lua([[
            _G.give_session()
            _G.ctx:open_widget()
            _G.ctx:close_widget()
        ]])
        assert.equal(1, child.lua_get("_G.widget.hides"))
    end)

    it("toggle_widget shows then hides (require('tend').toggle)", function()
        child.lua([[
            _G.give_session()
            -- give_session shows the widget; start from a known-closed state.
            _G.ctx:close_widget()
            _G.ctx:toggle_widget() -- closed -> show
            _G.after_show_open = _G.widget:is_open()
            _G.ctx:toggle_widget() -- open -> hide
            _G.after_hide_open = _G.widget:is_open()
        ]])
        assert.is_true(child.lua_get("_G.after_show_open"))
        assert.is_false(child.lua_get("_G.after_hide_open"))
    end)

    it("the chat input submits a prompt to the focused session", function()
        child.lua([[
            _G.give_session()
            _G.calls = {}
            -- Simulate the user typing in the input and pressing submit.
            _G.accepted = _G.widget.on_submit("and then?")
        ]])
        assert.is_true(child.lua_get("_G.accepted"))
        local sent = calls()
        assert.equal("agent.prompt", sent[1].method)
        assert.same(
            { session_id = "ses-1", text = "and then?" },
            sent[1].params
        )
    end)

    it("a '/command' submission routes to slash.invoke", function()
        child.lua([[
            _G.give_session()
            _G.replies["slash.invoke"] = {
                result = { origin = "daemon", message = "closed t-1" },
            }
            _G.calls = {}
            _G.accepted = _G.widget.on_submit("/close t-1")
        ]])
        assert.is_true(child.lua_get("_G.accepted"))
        local sent = calls()
        assert.equal("slash.invoke", sent[1].method)
        assert.same({
            session_id = "ses-1",
            command = "close",
            args = "t-1",
        }, sent[1].params)
        -- The daemon's outcome message is surfaced.
        assert.is_not_nil(last_notice().msg:find("closed t-1", 1, true))
    end)

    it("a bare '/command' with no args omits args", function()
        child.lua([[
            _G.give_session()
            _G.replies["slash.invoke"] = { result = { origin = "daemon" } }
            _G.calls = {}
            _G.widget.on_submit("/tasks")
        ]])
        local sent = calls()
        assert.equal("slash.invoke", sent[1].method)
        assert.same({ session_id = "ses-1", command = "tasks" }, sent[1].params)
    end)

    it("a plain prompt still routes to agent.prompt", function()
        child.lua([[
            _G.give_session()
            _G.calls = {}
            _G.widget.on_submit("not a slash")
        ]])
        assert.equal("agent.prompt", calls()[1].method)
    end)

    it("a plain turn sends text (no content array)", function()
        child.lua([[
            _G.give_session()
            _G.calls = {}
            _G.widget.on_submit("just text")
        ]])
        local p = find_call(calls(), "agent.prompt").params
        assert.equal("just text", p.text)
        assert.is_nil(p.content)
    end)

    it("attached files are sent as agent.prompt content blocks", function()
        child.lua([[
            _G.give_session()
            _G.ctx:add_files({ "lua/tend/init.lua" })
            _G.calls = {}
            _G.widget.on_submit("review this")
        ]])
        local p = find_call(calls(), "agent.prompt").params
        -- Content supersedes text: no top-level text, a content array instead.
        assert.is_nil(p.text)
        assert.equal("text", p.content[1].type)
        assert.equal("review this", p.content[1].text)
        assert.equal("resource_link", p.content[2].type)
        assert.is_not_nil(p.content[2].uri:find("init.lua", 1, true))
    end)

    it("an @-file pick attaches the file to the next turn's content", function()
        -- The widget's @-file source, wired in ensure_widget, hands a picked
        -- path to the daemon context so it rides the next turn as a content
        -- block (the same path add_file / the files panel would attach).
        child.lua([[
                _G.give_session()
                _G.calls = {}
                _G.widget.files.on_pick("lua/tend/init.lua")
                _G.widget.on_submit("review this")
            ]])
        local p = find_call(calls(), "agent.prompt").params
        assert.is_nil(p.text)
        assert.equal("review this", p.content[1].text)
        assert.equal("resource_link", p.content[2].type)
        assert.is_not_nil(p.content[2].uri:find("init.lua", 1, true))
    end)

    it("a slash submission discards attached context", function()
        child.lua([[
            _G.give_session()
            _G.ctx:add_files({ "lua/tend/init.lua" })
            _G.replies["slash.invoke"] = { result = { origin = "daemon" } }
            _G.widget.on_submit("/tasks") -- slash: attached context discarded
            _G.calls = {}
            _G.widget.on_submit("now") -- normal turn: no stale content
        ]])
        local p = find_call(calls(), "agent.prompt").params
        assert.equal("now", p.text)
        assert.is_nil(p.content)
    end)

    it("attached context is cleared after the turn", function()
        child.lua([[
            _G.give_session()
            _G.ctx:add_files({ "lua/tend/init.lua" })
            _G.widget.on_submit("first")
            _G.calls = {}
            _G.widget.on_submit("second")
        ]])
        -- The second turn has no attached files, so it sends plain text.
        local p = find_call(calls(), "agent.prompt").params
        assert.equal("second", p.text)
        assert.is_nil(p.content)
    end)

    it("a submit with no focused session is rejected", function()
        child.lua([[
            _G.ctx:ensure_widget()
            _G.accepted = _G.widget.on_submit("hi")
        ]])
        assert.is_false(child.lua_get("_G.accepted"))
        assert.same({}, calls())
    end)

    it("TendChat without a session reports instead of calling", function()
        child.lua([[vim.cmd("TendChat")]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("TendSessionNew", 1, true))
    end)

    it("TendEvents shows the widget on the focused session", function()
        child.lua([[
            _G.give_session()
            _G.widget.shows = {}
            vim.cmd("TendEvents")
        ]])
        assert.is_true(child.lua_get("#_G.widget.shows >= 1"))
        -- Reading, not composing: the prompt is not focused.
        assert.is_false(
            child.lua_get(
                "_G.widget.shows[#_G.widget.shows].focus_prompt == true"
            )
        )
        assert.is_true(
            child.lua_get(
                "_G.widget.buf_nrs.chat == _G.ctx:active_session().bufnr"
            )
        )
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

    it("stop_generation cancels the focused session's turn", function()
        child.lua([[
            _G.give_session()
            _G.calls = {}
            _G.ctx:stop_generation()
        ]])
        local sent = calls()
        assert.equal("agent.cancel", sent[1].method)
        assert.same({ session_id = "ses-1" }, sent[1].params)
    end)

    it("stop_generation without a focused session reports", function()
        child.lua([[ _G.ctx:stop_generation() ]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("no focused session", 1, true))
    end)

    it("restore_session_by_id focuses the matching session", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-Z",
                            provider_id = "codex",
                            stream_id = "str-Z",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ctx:attach_session("ses-Z")
        ]])
        assert.equal("ses-Z", child.lua_get("_G.ctx.active"))
        assert.equal(
            "str-Z",
            child.lua_get("_G.conn.subscriber.tracked[1].stream_id")
        )
    end)

    it("restore_session_by_id reports an unknown id", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-other",
                            provider_id = "codex",
                            stream_id = "str-other",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ctx:attach_session("nope")
        ]])
        assert.is_true(child.lua_get("_G.ctx.active == nil"))
        assert.is_not_nil(last_notice().msg:find("no session nope", 1, true))
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
            _G.widget.on_submit("to two")
        ]])
        local sent = calls()
        assert.equal("agent.prompt", sent[1].method)
        assert.same({ session_id = "ses-2", text = "to two" }, sent[1].params)
    end)

    it("attaching a session replays its history (resets the cursor)", function()
        child.lua([[
            _G.give_workspace()
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-old",
                            provider_id = "codex",
                            stream_id = "str-old",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ui_choice = 1
            vim.cmd("TendSessionAttach")
        ]])
        -- Attaching resets the stream cursor so the daemon replays the retained
        -- transcript into the fresh buffer rather than resuming from the tail.
        assert.is_true(
            child.lua_get(
                "vim.tbl_contains(_G.conn.subscriber.resets, 'str-old')"
            )
        )
    end)

    it(
        "switching sessions while open reopens the widget on the new buffer",
        function()
            child.lua([[
            _G.give_session() -- ses-1 shown (widget open)
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-2",
                            provider_id = "codex",
                            stream_id = "str-2",
                            status = "idle",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.widget.hides = 0
            _G.ui_choice = 1
            vim.cmd("TendSessionAttach")
        ]])
            -- An open widget keeps its old buffer on a bare re-show, so switching
            -- must hide() first; the widget then re-shows on ses-2's buffer.
            assert.is_true(child.lua_get("_G.widget.hides >= 1"))
            assert.is_true(
                child.lua_get(
                    "_G.widget.buf_nrs.chat == _G.ctx.sessions['ses-2'].bufnr"
                )
            )
        end
    )

    it(
        "the in-chat switcher (on_switch) switches the focused session",
        function()
            child.lua([[
            _G.give_session() -- ses-1 focused + open
            _G.replies["session.list"] = {
                result = {
                    sessions = {
                        {
                            session_id = "ses-2",
                            provider_id = "codex",
                            stream_id = "str-2",
                            status = "running",
                            workspace_id = "ws-1",
                        },
                    },
                },
            }
            _G.ui_choice = 1
            -- The chat-buffer switch keymap fires the widget's on_switch
            -- callback, which opens the session picker without leaving the chat.
            _G.widget.on_switch()
        ]])
            -- The chosen session becomes active and the chat window follows it
            -- (its per-session transcript buffer is now the shown chat buffer).
            assert.equal("ses-2", child.lua_get("_G.ctx.active"))
            assert.is_true(
                child.lua_get(
                    "_G.widget.buf_nrs.chat == _G.ctx.sessions['ses-2'].bufnr"
                )
            )
            -- Switching lands in the prompt so the user can type at once; the
            -- chat pane stays available for reading/copying.
            assert.is_true(
                child.lua_get(
                    "_G.widget.shows[#_G.widget.shows].focus_prompt == true"
                )
            )
        end
    )

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
        ]])
        -- A fresh context carrying the new config (providers are the no-pick
        -- fallback; interactive picks come from the daemon's provider.list).
        local providers = child.lua([[
            local ctx = require("tend.commands").current()
            return ctx and ctx.providers or {}
        ]])
        assert.same({ "zed" }, providers)
    end)

    -- Daemon-sourced model/thought switchers acting on the focused session.
    local function give_session_with_options()
        child.lua([[
            _G.give_session()
            _G.replies["session.list"] = { result = { sessions = {
                {
                    session_id = "ses-1",
                    provider_id = "codex",
                    current_model_id = "sonnet",
                    available_models = {
                        { id = "sonnet", name = "Sonnet" },
                        { id = "opus", name = "Opus" },
                    },
                    current_mode_id = "default",
                    available_modes = {
                        { id = "default", name = "Default" },
                        { id = "think", name = "Think hard" },
                    },
                    current_thought_level_id = "medium",
                    available_thought_levels = {
                        { id = "low", name = "Low" },
                        { id = "medium", name = "Medium" },
                        { id = "high", name = "High" },
                    },
                },
            } } }
            _G.calls = {}
        ]])
    end

    it(
        "switch_model lists the session's models and sets the chosen one",
        function()
            give_session_with_options()
            child.lua([[
            _G.replies["session.set_model"] = { result = { current_model_id = "opus" } }
            _G.ui_choice = 2 -- Opus
            _G.widget.controls.switch_model()
        ]])
            local sent = calls()
            assert.equal("session.list", sent[1].method)
            assert.equal("session.set_model", sent[2].method)
            assert.same(
                { session_id = "ses-1", model_id = "opus" },
                sent[2].params
            )
        end
    )

    it("switch_model reflects the new model in the chat header", function()
        give_session_with_options()
        child.lua([[
            _G.replies["session.set_model"] = { result = { current_model_id = "opus" } }
            _G.ui_choice = 2
            _G.widget.controls.switch_model()
        ]])
        local headers = child.lua_get("_G.widget.headers")
        local last = headers[#headers]
        assert.equal("chat", last.window)
        assert.is_not_nil(last.context:find("opus", 1, true))
    end)

    it("switch_model reports when the provider offers no models", function()
        child.lua([[
            _G.give_session()
            _G.replies["session.list"] = { result = { sessions = {
                { session_id = "ses-1", available_models = {} },
            } } }
            _G.calls = {}
            _G.widget.controls.switch_model()
        ]])
        local methods = {}
        for _, c in ipairs(calls()) do
            table.insert(methods, c.method)
        end
        assert.same({ "session.list" }, methods)
        assert.is_not_nil(last_notice().msg:find("no model", 1, true))
    end)

    it(
        "change_mode lists the session's modes and sets the chosen one",
        function()
            give_session_with_options()
            child.lua([[
                _G.replies["session.set_mode"] = { result = { current_mode_id = "think" } }
                _G.ui_choice = 2 -- Think hard
                _G.widget.controls.change_mode()
            ]])
            local sent = calls()
            assert.equal("session.list", sent[1].method)
            assert.equal("session.set_mode", sent[2].method)
            assert.same(
                { session_id = "ses-1", mode_id = "think" },
                sent[2].params
            )
        end
    )

    it("change_mode reports when the provider offers no modes", function()
        child.lua([[
                _G.give_session()
                _G.replies["session.list"] = { result = { sessions = {
                    { session_id = "ses-1", available_modes = {} },
                } } }
                _G.calls = {}
                _G.widget.controls.change_mode()
            ]])
        assert.is_not_nil(last_notice().msg:find("no modes", 1, true))
    end)

    it(
        "change_thought_level lists the session's thought levels and sets the chosen one",
        function()
            give_session_with_options()
            child.lua([[
                _G.replies["session.set_thought_level"] =
                    { result = { current_thought_level_id = "high" } }
                _G.ui_choice = 3 -- High
                _G.widget.controls.change_thought_level()
            ]])
            local sent = calls()
            assert.equal("session.list", sent[1].method)
            assert.equal("session.set_thought_level", sent[2].method)
            assert.same(
                { session_id = "ses-1", thought_level_id = "high" },
                sent[2].params
            )
        end
    )

    it(
        "change_thought_level reflects the new level in the chat header",
        function()
            give_session_with_options()
            child.lua([[
            _G.replies["session.set_thought_level"] =
                { result = { current_thought_level_id = "high" } }
            _G.ui_choice = 3
            _G.widget.controls.change_thought_level()
        ]])
            local headers = child.lua_get("_G.widget.headers")
            local last = headers[#headers]
            assert.equal("chat", last.window)
            assert.is_not_nil(last.context:find("high", 1, true))
        end
    )

    it(
        "change_thought_level reports when the provider offers no thought levels",
        function()
            child.lua([[
                _G.give_session()
                _G.replies["session.list"] = { result = { sessions = {
                    { session_id = "ses-1", available_thought_levels = {} },
                } } }
                _G.calls = {}
                _G.widget.controls.change_thought_level()
            ]])
            assert.is_not_nil(
                last_notice().msg:find("thought/reasoning", 1, true)
            )
        end
    )

    it(
        "agent_thought_level_updated keeps the header live without a set call",
        function()
            -- give_session tracks and focuses ses-1; an agent-driven thought-level
            -- event on its stream must update the header with no set call.
            child.lua([[
                _G.give_session()
                _G.calls = {}
                _G.ctx:apply_session_updates(_G.ctx.sessions["ses-1"], {
                    type = "agent_thought_level_updated",
                    payload = { session_id = "ses-1", current_thought_level_id = "low" },
                })
            ]])
            assert.same({}, calls())
            assert.equal(
                "low",
                child.lua_get("_G.ctx.sessions['ses-1'].thought_level_id")
            )
            local headers = child.lua_get("_G.widget.headers")
            local last = headers[#headers]
            assert.is_not_nil(last.context:find("low", 1, true))
        end
    )

    it("the switchers report when no session is focused", function()
        child.lua([[
            _G.ctx:ensure_widget()
            _G.calls = {}
            _G.widget.controls.switch_model()
        ]])
        assert.same({}, calls())
        assert.is_not_nil(last_notice().msg:find("no focused session", 1, true))
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
