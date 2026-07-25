--- A scripted tendd stand-in for smoke tests: a real Unix-socket JSON-RPC
--- server with canned daemon-method handlers.
---
--- It runs inside the (child) Neovim process under test, next to the plugin,
--- so one libuv loop serves both ends of the socket and the plugin's real
--- connect path is exercised — no injected transports. Every inbound request
--- is recorded in `calls`; replies come from default handlers (overridable per
--- method via `responses`). The test drives the daemon side with `notify` /
--- `push_event` (broadcast to connected clients) and `drop` (close client
--- connections while staying listening, so reconnect can be observed).
local rpc = require("tend.rpc.client")

local uv = vim.uv or vim.loop

local M = {}

--- @class tests.FakeDaemon
--- @field path string socket path
--- @field epoch string daemon_epoch reported on hello
--- @field calls { method: string, params: any }[] every request, in order
--- @field responses table<string, fun(params: any): any> per-method overrides
--- @field server uv.uv_pipe_t listening socket (managed by start/stop)
--- @field private conns { pipe: uv.uv_pipe_t, client: tend.rpc.Client }[]
local FakeDaemon = {}
FakeDaemon.__index = FakeDaemon
M.FakeDaemon = FakeDaemon

-- The daemon contract versions the fake reports: the real shape, satisfying
-- the plugin's pin.
M.VERSIONS = {
    plugin_to_daemon = "0.28.0",
    daemon_to_editor = "0.2.0",
    daemon_to_client = "1.0.0",
}

-- Methods the fake daemon serves.
local METHODS = {
    "daemon.hello",
    "client.register",
    "workspace.open",
    "events.subscribe",
    "events.unsubscribe",
    "task.create",
    "task.list",
    "task.claim",
    "provider.list",
    "agent.start",
    "agent.prompt",
    "slash.list",
    "slash.complete",
    "slash.invoke",
    "approval.list",
    "approval.respond",
}

--- @param daemon tests.FakeDaemon
--- @return table<string, fun(params: any): any>
local function default_handlers(daemon)
    return {
        ["daemon.hello"] = function()
            return {
                versions = M.VERSIONS,
                daemon_epoch = daemon.epoch,
            }
        end,
        ["client.register"] = function(params)
            return { client_id = params.client_id }
        end,
        ["workspace.open"] = function(params)
            return {
                workspace_id = "ws-1",
                worktree_root = params.dir,
                worktree_id = "wt-1",
                ephemeral = false,
                daemon_epoch = daemon.epoch,
            }
        end,
        ["events.subscribe"] = function()
            return { tail = 0 }
        end,
        ["events.unsubscribe"] = function()
            return vim.NIL
        end,
        ["task.create"] = function(params)
            return {
                ref = {
                    provider = "beads",
                    workspace_id = params.workspace_id,
                    id = "t-1",
                },
                title = params.title,
                status = "open",
            }
        end,
        ["task.list"] = function()
            return { tasks = {} }
        end,
        ["task.claim"] = function(params)
            return {
                ref = params.ref,
                title = "task",
                status = "in_progress",
                assignee = params.assignee,
            }
        end,
        ["provider.list"] = function()
            return {
                providers = {
                    { provider_id = "codex", enabled = true, running = 0 },
                },
            }
        end,
        ["agent.start"] = function()
            return {
                session_id = "ses-1",
                stream_id = "str-ses-1",
                status = "idle",
            }
        end,
        ["agent.prompt"] = function()
            return { stop_reason = "end_turn", status = "idle" }
        end,
        ["slash.list"] = function()
            return {
                commands = {
                    {
                        name = "tasks",
                        description = "List tasks",
                        origin = "daemon",
                    },
                },
            }
        end,
        ["slash.complete"] = function()
            return { candidates = {} }
        end,
        ["slash.invoke"] = function()
            return { origin = "daemon", message = "ok" }
        end,
        ["approval.list"] = function()
            return { approvals = {} }
        end,
        ["approval.respond"] = function()
            return vim.empty_dict()
        end,
    }
end

--- Start a fake daemon listening on a fresh (or given) socket path.
--- @param path string|nil
--- @return tests.FakeDaemon
function M.start(path)
    local self = setmetatable({
        path = path or vim.fn.tempname(),
        epoch = "epoch-1",
        calls = {},
        responses = {},
        conns = {},
    }, FakeDaemon)
    self.responses = default_handlers(self)

    local server = assert(uv.new_pipe(false))
    self.server = server
    assert(server:bind(self.path))
    assert(server:listen(16, function(err)
        assert(not err, err)
        self:accept()
    end))
    return self
end

--- Accept one client connection and wire the daemon-role rpc endpoint to it
--- (called by the listen callback installed in start).
function FakeDaemon:accept()
    local pipe = assert(uv.new_pipe(false))
    self.server:accept(pipe)
    local client = rpc.Client.new({
        writer = function(data)
            pipe:write(data)
        end,
        closer = function()
            if not pipe:is_closing() then
                pipe:close()
            end
        end,
    })
    for _, method in ipairs(METHODS) do
        client:on_request(method, function(params)
            table.insert(self.calls, { method = method, params = params })
            local respond = self.responses[method]
            if not respond then
                return nil,
                    {
                        code = -32601,
                        message = "fake daemon: no handler for " .. method,
                    }
            end
            return respond(params)
        end)
    end
    pipe:read_start(function(rerr, data)
        if rerr or not data then
            client:close()
            return
        end
        -- Mirror the plugin's transport: dispatch outside fast-event context.
        vim.schedule(function()
            client:feed(data)
        end)
    end)
    table.insert(self.conns, { pipe = pipe, client = client })
end

--- The recorded requests for one method, in arrival order.
--- @param method string
--- @return any[] params_list
function FakeDaemon:calls_for(method)
    local out = {}
    for _, call in ipairs(self.calls) do
        if call.method == method then
            table.insert(out, call.params)
        end
    end
    return out
end

--- Send a daemon->client notification to every connected client.
--- @param method string
--- @param params any
function FakeDaemon:notify(method, params)
    for _, conn in ipairs(self.conns) do
        if not conn.pipe:is_closing() then
            conn.client:notify(method, params)
        end
    end
end

--- Push one event envelope on its stream (an event.push notification).
--- @param event table
function FakeDaemon:push_event(event)
    self:notify("event.push", { event = event })
end

--- Close every client connection (the clients see EOF) while the server keeps
--- listening, so a reconnecting client lands on the same daemon.
function FakeDaemon:drop()
    for _, conn in ipairs(self.conns) do
        if not conn.pipe:is_closing() then
            conn.pipe:close()
        end
    end
    self.conns = {}
end

--- Shut the daemon down: drop clients, stop listening, remove the socket.
function FakeDaemon:stop()
    self:drop()
    if not self.server:is_closing() then
        self.server:close()
    end
    vim.fn.delete(self.path)
end

return M
