--- Core :Tend* user commands over the daemon connection.
---
--- One context per Neovim instance holds the connection plus the current
--- workspace, task, provider, persona, and agent session — connection-scoped
--- state, deliberately not per-tab (the daemon owns sessions; the editor is one
--- client). Commands resolve their inputs via vim.ui.select/vim.ui.input and
--- report failures through the logger, never silently.
---
--- Wired here, sessions fan their event stream out to both the chat view (the
--- rich ChatView, rendering messages and tool-call blocks) and the approval
--- manager, so a delegated agent's output and its approval prompts stay in
--- sync. :TendOpenChanges/:TendDiff drive the daemon's diff-review surface
--- (file.diff) and the local diff renderer.
local ChatView = require("tend.transcript.chat_view")
local ChatWidget = require("tend.ui.chat_widget")
local Config = require("tend.config")
local Connection = require("tend.daemon.connection")
local DiffReview = require("tend.ui.diff_review")
local Discovery = require("tend.persona.discovery")
local Logger = require("tend.utils.logger")
local TodoList = require("tend.ui.todo_list")

local M = {}

--- @class tend.commands.Session
--- @field session_id string
--- @field stream_id string
--- @field workspace_id string
--- @field bufnr integer per-session chat buffer (created via the widget)
--- @field view tend.transcript.ChatView
--- @field provider_id? string provider shown in the chat header
--- @field model_id? string active model, reflected in the chat header
--- @field mode_id? string active mode (thought/reasoning), reflected in the header
--- @field plan? tend.acp.PlanEntry[] latest agent plan, rendered in the todos panel
--- @field commands? tend.slash.Command[] merged slash-command set (provider + daemon)

--- @alias tend.commands.SubmitInput fun(prompt: string): boolean
--- @alias tend.commands.WidgetFactory fun(on_submit: tend.commands.SubmitInput, on_switch: fun(), controls: tend.ui.ChatWidget.Controls, slash: tend.ui.SlashSource): tend.ui.ChatWidget

--- @class tend.commands.Context
--- @field conn tend.daemon.Connection
--- @field workspace? table api.WorkspaceInfo
--- @field task? table api.Task
--- @field provider_id? string
--- @field persona_id? string
--- @field persona? tend.persona.Persona
--- @field sessions table<string, tend.commands.Session> locally-tracked sessions by id
--- @field active? string the focused session id; :TendChat/:TendEvents target it
--- @field widget? tend.ui.ChatWidget the one chat widget, created on first session
--- @field private todos? tend.ui.TodoList shared todos panel, created on first plan
--- @field private providers string[]
--- @field private assignee string
--- @field private persona_dirs string[]
--- @field private persona_sources? tend.persona.Source[]
--- @field private widget_factory tend.commands.WidgetFactory
local Context = {}
Context.__index = Context
M.Context = Context

--- @class tend.commands.Opts
--- @field socket? string Daemon socket path override.
--- @field providers? string[] ACP provider ids offered by :TendProvider.
--- @field assignee? string Task assignee used by :TendClaim.
--- @field persona_dirs? string[] Directories scanned for native personas.
--- @field persona_sources? tend.persona.Source[] Harness agent import sources.
--- @field connection? tend.daemon.Connection Injected connection (tests).
--- @field widget_factory? tend.commands.WidgetFactory Injected chat widget (tests).

--- The context registered by the last setup() call, or nil before setup. A
--- connection-scoped singleton by design: the daemon owns sessions and the
--- editor is one client, so there is exactly one active context.
--- @type tend.commands.Context|nil
local current = nil

--- The active command context (nil before setup).
--- @return tend.commands.Context|nil
function M.current()
    return current
end

--- Build the context and register the :Tend* user commands. Re-running setup
--- rebuilds the context: the previous context's connection is stopped first,
--- so its client identity and reconnect timer do not outlive it.
--- @param opts? tend.commands.Opts
--- @return tend.commands.Context
function M.setup(opts)
    opts = opts or {}
    local self = setmetatable({
        conn = opts.connection
            or Connection.Connection.new({ socket_path = opts.socket }),
        providers = opts.providers or {},
        assignee = opts.assignee or vim.env.USER or "tend",
        persona_dirs = opts.persona_dirs or Discovery.default_user_dirs(),
        persona_sources = opts.persona_sources,
        workspace = nil,
        task = nil,
        provider_id = nil,
        persona_id = nil,
        persona = nil,
        sessions = {},
        active = nil,
        widget = nil,
        todos = nil,
        widget_factory = opts.widget_factory
            or function(on_submit, on_switch, controls, slash)
                return ChatWidget:new(
                    vim.api.nvim_get_current_tabpage(),
                    on_submit,
                    on_switch,
                    controls,
                    slash
                )
            end,
    }, Context)
    if current then
        current:dispose()
    end
    current = self
    self:register_commands()
    return self
end

--- @private
--- @param msg string
local function report(msg)
    Logger.notify(msg, vim.log.levels.WARN)
end

--- @private
--- @param msg string
local function info(msg)
    Logger.notify(msg, vim.log.levels.INFO)
end

--- @private
--- Request wrapper: daemon errors are reported, successes reach cb.
--- @param method string
--- @param params any
--- @param cb? fun(result: any)
function Context:call(method, params, cb)
    self.conn:request(method, params, function(err, result)
        if err then
            Logger.notify(
                "tend: " .. method .. " failed: " .. err.message,
                vim.log.levels.ERROR
            )
            return
        end
        if cb then
            cb(result)
        end
    end)
end

--- Release the context's connection: stop reconnecting and close the socket.
--- Called by setup() when replacing the context, so the old connection cannot
--- keep its client identity registered alongside the new one.
function Context:dispose()
    self.conn:stop()
    if self.widget then
        self.widget:destroy()
        self.widget = nil
    end
    self.todos = nil
end

--- @private
--- The one chat widget, created on first use. Its persistent input drives
--- agent.prompt for the active session (the widget is decoupled from any
--- runtime via its on_submit_input callback).
--- @return tend.ui.ChatWidget
function Context:ensure_widget()
    if not self.widget then
        self.widget = self.widget_factory(function(prompt)
            return self:submit_prompt(prompt)
        end, function()
            self:switch_session()
        end, {
            -- Daemon-sourced switchers acting on the active session: provider sets
            -- the default for new sessions, model/thought reconfigure the focused
            -- session through the daemon (set_model/set_mode).
            switch_provider = function()
                self:provider_pick()
            end,
            switch_model = function()
                self:switch_model()
            end,
            change_thought_level = function()
                self:change_thought_level()
            end,
        }, {
            -- Slash completion source: command names come from the active
            -- session's cached (daemon-supplied) set; arguments are completed
            -- live via the daemon's slash.complete for that session.
            list = function()
                return self:active_commands()
            end,
            complete = function(command, prefix, cb)
                self:complete_slash(command, prefix, cb)
            end,
        })
    end
    return self.widget
end

--- @private
--- The active session's merged slash-command set (empty when none is focused or
--- the daemon has not reported one yet). Backs the prompt's name completion.
--- @return tend.slash.Command[]
function Context:active_commands()
    local session = self:active_session()
    return (session and session.commands) or {}
end

--- @private
--- Complete a slash command's argument against the active session via the
--- daemon; provider or unknown commands yield no candidates. Errors surface
--- through :call and the callback receives an empty list.
--- @param command string
--- @param prefix string
--- @param cb fun(candidates: tend.slash.Candidate[])
function Context:complete_slash(command, prefix, cb)
    local session = self:active_session()
    if not session then
        cb({})
        return
    end
    self:call("slash.complete", {
        session_id = session.session_id,
        command = command,
        prefix = prefix ~= "" and prefix or nil,
    }, function(result)
        cb(result.candidates or {})
    end)
end

--- @private
--- The shared todos panel controller, created on the first plan. Bound to the
--- one widget's todos buffer: it shows the widget when a plan arrives (so a plan
--- surfaces even while the chat is hidden) and closes the panel when the plan is
--- cleared. One panel reflects whichever session is active.
--- @return tend.ui.TodoList
function Context:ensure_todo_list()
    if not self.todos then
        local widget = self:ensure_widget()
        self.todos = TodoList:new(widget.buf_nrs.todos, function(todo_list)
            if not todo_list:is_empty() then
                widget:show({ focus_prompt = false })
            end
        end, function()
            widget:close_optional_window("todos")
        end)
    end
    return self.todos
end

--- @private
--- Render a session's plan into the shared todos panel. Only the active
--- session's plan is shown (there is one panel; switching sessions re-renders
--- via show_session). An empty plan clears the panel. Gated by the todos window
--- config so a user who disabled the panel never sees it.
--- @param session tend.commands.Session
function Context:render_plan(session)
    if self.active ~= session.session_id then
        return
    end
    if not Config.windows.todos.display then
        return
    end
    local entries = session.plan or {}
    if #entries == 0 then
        -- An empty plan is the daemon's full-replacement "no todos"; clear and
        -- hide the panel rather than leaving an empty window open.
        if self.todos then
            self.todos:clear()
        end
        if self.widget then
            self.widget:close_optional_window("todos")
        end
        return
    end
    self:ensure_todo_list():render(entries)
end

--- @private
--- Show the chat widget on a session: point its chat window at the session's
--- buffer and (re)open the widget. Switching the active session is just
--- swapping which buffer the one widget renders.
--- @param session tend.commands.Session
--- @param focus_prompt boolean
function Context:show_session(session, focus_prompt)
    local widget = self:ensure_widget()
    -- An open widget's chat window keeps its current buffer when re-shown
    -- (WidgetLayout reuses the existing window), so switching the active session
    -- while open must close the windows first; show() then rebuilds them on the
    -- new chat buffer, reapplying its window-local setup.
    if widget.buf_nrs.chat ~= session.bufnr and widget:is_open() then
        widget:hide()
    end
    widget.buf_nrs.chat = session.bufnr
    widget:show({ focus_prompt = focus_prompt })
    self:render_session_header(session)
    self:render_plan(session)
end

--- @private
--- Reflect a session's provider/model/mode in the chat panel header, so the
--- active configuration is visible without opening a switcher. Skips empty parts
--- (a session whose model/mode the daemon has not reported yet shows just the
--- provider); a no-op when nothing is known.
--- @param session tend.commands.Session
function Context:render_session_header(session)
    if not self.widget then
        return
    end
    local parts = {}
    for _, value in ipairs({
        session.provider_id,
        session.model_id,
        session.mode_id,
    }) do
        if value and value ~= "" then
            table.insert(parts, value)
        end
    end
    if #parts > 0 then
        self.widget:render_header("chat", table.concat(parts, " · "))
    end
end

--- @private
--- Submit a prompt from the chat input to the active session. Returns whether
--- the input was accepted (the widget keeps the text when it is not).
--- @param prompt string
--- @return boolean accepted
function Context:submit_prompt(prompt)
    if not self:active_session() then
        report("tend: no focused session; run :TendSessionNew")
        return false
    end
    self:collapse_completed_plan()
    if prompt:match("^/%S") then
        self:invoke_slash(prompt)
    else
        self:prompt_turn(prompt)
    end
    return true
end

--- @private
--- Route a "/command args" submission to the daemon for the active session. The
--- daemon dispatches: a command it owns runs as a daemon action (its outcome is
--- reported here), anything else is forwarded to the agent as a prompt turn (its
--- output streams into the transcript, like a normal turn).
--- @param text string the raw prompt, starting with "/"
function Context:invoke_slash(text)
    local session = self:active_session()
    if not session then
        return
    end
    local command, args = text:match("^/([^%s]+)%s*(.-)%s*$")
    self:call("slash.invoke", {
        session_id = session.session_id,
        command = command,
        args = args ~= "" and args or nil,
    }, function(result)
        -- Daemon commands report an outcome message; forwarded commands stream
        -- their output as transcript events, so only a message is surfaced here.
        if result.message and result.message ~= "" then
            info("tend: " .. result.message)
        end
    end)
end

--- @private
--- When the active session's plan is fully completed, clear its todos panel as
--- the next turn is submitted (mirrors the legacy auto-close) and drop the
--- stored plan so switching back does not resurrect a finished plan.
function Context:collapse_completed_plan()
    local session = self:active_session()
    if not session or not session.plan or #session.plan == 0 then
        return
    end
    for _, entry in ipairs(session.plan) do
        if entry.status ~= "completed" then
            return
        end
    end
    session.plan = nil
    if self.todos then
        self.todos:clear()
    end
    if self.widget then
        self.widget:close_optional_window("todos")
    end
end

--- Register the :Tend* user commands for this context (called by setup).
function Context:register_commands()
    local defs = {
        {
            "TendConnect",
            "connect",
            "Connect to tendd and open the cwd workspace",
        },
        { "TendTaskNew", "task_new", "Create a task and make it current" },
        {
            "TendTaskPick",
            "task_pick",
            "Pick a task and delegate it to a session",
        },
        { "TendClaim", "claim", "Claim the current task" },
        { "TendProvider", "provider_pick", "Pick the ACP provider" },
        { "TendPersona", "persona_pick", "Pick a persona" },
        {
            "TendSessionNew",
            "session_new",
            "Start a task-less session on a chosen provider",
        },
        {
            "TendSessionAttach",
            "session_attach",
            "List active sessions and focus one",
        },
        {
            "TendSessionDisconnect",
            "session_disconnect",
            "Stop following a session in this editor",
        },
        { "TendChat", "chat", "Send a prompt to the focused session" },
        { "TendEvents", "events", "Open the focused session's transcript" },
        { "TendApprove", "approve", "Review pending approvals" },
        {
            "TendOpenChanges",
            "open_changes",
            "Open a change set's files for review",
            "?",
        },
        { "TendDiff", "diff", "Review a change set's before/after diff", "?" },
    }
    for _, def in ipairs(defs) do
        local name, method, desc, nargs = def[1], def[2], def[3], def[4]
        vim.api.nvim_create_user_command(name, function(cmd)
            self[method](self, cmd.args ~= "" and cmd.args or nil)
        end, { desc = desc, nargs = nargs or 0 })
    end
end

--- Connect to the daemon and open the cwd workspace.
function Context:connect()
    self.conn:start()
    self.conn:when_connected(function()
        local dir = vim.fn.getcwd()
        self:call("workspace.open", { dir = dir }, function(ws)
            self.workspace = ws
            info(
                "tend: attached to "
                    .. ws.worktree_root
                    .. " ("
                    .. ws.workspace_id
                    .. ")"
            )
        end)
    end)
end

--- @private
--- @return table|nil workspace
function Context:need_workspace()
    if not self.workspace then
        report("tend: no workspace; run :TendConnect first")
        return nil
    end
    return self.workspace
end

--- Create a task (prompts for a title) and make it current.
function Context:task_new()
    local ws = self:need_workspace()
    if not ws then
        return
    end
    vim.ui.input({ prompt = "Task title: " }, function(title)
        if not title or title == "" then
            return
        end
        self:call("task.create", {
            workspace_id = ws.workspace_id,
            title = title,
        }, function(task)
            self.task = task
            info("tend: created task " .. task.ref.id)
        end)
    end)
end

--- @private
--- @param task table api.Task
--- @return string
local function task_label(task)
    return task.ref.id .. " · " .. task.title .. " [" .. task.status .. "]"
end

--- @private
--- Compose the prompt that hands a task to a session: the task id, title, and
--- description, as a turn the running agent acts on.
--- @param task table api.Task
--- @return string
local function task_prompt(task)
    local prompt = "Please work on task " .. task.ref.id .. ": " .. task.title
    if task.description and task.description ~= "" then
        prompt = prompt .. "\n\n" .. task.description
    end
    return prompt
end

--- @private
--- Fetch the workspace's tasks and pass them to cb; reports and skips cb when
--- there are none. Requires a workspace.
--- @param cb fun(tasks: table[])
function Context:with_tasks(cb)
    local ws = self:need_workspace()
    if not ws then
        return
    end
    self:call("task.list", { workspace_id = ws.workspace_id }, function(result)
        local tasks = result.tasks
        if type(tasks) ~= "table" or #tasks == 0 then
            report("tend: no tasks in this workspace")
            return
        end
        cb(tasks)
    end)
end

--- Pick a task from the workspace's task list and delegate it: make it the
--- current task, then choose a target — a new session or an existing one — and
--- hand the task to it as a prompt turn.
function Context:task_pick()
    self:with_tasks(function(tasks)
        vim.ui.select(tasks, {
            prompt = "Task",
            format_item = task_label,
        }, function(task)
            if not task then
                return
            end
            self.task = task
            self:deliver_task(task)
        end)
    end)
end

--- @private
--- @return table|nil task
function Context:need_task()
    if not self.task then
        report("tend: no current task; run :TendTaskPick or :TendTaskNew")
        return nil
    end
    return self.task
end

--- Claim the current task for the configured assignee.
function Context:claim()
    local task = self:need_task()
    if not task then
        return
    end
    self:call("task.claim", {
        ref = task.ref,
        assignee = self.assignee,
    }, function(updated)
        self.task = updated
        info("tend: claimed " .. updated.ref.id .. " for " .. self.assignee)
    end)
end

--- Pick the ACP provider used as the default for new sessions.
function Context:provider_pick()
    self:pick_provider(function(provider_id)
        self.provider_id = provider_id
    end)
end

--- @private
--- Fetch the workspace's enabled providers from the daemon (provider.list) and
--- pass them to cb; reports and skips cb when none are enabled. Requires a
--- workspace. The daemon — not client config — is the source of truth for which
--- providers exist and are runnable.
--- @param cb fun(providers: table[]) api.ProviderInfo[] (enabled only)
function Context:list_providers(cb)
    local ws = self:need_workspace()
    if not ws then
        return
    end
    self:call(
        "provider.list",
        { workspace_id = ws.workspace_id },
        function(result)
            local enabled = {}
            for _, p in ipairs(result.providers or {}) do
                if p.enabled then
                    table.insert(enabled, p)
                end
            end
            if #enabled == 0 then
                report("tend: no enabled providers on the daemon")
                return
            end
            cb(enabled)
        end
    )
end

--- @private
--- Choose an enabled daemon provider and pass its id to cb. Reports and skips cb
--- when none are available. The selection is not stored as the default — callers
--- that want that (provider_pick) do it themselves.
--- @param cb fun(provider_id: string)
function Context:pick_provider(cb)
    self:list_providers(function(providers)
        vim.ui.select(providers, {
            prompt = "Provider",
            format_item = function(p)
                local label = p.provider_id
                if p.running and p.running > 0 then
                    label = label .. " (running)"
                end
                return label
            end,
        }, function(choice)
            if choice then
                cb(choice.provider_id)
            end
        end)
    end)
end

--- Pick a persona: native definitions (user dirs + workspace .tend/personas)
--- alongside agents imported read-only from harness dirs in the workspace
--- (.claude/agents and friends). The selection is held on the context for
--- prompt composition once sessions carry a persona.
function Context:persona_pick()
    local personas = Discovery.discover({
        user_dirs = self.persona_dirs,
        workspace_root = self.workspace and self.workspace.worktree_root or nil,
        sources = self.persona_sources,
    })
    if #personas == 0 then
        report("tend: no personas found (persona dirs or workspace agents)")
        return
    end
    vim.ui.select(personas, {
        prompt = "Persona",
        format_item = function(persona)
            local label = persona.id
            if
                persona.name ~= ""
                and persona.id:sub(-#persona.name) ~= persona.name
            then
                label = label .. " · " .. persona.name
            end
            if persona.description then
                label = label .. " — " .. persona.description
            end
            return label
        end,
    }, function(persona)
        if persona then
            self.persona = persona
            self.persona_id = persona.id
        end
    end)
end

--- @private
--- The focused session, or nil when none is selected.
--- @return tend.commands.Session|nil
function Context:active_session()
    return self.active and self.sessions[self.active] or nil
end

--- @private
--- Fetch the daemon's SessionInfo for the focused session (the authoritative
--- source of its current/available modes and models) and pass it to cb. Reports
--- and skips cb when no session is focused or the daemon no longer has it.
--- @param cb fun(info: table) api.SessionInfo
function Context:active_session_info(cb)
    local session = self:active_session()
    if not session then
        report(
            "tend: no focused session; run :TendSessionNew or :TendSessionAttach"
        )
        return
    end
    local ws = self.workspace
    local params = ws and { workspace_id = ws.workspace_id } or {}
    self:call("session.list", params, function(result)
        for _, s in ipairs(result.sessions or {}) do
            if s.session_id == session.session_id then
                cb(s)
                return
            end
        end
        report("tend: focused session is no longer on the daemon")
    end)
end

--- @private
--- Format a mode/model option for the picker, marking the current one.
--- @param option table api.SessionMode|api.SessionModel
--- @param current_id? string
--- @return string
local function option_label(option, current_id)
    local label = (option.name and option.name ~= "") and option.name
        or option.id
    return (option.id == current_id and "● " or "  ") .. label
end

--- Switch the focused session's model: pick from the daemon-advertised models
--- for the session and set it (session.set_model). Reports cleanly when the
--- provider offers no model choice, so the keymap is never a dead end.
function Context:switch_model()
    self:active_session_info(function(s)
        local models = s.available_models or {}
        if #models == 0 then
            info("tend: this provider offers no model choice")
            return
        end
        vim.ui.select(models, {
            prompt = "Model",
            format_item = function(m)
                return option_label(m, s.current_model_id)
            end,
        }, function(choice)
            if not choice then
                return
            end
            self:call("session.set_model", {
                session_id = s.session_id,
                model_id = choice.id,
            }, function(res)
                self:apply_session_config(
                    s.session_id,
                    { model_id = res and res.current_model_id or choice.id }
                )
                info("tend: model → " .. option_label(choice):sub(3))
            end)
        end)
    end)
end

--- Switch the focused session's thought/reasoning level: pick from the
--- daemon-advertised modes for the session and set it (session.set_mode). The
--- daemon models reasoning as session modes (tend-e7p.11). Reports cleanly when
--- the provider offers no modes.
function Context:change_thought_level()
    self:active_session_info(function(s)
        local modes = s.available_modes or {}
        if #modes == 0 then
            info("tend: this provider offers no thought/reasoning levels")
            return
        end
        vim.ui.select(modes, {
            prompt = "Thought level",
            format_item = function(m)
                return option_label(m, s.current_mode_id)
            end,
        }, function(choice)
            if not choice then
                return
            end
            self:call("session.set_mode", {
                session_id = s.session_id,
                mode_id = choice.id,
            }, function(res)
                self:apply_session_config(
                    s.session_id,
                    { mode_id = res and res.current_mode_id or choice.id }
                )
                info("tend: thought level → " .. option_label(choice):sub(3))
            end)
        end)
    end)
end

--- @private
--- Record a session's new model/mode locally and refresh the chat header if the
--- session is the focused one. A no-op for an untracked session.
--- @param session_id string
--- @param config { model_id?: string, mode_id?: string }
function Context:apply_session_config(session_id, config)
    local session = self.sessions[session_id]
    if not session then
        return
    end
    if config.model_id then
        session.model_id = config.model_id
    end
    if config.mode_id then
        session.mode_id = config.mode_id
    end
    if self.active == session_id then
        self:render_session_header(session)
    end
end

--- @private
--- Ensure a session is locally tracked: create its chat buffer/view and
--- subscribe to its stream once. Returns the tracked session. Idempotent — a
--- session already tracked (started here, or selected before) is returned
--- as-is, so its transcript and cursor are preserved.
--- @param spec { session_id: string, stream_id: string, workspace_id: string, provider_id?: string }
--- @return tend.commands.Session
function Context:track_session(spec)
    local existing = self.sessions[spec.session_id]
    if existing then
        return existing
    end
    -- Each session gets its own chat buffer from the one widget; the chat
    -- window shows whichever session is active. The buffer renders even while
    -- the widget is hidden, so a session's transcript is ready when shown.
    local bufnr = self:ensure_widget():create_chat_buffer()
    local view = ChatView.new(bufnr, { provider_id = spec.provider_id })
    --- @type tend.commands.Session
    local session = {
        session_id = spec.session_id,
        stream_id = spec.stream_id,
        workspace_id = spec.workspace_id,
        bufnr = bufnr,
        view = view,
        provider_id = spec.provider_id,
    }
    self.sessions[spec.session_id] = session
    -- Replay the session's retained history into the fresh buffer: a session
    -- attached (or re-attached after a disconnect) should show its prior
    -- transcript, not start blank. For a session just started here this is a
    -- no-op (its cursor is already at 0).
    self.conn.subscriber:reset_cursor(spec.workspace_id, spec.stream_id)
    -- One stream, several consumers: the transcript renders every event, the
    -- approval manager reacts to approval_requested/resolved, agent_plan events
    -- feed the todos panel, and slash_commands_updated refreshes this session's
    -- command set for prompt completion.
    self.conn.subscriber:track({
        workspace_id = spec.workspace_id,
        stream_id = spec.stream_id,
        on_event = function(event)
            view:apply(event)
            self.conn.approvals:handle_event(event)
            self:apply_plan(session, event)
            self:apply_commands(session, event)
        end,
    })
    -- Prime the command set so "/" completes before the agent first advertises
    -- commands: the daemon commands are always available, and slash.list returns
    -- the merged set. Later slash_commands_updated events replace it.
    self:call("slash.list", { session_id = spec.session_id }, function(result)
        session.commands = result.commands or {}
    end)
    return session
end

--- @private
--- Refresh a session's slash-command set from a slash_commands_updated event.
--- The event carries the full merged set (provider + daemon commands), so it
--- replaces rather than merges. Non-command events are ignored.
--- @param session tend.commands.Session
--- @param event table daemon event envelope
function Context:apply_commands(session, event)
    if event.type ~= "slash_commands_updated" then
        return
    end
    local payload = type(event.payload) == "table" and event.payload or {}
    session.commands = payload.commands or {}
end

--- @private
--- Route an agent_plan event into a session's stored plan and, when it is the
--- active session, the shared todos panel. Non-plan events are ignored. The full
--- plan replaces the previous one, so replays on reconnect are idempotent.
--- @param session tend.commands.Session
--- @param event table daemon event envelope
function Context:apply_plan(session, event)
    if event.type ~= "agent_plan" then
        return
    end
    local payload = type(event.payload) == "table" and event.payload or {}
    session.plan = payload.entries or {}
    self:render_plan(session)
end

--- One prompt turn on the focused session; the output arrives as transcript
--- events, so only failures are surfaced here.
--- @param text string
function Context:prompt_turn(text)
    local session = self:active_session()
    if not session then
        return
    end
    self:call("agent.prompt", {
        session_id = session.session_id,
        text = text,
    }, function(result)
        if result.status == "error" then
            report("tend: turn ended with error (" .. result.stop_reason .. ")")
        end
    end)
end

--- @private
--- Start a session on the open workspace, track and focus it, and pass the
--- tracked session to cb. task may be nil for a task-less (conversation)
--- session; when set, the session is started bound to that task. Requires a
--- workspace (caller checks). Previously-started sessions stay tracked.
--- @param provider string
--- @param task table|nil api.Task
--- @param cb fun(session: tend.commands.Session)
function Context:start_session(provider, task, cb)
    local ws = self.workspace
    if not ws then
        return
    end
    local params = {
        provider_id = provider,
        workspace_id = ws.workspace_id,
        worktree_root = ws.worktree_root,
    }
    if task then
        params.task = task.ref
    end
    self:call("agent.start", params, function(started)
        local session = self:track_session({
            session_id = started.session_id,
            stream_id = started.stream_id,
            workspace_id = ws.workspace_id,
            provider_id = provider,
        })
        self.active = started.session_id
        cb(session)
    end)
end

--- Start a task-less session: pick a provider, create a conversation session on
--- the open workspace (no task bound), and focus it. Work the session performs
--- stays task-gated by the daemon until a task is delegated to it
--- (see |:TendTaskPick|); this just gets a session going to chat with.
function Context:session_new()
    local ws = self:need_workspace()
    if not ws then
        return
    end
    self:pick_provider(function(provider)
        self:start_session(provider, nil, function(session)
            self:show_session(session, true)
            info(
                "tend: started session "
                    .. session.session_id
                    .. " ("
                    .. provider
                    .. ")"
            )
        end)
    end)
end

--- @private
--- @param s table api.SessionInfo
--- @return string
local function session_label(s)
    local label = s.session_id
        .. " · "
        .. (s.provider_id or "?")
        .. " · "
        .. (s.task and s.task.id or "no task")
        .. " ["
        .. (s.status or "?")
        .. "]"
    if s.pending then
        label = label .. " ⏳" .. s.pending.kind
    end
    return label
end

--- @private
--- Fetch the daemon's sessions (scoped to the current workspace when one is
--- open) and pass them to cb; reports and skips cb when there are none.
--- @param cb fun(sessions: table[])
function Context:with_sessions(cb)
    local ws = self.workspace
    local params = ws and { workspace_id = ws.workspace_id } or {}
    self:call("session.list", params, function(result)
        local list = result.sessions or {}
        if #list == 0 then
            report("tend: no active sessions; run :TendSessionNew to start one")
            return
        end
        cb(list)
    end)
end

--- @private
--- Track a session (idempotent) and make it the focused one.
--- @param s table api.SessionInfo
--- @return tend.commands.Session
function Context:focus_session(s)
    local session = self:track_session({
        session_id = s.session_id,
        stream_id = s.stream_id,
        provider_id = s.provider_id,
        -- The daemon reports a session's workspace independent of its task, so a
        -- task-less session still carries one; fall back to the task's for an
        -- older daemon.
        workspace_id = s.workspace_id or (s.task and s.task.workspace_id) or "",
    })
    -- The daemon's SessionInfo carries the authoritative current model/mode;
    -- record them so the chat header reflects the configuration on attach.
    session.provider_id = s.provider_id or session.provider_id
    session.model_id = s.current_model_id
    session.mode_id = s.current_mode_id
    self.active = s.session_id
    return session
end

--- List the daemon's sessions and focus the chosen one — tracking its stream
--- (transcript) if not already followed, then pointing the chat widget at it so
--- :TendChat / :TendEvents and the input target it. The picker marks the active
--- session and shows each one's status/task. Shared by |:TendSessionAttach| and
--- the in-chat switch keymap, so switching works from inside the chat without
--- leaving it.
function Context:switch_session()
    self:with_sessions(function(list)
        vim.ui.select(list, {
            prompt = "Session",
            format_item = function(s)
                local marker = (s.session_id == self.active) and "● " or "  "
                return marker .. session_label(s)
            end,
        }, function(choice)
            if not choice then
                return
            end
            local session = self:focus_session(choice)
            -- Land in the prompt so the user can type immediately after
            -- switching; the chat pane stays available for reading/copying.
            self:show_session(session, true)
            info("tend: focused session " .. choice.session_id)
        end)
    end)
end

--- List the daemon's sessions, then focus the chosen one. The :TendSessionAttach
--- entry point for the session switcher (see |Context:switch_session|).
function Context:session_attach()
    self:switch_session()
end

--- @private
--- Hand a task to a session: list the workspace's sessions and offer them
--- alongside a "new session" target. Picking an existing session delivers the
--- task to it as a prompt turn; picking "new session" starts a fresh session
--- bound to the task. The target becomes the focused session for follow-up
--- |:TendChat|. Offered even when no sessions exist (new session is always a
--- choice), so it does not dead-end like |:TendSessionAttach|.
--- @param task table api.Task
function Context:deliver_task(task)
    local ws = self.workspace
    local params = ws and { workspace_id = ws.workspace_id } or {}
    self:call("session.list", params, function(result)
        local sessions = result.sessions or {}
        -- A synthetic "new session" target leads the list so it is always
        -- reachable, including when there are no running sessions.
        local new_target = { __new = true }
        local options = { new_target }
        for _, s in ipairs(sessions) do
            table.insert(options, s)
        end
        vim.ui.select(options, {
            prompt = "Deliver " .. task.ref.id .. " to",
            format_item = function(o)
                if o.__new then
                    return "+ New session"
                end
                return session_label(o)
            end,
        }, function(choice)
            if not choice then
                return
            end
            if choice.__new then
                self:start_session_for_task(task)
            else
                local session = self:focus_session(choice)
                self:show_session(session, false)
                self:prompt_turn(task_prompt(task))
                info(
                    "tend: delegated "
                        .. task.ref.id
                        .. " to session "
                        .. choice.session_id
                )
            end
        end)
    end)
end

--- @private
--- Start a new session bound to a task (provider from |:TendProvider| or the
--- first configured one), focus it, and hand it the task as its first turn.
--- @param task table api.Task
function Context:start_session_for_task(task)
    local provider = self.provider_id or self.providers[1]
    if not provider then
        report(
            "tend: no provider; run :TendProvider or configure daemon.providers"
        )
        return
    end
    self:start_session(provider, task, function(session)
        self:show_session(session, false)
        self:prompt_turn(task_prompt(task))
        info(
            "tend: delegated "
                .. task.ref.id
                .. " to new session "
                .. session.session_id
        )
    end)
end

--- Stop following a session in this editor: pick a locally-tracked session and
--- detach from it — unsubscribe its stream and drop its transcript. The session
--- itself keeps running on the daemon (this is a client-side detach, not
--- |agent.stop|), so |:TendSessionAttach| can pick it up again later.
function Context:session_disconnect()
    local tracked = {}
    for _, session in pairs(self.sessions) do
        table.insert(tracked, session)
    end
    if #tracked == 0 then
        report("tend: no tracked sessions to disconnect")
        return
    end
    table.sort(tracked, function(a, b)
        return a.session_id < b.session_id
    end)
    vim.ui.select(tracked, {
        prompt = "Disconnect session",
        format_item = function(s)
            local marker = (s.session_id == self.active) and "● " or "  "
            return marker .. s.session_id
        end,
    }, function(session)
        if not session then
            return
        end
        self:disconnect_session(session)
        info("tend: disconnected session " .. session.session_id)
    end)
end

--- @private
--- Detach a tracked session: unsubscribe its stream, drop the local record and
--- its transcript buffer, and clear focus if it was focused.
--- @param session tend.commands.Session
function Context:disconnect_session(session)
    self.conn.subscriber:untrack(session.stream_id)
    self.sessions[session.session_id] = nil
    if self.active == session.session_id then
        self.active = nil
    end
    -- If the widget is showing this session's buffer, hide it first so the
    -- buffer is not deleted out from under the chat window.
    if self.widget and self.widget.buf_nrs.chat == session.bufnr then
        self.widget:hide()
    end
    if vim.api.nvim_buf_is_valid(session.bufnr) then
        vim.api.nvim_buf_delete(session.bufnr, { force = true })
    end
end

--- Open (or focus) the chat widget on the focused session, cursor in the input.
--- The persistent input drives agent.prompt; replies stream into the same
--- widget, so prompting and reading happen in one place.
function Context:chat()
    local session = self:active_session()
    if not session then
        report(
            "tend: no focused session; run :TendSessionNew or :TendSessionAttach"
        )
        return
    end
    self:show_session(session, true)
end

--- Open (or focus) the chat widget on the focused session, cursor in the
--- transcript (reading rather than composing).
function Context:events()
    local session = self:active_session()
    if not session then
        report(
            "tend: no focused session; run :TendSessionNew or :TendSessionAttach"
        )
        return
    end
    self:show_session(session, false)
end

--- Show the chat widget on the focused session. Backs require("tend").open;
--- reports (does not auto-create) when no session is focused — sessions are
--- created via :TendSessionNew on the daemon path.
--- @param opts tend.ui.ChatWidget.ShowOpts|nil
function Context:open_widget(opts)
    local session = self:active_session()
    if not session then
        report("tend: no focused session; run :TendSessionNew")
        return
    end
    self:show_session(session, not (opts and opts.focus_prompt == false))
end

--- Hide the chat widget. Backs require("tend").close; a no-op when the widget
--- was never opened.
function Context:close_widget()
    if self.widget then
        self.widget:hide()
    end
end

--- Toggle the chat widget: hide it when open, else show it on the focused
--- session. Backs require("tend").toggle.
--- @param opts tend.ui.ChatWidget.ShowOpts|nil
function Context:toggle_widget(opts)
    if self.widget and self.widget:is_open() then
        self.widget:hide()
    else
        self:open_widget(opts)
    end
end

--- Rotate the chat widget through the configured layouts. Backs
--- require("tend").rotate_layout; a no-op when the widget was never opened.
--- @param layouts tend.UserConfig.Windows.Position[]|nil
function Context:rotate_layout(layouts)
    if self.widget then
        self.widget:rotate_layout(layouts)
    end
end

--- @private
--- Resolve a change set id for a review command: an explicit argument, else a
--- prompt. (Auto-resolving "the last set" is deferred — the id lives in the
--- file_edit approval detail, not on the event stream.) Calls cb with the id
--- when one is available.
--- @param arg string|nil
--- @param cb fun(change_set_id: string)
function Context:resolve_change_set(arg, cb)
    if arg and arg ~= "" then
        cb(arg)
        return
    end
    vim.ui.input({ prompt = "Change set id: " }, function(input)
        if input and input ~= "" then
            cb(input)
        end
    end)
end

--- Open a change set's files in buffers for in-place review. Read-only: it
--- fetches the set from file.diff (not task-gated) and opens the named files.
--- @param arg string|nil change set id
function Context:open_changes(arg)
    self:resolve_change_set(arg, function(csid)
        self:call("file.diff", { change_set_id = csid }, function(result)
            local uris = {}
            for _, f in ipairs(result.files or {}) do
                table.insert(uris, f.uri)
            end
            if #uris == 0 then
                report("tend: change set " .. csid .. " has no files")
                return
            end
            DiffReview.open_files(uris)
        end)
    end)
end

--- Review a change set's before/after snapshots in a diff view. Read-only: the
--- snapshots come from file.diff and render locally.
--- @param arg string|nil change set id
function Context:diff(arg)
    self:resolve_change_set(arg, function(csid)
        self:call("file.diff", { change_set_id = csid }, function(result)
            local files = result.files or {}
            if #files == 0 then
                report("tend: change set " .. csid .. " has no files")
                return
            end
            DiffReview.show_snapshots(csid, files)
        end)
    end)
end

--- Sync and surface pending approvals.
function Context:approve()
    self.conn.approvals:sync(function(err, count)
        if not err and count == 0 then
            info("tend: no pending approvals")
        end
    end)
end

return M
