local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")
local Versions = require("tend.daemon.versions")

-- Headless smoke test of the real plugin against a fake daemon: a scripted
-- JSON-RPC server on a real Unix socket inside the child Neovim, so the
-- genuine libuv connect path, command surface, transcript, approval float,
-- and reconnect logic run together with no injected transports. The parent
-- only orchestrates and polls; every poll round-trip lets the child's event
-- loop service socket I/O and timers.
describe("daemon smoke", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            _G.daemon = require("tests.helpers.fake_daemon").start()

            -- Scripted UI: selections take the first item, inputs return
            -- whatever the test put in _G.ui_input.
            vim.ui.select = function(items, _, on_choice)
                on_choice(items[1], 1)
            end
            vim.ui.input = function(_, on_confirm)
                on_confirm(_G.ui_input)
            end

            require("tend").setup({
                daemon = {
                    socket = _G.daemon.path,
                    providers = { "codex" },
                },
            })
            _G.ctx = require("tend.commands").current()
            -- This smoke test exercises the real socket/daemon path, not the
            -- chat window machinery; inject a fake widget (real scratch chat
            -- buffers, stubbed windows) so transcript assertions hold without
            -- opening real widget windows headlessly.
            _G.widget = nil
            _G.ctx.widget_factory = function(on_submit)
                local w = { on_submit = on_submit, buf_nrs = { chat = -1 } }
                function w:create_chat_buffer()
                    return vim.api.nvim_create_buf(false, true)
                end
                function w:show() end
                function w:hide() end
                function w:destroy() end
                function w:render_header() end
                _G.widget = w
                return w
            end
            -- A second of real reconnect delay is daemon-outage UX, not test
            -- pace; tighten it so the reconnect scenario observes quickly.
            _G.ctx.conn.reconnect_delay_ms = 100
        ]])
    end)

    after_each(function()
        pcall(child.lua, [[_G.daemon:stop()]])
        child.stop()
    end)

    --- Poll a boolean child expression until true or the tries run out.
    --- @param expr string
    --- @param tries integer|nil
    --- @return boolean
    local function wait_for(expr, tries)
        for _ = 1, tries or 150 do
            if child.lua_get(expr) == true then
                return true
            end
            vim.uv.sleep(20)
        end
        return false
    end

    --- :TendConnect and wait until the workspace is resolved.
    local function attach()
        child.cmd("TendConnect")
        assert.is_true(wait_for("_G.ctx.workspace ~= nil"))
    end

    --- Start a task-less session (provider picked = the first, codex) and send
    --- it the given prompt turn via the chat input (the widget's submit
    --- callback).
    --- @param instruction string
    local function start_session(instruction)
        child.cmd("TendSessionNew")
        assert.is_true(wait_for("_G.ctx:active_session() ~= nil"))
        child.lua(string.format([[_G.widget.on_submit(%q)]], instruction))
    end

    --- @param expr string an expression yielding a params table in the child
    --- @return table
    local function params(expr)
        return child.lua_get(expr)
    end

    it("attach handshakes, registers, and opens the cwd workspace", function()
        attach()

        local hello = params("_G.daemon:calls_for('daemon.hello')[1]")
        assert.same(Versions.REQUIRED, hello.required)

        local register = params("_G.daemon:calls_for('client.register')[1]")
        assert.equal("editor", register.role)
        assert.is_true(register.prompt_capable)
        assert.is_not_nil(register.client_id)

        local open = params("_G.daemon:calls_for('workspace.open')[1]")
        assert.equal(child.lua_get("vim.fn.getcwd()"), open.dir)
        assert.equal("ws-1", child.lua_get("_G.ctx.workspace.workspace_id"))
        assert.equal("connected", child.lua_get("_G.ctx.conn:info().status"))
    end)

    it("a session runs a turn and streams it into the transcript", function()
        attach()
        start_session("do it")

        local start = params("_G.daemon:calls_for('agent.start')[1]")
        assert.equal("codex", start.provider_id)
        assert.equal("ws-1", start.workspace_id)
        -- A task-less session: no task is sent on start.
        assert.is_nil(start.task)
        assert.equal(child.lua_get("vim.fn.getcwd()"), start.worktree_root)

        local subscribe = params("_G.daemon:calls_for('events.subscribe')[1]")
        assert.equal("str-ses-1", subscribe.stream_id)

        local prompt = params("_G.daemon:calls_for('agent.prompt')[1]")
        assert.equal("ses-1", prompt.session_id)
        assert.equal("do it", prompt.text)

        child.lua([[
            _G.daemon:push_event({
                stream_id = "str-ses-1",
                seq = 1,
                cursor_seq = 1,
                kind = "event",
                type = "agent_message_chunk",
                payload = { text = "hello from agent" },
            })
        ]])
        assert.is_true(wait_for([[vim.tbl_contains(
                vim.api.nvim_buf_get_lines(_G.ctx:active_session().bufnr, 0, -1, false),
                "hello from agent"
            )]]))
    end)

    it("an approval prompt round-trips through the float", function()
        attach()

        child.lua([[
            _G.daemon:notify("prompt.raise", {
                session_id = "ses-1",
                kind = "approval",
                approval_id = "ap-1",
                prompt = "run make?",
                detail = {
                    kind = "pane_run",
                    pane_run = {
                        pane_id = "pn-1",
                        command = "make",
                        cwd = "/repo",
                    },
                },
            })
        ]])
        assert.is_true(wait_for("_G.ctx.conn.approvals.view:is_open() == true"))
        local lines = child.lua_get(
            "vim.api.nvim_buf_get_lines("
                .. "_G.ctx.conn.approvals.view:bufnr(), 0, -1, false)"
        )
        assert.is_true(vim.tbl_contains(lines, "command: make"))

        child.type_keys("a")
        assert.is_true(
            wait_for("#_G.daemon:calls_for('approval.respond') == 1")
        )
        local respond = params("_G.daemon:calls_for('approval.respond')[1]")
        assert.equal("ap-1", respond.approval_id)
        assert.is_true(respond.approved)
        -- The ack resolves the pending approval and the float closes.
        assert.is_true(
            wait_for("_G.ctx.conn.approvals.view:is_open() == false")
        )
    end)

    it("reconnects after a drop and keeps streaming events", function()
        attach()
        start_session("go")
        child.lua([[
            _G.daemon:push_event({
                stream_id = "str-ses-1",
                seq = 1,
                cursor_seq = 1,
                kind = "event",
                type = "agent_message_chunk",
                payload = { text = "before the drop" },
            })
        ]])
        assert.is_true(wait_for([[table.concat(
                vim.api.nvim_buf_get_lines(_G.ctx:active_session().bufnr, 0, -1, false),
                "\n"
            ):find("before the drop", 1, true) ~= nil]]))

        child.lua([[_G.daemon:drop()]])
        -- The same identity re-registers and the tracked session stream is
        -- re-subscribed from its cursor.
        assert.is_true(wait_for("#_G.daemon:calls_for('client.register') == 2"))
        assert.is_true(
            wait_for("#_G.daemon:calls_for('events.subscribe') == 2")
        )
        local registers = params("_G.daemon:calls_for('client.register')")
        assert.equal(registers[1].client_id, registers[2].client_id)
        local resubscribe = params("_G.daemon:calls_for('events.subscribe')[2]")
        assert.equal("str-ses-1", resubscribe.stream_id)
        assert.equal(1, resubscribe.last_seq)

        child.lua([[
            _G.daemon:push_event({
                stream_id = "str-ses-1",
                seq = 2,
                cursor_seq = 2,
                kind = "event",
                type = "agent_message_chunk",
                payload = { text = "after the drop" },
            })
        ]])
        assert.is_true(wait_for([[table.concat(
                vim.api.nvim_buf_get_lines(_G.ctx:active_session().bufnr, 0, -1, false),
                "\n"
            ):find("after the drop", 1, true) ~= nil]]))
    end)
end)
