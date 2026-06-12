--- Daemon connection owner: one socket, one identity, one bootstrap path.
---
--- Owns the rpc client's lifecycle for this Neovim instance: connect, the
--- daemon.hello handshake, client.register (a stable client id, editor role,
--- prompt-capable), then bootstrapping the stream subscriber (with the daemon
--- epoch, so cursors survive a reconnect and reset across a daemon restart) and
--- the approval manager (which re-syncs pending approvals). On disconnect both
--- are notified and a reconnect is scheduled; the same identity is re-registered
--- so the daemon sees a returning client, not a new one.
---
--- The transport is injectable (connect_fn/defer_fn) so the whole lifecycle is
--- unit-testable without a socket or timers.
local Logger = require("tend.utils.logger")
local ApprovalManager = require("tend.approval.manager")
local StreamSubscriber = require("tend.rpc.stream_subscriber")
local Versions = require("tend.daemon.versions")
local rpc = require("tend.rpc.client")

local M = {}

-- Wire method names, matching the daemon contract.
M.METHOD_HELLO = "daemon.hello"
M.METHOD_REGISTER = "client.register"

-- Synthetic client-side error code for a request issued while disconnected.
M.ERR_NOT_CONNECTED = -32001

--- @alias tend.daemon.Status "disconnected"|"connecting"|"connected"

--- @class tend.daemon.Connection
--- @field subscriber tend.rpc.StreamSubscriber
--- @field approvals tend.approval.Manager
--- @field private client_id string
--- @field private role string
--- @field private prompt_capable boolean
--- @field private socket_path string|nil
--- @field private connect_fn fun(opts: table, cb: fun(client: tend.rpc.Client|nil, err: string|nil))
--- @field private defer_fn fun(fn: function, ms: integer)
--- @field private reconnect_delay_ms integer
--- @field private on_error fun(msg: string)
--- @field private on_status fun(status: tend.daemon.Status)
--- @field private client tend.rpc.Client|nil
--- @field private state tend.daemon.Status
--- @field private stopped boolean
--- @field private retry_pending boolean
--- @field private waiters function[] callbacks queued for the next connect
--- @field private hello? { versions: table<string, string>, daemon_epoch: string }
--- @field private version_mismatch? string why the last handshake failed the pin
local Connection = {}
Connection.__index = Connection
M.Connection = Connection

--- @class tend.daemon.ConnectionOpts
--- @field client_id? string Stable identity; reused across reconnects.
--- @field role? string "editor" (default) or "observer".
--- @field prompt_capable? boolean Defaults to true.
--- @field socket_path? string Defaults to the daemon's well-known socket.
--- @field connect_fn? fun(opts: table, cb: fun(client: tend.rpc.Client|nil, err: string|nil))
--- @field defer_fn? fun(fn: function, ms: integer)
--- @field reconnect_delay_ms? integer
--- @field on_error? fun(msg: string)
--- @field on_status? fun(status: tend.daemon.Status)
--- @field subscriber? tend.rpc.StreamSubscriber
--- @field approvals? tend.approval.Manager

--- @param opts? tend.daemon.ConnectionOpts
--- @return tend.daemon.Connection
function Connection.new(opts)
    opts = opts or {}
    return setmetatable({
        client_id = opts.client_id or ("nvim-" .. vim.fn.getpid()),
        role = opts.role or "editor",
        prompt_capable = opts.prompt_capable ~= false,
        socket_path = opts.socket_path,
        connect_fn = opts.connect_fn or function(copts, cb)
            rpc.connect(copts, cb)
        end,
        defer_fn = opts.defer_fn or function(fn, ms)
            vim.defer_fn(fn, ms)
        end,
        reconnect_delay_ms = opts.reconnect_delay_ms or 2000,
        on_error = opts.on_error or function(msg)
            Logger.notify(msg, vim.log.levels.ERROR)
        end,
        on_status = opts.on_status or function() end,
        subscriber = opts.subscriber or StreamSubscriber.StreamSubscriber.new(),
        approvals = opts.approvals or ApprovalManager.Manager.new(),
        client = nil,
        state = "disconnected",
        stopped = false,
        retry_pending = false,
        waiters = {},
    }, Connection)
end

--- Begin connecting (idempotent); safe to call while already connected.
function Connection:start()
    self.stopped = false
    if self.state ~= "disconnected" then
        return
    end
    self:connect_once()
end

--- Close the connection and stop reconnecting.
function Connection:stop()
    self.stopped = true
    local client = self.client
    if client then
        client:close()
    end
    self:handle_disconnect()
end

--- @return tend.daemon.Status
function Connection:status()
    return self.state
end

--- @class tend.daemon.ConnectionInfo
--- @field status tend.daemon.Status
--- @field client_id string
--- @field versions? table<string, string> daemon versions from the last hello
--- @field daemon_epoch? string
--- @field version_mismatch? string why the last handshake failed the pin

--- A health-reporting snapshot of the connection.
--- @return tend.daemon.ConnectionInfo
function Connection:info()
    --- @type tend.daemon.ConnectionInfo
    local info = {
        status = self.state,
        client_id = self.client_id,
        version_mismatch = self.version_mismatch,
    }
    if self.hello then
        info.versions = self.hello.versions
        info.daemon_epoch = self.hello.daemon_epoch
    end
    return info
end

--- Issue a request on the live connection. While disconnected the callback
--- receives a synthetic ERR_NOT_CONNECTED error instead.
--- @param method string
--- @param params any
--- @param cb? fun(err: tend.rpc.Error|nil, result: any)
function Connection:request(method, params, cb)
    local client = self.client
    if self.state ~= "connected" or not client then
        if cb then
            cb({
                code = M.ERR_NOT_CONNECTED,
                message = "tend: not connected to the daemon",
            }, nil)
        end
        return
    end
    client:request(method, params, cb)
end

--- Run cb now when connected, otherwise once the next bootstrap completes.
--- @param cb function
function Connection:when_connected(cb)
    if self.state == "connected" then
        cb()
        return
    end
    table.insert(self.waiters, cb)
end

--- @private
--- @param status tend.daemon.Status
function Connection:set_state(status)
    self.state = status
    self.on_status(status)
end

--- @private
function Connection:connect_once()
    self:set_state("connecting")
    self.connect_fn({
        path = self.socket_path,
        on_error = self.on_error,
        on_disconnect = function()
            self:handle_disconnect()
        end,
    }, function(client, err)
        if not client then
            self.on_error("tend: daemon connect failed: " .. tostring(err))
            self:set_state("disconnected")
            self:schedule_reconnect()
            return
        end
        self:handshake(client)
    end)
end

--- @private
--- Play hello + register on a fresh transport, then bootstrap the subscriber
--- (with the daemon epoch) and the approval manager. The hello reply is
--- checked against the plugin's version pin before anything else happens; a
--- mismatch is terminal — retrying cannot heal it, so no reconnect is
--- scheduled (a later :TendAttach may try again after a daemon upgrade).
--- @param client tend.rpc.Client
function Connection:handshake(client)
    client:request(M.METHOD_HELLO, {
        required = Versions.REQUIRED,
    }, function(err, hello)
        if err then
            self:handshake_failed(client, "hello", err)
            return
        end
        local ok, why = Versions.satisfies(hello.versions, Versions.REQUIRED)
        if not ok then
            self.version_mismatch = why
            self.on_error("tend: daemon API version mismatch: " .. why)
            client:close()
            self:set_state("disconnected")
            return
        end
        self.version_mismatch = nil
        self.hello = {
            versions = hello.versions,
            daemon_epoch = hello.daemon_epoch,
        }
        client:request(M.METHOD_REGISTER, {
            client_id = self.client_id,
            role = self.role,
            prompt_capable = self.prompt_capable,
        }, function(rerr)
            if rerr then
                self:handshake_failed(client, "register", rerr)
                return
            end
            self.client = client
            self.subscriber:bootstrap(client, hello.daemon_epoch)
            self.approvals:bootstrap(client)
            self:set_state("connected")
            local waiters = self.waiters
            self.waiters = {}
            for _, waiter in ipairs(waiters) do
                pcall(waiter)
            end
        end)
    end)
end

--- @private
--- @param client tend.rpc.Client
--- @param step string
--- @param err tend.rpc.Error
function Connection:handshake_failed(client, step, err)
    self.on_error("tend: daemon " .. step .. " failed: " .. err.message)
    client:close()
    self:set_state("disconnected")
    self:schedule_reconnect()
end

--- @private
--- Transport loss (or stop): release the client, tell the subscriber and the
--- approval manager, and arrange the next attempt. Idempotent — the close we
--- issue ourselves also fires the transport's on_disconnect.
function Connection:handle_disconnect()
    if self.state == "disconnected" and not self.client then
        return
    end
    self.client = nil
    self.subscriber:disconnected()
    self.approvals:disconnected()
    self:set_state("disconnected")
    self:schedule_reconnect()
end

--- @private
function Connection:schedule_reconnect()
    if self.stopped or self.retry_pending then
        return
    end
    self.retry_pending = true
    self.defer_fn(function()
        self.retry_pending = false
        if not self.stopped and self.state == "disconnected" then
            self:connect_once()
        end
    end, self.reconnect_delay_ms)
end

return M
