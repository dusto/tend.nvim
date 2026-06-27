--- Core :Tend* user commands over the daemon connection.
---
--- One context per Neovim instance holds the connection plus the current
--- workspace, task, provider, persona, and agent session — connection-scoped
--- state, deliberately not per-tab (the daemon owns sessions; the editor is one
--- client). Commands resolve their inputs via vim.ui.select/vim.ui.input and
--- report failures through the logger, never silently.
---
--- Wired here, sessions fan their event stream out to both the transcript view
--- and the approval manager, so a delegated agent's output and its approval
--- prompts stay in sync. :TendOpenChanges/:TendDiff drive the daemon's
--- diff-review surface (file.diff) and the local diff renderer.
local Connection = require("tend.daemon.connection")
local DiffReview = require("tend.ui.diff_review")
local Discovery = require("tend.persona.discovery")
local Logger = require("tend.utils.logger")
local TranscriptView = require("tend.transcript.view")

local M = {}

--- @class tend.commands.Session
--- @field session_id string
--- @field stream_id string
--- @field workspace_id string
--- @field bufnr integer transcript buffer
--- @field view tend.transcript.View

--- @class tend.commands.Context
--- @field conn tend.daemon.Connection
--- @field workspace? table api.WorkspaceInfo
--- @field task? table api.Task
--- @field provider_id? string
--- @field persona_id? string
--- @field persona? tend.persona.Persona
--- @field sessions table<string, tend.commands.Session> locally-tracked sessions by id
--- @field active? string the focused session id; :TendChat/:TendEvents target it
--- @field private providers string[]
--- @field private assignee string
--- @field private persona_dirs string[]
--- @field private persona_sources? tend.persona.Source[]
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
end

--- Register the :Tend* user commands for this context (called by setup).
function Context:register_commands()
    local defs = {
        {
            "TendAttach",
            "attach",
            "Connect to tendd and open the cwd workspace",
        },
        { "TendTaskNew", "task_new", "Create a task and make it current" },
        { "TendTaskPick", "task_pick", "Pick the current task" },
        { "TendClaim", "claim", "Claim the current task" },
        { "TendProvider", "provider_pick", "Pick the ACP provider" },
        { "TendPersona", "persona_pick", "Pick a persona" },
        {
            "TendDelegate",
            "delegate",
            "Start an agent session on the current task",
        },
        {
            "TendDelegateTo",
            "delegate_to",
            "Route a picked task to an existing session",
        },
        {
            "TendSessions",
            "sessions_pick",
            "List active sessions and focus one",
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
function Context:attach()
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
        report("tend: no workspace; run :TendAttach first")
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

--- Pick the current task from the workspace's task list.
function Context:task_pick()
    self:with_tasks(function(tasks)
        vim.ui.select(tasks, {
            prompt = "Task",
            format_item = task_label,
        }, function(task)
            if task then
                self.task = task
            end
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

--- Pick the ACP provider used for new sessions.
function Context:provider_pick()
    if #self.providers == 0 then
        report("tend: no providers configured (daemon.providers)")
        return
    end
    vim.ui.select(self.providers, { prompt = "Provider" }, function(provider_id)
        if provider_id then
            self.provider_id = provider_id
        end
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
--- Ensure a session is locally tracked: create its transcript buffer/view and
--- subscribe to its stream once. Returns the tracked session. Idempotent — a
--- session already tracked (started here, or selected before) is returned
--- as-is, so its transcript and cursor are preserved.
--- @param spec { session_id: string, stream_id: string, workspace_id: string }
--- @return tend.commands.Session
function Context:track_session(spec)
    local existing = self.sessions[spec.session_id]
    if existing then
        return existing
    end
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "hide"
    local view = TranscriptView.new(bufnr)
    --- @type tend.commands.Session
    local session = {
        session_id = spec.session_id,
        stream_id = spec.stream_id,
        workspace_id = spec.workspace_id,
        bufnr = bufnr,
        view = view,
    }
    self.sessions[spec.session_id] = session
    -- One stream, two consumers: the transcript renders every event and the
    -- approval manager reacts to approval_requested/resolved.
    self.conn.subscriber:track({
        workspace_id = spec.workspace_id,
        stream_id = spec.stream_id,
        on_event = function(event)
            view:apply(event)
            self.conn.approvals:handle_event(event)
        end,
    })
    return session
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

--- Start an agent session on the current task, track it, focus it, and send the
--- first prompt. Previously-started sessions stay tracked and selectable.
function Context:delegate()
    local ws = self:need_workspace()
    if not ws then
        return
    end
    local task = self:need_task()
    if not task then
        return
    end
    local provider = self.provider_id or self.providers[1]
    if not provider then
        report(
            "tend: no provider; run :TendProvider or configure daemon.providers"
        )
        return
    end
    self:call("agent.start", {
        provider_id = provider,
        task = task.ref,
        worktree_root = ws.worktree_root,
    }, function(started)
        self:track_session({
            session_id = started.session_id,
            stream_id = started.stream_id,
            workspace_id = ws.workspace_id,
        })
        self.active = started.session_id
        vim.ui.input({ prompt = "Instruction: " }, function(text)
            if text and text ~= "" then
                self:prompt_turn(text)
            end
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
            report("tend: no active sessions; run :TendDelegate to start one")
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
        workspace_id = s.task and s.task.workspace_id or "",
    })
    self.active = s.session_id
    return session
end

--- List the daemon's sessions, then focus the chosen one — tracking its stream
--- (transcript) if not already followed — so :TendChat / :TendEvents target it.
function Context:sessions_pick()
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
            self:focus_session(choice)
            info("tend: focused session " .. choice.session_id)
        end)
    end)
end

--- Route a task to an existing session: pick a task, pick a running session,
--- and hand the task to it as a prompt turn (rather than starting a new session
--- via :TendDelegate). The chosen session becomes the focused one.
function Context:delegate_to()
    self:with_tasks(function(tasks)
        vim.ui.select(tasks, {
            prompt = "Task to delegate",
            format_item = task_label,
        }, function(task)
            if not task then
                return
            end
            self:with_sessions(function(list)
                vim.ui.select(list, {
                    prompt = "Deliver to session",
                    format_item = session_label,
                }, function(s)
                    if not s then
                        return
                    end
                    self:focus_session(s)
                    self.task = task
                    self:prompt_turn(task_prompt(task))
                    info(
                        "tend: delegated "
                            .. task.ref.id
                            .. " to session "
                            .. s.session_id
                    )
                end)
            end)
        end)
    end)
end

--- Send a prompt turn to the focused session.
function Context:chat()
    if not self:active_session() then
        report("tend: no focused session; run :TendDelegate or :TendSessions")
        return
    end
    vim.ui.input({ prompt = "Prompt: " }, function(text)
        if text and text ~= "" then
            self:prompt_turn(text)
        end
    end)
end

--- Open the focused session's transcript in a split.
function Context:events()
    local session = self:active_session()
    if not session then
        report("tend: no focused session; run :TendDelegate or :TendSessions")
        return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == session.bufnr then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    vim.api.nvim_open_win(session.bufnr, true, {
        split = "right",
        win = 0,
    })
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
