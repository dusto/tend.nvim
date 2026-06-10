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
--- prompts stay in sync. :TendOpenChanges/:TendDiff are not registered yet:
--- they need the daemon's diff-review methods (file.diff/editor.diff), which
--- have not landed.
local Connection = require("tend.daemon.connection")
local Logger = require("tend.utils.logger")
local TranscriptView = require("tend.transcript.view")

local M = {}

--- @class tend.commands.Session
--- @field session_id string
--- @field stream_id string
--- @field bufnr integer transcript buffer
--- @field view tend.transcript.View

--- @class tend.commands.Context
--- @field conn tend.daemon.Connection
--- @field workspace? table api.WorkspaceInfo
--- @field task? table api.Task
--- @field provider_id? string
--- @field persona_id? string
--- @field session? tend.commands.Session
--- @field private providers string[]
--- @field private assignee string
--- @field private persona_dirs string[]
local Context = {}
Context.__index = Context
M.Context = Context

--- @class tend.commands.Opts
--- @field socket? string Daemon socket path override.
--- @field providers? string[] ACP provider ids offered by :TendProvider.
--- @field assignee? string Task assignee used by :TendClaim.
--- @field persona_dirs? string[] Directories scanned for native personas.
--- @field connection? tend.daemon.Connection Injected connection (tests).

--- Build the context and register the :Tend* user commands. Re-running setup
--- replaces the registered commands; the context is rebuilt.
--- @param opts? tend.commands.Opts
--- @return tend.commands.Context
function M.setup(opts)
    opts = opts or {}
    local self = setmetatable({
        conn = opts.connection
            or Connection.Connection.new({ socket_path = opts.socket }),
        providers = opts.providers or {},
        assignee = opts.assignee or vim.env.USER or "tend",
        persona_dirs = opts.persona_dirs
            or { vim.fn.expand("~/.config/tend/personas") },
        workspace = nil,
        task = nil,
        provider_id = nil,
        persona_id = nil,
        session = nil,
    }, Context)
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
        { "TendChat", "chat", "Send a prompt to the current session" },
        { "TendEvents", "events", "Open the session transcript" },
        { "TendApprove", "approve", "Review pending approvals" },
    }
    for _, def in ipairs(defs) do
        local name, method, desc = def[1], def[2], def[3]
        vim.api.nvim_create_user_command(name, function()
            self[method](self)
        end, { desc = desc })
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

--- Pick the current task from the workspace's task list.
function Context:task_pick()
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
        vim.ui.select(tasks, {
            prompt = "Task",
            format_item = function(task)
                return task.ref.id
                    .. " · "
                    .. task.title
                    .. " ["
                    .. task.status
                    .. "]"
            end,
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

--- Pick a persona from the native persona directories. The full picker with
--- harness-agent import is tracked separately; this lists native definitions.
function Context:persona_pick()
    local ids = {}
    for _, dir in ipairs(self.persona_dirs) do
        for _, path in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
            table.insert(ids, vim.fn.fnamemodify(path, ":t:r"))
        end
    end
    if #ids == 0 then
        report("tend: no personas found in configured persona dirs")
        return
    end
    vim.ui.select(ids, { prompt = "Persona" }, function(persona_id)
        if persona_id then
            self.persona_id = persona_id
        end
    end)
end

--- @private
--- One prompt turn on the current session; the output arrives as transcript
--- events, so only failures are surfaced here.
--- @param text string
function Context:prompt_turn(text)
    local session = self.session
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

--- Start an agent session on the current task and send the first prompt.
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
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].bufhidden = "hide"
        local view = TranscriptView.new(bufnr)
        self.session = {
            session_id = started.session_id,
            stream_id = started.stream_id,
            bufnr = bufnr,
            view = view,
        }
        -- One stream, two consumers: the transcript renders every event and
        -- the approval manager reacts to approval_requested/resolved.
        self.conn.subscriber:track({
            workspace_id = ws.workspace_id,
            stream_id = started.stream_id,
            on_event = function(event)
                view:apply(event)
                self.conn.approvals:handle_event(event)
            end,
        })
        vim.ui.input({ prompt = "Instruction: " }, function(text)
            if text and text ~= "" then
                self:prompt_turn(text)
            end
        end)
    end)
end

--- Send a prompt turn to the current session.
function Context:chat()
    if not self.session then
        report("tend: no session; run :TendDelegate first")
        return
    end
    vim.ui.input({ prompt = "Prompt: " }, function(text)
        if text and text ~= "" then
            self:prompt_turn(text)
        end
    end)
end

--- Open the current session's transcript in a split.
function Context:events()
    local session = self.session
    if not session then
        report("tend: no session; run :TendDelegate first")
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

--- Sync and surface pending approvals.
function Context:approve()
    self.conn.approvals:sync(function(err, count)
        if not err and count == 0 then
            info("tend: no pending approvals")
        end
    end)
end

return M
